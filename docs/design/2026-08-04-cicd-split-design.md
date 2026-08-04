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
| 3 | Manifest Validation | `helm lint charts/voteball`; `helm template … --set image.tag=$IMAGE_TAG`; `kubectl apply --dry-run=server -f -` against the rendered output |
| 4 | Authenticate | in-cluster ServiceAccount `jenkins-cd-agent`; `kubectl auth can-i` self-check proves the token works and is scoped (§4) |
| 5 | Promote | rewrite `image.tag` in `charts/voteball/values.yaml`, commit `ci: image tag <sha> [skip ci]`, push to `master` |
| 6 | Deploy | `argocd app sync voteball --revision <promote-commit> --timeout 300` |
| 7 | Rollout | `kubectl rollout status deployment/{frontend,backend,worker} -n $NAMESPACE --timeout=300s` |
| 8 | Verify | `kubectl get deployments,pods,services,ingress -n $NAMESPACE`; assert every running container image ends in `:$IMAGE_TAG` |
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
| AWS role (IRSA) | ECR push to this account's repos | **none** |
| Kubernetes RBAC | none | Role in `devops-app` only |
| Containers | `jnlp`, `buildkit`, `tools` (aws-cli, trivy, ruff, hadolint), `postgres` | `jnlp`, `deploy` (kubectl, helm, argocd CLI, curl, jq) |
| Can build an image | yes | no |
| Can change what production runs | no | yes |

Neither can do the other's job, which is the whole point: a compromised build agent can push a junk
image but cannot deploy it; a compromised deploy agent can only deploy images that already exist and
already passed Trivy.

`jenkins-cd-agent`'s RBAC is a namespaced `Role` + `RoleBinding` in `devops-app` — no
`ClusterRole`, no `cluster-admin`:

- `apps`: `deployments` — `get,list,watch,patch` (for `rollout status` and `rollout undo`)
- `""`: `pods`, `services`, `events` — `get,list,watch`
- `""`: `pods/log` — `get`
- `networking.k8s.io`: `ingresses` — `get,list`

`kubectl apply --dry-run=server` in stage 3 needs create permission it does not have, so the dry-run
is scoped to a `--dry-run=server` against a namespace it can read; where a permission is genuinely
absent the stage degrades to `--dry-run=client` and says so in the log rather than failing silently.
This is deliberate: expanding CD's RBAC to full `create` on every kind in the chart would undo the
least-privilege story for the sake of one validation nicety, and ArgoCD — which *does* hold those
permissions — performs the real apply immediately afterwards.

The ArgoCD CLI authenticates with a dedicated ArgoCD **local account** (`jenkins-cd`) declared in
`terraform/addon-argocd.tf`'s `argocd-cm`, granted only `applications, sync/get/action` on
`voteball/voteball` in `argocd-rbac-cm`. Its token is stored in Secrets Manager alongside the existing
Jenkins secrets and reaches the pod through the existing ESO ExternalSecret — no new secret mechanism.

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
to apply the chart and could not bypass it. What Jenkins CD adds is the four things a reconciler
structurally cannot do: refuse a tag that does not exist or is `latest`, wait for the rollout and
confirm the running images match what was asked for, make a real HTTPS request to the public site, and
revert git when that request fails. This is the conventional GitOps split, not a workaround.

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
