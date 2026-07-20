# CI migration: GitHub Actions → Jenkins on EC2

**Date:** 2026-07-20
**Status:** approved, pending implementation

## Problem

A course requirement now mandates Jenkins as the CI system. The existing pipeline
(`.github/workflows/ci.yml`) works and is documented in `docs/cicd.md`, but it runs on GitHub's
hosted runners and authenticates to AWS through a GitHub-specific OIDC federation
(`terraform/github-oidc.tf`). Neither carries over.

Because the requirement is a graded one, the *artifacts* are part of the deliverable: a readable
pipeline definition, a documented setup procedure, and evidence of a green end-to-end run. A pipeline
that merely works is not sufficient — every important decision must be explainable.

### What carries over unchanged

The delivery half of the pipeline is CI-agnostic. Jenkins' job ends at "push images to ECR and commit
the new tag to `values.yaml`"; ArgoCD observes that commit and rolls the Deployments exactly as it does
today. `charts/voteball/`, `argocd/voteball-application.yaml`, `scripts/sync-values-from-tf.sh`,
`scripts/deploy.sh` and `scripts/build-push-ecr.sh` require **no changes**.

This is a direct consequence of the GitOps choice: CI never held cluster credentials, so replacing CI
does not touch the security boundary around the cluster.

### What does not carry over

Seven behaviours differ. Most are things GitHub Actions provides that Jenkins does not (G1–G5, G7);
G6 is a Jenkins quirk with no GitHub Actions counterpart. Each is a real defect if translated naively,
and each is labelled here and referenced from the design, the verification list and the implementation
plan.

#### G1 — re-running a build fails against immutable ECR tags

`terraform/ecr.tf:9` sets `image_tag_mutability = "IMMUTABLE"`. Images are tagged with the short commit
SHA, so re-running a build for the same commit attempts to push a tag that already exists and ECR
rejects it. Under GitHub Actions this was rare. Under Jenkins — where "Build Now" and replaying a build
to debug a later stage are routine, especially while learning the tool — it is a frequent, confusing
red build caused by nothing being wrong.

#### G2 — `[skip ci]` is a GitHub Actions feature and does nothing in Jenkins

The pipeline's final step commits the bumped image tag back to `master`. GitHub Actions honours
`[skip ci]` in a commit message natively and does not re-trigger. **Jenkins has no such convention.**
The webhook fires on Jenkins' own commit, which is a new SHA, so Jenkins builds it, pushes images,
bumps the tag, commits again — an unbounded build loop that consumes ECR storage and continuously rolls
production pods.

This is the highest-impact item on the list: it fails silently, unattended, and costs money.

#### G3 — the `services/**` path filter has no direct equivalent

`ci.yml:5-8` restricts builds to commits touching app source. Jenkins' declarative equivalent is
`when { changeset "services/**" }`, which behaves differently in one case: a manually triggered build
has an empty changeset and would skip every stage, making "Build Now" a no-op.

#### G4 — there is no free git credential

GitHub Actions supplies an ambient `GITHUB_TOKEN` scoped to the repository, which `ci.yml` uses to push
the tag bump. Jenkins has no ambient identity and needs an explicitly provisioned credential — a new
secret that did not previously exist.

#### G5 — the build host is persistent, so disk fills

GitHub's runners are destroyed after every job. A long-lived EC2 agent accumulates four image builds
per run plus Trivy's cache on a fixed-size volume until builds fail on a full disk.

#### G6 — Jenkins job parameters do not exist until the job has run once

Jenkins registers a pipeline's `parameters` block only after it has read the `Jenkinsfile` during a
build. The `FORCE_BUILD` checkbox (see G3) is therefore absent from the UI on the very first run, so
the first attempt to trigger a manual build cannot set it. The pipeline is not broken, but it appears
to be — an unnecessary obstacle during initial setup, when confidence in the new system is lowest.

#### G7 — build failures are silent

GitHub Actions emails the committer when a run fails. Jenkins sends nothing unless SMTP is configured,
and this Jenkins has no publicly reachable UI, so a red build is invisible until the maintainer next
opens the tunnel. Because the pipeline auto-deploys, an unnoticed failure means believing a change
shipped when it did not.

## Non-goals

- **No application behaviour changes.** This is CI infrastructure only.
- **No change to ArgoCD, the Helm chart, or the deploy/destroy scripts.**
- **Jenkins does not deploy.** Introducing `helm upgrade`/`kubectl` into Jenkins would require EKS
  credentials on the build host, widening blast radius, and would fight ArgoCD's `selfHeal`. The
  GitOps bonus track is retained.
- **No Jenkins Configuration as Code (JCasC) in this pass** — deferred, see §8.
- **No SSM Session Manager access path in this pass** — deferred, see §8.
- **No multi-branch or PR-triggered builds.** The repository works directly on `master`; the existing
  pipeline has no PR checks and this migration does not add any.

## Design

### 1. Two Terraform stacks, deliberately separate

A new stack at `terraform/jenkins/` holds the build host. It has its **own state file** and is applied
and destroyed independently of `terraform/`.

| Stack | Contains | Lifecycle |
|---|---|---|
| `terraform/` (existing) | VPC, EKS, RDS, ECR, ACM, add-ons | destroyed and rebuilt frequently |
| `terraform/jenkins/` (new) | one EC2 instance, IAM role, security group, Elastic IP | applied once, left alone |

`scripts/destroy.sh` only ever operates in `terraform/`, so tearing down the cluster leaves Jenkins and
its build history intact. This is the central constraint: a CI server owned by the stack it builds for
would be deleted on every teardown cycle.

The new stack **does not reference the existing one**. Its ECR permission is expressed as an ARN
pattern rather than a resource reference:

```hcl
resources = [
  "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-*"
]
```

This grants no more than the current policy (the four `voteball-*` repositories) while removing any
cross-stack dependency, so the Jenkins stack applies cleanly even while the main stack is destroyed.

Files:

```
terraform/jenkins/
  main.tf                  # instance, security group, Elastic IP, key pair
  iam.tf                   # role, instance profile, ECR-push policy
  variables.tf             # region, cluster_name, admin_cidr, public_key_path, instance_type
  outputs.tf               # public IP, ready-to-paste SSH tunnel command
  user_data.sh             # bootstrap
  jenkins.tfvars.example
  README.md                # what this stack is, why it is separate, how to apply it
```

Deployed into the region's **default VPC** (`vpc-04eeceb25344a3ae7` in `il-central-1`), not the
application VPC — again so the two lifecycles never touch. `account_id` is resolved by
`data.aws_caller_identity`, not hardcoded, per the repo's forkability rule.

### 2. `.gitignore` must be extended (latent secret-leak bug)

The existing rules are anchored to the stack root:

```
terraform/voteball.tfvars
terraform/terraform.tfstate*
```

These do **not** match `terraform/jenkins/terraform.tfstate`. Without an update, the new stack's state
file would be tracked by git on the first `git add`. Add:

```
terraform/jenkins/jenkins.tfvars
terraform/jenkins/terraform.tfstate*
terraform/jenkins/.terraform/
terraform/jenkins/tfplan
```

The comment block at `.gitignore:9-13` explaining the absence of a blanket `terraform/` rule stays
correct and gains one line noting the subdirectory.

### 3. AWS authentication: instance profile, not OIDC

An IAM role is attached to the instance itself. Any AWS SDK or CLI call on that host obtains temporary
credentials from the instance metadata service automatically. There is no OIDC provider, no
`configure-aws-credentials` step, and no stored key material. ECR login reduces to:

```bash
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

The policy is lifted verbatim from `terraform/github-oidc.tf:36-52` — `ecr:GetAuthorizationToken` plus
the layer-upload set — scoped as described in §1. **No EKS, RDS, S3, SNS or Secrets Manager access.**

IMDSv2 is enforced (`http_tokens = "required"`), so a server-side request forgery on the host cannot
trivially exfiltrate the role's credentials.

> **Hazard.** The strings "OIDC provider" also appear in `terraform/eks.tf` and `terraform/irsa.tf`.
> Those are the *cluster's* OIDC provider, which underpins IRSA for the worker, backup, ESO,
> ALB-controller, autoscaler and external-dns service accounts. They are unrelated to GitHub and must
> not be touched. Only `terraform/github-oidc.tf` is deleted.

### 4. Network exposure

| Direction | Port | Source / destination | Purpose |
|---|---|---|---|
| inbound | 8080 | GitHub hook CIDRs, fetched at apply time | receive push webhooks |
| inbound | 22 | `var.admin_cidr` (maintainer's IP) | SSH tunnel to the UI |
| outbound | all | anywhere | ECR, GitHub, Docker Hub, ghcr.io, OS package repos |

The GitHub ranges are read live rather than hardcoded, since they change:

```hcl
data "http" "github_meta" { url = "https://api.github.com/meta" }
# cidr_blocks = jsondecode(data.http.github_meta.response_body)["hooks"]
```

**The Jenkins UI is never publicly reachable.** Access is via an SSH tunnel:

```bash
ssh -i ~/.ssh/voteball-jenkins.pem -L 8080:localhost:8080 ec2-user@<eip>
# then browse http://localhost:8080
```

Tunnelled traffic arrives at Jenkins from `localhost` and is therefore never evaluated against the
security group, which is why the UI is reachable despite port 8080 being closed to the maintainer's IP.

Two accepted positions, both to be stated explicitly in `docs/security.md` rather than left implicit:

- **Egress is unrestricted.** Docker Hub, ghcr.io and GitHub publish wide and frequently changing IP
  ranges; an egress allowlist would be brittle rather than secure. Standard practice for a build host.
- **The webhook is plain HTTP.** The payload contains no secrets. It is authenticated by a shared
  secret (§6), not by transport encryption. TLS termination in front of Jenkins is possible but adds a
  certificate lifecycle for no meaningful gain here.

Outbound-only for everything except the single webhook entry is the property that makes this
defensible: only one thing in the world can *initiate* a connection to this host, and it is GitHub.

### 5. The instance

`t3.medium` (2 vCPU / 4 GB), Amazon Linux 2023, 30 GB gp3, with an **Elastic IP** so the address
survives stop/start cycles.

`t3.small` was rejected: four concurrent-ish Docker builds plus Trivy's vulnerability database do not
fit comfortably in 2 GB, and intermittent out-of-memory build failures are a poor thing to debug while
also learning Jenkins.

Cost is roughly **$30/month** running continuously. The intended operating mode is to stop the instance
between working sessions (`aws ec2 stop-instances`), which drops the cost to about **$2.50/month** for
storage; all Jenkins state persists on the EBS volume and the Elastic IP keeps the address stable.
**Webhooks are silently discarded while the instance is stopped** — this is a documented consequence,
not a fault, and the runbook records the start/stop commands.

A new `voteball-jenkins` key pair is created for this host. The two existing key pairs in the account
(`S3App-EC2-pem`, `S3App-Frontend-pem`) belong to the retired, independent S3App project and are not
reused. The private `.pem` never leaves the maintainer's machine and is already covered by the `*.pem`
rule in `.gitignore`.

### 6. Bootstrap (`user_data.sh`)

Runs as root on first boot. Installs `java-21-amazon-corretto`, `git`, the Jenkins RPM repository and
`jenkins`, and `docker`; adds the `jenkins` user to the `docker` group; enables and starts both
services; creates `/var/lib/trivy-cache` owned by `jenkins`.

**Trivy is not installed.** It runs as a container (`aquasec/trivy:0.58.1`), exactly as it does today,
so Docker fetches it on demand. This preserves parity with the current pipeline and keeps the pinned
scanner version visible in the `Jenkinsfile` rather than buried in a bootstrap script.

The script is written to be **idempotent and safe to re-run**. `user_data` executes only on first boot
and Terraform does not verify that it succeeded — `terraform apply` reports success as long as the
instance was created, so a scripting error surfaces only as a missing service. Making the script
re-runnable allows iteration over SSH (re-running it directly, reading
`/var/log/cloud-init-output.log`) instead of destroying and recreating the instance for each attempt.
A single clean destroy-and-recreate at the end proves it works from scratch.

**Accepted risk, to be documented:** membership of the `docker` group grants effective root on the
host, so anyone able to define a Jenkins job can control the machine. This is inherent to building
container images on a Jenkins agent. It is mitigated by the host having no inbound access other than
GitHub's webhook, and by Jenkins requiring authentication.

**Webhook authentication.** A shared secret is generated during setup and configured in both the GitHub
webhook and the Jenkins job, so Jenkins verifies the HMAC signature GitHub attaches to each delivery.
Without it, any host inside GitHub's IP ranges could trigger builds. The secret is entered through the
Jenkins UI and stored in the credentials store; it never enters git.

**First-time configuration**, performed once through the UI and recorded as a numbered runbook in
`docs/cicd.md`:

- **Plugins:** Git, Pipeline, GitHub, Credentials Binding, SSH Agent. Deliberately **not** Docker
  Pipeline: that plugin exists for the `docker.build()` DSL, and the `Jenkinsfile` shells out to the
  `docker` CLI instead, so installing it would add an unused component to patch. (This list is also the
  input to the deferred JCasC pass's `plugins.txt`, which is why it is fixed here rather than left to
  whatever the setup wizard's "recommended" set happens to contain.)
- **Job type:** a **Pipeline** job configured as *Pipeline script from SCM* — not Freestyle (which
  would put the build definition in Jenkins' database instead of the repository, defeating the point)
  and not Multibranch (the project works directly on `master`; see non-goals).
- **Credentials:** the deploy key (G4) and the webhook shared secret.
- **Webhook:** `http://<elastic-ip>:8080/github-webhook/` — the trailing slash is required.
- Unlock, admin user, then the G6 first run.

### 7. The `Jenkinsfile`

A declarative pipeline at the repository root, written plainly and commented, mirroring the current
four steps. Each mitigation below is numbered against the gotcha it closes.

```
options: disableConcurrentBuilds(), buildDiscarder(last 20)      → G5
parameters: FORCE_BUILD (boolean, default false)                 → G3
triggers: githubPush()

Stage 1  Guard          abort if the head commit message contains [skip ci]   → G2
Stage 2  Checkout       via the deploy key                                    → G4
Stage 3  Already built? query ECR for this SHA; if present, jump to Stage 7   → G1
Stage 4  Build          four images tagged with the short SHA                 → G3
Stage 5  Scan           Trivy with a persistent cache; blocking on backend/
                        worker/nginx, report-only on backup
Stage 6  Push           to ECR
Stage 7  Bump tag       sed values.yaml, rebase, commit "[skip ci]", push     → G4
post     always         docker image prune -f                                 → G5
```

#### G1 — idempotent re-runs

Stage 3 queries `aws ecr describe-images --image-ids imageTag=$TAG` for each repository. If every image
for this commit already exists, stages 4–6 are skipped and the build proceeds directly to the tag bump,
logging the reason. Re-runs become green and idempotent, one image per commit is preserved, and nothing
is rebuilt or rescanned pointlessly.

The skip path is only taken on a positive result from ECR — a lookup failure builds normally rather
than assuming success, so the failure mode is a redundant build, never a build that silently ships
nothing.

#### G2 — explicit loop guard

Stage 1 reads the head commit message (`git log -1 --pretty=%B`) and aborts the build if it contains
`[skip ci]`. The marker is still written into the bump commit so history reads identically and the
repository stays portable, but Jenkins gets real logic rather than relying on a convention it does not
implement.

The guard is a visible first stage rather than a plugin setting so that it appears in the file a
reviewer reads, and so that removing it is an obvious edit rather than an invisible configuration
change.

#### G3 — path filtering with a manual override

Stages 4–6 carry `when { anyOf { changeset "services/**"; expression { params.FORCE_BUILD } } }`. Normal
pushes behave as `ci.yml` does today; a manual "Build Now" with `FORCE_BUILD` ticked always builds,
which also provides a clean way to demonstrate the pipeline without inventing a commit.

The existing caveat documented in `docs/cicd.md` — that the filter is a path match, not a judgement,
so a comment-only change to `services/backend/schema.sql` triggers a full build — remains true and
remains correct.

#### G4 — repository-scoped deploy key

A GitHub **deploy key** with write access, stored in the Jenkins credentials store and used for both
checkout and push. Preferred over a personal access token, which is scoped to the whole account: if the
build host were compromised, a deploy key loses exactly one repository.

Stage 7 runs `git pull --rebase --autostash` before pushing — the same fix commits `ed39db2` and
`1269ba8` applied to `scripts/deploy.sh` for the identical race. `disableConcurrentBuilds()` prevents
two builds from contending for `values.yaml` in the first place.

#### G5 — bounded disk usage

`docker image prune -f` in `post { always { … } }`, plus `buildDiscarder` retaining the last 20 builds.

#### G6 — first run registers the parameters

No code change resolves this; it is inherent to how Jenkins loads a pipeline. The runbook instead
records the required sequence: **run the job once with no parameters** (which registers them and, on a
commit that touches no app source, correctly does nothing), after which `FORCE_BUILD` appears for
subsequent manual builds. Called out explicitly so that an empty first run reads as expected behaviour
rather than a broken pipeline.

#### G7 — accepted: no failure notifications

Configuring SMTP would mean provisioning and storing mail credentials on the build host for a
two-week-old project with a single maintainer, so this pass **accepts silent failures** rather than
adding that surface. The compensating practice is that verification means checking the Jenkins UI, not
inferring success from the site still working — and ArgoCD's own state (`kubectl get application
voteball -n argocd`) independently reveals whether the deployed tag advanced.

Recorded as a decision rather than an oversight; revisit if the project outlives the course.

#### Trivy cache

The current invocation uses `--rm` with no volume, so the ~50 MB vulnerability database is discarded
and re-downloaded on each of the four scans, every build. On GitHub's ephemeral runners this was
invisible; on a persistent host it is wasteful and exposes the pipeline to anonymous pull rate limits
on ghcr.io (`TOOMANYREQUESTS`), which would fail builds for reasons unrelated to the code. The Jenkins
invocation mounts `/var/lib/trivy-cache`, reducing database downloads from four per build to roughly
one per six hours (Trivy refreshes when its copy is older than that).

Scanner *version* updates remain manual by design — the pinned `aquasec/trivy:0.58.1` tag means a new
upstream release cannot turn a green pipeline red without a deliberate edit. `docs/maintenance.md`
gains a reminder to bump it.

### 8. Deferred to a later pass

- **JCasC (Jenkins Configuration as Code).** This pass configures Jenkins through its web UI once —
  unlock, plugins, admin user, job definition, credentials — and records those steps as a numbered
  runbook, which the rubric explicitly permits ("document manual operations"). A later pass converts
  that clicking into `jenkins.yaml` plus `plugins.txt` so the host self-configures on boot. Sequencing
  it second is deliberate: a working green build is banked first, and the configuration file is easier
  to write and to understand having performed the equivalent steps by hand.
- **SSM Session Manager** as the UI access path, replacing the SSH tunnel and closing port 22 entirely.

### 9. Repository changes

**Delete** — *ordering is constrained; see §10*

- `.github/workflows/ci.yml`
- `terraform/github-oidc.tf`
- the `github_actions_role_arn` output (`terraform/outputs.tf:56-58`)

**Add**

- `Jenkinsfile`
- `terraform/jenkins/` (§1)
- `.gitignore` entries (§2)

**Rewrite**

- `docs/cicd.md` — the four required GitHub repo variables and the OIDC failure modes are obsolete. The
  structure is retained, including the failure-modes table (which gains the G1–G7 symptoms) and the
  verified-run evidence table (re-recorded against the Jenkins run). Gains the first-time-configuration
  runbook (§6) and the instance start/stop commands (§5).

**Graded deliverables** — these are read by the assessor, not just by maintainers, so they are called
out separately rather than folded into the amendment list:

- **`docs/eks/architecture.md:43`** — the architecture diagram is Mermaid, inline, and its CI node
  currently reads `gh[GitHub Actions<br/>OIDC → build/Trivy/ECR]`. The rubric names the diagram as an
  explicit deliverable, so this is a graded artifact describing a pipeline that will no longer exist.
  The node and the accompanying prose at line 71 both change.
- **`README.submission.md:46`** — the turn-in README describes the GitHub Actions flow. It must
  describe the Jenkins flow *and* carry the green-build evidence; `docs/cicd.md` is too deep for the
  assessor to be relied on to reach it.

**Amend** — each references GitHub Actions and must be updated:
`CLAUDE.md`, `README.md`, `docs/security.md`, `docs/production-readiness.md`, `docs/maintenance.md`,
and the two 2026-07-20 design docs (which are historical records and receive only a forward-reference
note, not a rewrite).

`docs/security.md` specifically gains: the instance-profile model replacing OIDC federation (§3), the
inbound/outbound posture and its two accepted positions (§4), and the `docker`-group root-equivalence
on the build host (§6).

`CLAUDE.md` additionally gains a short standing warning about G2, in the same spirit as the existing
`ignore_changes`/`final_snapshot_identifier` warning: a future tidy-up that removes the guard stage
reintroduces an unbounded, billable build loop.

**Unchanged:** `charts/`, `argocd/`, `scripts/`, `services/`.

### 10. Cutover and rollback

#### The two pipelines must never be armed simultaneously

If `ci.yml` and the Jenkins webhook are both live — even briefly — a single push to `services/**`
triggers both. They build the same commit (one fails on the immutable tag, per G1) and both attempt to
bump `values.yaml` and push to `master`, which is exactly the collision that motivated choosing
"replace" over "coexist" in the first place. Introducing it accidentally during the transition would
be a self-inflicted version of the problem this design exists to avoid.

The cutover is therefore ordered:

1. Build and apply `terraform/jenkins/`; complete first-time configuration.
2. Add the `Jenkinsfile`, but create the webhook **disabled** (or omit it) and drive builds manually
   with `FORCE_BUILD` until the pipeline is green end to end.
3. **Disarm GitHub Actions** — change `ci.yml`'s trigger to `workflow_dispatch` and push. From this
   moment no push can start a GitHub Actions run.
4. **Then** enable the GitHub webhook. Exactly one system is now trigger-driven.
5. Run the full verification list below.
6. Only after verification passes: delete `ci.yml`, then `terraform/github-oidc.tf` and its output.

#### Rollback

Steps 3 and 6 are deliberately separated so that a working pipeline is recoverable throughout.

Between steps 3 and 6, `ci.yml` still exists and its IAM role still exists in AWS; reverting one commit
restores the GitHub Actions pipeline in full. **This is the property that must be preserved** — it is
what makes the migration safe to attempt under deadline pressure.

After step 6 the rollback is materially more expensive: recovering GitHub Actions would require
restoring `ci.yml`, re-applying the main Terraform stack to recreate the IAM role and OIDC provider,
and re-adding the four GitHub repository variables. `terraform/github-oidc.tf` is therefore deleted
**last, as its own commit**, after verification has passed — never bundled with the rest of the
cleanup.

## Verification

The migration is complete when all of the following are demonstrated:

1. `terraform apply` in `terraform/jenkins/` creates the host; Jenkins is reachable through the SSH
   tunnel with no other inbound access.
2. A push touching `services/**` triggers a build via webhook, and the pipeline completes: four images
   built, Trivy blocking scan passed, images in ECR tagged with the short SHA, `values.yaml` bumped.
3. ArgoCD syncs the new tag unprompted and the Deployments roll with no `ImagePullBackOff`.
4. **G2 is proved, not assumed.** The tag-bump commit Jenkins itself pushed must be observed *not* to
   start a second build. This is the single most important check; it is the only failure on the list
   that runs unattended and accrues cost.
5. **G1 is proved.** Re-running a completed build succeeds (green), skips stages 4–6, and reports why.
6. A docs-only push does **not** trigger a build; a manual build with `FORCE_BUILD` does.
7. Stopping and starting the instance leaves Jenkins, its job, and its history intact, and the Elastic
   IP unchanged.
8. **At no point were both pipelines trigger-driven.** After §10 step 3, the GitHub Actions run history
   shows no new runs; the webhook is enabled only afterwards.
9. **Rollback is intact until the end.** Before §10 step 6, reverting the `ci.yml` trigger commit is
   confirmed to restore a working GitHub Actions pipeline — verified by inspection of the role and
   repository variables, not assumed.
10. The architecture diagram (`docs/eks/architecture.md:43`) and `README.submission.md` describe
    Jenkins and carry the evidence.
11. `git grep -i "github actions"` returns only intentional historical references.

Evidence is recorded in `docs/cicd.md` in the same format as the existing 2026-07-20 verified-run
table, and summarised in `README.submission.md`.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| G2 guard is defective → unbounded build loop | **High** — unattended, billable | Verification step 4 is explicit and mandatory; `CLAUDE.md` warning; `disableConcurrentBuilds()` bounds the rate |
| G1 skip logic wrongly reports "already built" → green build ships nothing | Medium | Skip only on a positive ECR lookup; lookup failure builds normally |
| `user_data` fails silently; `terraform apply` still reports success | Medium | Idempotent script, iterate over SSH, one clean rebuild to prove it; `README.md` points at `/var/log/cloud-init-output.log` |
| ECR repositories are destroyed with the main stack (`force_delete = true`), so pushes fail while torn down | Low — expected | Documented in `docs/cicd.md` failure modes, matching the existing note about CI during teardown |
| Jenkins host lost → build history and configuration lost | Low — accepted | Rebuildable from Terraform; the deferred JCasC pass recovers configuration |
| GitHub webhook CIDRs change | Low | Fetched at apply time from `api.github.com/meta`; re-apply refreshes them |
| Webhooks discarded while the instance is stopped | Low — intended | Runbook documents it; `FORCE_BUILD` re-runs on demand |
| Both pipelines armed during cutover → duplicate builds racing to push `values.yaml` | **High** — self-inflicted, and the exact failure this design avoids | §10 ordering: disarm GitHub Actions *before* enabling the webhook; verification step 8 |
| `github-oidc.tf` deleted too early → expensive rollback under deadline pressure | Medium | §10: deleted last, as its own commit, after verification; verification step 9 |
| Build failures unnoticed (G7) | Medium | Accepted, §7; compensated by checking the Jenkins UI and ArgoCD's Application state rather than inferring success from the live site |
| `FORCE_BUILD` absent on first run (G6) reads as a broken pipeline | Low | Runbook records the required first run explicitly |
| Architecture diagram still shows GitHub Actions at submission | Medium — graded artifact | Listed as a deliverable in §9, not folded into the general docs sweep; verification step 10 |
| Jenkins security advisories | Low | Reminder added to `docs/maintenance.md` alongside the EKS support-window tracking |

## Scope confirmation (2026-07-20)

This design was written against the assumption that the requirement means "use Jenkins for CI", with no
further Jenkins-specific constraints. **That was checked with the course lecturer before any
infrastructure was applied, and the choice of approach was left to the implementer.** The design
therefore stands as written, and the following were considered and deliberately declined:

- **Jenkins performing the deployment.** Declined: it would require EKS credentials on the build host,
  widening blast radius, and would fight ArgoCD's `selfHeal`. ArgoCD remains the deployer, and Jenkins
  holds no cluster access at all (§3).
- **Kubernetes-hosted ephemeral agents.** Declined: ephemeral agents solve build contention and
  cross-build contamination between many teams, neither of which this single-maintainer project has.
  Adopting them would require cluster credentials for Jenkins — weakening the property in §3 that it
  has none — plus Kaniko or rootless BuildKit to build images under the cluster's non-root,
  `readOnlyRootFilesystem` pod security posture, and would put heavyweight builds on the same Spot
  nodes that serve live traffic.
- **A multibranch pipeline.** Declined: this repository is developed as direct commits to `master`,
  with no feature branches or pull requests, so a multibranch job would discover exactly one branch and
  behave identically to a single Pipeline job with more indirection. It would also introduce a real
  hazard — a build on a non-`master` branch must never run the tag-bump stage, since ArgoCD deploys
  whatever `values.yaml` names on `master`. Should multibranch ever be adopted, the bump stage requires
  `when { branch 'master' }`.
