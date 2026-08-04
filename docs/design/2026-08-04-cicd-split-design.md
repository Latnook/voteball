# Splitting CI from CD: two pipelines, two jobs, one immutable tag between them

Design for *משימה 4 — CI/CD עם Jenkins בתוך Kubernetes* (brief dated 2026-08-03).

The brief's organising principle is a hard boundary:

| Pipeline | Responsible for | Forbidden from |
|---|---|---|
| CI | tests, building images, scanning, tagging, pushing to a registry | deploying to the cluster |
| CD | receiving an existing image tag or digest, deploying, verifying, rolling back | rebuilding the image |

> *כלל קידום גרסה: ה-image שנבדק ב-CI הוא ה-image שנפרס ב-CD. אין לבנות אותו שוב ואין להשתמש ב-latest.*

## Problem

The 2026-07-30 migration (`2026-07-30-jenkins-on-eks-design.md`) put Jenkins in the cluster and
satisfies most of the brief's sections 2 and 6 already. What it does **not** satisfy is the brief's
central requirement, because there is exactly one pipeline.

`Jenkinsfile` today runs seven stages — Guard, Resolve tag, Already built?, Build images, Trivy scan,
Push to ECR, Bump image tag — and ends by committing `image.tag` into `charts/voteball/values.yaml`,
which ArgoCD then syncs. Two things are wrong with that under this brief:

1. **The tag bump is a deploy decision made inside the build pipeline.** Choosing what production runs
   is CD's job. As long as it lives in CI, the two cannot be separated even nominally.
2. **Nothing verifies the deploy.** The pipeline is green the moment the commit lands. Rollout
   success, pod health and site reachability are never checked, so a broken release is discovered by
   visitors. The brief mandates Rollout, Verify, Smoke Test and Failure Handling stages.

Three further gaps, all mechanical:

- **The 153 tests in `services/{backend,worker}/tests/` are never run by the pipeline.** They exist,
  they pass, and CI ignores them entirely. The brief lists Tests as a mandatory CI stage.
- No Validation or Lint/Static Analysis stage, and no Publish Metadata stage recording the pushed
  digest.
- Jenkins home is an `emptyDir`; the brief lists a PersistentVolumeClaim as a mandatory install
  component.

## What already satisfies the brief (do not rebuild these)

Recorded here so the implementation plan does not redo solved work, and so the submission README can
cite it:

- Jenkins runs in a dedicated namespace (`ci`), never `default`, installed as a `helm_release` by
  Terraform (`terraform/addon-jenkins.tf`), pinned to chart 5.9.45 with a pinned controller image tag
  — no `latest` anywhere.
- **Everything is configured as code.** JCasC (`ci/jenkins/jenkins.yaml`) owns plugins, the security
  realm, authorization, the Kubernetes cloud, the agent pod template, both credentials and the job
  definition. UI edits do not survive a restart, and on Spot the controller restarts roughly daily.
- **The controller runs no builds** (`numExecutors: 0`); every build runs on a dynamically-provisioned
  agent Pod that is destroyed at the end.
- **No Docker socket is mounted.** Builds use rootless BuildKit. The `buildkit` container's
  `allowPrivilegeEscalation: true` + `SETUID`/`SETGID` exception is documented and scoped; it is still
  uid 1000, unprivileged, with no host paths or devices.
- Agent pods authenticate to AWS by **IRSA** (ECR push only); the controller carries no AWS role.
- Secrets live in **AWS Secrets Manager**, synced by **External Secrets Operator** into a Kubernetes
  Secret and projected as environment variables. Nothing secret is in git or tfstate.
- **NetworkPolicies** in `charts/jenkins-support` confine the `ci` namespace; it has no route to RDS or
  to `devops-app`.
- **Trivy** scans every image before push, failing the build on HIGH/CRITICAL.
- The webhook Ingress is HTTPS via ACM, and — importantly for section 6 — routes **only**
  `/github-webhook`. The Jenkins UI, script console and credential store have no ALB rule reaching
  them and are unreachable from the internet. Operators use `kubectl port-forward`.
- ArgoCD is itself fully declared in code: `terraform/addon-argocd.tf` plus
  `argocd/voteball-application.yaml.tmpl`, with `scripts/render-argocd-app.sh --check` failing on any
  live/template mismatch or hand-registered credential.

## Non-goals

- **Replacing ArgoCD with `helm upgrade --install` in the CD pipeline.** The brief's example uses
  `helm upgrade`, but it permits any documented mechanism, and the course instructor confirmed
  (2026-08-04) first that ArgoCD is acceptable provided everything is configured as code — which it
  is — and then that the mechanism *"doesn't matter as long as the CI/CD pipeline works"*. A direct
  `helm upgrade` would additionally now fail on server-side-apply field ownership, and would fight
  `selfHeal`. See §7.

- **Dropping `Jenkinsfile-cd` and letting ArgoCD be the whole of CD.** Considered seriously on
  2026-08-04 and rejected. The instructor's licence is about the deploy *mechanism*; the pipeline
  itself is still named as a deliverable in four places (§4 p.5, §5 p.6, §9 item 1 p.10, §10 evidence
  p.11). More importantly the two are not interchangeable: ArgoCD is a **reconciler**, not a deployer.
  It has no concept of a deployment attempt that can fail — only current state versus desired state —
  so it cannot smoke-test the live site, cannot judge a release bad, and will `selfHeal` a broken
  version back into place if anyone corrects it outside git. The verification and rollback the brief
  asks for have to live outside ArgoCD by construction. See §7 and §8.
- **A staging environment.** The brief's promotion and manual-approval items are conditional on one
  existing (*אם קיימת סביבת staging או production*). Voteball is deliberately single-environment; that
  stays.
- **Pull-request pipelines and PR quality gates** (bonus). The repo owner works solo and commits
  straight to `master`; a PR-triggered pipeline would never fire.
- **Rewriting the app, the chart, or the Terraform stack** beyond the additions in §5 and §6.

## Design

### 1. Two pipelines, two jobs, one handoff

Two Jenkinsfiles at the repo root, replacing the single `Jenkinsfile`:

- `Jenkinsfile-ci` → JCasC job **`application-ci`**, triggered by the GitHub push webhook.
- `Jenkinsfile-cd` → JCasC job **`application-cd`**, parameterized, triggered by `application-ci` and
  re-runnable by hand.

The handoff is the brief's second permitted mechanism — *הפעלת CD מתוך build trigger והעברת parameter*.
`application-ci`'s final stage calls:

```groovy
build job: 'application-cd', wait: false, parameters: [
  string(name: 'IMAGE_TAG',    value: env.IMAGE_TAG),
  string(name: 'IMAGE_DIGEST', value: env.BACKEND_DIGEST),
  string(name: 'SOURCE_BUILD', value: env.BUILD_NUMBER),
]
```

`SOURCE_BUILD` exists purely for the brief's traceability requirement: *מתוך build של CD צריך להיות
אפשר לזהות את ה-build ב-CI, ה-Git commit, ה-image וה-digest שהובילו לפריסה.* The CD build description
is set from it, so the CD build page names its originating CI build, the commit, the tag and the digest.

**The Guard stage stays, and moves to CI.** Jenkins has no native `[skip ci]`. Under the split, CD is
what writes the `values.yaml` bump commit, and that commit fires the same push webhook that triggers
CI. Without the guard, CI would build again, trigger CD again, which would commit again — an unbounded
billable loop that also rolls production pods continuously. `scripts/ci/should-skip-build.sh` is
unchanged and keeps its tests in `scripts/tests/test-ci-guards.sh`.

### 2. `Jenkinsfile-ci`

| # | Stage | Behaviour | Origin |
|---|---|---|---|
| 1 | Guard | `scripts/ci/should-skip-build.sh` — abort on our own `[skip ci]` commit | kept (G2) |
| 2 | Checkout | set build description to `branch @ <short-sha> (build #N)` | extended |
| 3 | Validation | `scripts/ci/validate-repo.sh` — every service dir has a `Dockerfile` and a `.dockerignore`; no `FROM …:latest` and no `image: …:latest` anywhere; chart `Chart.yaml` version parses | **new** |
| 4 | Lint / Static Analysis | `ruff check` over `services/backend` and `services/worker`; `hadolint` over all four Dockerfiles | **new** |
| 5 | Tests | `pytest` for backend and worker against a Postgres sidecar (§5); JUnit XML published to Jenkins | **new** |
| 6 | Already built? | `scripts/ci/images-exist.sh` — skip rebuild when the immutable tag is already in ECR | kept (G1) |
| 7 | Build images | rootless BuildKit, four contexts, cache in `${cluster_name}-buildcache` | kept |
| 8 | Trivy scan | fail on HIGH/CRITICAL, DB from `${cluster_name}-trivy-db` | kept |
| 9 | Push to ECR | tag = short commit SHA, capture each image's digest | kept |
| 10 | Publish Metadata | write and `archiveArtifacts` an `image-metadata.json` | **new** |
| 11 | Trigger CD | `build job: 'application-cd'` with the parameters above | **new** |
| — | `post { always }` | `cleanWs()` | **new** |

There is **no deploy stage**, and the `Bump image tag` stage is deleted from CI — it moves to CD (§3).

`image-metadata.json` shape:

```json
{
  "image_tag": "a2ad614",
  "git_commit": "a2ad614f...",
  "ci_build": "42",
  "built_at": "2026-08-04T12:31:00Z",
  "images": {
    "voteball-backend":  { "digest": "sha256:…" },
    "voteball-frontend": { "digest": "sha256:…" },
    "voteball-worker":   { "digest": "sha256:…" },
    "voteball-backup":   { "digest": "sha256:…" }
  }
}
```

**Ordering rationale.** Validation, Lint and Tests run *before* the "Already built?" check and before
any build. They are cheap and they gate everything: a repo whose tests fail must not produce an image
at all, let alone reach the registry. Conversely, "Already built?" must run after them, because on a
re-run of an already-built tag we still want the tests to have passed.

### 3. `Jenkinsfile-cd`

Parameters: `IMAGE_TAG` (required), `IMAGE_DIGEST` (optional), `SOURCE_BUILD` (optional),
`NAMESPACE` (default `devops-app`).

| # | Stage | Behaviour |
|---|---|---|
| 1 | Checkout | chart and scripts only; sets the traceability build description |
| 2 | Input Validation | `IMAGE_TAG` non-empty, **rejects `latest`** and any non-`[0-9a-f]{7,40}` value; `NAMESPACE` must be in an allowlist of one (`devops-app`); `scripts/ci/images-exist.sh` confirms the tag genuinely exists in ECR for all four repos |
| 3 | Manifest Validation | `helm lint charts/voteball`; `helm template … --set image.tag=$IMAGE_TAG`; `kubectl create --dry-run=client -f -` against the rendered output (§4 explains why `create`, not `apply`, and not `=server`) |
| 4 | Authenticate | in-cluster ServiceAccount `jenkins-cd-agent`; `kubectl auth can-i` self-check proves the token works and is scoped (§4) |
| 5 | Promote | rewrite `image.tag` in `charts/voteball/values.yaml`, commit `ci: image tag <sha> [skip ci]`, push to `master` |
| 6 | Deploy | `argocd app sync voteball --timeout 300` — no `--revision` (see the build #3 verification outcome below); Promote already pushed the tag bump to the tracked branch, so syncing it reaches the promoted commit |
| 7 | Rollout | `argocd app wait voteball --sync --health --timeout 300` — ArgoCD's own health model, **not** a reimplementation of it with `kubectl rollout status` |
| 8 | Verify | `argocd app get voteball -o json`: assert `sync.status == Synced`, `health.status == Healthy`, and `sync.revision` equals the promote commit. One `kubectl get deployments,pods,services,ingress -n $NAMESPACE` afterwards **purely to capture the brief's §10 evidence**, not as a second opinion |
| 9 | Smoke Test | `scripts/ci/smoke-test.sh` — HTTPS `GET /health` expecting 200, `GET /api/results` expecting 200 and parseable JSON containing the expected keys, retried with backoff |
| 10 | Failure Handling | on any failure in 6–9: dump `kubectl get events --sort-by=.metadata.creationTimestamp` and the last 200 log lines per Deployment, then **roll back** (§8) and re-verify |
| — | `post { always }` | `cleanWs()` |

Stage 5 sits *after* validation deliberately. Promoting means committing to `master`, which is
externally visible and triggers webhooks; nothing should be committed until the tag is known to exist
and the chart is known to render.

### 4. Two agent pod templates, and the permission split

The brief asks for *template אחד עבור CI ואחד עבור CD*. Two templates, declared in
`ci/jenkins/jenkins.yaml`, each with its own ServiceAccount:

| | `voteball-build` (CI) | `voteball-deploy` (CD) |
|---|---|---|
| ServiceAccount | `jenkins-agent` | `jenkins-cd-agent` (**new**) |
| AWS role (IRSA) | ECR **push** to this account's repos | ECR **read-only** on the four app repos |
| Kubernetes RBAC | none | read-only `Role` in `devops-app` only |
| Containers | `jnlp`, `buildkit`, `tools` (aws-cli, trivy, ruff, hadolint), `postgres` | `jnlp`, `deploy` (argocd CLI, kubectl, helm, aws-cli, curl, jq) |
| Can build an image | yes | no |
| Can write to the cluster | no | **no** — only ArgoCD applies |

Neither can do the other's job, which is the whole point: a compromised build agent can push a junk
image but cannot deploy it; a compromised deploy agent can only ask ArgoCD to sync a commit, and only
of images that already exist and already passed Trivy.

`jenkins-cd-agent`'s RBAC is a namespaced, **read-only** `Role` + `RoleBinding` in `devops-app` — no
`ClusterRole`, no `cluster-admin`, and no write verb of any kind:

- `apps`: `deployments`, `replicasets` — `get,list,watch`
- `""`: `pods`, `services`, `events` — `get,list,watch`
- `""`: `pods/log` — `get`
- `networking.k8s.io`: `ingresses` — `get,list`

There is deliberately **no `patch` on deployments**. An earlier draft granted it for `kubectl rollout
undo`; rollback goes through git (§8), so nothing in CD ever writes to the cluster. That makes the
security claim absolute rather than approximate: *Jenkins holds no permission to change anything in
`devops-app`.* Everything that reaches the cluster goes through ArgoCD, and CD could not bypass it
even if its Jenkinsfile tried.

The read-only ECR role exists for one job — stage 2 proving the requested tag really is in the
registry before anything is committed to `master`. `ecr:DescribeImages` and
`ecr:BatchGetImage` on the four app repositories, nothing else, no push.

`kubectl apply --dry-run=server` in stage 3 would need create permission the CD agent does not have
and must not be given, so the original plan here was `helm lint` + `helm template` + `kubectl apply
--dry-run=client` over the rendered output. The server-side dry run is not worth broad write access
to the app namespace, and ArgoCD — which *does* hold those permissions — performs the real
server-side apply seconds later and fails the sync if the manifests are invalid.

**Verification outcome (application-cd build #1, 2026-08-04): even `apply --dry-run=client` was
wrong, not just `=server`.** The build reached Manifest Validation and failed with `Error from
server (Forbidden): error when retrieving current configuration of:`, repeated once per resource
kind in the chart. The reason is that client-side `apply` is not purely local either — to decide
create-versus-patch it first GETs each object's *current* configuration from the API server, and
`jenkins-cd-reader` can only `get` the seven kinds listed above. Every other kind the chart renders
(`ServiceAccount`, `ConfigMap`, `ExternalSecret`, `HorizontalPodAutoscaler`,
`PodDisruptionBudget`, `NetworkPolicy`, `CronJob`, the migration `Job`) came back Forbidden. The
design's own read-only guarantee for `jenkins-cd-agent` — the thing this section exists to protect —
was the direct cause of the first live pipeline run failing.

The fix, verified for real against the cluster (a minted token *as* `jenkins-cd-agent`, not
cluster-admin — testing as ourselves and assuming the result would generalise is exactly how this
bug got in): `kubectl create --dry-run=client` instead of `apply`. `create` never reads an existing
object, so it needs no RBAC read grant at all beyond the cluster's default discovery/OpenAPI-schema
access that every authenticated identity already has — not anything this Role grants. Run against the
full rendered chart (24 resources) as `jenkins-cd-agent`, it exits 0 with every resource reported
`created (dry run)` and zero Forbidden errors, where `apply --dry-run=client` against the identical
input fails on the first `NetworkPolicy`.

**This narrows the failure window, it does not close it, and that has to be stated plainly rather
than implied.** Also verified for real, not assumed: `create --dry-run=client` catches a chart that
fails to render (via `helm template`'s own exit code, checked first), malformed YAML, a document
missing required top-level fields, and a `kind` the API server doesn't recognise. It does **not**
catch deep per-field schema/type errors — a `Deployment` rendered with `replicas: "not-a-number"`
(string where an int32 is expected) or with a wholly invented `spec.totallyBogusUnknownField` both
still print `created (dry run)` and exit 0, identically whether run as `jenkins-cd-agent` or as
cluster-admin, so this is a property of client-side dry-run itself, not a permission gap the Role
could close. Nor can it catch anything that depends on the *live* object — immutable-field conflicts,
admission-webhook behaviour tied to existing state — since `create` never looks at what already
exists. ArgoCD's real server-side apply, moments later, remains the actual safety net; this stage
narrows what can reach it, and the CD Jenkinsfile's own comment states this rather than leaving the
narrower coverage implicit. The log states which form ran and what it does and does not cover, so
nothing degrades silently.

**Verification outcome (application-cd build #3, 2026-08-04): `--revision` on Deploy was also
wrong.** The build passed Checkout, Input Validation, Manifest Validation and Promote — the tag-bump
commit really did land on `master` — then failed in Deploy with `argocd app sync voteball --revision
"$PROMOTE_SHA" --timeout 300` returning `rpc error: code = FailedPrecondition desc = Cannot sync to
<sha>: auto-sync currently set to master`. The `voteball` Application's `syncPolicy.automated` is set
(`prune: true`, `selfHeal: true`, confirmed both in `argocd/voteball-application.yaml.tmpl` and against
the live Application) with `targetRevision: master`. With automated sync enabled, ArgoCD refuses to pin
a sync to an arbitrary revision — the whole point of automated sync is that it follows the tracked
branch, so a pinned `--revision` is a contradiction of the policy the Application already declares, not
a stricter form of it.

The `--revision "$PROMOTE_SHA"` was over-specification, not extra precision: Promote (stage 5) already
pushed the tag bump to `master` before Deploy runs, so a plain `argocd app sync voteball` — no
revision — syncs `master`, which at that point *is* the promoted commit. This was confirmed live: even
though the CLI call failed, ArgoCD's own automated sync picked up the promoted commit on its own and
rolled the Deployments to the new tag without Jenkins' help. The fix removes `--revision` and keeps the
`sync` call itself, which still forces an immediate reconciliation instead of waiting out the polling
interval. **The right response to the rejection is not to disable automated sync so `--revision` can be
readded** — `selfHeal` is what keeps the cluster matching git between deploys, and giving that up to
regain a redundant flag would be a worse trade than the flag was worth. The Verify stage's assertion
that `status.sync.revision` equals `$PROMOTE_SHA` is unchanged and is now the sole thing confirming
ArgoCD landed on *this* build's commit rather than a newer one that raced in before reconciliation.

The ArgoCD CLI authenticates with a dedicated ArgoCD **local account** (`jenkins-cd`) declared in
`terraform/addon-argocd.tf`'s `argocd-cm`, granted only `applications, sync/get/action` on
`voteball/voteball` in `argocd-rbac-cm`. Its token is stored in Secrets Manager alongside the existing
Jenkins secrets and reaches the pod through the existing ESO ExternalSecret — no new secret mechanism.

**Verification outcome (application-cd builds #5 and #6, 2026-08-04): the RBAC policy was still one
resource short.** Both builds got through Checkout, Input Validation, Manifest Validation, Promote,
Deploy and Rollout — the deploy itself genuinely succeeded — then failed in Verify with `rpc error:
code = PermissionDenied desc = permission denied: projects, get, voteball, sub: jenkins-cd`. `argocd
app get` does not only read the Application; it also resolves and reads the AppProject the Application
belongs to (named `voteball`, confirmed against `argocd/voteball-application.yaml.tmpl`), and the
policy granted `applications, get/sync` on `voteball/voteball` but nothing on `projects`. The fix is
one additional line, `p, role:jenkins-cd, projects, get, voteball, allow` — read-only, scoped to the
single project this account's Application lives in, no `update`/`delete`/`create`, no wildcard. Same
lesson as the build #1 outcome above: a permission grant scoped to "the one Application it deploys"
still has to account for everything a read of that Application transitively touches, not just the
Application object itself.

### 5. Running the tests needs a real Postgres

`services/backend/tests/conftest.py` and `services/worker/tests/conftest.py` connect to a real
Postgres and `DROP TABLE … CASCADE` a list of tables between tests; they are not sqlite-compatible and
were never intended to be. To run them on an agent, the CI pod template gains a `postgres:16-alpine`
sidecar container listening on localhost, with `DB_SSLMODE=disable` (the production default is
`require`; the tests already override it).

The sidecar is ephemeral, holds no real data, and is destroyed with the pod. It is reachable only from
inside the pod's own network namespace, so the `ci` NetworkPolicies are unaffected and no route to the
real RDS instance is created or needed.

**Both `conftest.py` `DROP TABLE` lists must stay in step with the eight rollup tables** — that
constraint predates this design and is unchanged, but a CI stage that actually runs the tests is the
first thing that will catch a drift between them.

### 6. Jenkins home on EFS, not EBS

The brief lists persistent storage for Jenkins home via PVC as mandatory. `2026-07-30-jenkins-on-eks-design.md`
§2 rejected a PVC and set `persistence = { enabled = false }`, for a good reason: the node group is
100% Spot and reclaimed roughly daily, and an **EBS volume is locked to one Availability Zone**, so
every reschedule must land back in that AZ or the pod hangs `Pending` indefinitely — the one failure
mode in the design that needs a human.

That reasoning is specific to EBS. **EFS is a network filesystem reachable from every AZ in the VPC**,
so it carries none of the AZ-lock risk while satisfying the requirement. New file
`terraform/addon-efs.tf`:

- `aws_efs_file_system` with encryption at rest and lifecycle transition to Infrequent Access at 30
  days;
- `aws_efs_mount_target` in each private subnet;
- a security group allowing TCP 2049 **from the node security group only**;
- `aws_eks_addon "aws-efs-csi-driver"` with its IRSA role;
- a `StorageClass` in EFS access-point mode;
- `persistence` in `terraform/addon-jenkins.tf` flipped to `{ enabled = true, storageClass = "efs-sc",
  size = "8Gi", accessMode = "ReadWriteOnce" }`.

Cost is roughly $1–2/month at this size — EFS bills per GB stored plus per GB of throughput, and a
Jenkins home with plugins baked into the image and build retention capped at 20 is small and nearly
idle.

**What this changes and what it does not.** Build history now survives a Spot reclaim. What does *not*
change is the disposability principle: JCasC remains the source of truth, the controller still rebuilds
itself entirely from code, and losing the volume is still a recoverable event rather than a disaster.
The durable record of what was deployed remains the `ci: image tag <sha> [skip ci]` commits on
`master`, which never expire. Nothing in the design starts depending on the volume's contents.

### 7. ArgoCD stays the applier

The CD pipeline orchestrates and verifies; ArgoCD performs the apply. Three reasons, in order of
weight:

1. **A direct `helm upgrade` would now fail.** ArgoCD owns the release with server-side apply; a
   manual upgrade loses on field ownership. This is recorded in `charts/voteball/CLAUDE.md`.
2. **`selfHeal` would fight it.** ArgoCD reconciles `charts/voteball` against `master`. A Jenkins-applied
   change that differed from git would be reverted within the reconciliation window, producing a green
   pipeline and an un-deployed change.
3. **It is a stronger answer to the brief's own criteria**, not a weaker one. The instructor's
   condition (2026-08-04) was that everything be configured as code; ArgoCD here is declared in
   Terraform plus one rendered template, with `render-argocd-app.sh --check` failing the build on any
   UI-made drift — including a hand-registered repo or cluster credential. Nothing is clicked.

**The division of labour, stated plainly for the README:** ArgoCD applies; Jenkins CD decides and
verifies. Everything that reaches the cluster still goes through ArgoCD — Jenkins holds no permission
to apply the chart and could not bypass it. This is the conventional GitOps split, not a workaround.

**The governing rule (decided 2026-08-04): whatever ArgoCD can do, ArgoCD does. Jenkins does only what
ArgoCD structurally cannot.** Applied literally, that is a short list on each side:

| Job | Owner | Why |
|---|---|---|
| Apply manifests to the cluster | **ArgoCD** | It already does, with server-side apply and field ownership. Jenkins has no write permission at all. |
| Decide when a resource is healthy | **ArgoCD** | It has a health model per resource kind. `kubectl rollout status` on three Deployments would be a worse copy of it. |
| Keep the cluster matching git | **ArgoCD** | `selfHeal`. Nothing in CD tries to hold the cluster in a state git disagrees with. |
| Reconcile drift, prune removed resources | **ArgoCD** | Continuous, not per-build. |
| Refuse a tag that is `latest` or absent from ECR | **Jenkins** | ArgoCD deploys whatever git says; it has no notion of an invalid request. |
| Decide *which* tag git should name | **Jenkins** | Only CI knows what it just built and tested. |
| Ask the live site over HTTPS whether it works | **Jenkins** | ArgoCD checks pod health, never the product. Healthy pods serving a broken site is `Healthy` to ArgoCD. |
| Judge a release bad and revert git | **Jenkins** | ArgoCD has no concept of a failed deployment attempt — only of drift, which it would *undo*. |
| Link commit → tests → digest → deployment | **Jenkins** | Build records are a CI/CD artifact; ArgoCD keeps sync history, not provenance. |

The practical consequence in `Jenkinsfile-cd`: stages 6, 7 and 8 are three `argocd` CLI calls, not a
hand-rolled rollout loop. The only `kubectl` in the happy path is one read to capture the evidence the
brief's §10 requires. If a stage could be written either as ArgoCD delegation or as Jenkins logic,
it is written as delegation.

The README must state this explicitly, since the brief's worked example shows `helm upgrade --install`
and a grader will look for it.

### 8. Rollback

Decided 2026-08-04: **automatic, on any failure in Deploy, Rollout, Verify or Smoke Test.**

The previous tag is read from `git log` on `charts/voteball/values.yaml` — the last `ci: image tag`
commit before the one this build just wrote. Rollback then re-runs the same promote-and-sync path with
that tag, so there is exactly one code path that changes what production runs, whether it is going
forward or backward. After rolling back, stages 7–9 re-run; if verification fails *again*, the
pipeline stops and reports, since a second failure means the problem is not the new image.

The alternative — `argocd app rollback`, which reverts to a previous ArgoCD history entry without
touching git — was rejected because it leaves `master` asserting a version the cluster is not running.
`selfHeal` would then reapply the bad tag at the next reconciliation. Rolling back *through git* keeps
git as the single source of truth.

**Rollback is also what makes CD safe to re-run by hand**: pointing `application-cd` at any older tag
is the documented manual rollback procedure, and it is the same machinery.

### 9. Deliverables

Brief section 9 lists ten required files. Mapping:

| Brief item | Here |
|---|---|
| 1. `Jenkinsfile-ci`, `Jenkinsfile-cd` | repo root; `Jenkinsfile` deleted |
| 2. Helm values / manifests for Jenkins | `terraform/addon-jenkins.tf`, `terraform/addon-efs.tf`, `charts/jenkins-support/` |
| 3. JCasC, plugin list, agent pod templates | `ci/jenkins/jenkins.yaml` |
| 4. ServiceAccounts + RBAC for Jenkins and deploy | `charts/jenkins-support/templates/rbac.yaml` (**new**) |
| 5. Job DSL / seed job creating both jobs | `jobs:` block of `ci/jenkins/jenkins.yaml` |
| 6. Dockerfiles and image build files | `services/*/Dockerfile`, `ci/jenkins/Dockerfile` |
| 7. App Helm chart | `charts/voteball/` |
| 8. Install, verify and cleanup scripts | `scripts/jenkins/{install,verify,uninstall}-jenkins.sh` (**new**) |
| 9. Architecture diagrams | `docs/eks/architecture.md` — Deployment View and Pipeline Flow, Mermaid |
| 10. Evidence folder | `docs/eks/evidence/2026-08-04-task4-*.txt` + `docs/screenshots/` |

Plus the brief's section 6 example files, which must show shape without values:
`charts/jenkins-support/values.example.yaml` and `ci/jenkins/secret.example.yaml` (**new**).

**On the lifecycle scripts.** Jenkins is a platform add-on owned by Terraform, so `install` and
`uninstall` are thin, honest wrappers around `terraform apply`/`destroy -target`, not a parallel
install path — a second way to install Jenkins would be a lie about how this repo works.
`verify-jenkins.sh` is the substantial one: it runs the brief's whole section-10 checklist
(`kubectl get namespaces`, `pods -n ci -o wide`, `service,ingress,pvc -n ci`,
`serviceaccount,role,rolebinding -n ci`, `helm list -n ci`) and asserts on the results — controller
Ready, no build running on the controller, both jobs present, PVC Bound — exiting non-zero on any
failure, rather than printing output for a human to eyeball.

Documentation changes: `docs/cicd.md` rewritten for two pipelines; a task-4 section in
`README.submission.md` covering install/configure/verify/uninstall, both pipelines, the rollback
procedure and the security writeup; and `CLAUDE.md` updated where it describes a single `Jenkinsfile`.

## Verification

Every item below produces a file in `docs/eks/evidence/` or `docs/screenshots/`:

1. `scripts/tests/test-ci-guards.sh` and `scripts/tests/test-sync-values.sh` pass offline.
2. `helm lint` and `helm template` clean for `charts/voteball`, `charts/jenkins-support`.
3. `terraform validate` and `terraform fmt -recursive` clean.
4. `verify-jenkins.sh` exits 0 against the live cluster, with the PVC now `Bound`.
5. A real push to `master` triggers `application-ci`: tests visible in the Jenkins test report, images
   built, Trivy clean, digests recorded in the archived `image-metadata.json`.
6. `application-cd` fires automatically with the tag as a parameter, promotes, syncs, and its smoke
   test passes. Its build description names the CI build, commit, tag and digest.
7. **Rollback demonstrated for real** (decided 2026-08-04): deploy a backend image whose health
   endpoint deliberately fails, watch stage 10 detect it, roll back to the previous tag automatically,
   and re-verify green. The public site is degraded for the few minutes this takes; that is accepted,
   because evidence that the mechanism fires is worth more than evidence that it compiles.
8. A CI failure blocks deploy: push a deliberately failing test and confirm `application-cd` never
   runs.
9. `render-argocd-app.sh --check` still passes — the ArgoCD `Application` is unchanged by any of this.

## Risks

| Risk | Mitigation |
|---|---|
| The rollback demo leaves the site broken if rollback itself is buggy | Rehearse stage 10 against a *healthy* deploy first (roll back to the previous good tag by hand and back again); only then run the deliberately-broken one. `scripts/build-push-ecr.sh` can restore any tag without CI if both pipelines are wedged. |
| CD's git push races the webhook, retriggering CI | Existing Guard (G2) stage, already proven — `docs/cicd.md` build 5 is the webhook firing on Jenkins' own commit and being stopped by it. |
| Postgres sidecar makes CI agents slower/heavier to schedule | Sidecar is `postgres:16-alpine` with modest requests; the node group autoscales. If scheduling latency becomes a problem the tests can move to their own template. |
| EFS mount target security group misconfigured, exposing NFS | SG allows 2049 from the node SG only, and the mount targets sit in private subnets with no internet route. |
| Adding the EFS CSI driver disturbs the running cluster | Additive `aws_eks_addon`; the only restart is the Jenkins StatefulSet picking up its new volume. No app namespace change, no RDS change, no rebuild. |
| Two Jenkinsfiles drift apart on shared logic | Shared logic already lives in `scripts/ci/*.sh` and stays there; both pipelines call the same scripts, which have offline tests. |
| A grader looks for `helm upgrade --install` and does not find it | §7's reasoning is stated explicitly in `README.submission.md`, citing the instructor's 2026-08-04 confirmation. |

## Decisions taken (2026-08-04)

- **EFS-backed PVC** for Jenkins home, over keeping `emptyDir` or pinning a node group to one AZ for
  EBS. Satisfies the brief without reintroducing the AZ-lock failure mode.
- **Automatic rollback** on smoke-test failure, over stopping and alerting.
- **Rollback demonstrated by really breaking the live site**, over demonstrating the mechanism on a
  healthy version.
- **ArgoCD retained as the applier**, on the instructor's confirmation that as-code configuration is
  what matters.
- **"Whatever ArgoCD can do, ArgoCD does"** as the governing rule for the CD pipeline, stated by the
  repo owner. Jenkins CD is scoped to exactly what a reconciler cannot do. Consequences already
  applied above: rollout waiting delegates to `argocd app wait` instead of `kubectl rollout status`
  (§3); verification reads ArgoCD's own sync and health status rather than re-deriving it (§3); the
  CD ServiceAccount's `Role` lost its `patch` verb and is now strictly read-only, so Jenkins holds no
  write permission anywhere in `devops-app` (§4).
