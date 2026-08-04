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
| 6 | Deploy | `argocd app sync voteball --timeout 600` — no `--revision` (see the build #3 verification outcome below); Promote already pushed the tag bump to the tracked branch, so syncing it reaches the promoted commit |
| 7 | Rollout | `argocd app wait voteball --sync --health --timeout 600` — ArgoCD's own health model, **not** a reimplementation of it with `kubectl rollout status` |
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

**Verification outcome (application-cd build #10, 2026-08-04): 300s was too tight for a cold-image
first deploy, and the failure mode is a false rollback, not just a slow one.** Build #9 deployed tag
`241bed6` and went fully `Synced`/`Healthy` in about 90 seconds. Build #10 deployed tag `9474665`,
built by CI moments earlier — none of its four images had ever been pulled onto the (100% Spot, small)
node group, so the rollout had to pull all four before any pod could go Ready, and it did not finish
inside Deploy's `--timeout 300`. The build failed with `timed out (300s) waiting for app "voteball"
match desired state`, which is not a benign slow-path: a failed Deploy stage trips the automatic
rollback in `post > failure` (§8) exactly as if the deploy were actually broken. It was not — ArgoCD
reached `Synced`/`Healthy` on its own shortly after, and all four `9474665` images were confirmed
present in ECR throughout. So the pipeline would have reverted a perfectly healthy deploy purely
because image pulls were slower than a budget sized around warm-image runs.

The fix raises both `argocd app sync --timeout` and `argocd app wait --timeout` from 300 to 600, large
enough to cover a cold-image first deploy with room to spare. That alone would not have been enough:
the pipeline's own `options { timeout(time: 20, unit: 'MINUTES') }` wraps the whole run, and 600s +
600s for Deploy and Rollout alone is already 1200s — the entire old 20-minute budget, with nothing left
for the other six stages. A pipeline-level timeout firing mid-rollout is the same false-rollback
failure by a different route, so the fix raises that budget too, to 30 minutes. The other six stages
combined have never been observed anywhere near 10 minutes — build #9's entire pipeline, all eight
stages, went green in ~90s with warm images — so 30 minutes leaves a comfortable cushion over the
1200s worst case for Deploy+Rollout alone.

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

## Verification outcome (2026-08-04)

**Eleven distinct defects surfaced only by actually running both pipelines against the live
cluster.** None were caught by `helm lint`, `terraform validate`, `hadolint` run outside CI, or
reading either Jenkinsfile before running it. §4 above already carries the full narrative for three
of them (the ArgoCD/RBAC failures on `application-cd`'s first live runs); this section is the
complete, ordered list, including the eight that have no write-up anywhere else. They are recorded
here in the order they were hit, because that is also the order a rebuild would hit them again if any
one fix in this list were ever reverted.

1. **`ruff` installed but not runnable — exit 127.** The Lint / Static Analysis stage runs as uid
   1000 with `HOME=/tmp`; `pip install --quiet ruff` succeeds but installs to `~/.local/bin`, which
   nothing puts on `PATH` in that container. Bare `ruff check` then failed with "ruff: not found" —
   reading like the install itself failed, not like a `PATH` problem. Fixed by invoking `python -m
   ruff check services/backend services/worker` instead, which runs the installed module directly and
   needs no `PATH` entry.
2. **`pg_isready` is not in `python:3.12-slim`.** The Tests stage's wait-for-Postgres loop was
   written around `pg_isready`, which ships with postgres-client packages this slim base image
   doesn't carry. Replaced with a stdlib TCP-connect loop
   (`python3 -c "import socket,sys; s=socket.socket(); ...; s.connect_ex(('localhost',5432))"`), which
   needs nothing beyond the interpreter already in the image and asks exactly what the loop needs to
   know: has the sidecar opened its listening socket.
3. **`cleanWs()` needs the `ws-cleanup` plugin, absent from the controller image.** Both
   `post { always }` blocks originally called `cleanWs()`; `ws-cleanup` is not in
   `ci/jenkins/plugins.txt`, and adding it means rebuilding the controller image. Replaced with
   `deleteDir()`, a Jenkins-core step needing no plugin, with the same practical effect.
4. **`junit` needs the JUnit plugin, also absent.** The Tests stage's `junit '*-tests.xml'` step
   failed with `NoSuchMethodError` for the same missing-plugin reason. Replaced with
   `archiveArtifacts artifacts: '*-tests.xml', allowEmptyArchive: false`. The test **gate** was never
   this step — it is pytest's own exit code under `set -eu` — so this loses only the per-test report
   view in Jenkins' UI, not any of what actually blocks a bad build from proceeding.
5. **Six genuine `ruff` violations, once it could actually run.** Two unused imports and four uses of
   the ambiguous variable name `l` (`E741`) in test files. Fixed in the test files themselves — not
   suppressed with `noqa` or a relaxed ruleset.
6. **hadolint DL3021 on the frontend Dockerfile.** A multi-source `COPY` (several named files into
   one destination directory) needs a `/`-terminated destination; `services/frontend/Dockerfile`'s
   `COPY index.html ... /usr/share/nginx/html` was missing the trailing slash. Fixed by adding it.
7. **A DL3018 apk-version pin was reverted as a time bomb.** An early pass pinned exact apk package
   versions in `services/backup/Dockerfile` to satisfy hadolint's DL3018 (unpinned apk version) — but
   Alpine's package versions move with the base image tag, so a pin silently breaks the next build
   whenever Alpine moves and the pinned version stops existing. It was also inconsistent with DL3008
   and DL3013, already deliberately ignored in the same Dockerfile for the identical reason. Reverted
   the pin; added `--ignore DL3018` to hadolint's invocation in `Jenkinsfile-ci`, alongside the
   already-ignored DL3008/DL3013.
8. **The Publish Metadata stage's shell failed with an unterminated-quote error that reproduces
   nowhere.** The stage failed inside Jenkins with a quoting error, but the identical script text is
   clean under `bash -n` run locally **and** under `sh -n` inside the real
   `amazon/aws-cli:2.22.0` image (bash 4.2.46) — the two places that should have caught it, didn't.
   **The root cause was never identified.** It was mitigated, not fixed: prose comments were moved out
   of shell step bodies, and `scripts/tests/check-jenkinsfile-shell.sh` was hardened to catch more
   shapes of this class of error statically before a build ever runs. Say plainly what this is: a
   workaround. If Publish Metadata breaks again in a way that looks like this, do not assume the
   hardening covers it.
9. **`kubectl apply --dry-run=client` is not purely local.** Full detail in §4 above (build #1). In
   short: client-side `apply` GETs each object's current state to decide create-versus-patch, so it
   needs read RBAC on every kind the chart renders — which the CD ServiceAccount's deliberately
   narrow, seven-kind read-only `Role` does not grant, by design. Switched Manifest Validation to
   `kubectl create --dry-run=client`, which never reads an existing object and needs no RBAC beyond
   the cluster's default discovery access; verified for real as `jenkins-cd-agent` (a minted token,
   not cluster-admin) against all 24 rendered resources.
10. **`argocd app sync --revision <sha>` is rejected once automated sync tracks a branch.** Full
    detail in §4 above (build #3): `FailedPrecondition ... auto-sync currently set to master`. Fixed
    by dropping `--revision` entirely — Promote (stage 5) already pushed the tag bump to `master`
    before Deploy runs, so a plain `argocd app sync voteball` reaches the promoted commit anyway.
    Verify's assertion that `sync.revision` equals the promote SHA is what now confirms ArgoCD landed
    on *this* build's commit rather than a newer one that raced in.
11. **`argocd app get` also needs `projects, get` on the AppProject.** Full detail in §4 above
    (builds #5 and #6). `app get` transitively resolves and reads the Application's owning AppProject,
    not just the Application object; the RBAC policy granted `applications, get/sync` but nothing on
    `projects`. Fixed with one additional read-only line, scoped to the single `voteball` project —
    same lesson as defect 9: a permission scoped to "the one object it needs" still has to cover
    everything reading that object transitively touches.

Plus two more, found while verifying rather than while first building the stages:

- **A 300s Deploy/Rollout timeout was too tight for the first deploy of a newly built tag**, and the
  failure mode was a false rollback, not just a slow one. Full detail in §4 above (build #10): four
  cold image pulls on a Spot node group that had never run that tag pushed the rollout past 300s,
  which **failed the stage and thus triggered an automatic rollback of a deploy that was actually
  healthy** and reached `Synced`/`Healthy` on its own moments later. Raised `argocd app sync`/
  `app wait` timeouts to 600s, and the pipeline's own `options { timeout(...) }` to 30 minutes to
  leave room for both.
- **`image-metadata.json` shipped with an empty `git_commit`** (visible in
  `docs/eks/evidence/2026-08-04-task4-image-metadata.json`, captured from build #33, which still
  shows `"git_commit": ""`). Cause: `amazon/aws-cli:2.22.0`, the container Publish Metadata runs in,
  has no `git` binary at all — confirmed with
  `docker run --rm --entrypoint sh amazon/aws-cli:2.22.0 -c "command -v git"`, which finds nothing —
  and the failing `git rev-parse HEAD` was buried inside a `$(...)` substitution used as one argument
  to `printf`. `set -eu` does not catch that: the discarded exit status belongs to the substitution,
  not to the `printf` call itself, so the stage kept going and wrote an empty string. Fixed by
  capturing the full commit SHA earlier, in the "Resolve tag and account" stage, which runs in the
  default `jnlp` container that does have `git`, and asserting the captured `GIT_COMMIT_SHA` is
  non-empty before Publish Metadata writes the file — a container that structurally cannot do the job
  is no longer asked to.

### What was proven live

The strongest form of evidence this design has: a running pipeline against the real cluster, not a
plan for one. Full logs in `docs/eks/evidence/2026-08-04-task4-*.txt`.

- **CI green end to end**: 188 tests run inside the pipeline (153 backend + 35 worker), Trivy clean
  (`Total: 0 (HIGH: 0, CRITICAL: 0)`) on all four images, four images built and pushed to ECR,
  metadata archived, CD triggered by parameter — `application-ci` build 33 handing off to
  `application-cd` build 12.
- **A real change deployed and verified to production by the pipeline**, end to end, with no human
  step between the push and a verified-healthy live site.
- **A failing test blocks the deploy**: `application-ci` build 28 went red at Tests
  (`1 failed, 153 passed`), and `application-cd`'s build count did not move — nothing was deployed
  from a red build.
- **The G2 guard closes the loop on both pipelines' own commits**: `application-ci` builds 30 and 34,
  triggered by `application-cd`'s own tag-bump commits, both reported `NOT_BUILT` at the Guard stage
  rather than rebuilding what CD had just promoted.
- **Automatic rollback fired unstaged** — not as a rehearsed demo, but live while the pipeline was
  still being brought up (`application-cd` builds #3 and #5) — and the `ROLLBACK_DEPTH` recursion
  bound held on both (builds #4 and #6: a rollback that itself fails verification does not roll back
  again; it stops and says so, rather than oscillating forever between two tags, each cycle pushing a
  commit and rolling production pods).
- **The deliberate demo**: a backend build whose `/api/results` returns 500 while `/health` stays
  healthy, deployed outside CI (CI would have refused it — the failure is deliberate, not a test
  regression). ArgoCD reported `sync=Synced health=Healthy` the entire time the site was broken,
  because a reconciler has no notion of whether the product actually works; only the smoke test
  caught it, after 10 retries. Rollback fired automatically and the site recovered.
  Visitor-visible degradation ran approximately 3 minutes, entirely self-healed, with no human action
  taken. This is the single clearest justification for the CD pipeline existing at all — a reconciler
  cannot see this failure, by construction, and did not.

### Security caveat, stated plainly rather than glossed over

Already recorded in `docs/security.md`, and repeated here because it belongs next to the rest of the
verification story rather than only in the security doc: the `ci` namespace's NetworkPolicy does what
its comment claims for the thing it exists to protect — an agent pod's route to the RDS endpoint times
out, and `devops-app` is unreachable, both verified live. But the same policy's re-admission of the
EKS service CIDR (needed so agents can reach the Kubernetes API on 443) is scoped to a CIDR block, not
to the API server's specific address, and lists ports 443/8080/50000 — which also reaches
`argocd-server`'s ClusterIP on port 443 (used) and, verified live, port 80 too. The practical exposure
is nil: every `argocd` CLI call in `Jenkinsfile-cd` uses `--grpc-web` over 443, and `--plaintext`,
which would use port 80, is never invoked. The claim that matters — CD **cannot write to the
cluster** — is enforced by RBAC, not by network path, and is absolute (defect 9 above is exactly what
happens when that RBAC is tested for real). But "CI cannot reach `devops-app`" and "CI's network path
to ArgoCD is minimal" are two different claims, and only the first one is true. Stated here rather
than left implied by the comment in `charts/jenkins-support/templates/networkpolicy.yaml`.

### Found by the final whole-branch review, after the pipeline was already green

Everything above was found while building and running the two pipelines. The four defects below were
found afterwards, by a whole-branch review of the finished, passing work — none of them made any build
fail, which is exactly why they survived every stage that did run. All four are fixed on `master`
(`Jenkinsfile-cd` carries a `FIXED 2026-08-04` comment at each site); this records what the failure
actually was, since none of it had a durable write-up until now.

1. **Rollback was silently disarmed by a Groovy escaping bug.** The Promote stage's `sed` command,
   inside a Groovy `'''…'''` (triple-single-quoted) string, was written with `\"` around the pattern and
   replacement — intended to reach bash as an escaped, literal quote character. Groovy's triple-single-
   quoted strings do not treat `\"` as an escape, though: they unescape it to a bare `"` before bash ever
   sees the script. What bash actually received was `sed -i -E "s/^  tag: ".*"/  tag: "$TAG"/"` — the
   `"` characters there are ordinary shell quote *delimiters*, not literal characters passed to `sed` —
   so the rewrite stripped the surrounding quotes instead of preserving them, and every CD-written tag
   since the split had been landing in `values.yaml` **unquoted**. Three consequences, none of which any
   test caught:
   - `scripts/sync-values-from-tf.sh` requires a quoted `tag:` value and refuses to run against anything
     else, so it would report `image.tag` missing and exit 2 — and `scripts/deploy.sh` calls it
     unconditionally, so a fresh rebuild would have failed at the sync step.
   - `scripts/ci/previous-tag.sh` (rollback's "what tag were we on before this one" lookup) greps for
     `tag: "`, quoted, so it matched only history from before the split and would have returned the same
     frozen tag forever. **Rollback was effectively disarmed by this bug** — not by anything in the
     rollback logic itself, but by the tag history it reads having stopped updating. The 2026-08-04
     rollback demo (builds #3–#6, "What was proven live" above) did roll back to the correct tag, but
     only because that frozen tag still happened to be the right one at the time; it worked for the wrong
     reason.
   - Left unquoted, an all-digit or leading-zero short SHA is valid YAML and gets parsed as an integer or
     octal number rather than a string, which is a second, independent way this shape of bug corrupts
     `values.yaml`.

   Why every gate that should have caught it, didn't: the post-`sed` `grep` verification in the same
   stage used the identical `\"` escaping, so it checked for the same wrong (unquoted) shape it had just
   written and confirmed it. And `scripts/tests/test-sync-values.sh` built its test fixture by hand, with
   quotes already in place, so the guard's test never exercised what the real file actually looked like.
   Fixed by doubling the backslash (`\\"`), which Groovy unescapes to a single `\` that reaches bash as
   `\"` — an escaped literal quote inside the double-quoted `sed` script, which is what was intended
   originally. A regression case for the unquoted shape has been added to
   `scripts/tests/test-sync-values.sh` (`UNQUOTED` fixture) so this class of bug fails a test run instead
   of only a live rebuild.

2. **A live ECR credential was committed to the public repo.** Jenkins traces every `sh` step under
   `set -x`, and that trace logs each command *after* shell expansion. The ECR password was obtained via
   `$(aws ecr get-login-password)` and used as a `printf` **argument** — so the raw token, and its
   base64-encoded docker-auth form, were both written into the build console output as the expanded
   arguments of that traced command. That console log was saved verbatim as evidence and committed to
   the repo. Jenkins' built-in credential masking did not help, because masking only redacts values that
   came from Jenkins' credential store — this token was fetched at runtime by the AWS CLI, so Jenkins had
   never seen it and had nothing to mask. The token was redacted from the committed evidence, and
   separately self-expires (ECR tokens are valid 12 hours and cannot be revoked or manually renewed); the
   repo owner decided on 2026-08-04 to let it expire on its own rather than rewrite published git
   history, consistent with this repo's standing no-force-push rule (there is no evidence the token was
   ever used by anyone but this pipeline). All stored evidence files were then checked and confirmed to
   carry no other secret values.

3. **Fixing (2) regressed the credential a different way.** The fix moved the token out of argument
   position — writing `aws ecr get-login-password` straight to a file instead of capturing it into a
   `printf` argument via `$(...)`. That silently broke something the old `$(...)` form had been doing for
   free: command substitution strips trailing newlines, and redirecting straight to a file does not.
   `aws ecr get-login-password`'s output ends in a newline, so the file-based version encoded
   `AWS:<token>\n` into the docker-auth string instead of `AWS:<token>`, and BuildKit's ECR cache
   authentication with that corrupted auth would have failed with a 401 — not at the start of a build,
   but at the very end, during cache export, after the image had already built and every layer had
   already uploaded. The two requirements pull in opposite directions and both are real: the token value
   must never reach an argument position (that's what caused defect 2), *and* its trailing newline must
   still be stripped (or the auth is corrupt) — and satisfying the first one silently broke the second,
   because the newline-stripping had been an unstated side effect of the very syntax (`$(...)`) that had
   to be removed. Fixed with `tr -d '\n' < file`, which strips the newline while keeping the value out of
   argument position, satisfying both constraints — commented together at the fix site so the two don't
   get separated again.

4. **Three further ways a healthy deploy could have been rolled back**, beyond the cold-image Rollout
   timeout already recorded above (defect matching build #10): (a) Verify's `sync.revision` equality
   check would fail a good deploy if any unrelated commit landed on `master` during the Deploy/Rollout
   window and got auto-synced first — and this repo's own `CLAUDE.md` tells every contributor to commit
   and push continuously, so that window is not a rare edge case; (b) the evidence-capture `kubectl get`
   after Promote was running under the same `set -eu` as the checks around it, so a transient, read-only
   API hiccup on a diagnostics-only call could fail the whole stage; (c) `scripts/ci/previous-tag.sh`
   throws (exit 1) when there is no previous tag to roll back to, and the Groovy calling it used
   `sh(..., returnStdout: true)`, which throws on a non-zero exit — aborting the surrounding script block
   before the `ROLLBACK_DEPTH` recursion-bound check ever ran, which is exactly the path the depth-1
   "NEEDS A HUMAN" message exists to print, and it could never print on it. All three are fixed on
   `master`: (a) a revision mismatch alone now only logs a `WARNING`, gated instead on whether the
   *running* Deployments actually name the requested tag; (b) that `kubectl get` now runs outside the
   strict block and only warns on failure; (c) the call now uses `returnStatus: true`, capturing the exit
   code as data instead of throwing.

   The general lesson, stated plainly: **anything that can fail after Promote is a rollback trigger** —
   Promote is the point of no return, since it is what commits production to a new tag — so every timeout
   value and every command written into that back half of the pipeline is a correctness parameter, not a
   performance one. A too-tight timeout or an over-strict error check doesn't just make the build slower
   or noisier; it fires an automatic, production-affecting rollback of a deploy that was actually fine.
