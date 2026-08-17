# CI/CD pipelines

How a code change becomes a running, verified pod, with no manual deploy step and an automatic
rollback if the new version fails.

CI/CD is **Jenkins, running inside the EKS cluster** (namespace `ci`), installed by Terraform
(`terraform/addon-jenkins.tf`) as a `helm_release` of the official `jenkins/jenkins` chart, and
configured entirely by JCasC (`ci/jenkins/jenkins.yaml`). It is **two pipelines, not one**:
**`application-ci`** (`Jenkinsfile-ci`) builds, tests, scans and pushes; **`application-cd`**
(`Jenkinsfile-cd`) promotes, deploys, verifies and — on failure — rolls back. They were one pipeline
until the 2026-08-04 split; the reasoning for splitting them, and for keeping ArgoCD as the applier
rather than replacing it with `helm upgrade --install`, is in
[`docs/design/2026-08-04-cicd-split-design.md`](design/2026-08-04-cicd-split-design.md).

That design supersedes the *topology* of two earlier ones, not their *logic*. The pipeline's guard
labels **G1–G7**, used throughout below, were coined in
[`docs/design/2026-07-20-jenkins-migration-design.md`](design/2026-07-20-jenkins-migration-design.md)
(GitHub Actions → a dedicated EC2 host) and remain current — every one of them still lives in
`Jenkinsfile-ci`, just relabelled to a two-job world. The reasoning for running Jenkins *in the
cluster instead of on EC2* is in
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md), whose
"Verification outcome" section records what that move actually broke versus what the design
predicted — including the `emptyDir` decision it made for `JENKINS_HOME`, which the 2026-08-04 split
superseded (§2 of that doc carries a pointer to the current storage design; see "Running the
instance" below for what actually runs today).

The single-pipeline version was verified end-to-end on 2026-07-20 (against the live cluster),
2026-07-21 (JCasC self-configuration on a fresh EC2 instance) and 2026-07-30/31 (the in-cluster
move). The two-pipeline split was verified end-to-end on 2026-08-04: a push builds, tests, scans,
pushes four images and triggers CD; CD promotes, ArgoCD deploys, the smoke test passes; a
deliberately-broken deploy was rolled back automatically; and the tag-bump commit is correctly
refused by the Guard stage in both directions (CI's own guard, and CD's rollback-depth bound).

---

## The short version

**`application-ci`** runs on every push to `master` that touches `services/**` (or is forced). It
validates the repo shape, lints, runs the 153 backend/worker tests against a real Postgres sidecar,
builds four images with rootless BuildKit, scans them with Trivy, pushes the clean ones to ECR under
the git-SHA tag, writes a metadata file recording the digests, and hands the tag to `application-cd`
as a build parameter. **It never touches the cluster and holds no cluster credentials of any kind.**

**`application-cd`** receives a tag (from CI, or from a human re-running it by hand) that has already
been built, tested and scanned. It validates the request, writes the tag into
`charts/voteball/values.yaml` and pushes that commit to `master`, asks ArgoCD to sync it, waits for
ArgoCD's own health verdict, double-checks with a real HTTPS request against the live site, and —
if any of that fails — rolls production back to the previous tag automatically by re-running itself
against it.

```
git push (services/**) → webhook → application-ci → application-cd → ArgoCD → pods roll
                                    (build/test/scan/push)  (promote/deploy/verify/rollback)
```

**Jenkins never applies anything to the cluster; ArgoCD does.** Neither pipeline holds write
permission to `devops-app` — CI's ServiceAccount has zero Kubernetes RBAC at all, and CD's
ServiceAccount holds a strictly read-only Role (`get`/`list`/`watch`, nothing that changes state).
Every byte that reaches a running pod gets there through ArgoCD's own server-side apply. See §7 of
the design doc for why, and the [ownership table](README.submission.md#why-argocd-is-the-applier-and-jenkins-cd-is-not)
reproduced in the submission README.

**Jenkins is a platform add-on, not the application.** Changes to the Jenkins release (the Helm
values in `terraform/addon-jenkins.tf`, or JCasC in `ci/jenkins/jenkins.yaml`) reach the cluster by
`terraform apply`, exactly like ArgoCD, External Secrets Operator or external-dns — **not** by
committing to `master`. This is the opposite of `charts/voteball`, which ArgoCD syncs from git.
Committing a JCasC change and walking away changes nothing until someone runs `terraform apply`.

---

## What a build agent is, and what it is allowed to do

Both `Jenkinsfile-ci` and `Jenkinsfile-cd` say `agent { label '...' }` and nothing else about what
that agent is made of. Everything in this section is what that one line sets in motion — for
**two** pod templates now, declared side by side in `ci/jenkins/jenkins.yaml`'s Kubernetes cloud,
one per job. **The agent does not exist until a build needs it, and stops existing when the build
ends** — there is no build machine to log into, patch, or keep clean, for either job.

### Lifecycle (both templates)

1. **A queue item appears** needing the label `voteball-build` or `voteball-deploy`. The controller
   runs `numExecutors: 0` (set in both `ci/jenkins/jenkins.yaml` and the Helm values), so it can never
   satisfy that itself. The item sits in the queue *unsatisfiable* — by design, not as a fault.
2. **The Kubernetes cloud provisions.** It matches the label to the corresponding pod template,
   checks its cap (`containerCapStr: "4"` across *both* templates combined — raised from 3 to 4 with
   the split, since a CD deploy or a manual rollback can now run concurrently with the CI build for
   the next push), mints a one-time connection secret for this specific agent, and creates a pod in
   `ci`.
3. **Kubernetes schedules it** onto the existing Spot node group. If nothing fits, Cluster Autoscaler
   adds a node *first* — seconds on a warm cluster, minutes on a cold one. That wait happens below
   Jenkins and is invisible in the build log.
4. **The agent dials out.** The `jnlp` container connects to `jenkins-agent.ci.svc.cluster.local:50000`
   and presents its secret. Note the direction — the controller never connects to the agent. Once the
   handshake lands the node comes online and the pipeline starts.
5. **The pod is destroyed** when the build ends. Agents are **single-use**: one build per pod, never
   reused, never shared between a CI build and the CD build it triggers. `retentionTimeout: 5` is the
   backstop that reaps a pod which was provisioned but never connected.

The pod-creating API call in step 2 is made by the **controller's** ServiceAccount, using a
namespace-scoped Role over `pods`, `pods/exec`, `pods/log`, `persistentvolumeclaims` and `events` in
`ci` — nothing else, and nothing in any other namespace. `pods/exec` is not incidental: it is *how*
every `container('...') { sh ... }` step runs, in either job. Neither build has a shell of its own;
each step is the controller exec'ing into a named container of a pod it owns.

### The two templates, contrasted

Two ServiceAccounts, two IRSA roles, two Kubernetes RBAC grants — deliberately incompatible with each
other's job:

| | `voteball-build` (`application-ci`) | `voteball-deploy` (`application-cd`) |
|---|---|---|
| ServiceAccount | `jenkins-agent` | `jenkins-cd-agent` |
| AWS role (IRSA) | ECR **push**/pull on `repository/<cluster_name>-*` | ECR **read-only** (`DescribeImages`, `BatchGetImage`) on the same repos, no push |
| Kubernetes RBAC | **none** — no Role or ClusterRole binds this ServiceAccount anywhere | a namespaced, **strictly read-only** `Role` in `devops-app` (`charts/jenkins-support/templates/rbac.yaml`): `get`/`list`/`watch` on deployments, replicasets, pods, services, events, ingresses, plus `get` on pod logs — no `patch`, no `create`, no ClusterRole |
| Containers | `jnlp`, `buildkit`, `trivy`, `skopeo`, `awscli`, `python`, `postgres`, `hadolint` (8, including the implicit `jnlp`) | `jnlp`, `deploy` (kubectl+helm+aws-cli+jq+curl, `alpine/k8s:1.31.3`), `argocd` (the ArgoCD CLI, `quay.io/argoproj/argocd:v3.4.5` — pinned to the same version as the running server) |
| Can build an image | yes | no |
| Can write to the cluster | no (zero RBAC) | **no** — read-only RBAC; only ArgoCD applies |

Neither can do the other's job, which is the whole point: a compromised build agent can push a junk
image but cannot deploy it; a compromised deploy agent can only ask ArgoCD to sync a commit, and only
of images that already exist and already passed Trivy — and it cannot even confirm a rollout with
`kubectl rollout status`, because it has no write verb and delegates that question to ArgoCD's own
health model instead (§ "application-cd" below).

> **"5/5" and "3/3" (or fewer) are both meaningful counts** when reading `kubectl get pods -n ci`
> during a build — a wrong container count on either template is the first sign of the failure modes
> below.

### The five trust boundaries

Both agents cross the same shape of boundary, with different credentials at three of the five steps.
**No credential works for more than one job**, and none of them is a long-lived AWS key.

| Boundary | How it is authenticated | Scope | Lifetime |
|---|---|---|---|
| Agent → controller | one-time secret, injected into the pod at creation | this agent only | dies with the pod |
| Agent → Kubernetes API | ServiceAccount token | CI: **nothing**. CD: read-only on `devops-app` | n/a |
| Agent → AWS | IRSA (OIDC federation) | CI: ECR push. CD: ECR read-only | minutes, auto-renewed |
| Agent → ECR registry | token from `ecr:GetAuthorizationToken` | same repositories as the IRSA role | 12 h, deleted at stage end |
| Agent → GitHub / ArgoCD | CI: SSH deploy key, lent for the Trigger CD stage (unused otherwise). CD: the same deploy key for `Promote`, plus a dedicated ArgoCD API token for `Deploy`/`Rollout`/`Verify` | CI: this repository. CD: this repository (write); the `voteball` Application only (`get`, `sync`) | until the next rebuild (deploy key); until the token is rotated (ArgoCD token) |

**AWS — identity, not a password.** Terraform told AWS once to trust this cluster's OIDC provider,
and wrote two trust policies naming two claimants: `system:serviceaccount:ci:jenkins-agent` (push)
and `system:serviceaccount:ci:jenkins-cd-agent` (read-only). At build time the EKS pod-identity
webhook injects a short-lived, signed token into the pod; the AWS SDK exchanges it via
`sts:AssumeRoleWithWebIdentity` for temporary credentials. **No static AWS key exists anywhere** —
not in either pod, not in git, not in tfstate, not in Secrets Manager. The controller's own
ServiceAccount carries no `role-arn` annotation and therefore no AWS identity whatsoever, in either
pipeline.

**GitHub — a real key, borrowed not owned, used by both jobs.** `scripts/seed-jenkins-secret.sh`
generates a fresh ed25519 pair at deploy time, keeps the private half in Secrets Manager and prints
the public half; `scripts/register-github-ci.sh` registers that public half on the repo as a deploy
key with write access (both `application-ci`'s checkout and `application-cd`'s `Promote` stage push
commits with it). At build time the private half travels:

```
Secrets Manager (voteball/jenkins)
  → ESO  → k8s Secret `jenkins-secret`  → controller pod env  → JCasC credential `voteball-deploy-key`
  → sshagent(), lent over the already-authenticated agent connection for one stage only
```

It stays on the **controller**; `sshagent` lends it for one stage in either job. It is never in the
pod spec and never an agent environment variable, so reading the pod manifest does not reveal it.

**ArgoCD — a scoped local account, new in the split.** `application-cd`'s `Deploy`, `Rollout` and
`Verify` stages authenticate to `argocd-server.argocd.svc.cluster.local` with a bearer token for a
dedicated ArgoCD **local account**, `jenkins-cd`, declared in `terraform/addon-argocd.tf`'s
`argocd-cm`/`argocd-rbac-cm`. Its RBAC is `applications, get` and `applications, sync` on
`voteball/voteball` and nothing else — it cannot log into the ArgoCD UI (the account is
`apiKey`-only) and cannot touch any other Application. The token reaches the pod exactly like the
GitHub deploy key: Secrets Manager → ESO → Kubernetes Secret → pod env → JCasC credential
(`argocd-auth-token`), read with `withCredentials` in the three stages that need it.

> **Why this asymmetry costs you a step after every teardown.** AWS permission survives a rebuild
> because it is a *rule* — "trust this cluster's `jenkins-agent`" — and the rule does not care that
> the pods are new. GitHub and ArgoCD permission do not survive, because each is a *specific secret*,
> and the rebuild minted a different one (a new deploy key; a new ArgoCD instance with no accounts
> yet). Anything based on proved identity is self-healing; anything based on a stored secret needs
> re-registering or re-minting. That is why the first-time setup runbook below has a step for each.

---

## `application-ci`, stage by stage

The pipeline lives in [`Jenkinsfile-ci`](../Jenkinsfile-ci) at the repository root; the Jenkins job is
defined by Job DSL inside `ci/jenkins/jenkins.yaml`'s `jobs:` block as *Pipeline script from SCM* — so
the build definition is in the repository and reviewable, not hidden in Jenkins' database, and **it
was never created through the UI**. The pod agent template lives in the same file's Kubernetes cloud
`templates:` block, not in `Jenkinsfile-ci` — the 2026-07-20 design's own rule ("everything about HOW
to build lives in the Jenkinsfile ... this block only says where to find it and when to run it"),
applied to *what a build agent is made of*.

### 1. Trigger — GitHub webhook

A push to `master` sends a webhook to `https://jenkins.<app_domain>/github-webhook/`. Jenkins verifies
the HMAC signature GitHub attaches using a shared secret, so a random request cannot start builds.

Only app-source changes rebuild images: the build/scan/push stages carry
`when { anyOf { changeset 'services/**'; expression { params.FORCE_BUILD }; expression { env.NO_CHANGELOG } } }`
(**G3**). Editing `README.md`, `terraform/` or `docs/` triggers the job but builds nothing (Publish
Metadata and Trigger CD share the same guard, so a docs-only push does not hand CD a tag with no
images behind it).

The third condition (**G3b**) exists because `changeset` returns false for two different situations
and cannot distinguish them: "no file under `services/` changed", and "Jenkins has no changelog at
all" — which happens on the first build after the controller is recreated, and `JENKINS_HOME` being
reclaimable (see "Running the instance" below) makes that a routine event, not a one-off.
`NO_CHANGELOG` is set from `currentBuild.changeSets.isEmpty()` in *Resolve tag and account*, and makes
the pipeline build when it cannot tell what changed. Redundancy is bounded by G1: if the images for
that SHA are already in ECR, `ALREADY_BUILT` short-circuits everything anyway.

> **This was a real, silent failure, not a hypothetical**, in the single-pipeline predecessor of this
> job: build 2 on 2026-08-03 checked out a fresh commit, logged `First time build. Skipping
> changelog.`, wrote a 0-byte changelog, skipped build/scan/push, and reported **SUCCESS** while ECR
> held no images for that SHA. `scripts/tests/test-ci-guards.sh` now asserts every `changeset` gate
> keeps its G3b branch.

`FORCE_BUILD` is a checkbox on "Build with Parameters". It exists because a **manually** triggered
build has an empty changeset and would otherwise skip every stage, making "Build Now" a silent no-op.

### 2. Guard: is this our own commit? (G2)

**This stage is load-bearing and must never be removed.** `application-cd`'s Promote stage commits the
bumped image tag back to `master`. `[skip ci]` is a *GitHub Actions* convention; **Jenkins has never
heard of it**. Without the guard, the webhook fires on that commit, `application-ci` builds it,
triggers `application-cd`, which commits again — an unbounded build loop that burns money and
continuously rolls production pods, now across *two* jobs instead of one.

The first stage reads the head commit message and, if `scripts/ci/should-skip-build.sh` says `skip`,
sets `currentBuild.result = 'NOT_BUILT'` and aborts. It runs unconditionally and first, so a
`[skip ci]` commit cannot be built even manually with `FORCE_BUILD` ticked.

### 3. Validation (new)

`scripts/ci/validate-repo.sh` — cheap, cost-nothing repo-shape assertions that gate everything after
them: every service directory has a `Dockerfile` and a `.dockerignore`, no Dockerfile pins (or
implicitly resolves to) `:latest`, and `charts/voteball/Chart.yaml` at least parses a `version:` line.
Runs before "Already built?" deliberately — a re-run of an already-built tag still has to pass
validation.

### 3b. Script tests (new, 2026-08-11)

`scripts/tests/run-ci-suite.sh` — the tests that protect the pipeline itself. Numbered `3b` rather
than renumbering everything below it, the same convention `deploy.sh` uses for its own inserted
steps.

**Until this stage existed, nothing in CI ran `scripts/tests/` at all.** The pipeline ran `pytest`
for `services/{backend,worker}` and stopped, so the `[skip ci]` loop guard, the immutable-tag re-run
check, the `values.yaml` drift check and the dirty-tree guard were each covered by a test that only
ran when somebody remembered. Any one of them could have been deleted and every build would have
stayed green — the exact failure mode the repo's own rule ("pipeline logic that can only be tested by
running the pipeline is exactly what this project refuses to accept") exists to prevent, applied
everywhere except to the tests themselves.

The suite's `PYTHON_GROUP`, `GIT_GROUP` and `SKIP` lists are **exhaustive**: it fails if any file in
`scripts/tests/` appears in none of them — and that check runs whichever group is invoked, so a new
test cannot hide in the gap between the two groups. It also fails if a listed test has been deleted.
A bare glob would silently absorb a future helm-dependent test and break every build; an unchecked
hand-list would silently drop a new test and protect nothing. Three tests are skipped for tools no
image in the pod carries — `test-jenkins-chart.sh` (helm), `test-register-github-ci.sh` (gh),
`test-webhook-wait.sh` (curl) — and they still run by hand. Moving one into a group means adding the
tool to an image, not weakening the test.

**It runs in two containers, because none has both `python3` and `git`.** `python:3.12-slim` has
python3 and no git; the default `jnlp` container has git — it performs the checkout — and no python3.
So `run-ci-suite.sh git` runs in jnlp (one test, which builds throwaway repositories) and
`run-ci-suite.sh python` runs in `container('python')` (the other eleven). **Build #7 established this
the expensive way**: the whole suite ran in jnlp and four tests died on `python3: command not found`,
failing the build. The lesson is in the script's comments — decide a test's group by running it in a
bare image, never by reading it, since several mention `aws` and `terraform` only in comments and stub
variables.

Placed before Lint and Tests because it is the cheapest gate in the pipeline — seconds, no network,
no database — and a broken guard should stop a build before anything is built.

### 4. Lint / Static Analysis (new)

`ruff check` over `services/backend` and `services/worker` in the `python` container; `hadolint`
against all four Dockerfiles in the `hadolint` container (`DL3008`/`DL3013`, unpinned apt/pip
versions, are suppressed — the Dockerfiles pin through `requirements.txt`, which hadolint cannot see).

### 5. Tests (new)

The 250 tests in `services/{backend,worker}/tests/` (208 backend + 42 worker — count them with
`pytest tests/ --collect-only -q` in each service rather than trusting this number, it drifts every
time a test is added), run against a **real** Postgres — both
`conftest.py` files `DROP TABLE ... CASCADE` and call `init_db()`, and were never sqlite-compatible.
The `postgres` container in the CI pod template (`postgres:16-alpine`, `DB_SSLMODE=disable`) provides
it on `localhost`; it is ephemeral, holds no real data, and is reachable only from inside this pod's
own network namespace, so the `ci` NetworkPolicies are unaffected and no route to the real RDS
instance is created or needed.

These tests existed before this stage did and were never run by CI, so a failing test blocked
nothing. **They now block everything** — including the tag CD would otherwise have received.
`pg_isready` is polled for up to 60s before pytest runs, since containers in a pod start concurrently
and a premature connection reads like a configuration error rather than a race. JUnit XML is
published with `allowEmptyResults: false`, so a stage that silently produced no report fails loudly
rather than looking green.

### 6. Resolve tag and account

Fails loudly if `AWS_REGION`/`CLUSTER_NAME` (Jenkins global environment variables, set via JCasC
`globalNodeProperties`) are missing, rather than producing `null.dkr.ecr.null.amazonaws.com` later.
Resolves `TAG` (short commit SHA), `AWS_ACCOUNT_ID` (via `container('awscli')`), `ECR_REGISTRY`, and
`NO_CHANGELOG` (G3b, above). Sets the build description to `<branch> @ <sha> (build #N)`.

### 7. Already built? (G1)

ECR repositories are `IMMUTABLE`, and images are tagged with the short git SHA, so re-pushing an
existing tag is rejected by ECR — a red build caused by nothing being wrong, on a routine "Build Now"
or replay. `scripts/ci/images-exist.sh` asks ECR whether all four images for this SHA already exist;
if they do, build/scan/push are skipped and the pipeline goes straight to Publish Metadata and
Trigger CD. The skip only happens on a **positive** answer — a lookup failure builds normally.

### 8. Build images

Four images (`backend`, `worker`, `nginx`, `backup`), rootless BuildKit (`moby/buildkit:v0.19.0-rootless`,
uid 1000), `--output type=docker` (not `type=oci` — Trivy's `--input` cannot read an OCI archive), tagged
with the short git SHA — never `latest`. Both the layer cache (`<cluster_name>-buildcache`, mutable,
outside the immutable ECR set) and the Trivy database (`<cluster_name>-trivy-db`) live in ECR rather
than on any volume, since a pod agent starts cold every time. See the design doc §5a for the full
BuildKit/ECR-caching mechanics; nothing there changed in the split.

### 9. Trivy scan

`backend`/`worker`/`nginx` **block** the build on fixable `CRITICAL`/`HIGH` findings; `backup`
(third-party `postgres:17-alpine` + aws-cli) is report-only, since its CVEs are upstream and outside
this project's control.

### 10. Push to ECR

`skopeo copy docker-archive:/images/<svc>.tar docker://...` — the **exact same file** Trivy just
scanned, so the scanned artifact and the pushed artifact are provably the same bytes. No *deployable,
tagged* image reaches ECR before the scan passes.

### 11. Publish Metadata (new)

Writes and `archiveArtifacts`s `image-metadata.json` — image tag, git commit, CI build number,
timestamp, and each image's digest — and captures the backend digest into `env.BACKEND_DIGEST`. This
is the brief's traceability requirement: from a CD build it must be possible to identify the CI build,
commit, image and digest that produced it. A digest is the content; a tag is a movable pointer, so the
digest is what actually matters here.

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

### 12. Trigger CD (new)

```groovy
build job: 'application-cd', wait: false, parameters: [
  string(name: 'IMAGE_TAG',    value: env.TAG),
  string(name: 'IMAGE_DIGEST', value: env.BACKEND_DIGEST ?: ''),
  string(name: 'SOURCE_BUILD', value: env.BUILD_NUMBER),
]
```

`wait: false` so a slow rollout does not hold a CI executor, and so a CD failure is reported against
the CD build where its own logs live, not as a confusing CI failure. This is **not** a deploy stage —
`application-ci` holds no cluster credentials at all and cannot reach the cluster; handing the tag to
a separate job is one of the connection mechanisms the course brief permits (build trigger + parameter
passing). The `when` guard here is the same one Publish Metadata carries, and is load-bearing for the
same reason: without it, a docs-only commit would trigger CD with a tag that has no images in ECR, and
CD's own Input Validation would then correctly — but needlessly — turn every documentation commit
into a red CD build.

### Cleanup

`post { always }` removes the live ECR login token written to the shared `/images` volume during
"Build images" (a failed build should not leave a 12-hour registry credential sitting in a volume for
the rest of the pod's life), then `cleanWs()`. `buildDiscarder` keeps the last 20 builds (**G5**;
`docker image prune` from the old EC2-host pipeline stays deleted, not ported — a pod agent is
destroyed after every build, so the disk cleans itself). `post { failure }` logs that no notification
is sent (**G7**, unchanged — see "Deferred, on purpose").

---

## `application-cd`, stage by stage

The pipeline lives in [`Jenkinsfile-cd`](../Jenkinsfile-cd), same Job-DSL/Pipeline-script-from-SCM
pattern as CI, **never created through the UI**. It is parameterized (`IMAGE_TAG`, `IMAGE_DIGEST`,
`SOURCE_BUILD`, `NAMESPACE` default `devops-app`, `ROLLBACK_DEPTH` default `0` — internal, see
Rollback below) and carries no `githubPush()` trigger: a push-triggered CD would deploy on every
commit regardless of whether CI passed, which is exactly the gate this split exists to create. It
starts only from `application-ci`'s Trigger CD stage, or by hand.

**Governing rule, stated in the file's own header comment: whatever ArgoCD can do, ArgoCD does.**
Deploy, rollout-waiting and health assessment are all delegated to ArgoCD CLI calls; what lives in
this Jenkinsfile is only what a reconciler structurally cannot do — reject an invalid request, choose
which tag git should name, ask the live site over HTTPS whether it works, and revert git when it does
not. See design doc §7 for the full ownership table (also reproduced in `README.submission.md`).

### 1. Checkout

Sets the build description for traceability:
`tag <TAG> <- ci #<SOURCE_BUILD> (<digest prefix>)` — so a CD build page names the CI build, commit,
tag and digest that produced it without opening a second window.

### 2. Input Validation

Nothing is committed to `master` until the request is known to be valid — a bad tag caught here costs
nothing; caught after the promote commit it has already fired a webhook. Checks, in order: `IMAGE_TAG`
non-empty; not `latest`; matches `^[0-9a-f]{7,40}$` (a commit SHA, not an arbitrary string);
`NAMESPACE` in an allowlist of exactly one (`devops-app`); `AWS_REGION`/`CLUSTER_NAME`/`APP_DOMAIN`
are all set as Jenkins global environment variables (checked *here*, not left to fail inside Smoke
Test's `set -eu`, because by Smoke Test `PROMOTE_SHA` is already set and an "unbound variable" there
would trigger the automatic rollback against a deploy that actually worked). Finally,
`scripts/ci/images-exist.sh` (the same script G1 uses, run read-only through the CD agent's ECR
read-only IRSA role) confirms all four images for the requested tag really are in ECR before `master`
is told to name it.

### 3. Manifest Validation

`helm lint charts/voteball`; `helm template ... --set image.tag=$TAG`; then
`kubectl create --dry-run=client` against the rendered output — **`create`, not `apply`, and
`=client`, not `=server`.**

A server-side dry run would need create permission on every kind in the chart, and granting the
read-only CD agent that would undo the read-only guarantee for one validation nicety — so client-side
was always the plan. But `application-cd` build #1, the pipeline's first ever live run, showed that
`apply --dry-run=client` needs real permission too: to decide create-vs-patch it GETs each object's
*current* configuration from the API server first, and `jenkins-cd-reader` cannot `get` most of the
kinds this chart renders (see `charts/jenkins-support/templates/rbac.yaml`). The build failed
Forbidden on every one of them. `kubectl create --dry-run=client` doesn't have this problem — `create`
never reads an existing object — and was verified (as `jenkins-cd-agent`, not cluster-admin) to pass
cleanly against the real chart with zero Forbidden errors.

**What it does and doesn't catch, also verified for real rather than assumed:** it catches a chart
that fails to render, malformed YAML, and a document missing required fields or naming an unknown
`kind`. It does **not** catch deep per-field schema errors (a string where an int is expected, or a
made-up field, both still pass) or anything that depends on the live object's current state — that
class of check is why ArgoCD's real server-side apply, seconds later, is still what actually catches
an invalid manifest and fails the sync. This stage narrows the failure window; it does not close it.
Full writeup: `docs/design/2026-08-04-cicd-split-design.md` §4.

### 4. Promote

The deploy decision, expressed as a commit — the only stage that writes to a shared system before
ArgoCD is asked to act:

```bash
sed -i -E "s/^  tag: \".*\"/  tag: \"$TAG\"/" charts/voteball/values.yaml
grep -q "^  tag: \"$TAG\"" charts/voteball/values.yaml || exit 1   # assert the rewrite landed
git commit -m "ci: image tag $TAG [skip ci]"
git pull --rebase --autostash origin master
git push origin HEAD:master
```

Uses the same GitHub deploy key as CI's checkout, over `sshagent()`, with the same pinned
`known_hosts` write this stage needs because raw `git push` in the `jnlp` container has its own,
separate `known_hosts` from the git *plugin*'s checkout (this is **G4** — the write-access deploy key
and SSH-remote requirement — now living here instead of in the old single pipeline's tag-bump stage).
The `grep` assertion after the `sed` exists because `sed` exits 0 whether or not its pattern matched:
if the `tag:` line's shape ever drifts (re-indented, unquoted), a silent no-op here would report
success on an unrewritten file, and ArgoCD would faithfully sync the *old* tag — a green deploy that
deployed nothing. `[skip ci]` is documentation; the Guard stage in `Jenkinsfile-ci` is what actually
enforces it — removing either reopens the unbounded commit loop described under Guard above.

### 5. Deploy

```bash
argocd app sync voteball \
  --server argocd-server.argocd.svc.cluster.local \
  --grpc-web --insecure --timeout 600
```

Authenticated with the `jenkins-cd` ArgoCD local account's token (`withCredentials`). **Port 443, not
80** — `--plaintext` targets port 80, and it hangs then fails with a transport error that reads
exactly like an expired token; see the "Network exposure" note below for what is and is not actually
open on that port. `--insecure` skips verifying `argocd-server`'s self-signed certificate, acceptable
for a ClusterIP hop that never leaves the cluster (the token still authenticates the caller);
`--grpc-web` because the server does not proxy raw HTTP/2 gRPC through this path.

**No `--revision`, and `--timeout 600` not 300** — both were corrected in the code and are easy to
"restore" by mistake. The Application has `syncPolicy.automated` with `targetRevision: master`, and
ArgoCD refuses to pin a sync to an arbitrary commit while auto-sync is on (`FailedPrecondition:
Cannot sync to <sha>: auto-sync currently set to master`, build #3). Promote has already pushed the
tag bump to `master`, so syncing master *is* syncing the promoted commit. The 300s timeout was raised
after build #10 timed out pulling four cold images onto Spot nodes — and a timeout here does not just
run long, it fails the stage and trips the rollback below.

**Two ArgoCD errors are tolerated as success, and exactly one of them is `another operation is
already in progress`.** Automated sync means Promote's push can make ArgoCD start syncing before this
explicit call arrives, and ArgoCD then refuses the second concurrent operation. That is not a failed
deploy — it means the wanted sync is already running. `application-cd` #3 (2026-08-10) failed on
precisely this: Promote pushed at 12:40:17, the sync call was refused at 12:40:20, and that same
build's own post-failure event dump shows ArgoCD had already created the migrate Job pulling that
build's image. The stage failed, the rollback fired, and a deploy that was succeeding was reverted.
Rollout and Verify remain the real gates — Rollout waits for the running operation and Verify asserts
the landed revision — which is what makes tolerating the redundant command safe. It is **not** a
blanket `|| true`: a genuinely rejected sync (bad token, unknown app, RBAC denial) still fails.

### 6. Rollout

```bash
argocd app wait voteball --server ... --sync --health --timeout 300
```

Delegated to ArgoCD's own health model rather than reimplemented as `kubectl rollout status` over
three Deployments — ArgoCD already knows how to assess health per resource kind, and the CD
ServiceAccount holds no write verb that a hand-rolled rollout loop would need anyway.

### 7. Verify

Reads ArgoCD's own verdict rather than re-deriving one:

```bash
argocd app get voteball ... -o json
# assert status.sync.status == Synced, status.health.status == Healthy,
# status.sync.revision starts with $PROMOTE_SHA
```

Followed by one `kubectl get deployments,pods,services,ingress -n devops-app` through the CD agent's
read-only `deploy` container — **evidence capture for the brief's §10 requirement, not a second
opinion**. It is the only `kubectl` call in the happy path, and it is read-only.

### 8. Smoke Test

```bash
SMOKE_BASE_URL="https://$APP_DOMAIN" scripts/ci/smoke-test.sh
```

The one check in the whole system that asks the *product*, not the platform, whether it works.
ArgoCD's `Healthy` means pods pass their probes; a backend that starts cleanly and 500s on every query
is `Healthy` to ArgoCD and broken to a visitor. `smoke-test.sh` retries with backoff against three
endpoints: `/` (site root loads), `/api/options` (backend reads the database), `/api/results?by=all`
(the worker-computed rollup tables are readable — the deepest failure the other two cannot see). It
deliberately does **not** check `/health`: that path is already what the kubelet probes and what
ArgoCD's health assessment is built on, so re-checking it here would just re-ask a question ArgoCD
already answered.

### Failure Handling and automatic rollback (`post { failure }`)

On any failure in Deploy, Rollout, Verify or Smoke Test — see Rollback below.

### Cleanup

`post { cleanup }`, **not** `post { always }` — Jenkins runs post blocks in a fixed order (`always`,
..., `failure`, ..., `cleanup`), and `cleanWs()` in `always` would delete the workspace *before* the
`failure` block's rollback logic can read `scripts/ci/previous-tag.sh`, which needs the git history
still checked out. Placing the workspace wipe in `cleanup` (which always runs last) keeps the
rollback's `git log` working on exactly the failure path where it matters most.

---

## Rollback

**Automatic**, on any failure in Deploy, Rollout, Verify or Smoke Test (decided 2026-08-04; design doc
§8). `scripts/ci/previous-tag.sh` reads `git log -p` on `charts/voteball/values.yaml` for the *second*
most recent `tag:` value written by a promote commit — the first is the tag that just failed. The
`post { failure }` block then re-runs `application-cd` against that previous tag with
`ROLLBACK_DEPTH` incremented, so rolling forward and rolling back go through the exact same code path
(Promote → Deploy → Rollout → Verify → Smoke Test) rather than two different mechanisms that could
drift apart.

**Bounded to one retry.** `ROLLBACK_DEPTH >= 1` on entry to `post { failure }` means this build is
*itself* a rollback and it *also* failed verification — the second failure in a row means the problem
is not "which tag", so the pipeline stops, reports "**NEEDS A HUMAN**", and leaves production running
whatever it currently runs rather than oscillating between two tags forever. This was reproduced for
real against a scratch repo before being accepted as the design: `previous != TAG` alone does not
terminate the cycle, since a failing deploy of commit `c` rolls back to `b`, whose own rollback (if it
also fails) reads its "previous" as `c` again, alternating `b, c, b, c, ...` indefinitely. Depth
bounds it to exactly one bounce.

**Diagnostics run before the rollback**, not after — once the rollback lands, the evidence of what
broke is gone. `post { failure }` dumps `kubectl get events --sort-by=.metadata.creationTimestamp`
(last 40 lines) and the last 200 log lines of each Deployment before deciding whether to roll back.

**The rollback target is checked against ECR before it is used** (`scripts/ci/rollback-target.sh`,
added 2026-08-17). `previous-tag.sh` answers "what did `values.yaml` say before this deploy?" from git
history — but **git history survives a teardown and ECR does not**. `terraform destroy` deletes the
repositories (`force_delete = true`) and the next `deploy.sh` pushes exactly one tag, so between a
rebuild and the first successful CD promote, the tag git calls "previous" belongs to the *previous
cluster's* registry. Measured on 2026-08-17 right after a rebuild: `previous-tag.sh` returned
`61256d4` while ECR held only `480ee8b`.

The old behaviour was worse than a failed rollback. It triggered a rollback build against the missing
tag; that build died in **Input Validation**, which runs *before* Promote, so `PROMOTE_SHA` was never
set on it, the depth bound never ran, and the console said `Images for <tag> are NOT all in ECR` — a
message that reads like a mistyped parameter. Now the guard runs first and the build says what is
actually true: *"git names `<tag>` as the previous version, but that tag is NOT in ECR … PRODUCTION IS
LEFT RUNNING `<tag>`, WHICH FAILED VERIFICATION, AND NEEDS A HUMAN"*, with the recovery command.

It **fails safe toward "needs a human"** — the opposite direction to `images-exist.sh`, whose lookup
failures yield "missing" so the pipeline rebuilds. A redundant rebuild is cheap; attempting a recovery
that cannot work costs ten minutes and then misreports why. The two failure verdicts stay distinct on
purpose (`NO_ROLLBACK_TARGET`, exit 3, vs `NO_PREVIOUS_TAG`, exit 4) because they need different human
responses: "that image is gone, pick another tag" versus "there has never been another version".

It takes the tag as an argument so CD can resolve it in `jnlp` (git, where Promote already pushes) and
check ECR in the `deploy` container (aws, where Input Validation already calls `images-exist.sh`) — no
container in the `voteball-deploy` pod is proven to do both against that workspace, the same split and
the same reason as `Jenkinsfile-ci` running its script suite twice.
`scripts/tests/test-rollback-target.sh` covers it offline by building throwaway git repos, and asserts
`Jenkinsfile-cd` still calls the script — an orphaned guard is exactly how `previous-tag.sh` sat
silently disarmed by an escaping bug on 2026-08-04.

**Rollback never fires for a failure before Promote.** A failure in Input Validation or Manifest
Validation changed nothing, so there is nothing to undo; rolling back then would deploy an older tag
for no reason. This is `if (env.PROMOTE_SHA)` in the Groovy — `PROMOTE_SHA` is only set once the
Promote stage's commit actually lands.

**The manual rollback procedure is the same machinery, not a separate runbook:**

> Run `application-cd` with `IMAGE_TAG` set to any older commit SHA. That is the whole procedure; it
> is the same machinery the automatic rollback uses.

Why not `argocd app rollback` (reverting to a previous ArgoCD history entry without touching git)?
Rejected in the design (§8) because it leaves `master` asserting a version the cluster is not
running — `selfHeal` would reapply the bad tag at the next reconciliation. Rolling back *through git*
keeps git the single source of truth in both directions.

---

## First-time setup runbook

Originally done once, through Terraform and the Jenkins UI (for the UI-only parts).

**1. Seed the Jenkins secret, once per account, before first apply.**

```bash
./scripts/seed-jenkins-secret.sh
```

Prints a deploy public key to add to GitHub (with write access) and the webhook secret. The
`ARGOCD_AUTH_TOKEN` field in the payload is deliberately left empty here — see step 5.

> **"Once per account" does not survive a teardown** — steps 1 and 4 both repeat after every
> destroy/rebuild, for the reasons in "What a build agent is" above (a rebuild mints a fresh deploy
> key; GitHub still holds the old one). Since 2026-08-03 `deploy.sh` re-registers the deploy key
> automatically at step 3c via `SKIP_PROBE=1 ./scripts/register-github-ci.sh`, so step 4 below is only
> needed standalone or when that step warned.

**2. `terraform apply -var-file=voteball.tfvars`** from `terraform/`. This is the **main** stack — no
separate `jenkins.tfvars`, no second `terraform init`. It creates the `ci` namespace, both agents'
IRSA roles, the EFS filesystem and its StorageClass (`terraform/addon-efs.tf`), the webhook's ACM
certificate, `charts/jenkins-support` (ExternalSecret, RBAC, NetworkPolicies), and the two
`helm_release`s (`jenkins`, `jenkins_support`).

**3. Reach the UI to confirm it booted.**

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080
# then browse http://localhost:8080
```

Login is the username/password seeded in step 1. There is no SSH tunnel, no Elastic IP, no
`admin_cidr` to keep in sync with an ISP.

**4. Add the GitHub webhook.** Repo → Settings → Webhooks → Add:

- Payload URL `https://jenkins.<app_domain>/github-webhook/` — **the trailing slash is required**
- Content type `application/json`, Secret = the same shared secret from step 1, event: just the push
  event

This is the one step that stays manual for the same reason it always was: nothing in this design
gives Jenkins its own ability to register a hook.

**5. Mint and merge the ArgoCD token — new for the split.** ArgoCD does not exist on a fresh install
until step 2's apply creates it, so the `jenkins-cd` account's token cannot be minted before then, and
step 1's secret payload has to leave `ARGOCD_AUTH_TOKEN` empty. After step 2:

> **Since 2026-08-04, `deploy.sh` does this automatically at step 7b**
> (`./scripts/seed-argocd-token.sh`) — it mints the token via the ArgoCD API, merges it into
> `voteball/jenkins` without touching the other five keys, forces the ExternalSecret refresh, and
> restarts the controller, all in one idempotent step (it changes nothing if the stored token still
> authenticates; `FORCE_ROTATE=1` mints a new one regardless). The manual procedure below is only
> needed standalone — outside `deploy.sh`, or if that step warned.

```bash
argocd account generate-token --account jenkins-cd \
  --server argocd-server.argocd.svc.cluster.local --grpc-web --insecure   # run from a pod with the CLI, or port-forward argocd-server first

aws secretsmanager get-secret-value --secret-id voteball/jenkins --query SecretString --output text \
  | jq --arg tok "<token from above>" '.ARGOCD_AUTH_TOKEN = $tok' \
  | xargs -0 -I{} aws secretsmanager put-secret-value --secret-id voteball/jenkins --secret-string '{}'
```

**Then restart the controller so it actually picks the token up.** This is not optional and was hit
for real during the split: `containerEnvFrom` projects the Secret's keys into the pod's environment at
**pod start**, not continuously — a new key added to Secrets Manager (and synced into the Kubernetes
Secret by ESO) does **not** reach an already-running controller. Confirmed live: the token was correct
in Secrets Manager *and* in the Kubernetes Secret while JCasC still resolved `${ARGOCD_AUTH_TOKEN}` as
empty, because the controller pod had started before either existed.

```bash
kubectl rollout restart statefulset jenkins -n ci
```

**And check for the quiet failure mode, not just a crash.** JCasC does **not** fail fatally on an
unresolved `${ARGOCD_AUTH_TOKEN}` — it logs `Found unresolved variable 'ARGOCD_AUTH_TOKEN'. Will
default to empty string` and boots anyway. The controller comes up healthy, the `application-cd` job
exists, and the credential is silently empty — more dangerous than a crash, because nothing about the
controller's own status says so. After the restart, confirm with:

```bash
kubectl logs -n ci jenkins-0 -c jenkins | grep -i "unresolved variable"   # expect: nothing
```

**6. Run each job once with no parameters (G6).** Jenkins registers a pipeline's `parameters` block
only after it has read the `Jenkinsfile` during a build, so `FORCE_BUILD` (on `application-ci`) and
the deploy parameters (on `application-cd`, though these are Job-DSL-declared and appear immediately)
may not show until then. **That first `application-ci` run doing nothing is expected, not a fault.**

To change configuration afterwards: edit `ci/jenkins/jenkins.yaml` (or the Helm values in
`terraform/addon-jenkins.tf`), commit, then `terraform apply`. The chart's config-reload sidecar
picks up the new JCasC without a manual restart in the common case; if it doesn't, delete the Jenkins
pod (or `kubectl rollout restart statefulset jenkins -n ci`) and let it reschedule.

---

## Running the instance

There is no instance to start or stop. Jenkins runs whenever the cluster runs, and is torn down with
it by `terraform destroy` — there is no equivalent of "stop it to save money", because there is no
separate bill for it beyond the small EFS cost noted below: it is pods on nodes the cluster already
has running for the app.

**`JENKINS_HOME` is a PersistentVolumeClaim on EFS (`efs-sc` StorageClass, `Retain` policy), not an
`emptyDir`.** This changed in the 2026-08-04 split — the course brief lists persistent Jenkins-home
storage as a mandatory component, and `emptyDir` cannot satisfy it. The reasoning that originally
rejected a PVC still holds and is exactly *why* the PVC had to be EFS-backed rather than EBS-backed:
the node group is 100% Spot and reclaimed roughly once a day (measured: three reclaims in ~84 hours —
see `docs/design/2026-07-30-jenkins-on-eks-design.md` §2), and an **EBS volume is locked to one
Availability Zone**, so an EBS-backed PVC would need every reschedule to land back in the same AZ or
the pod hangs `Pending` — the one failure mode that needs a human. **EFS is a network filesystem
reachable from a mount target in every AZ**, so it carries none of that AZ-lock risk. See
`terraform/addon-efs.tf` for the filesystem, mount targets, security group (TCP 2049 from the node
security group only) and the `aws-efs-csi-driver` add-on; cost is roughly $1–2/month at this size.

**What this changes and what it does not.** Build history (build numbers, the last 20 logs) now
survives a routine Spot reclaim — the PVC rebinds to the same EFS data. What does **not** change: JCasC
remains the sole source of truth, and the controller still rebuilds its entire configuration from
`ci/jenkins/jenkins.yaml` on every boot regardless of what the volume holds — nothing in this design
starts depending on the volume's contents for correctness. The durable record of what was *deployed*
(as opposed to what Jenkins remembers building) was never the build log anyway — it is the
`ci: image tag <sha> [skip ci]` commits on `master`, which never expire and survive every teardown.

**Storage survives three different events three different ways** — see
[`docs/eks/architecture.md`](eks/architecture.md) diagram 6 and
[`scripts/jenkins/uninstall-jenkins.sh`](../scripts/jenkins/uninstall-jenkins.sh) for the exact
mechanics:

| Event | What happens to build history | What happens to the underlying data |
|---|---|---|
| Spot reclaim of the controller pod (routine, ~daily) | **Survives** — the same PVC rebinds | untouched |
| Removing the Jenkins release only (`helm uninstall`, or `scripts/jenkins/uninstall-jenkins.sh`'s `terraform destroy -target=helm_release.jenkins`) | **Lost** — the PVC has no `helm.sh/resource-policy: keep` annotation, so it is deleted and the PV released | **Intact** — `efs-sc`'s reclaim policy is `Retain`, so the EFS access point's data is not deleted; a reinstall provisions a *new* access point rather than rebinding the old one, so recovering prior history needs a manual PV rebind (`scripts/jenkins/uninstall-jenkins.sh` documents the steps) |
| Full `terraform destroy` of the EFS resources (whole-stack teardown) | Lost | **Gone for good** — the filesystem itself is deleted |

To force a fresh controller (e.g. after a JCasC change that needs a full restart to pick up):

```bash
kubectl rollout restart statefulset jenkins -n ci
```

It comes back configured from JCasC within about a minute, with no plugin download — the plugin set
is baked into the controller image (`ci/jenkins/Dockerfile`), rebuilt out-of-band with
`scripts/build-push-ecr.sh jenkins <tag>` whenever `plugins.txt` changes, which is rare — **and now
with its build history intact**, since the routine restart path (a Spot reclaim, or this command) is
exactly the case the PVC rebinds through.

---

## Failure modes

The first block happened for real during the 2026-07-30/31 move to EKS and is recorded with actual
symptoms, because in every case the symptom pointed somewhere other than the cause. A second block was
added during the 2026-08-04 CI/CD split, for the same reason. The rest are the G1–G7 differences the
original 2026-07-20 design predicted and remain accurate, now labelled against `Jenkinsfile-ci`.

| Symptom | Cause | Fix |
|---|---|---|
| Declarative pipeline fails to parse; no stage ever runs | An empty `environment {}` block — declarative Groovy rejects it outright | Remove the block entirely; nothing needs to live in it (see the comment at the top of `Jenkinsfile-ci`) |
| Controller `CrashLoopBackOff`, nothing useful in `kubectl describe pod` or events | JCasC `defaultConfig: true` in the Helm values collides with `ci/jenkins/jenkins.yaml` defining the same keys — `ConfiguratorConflictException`, exit code 5 | `controller.JCasC.defaultConfig = false` in `terraform/addon-jenkins.tf`; add anything missing to `ci/jenkins/jenkins.yaml` instead |
| Agent pod sits at "healthy but short of full", `application-ci` build hangs on "still waiting to schedule" forever, nothing logged | `allowPrivilegeEscalation: false` (or missing `SETUID`/`SETGID`) on the `voteball-build` template's `buildkit` container | `buildkit` needs `allowPrivilegeEscalation: true` and `capabilities.add: [SETUID, SETGID]`, `seccompProfile`/`appArmorProfile` `Unconfined` — see `ci/jenkins/jenkins.yaml`'s long comment on exactly what this does and does not grant |
| Agent pod goes fully Running, but the build never proceeds — no error, just silence until `retentionTimeout` reaps the pod | The `ci` NetworkPolicy's egress allowlist excluded the VPC's own pod range, so the agent has no permitted route to the controller | The egress policy must explicitly re-allow same-namespace pod-to-pod traffic (`- to: [{ podSelector: {} }]`) — see `charts/jenkins-support/templates/networkpolicy.yaml` |
| `aws: not found`, exit code 127 | A step ran outside `container('awscli')` (CI) or `container('deploy')` (CD) — steps outside any `container()` run in `jnlp`, which has git but neither CLI | Wrap every `aws` invocation in the right `container()` block |
| `[Errno 13] Permission denied: '/.aws'` (or Trivy failing to write `$HOME/.cache`) | Every container runs as uid 1000, but the base images assume root and leave `HOME=/`, unwritable | `env: [{ name: HOME, value: /tmp }]` — already applied to every container in both pod templates |
| `401 Unauthorized` against `*-buildcache`, minutes into a build | `buildctl` reads `$DOCKER_CONFIG/config.json` and inherits nothing from IRSA automatically | The `awscli` container writes an ECR login to `/images/dockercfg/config.json`; `buildkit` exports `DOCKER_CONFIG` before calling `buildctl` |
| ECR returns a bare `400 Bad Request` on the cache manifest PUT, after the image already built and every layer uploaded | BuildKit's default cache export is an OCI image *index*, which ECR's manifest API rejects | `--export-cache ...,image-manifest=true,oci-mediatypes=true` |
| Trivy fails with `manifest.json not found in tar`, reads like a corrupt image | `--output type=oci` (an OCI *archive*) instead of `type=docker` (a docker-archive tar); Trivy's `--input` reads the latter, not the former | `--output type=docker,dest=...` |
| `application-cd`'s Promote stage fails with `Host key verification failed`, after nothing else was touched (Promote is CD's first writing stage) | The JCasC-pinned host key only covers the git **plugin**'s checkout in each job. `Promote` shells out to raw `git push` in `jnlp`, which has its own, separate `~/.ssh/known_hosts` | Write the pinned GitHub host key into `~/.ssh/known_hosts` inside the stage before pushing — already applied in `Jenkinsfile-cd`'s Promote stage |
| **G2** — `application-ci` rebuilds its own tag-bump commit, forever, and re-triggers `application-cd` each time | The Guard stage or `scripts/ci/should-skip-build.sh` was removed | Restore the Guard stage — first, unconditional, in `Jenkinsfile-ci` |
| **G1** — re-running `application-ci` fails with `tag already exists` | ECR tags are `IMMUTABLE`, images tagged by commit SHA | Already handled by "Already built?"; if it still fails, check the `jenkins-agent` IRSA role has `ecr:DescribeImages` |
| A commit you expected to build finishes `NOT_BUILT` immediately | The commit's **subject line** contains the skip marker. Since 2026-08-11 the body is *not* matched — it used to be, and that misfired: two commits whose bodies described the guard skipped themselves, so two CI changes shipped without CI ever running and reported `NOT_BUILT`, which reads like a pass | Expected only if the marker really is in the subject. Amend the subject and push again |
| **G3** — "Build Now" on `application-ci` does nothing | The changeset contains commits, but none touch `services/**` | *Build with Parameters*, tick `FORCE_BUILD` |
| **G3b** — a **webhook** `application-ci` build reports SUCCESS but ECR gained no image | First build after the controller was recreated has no changelog to diff against | `scripts/tests/test-ci-guards.sh` fails if the `NO_CHANGELOG` branch is gone; re-run with `FORCE_BUILD` |
| **G4** — `application-cd`'s Promote stage: `git push` denied | Deploy key missing or read-only, or an HTTPS (not SSH) job SCM URL | Deploy key with **write** access + SSH SCM URL, on **both** jobs |
| **G6** — a parameter checkbox/field is missing on a job | The job has never run, so Jenkins has not fully read its `Jenkinsfile` yet | Run the job once |
| **G7** — a build failed and nobody noticed | Jenkins sends no email without SMTP | Accepted, see "Deferred, on purpose". Check the Jenkins UI, or `kubectl get application voteball -n argocd` |
| `application-cd` is triggered (by hand, usually) with a tag that is not in ECR | Someone passed a made-up or mistyped `IMAGE_TAG`, or a tag from before a `force_delete`d ECR repo | Input Validation's `images-exist.sh` check refuses it before anything is committed — the build fails at stage 2, `master` is untouched, nothing to roll back |
| `application-cd`'s `Deploy`/`Rollout`/`Verify` stages fail with an auth error against ArgoCD | The `jenkins-cd` ArgoCD account's token expired or was rotated without updating Secrets Manager, or the controller was never restarted after the token was added (see runbook step 5) | Re-mint with `argocd account generate-token --account jenkins-cd`, merge into `voteball/jenkins`, then `kubectl rollout restart statefulset jenkins -n ci` — env vars only reach a controller at pod start |
| `application-cd`'s Deploy stage fails immediately with `FailedPrecondition desc = another operation is already in progress`, and CD rolls back a deploy that was working | A race with ArgoCD's **own** automated sync, not a deploy failure. `syncPolicy.automated` means the tag-bump commit Promote just pushed can make ArgoCD start syncing seconds before the pipeline's explicit `argocd app sync` lands, and ArgoCD refuses a second concurrent operation. Hit for real by `application-cd` #3 (2026-08-10): pushed 12:40:17, refused 12:40:20, and that build's own event dump shows ArgoCD had already created the migrate Job for that build's image | Already handled — the Deploy stage treats **only** this error string as success and continues, since Rollout waits for the in-flight operation and Verify asserts the landed revision. Do not "clean this up" into a blanket `\|\| true`; every other sync error must still fail. If a deploy was already rolled back by this, re-promote the tag by hand (see Rollback) — but note `git pull --rebase` will silently **drop** that re-promote, because rolling a tag forward and back leaves two upstream commits whose patches are exact inverses, so the re-promote has the same patch-id as the original and rebase discards it as already applied, reporting only a `skippedCherryPicks` hint |
| Smoke Test fails on what looks like a perfectly healthy site, and CD rolls back a good deploy | ALB target-group warm-up: `argocd app wait --health` can report `Healthy` fractionally before the ALB has finished routing to the newly-Ready pods, so the first smoke-test attempt lands before the path is live | `smoke-test.sh` already retries (`SMOKE_RETRIES`/`SMOKE_DELAY`, default 10×6s) for exactly this; if it still rolls back, widen the retry window rather than removing the check — the check exists because ArgoCD's `Healthy` is a pod-probe verdict, not a "the site works" verdict |
| JCasC boots with a Jenkins-shaped controller and a job that silently has no credential | An unresolved `${VAR}` in `ci/jenkins/jenkins.yaml` — JCasC does **not** fail fatally on this; it logs `Found unresolved variable 'X'. Will default to empty string` and boots anyway | `kubectl logs -n ci jenkins-0 -c jenkins \| grep -i "unresolved variable"` after any secret or JCasC change; treat any hit as a failed deploy even though nothing crashed |
| A key added to `voteball/jenkins` in Secrets Manager (and visible in the synced Kubernetes Secret) is still unresolved in JCasC | `containerEnvFrom` projects the Secret into the pod's environment at **pod start**, not continuously — an already-running controller never sees a key added after it started | `kubectl rollout restart statefulset jenkins -n ci` after adding or changing any key the controller consumes |
| A stale job survives in the Jenkins UI, red, pointing at a `Jenkinsfile` that no longer exists | JCasC's Job DSL does not delete jobs it stops declaring — `removedJobAction` defaults to `ignore`. This happened for real when the single `voteball` job was replaced by `application-ci`/`application-cd`: the old job survived and had to be deleted **manually** via the Jenkins API | Delete it by hand — a bare `Jenkins-Crumb` header 403s; the call needs a session cookie jar. `scripts/jenkins/verify-jenkins.sh` asserts the job list is exactly `["application-cd","application-ci"]` for exactly this reason, and should be run with `VERIFY_STRICT=1` for evidence so a credential-less run fails loudly instead of silently skipping that assertion |
| `RepositoryNotFoundException` pushing to ECR | The main stack is destroyed — Jenkins and ECR (`force_delete = true`) go with it | Expected while torn down. `./scripts/build-push-ecr.sh` is the manual fallback |
| CI is green but the site doesn't change | No cluster, no ArgoCD Application, or `application-ci` skipped every build/scan/push stage (G3/G3b) and never triggered `application-cd`, or `application-cd` never ran | `kubectl get application voteball -n argocd`; check the CI build's log for `Stage "Build images" skipped due to when conditional`; check whether `application-cd` even started (Jenkins UI, or `SOURCE_BUILD` on the last promote commit) |
| Pods go to `ImagePullBackOff` after a sync | `values.yaml` on `master` names a tag/registry that doesn't exist in this account's ECR | `./scripts/sync-values-from-tf.sh --check` |
| The Jenkins UI shows *"It appears that your reverse proxy set up is broken"* | Cosmetic and structural: `unclassified.location.url` is the public webhook URL, but the ALB routes **only** `/github-webhook` there and the UI is reached by port-forward | Ignore it; do **not** point `location.url` at localhost — the GitHub plugin builds the webhook URL from that value |
| A build console log shows a secret in plain text (raw token, base64 auth string, etc.), even though nothing was pasted by hand | Jenkins traces every `sh` step with `set -x`, and that trace prints each command **after shell expansion**. Any secret fetched at runtime — as opposed to injected via `withCredentials`, which Jenkins knows to mask — will be printed if it ever sits in an *argument position*, since the argument is what the expanded trace line shows. `aws ecr get-login-password` used as a `printf` argument is the specific case that happened for real (2026-08-04 whole-branch review): the raw token and its base64 docker-auth form both landed in a committed evidence log | Keep runtime-fetched secrets out of argument position — write them straight to a file and read the file, never capture them into a shell variable/`$(...)` that then gets passed as an argument to another command. Do **not** "simplify" the file-based ECR-login handling in `Jenkinsfile-cd` back into a `$(aws ecr get-login-password ...)` substitution — that is exactly the shape that leaked |
| A build fails at the very end with an ECR `401 Unauthorized`, during cache import or export, after the image already built successfully | Suspect the docker-auth construction, not IAM — specifically a trailing newline in the password. `aws ecr get-login-password`'s output ends in `\n`; command substitution (`$(...)`) strips that for free, but redirecting its output straight to a file does not, so a naive file-based rewrite of the login step can silently corrupt the base64 `AWS:<token>` auth string with the SHA's or token's trailing newline still attached | `Jenkinsfile-cd` pipes the password file through `tr -d '\n'` before base64-encoding it — confirm that step is still present rather than re-deriving IAM permissions that were never the problem |

---

## Doing it by hand

`./scripts/build-push-ecr.sh` runs the build/scan/push part locally — the four app images, or (with
the `jenkins` argument) the controller image itself. `./scripts/deploy.sh` runs the full sequence
including this and the Terraform apply that installs Jenkins. **There is no CI/CD while the cluster is
destroyed** — ArgoCD is also gone during a teardown, so nothing could deploy anyway — which makes
`./scripts/build-push-ecr.sh` load-bearing rather than a convenience during that window.

Note the ordering constraint `deploy.sh` encodes: **`values.yaml` must be committed and pushed before
the ArgoCD Application is created.** Bootstrapping ArgoCD against a `master` that still holds stale
values makes it immediately revert the deploy to an image tag that no longer exists, putting every pod
in `ImagePullBackOff`.

There is no equivalent "do the deploy by hand" for `application-cd` beyond what Rollback already
covers: running it with an older `IMAGE_TAG` **is** the manual procedure, not a fallback to something
else.

---

## GitHub Actions is fully retired (2026-07-21)

`terraform/github-oidc.tf` and the `github_actions_role_arn` output were deleted, and the IAM role and
OIDC provider destroyed in AWS. Restoring it now requires the workflow file, a main-stack
`terraform apply` to recreate the role and provider, and re-adding four repository variables.

## The EC2 host is fully retired (2026-07-31)

The dedicated `t3.medium` and its whole separate Terraform stack — the Elastic IP, the separate
Terraform state, the `admin_cidr` allowlist, the SSH key pair — are destroyed and deleted. See
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md) for
the full design and its "Verification outcome" section for what the move actually broke.

## Deferred, on purpose

- **Tests-in-CI and smoke-testing are no longer deferred** — they shipped in the 2026-08-04 split
  (`application-ci`'s Tests stage; `application-cd`'s Smoke Test stage). Earlier revisions of this
  document listed both here; they are load-bearing pipeline stages now, not a future item.
- **SSM Session Manager** — moot; there is no SSH access to anything Jenkins runs on.
- **Build-failure notifications (G7).** Jenkins sends nothing without SMTP, and provisioning mail
  credentials is a surface this project declined to add. The compensating practice: verification means
  checking the Jenkins UI or ArgoCD's Application state — for a deploy that failed and rolled back,
  the rollback itself is the notification, since it changes what the site serves — **not** inferring
  success from the site still working. Recorded as a decision, not an oversight.
- **Multibranch, a shared cluster-wide BuildKit daemon, PR pipelines.** Still out of scope for the
  same reasons the 2026-07-20 and 2026-08-04 designs gave; the repo owner works solo and commits
  straight to `master`, so a PR-triggered pipeline would never fire.
