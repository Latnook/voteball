# CI/CD pipeline

How a code change becomes a running pod, with no manual deploy step.

CI is **Jenkins, running inside the EKS cluster** (namespace `ci`), installed by Terraform
(`terraform/addon-jenkins.tf`) as a `helm_release` of the official `jenkins/jenkins` chart, and
configured entirely by JCasC (`ci/jenkins/jenkins.yaml`). It replaced a GitHub Actions pipeline on
2026-07-20, then a dedicated EC2 host on 2026-07-30/31 — the reasoning for the pipeline's *logic* is in
[`docs/design/2026-07-20-jenkins-migration-design.md`](design/2026-07-20-jenkins-migration-design.md)
(gotcha labels **G1–G7**, referenced throughout below and still current); the reasoning for *running it
in the cluster instead of on EC2* is in
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md), whose
"Verification outcome" section records what the move actually broke versus what the design predicted.

The pipeline was verified end-to-end on 2026-07-20 against the live cluster, JCasC self-configuration
was verified on 2026-07-21 (a genuinely fresh EC2 instance), and the in-cluster move was verified
end-to-end on 2026-07-30/31: a push builds, scans, pushes four images and commits a tag bump, ArgoCD
deploys it, and the tag-bump commit is correctly refused by the Guard stage.

---

## The short version

```
git push (services/**)  →  webhook  →  Jenkins (pod agent)  →  ECR  →  values.yaml bump  →  ArgoCD  →  pods roll
        you                            build → scan → push        commit                       rolling update
```

Nobody runs `kubectl` or `helm`. **Jenkins does not deploy** — it stops at "push images, commit the new
tag". ArgoCD notices the commit and rolls the Deployments. That split is deliberate: it means Jenkins
holds **no cluster-deploy credentials at all**, for a sharper reason than before it moved in-cluster —
it is now physically *inside* the cluster it must still be unable to change.

**Jenkins is a platform add-on, not the application.** Changes to the Jenkins release (the Helm values
in `terraform/addon-jenkins.tf`, or JCasC in `ci/jenkins/jenkins.yaml`) reach the cluster by
`terraform apply`, exactly like ArgoCD, External Secrets Operator or external-dns — **not** by
committing to `master`. This is the opposite of `charts/voteball`, which ArgoCD syncs from git.
Committing a JCasC change and walking away changes nothing until someone runs `terraform apply`.

---

## The pipeline, step by step

The pipeline lives in [`Jenkinsfile`](../Jenkinsfile) at the repository root, and the Jenkins job is
defined by Job DSL inside `ci/jenkins/jenkins.yaml` as *Pipeline script from SCM* — so the build
definition is in the repository and reviewable, not hidden in Jenkins' database. What changed in the
move: **the pod agent template is now also in JCasC**, under the Kubernetes cloud's `templates:` block,
not the `Jenkinsfile`. The `Jenkinsfile` says `agent { label 'voteball-build' }` and nothing about which
containers exist — that split follows the 2026-07-20 design's own rule ("everything about HOW to build
lives in the Jenkinsfile ... this block only says where to find it and when to run it"), applied to the
one new thing JCasC now owns: *what a build agent is made of*.

### 1. Trigger — GitHub webhook

A push to `master` sends a webhook to `https://jenkins.<app_domain>/github-webhook/`. Jenkins verifies
the HMAC signature GitHub attaches using a shared secret, so a random request cannot start builds.

Only app-source changes rebuild images: the build/scan/push stages carry
`when { anyOf { changeset 'services/**'; expression { params.FORCE_BUILD } } }` (**G3**). Editing
`README.md`, `terraform/` or `docs/` triggers the job but builds nothing.

> **Non-obvious:** the filter is a path match, not a "was this app code?" judgement. A docs-only commit
> that also touches `services/backend/schema.sql` (e.g. fixing a comment) *will* trigger a full build.
> That is correct — the file is baked into the backend image — but it surprises people.

`FORCE_BUILD` is a checkbox on "Build with Parameters". It exists because a **manually** triggered build
has an empty changeset and would otherwise skip every stage, making "Build Now" a silent no-op.

> **Do not trigger a build immediately after pushing, and then read the result as yours.** The push
> fires the webhook, so a queue item already exists — and `disableConcurrentBuilds()` makes Jenkins
> **coalesce queue items for the same job**. The webhook's item carries DEFAULT parameters, so it
> absorbs your parameterised request and the build records `FORCE_BUILD=false`.
>
> Nothing is broken when this happens; you are looking at a different build than the one you asked
> for. On 2026-07-31 this cost an hour of chasing a non-existent API bug. Check `build.xml`'s cause
> before concluding anything: `GitHubPushCause` is the webhook's, `UserIdCause` is yours. If you want
> a parameterised build, either wait for the webhook's build to finish or trigger on a commit you did
> not just push.

**Behaviour change from the EC2 host:** webhooks used to be silently discarded while the host was
stopped, so a push only built if someone had started the machine first. In the cluster Jenkins is
always running, so **every push to `master` touching `services/` now builds.** That is correct CI
behaviour, called out because it differs from the old status quo.

### 2. Guard — is this our own commit? (G2)

**This stage is load-bearing and must never be removed.** The last stage of the pipeline commits the
bumped image tag back to `master`. `[skip ci]` is a *GitHub Actions* convention; **Jenkins has never
heard of it**. Without the guard, the webhook fires on Jenkins' own commit, Jenkins builds it, bumps the
tag, commits again — an unbounded build loop that burns money and continuously rolls production pods.

So the first stage reads the head commit message and, if `scripts/ci/should-skip-build.sh` says `skip`,
sets `currentBuild.result = 'NOT_BUILT'` and aborts. It runs unconditionally and first, so a `[skip ci]`
commit cannot be built even manually with `FORCE_BUILD` ticked.

It is a visible stage rather than a plugin setting precisely so that removing it is an obvious edit in a
reviewed file, not an invisible configuration change.

### 3. Authenticate to AWS — IRSA on the agent, nothing on the controller

There is no Docker daemon and no `docker` CLI in a pod agent at all — EKS nodes run `containerd`. Builds
use rootless BuildKit instead (§5).

AWS identity is **IRSA**, and it is split narrower than the single EC2 instance profile it replaces:

| Component | AWS role |
|---|---|
| Jenkins controller | **none** |
| Jenkins agent pods (`jenkins-agent` ServiceAccount) | ECR push/pull only, ARN pattern `repository/<cluster_name>-*` |
| Secrets Manager read | ESO's own role, not Jenkins' — Jenkins never reads Secrets Manager directly |

The role can push/pull `repository/<cluster_name>-*` and call `ecr:GetAuthorizationToken`, and
**nothing else** — no EKS, RDS, S3, SNS. `GetDownloadUrlForLayer` is included (the EC2 profile never
needed it, because that host only ever pushed) — the agent now also *imports* the BuildKit layer cache
and *pulls* the mirrored Trivy database from ECR, both new in this design (§5a).

Every `aws` CLI call must run inside `container('awscli')` — steps outside a `container()` block run in
the `jnlp` container, which has git but no AWS CLI. Forgetting this is `aws: not found`, exit 127 (see
Failure modes).

### 4. Already built? (G1)

ECR repositories are created with `image_tag_mutability = "IMMUTABLE"`, and images are tagged with the
short git SHA. Re-running a build for the same commit would therefore try to push a tag that already
exists, and ECR rejects it — a red build caused by nothing being wrong. "Build Now" and replaying a
build to debug a later stage are routine in Jenkins.

`scripts/ci/images-exist.sh` asks ECR whether all four images for this SHA already exist. If they do,
build/scan/push are skipped and the pipeline goes straight to the tag bump, saying why. The skip only
happens on a **positive** answer — a lookup failure builds normally, so the worst case is a redundant
build, never a green build that silently ships nothing.

### 5. Build, scan, push — rootless BuildKit, no Docker daemon

Four images (`backend`, `worker`, `nginx`, `backup`) are built and tagged with the short git SHA — never
`latest`, so every deployed pod maps to an exact commit.

**Build.** The `buildkit` container in the agent pod runs `moby/buildkit:v0.19.0-rootless` as uid 1000.
`buildctl build --output type=docker,dest=/images/<svc>.tar` writes a `docker-archive` tarball to a
shared `emptyDir`. **`type=docker`, not `type=oci`** — both write a tar, but `type=oci` writes an OCI
*archive* (`index.json` + `blobs/`), and Trivy's `--input` reads a `docker-archive` or an OCI
*directory*, not an OCI archive; with `type=oci` the build succeeds and Trivy then fails with
`manifest.json not found in tar`, which reads like a corrupt image rather than the wrong export type.

**Docker-in-Docker and Kaniko were both rejected** — DinD needs `privileged: true`, which contradicts
every other container security setting in this project; Kaniko was archived upstream by Google on
2025-06-03. Rootless BuildKit is uid 1000, not privileged, still maintained, and the documented Kaniko
migration target. See the design doc §5 for the full comparison. **`buildkit` is the one container in
the whole project that sets `allowPrivilegeEscalation: true` plus `capabilities.add: [SETUID, SETGID]`**
— creating a user namespace for rootless building needs `newuidmap`, a SETUID binary; without the
exception `rootlesskit` dies instantly and the build hangs on "still waiting to schedule" forever with
nothing logged. It is still uid 1000, no host devices, no host paths — do not "make it consistent" with
the rest of the project; the exception is scoped to one CI container in a namespace whose NetworkPolicy
already denies it any route to RDS or `devops-app`.

**Scan.** `trivy image --db-repository <ECR>/<cluster_name>-trivy-db --input /images/<svc>.tar` runs in
its own container. `backend`, `worker`, `nginx` **block** on fixable `CRITICAL`/`HIGH` findings; `backup`
(third-party `postgres:17-alpine` + aws-cli, upstream CVEs outside this project's control) is
report-only.

**Push.** `skopeo copy docker-archive:/images/<svc>.tar docker://<ECR>/<cluster_name>-<svc>:<tag>` — the
**exact same file** Trivy just scanned, so the scanned artifact and the pushed artifact are provably the
same bytes. This is a strictly stronger guarantee than the old `docker build` → `docker run` (scan) →
`docker push` flow, which quietly assumed the scanned and pushed images were identical without proving
it. **No *deployable, tagged* image reaches ECR before the scan passes** — the Build stage's
`--export-cache` does push unscanned layer-cache blobs to the `buildcache` repository ahead of the scan,
but that repository is not one the app ever deploys from.

**5a. Build caching — the one thing that would otherwise have regressed.** The EC2 host was persistent
and kept a warm Docker layer cache and Trivy database between builds; a pod agent starts cold every
time. Both caches now live in ECR instead of on any volume:

- **Layer cache:** `--import-cache`/`--export-cache type=registry,ref=<ECR>/<cluster_name>-buildcache:<svc>`.
  That repository **must stay `MUTABLE` and outside `local.ecr_repos`** in `terraform/ecr.tf` — cache
  tags are rewritten on every build by design, and the app-image set is `IMMUTABLE` on purpose.
  `image-manifest=true,oci-mediatypes=true` is required on the export: BuildKit's default cache manifest
  is an OCI image *index*, which ECR rejects with a bare `400 Bad Request` on the manifest PUT — after
  the whole image has already built and every layer uploaded, so it reads like a transient registry
  fault.
- **Trivy database:** `--db-repository <ECR>/<cluster_name>-trivy-db`, mirrored from upstream by
  `scripts/mirror-trivy-db.sh`. A pod volume could not do this job — it dies with the build, so it would
  re-download the ~100 MB database on each of four scans, every build, reintroducing the exact
  ghcr.io rate-limit risk the original host-mount existed to avoid.

### 6. Bump the tag and commit back (G4)

```bash
sed -i -E "s/^  tag: \".*\"/  tag: \"$TAG\"/" charts/voteball/values.yaml
git commit -m "ci: image tag $TAG [skip ci]"
git pull --rebase --autostash origin master
git push origin HEAD:master
```

Jenkins has no ambient git identity, so this uses a **GitHub deploy key with write access**, held in
Secrets Manager (`voteball/jenkins`) and injected via JCasC as an `sshagent`-usable credential. A deploy
key is preferred over a personal access token because it is scoped to exactly one repository.

**The job's SCM URL must be the SSH remote** (`git@github.com:<owner>/<repo>.git`), not HTTPS —
`sshagent` only affects SSH remotes; with HTTPS the deploy key is silently ignored and this stage fails
or hangs on a credential prompt. Still failure mode 1 below, unchanged by the move.

**Raw `git` needs its own `known_hosts`, separately from the git *plugin*'s checkout.** The JCasC
`security.gitHostKeyVerificationConfiguration` block pins GitHub's host key for the git **plugin**'s
checkout at the start of the build; this stage shells out to plain `git push` in the `jnlp` container,
which has no `known_hosts` of its own and fails late with `Host key verification failed` — after the
image has already been built, scanned and pushed. The fix (already applied) writes the same pinned key
into `~/.ssh/known_hosts` inside this stage before pushing.

`[skip ci]` is still written into the message — for continuity, readability, and so the repository stays
portable — but in Jenkins it is the **Guard stage**, not the marker, that does the work.

### 7. ArgoCD syncs

The `voteball` Application watches `charts/voteball` on `master` with `automated: {prune, selfHeal}`. It
picks up the new tag unprompted and Kubernetes performs a rolling update across all three Deployments.

### 8. Cleanup

`buildDiscarder` (last 20 builds) is unchanged. **`docker image prune` is gone, not ported** — it existed
because the EC2 host was persistent; a pod agent is destroyed after every build, so the disk cleans
itself. `post { always }` now only removes a live ECR login token written to the shared `/images`
volume during the Build stage, so a failed build does not leave it sitting there for the rest of the
pod's life.

---

## First-time setup runbook

Originally done once, through Terraform and the Jenkins UI.

**1. Seed the Jenkins secret, once per account, before first apply.**

```bash
./scripts/seed-jenkins-secret.sh
```

Prints a deploy public key to add to GitHub (with write access) and the webhook secret.

> **"Once per account" does not survive a teardown — steps 1 and 4 both repeat after every
> destroy/rebuild.** `terraform/secrets.tf` sets `recovery_window_in_days = 0`, so `voteball/jenkins`
> is *hard-deleted* on destroy (deliberately — a 7-day recovery window would block recreating a secret
> of the same name for a week). With nothing left to preserve, this script mints a **fresh deploy key
> and a fresh webhook secret**, and GitHub still holds the old ones. Until both are re-registered the
> webhook is rejected and the pipeline's final `git push` is denied — a cluster that looks entirely
> healthy with a CI pipeline nothing can trigger. `deploy.sh` does not warn about this.
>
> `scripts/deploy.sh` runs this at step 3b, **before** the apply that creates Jenkins. That order is
> load-bearing: External Secrets Operator copies the vault into the `jenkins-secret` Kubernetes Secret
> once at creation and then only every `refreshInterval` (1h), so seeding afterwards leaves the
> controller with no admin account until the hourly refresh lands (hit on the 2026-07-31 rebuild).

**2. `terraform apply -var-file=voteball.tfvars`** from `terraform/`. This is the **main** stack now —
there is no separate `jenkins.tfvars` or second `terraform init`. It creates the `ci` namespace, the
agent's IRSA role, the webhook's ACM certificate, `charts/jenkins-support` (ExternalSecret +
NetworkPolicies), and the `helm_release` itself.

**3. Reach the UI to confirm it booted.**

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080
# then browse http://localhost:8080
```

This replaces the old SSH tunnel entirely — there is no SSH key, no Elastic IP, no `admin_cidr` to keep
in sync with your ISP. Login is the username/password seeded in step 1.

**4. Add the GitHub webhook.** Repo → Settings → Webhooks → Add:

- Payload URL `https://jenkins.<app_domain>/github-webhook/` — **the trailing slash is required**
- Content type `application/json`, Secret = the same shared secret from step 1, event: just the push
  event

This is the one step that stays manual for the same reason it always was: nothing in this design gives
Jenkins its own ability to register a hook.

**5. Run the job once with no parameters (G6).** Jenkins registers a pipeline's `parameters` block only
after it has read the `Jenkinsfile` during a build, so `FORCE_BUILD` does not exist yet. **That first run
doing nothing is expected, not a fault.** Afterwards the checkbox appears.

To change configuration afterwards: edit `ci/jenkins/jenkins.yaml` (or the Helm values in
`terraform/addon-jenkins.tf`), commit, then `terraform apply`. The chart's config-reload sidecar picks
up the new JCasC without a manual restart in the common case; if it doesn't, delete the Jenkins pod and
let it reschedule — see "Running the instance" below.

---

## Running the instance

There is no instance to start or stop. Jenkins runs whenever the cluster runs, and is torn down with it
by `terraform destroy` — there is no equivalent of "stop it to save money", because there is no separate
bill for it: it is pods on nodes the cluster already has running for the app.

**The controller is disposable by design.** `JENKINS_HOME` is an `emptyDir`, not a PersistentVolume. The
node group is 100% Spot and gets reclaimed roughly once a day; an EBS volume is locked to one
Availability Zone, so a PVC would need every reschedule to land back in the same AZ or the pod hangs
`Pending` — the one failure mode this design needs a human for. At a daily reclaim rate a PVC would
preserve almost nothing while adding exactly that risk. **Do not add one.**

What is lost on a reclaim (and on every `terraform destroy`): build history and build numbers, reset to
zero. This is capped at the last 20 builds anyway (`buildDiscarder`), and the durable record was never
the build log — it is the `ci: image tag <sha> [skip ci]` commits on `master`, which never expire and
survive every teardown. If a build fails and the pod is reclaimed before anyone reads the log, that log
is gone; in practice a failure is read when it happens.

To force a fresh controller (e.g. after a JCasC change that needs a full restart to pick up):

```bash
kubectl delete pod -n ci -l app.kubernetes.io/component=jenkins-controller
```

It comes back configured from JCasC within about a minute, with no plugin download — the plugin set is
baked into the controller image (`ci/jenkins/Dockerfile`), rebuilt out-of-band with
`scripts/build-push-ecr.sh jenkins <tag>` whenever `plugins.txt` changes, which is rare.

---

## Failure modes

The first ten happened for real during the 2026-07-30/31 move to EKS and are recorded with their actual
symptoms, because in every case the symptom pointed somewhere other than the cause. The rest are the
G1–G7 differences the original design predicted and remain accurate.

| Symptom | Cause | Fix |
|---|---|---|
| Declarative pipeline fails to parse; no stage ever runs | An empty `environment {}` block in the `Jenkinsfile` — declarative Groovy rejects it outright ("No variables specified for environment") | Remove the block entirely; nothing needs to live in it (see the comment at the top of the `Jenkinsfile`) |
| Controller `CrashLoopBackOff`, nothing useful in `kubectl describe pod` or events | JCasC `defaultConfig: true` in the Helm values collides with `ci/jenkins/jenkins.yaml` defining the same keys (`numExecutors`, the `clouds:` block) — `ConfiguratorConflictException`, exit code 5, "Failed to initialize Jenkins" | Set `controller.JCasC.defaultConfig = false` in `terraform/addon-jenkins.tf`. If the controller needs something the default config provided, add it to `ci/jenkins/jenkins.yaml` instead — that file is the single source of truth |
| Agent pod sits at "4/5 healthy", build hangs on "still waiting to schedule" forever, nothing logged | `allowPrivilegeEscalation: false` (or missing `SETUID`/`SETGID`) on the `buildkit` container — rootless BuildKit cannot create its user namespace and `rootlesskit` dies instantly | The `buildkit` container needs `allowPrivilegeEscalation: true` and `capabilities.add: [SETUID, SETGID]`, with `seccompProfile`/`appArmorProfile` set to `Unconfined`. It is still uid 1000, not privileged — see `ci/jenkins/jenkins.yaml`'s long comment on exactly what this does and does not grant |
| Agent pod goes 5/5 Running, but the build never proceeds — no error, just silence until the cloud's `retentionTimeout` reaps the pod | The `ci` NetworkPolicy's egress allowlist excluded the VPC's own pod range, so the agent has no permitted route to the controller (`jenkins.ci.svc.cluster.local:8080`/`:50000`) | The egress policy must explicitly re-allow same-namespace pod-to-pod traffic (`- to: [{ podSelector: {} }]`) even though the broad "allow the internet, deny the VPC" rule looks like it should cover it — see `charts/jenkins-support/templates/networkpolicy.yaml` |
| `aws: not found`, exit code 127 | A step ran outside `container('awscli')` — steps outside any `container()` block run in the `jnlp` container, which has git but no AWS CLI | Wrap every `aws` invocation in `container('awscli') { ... }` |
| `[Errno 13] Permission denied: '/.aws'` (or Trivy failing to write `$HOME/.cache`) | The pod runs every container as uid 1000, but the `trivy`/`awscli`/`skopeo` base images assume root and leave `HOME=/`, which is not writable | Set `env: [{ name: HOME, value: /tmp }]` on those containers — already applied in `ci/jenkins/jenkins.yaml` |
| `401 Unauthorized` against the `*-buildcache` repository, minutes into a build | `buildctl` reads `$DOCKER_CONFIG/config.json` for registry credentials and inherits nothing from the agent's IRSA identity automatically | The Build stage's `awscli` container writes an ECR login to a shared `/images/dockercfg/config.json`, and the `buildkit` container exports `DOCKER_CONFIG=/images/dockercfg` before calling `buildctl` |
| ECR returns a bare `400 Bad Request` on the cache manifest PUT, after the whole image already built and every layer uploaded | BuildKit's default cache export is an OCI image *index*, which ECR's manifest API rejects | Add `image-manifest=true,oci-mediatypes=true` to `--export-cache` |
| Trivy fails with `manifest.json not found in tar`, reads like a corrupt image | BuildKit exported `type=oci` (an OCI *archive*: `index.json` + `blobs/`) instead of `type=docker` (a `docker-archive` tar). Trivy's `--input` reads a docker-archive or an OCI *directory*, never an OCI archive | Export with `--output type=docker,dest=...`. `skopeo` reads `docker-archive:` just as happily, so nothing downstream loses out |
| Tag-bump stage fails with `Host key verification failed`, after the image has already built, scanned and pushed | The JCasC-pinned host key (`security.gitHostKeyVerificationConfiguration`) only covers the git **plugin**'s checkout. This stage shells out to raw `git push` in the `jnlp` container, which has its own, separate `~/.ssh/known_hosts` | Write the same pinned GitHub host key into `~/.ssh/known_hosts` inside this stage before pushing — see the comment at the top of the `Bump image tag` stage in the `Jenkinsfile` |
| **G2** — Jenkins rebuilds its own tag-bump commit, forever | The Guard stage or `scripts/ci/should-skip-build.sh` was removed. `[skip ci]` does nothing in Jenkins on its own | Restore the Guard stage. See the standing warning in `CLAUDE.md` |
| **G1** — re-running a build fails with `tag already exists` | ECR tags are `IMMUTABLE` and images are tagged by commit SHA | Already handled by the "Already built?" stage; if it fails, check the agent's IRSA role still has `ecr:DescribeImages` |
| A commit you expected to build finishes `NOT_BUILT` immediately, and the site does not change | The commit **message** contains the skip marker anywhere in it — including when merely *writing about* it. The Guard deliberately fails safe toward skipping: a wrong skip costs one manual rebuild, a wrong build costs an unbounded loop | Expected behaviour, not a fault. A marker-bearing commit can never be built, even with `FORCE_BUILD`, because the Guard runs first and unconditionally. Amend the commit message and push again |
| **G3** — "Build Now" does nothing | A manual build has an empty changeset, so the `services/**` condition is false | Use *Build with Parameters* and tick `FORCE_BUILD` |
| **G4** — `git push` denied at the last stage | Deploy key missing, read-only, or (see above) an HTTPS SCM URL | Deploy key with **write** access + SSH SCM URL |
| **G6** — `FORCE_BUILD` checkbox is missing | The job has never run, so Jenkins has not read the `parameters` block yet | Run the job once; it registers them |
| **G7** — a build failed and nobody noticed | Jenkins sends no email without SMTP | Accepted, see below. Check the Jenkins UI, or `kubectl get application voteball -n argocd` to see whether the deployed tag actually advanced |
| `RepositoryNotFoundException` pushing to ECR | **The main stack is destroyed** — Jenkins goes with it, and so does ECR (`force_delete = true`) | Expected while torn down. `./scripts/build-push-ecr.sh` is the manual fallback when there is no cluster to run CI at all |
| CI is green but the site doesn't change | No cluster, or no ArgoCD Application | `kubectl get application voteball -n argocd`; `./scripts/deploy.sh` bootstraps it |
| Pods go to `ImagePullBackOff` after a sync | `values.yaml` on `master` names a tag/registry that doesn't exist in this account's ECR | `./scripts/sync-values-from-tf.sh --check` |

---

## Doing it by hand

`./scripts/build-push-ecr.sh` runs the build/scan/push part locally — the four app images, or (with the
`jenkins` argument) the controller image itself. `./scripts/deploy.sh` runs the full sequence including
this and the Terraform apply that installs Jenkins. **There is no CI while the cluster is destroyed** —
ArgoCD is also gone during a teardown, so nothing could deploy anyway — which makes
`./scripts/build-push-ecr.sh` load-bearing rather than a convenience during that window, and it must be
kept working.

Note the ordering constraint `deploy.sh` encodes: **`values.yaml` must be committed and pushed before
the ArgoCD Application is created.** Bootstrapping ArgoCD against a `master` that still holds stale
values makes it immediately revert the deploy — after a rebuild, to an image tag that no longer exists,
so every pod lands in `ImagePullBackOff`.

---

## GitHub Actions is fully retired (2026-07-21)

`terraform/github-oidc.tf` and the `github_actions_role_arn` output were deleted, and the IAM role and
OIDC provider destroyed in AWS. Restoring it now requires the workflow file, a main-stack
`terraform apply` to recreate the role and provider, and re-adding four repository variables.

## The EC2 host is fully retired (2026-07-31)

The dedicated `t3.medium` and its whole separate Terraform stack — the Elastic IP, the separate
Terraform state, the `admin_cidr` allowlist, the SSH key pair — are destroyed and deleted. See
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md) for the
full design and its "Verification outcome" section for what the move actually broke.

## Deferred, on purpose

- **SSM Session Manager** — moot now; there is no SSH access to anything Jenkins runs on.
- **Build-failure notifications (G7).** Jenkins sends nothing without SMTP, and provisioning mail
  credentials is a surface this project declined to add. The compensating practice: verification means
  checking the Jenkins UI or ArgoCD's Application state, **not** inferring success from the site still
  working. Recorded as a decision, not an oversight — revisit if the project outlives the course.
- **Multibranch, notifications, or a shared cluster-wide BuildKit daemon.** All still out of scope for
  the same reasons the 2026-07-20 design gave; the in-cluster move did not reopen any of them.
