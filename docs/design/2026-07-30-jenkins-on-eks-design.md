# CI migration: Jenkins on EC2 → Jenkins on EKS

Supersedes the deployment topology of `2026-07-20-jenkins-migration-design.md` (which moved CI from
GitHub Actions to a dedicated EC2 host) and `2026-07-21-jenkins-jcasc-design.md` (which put that
host's configuration in git). **Both remain the reference for _why_ the pipeline has the shape it
has** — the G1–G7 guard labels, the `[skip ci]` loop guard, the tag-bump-commit-as-deploy model. This
document changes only *where Jenkins runs* and *how it builds images*. It does not change what the
pipeline does.

## Problem

CI runs on a dedicated `t3.medium` EC2 instance built by the separate `terraform/jenkins/` stack. That
was the right call in July: it kept the CI server outside the lifecycle of the cluster it builds for,
which `scripts/destroy.sh` tears down on every rebuild cycle.

Two things have changed:

1. **The submission story.** The project's whole thesis is that everything runs on Kubernetes. A CI
   server on a hand-managed EC2 instance is the one component that contradicts it.
2. **The host is a maintenance surface.** It must be started before a push will build (webhooks are
   silently discarded while it is stopped), `admin_cidr` must be re-applied whenever the maintainer's
   ISP reassigns their home IP, and the OS must be patched in place because the AMI foot-gun is
   disarmed rather than solved.

Cost is a secondary motivation and is honestly modest — see the cost table below. This migration saves
roughly $8/month.

### What carries over unchanged

- **The pipeline's logic.** Both CI guard scripts (`scripts/ci/should-skip-build.sh`,
  `scripts/ci/images-exist.sh`) and their offline test (`scripts/tests/test-ci-guards.sh`) are
  untouched. **G2, the `[skip ci]` loop guard, is preserved exactly** — Jenkins still has no native
  `[skip ci]`, and the unbounded billable build loop it prevents is unchanged by the move.
- **The deploy model.** Jenkins builds, scans, pushes and commits a tag bump. **ArgoCD deploys.**
  Jenkins holds no cluster-deploy credentials, now for a sharper reason than before: it is *inside*
  the cluster and must still be unable to change it.
- **JCasC as the source of truth.** `casc/jenkins.yaml` moves into the Helm release's
  `controller.JCasC.configScripts`. The `${PLACEHOLDER}` substitution mechanism is unchanged; the
  values arrive as pod environment variables instead of from `user_data.sh`.
- **The `voteball/jenkins` secret in Secrets Manager**, with the same keys.

### What does not carry over

- **The Docker daemon.** EKS nodes run `containerd`. `docker build`, `docker push`, `docker login`
  and the four `-v /var/run/docker.sock` mounts in the Trivy stage have no equivalent in a pod.
- **The EC2 host and its whole stack.** `terraform/jenkins/` is destroyed and deleted, along with the
  AMI `ignore_changes` foot-gun, the SSH key pair, the SSH tunnel, `admin_cidr`, the Elastic IP, and
  the hand-written GitHub-plugin XML.
- **Build history across a cluster teardown.** Accepted deliberately; see §2.

## Non-goals

- **Not changing what the pipeline does.** Same four images, same Trivy severity gate, same tag-bump
  commit, same ArgoCD hand-off.
- **Not giving Jenkins any deploy capability.** The temptation to `kubectl apply` from a pod that is
  already in the cluster is exactly what the RBAC scope in §7 exists to foreclose.
- **Not making CI survive a cluster teardown.** It will not. See Risks.
- **Not adding multibranch, notifications, or SMTP.** G7 stands: there is no email. Deferred items
  from the 2026-07-20 design stay deferred.

## Design

### 1. Where Jenkins runs

**Namespace `ci`**, not `devops-app`. The application namespace is the graded deliverable and should
contain the application. A separate namespace also makes the isolation claim enforceable rather than
conventional: a NetworkPolicy in `ci` denies egress to the RDS security group and to `devops-app`.

**Installed by Terraform as a `helm_release`** of the official `jenkins/jenkins` chart — not by
ArgoCD. This follows the boundary `CLAUDE.md` already draws: Terraform owns platform add-ons (ArgoCD,
ESO, external-dns, kube-prometheus-stack), ArgoCD owns the application chart. Jenkins is platform.
Installing it via ArgoCD would also add a dependency on a component Terraform itself creates, for no
benefit.

**Consequence:** changes to the Jenkins release reach the cluster by `terraform apply`, not by
committing to `master`. This differs from the app chart and must be stated in `docs/cicd.md`, because
the two work differently on purpose.

### 2. The controller is disposable — no PersistentVolume

This is the decision the rest of the design hangs off, and it is grounded in measured behaviour of
this cluster rather than in general Spot guidance.

The node group is 100% Spot (`t3.large`/`t3a.large`, min 2, spread across `il-central-1a` and
`il-central-1b`). Auto Scaling group activity for
`eks-default-2026072706270847790000001f-08cfd120-be5e-acc0-3af6-9e8bc118a639`, covering the cluster's
entire life from its creation on 2026-07-27 06:27 to 2026-07-30:

```
2026-07-29 15:26  "taken out of service in response to an EC2 health check
                   indicating it has been terminated or stopped"
2026-07-30 04:36  (same)
2026-07-30 08:28  (same)
```

That wording is a Spot reclaim: the instance vanished and the ASG noticed via health check. (The
15:20 and 15:24 entries the same day read "in response to a user request" — those are the 1.35
upgrade, deliberate.) **Three reclaims in ~84 hours, roughly one per day.** Note also that
`i-093dcbec` survived all three days untouched while the other node slot churned three times: one of
the two Spot pools in this region is markedly thinner than the other.

**Therefore `JENKINS_HOME` is an `emptyDir`.** An EBS volume is locked to one Availability Zone, so a
PersistentVolumeClaim would require every reschedule to land back in the same AZ or the pod hangs
`Pending`, unable to mount. At a daily reclaim rate a PVC would preserve almost nothing while
introducing the only failure mode in this design that needs manual intervention. An `emptyDir`
controller reschedules into any AZ in seconds — which is precisely how the application already
survives these reclaims.

**What is lost:** build history and build numbers reset on each reclaim (~daily) and on any cluster
teardown. This is acceptable, and the repo already demonstrates why:

- **The deploy audit trail is in git, permanently.** 55 `ci: image tag <sha> [skip ci]` commits on
  `master` record what was deployed and when. That record never expires and is untouched by any
  teardown.
- **History was already capped at 20 builds** by `buildDiscarder` / `logRotator` in both the
  `Jenkinsfile` and JCasC. "History" means the last 20 runs, not an archive.
- **Build logs that mattered were already transcribed into git.** `docs/cicd.md` cites build 3 (a
  Trivy finding), build 5 (the Guard catching Jenkins' own commit) and build 17 (the green run after
  a redeploy) as prose. The log was never the record; the written finding is.

**Residual cost, stated plainly:** if a build fails and the pod is reclaimed before the log is read,
that log is gone. In practice a failure is read when it happens.

**Consequence:** the EBS CSI driver is *not* added to the cluster. It was in an earlier draft of this
design solely to back the Jenkins PVC.

### 3. A custom Jenkins image with plugins baked in

A disposable controller restarts about daily. The official chart downloads its plugin set from
`updates.jenkins.io` at every startup — acceptable monthly, wasteful daily, and it makes CI depend on
a third-party site being reachable.

**So the controller image is built from `jenkins/jenkins:lts` with `jenkins-plugin-cli` baking in
`plugins.txt`, and pushed to ECR** as a fifth repository alongside `backend`, `worker`, `nginx` and
`backup`. Startup becomes seconds and requires no internet.

**How it is rebuilt.** The Jenkins image is **not** part of the per-commit pipeline — that pipeline is
gated on `services/**` (G3) and its `ECR_REPOS` list stays at four, so `images-exist.sh` and the G1
guard are unaffected. The controller image is built out-of-band with `scripts/build-push-ecr.sh`
whenever `plugins.txt` or `ci/jenkins/Dockerfile` changes, which is rare. This also resolves the
chicken-and-egg: the first image is built by hand before Jenkins exists in the cluster at all.

**Side benefit.** `plugins.txt` documents (lines 7–11) that versions are deliberately unpinned, whose
stated cost is that "two builds of the same commit can install different plugin versions". Once the
plugins live in an immutable ECR image, **the image tag is the pin**: the file stays unpinned and
readable, while what runs in the cluster is exactly reproducible. `jenkins-plugin-cli --list` output
is captured at image-build time.

### 4. Plugin set: 8 in, 8 out

| Plugin | Change | Reason |
|---|---|---|
| `configuration-as-code` | keep | More load-bearing than before — the only thing that rebuilds a disposable controller |
| `job-dsl` | keep | The `jobs:` block |
| `workflow-aggregator` | keep | Declarative pipeline |
| `git` | keep | SCM checkout |
| `github` | keep | `githubPush()` and the webhook secret |
| `ssh-agent` | keep | G4, the tag-bump push — unaffected by this migration |
| `timestamper` | keep | `options { timestamps() }` |
| `credentials-binding` | **drop** | Its own comment concedes the `Jenkinsfile` does not use it and it is kept speculatively |
| `kubernetes` | **add** | Pod agents. The one genuinely new plugin |

`workflow-aggregator` is deliberately **not** trimmed into its constituent plugins. Doing so means
maintaining a dependency graph by hand that breaks silently on upgrade, and the file's own header
chose the opposite: top-level entries only, `jenkins-plugin-cli` resolves the rest.

`docker-workflow` stays excluded, but its justification comment must be rewritten: the current reason
("the Jenkinsfile shells out to the `docker` CLI") stops being true.

**On plugin-vs-cluster version:** there is no version-matching rule between the `kubernetes` plugin
and the EKS minor version, and nothing like `kubectl`'s ±1 skew policy. Agent pods use the `v1` API.
What does age is the bundled fabric8 client's **streaming protocol** support — see §7. The rule is
"keep the plugin current and re-check it when bumping EKS", which belongs on the existing version
checklist in `docs/maintenance.md`.

### 5. Building images without a Docker daemon: rootless BuildKit

Three options exist; two are ruled out by commitments already made.

**Docker-in-Docker — rejected.** Requires `privileged: true`. The requirements brief lists under
*mandatory* container security: non-root, **no privilege escalation**, minimal capabilities. A
privileged pod that builds the images for an application whose every container sets
`allowPrivilegeEscalation: false` would be the weakest point in the submission. Rejected on stated
requirements, not on effort.

**Kaniko — rejected.** Google archived `GoogleContainerTools/kaniko` on 2025-06-03: read-only, no
commits, no CVE fixes. Chainguard maintains a fork, but it receives no new features. Building a
pipeline whose purpose includes a vulnerability gate on top of an abandoned tool is a contradiction.

**Rootless BuildKit — chosen.** `moby/buildkit:rootless` runs as UID 1000 with no privileged flag,
is maintained by the Moby project, and is the documented migration target from Kaniko. It needs
`BUILDKITD_FLAGS: --oci-worker-no-process-sandbox`.

**The pipeline becomes build → scan the tarball → push the tarball**, which is a strictly stronger
gate than today's. BuildKit exports an OCI archive to disk; Trivy scans that file; `skopeo copy`
uploads the same file. Today's flow builds, scans a local image and then pushes, quietly assuming
those are identical bytes. Under the new flow **the scanned artifact and the pushed artifact are the
same file**, because nothing is rebuilt between the two steps. Nothing reaches ECR before the scan
passes.

**BuildKit runs as a sidecar container in the agent pod**, not as a shared cluster-wide Deployment. A
shared daemon would keep a warm local cache but puts a stateful component on a Spot node that is
reclaimed about daily — reintroducing exactly the problem §2 removes. With the registry-backed cache
below, cache warmth no longer depends on any pod surviving, so the stateless option loses nothing.

### 5a. Build caching — the one genuine regression, and its fix

The EC2 host is persistent and therefore holds a warm Docker layer cache and a warm Trivy database
between builds. **Pod agents start cold every time.** Left unaddressed this migration makes builds
slower and reintroduces a rate-limit risk. Both caches move from local disk to ECR, which ends up
more robust than the host cache it replaces.

**Layer cache → ECR.** BuildKit exports and imports cache through a registry:

```
--export-cache type=registry,ref=$ECR_REGISTRY/$CLUSTER_NAME-buildcache:<svc>,mode=max
--import-cache type=registry,ref=$ECR_REGISTRY/$CLUSTER_NAME-buildcache:<svc>
```

> **This collides with a deliberate setting.** `terraform/ecr.tf:10` sets
> `image_tag_mutability = "IMMUTABLE"` across the `for_each` set, because git-SHA tags are unique and
> immutability prevents a silent overwrite. **Cache tags must be overwritable** — they are rewritten
> on every build by design. The cache repository is therefore a **separate `aws_ecr_repository`
> resource with `MUTABLE` tags, deliberately outside `local.ecr_repos`.** It must not be added to
> that set, or every build fails its cache export. A lifecycle policy expires cache blobs so the
> repository does not grow without bound.

**Trivy database → ECR.** The existing `TRIVY_CACHE` host mount cannot simply become a pod volume: a
pod volume dies with the build, so it would not be a cache at all, and the ~100 MB database would be
re-downloaded on each of four scans, every build — the precise ghcr.io rate-limit risk the original
comment exists to prevent. Instead Trivy pulls the database from an OCI registry of our choosing:

```
trivy image --db-repository $ECR_REGISTRY/$CLUSTER_NAME-trivy-db --input /images/<svc>.tar
```

This is **better than the status quo**: in-region, no rate limit, and no build-time dependency on a
third-party host. A scheduled job mirrors the upstream database into that repository; if the mirror
is stale, Trivy warns rather than failing open silently — treat a stale-DB warning as a build
failure, not a nuisance.

### 6. `Jenkinsfile` changes

**Top:** `agent any` becomes a `kubernetes` agent with a pod template declaring containers
`buildkit`, `trivy`, `skopeo` and `aws-cli`, plus a shared `emptyDir` at `/images` for the tarballs.
There is **no** cache volume — both caches live in ECR (§5a).

**The pod template lives in the `Jenkinsfile`, not in JCasC.** JCasC declares only the Kubernetes
*cloud* — how to reach the API server, which namespace, which ServiceAccount, agent defaults. Which
containers and image versions a build needs is part of *how to build*, and the 2026-07-20 design
committed to that split explicitly: "everything about HOW to build lives in the Jenkinsfile, in the
repository. This block only says where to find it and when to run it." Splitting the two by accident
is how a project acquires two sources of truth for one thing.

**Agent and controller sizing.** Measured headroom on 2026-07-30 with the full stack running (app,
Prometheus, ArgoCD, controllers) on two `t3.large` nodes:

```
node A: cpu 625m/2000m requested (32%), memory  583Mi/~7.3Gi (8%)
node B: cpu 875m/2000m requested (45%), memory 1207Mi/~7.3Gi (16%)
```

So roughly 1 vCPU and 6 GiB are free per node. Starting points: controller `250m`/`1Gi` requested,
agent pod `500m`/`2Gi` across its containers. Both fit on the existing nodes without scaling, and the
Cluster Autoscaler (max 4) absorbs a concurrent burst — though `disableConcurrentBuilds()` means
there is normally only ever one agent.

**Four stages change in mechanism:**

| Stage | Lines (pre-change) | Change |
|---|---|---|
| `Build images` | 100–116 | Four `docker build` → four `buildctl build --output type=oci,dest=/images/<svc>.tar` |
| `Trivy scan` | 118–147 | `docker run` + two `-v` mounts → `trivy image --input /images/<svc>.tar`. Severity gate, `--ignore-unfixed`, and the backend/worker/nginx-blocking vs backup-report-only split are all unchanged |
| `Push to ECR` | 149–162 | `docker push` → `skopeo copy oci-archive:/images/<svc>.tar docker://...`. The `docker login` on line 108 disappears; credentials pass per-copy |
| `post { always }` | 208–212 | **Deleted.** `docker image prune` (G5) exists because the EC2 host is persistent. A pod agent is destroyed after every build |

The `TRIVY_CACHE` environment variable and its host mount are **removed**, replaced by
`--db-repository` (§5a). Do not "port" the mount to an `emptyDir`: that silently converts a
cross-build cache into a per-build one and restores the rate-limit exposure the original comment
warns about.

**Four stages are untouched**, and this is the payoff from extracting the guards into `scripts/ci/`:

| Stage | Line | Why it survives |
|---|---|---|
| `Guard: is this our own commit?` | 43 | Pure git + `should-skip-build.sh` |
| `Resolve tag and account` | 67 | `git rev-parse` + `aws sts` |
| `Already built?` | 89 | `images-exist.sh`, ECR API only |
| `Bump image tag` | 165 | `sed` + `git push` via `sshagent` |

The logic that is dangerous to get wrong (G2, the infinite-build-loop guard) is the logic that does
not move, and its offline test still covers it. The rewritten parts are mechanical, where a mistake
fails the build loudly instead of looping silently.

### 7. Identity and RBAC

**AWS permissions split, and get narrower than today.** The current single instance profile holds
both ECR push and Secrets Manager read.

| Component | AWS permissions |
|---|---|
| Jenkins controller | **none** |
| Jenkins agent pods | ECR push only, via IRSA — same ARN pattern (`${cluster_name}-*`) as the retired instance profile |
| Secrets Manager read | ESO's existing role, not Jenkins' |

**Kubernetes permissions: a namespace-scoped `Role` in `ci` only.** No ClusterRole, no
`cluster-admin`, no access to `devops-app`. Verbs: create/delete/get/list/watch on `pods`, get on
`pods/log`, and **both `create` and `get` on `pods/exec`**.

> **Gotcha — `pods/exec` needs two verbs, not one.** Every step in a pod agent runs through exec: it
> is how the plugin executes shell commands inside the `buildkit`, `trivy` and `skopeo` containers. A
> SPDY exec upgrade is an HTTP **POST** and authorises as `create` on `pods/exec`; a WebSocket
> upgrade is an HTTP **GET** and authorises as `get`. Kubernetes 1.36 adds the
> `ExtendWebSocketsToKubelet` gate (beta, default on) and an
> `AuthorizePodWebsocketUpgradeCreatePermission` gate that layers a synthetic check back on top,
> precisely because this changes which permission an exec requires. Granting only one verb produces a
> build that fails with a 403 on its first `sh` step, with nothing visibly wrong in the pod.

**1.36 does not break the plugin.** SPDY is not removed: the API server proxies WebSocket
`exec`/`attach`/`port-forward` to the kubelet, which performs the WebSocket-to-SPDY translation. The
transition moved a layer down rather than dropping anything.

### 8. Network exposure

Today: a public IP on port 8080 exposes **the entire Jenkins UI** to GitHub's CIDR ranges over
**plaintext HTTP**, documented as accepted residual risk in `terraform/jenkins/main.tf:41-47`. An
Elastic IP keeps the webhook address stable.

All four pieces change, three for the better:

- **Only `/github-webhook/` is routed.** The Ingress exposes that path and nothing else, so the UI,
  script console and credential store are not reachable from the internet — the ALB has no route to
  them. This closes the accepted risk rather than porting it.
- **HTTPS via ACM.** A small certificate for `jenkins.<app_domain>`. Terraform passes its ARN
  directly into the `helm_release` values, so **`sync-values-from-tf.sh` stays at ten managed
  fields** — no new managed field, no new drift surface.
- **external-dns replaces the Elastic IP.** `jenkins.<app_domain>` is a stable name that survives a
  cluster rebuild, doing the EIP's job for free.
- **UI access becomes `kubectl port-forward -n ci svc/jenkins 8080:8080`**, retiring the SSH key
  pair, the tunnel, and `admin_cidr` — including re-applying Terraform when the maintainer's ISP
  reassigns their IP.

**One ALB, shared.** A second ALB would cost ~$18/month and make this migration cost more than it
saves. The Jenkins Ingress therefore joins the application's ALB via
`alb.ingress.kubernetes.io/group.name`.

> **Accepted cost (approved 2026-07-30):** adding `group.name` to the application's existing Ingress
> makes the AWS Load Balancer Controller **replace the ALB**. `voteball.latnook.com` will be
> unreachable for roughly 2–5 minutes during that change. This is a scheduled, one-time disruption.

**Behaviour change:** webhooks are currently discarded while the instance is stopped, so pushes only
build when the host has been started. In the cluster Jenkins is always running, so **every push to
`master` touching `services/` builds.** That is correct CI behaviour and is called out because it
differs from the status quo.

**Egress — the NetworkPolicy in `ci`.** The EC2 host's security group allows unrestricted egress, and
`terraform/jenkins/main.tf:64-66` documents why: ECR, GitHub, Docker Hub and ghcr.io all publish wide,
shifting ranges, so an allowlist there would be brittle rather than secure. That reasoning still holds
for *IP-based* rules, so the NetworkPolicy is written the other way round — **broad egress to the
internet, with specific denials that actually matter**:

| Destination | Policy |
|---|---|
| RDS security group / the isolated DB subnets | **Deny** |
| `devops-app` namespace pods | **Deny** |
| `kube-system` (except DNS) | **Deny** |
| Internet (ECR, GitHub, registries) | Allow |
| DNS | Allow |

That is a meaningful tightening over the current unrestricted egress, and it is the enforceable half
of the claim in §1. The denials are what a reviewer would actually check; an IP allowlist for
registry endpoints would be theatre that breaks on the next range change.

**IRSA scope is unchanged by §5a.** The ECR push policy is written as the ARN pattern
`repository/${cluster_name}-*`, which already covers `-buildcache` and `-trivy-db`. No widening is
needed — the pattern that made the old stack independent of the main one pays off again here.

### 9. Secrets

Unchanged in substance. The same `voteball/jenkins` secret in Secrets Manager, the same keys
(`JENKINS_ADMIN_USER`, `JENKINS_ADMIN_HASH`, `GITHUB_DEPLOY_USER`, `GITHUB_DEPLOY_KEY`,
`GITHUB_WEBHOOK_SECRET`), seeded by the same `scripts/seed-jenkins-secret.sh`.

What changes is the delivery path: **ESO syncs it into a Kubernetes Secret in `ci`**, mounted as
environment variables on the controller pod, instead of `user_data.sh` fetching it via the instance
profile and writing one file per value. The one-file-per-value mechanism existed because the deploy
key is multi-line and its trailing newline is load-bearing; a Kubernetes Secret carries multi-line
values natively, so that workaround is retired.

**The trailing-newline requirement on `GITHUB_DEPLOY_KEY` still stands.** A key without it cannot be
loaded by OpenSSH, and the resulting error is `Permission denied (publickey)`, which reads like an
authorisation problem and is not.

### 10. Cost

| | Now | After |
|---|---|---|
| EC2 `t3.medium` (kept stopped) | ~$2.50/mo | — |
| Elastic IP | ~$3.60/mo | — |
| 30 GB root volume | ~$2.40/mo | — |
| Jenkins PVC | — | $0 (no PVC) |
| Load balancer | — | $0 (shared) |
| **Net** | | **~$8/mo saved** |

Agent pods consume node capacity during builds and may briefly trigger the Cluster Autoscaler; on
Spot `t3.large` for ~5-minute builds this is negligible. **The saving is modest and is not the main
justification** — the portfolio story and the removal of a hand-maintained host are.

### 11. Cutover and rollback

Order is not negotiable: **build the in-cluster Jenkins and prove it green first, then destroy
`terraform/jenkins/`.** The reverse leaves no CI while debugging CI.

1. Build and push the Jenkins controller image by hand (`scripts/build-push-ecr.sh`).
2. `terraform apply` the `ci` namespace, IRSA role, RBAC, ACM cert, ESO ExternalSecret and the
   `helm_release`. The old host stays stopped-but-intact.
3. Add `group.name` to the application Ingress. **This is the ALB replacement window.**
4. **Manual step, unavoidable:** repoint the webhook in GitHub repo settings to
   `https://jenkins.<app_domain>/github-webhook/`.
5. Verify (below).
6. Only then: `terraform destroy` the `terraform/jenkins/` stack and delete the directory.

**Rollback** at any point before step 6: start the EC2 instance and repoint the webhook back. The
cutover is only safe because of the 2026-07-21 JCasC work — the deploy key and webhook secret live in
Secrets Manager, not solely in Jenkins' credential store, so destroying the host destroys nothing
irreplaceable. Before that change this would have been a one-way door.

**Do not delete the old root EBS volume until the new pipeline has run green**, and remember it has
`delete_on_termination = false`: it survives `terraform destroy` and must be deleted by hand
afterwards, or it bills indefinitely.

### 12. Repository changes

**Added**

- `ci/jenkins/Dockerfile` — controller image, bakes `plugins.txt`
- `terraform/addon-jenkins.tf` — namespace, `helm_release`, IRSA role, RBAC, NetworkPolicy, ACM cert,
  ExternalSecret. Named to match the existing `addon-*.tf` convention, since Jenkins is now a platform
  add-on like ArgoCD and ESO
- `charts/` — no change; Jenkins is not part of the application chart

**Changed**

- `Jenkinsfile` — pod agent template; four stages rewritten; `post` block deleted
- `casc/jenkins.yaml` → moves into the Helm values. `slaveAgentPort: -1` becomes a real port;
  `numExecutors: 2` becomes `0` (the controller stops building); the GitHub-plugin XML commentary is
  deleted wholesale — the official chart configures the plugin properly, so the
  `hookSecretConfigs` plural/singular trap, the two-files rule and the SHA-256 testing note all go
- `plugins.txt` — `credentials-binding` out, `kubernetes` in; `docker-workflow` exclusion reason
  rewritten
- `terraform/ecr.tf` — three additions: a fifth repository for the Jenkins controller image (inside
  `local.ecr_repos`, immutable like the rest), plus **two separate `MUTABLE` repositories outside
  that set** — `${cluster_name}-buildcache` and `${cluster_name}-trivy-db` (§5a), with a lifecycle
  policy expiring old cache blobs
- `charts/voteball/templates/ingress.yaml` — `group.name` annotation
- `docs/cicd.md` — substantially rewritten
- `docs/security.md` — the accepted "whole UI exposed over plaintext HTTP" risk is removed, not
  reworded
- `docs/deploy.md`, `docs/maintenance.md`, `README.submission.md`, `docs/eks/architecture.md`

**Deleted**

- `terraform/jenkins/` — the entire stack

**`CLAUDE.md` rules that become false and must be removed the same day.** A stale rule is worse than
a missing one; the repo's own doc-drift note records that a doc contradicting itself misdirects
effort worse than an omission does.

| Rule | Fate |
|---|---|
| "`terraform/jenkins/` is a separate stack … never add it to `destroy.sh`" | Delete — the stack is gone |
| "The Jenkins host's AMI foot-gun is DISARMED — don't re-arm it" | Delete — no AMI, no instance |
| "The Jenkins host is configured by JCasC, not by clicking" | Rewrite — still true, different mechanism |
| "The GitHub plugin is configured by XML, not JCasC" (two files, SHA-256, `hookSecretConfigs`) | Delete — the chart handles it |
| "Stop the instance to save money; do not destroy it" | Delete |
| "Do not remove the Guard stage … or `should-skip-build.sh`" | **Keep verbatim** — still the loop guard |
| "Terraform state lives in S3, one key per stack" | Update — `voteball/jenkins.tfstate` is retired |

## Verification

1. `scripts/tests/test-ci-guards.sh` passes unchanged (offline).
2. `helm template` on the Jenkins release renders the JCasC config, and the rendered RBAC is a
   namespace-scoped `Role` — assert no `ClusterRole`/`ClusterRoleBinding` is produced.
3. `kubectl auth can-i --as=system:serviceaccount:ci:jenkins get pods -n devops-app` → **no**.
4. `kubectl auth can-i --as=system:serviceaccount:ci:jenkins create pods/exec -n ci` → **yes**, and
   the same for `get`.
5. A real end-to-end build: push a `services/` change, observe webhook → guard → build → Trivy →
   push → tag bump, then ArgoCD syncing the new tag. **There is no honest substitute for one real
   green build.**
6. A deliberately vulnerable image fails the Trivy gate and **nothing is pushed to ECR** — confirming
   the scan-before-push property of §5.
7. Delete the Jenkins pod; confirm it returns configured from JCasC within ~60 seconds with no
   internet plugin fetch.
8. Confirm `https://jenkins.<app_domain>/` (root path) is **not** reachable, while
   `/github-webhook/` is.
9. **Cache proof:** run the same build twice with no source change. The second run must import layer
   cache from ECR and complete materially faster, and must not download the Trivy database. A second
   build that is as slow as the first means §5a is not working, regardless of whether it went green.
10. From a Jenkins agent pod, confirm the NetworkPolicy denies the RDS endpoint (`nc -z` times out)
    while ECR and GitHub remain reachable.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Spot reclaim kills an in-flight build | Medium, ~daily reclaim rate | Accept and re-run. Pinning to On-Demand costs ~$30/mo and would erase the entire saving |
| **No CI at all while the cluster is destroyed** | Medium | Accepted. ArgoCD is also gone during a teardown, so nothing could deploy anyway. `scripts/build-push-ecr.sh` is the manual fallback and becomes load-bearing rather than a convenience — it must be kept working |
| ALB replacement window | Low, one-time | Scheduled; approved 2026-07-30 |
| `pods/exec` RBAC verb mismatch | Low but obscure | Both verbs granted; §7 records why. Verification step 4 asserts it |
| Jenkins gains cluster access by drift | **High if it happens** | Namespace-scoped `Role` only, NetworkPolicy denying `devops-app` and RDS, verification step 3. Jenkins still never deploys |
| Every push now builds | Low | Intended CI behaviour; noted because it differs from the status quo |
| Cold build cache makes builds slower | Medium | Resolved by §5a: layer cache and Trivy DB both move to ECR. **The cache ECR repo must be `MUTABLE` and outside `local.ecr_repos`** or every build fails its cache export |
| ~~Node disk pressure from four images plus tarballs~~ | **Closed** | Measured 2026-07-30: 18.2 GB allocatable ephemeral storage per node; the four images total 286 MiB compressed (backend 50, worker 64, nginx 22, backup 150). Not a constraint |
| Node CPU/memory pressure from the controller and agents | Low | Measured 2026-07-30: ~1 vCPU and ~6 GiB free per node with the full stack running. Sizing in §6 |

## Decisions confirmed (2026-07-30)

- **Motivation:** portfolio story ("everything on Kubernetes") plus retiring the EC2 host. Cost saving
  is real but modest and not the justification.
- **Build history:** let it go on teardown. Subsequently strengthened to "let it go on every reclaim"
  once the ~daily Spot reclaim rate was measured — the PVC was dropped as a result.
- **ALB:** share one, accept a 2–5 minute scheduled outage on `voteball.latnook.com`.
- **Image building:** rootless BuildKit, as a per-build sidecar. DinD rejected on the project's own
  container-security requirements; Kaniko rejected as archived upstream.
- **Terraform layout:** `terraform/jenkins/` is deleted and Jenkins becomes `terraform/addon-jenkins.tf`
  in the main stack. This deliberately reverses the "never let the CI server be owned by the stack it
  builds for" rule — that rule protected credentials, job config and history, none of which live on
  the host any more.
- **Caching:** both caches move to ECR rather than to any volume. Added after review found that
  porting the `TRIVY_CACHE` mount to a pod volume would have silently turned a cross-build cache into
  a per-build one.
- **Node capacity:** measured rather than assumed; disk risk closed, CPU/memory confirmed ample.
