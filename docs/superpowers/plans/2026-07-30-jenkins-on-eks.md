# Jenkins on EKS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **DELETE THIS FILE IN THE SAME COMMIT AS TASK 10.** `CLAUDE.md` requires it: an executed plan left
> in the repo reads like pending work. `docs/superpowers/` regenerates every time this workflow runs,
> so deleting it once is not a fix — the deletion happens at the end of *every* plan.

**Goal:** Retire the dedicated Jenkins EC2 host and run CI inside the EKS cluster, with no loss of
pipeline behaviour and no privileged containers.

**Architecture:** Jenkins controller runs as a disposable pod in a new `ci` namespace, installed by
Terraform via the official `jenkins/jenkins` Helm chart, configured entirely by the existing JCasC
file. Builds run in ephemeral pod agents using rootless BuildKit (no Docker daemon), scanning an OCI
tarball with Trivy and pushing that same file with skopeo. Layer cache and Trivy's database live in
ECR. Jenkins still never deploys — it pushes a tag-bump commit and ArgoCD reconciles.

**Tech Stack:** Terraform (aws ~> 5.0, helm v3 provider), Helm, EKS 1.36, Jenkins LTS + JCasC,
rootless BuildKit, Trivy, skopeo, AWS ECR / ACM / Secrets Manager / External Secrets Operator.

**Design doc:** `docs/design/2026-07-30-jenkins-on-eks-design.md`. Read it before Task 1. Section
references below (§2, §5a, §7…) point at it.

## Execution order (decided 2026-07-30)

Work happens on branch **`feat/jenkins-on-eks`**, in the main working directory — **not a git
worktree**. `terraform/backend.hcl`, `terraform/voteball.tfvars` and `terraform/jenkins/jenkins.tfvars`
are gitignored and exist only here, so every `terraform init/plan/apply` below would fail in a
worktree.

Because ArgoCD syncs `charts/voteball` from `master` only, the tasks do not run in numerical order:

| Phase | Tasks | Where |
|---|---|---|
| 1 | 1, 2, 3, 4, 5, 6, 8 | branch — all code and Terraform |
| 2 | *merge to `master`* | — |
| 3 | 7, 9 | master — the ALB swap needs ArgoCD, and cutover needs the webhook path |
| 4 | 10 | master — irreversible; gated on a week of green builds |

**Terraform applies in phase 1 change live infrastructure while `master` does not yet describe it.**
That drift is accepted and ends at the merge; do not rebuild the stack from `master` mid-migration.

## Global Constraints

- **No hardcoded account, region, domain, registry or ARN anywhere.** Identity comes from
  `terraform/voteball.tfvars` and `terraform output` only. A hardcoded value is a bug.
- **No `Claude-Session:` trailer and no `claude.ai/code/session_...` URL in any commit message.**
- **Commit and push as you go.** Never force-push.
- **All containers:** non-root, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
  `readOnlyRootFilesystem: true` where possible. **No privileged container may be introduced** — this
  is the requirement that ruled out Docker-in-Docker.
- **Jenkins gets no cluster-deploy capability.** Namespace-scoped `Role` in `ci` only. No
  `ClusterRole`, no `ClusterRoleBinding`, no access to `devops-app`.
- **Do not remove the Guard stage from the `Jenkinsfile` or `scripts/ci/should-skip-build.sh`.** It is
  the only thing preventing an unbounded, billable build loop.
- **`terraform fmt -recursive`** before committing any `.tf` change.
- **Terraform init needs `-backend-config=backend.hcl`** (generated, gitignored). Run
  `../scripts/bootstrap-tf-backend.sh` first if it is missing.
- **`terraform apply` creates billed resources.** Every apply step in this plan is a stop-and-confirm
  point; never run one unattended.
- **Chart versions drift.** Verify with `helm search repo <chart> --versions` before pinning, and
  record the verification date in a comment, matching the existing `addon-*.tf` style.
- **Prefer JCasC and the Jenkins CLI over the UI and over Helm values** (operator instruction,
  2026-07-30). Anything describing Jenkins' configuration or its build environment belongs in
  `ci/jenkins/jenkins.yaml`; anything operational goes through `scripts/jenkins-cli.sh`. The UI is
  not reachable from outside the cluster by design, and a UI change would not survive a restart of a
  controller whose home directory is an `emptyDir`.
- **Cluster is EKS 1.36** (`v1.36.2-eks`, two `t3.large` Spot nodes, `il-central-1a`/`1b`).

---

## File Structure

**Created**
| Path | Responsibility |
|---|---|
| `ci/jenkins/Dockerfile` | Controller image: Jenkins LTS + plugins baked in |
| `ci/jenkins/plugins.txt` | Plugin list (moved from `terraform/jenkins/casc/`) |
| `ci/jenkins/jenkins.yaml` | JCasC config (moved from `terraform/jenkins/casc/`) |
| `charts/jenkins-support/` | Tiny local chart: SecretStore, ExternalSecret, NetworkPolicy |
| `terraform/addon-jenkins.tf` | Namespace, IRSA, ACM cert, both `helm_release`s |
| `scripts/mirror-trivy-db.sh` | Mirrors Trivy's vulnerability DB into ECR |
| `scripts/tests/test-jenkins-chart.sh` | Offline `helm template` assertions (RBAC scope, JCasC) |

**Modified**
| Path | Change |
|---|---|
| `terraform/ecr.tf` | +1 immutable repo, +2 **mutable** cache repos outside `local.ecr_repos` |
| `terraform/addon-eso.tf` | Widen ESO's Secrets Manager ARN list to include the Jenkins secret |
| `terraform/secrets.tf` | Adopt the imported `voteball/jenkins` secret |
| `charts/voteball/templates/ingress.yaml` | `group.name` annotation |
| `Jenkinsfile` | Pod agent; 4 stages rewritten; `post` block deleted |
| `scripts/deploy.sh` | Seed the Jenkins secret during a rebuild |
| `scripts/build-push-ecr.sh` | Optional `jenkins` target |
| `docs/cicd.md`, `docs/security.md`, `docs/deploy.md`, `CLAUDE.md`, … | See Task 10 |

**Deleted**
| Path | Why |
|---|---|
| `terraform/jenkins/` | The entire EC2 stack |
| `docs/superpowers/plans/2026-07-30-jenkins-on-eks.md` | This file, in Task 10's commit |

---

### Task 1: ECR repositories for the controller image and the two caches

**Files:**
- Modify: `terraform/ecr.tf:3-5` (the `local.ecr_repos` list) and append new resources

**Interfaces:**
- Produces: ECR repositories `${cluster_name}-jenkins` (immutable),
  `${cluster_name}-buildcache` (**mutable**), `${cluster_name}-trivy-db` (**mutable**). Later tasks
  reference these exact names.

- [ ] **Step 1: Add the controller repo to the existing immutable set**

In `terraform/ecr.tf`, change the locals block:

```hcl
locals {
  # jenkins is the CI controller image (plugins baked in, see ci/jenkins/Dockerfile). It belongs in
  # this immutable set like the others: its tag is a git SHA and must never be overwritten.
  ecr_repos = ["backend", "worker", "nginx", "backup", "jenkins"]
}
```

- [ ] **Step 2: Add the two cache repositories — deliberately OUTSIDE that set**

Append to `terraform/ecr.tf`:

```hcl
# ---- Build caches. MUTABLE ON PURPOSE, and deliberately NOT in local.ecr_repos. ----
#
# Every repo above is IMMUTABLE because a git-SHA tag is unique and must never be silently
# overwritten. Cache tags are the exact opposite: they are REWRITTEN on every build by design.
# Adding either repo below to local.ecr_repos makes every build fail on cache export with
# "cannot overwrite immutable tag", and the error surfaces at the end of a long build.
#
# buildcache: BuildKit layer cache (--export-cache/--import-cache type=registry).
# trivy-db:   a mirror of Trivy's vulnerability database, so scans do not pull from ghcr.io on every
#             build. Replaces the TRIVY_CACHE host mount the EC2 host used; a pod volume could not
#             do this job because it dies with the build. See the design doc section 5a.
resource "aws_ecr_repository" "cache" {
  for_each             = toset(["buildcache", "trivy-db"])
  name                 = "${var.cluster_name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    # These hold cache blobs and a vulnerability database, not deployable images. Scanning them
    # produces noise about a scanner's own contents.
    scan_on_push = false
  }
}

# Cache grows without bound otherwise: every build writes new layer blobs and orphans the old ones.
resource "aws_ecr_lifecycle_policy" "cache" {
  for_each   = aws_ecr_repository.cache
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire cache blobs after 14 days"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
```

- [ ] **Step 3: Format and validate**

```bash
cd terraform
terraform fmt -recursive
terraform validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Plan and confirm exactly five new resources**

```bash
terraform plan -var-file=voteball.tfvars -target=aws_ecr_repository.app \
  -target=aws_ecr_repository.cache -target=aws_ecr_lifecycle_policy.cache
```
Expected: 1 new `aws_ecr_repository.app["jenkins"]`, 1 new `aws_ecr_lifecycle_policy.app["jenkins"]`,
2 new `aws_ecr_repository.cache`, 2 new `aws_ecr_lifecycle_policy.cache`. **No changes to the four
existing app repositories** — if any shows a change, stop: the immutable set was edited wrongly.

- [ ] **Step 5: Apply (billed resources — confirm first)**

```bash
terraform apply -var-file=voteball.tfvars
```

- [ ] **Step 6: Verify mutability is what each repo needs**

```bash
aws ecr describe-repositories \
  --query 'repositories[?starts_with(repositoryName,`voteball-`)].[repositoryName,imageTagMutability]' \
  --output table
```
Expected: `voteball-jenkins` → `IMMUTABLE`; `voteball-buildcache` and `voteball-trivy-db` →
`MUTABLE`; the four app repos unchanged at `IMMUTABLE`.

- [ ] **Step 7: Commit**

```bash
git add terraform/ecr.tf
git commit -m "feat(ecr): add jenkins controller repo and two mutable cache repos

The cache repos are deliberately outside local.ecr_repos: that set is
IMMUTABLE because git-SHA tags must never be overwritten, while cache
tags are rewritten every build by design. Adding them to it fails every
build's cache export."
git push origin feat/jenkins-on-eks
```

---

### Task 2: The Jenkins controller image

**Files:**
- Create: `ci/jenkins/Dockerfile`, `ci/jenkins/plugins.txt`, `ci/jenkins/jenkins.yaml`
- Modify: `scripts/build-push-ecr.sh`

**Interfaces:**
- Consumes: `${cluster_name}-jenkins` ECR repo (Task 1).
- Produces: an image at `<registry>/voteball-jenkins:<tag>` with all plugins pre-installed and JCasC
  at `/var/jenkins_home/casc_configs/jenkins.yaml`. Task 6's `helm_release` references it.

- [ ] **Step 1: Move the two config files, preserving history**

```bash
mkdir -p ci/jenkins
git mv terraform/jenkins/casc/plugins.txt ci/jenkins/plugins.txt
git mv terraform/jenkins/casc/jenkins.yaml ci/jenkins/jenkins.yaml
```

- [ ] **Step 2: Edit `ci/jenkins/plugins.txt` — one plugin out, one in**

Remove the `credentials-binding` entry and its two comment lines (the comment concedes the
`Jenkinsfile` does not use it). Add, in the "what the Jenkinsfile uses" block:

```
# ephemeral pod agents -- the whole reason this host is now in the cluster
kubernetes
```

Rewrite the `docker-workflow` exclusion note, whose stated reason stops being true:

```
#   docker-workflow  -- there is no Docker daemon and no `docker` CLI in a pod agent at all. Builds
#                       use rootless BuildKit via buildctl; see the Jenkinsfile.
```

Replace the "Versions are DELIBERATELY unpinned" paragraph's trade-off sentence with:

```
# The trade-off that used to apply here is gone: these plugins are now baked into an immutable ECR
# image, so the IMAGE TAG is the pin. Two deploys of the same image tag are byte-identical even
# though this file names no versions. `jenkins-plugin-cli --list` output is captured at image build.
```

- [ ] **Step 3: Edit `ci/jenkins/jenkins.yaml` — four changes**

1. Replace the file header's "WHY" paragraph reference to `user_data.sh` with: placeholders are
   resolved from environment variables projected from the `jenkins-secret` Kubernetes Secret, which
   External Secrets Operator syncs from `voteball/jenkins` in Secrets Manager.
2. `numExecutors: 2` → `numExecutors: 0`, with a comment: the controller must not build; agents do.
3. Delete `slaveAgentPort: -1` and its comment; the chart manages the agent listener.
4. Delete the entire `gitHubPluginConfig is NOT configured here` comment block under `unclassified:`
   (the XML workaround, the `hookSecretConfigs` plural/singular trap, the SHA-256 note). The chart
   configures the plugin properly. **Keep the `crumbIssuer` comment** — still accurate.
5. Change `unclassified.location.url` to `https://jenkins.${APP_DOMAIN}/`. It must be the real
   external URL now, because the GitHub plugin builds the webhook URL from it.
6. Add the Kubernetes cloud **and the build pod template**. Per the operator's instruction
   (2026-07-30), as much as possible is declared in JCasC rather than split across the `Jenkinsfile`:
   the `Jenkinsfile` names a label, JCasC owns what that label provisions.

```yaml
  clouds:
    - kubernetes:
        name: "kubernetes"
        serverUrl: "https://kubernetes.default.svc"
        namespace: "ci"
        jenkinsUrl: "http://jenkins.ci.svc.cluster.local:8080"
        jenkinsTunnel: "jenkins-agent.ci.svc.cluster.local:50000"
        directConnection: false
        # Bounded so a wedged agent cannot hold the queue forever.
        containerCapStr: "3"
        retentionTimeout: 5
        connectTimeout: 60
        readTimeout: 60
        templates:
          - name: "voteball-build"
            label: "voteball-build"
            # RAW POD YAML, NOT the typed `containers:` list. That list cannot express
            # securityContext, so the typed form would silently drop
            # allowPrivilegeEscalation:false and capabilities.drop:[ALL] from every container and
            # still start successfully -- the failure mode being avoided is a green build on
            # containers that quietly hold more privilege than the cluster's own rules allow.
            yamlMergeStrategy: override
            yaml: |
              apiVersion: v1
              kind: Pod
              spec:
                serviceAccountName: jenkins
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 1000
                containers:
                  # Rootless BuildKit. NOT privileged, and not Docker-in-Docker: a privileged pod
                  # would be the weakest point in a cluster whose every app container sets
                  # allowPrivilegeEscalation:false. --oci-worker-no-process-sandbox is required
                  # for rootless operation on Kubernetes.
                  - name: buildkit
                    image: moby/buildkit:v0.19.0-rootless
                    args:
                      - --addr=unix:///run/user/1000/buildkit/buildkitd.sock
                      - --oci-worker-no-process-sandbox
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                      runAsUser: 1000
                      seccompProfile: { type: Unconfined }
                    resources:
                      requests: { cpu: "500m", memory: "2Gi" }
                      limits: { memory: "3Gi" }
                    volumeMounts:
                      - { name: images, mountPath: /images }
                  - name: trivy
                    image: aquasec/trivy:0.58.1
                    command: ["cat"]
                    tty: true
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    volumeMounts:
                      - { name: images, mountPath: /images }
                  - name: skopeo
                    image: quay.io/skopeo/stable:v1.17.0
                    command: ["cat"]
                    tty: true
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    volumeMounts:
                      - { name: images, mountPath: /images }
                  - name: awscli
                    image: amazon/aws-cli:2.22.0
                    command: ["cat"]
                    tty: true
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    volumeMounts:
                      - { name: images, mountPath: /images }
                volumes:
                  # Tarballs only. There is deliberately NO cache volume -- both caches live in
                  # ECR, because a pod volume dies with the build and would be a cache in name
                  # only. See the design doc section 5a.
                  - name: images
                    emptyDir: { sizeLimit: 8Gi }
```

> **Cost of putting this here rather than in the `Jenkinsfile`:** bumping a build tool's version (say
> Trivy) is now a `terraform apply` rather than a git commit ArgoCD picks up, because the
> `helm_release` reads this file with `file(...)`. That is a slower loop, accepted deliberately so
> that everything describing the CI *environment* lives in one declarative place. The `Jenkinsfile`
> still owns the build *steps*.

- [ ] **Step 4: Write `ci/jenkins/Dockerfile`**

```dockerfile
# Jenkins controller with plugins baked in.
#
# WHY BAKED: this controller is disposable and restarts roughly daily -- the node group is 100% Spot
# and ASG history showed three reclaims in 84 hours (design doc section 2). The official chart's
# default is to download plugins from updates.jenkins.io at every startup, which at that restart rate
# is both slow and a hard dependency on a third-party site being up. Baking them makes startup a few
# seconds and needs no internet.
#
# ADDING A PLUGIN: edit ci/jenkins/plugins.txt, then rebuild and push this image with
# ./scripts/build-push-ecr.sh jenkins. Editing the file alone changes nothing -- the running
# controller uses the image, not the file.
FROM jenkins/jenkins:lts-jdk21

# jenkins-plugin-cli resolves dependencies itself, which is why plugins.txt lists only top-level
# entries. --verbose records the resolved version of every plugin in the build log: that log IS the
# record of what this tag contains, since the file names no versions.
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --verbose \
 && jenkins-plugin-cli --list

# JCasC is NOT baked into this image, deliberately (decided 2026-07-30). The Helm release supplies
# ci/jenkins/jenkins.yaml through controller.JCasC.configScripts, so a second copy here would be a
# second source of truth that can disagree with it whenever the image and the chart are built from
# different commits.
#
# It would also not work. `persistence.enabled: false` mounts an emptyDir over /var/jenkins_home, so
# anything COPYed under that path is MASKED in the cluster while still being visible to `docker run`
# -- local testing passes and the cluster silently disagrees. The plugins above survive only because
# jenkins-plugin-cli writes them to /usr/share/jenkins/ref/, which the entrypoint copies INTO
# JENKINS_HOME at boot.

# Skip the setup wizard: JCasC owns this configuration, and the wizard would leave the 94-plugin
# "install suggested" set the plugins.txt header exists to replace.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

USER jenkins
```

- [ ] **Step 5: Build the image locally and verify the plugins are present**

```bash
docker build -t voteball-jenkins:test ci/jenkins
docker run --rm --entrypoint sh voteball-jenkins:test -c \
  'ls /usr/share/jenkins/ref/plugins/*.jpi | wc -l; ls /usr/share/jenkins/ref/plugins/ | grep -c "^kubernetes"'
```
Expected: a plugin count well above 8 (dependencies resolved), and at least 1 for `kubernetes`.
If the `kubernetes` count is 0, Step 2's edit did not take.

> **Check `/usr/share/jenkins/ref/plugins/`, not `/var/jenkins_home/plugins/`.** `jenkins-plugin-cli`
> writes to the reference directory, and the entrypoint copies it into `JENKINS_HOME` at boot — which
> is exactly what makes baked plugins survive the `emptyDir` home this controller runs with.
> `/var/jenkins_home/plugins/` does not exist in the built image, so checking it reports 0 and looks
> like a build failure.

- [ ] **Step 6: Verify `credentials-binding` is gone and nothing depends on it**

```bash
docker run --rm --entrypoint sh voteball-jenkins:test -c 'ls /usr/share/jenkins/ref/plugins/ | grep credentials'
```
Expected: `credentials` (a dependency of `git`/`github`, correct) but **not**
`credentials-binding`. If `credentials-binding` appears, something pulled it in transitively — that
is fine and requires no action; note it and move on.

- [ ] **Step 7: Add a `jenkins` target to `scripts/build-push-ecr.sh`**

Extend the script's repo list so `./scripts/build-push-ecr.sh jenkins` builds `ci/jenkins` into
`${cluster_name}-jenkins`. Follow the script's existing structure exactly; do not restructure it.
The Jenkins image is **not** part of the per-commit pipeline — `ECR_REPOS` in the `Jenkinsfile` stays
at four services, so G1 and `scripts/ci/images-exist.sh` are untouched.

- [ ] **Step 8: Push the first controller image by hand**

```bash
./scripts/build-push-ecr.sh jenkins
aws ecr describe-images --repository-name voteball-jenkins \
  --query 'imageDetails[].imageTags' --output table
```
Expected: one tag, the current git short SHA. **Record it** — Task 6 pins it.

- [ ] **Step 9: Commit**

```bash
git add ci/jenkins terraform/jenkins/casc scripts/build-push-ecr.sh
git commit -m "feat(ci): Jenkins controller image with plugins baked in

Moves plugins.txt and jenkins.yaml out of the EC2 stack into ci/jenkins/
and bakes the plugins into an image. A disposable controller restarts
about daily on Spot, and refetching ~8 top-level plugins plus their
dependencies from updates.jenkins.io each boot is both slow and a
third-party dependency at startup.

credentials-binding out (its own comment conceded the Jenkinsfile does
not use it), kubernetes in. numExecutors 0: the controller stops
building, agents do."
git push origin feat/jenkins-on-eks
```

---

### Task 3: Mirror the Trivy database into ECR

**Files:**
- Create: `scripts/mirror-trivy-db.sh`

**Interfaces:**
- Consumes: `${cluster_name}-trivy-db` ECR repo (Task 1).
- Produces: a Trivy DB usable as `--db-repository <registry>/voteball-trivy-db`. Task 8 uses this
  exact flag.

- [ ] **Step 1: Write the mirror script**

```bash
#!/usr/bin/env bash
# Mirror Trivy's vulnerability database into this account's ECR.
#
# WHY: the EC2 build host kept a warm DB in a host mount (TRIVY_CACHE). Pod agents are destroyed
# after every build, so that mount has no equivalent -- and porting it to an emptyDir would silently
# turn a cross-build cache into a per-build one, re-downloading ~100MB on each of four scans, every
# build. That is exactly the ghcr.io rate-limit exposure the original mount existed to prevent.
#
# Mirroring instead is strictly better than the host cache: in-region, no rate limit, and no
# build-time dependency on a third-party host.
#
# Run this after a rebuild, and periodically (weekly is ample -- Trivy publishes every 6h, but a
# few-days-old DB only misses very recent CVEs). A STALE DB MAKES SCANS PASS THAT SHOULD FAIL:
# treat Trivy's stale-database warning in a build log as a build failure, not noise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

region="$(tf_region)"
account="$(aws sts get-caller-identity --query Account --output text)"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
cluster="$(tf_cluster_name)"
dest="${registry}/${cluster}-trivy-db"

echo "Mirroring Trivy DB -> ${dest}"

aws ecr get-login-password --region "$region" \
  | skopeo login --username AWS --password-stdin "$registry"

# ghcr.io/aquasecurity/trivy-db is the OCI-packaged database Trivy pulls by default.
skopeo copy --dest-precompute-digests \
  docker://ghcr.io/aquasecurity/trivy-db:2 \
  "docker://${dest}:2"

echo "Done. Builds pull it via: trivy image --db-repository ${dest}"
```

```bash
chmod +x scripts/mirror-trivy-db.sh
```

- [ ] **Step 2: Confirm the config helpers used above actually exist**

```bash
grep -nE '^(tf_region|tf_cluster_name)\(\)' scripts/lib/config.sh
```
Expected: both functions found. **If either is named differently, use the real name** — do not add a
new helper, and do not hardcode a region or cluster name (Global Constraints).

- [ ] **Step 3: Run it**

```bash
./scripts/mirror-trivy-db.sh
```
Expected: a copy progress log ending without error.

- [ ] **Step 4: Verify a scan works against the mirror with no ghcr.io access**

```bash
REG="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.il-central-1.amazonaws.com"
docker run --rm -v "$HOME/.docker:/root/.docker:ro" aquasec/trivy:0.58.1 \
  image --db-repository "$REG/voteball-trivy-db" --download-db-only
```
Expected: `Downloading vulnerability DB` sourced from the ECR host, then success. If it falls back to
ghcr.io, the mirror tag is wrong.

- [ ] **Step 5: Commit**

```bash
git add scripts/mirror-trivy-db.sh
git commit -m "feat(ci): mirror the Trivy vulnerability DB into ECR

Pod agents are destroyed after every build, so the host's TRIVY_CACHE
mount has no equivalent. An emptyDir would look like a cache and not be
one, restoring the ghcr.io rate-limit exposure the mount prevented.
Mirroring is in-region, unmetered and removes a third-party dependency
from the build path."
git push origin feat/jenkins-on-eks
```

---

### Task 4: Migrate the Jenkins secret into the main stack

**Reordering these steps loses the GitHub deploy key. Recoverable, but not for free — read all steps
first.**

*What is actually at stake.* The secret holds five values: `JENKINS_ADMIN_USER`,
`JENKINS_ADMIN_HASH` (a bcrypt hash — the plaintext admin password exists nowhere in AWS or git),
`GITHUB_DEPLOY_USER` (`git`), `GITHUB_DEPLOY_KEY` (an ed25519 private key with **write** access to the
repo) and `GITHUB_WEBHOOK_SECRET`. Losing the secret means re-running
`scripts/seed-jenkins-secret.sh`, which **generates a new keypair** (line 61) and prints the public
half — so recovery costs a manual GitHub round-trip: add the new deploy key, remove the old one,
update the webhook secret. Not a one-way door, but CI is broken until someone does it by hand.
The backup in Step 1 exists to avoid that round-trip, not to avert a catastrophe.

**Files:**
- Modify: `terraform/secrets.tf`, `terraform/addon-eso.tf:10`, `scripts/deploy.sh`

**Interfaces:**
- Produces: `aws_secretsmanager_secret.jenkins` in the **main** stack's state, and ESO permitted to
  read it. Task 5's ExternalSecret references the secret name `${cluster_name}/jenkins`.

- [ ] **Step 1: Back up the live secret values before touching any state**

```bash
aws secretsmanager get-secret-value --secret-id voteball/jenkins \
  --query SecretString --output text > ~/voteball-jenkins-secret.json
chmod 600 ~/voteball-jenkins-secret.json
grep -c GITHUB_DEPLOY_KEY ~/voteball-jenkins-secret.json
```
Expected: `1`. Store it in a password manager afterwards and delete the local copy.

*(`terraform/jenkins/secrets.tf:12-15` calls this key unrecoverable. That is true of **this** key —
you cannot get the same one back — but not of the capability: `seed-jenkins-secret.sh` mints a
replacement and tells you what to paste into GitHub. Treat a loss here as an outage to repair, not
data destroyed. The comment predates the seed script and overstates the case; fix it in Task 10.)*

- [ ] **Step 2: Detach the secret from the OLD stack's state so its destroy cannot delete it**

```bash
cd terraform/jenkins
terraform init -backend-config=backend.hcl
terraform state rm aws_secretsmanager_secret.jenkins
terraform state rm aws_secretsmanager_secret_version.jenkins_placeholder
```
Expected: `Removed ...` twice. **The AWS resource is untouched** — `state rm` forgets, it does not
delete. Verify:

```bash
aws secretsmanager describe-secret --secret-id voteball/jenkins --query Name --output text
```
Expected: `voteball/jenkins`.

- [ ] **Step 3: Declare the secret in the main stack**

Append to `terraform/secrets.tf`:

```hcl
# ---- Jenkins CI secret ----
# Moved out of the retired terraform/jenkins/ stack on 2026-07-30 by `terraform state rm` there and
# `terraform import` here, so the live secret was never destroyed and recreated. Recreating it was
# not an option: Secrets Manager names are unique and a deleted secret blocks its own name for the
# whole recovery window, and the GITHUB_DEPLOY_KEY inside cannot be recovered from anywhere else.
#
# recovery_window_in_days = 0, UNLIKE the 7 the old stack used. That stack was never destroyed; this
# one is destroyed and rebuilt routinely, and a same-named secret pending deletion for 7 days blocks
# the next apply outright. The cost of 0 is real and is handled by process, not by Terraform:
# scripts/deploy.sh re-seeds this secret on every rebuild, and the operator must hold a copy of the
# deploy key outside AWS. See docs/cicd.md.
resource "aws_secretsmanager_secret" "jenkins" {
  name                    = "${var.cluster_name}/jenkins"
  description             = "Jenkins admin + GitHub deploy key + webhook secret. Seeded by scripts/seed-jenkins-secret.sh; read at boot by JCasC via ESO."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jenkins_placeholder" {
  secret_id     = aws_secretsmanager_secret.jenkins.id
  secret_string = jsonencode({ placeholder = "seed real values via scripts/seed-jenkins-secret.sh" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
```

- [ ] **Step 4: Import the live secret into the main stack**

```bash
cd ../   # terraform/
terraform init -backend-config=backend.hcl
terraform import -var-file=voteball.tfvars aws_secretsmanager_secret.jenkins voteball/jenkins
terraform import -var-file=voteball.tfvars \
  aws_secretsmanager_secret_version.jenkins_placeholder "voteball/jenkins|AWSCURRENT"
```
Expected: `Import successful!` twice.

- [ ] **Step 5: Confirm the plan wants to CHANGE the recovery window, not replace the secret**

```bash
terraform plan -var-file=voteball.tfvars -target=aws_secretsmanager_secret.jenkins
```
Expected: `~ update in-place` with `recovery_window_in_days: 7 -> 0`.
**If it says `-/+ must be replaced`, STOP and re-read Step 4** — a replace destroys the deploy key.

- [ ] **Step 6: Widen ESO's permission to include this secret**

In `terraform/addon-eso.tf`, replace the single-ARN line:

```hcl
  # Scope to exactly the two secrets ESO syncs (+ their 6-char random suffixes) -- least privilege.
  # The jenkins secret was added 2026-07-30 when CI moved into the cluster; without it the Jenkins
  # ExternalSecret fails with an AccessDenied that reads like a misconfiguration.
  external_secrets_secrets_manager_arns = [
    "${aws_secretsmanager_secret.app.arn}*",
    "${aws_secretsmanager_secret.jenkins.arn}*",
  ]
```

- [ ] **Step 7: Add Jenkins-secret seeding to `scripts/deploy.sh`**

The app secret is already seeded at step 3 of `deploy.sh`. Add the Jenkins secret the same way,
including collecting its inputs in the **preflight block at the top of the script** — not inline —
for the reason the script already documents: an inline prompt fails *after* a ~15-minute billed
`terraform apply`. Follow the existing `seed-eks-secret.sh` call's shape exactly.

- [ ] **Step 7b: Fix the webhook URL the seed script prints**

`scripts/seed-jenkins-secret.sh:98` tells the operator to point the webhook at
`http://<elastic-ip>:8080/github-webhook/`. There is no Elastic IP and no port 8080 after this
migration, and this text is what someone follows during a rebuild — leaving it turns a correct script
into confidently wrong instructions. Change it to:

```bash
echo "     Payload URL:  https://jenkins.<app_domain>/github-webhook/"
echo "     SSL verify:   ENABLED (the endpoint is HTTPS via ACM now)"
```

Derive `<app_domain>` from `scripts/lib/config.sh` rather than hardcoding it — Global Constraints.

- [ ] **Step 8: Format, validate, apply**

```bash
terraform fmt -recursive
terraform validate
terraform apply -var-file=voteball.tfvars
```

- [ ] **Step 9: Verify the secret still holds real values, not the placeholder**

```bash
aws secretsmanager get-secret-value --secret-id voteball/jenkins \
  --query SecretString --output text | grep -c GITHUB_DEPLOY_KEY
```
Expected: `1`. If this returns 0, restore from Step 1's backup with
`scripts/seed-jenkins-secret.sh` before continuing.

- [ ] **Step 10: Commit**

```bash
git add terraform/secrets.tf terraform/addon-eso.tf scripts/deploy.sh
git commit -m "refactor(secrets): adopt voteball/jenkins into the main stack

Moved by state rm + import, never destroy/recreate: Secrets Manager
names are unique for the whole recovery window and GITHUB_DEPLOY_KEY has
no other copy.

recovery_window_in_days drops 7 -> 0. The old stack was never destroyed;
this one is rebuilt routinely, where a same-named secret pending
deletion blocks the next apply. deploy.sh now re-seeds it, with the
inputs collected in preflight so the failure cannot land after a billed
apply.

ESO's ARN allowlist widened to both secrets."
git push origin feat/jenkins-on-eks
```

---

### Task 5: The `jenkins-support` chart (SecretStore, ExternalSecret, NetworkPolicy)

**Files:**
- Create: `charts/jenkins-support/Chart.yaml`, `values.yaml`, `templates/externalsecret.yaml`,
  `templates/networkpolicy.yaml`

**Interfaces:**
- Consumes: the `voteball/jenkins` secret (Task 4), namespace `ci` (Task 6 creates it).
- Produces: a Kubernetes Secret named `jenkins-secret` in `ci`, with keys `JENKINS_ADMIN_USER`,
  `JENKINS_ADMIN_HASH`, `GITHUB_DEPLOY_USER`, `GITHUB_DEPLOY_KEY`, `GITHUB_WEBHOOK_SECRET`. Task 6's
  `helm_release` projects these as controller env vars.

*(Why a chart rather than `kubernetes_manifest` resources: `kubernetes_manifest` needs a reachable
cluster at **plan** time, which breaks `terraform plan` on a destroyed cluster — the exact situation
`scripts/deploy.sh` runs in. A local chart installed by `helm_release` has no such requirement, and
it can be asserted offline with `helm template`.)*

- [ ] **Step 1: `charts/jenkins-support/Chart.yaml`**

```yaml
apiVersion: v2
name: jenkins-support
description: Cluster resources the official Jenkins chart does not provide - the ExternalSecret that feeds JCasC, and the NetworkPolicy that keeps CI away from the app and its database.
type: application
version: 0.1.0
```

- [ ] **Step 2: `charts/jenkins-support/values.yaml`**

```yaml
# All values are supplied by terraform/addon-jenkins.tf. Defaults here exist so `helm template` runs
# offline for scripts/tests/test-jenkins-chart.sh.
awsRegion: il-central-1
secretName: voteball/jenkins
refreshInterval: 1h
appNamespace: devops-app
```

- [ ] **Step 3: `charts/jenkins-support/templates/externalsecret.yaml`**

```yaml
# Mirrors charts/voteball/templates/externalsecret.yaml deliberately -- same ESO version, same
# apiVersion (external-secrets.io/v1; v1beta1 is no longer served by ESO 2.8.0), same explicit
# defaults so a controller does not drift from the rendered manifest.
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secrets
  namespace: {{ .Release.Namespace }}
spec:
  provider:
    aws:
      service: SecretsManager
      region: {{ .Values.awsRegion | quote }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jenkins-secret
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: {{ .Values.refreshInterval | quote }}
  secretStoreRef:
    name: aws-secrets
    kind: SecretStore
  target:
    name: jenkins-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  dataFrom:
    - extract:
        key: {{ .Values.secretName | quote }}
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

- [ ] **Step 4: `charts/jenkins-support/templates/networkpolicy.yaml`**

```yaml
# Egress policy for CI.
#
# Written as BROAD EGRESS WITH SPECIFIC DENIALS, not as an IP allowlist. terraform/jenkins/main.tf
# documented why the EC2 security group allowed all egress: ECR, GitHub and the registries all
# publish wide, shifting ranges, so an allowlist is brittle rather than secure. That reasoning still
# holds. What is enforceable -- and what a reviewer actually checks -- is that CI cannot reach the
# database or the application.
#
# NetworkPolicy cannot express "deny 10.0.x" alongside "allow the internet" directly, so this is
# expressed as: allow all egress EXCEPT the VPC's private ranges, then re-allow DNS and the
# Kubernetes API, which CI genuinely needs.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: jenkins-egress
  namespace: {{ .Release.Namespace }}
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS -- without this every outbound name lookup fails and the symptom looks like no network.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Everything outside the VPC: ECR, GitHub, the Jenkins update site.
    # The three RFC1918 exclusions are what deny RDS and the devops-app pods.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/16     # this VPC: RDS, app pods, everything internal
              - 172.16.0.0/12
              - 192.168.0.0/16
    # The Kubernetes API, so the controller can create agent pods in its own namespace.
    - to:
        - ipBlock:
            cidr: 172.20.0.0/16   # EKS service CIDR
      ports:
        - protocol: TCP
          port: 443
---
# Agents connect to the controller inside this namespace; nothing outside it may reach either.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: jenkins-ingress
  namespace: {{ .Release.Namespace }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}          # same namespace: controller <-> agents
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system   # the ALB target group health checks
```

- [ ] **Step 5: Verify the VPC and service CIDRs above are this cluster's real ones**

```bash
cd terraform
terraform output 2>/dev/null | grep -i vpc
aws eks describe-cluster --name voteball --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text
```
Expected: VPC `10.0.0.0/16` (per CLAUDE.md) and a service CIDR. **If the service CIDR is not
`172.20.0.0/16`, correct the template** — a wrong value here blocks agent creation entirely.

- [ ] **Step 6: Render offline to prove the chart is valid**

```bash
helm lint charts/jenkins-support
helm template jenkins-support charts/jenkins-support --namespace ci | head -40
```
Expected: lint passes; the render shows `SecretStore`, `ExternalSecret` and two `NetworkPolicy`
objects with `namespace: ci`.

- [ ] **Step 7: Commit**

```bash
git add charts/jenkins-support
git commit -m "feat(ci): jenkins-support chart with ExternalSecret and NetworkPolicies

A local chart rather than kubernetes_manifest resources: those need a
reachable cluster at PLAN time, which is exactly what deploy.sh does not
have on a rebuild.

NetworkPolicy is broad-egress-with-denials, not an IP allowlist, for the
same reason the EC2 security group allowed all egress -- registry ranges
shift. The enforceable part is that CI cannot reach RDS or devops-app."
git push origin feat/jenkins-on-eks
```

---

### Task 6: `terraform/addon-jenkins.tf` — namespace, IRSA, ACM, both releases

**Files:**
- Create: `terraform/addon-jenkins.tf`, `scripts/tests/test-jenkins-chart.sh`

**Interfaces:**
- Consumes: ECR repos (Task 1), controller image tag (Task 2 Step 8), the Jenkins secret (Task 4),
  the `jenkins-support` chart (Task 5).
- Produces: a running Jenkins in namespace `ci` with ServiceAccount `jenkins` carrying an ECR-push
  IRSA role. Task 7's Ingress targets the `jenkins` Service on port 8080.

- [ ] **Step 1: Pin the chart version, verified not recalled**

```bash
helm repo add jenkins https://charts.jenkins.io && helm repo update
helm search repo jenkins/jenkins --versions | head -5
```
Record the newest version and today's date; use them in the comment below, replacing `<VERSION>`.

- [ ] **Step 2: Write `terraform/addon-jenkins.tf`**

```hcl
# Jenkins CI, in-cluster. Replaces the retired terraform/jenkins/ EC2 stack.
#
# Design: docs/design/2026-07-30-jenkins-on-eks-design.md
#
# Jenkins is a PLATFORM add-on here, like ArgoCD and ESO, which is why it lives in this stack and is
# installed by helm_release rather than synced by ArgoCD. Consequence: changes reach the cluster by
# `terraform apply`, NOT by committing to master. That differs from charts/voteball on purpose.
#
# NOTE this stack now owns CI, reversing the old "never let the CI server be owned by the stack it
# builds for" rule. That rule protected credentials, job configuration and build history. None of
# those live here any more: credentials are in Secrets Manager, configuration is in git (JCasC), and
# build history is deliberately disposable (design doc section 2).

resource "kubernetes_namespace" "ci" {
  metadata {
    name = "ci"
    labels = {
      # Selectable by the NetworkPolicies in charts/jenkins-support.
      "kubernetes.io/metadata.name" = "ci"
    }
  }
}

# ---- IRSA: ECR push for the AGENTS. The controller gets no AWS role at all. ----
# Narrower than the EC2 instance profile it replaces, which held ECR push AND Secrets Manager read on
# one identity. Secrets Manager access now belongs to ESO alone.
data "aws_iam_policy_document" "jenkins_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:ci:jenkins"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_permissions" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken is account-wide by design
  }
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
      # GetDownloadUrlForLayer is required to IMPORT the BuildKit layer cache and to pull the
      # mirrored Trivy DB. The EC2 instance profile never needed it because that host only pushed.
      "ecr:GetDownloadUrlForLayer",
    ]
    # An ARN PATTERN, not references to the repositories. Lifted from the retired stack, where it
    # removed a cross-stack dependency; here it means the buildcache and trivy-db repos added in
    # Task 1 are already covered with no widening.
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-*"
    ]
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.cluster_name}-jenkins-irsa"
  assume_role_policy = data.aws_iam_policy_document.jenkins_trust.json
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "${var.cluster_name}-jenkins-permissions"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_permissions.json
}

# ---- TLS for the webhook endpoint ----
# Its own certificate, NOT a SAN added to the app's. Keeping them separate means this never touches
# ingress.certificateArn, so scripts/sync-values-from-tf.sh stays at ten managed fields.
resource "aws_acm_certificate" "jenkins" {
  domain_name       = "jenkins.${var.app_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "jenkins_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.jenkins.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "jenkins" {
  certificate_arn         = aws_acm_certificate.jenkins.arn
  validation_record_fqdns = [for r in aws_route53_record.jenkins_cert_validation : r.fqdn]
}

# ---- Supporting cluster resources (ExternalSecret + NetworkPolicies) ----
resource "helm_release" "jenkins_support" {
  name      = "jenkins-support"
  chart     = "${path.module}/../charts/jenkins-support"
  namespace = kubernetes_namespace.ci.metadata[0].name

  set = [
    { name = "awsRegion", value = var.aws_region },
    { name = "secretName", value = aws_secretsmanager_secret.jenkins.name },
  ]

  depends_on = [helm_release.external_secrets]
}

# ---- Jenkins itself ----
resource "helm_release" "jenkins" {
  name       = "jenkins"
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  version    = "<VERSION>" # verified via `helm search repo jenkins/jenkins --versions` on 2026-07-30
  namespace  = kubernetes_namespace.ci.metadata[0].name

  values = [yamlencode({
    controller = {
      image = {
        registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
        repository = "${var.cluster_name}-jenkins"
        tag        = var.jenkins_image_tag
      }
      # The image already contains every plugin. Leaving this on would make a disposable controller
      # refetch them from updates.jenkins.io on every restart -- roughly daily on Spot.
      installPlugins   = false
      overwritePlugins = false

      # The controller must not build. Agents do.
      numExecutors = 0

      resources = {
        requests = { cpu = "250m", memory = "1Gi" }
        limits   = { memory = "2Gi" }
      }

      # JCasC placeholders resolve from these, projected out of the Secret ESO writes.
      containerEnvFrom = [{ secretRef = { name = "jenkins-secret" } }]
      containerEnv = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "CLUSTER_NAME", value = var.cluster_name },
        { name = "GITHUB_REPO", value = var.github_repo },
        { name = "APP_DOMAIN", value = var.app_domain },
      ]

      JCasC = {
        defaultConfig = true
        configScripts = {
          "voteball" = file("${path.module}/../ci/jenkins/jenkins.yaml")
        }
      }

      # The Ingress is defined in Task 7, not here, because it must join the app's ALB group and
      # expose only one path.
      ingress = { enabled = false }

      serviceType = "ClusterIP"
    }

    serviceAccount = {
      name = "jenkins"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.jenkins.arn
      }
    }

    # Namespace-scoped Role only. The chart's default is already namespaced; asserted by
    # scripts/tests/test-jenkins-chart.sh so a future chart bump cannot widen it unnoticed.
    rbac = { create = true, readSecrets = false }

    # JENKINS_HOME is an emptyDir. See design doc section 2: three Spot reclaims in 84 hours, and an
    # EBS volume is AZ-locked, so a PVC would preserve almost nothing while adding the only failure
    # mode needing manual recovery (pod Pending forever, unable to mount).
    persistence = { enabled = false }

    agent = {
      # The pod template lives in the Jenkinsfile (that is "how to build"); this only sets defaults.
      enabled = true
      podName = "jenkins-agent"
    }
  })]

  depends_on = [
    helm_release.jenkins_support,
    aws_acm_certificate_validation.jenkins,
  ]
}
```

- [ ] **Step 3: Add the two variables this file needs**

Append to `terraform/variables.tf`:

```hcl
variable "jenkins_image_tag" {
  description = "Tag of the Jenkins controller image in ECR. Built by ./scripts/build-push-ecr.sh jenkins; bumped by hand when ci/jenkins/ changes, which is rare."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the GitHub repository Jenkins builds. Kept out of code so a fork supplies its own."
  type        = string
}
```

Add both to `terraform/voteball.tfvars` (gitignored), using the tag recorded in Task 2 Step 8:

```hcl
jenkins_image_tag = "<tag from Task 2 Step 8>"
github_repo       = "Latnook/voteball"
```

- [ ] **Step 4: Confirm the two data sources referenced above already exist in this stack**

```bash
grep -rn 'data "aws_caller_identity" "current"\|data "aws_route53_zone" "main"' terraform/*.tf
```
Expected: both found. **If either is missing or named differently, use the existing name** — do not
declare a duplicate, which fails validation.

- [ ] **Step 5: Write the offline chart test**

`scripts/tests/test-jenkins-chart.sh`:

```bash
#!/usr/bin/env bash
# Offline assertions on the rendered Jenkins release. Same pattern as test-sync-values.sh and
# test-ci-guards.sh: the dangerous properties are checked without touching a cluster.
#
# EXTEND THIS whenever the chart version is bumped. Its whole job is to catch a chart default
# quietly widening Jenkins' permissions -- a change that would deploy green and be invisible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template jenkins jenkins/jenkins --namespace ci \
  --set controller.installPlugins=false \
  --set controller.numExecutors=0 \
  --set persistence.enabled=false \
  --set rbac.create=true \
  --set rbac.readSecrets=false > "$rendered"

check "no ClusterRole is created"        "! grep -q '^kind: ClusterRole$' '$rendered'"
check "no ClusterRoleBinding is created" "! grep -q '^kind: ClusterRoleBinding$' '$rendered'"
check "a namespaced Role is created"     "grep -q '^kind: Role$' '$rendered'"
check "no PersistentVolumeClaim"         "! grep -q '^kind: PersistentVolumeClaim$' '$rendered'"
check "pods/exec is grantable"           "grep -q 'pods/exec' '$rendered'"

# The support chart renders offline with no cluster.
helm template jenkins-support "$REPO_ROOT/charts/jenkins-support" --namespace ci > "$rendered"
check "ExternalSecret rendered"  "grep -q 'kind: ExternalSecret' '$rendered'"
check "NetworkPolicy rendered"   "grep -q 'kind: NetworkPolicy' '$rendered'"
check "VPC range is excluded"    "grep -q '10.0.0.0/16' '$rendered'"

exit "$fail"
```

```bash
chmod +x scripts/tests/test-jenkins-chart.sh
```

- [ ] **Step 6: Run the test — it must pass before applying anything**

```bash
./scripts/tests/test-jenkins-chart.sh
```
Expected: every line `ok`, exit 0. **If `pods/exec` is absent from the rendered Role, add it
explicitly** via the chart's RBAC values — both `create` and `get` verbs. Design doc §7 explains why
one verb is not enough: a SPDY exec upgrade is a POST (`create`), a WebSocket upgrade is a GET
(`get`), and EKS 1.36 enables `ExtendWebSocketsToKubelet` by default. Granting only one produces a
403 on the first `sh` step of every build.

- [ ] **Step 7: Format, validate, plan, apply**

```bash
cd terraform
terraform fmt -recursive
terraform validate
terraform plan -var-file=voteball.tfvars
terraform apply -var-file=voteball.tfvars
```

- [ ] **Step 8: Verify Jenkins is running and configured**

```bash
kubectl get pods -n ci
kubectl logs -n ci deploy/jenkins -c jenkins | grep -i "configuration-as-code\|Jenkins is fully up"
kubectl get secret jenkins-secret -n ci -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2
```
Expected: pod `Running`; JCasC applied without error; the Secret carries all five keys. An empty
Secret means ESO cannot read Secrets Manager — re-check Task 4 Step 6.

- [ ] **Step 8b: Add a Jenkins CLI wrapper**

Per the operator's instruction (2026-07-30), operations go through the Jenkins CLI rather than the
UI wherever possible — the UI is not reachable from outside the cluster by design, and CLI commands
are scriptable and reviewable in a way clicking is not.

`scripts/jenkins-cli.sh`:

```bash
#!/usr/bin/env bash
# Run a Jenkins CLI command against the in-cluster controller.
#
#   ./scripts/jenkins-cli.sh who-am-i
#   ./scripts/jenkins-cli.sh list-jobs
#   ./scripts/jenkins-cli.sh build voteball -f -v
#   ./scripts/jenkins-cli.sh reload-jcasc-configuration
#
# Runs INSIDE the controller pod, so no port-forward and no ingress exposure is needed -- the UI is
# deliberately unreachable from the internet (see the design doc section 8).
#
# Auth: the admin user and an API token. JENKINS_ADMIN_USER comes from the same Secret JCasC reads.
# Export JENKINS_API_TOKEN first; mint one with:
#   ./scripts/jenkins-cli.sh --mint-token
set -euo pipefail

NS=ci
POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=jenkins-controller \
        -o jsonpath='{.items[0].metadata.name}')"

if [[ "${1:-}" == "--mint-token" ]]; then
  echo "Open a shell and create a token in the UI via port-forward, or use the Groovy console:" >&2
  echo "  kubectl port-forward -n $NS svc/jenkins 8080:8080" >&2
  exit 0
fi

USER="$(kubectl get secret jenkins-secret -n "$NS" -o jsonpath='{.data.JENKINS_ADMIN_USER}' | base64 -d)"
: "${JENKINS_API_TOKEN:?export JENKINS_API_TOKEN first (see --mint-token)}"

kubectl exec -i -n "$NS" "$POD" -c jenkins -- \
  java -jar /var/jenkins_home/war/WEB-INF/lib/cli-*.jar \
    -s http://localhost:8080/ \
    -auth "$USER:$JENKINS_API_TOKEN" \
    "$@"
```

```bash
chmod +x scripts/jenkins-cli.sh
```

- [ ] **Step 8c: Verify the CLI reaches the controller and JCasC loaded**

```bash
./scripts/jenkins-cli.sh who-am-i
./scripts/jenkins-cli.sh list-jobs
```
Expected: the admin username with `Authenticated`, and `voteball` in the job list. If the CLI jar
path does not match, find it with
`kubectl exec -n ci "$POD" -c jenkins -- sh -c 'ls /var/jenkins_home/war/WEB-INF/lib/cli-*.jar'`
and correct the script.

- [ ] **Step 8d: Confirm the pod template arrived from JCasC**

```bash
./scripts/jenkins-cli.sh groovy = <<'EOF'
def cloud = jenkins.model.Jenkins.instance.clouds.find { it.name == 'kubernetes' }
cloud.templates.each { t -> println "${t.label}  containers=${t.containers*.name}" }
EOF
```
Expected: one line naming label `voteball-build`. **An empty list means the `templates:` block did
not parse** — builds would then hang forever waiting for an agent that is never provisioned, with no
error in the controller log.

- [ ] **Step 9: Prove the permission boundary**

```bash
kubectl auth can-i get pods       -n devops-app --as=system:serviceaccount:ci:jenkins
kubectl auth can-i create pods    -n ci         --as=system:serviceaccount:ci:jenkins
kubectl auth can-i create pods/exec -n ci       --as=system:serviceaccount:ci:jenkins
kubectl auth can-i get    pods/exec -n ci       --as=system:serviceaccount:ci:jenkins
kubectl auth can-i '*' '*' --all-namespaces     --as=system:serviceaccount:ci:jenkins
```
Expected: **no**, yes, yes, yes, **no**. Any other result is a blocking failure.

- [ ] **Step 10: Commit**

```bash
git add terraform/addon-jenkins.tf terraform/variables.tf scripts/tests/test-jenkins-chart.sh
git commit -m "feat(ci): run Jenkins in-cluster from the main Terraform stack

Namespace ci, official chart, JCasC from ci/jenkins/jenkins.yaml,
JENKINS_HOME on emptyDir. IRSA gives the agents ECR push+pull; the
controller holds no AWS role, narrowing the EC2 instance profile that
carried ECR push and Secrets Manager read on one identity.

RBAC is namespace-scoped and asserted offline by
scripts/tests/test-jenkins-chart.sh, so a chart bump cannot widen it
unnoticed. pods/exec carries both create and get: SPDY upgrades are POST
and WebSocket upgrades are GET, and 1.36 turns on
ExtendWebSocketsToKubelet."
git push origin feat/jenkins-on-eks
```

---

### Task 7: Webhook exposure on the shared ALB

**This task causes a brief, deliberate outage of `voteball.latnook.com`. Approved 2026-07-30.**

**Files:**
- Modify: `charts/voteball/templates/ingress.yaml`
- Create: `charts/jenkins-support/templates/ingress.yaml`

**Interfaces:**
- Consumes: the ACM cert and `jenkins` Service (Task 6).
- Produces: `https://jenkins.<app_domain>/github-webhook/` reachable; everything else not.

- [ ] **Step 1: Add the group annotation to the app Ingress**

In `charts/voteball/templates/ingress.yaml`, add alongside the existing annotations:

```yaml
    # Joins one ALB shared with the CI webhook Ingress in the `ci` namespace. A second ALB would be
    # ~$18/mo and would make the Jenkins migration cost more than it saves.
    #
    # ADDING THIS REPLACES THE ALB: the controller moves this Ingress out of its implicit
    # per-Ingress group into the named one, provisioning a new load balancer and repointing DNS.
    # The site is unreachable for roughly 2-5 minutes. Do not apply this casually.
    alb.ingress.kubernetes.io/group.name: voteball
    alb.ingress.kubernetes.io/group.order: "10"
```

- [ ] **Step 2: Add the Jenkins Ingress to the support chart**

`charts/jenkins-support/templates/ingress.yaml`:

```yaml
# ONLY the webhook path is routed. The UI, script console and credential store are not reachable
# from the internet at all -- the ALB has no rule that reaches them.
#
# This is a deliberate tightening over the EC2 host, whose security group exposed the ENTIRE Jenkins
# UI to GitHub's CIDR ranges over plaintext HTTP (terraform/jenkins/main.tf:41-47 recorded that as
# accepted residual risk). Operators reach the UI with:
#   kubectl port-forward -n ci svc/jenkins 8080:8080
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins-webhook
  namespace: {{ .Release.Namespace }}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/certificate-arn: {{ .Values.certificateArn | quote }}
    alb.ingress.kubernetes.io/healthcheck-path: /login
    alb.ingress.kubernetes.io/group.name: voteball
    alb.ingress.kubernetes.io/group.order: "20"
spec:
  ingressClassName: alb
  rules:
    - host: {{ .Values.host | quote }}
      http:
        paths:
          - path: /github-webhook
            pathType: Prefix
            backend:
              service:
                name: jenkins
                port:
                  number: 8080
```

Add `certificateArn: ""` and `host: ""` to `charts/jenkins-support/values.yaml`, and pass both from
`helm_release.jenkins_support` in `terraform/addon-jenkins.tf`:

```hcl
    { name = "certificateArn", value = aws_acm_certificate_validation.jenkins.certificate_arn },
    { name = "host", value = "jenkins.${var.app_domain}" },
```

- [ ] **Step 3: Render both charts offline before touching the cluster**

```bash
helm template voteball charts/voteball | grep -A3 'group.name'
helm template jenkins-support charts/jenkins-support --namespace ci \
  --set certificateArn=arn:aws:acm:test --set host=jenkins.example.com | grep -A5 'kind: Ingress'
```
Expected: both carry `group.name: voteball`, with orders 10 and 20.

- [ ] **Step 4: Apply Terraform (Jenkins Ingress), then commit the app chart for ArgoCD**

```bash
cd terraform && terraform apply -var-file=voteball.tfvars
```

Then — **this is the outage window** — commit the app chart change so ArgoCD syncs it:

```bash
git add charts/voteball/templates/ingress.yaml charts/jenkins-support
git commit -m "feat(ingress): share one ALB between the app and the CI webhook

Adding group.name replaces the ALB, so voteball.latnook.com is
unreachable for 2-5 minutes on sync. Approved 2026-07-30: a second ALB
would be ~\$18/mo and would make the Jenkins migration cost more than it
saves.

The Jenkins Ingress routes ONLY /github-webhook. The UI is not exposed
at all, replacing the EC2 host's accepted risk of serving the entire UI
to GitHub's CIDRs over plaintext HTTP."
git push origin feat/jenkins-on-eks
```

- [ ] **Step 5: Watch the ALB swap and DNS settle**

```bash
kubectl get ingress -A -w
```
Wait until both Ingresses report the **same** ALB hostname. Then:

```bash
dig +short voteball.latnook.com
dig +short jenkins.latnook.com
curl -sS -o /dev/null -w '%{http_code}\n' https://voteball.latnook.com/
```
Expected: both names resolve to the same ALB; the site returns `200`.

- [ ] **Step 6: Prove the UI is NOT exposed**

```bash
curl -sS -o /dev/null -w 'root=%{http_code}\n'    https://jenkins.latnook.com/
curl -sS -o /dev/null -w 'webhook=%{http_code}\n' https://jenkins.latnook.com/github-webhook/
```
Expected: root `404` (no ALB rule reaches it); webhook a Jenkins response (`200`/`405`/`403`), **not**
`404`. A `200` on root is a blocking failure — the path restriction is not working.

---

### Task 8: Rewrite the `Jenkinsfile` for pod agents

**Files:**
- Modify: `Jenkinsfile` (agent declaration, `environment`, three stages, `post`)

**Interfaces:**
- Consumes: everything above.
- Produces: a pipeline whose four unchanged stages (Guard, Resolve, Already built?, Bump image tag)
  behave identically.

- [ ] **Step 0: Stop the old EC2 Jenkins FIRST — operator action**

```bash
cd terraform/jenkins && aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"
```

The old host cannot run the rewritten pipeline: `agent { label 'voteball-build' }` names a pod
template that exists only in the new controller, so a build there **hangs waiting for an executor
that never appears** rather than failing. The `[skip ci]` marker on this task's commit protects that
one commit; it does not protect any other push to `services/` landing in the same window. Stopping
the host removes the window entirely. **Do not destroy it** — it is the rollback until Task 10.

- [ ] **Step 1: Replace `agent any` with the JCasC-provided label**

```groovy
  // The pod that provides these containers is declared in ci/jenkins/jenkins.yaml, under the
  // kubernetes cloud's `templates:` block -- NOT here. The CI environment is configuration and
  // belongs in JCasC; the Jenkinsfile owns build steps. Changing which containers exist, or their
  // versions, means editing that file and re-applying Terraform.
  agent { label 'voteball-build' }
```

**Do not** inline a `kubernetes { yaml ... }` block here. Two sources of truth for the agent pod is
exactly what the JCasC decision avoids, and an inline block silently overrides the template.

- [ ] **Step 2: Replace the `environment` block**

```groovy
  environment {
    // AWS_REGION and CLUSTER_NAME remain Jenkins global environment variables -- see JCasC.
    TRIVY_IMAGE = 'aquasec/trivy:0.58.1'
    // TRIVY_CACHE is GONE. Do not reintroduce it as an emptyDir: that converts a cross-build cache
    // into a per-build one and re-downloads the ~100MB database on each of four scans, every build.
    // The DB is mirrored into ECR instead; see scripts/mirror-trivy-db.sh.
  }
```

- [ ] **Step 3: Rewrite `Build images`**

```groovy
    stage('Build images') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }   // G3
      } }
      steps {
        container('buildkit') {
          sh '''
            set -eu
            CACHE="$ECR_REGISTRY/$CLUSTER_NAME-buildcache"
            for svc in backend worker nginx backup; do
              case "$svc" in
                nginx) ctx=services/frontend ;;
                *)     ctx=services/$svc ;;
              esac
              buildctl-daemonless.sh build \
                --frontend dockerfile.v0 \
                --local context="$ctx" --local dockerfile="$ctx" \
                --output type=oci,dest=/images/$svc.tar,name="$ECR_REGISTRY/$CLUSTER_NAME-$svc:$TAG" \
                --import-cache type=registry,ref="$CACHE:$svc" \
                --export-cache type=registry,ref="$CACHE:$svc",mode=max
            done
          '''
        }
      }
    }
```

> **Note the `nginx`/`frontend` asymmetry** — the ECR repo is `nginx` but the build context is
> `services/frontend`. The old pipeline hardcoded this per line; the loop must preserve it.

- [ ] **Step 4: Rewrite `Trivy scan`**

```groovy
    stage('Trivy scan') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        container('trivy') {
          sh '''
            set -eu
            DB="$ECR_REGISTRY/$CLUSTER_NAME-trivy-db"
            for svc in backend worker nginx; do
              echo "--- trivy $CLUSTER_NAME-$svc (blocking) ---"
              trivy image --db-repository "$DB" --input /images/$svc.tar \
                --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed
            done

            # The backup image is a third-party base (postgres:17-alpine + aws-cli) whose CVEs are
            # upstream Go-tooling issues outside this project's control: surface, do not block.
            echo "--- trivy $CLUSTER_NAME-backup (report only) ---"
            trivy image --db-repository "$DB" --input /images/backup.tar \
              --severity CRITICAL,HIGH --exit-code 0 --ignore-unfixed
          '''
        }
      }
    }
```

- [ ] **Step 5: Rewrite `Push to ECR`**

```groovy
    stage('Push to ECR') {
      when { allOf {
        expression { env.ALREADY_BUILT != 'present' }
        anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } }
      } }
      steps {
        container('skopeo') {
          // skopeo copies the EXACT file Trivy scanned. Nothing is rebuilt between scan and push,
          // so the scanned artifact and the pushed artifact are provably the same bytes -- a
          // stronger guarantee than the docker build/scan/push flow this replaces.
          sh '''
            set -eu
            PW="$(aws ecr get-login-password --region "$AWS_REGION")"
            for svc in backend worker nginx backup; do
              skopeo copy --dest-creds "AWS:$PW" \
                oci-archive:/images/$svc.tar \
                docker://"$ECR_REGISTRY/$CLUSTER_NAME-$svc:$TAG"
            done
          '''
        }
      }
    }
```

> If the `skopeo` image lacks the AWS CLI, obtain the password in the `awscli` container and pass it
> between stages via a file under `/images`, which both containers mount.

- [ ] **Step 6: Delete the `post { always }` Docker prune**

```groovy
  post {
    // G5's `docker image prune` is DELETED, not ported: it existed because the EC2 host was
    // persistent. A pod agent is destroyed after every build, so the disk cleans itself.
    failure {
      // G7 -- there is no email. This line is the record; check the UI.
      echo 'BUILD FAILED. No notification is sent (see docs/cicd.md, G7).'
    }
  }
```

- [ ] **Step 7: Confirm the four untouched stages are byte-identical**

```bash
git diff Jenkinsfile | grep -E '^[-+].*(should-skip-build|images-exist|rev-parse|sshagent|git push)'
```
Expected: **no output.** Any hit means a stage that must not change, changed. In particular the Guard
stage and `scripts/ci/` must be untouched — Global Constraints.

- [ ] **Step 8: Re-run the guard tests**

```bash
./scripts/tests/test-ci-guards.sh
```
Expected: all pass (offline; they never needed a cluster).

- [ ] **Step 9: Commit**

```bash
git add Jenkinsfile
git commit -m "refactor(ci): build in pod agents with BuildKit, Trivy and skopeo [skip ci]

Four stages change mechanism, four are untouched. docker build ->
buildctl exporting an OCI tarball; docker run + socket mounts -> trivy
--input on that tarball; docker push -> skopeo copy of the same file.
The post-block docker prune is deleted, not ported: it existed because
the EC2 host was persistent.

Scanning the tarball and pushing that same file makes the scanned and
pushed artifacts provably identical, which the build/scan/push flow only
assumed.

Guard, Resolve, Already built? and Bump image tag are unchanged, and
scripts/ci/ is untouched."
git push origin feat/jenkins-on-eks
```

> **The `[skip ci]` marker above is deliberate and required:** the old EC2 Jenkins is still live at
> this point and would otherwise try to build this commit with a pipeline it cannot run.

---

### Task 9: Cutover and verification

**Files:** none — this is operational.

- [ ] **Step 1: Repoint the GitHub webhook**

In GitHub → repo Settings → Webhooks, change the payload URL to
`https://jenkins.<app_domain>/github-webhook/`. Keep the existing secret, content type
`application/json`, and **SSL verification enabled** (now possible — the old endpoint was plaintext).

- [ ] **Step 2: Trigger a real build**

Make a trivial change under `services/` (a comment), commit and push. Watch:

```bash
kubectl get pods -n ci -w
```
Expected: an agent pod appears, runs, and is deleted.

- [ ] **Step 3: Verify the full chain — via the CLI, not the UI**

```bash
./scripts/jenkins-cli.sh console voteball          # last build's full log
./scripts/jenkins-cli.sh list-builds voteball      # numbers, results, timings
git log --oneline -3 origin/master
```
Expected: guard → resolve → build → Trivy → push → tag bump, and a new
`ci: image tag <sha> [skip ci]` commit on `master`. Then confirm ArgoCD picked it up:

```bash
kubectl get application -n argocd voteball -o jsonpath='{.status.sync.status}{"\n"}'
kubectl get pods -n devops-app
```
Expected: `Synced`, and pods running the new tag.

- [ ] **Step 4: Prove the loop guard still works (G2)**

The tag-bump commit in Step 3 fires the webhook. Confirm via the CLI:

```bash
./scripts/jenkins-cli.sh list-builds voteball | head -3
```
Expected: the newest build is **`NOT_BUILT`**, and `console` shows description
`Skipped: tag-bump commit ([skip ci])`. **If it built, stop everything** — that is the unbounded
billable loop the Guard exists to prevent.

- [ ] **Step 5: Prove the cache works**

Re-run the same build with `FORCE_BUILD`. Compare durations.
Expected: materially faster, with `CACHED` lines in the BuildKit output and no Trivy DB download.
**A second build as slow as the first means §5a is not working, regardless of whether it went green.**

- [ ] **Step 6: Prove the network boundary from inside an agent**

```bash
kubectl run netcheck -n ci --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'nc -z -w3 $(getent hosts <rds-endpoint> | cut -d" " -f1) 5432; echo "rds=$?"; nc -z -w3 github.com 443; echo "github=$?"'
```
Expected: `rds=1` (blocked), `github=0` (reachable).

- [ ] **Step 7: Prove the controller is disposable**

```bash
kubectl delete pod -n ci -l app.kubernetes.io/component=jenkins-controller
kubectl get pods -n ci -w
```
Expected: back `Running` within ~60s, JCasC reapplied, the `voteball` job present, **no plugin
downloads** in the log. Confirm with `kubectl logs -n ci deploy/jenkins | grep -ci "Downloading"` →
`0`.

- [ ] **Step 8: Confirm the old EC2 host is still stopped, not destroyed**

It was stopped in Task 8 Step 0. Confirm it is intact and remains the rollback:

```bash
cd terraform/jenkins
aws ec2 describe-instances --instance-ids "$(terraform output -raw instance_id)" \
  --query 'Reservations[].Instances[].State.Name' --output text
```
Expected: `stopped`. **Do not destroy it yet** — leave it for at least one working week of green
builds before Task 10.

---

### Task 10: Retire the EC2 stack and reconcile the docs

**Do not start until Task 9 has been green for a week.**

**Files:**
- Delete: `terraform/jenkins/`, this plan
- Modify: `CLAUDE.md`, `docs/cicd.md`, `docs/security.md`, `docs/deploy.md`,
  `docs/eks/architecture.md`, `README.submission.md`, `.gitignore`,
  `scripts/bootstrap-tf-backend.sh`

- [ ] **Step 1: Confirm the secret is NOT in the old stack's state**

```bash
cd terraform/jenkins
terraform state list | grep -i secret
```
Expected: **no output.** If anything appears, Task 4 Step 2 did not take — re-run it, or the destroy
below deletes the deploy key.

- [ ] **Step 2: Destroy the EC2 stack**

```bash
terraform destroy -var-file=jenkins.tfvars
```

- [ ] **Step 3: Delete the orphaned EBS volume**

`delete_on_termination = false` means the root volume **survives** the destroy and bills forever.

```bash
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table
aws ec2 delete-volume --volume-id <the jenkins volume>
```

- [ ] **Step 4: Remove the stack's Terraform state object**

```bash
aws s3 rm "s3://$(terraform output -raw state_bucket 2>/dev/null || echo voteball-tfstate-<account>)/voteball/jenkins.tfstate"
```
(The bucket belongs to no stack and must never be destroyed — only this one key is removed.)

- [ ] **Step 5: Delete the directory and its gitignore entries**

```bash
cd ../..
git rm -r terraform/jenkins
```
Remove the `terraform/jenkins/*` entries from `.gitignore`, keeping each remaining rule's comment
intact. Update `scripts/bootstrap-tf-backend.sh` to generate one `backend.hcl`, not two.

- [ ] **Step 6: Remove the six now-false `CLAUDE.md` rules**

Delete outright: the "separate stack, never add to destroy.sh" rule; "The Jenkins host's AMI foot-gun
is DISARMED"; "The GitHub plugin is configured by XML, not JCasC" (with its two-files, SHA-256 and
`hookSecretConfigs` detail); "Stop the instance to save money"; the
`cd terraform/jenkins` command block. Rewrite "configured by JCasC, not by clicking" for the new
mechanism, and the state section for one key.

**Keep verbatim:** "Do not remove the Guard stage from the `Jenkinsfile`, or
`scripts/ci/should-skip-build.sh`."

Add, in Deployment:

```markdown
**CI/CD is Jenkins, running in the cluster** (namespace `ci`), installed by Terraform
(`terraform/addon-jenkins.tf`) from the official chart and configured entirely by
`ci/jenkins/jenkins.yaml`. **Changes to Jenkins reach the cluster by `terraform apply`, not by
committing to `master`** — the opposite of `charts/voteball`, which ArgoCD syncs.

The controller is **disposable**: `JENKINS_HOME` is an `emptyDir` and build history resets on every
Spot reclaim (~daily) and every teardown. That is deliberate — the deploy record is the
`ci: image tag <sha>` commits on `master`, not Jenkins. **Do not "fix" this by adding a PVC:** an EBS
volume is AZ-locked, so at this reclaim rate it preserves almost nothing while introducing a pod that
hangs `Pending` forever when its AZ has no node.

**Both build caches live in ECR, and their repositories must stay `MUTABLE` and outside
`local.ecr_repos`.** Cache tags are rewritten every build; the app repos are `IMMUTABLE` because
git-SHA tags must not be. Moving them into that set fails every build's cache export.

**There is no CI while the cluster is destroyed.** `scripts/build-push-ecr.sh` is the manual
fallback and must be kept working.
```

- [ ] **Step 7: Rewrite `docs/cicd.md`**

Update the flow, the first-time setup runbook (`kubectl port-forward` instead of the SSH tunnel), and
the failure modes. **Delete** failure modes about the webhook XML and `hookSecretConfigs` — they no
longer exist. **Keep** failure mode 1 (SSH remote URL for `sshagent`) — still live. Add: stale Trivy
DB, cache-export failure on an immutable repo, and `pods/exec` 403.

- [ ] **Step 8: Update the remaining docs**

- `docs/security.md` — **remove** the accepted "entire UI exposed over plaintext HTTP" risk; replace
  with the webhook-only, HTTPS posture and the NetworkPolicy denials.
- `terraform/secrets.tf` — soften the deploy-key comment inherited in Task 4. It claims the key
  "cannot be recovered from anywhere", which predates `scripts/seed-jenkins-secret.sh` and overstates
  the case: the script mints a replacement and prints the public half to paste into GitHub. State it
  accurately — losing it is an outage to repair by hand, not data destroyed — so nobody treats a
  routine teardown as more dangerous than it is.
- `docs/deploy.md` — Jenkins seeding in the deploy sequence; no EC2 host to start.
- `docs/eks/architecture.md`, `README.submission.md` — the `ci` namespace in the diagram and text.

- [ ] **Step 9: Check the doc claims that drift**

```bash
grep -rn 'terraform/jenkins' --include='*.md' . | grep -v docs/design/
grep -rn '\$37\|\$6/mo\|instance_id' --include='*.md' . | grep -v docs/design/
grep -c 'managed' scripts/sync-values-from-tf.sh
```
Expected: no live references outside `docs/design/` (design docs are dated evidence and must **not**
be "corrected"); no stale cost figures; the sync-managed field count still **ten**.

- [ ] **Step 10: Record the verification outcome in the design doc**

Append a `## Verification outcome` section to
`docs/design/2026-07-30-jenkins-on-eks-design.md` recording what actually broke, matching the
convention several other design docs follow. This is the durable record — the plan is not.

- [ ] **Step 11: Delete this plan and commit everything together**

```bash
git rm docs/superpowers/plans/2026-07-30-jenkins-on-eks.md
rmdir -p docs/superpowers/plans docs/superpowers 2>/dev/null || true
git add -A
git commit -m "chore(ci): retire the Jenkins EC2 stack

terraform/jenkins/ destroyed and deleted, its orphaned root volume
removed (delete_on_termination=false meant it outlived the instance),
and its tfstate key dropped. The state bucket is untouched.

Removes the six CLAUDE.md rules the move makes false -- the separate-stack
rule, the AMI foot-gun, the GitHub-plugin XML workaround, the
stop-do-not-destroy note -- rather than leaving them to contradict the
code. The Guard-stage rule is kept verbatim.

Records the verification outcome in the design doc and deletes the
implementation plan, per the workflow rule."
git push origin feat/jenkins-on-eks
```

---

## Self-Review

**Spec coverage.** Every design section maps to a task: §1 Where Jenkins runs → T6; §2 disposable
controller → T6 (`persistence.enabled: false`) + T9 S7; §3 custom image → T2; §4 plugin set → T2 S2;
§5 BuildKit → T8; §5a caching → T1, T3, T8; §6 Jenkinsfile → T8; §7 identity and RBAC → T6 (+T6 S9
proving the `pods/exec` verbs); §8 network exposure → T7; §9 secrets → T4, T5; §10 cost → no task
(informational); §11 cutover → T9, T10; §12 repository changes → T10.

**Two things the design doc did not surface, added here:** the Secrets Manager state migration
(T4 — a naive move destroys the deploy key, and `recovery_window_in_days = 7` wedges the next rebuild)
and ESO's single-ARN scope (T4 S6). Both were found while reading the existing Terraform.

**Placeholders.** One deliberate `<VERSION>` in T6, immediately preceded by the command that resolves
it — required by the Global Constraint against pinning a recalled chart version. `<tag from Task 2
Step 8>`, `<the jenkins volume>` and `<rds-endpoint>` are values that only exist at run time, each
with the command that produces it adjacent.

**Type consistency.** Names used identically across tasks: ECR repos `voteball-jenkins`,
`voteball-buildcache`, `voteball-trivy-db`; namespace `ci`; ServiceAccount `jenkins`; Kubernetes
Secret `jenkins-secret`; chart `charts/jenkins-support`; the four service loop
`backend worker nginx backup` with `nginx` built from `services/frontend` in both T8 S3 and the
existing pipeline.
