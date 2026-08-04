# Voteball on EKS — submission

A public poll correlating football fandom with Israeli political-party voting, deployed on **Amazon EKS**.
This is the turn-in document: architecture, how to run/verify/delete it, how security is handled, and the
trade-offs made. (For the plain-language deploy walkthrough see [`docs/deploy.md`](docs/deploy.md); for
the full security design see [`docs/security.md`](docs/security.md).)

**Division of work:** none to divide — this was done solo, by Ariel Palatnik. Every commit in the
repository is mine.

## Architecture

- **In Kubernetes** (`devops-app` namespace, chart `charts/voteball`): 3 Deployments — **frontend**
  (nginx, static site + `/api` proxy), **backend** (Flask/gunicorn API), **worker** (batch rollup poller)
  — plus their Services, an **Ingress→ALB**, ConfigMap, an ESO **ExternalSecret**, 4 ServiceAccounts,
  NetworkPolicies, an HPA on the backend, PDBs, a nightly **backup CronJob**, a
  **`post-install,pre-upgrade` schema-migration Job** (so schema work runs once per release rather than
  every replica racing on startup — `post-install` rather than `pre-install` because pre-install hooks
  run before the ServiceAccount and ConfigMap it needs exist), and a **PrometheusRule** carrying the
  operational alerts.
- **Outside Kubernetes (AWS, via `terraform/`):** the EKS cluster + Spot node group, a dedicated VPC
  (public/private/DB subnets, NAT), **RDS** Postgres (7-day PITR), **ECR**, **ACM** cert, **AWS WAF** in
  front of the ALB, **S3**, **SNS**, **Secrets Manager**, and the platform add-ons (AWS Load Balancer Controller, External Secrets Operator, Cluster
  Autoscaler, Node Termination Handler, CloudWatch pod logging, metrics-server, external-dns,
  ArgoCD, kube-prometheus-stack, **and Jenkins**).
- **In Kubernetes, a second namespace: `ci`.** Jenkins runs there — a controller with no AWS role at
  all, and two kinds of ephemeral pod agent: `voteball-build` (rootless BuildKit + Trivy + skopeo +
  aws-cli + a test toolchain, IRSA scoped to ECR push) runs `application-ci`; `voteball-deploy`
  (kubectl + helm + the ArgoCD CLI, IRSA scoped to ECR read-only, plus a strictly read-only Kubernetes
  Role in `devops-app`) runs `application-cd`. It is a **platform add-on like ArgoCD**, not the graded
  application namespace, so it is installed by `terraform apply` alongside the other add-ons rather
  than by ArgoCD. Full detail, including why the pipeline is split in two, is in the
  [**Task 4 — CI/CD with Jenkins in Kubernetes**](#task-4--cicd-with-jenkins-in-kubernetes) section
  below.
- **Terraform vs Helm boundary:** Terraform builds the AWS infra + cluster + platform add-ons (Jenkins
  included); the Helm chart is the app, delivered by **ArgoCD** (GitOps) from this repo's `master`. See
  `docs/deploy.md`.
- **Terraform state lives in S3** (versioned, encrypted, S3-native locking), one bucket, one key. The
  bucket belongs to no stack and is never destroyed.
- **CI config is code too:** Jenkins configures itself from `ci/jenkins/jenkins.yaml` (JCasC), applied
  via the Helm release's `controller.JCasC.configScripts`, with its credentials read from Secrets
  Manager through External Secrets Operator. Its controller is deliberately disposable — every
  setting rebuilds from JCasC on every boot, never from the UI — but `JENKINS_HOME` is a
  PersistentVolumeClaim backed by **EFS** (`efs-sc`, `Retain`), not an `emptyDir`: the node group is
  100% Spot and reclaimed roughly daily, and EFS (unlike EBS) has a mount target in every AZ, so the
  same volume rebinds wherever the controller pod reschedules. See `docs/cicd.md` for the full
  storage-survival breakdown across a reclaim, a release removal, and a full teardown.

Architecture diagram: [`docs/eks/architecture.md`](docs/eks/architecture.md).

## How to run it

Full step-by-step (with what each step does) is in **[`docs/deploy.md`](docs/deploy.md)**. In short:

```bash
./scripts/deploy.sh     # build everything and install the app
./scripts/destroy.sh    # tear it all down again
```

Both stop and ask for confirmation before Terraform touches billed resources. `deploy.sh` runs eleven
numbered steps, in order: resolve the newest DB snapshot → targeted apply for ECR + the two empty secret
containers → **seed both secrets** (app, then Jenkins) → mirror the Trivy DB into ECR → build/push the
Jenkins controller image → the full `terraform apply` → connect kubectl → build/push the 4 app images to
ECR (git-SHA tags) → **sync `values.yaml` from Terraform outputs** → `helm upgrade --install` →
bootstrap **ArgoCD**, which owns the release from then on.

**Seeding before the apply, not after it, is load-bearing** — and it was the other way round until
2026-07-31. The full apply creates the Jenkins release and its ExternalSecret together, and External
Secrets Operator copies the vault into the cluster once at creation and then only hourly; seeding
afterwards boots Jenkins with no admin account and 401s every login for an hour, while the deploy
reports success throughout.

That sync step matters: the RDS endpoint, ACM certificate ARN, S3 bucket and IRSA role ARNs are all
regenerated on every rebuild, so `charts/voteball/values.yaml` is **generated, never hand-edited**
(`./scripts/sync-values-from-tf.sh --check` fails on drift and verifies the image tag exists in ECR).

`destroy.sh` encodes the order that actually works — ArgoCD Application first (or `selfHeal` recreates
what you delete), then **both** Ingresses (the app's and the CI webhook's, which share one ALB group, so
deleting either alone leaves the ALB running and its ENIs blocking the VPC), then Terraform — and takes a
final DB snapshot, so a destroy/rebuild cycle preserves the votes.

### The three steps `deploy.sh` hides: images, namespace, secret

Those are wrapped in the script above, so here is each one on its own — this is what to run if you are
doing it by hand, and what the script does on your behalf if you are not.

**Building and pushing the images.** Four images, one Docker build context each
(`services/{backend,worker,frontend,backup}/`), tagged with the **git SHA** — never `latest`:

```bash
./scripts/build-push-ecr.sh          # builds all four, logs in to ECR, pushes <account>.dkr.ecr.<region>.amazonaws.com/voteball-{backend,worker,nginx,backup}:<sha>
```

In normal operation Jenkins does this on every push to `master` (rootless BuildKit → Trivy scan →
ECR), and the script is the manual path — it is also the **only** way to build while the cluster is
destroyed, since CI lives inside the cluster.

**Creating the namespace.** `devops-app` is created by Helm itself:

```bash
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace
```

**It is deliberately not a template in the chart.** A `Namespace` is a *cluster-scoped* object, and
the ArgoCD `AppProject` this Application runs in sets `clusterResourceWhitelist: []` — it is allowed
to create namespaced objects in `devops-app` and nothing else, anywhere. Shipping the namespace
inside the chart it deploys would mean widening that whitelist, i.e. handing the app's own release
permission to create cluster-scoped resources, to save one flag. `CreateNamespace=false` in
`argocd/voteball-application.yaml.tmpl` records the same decision on the ArgoCD side.

**Creating the real Secret.** The chart never contains a secret value — it ships an
**ExternalSecret**, and External Secrets Operator fills the `app-secret` Kubernetes Secret from AWS
Secrets Manager. The shape of that secret is documented in
**[`charts/voteball/secret-example.yaml`](charts/voteball/secret-example.yaml)** (an example file with
`REPLACE` placeholders — it is never applied). To create the real one:

```bash
ADMIN_USERNAME='<admin user>' ADMIN_PASSWORD='<admin password>' ./scripts/seed-eks-secret.sh
```

It reads `DB_PASS` from `terraform/voteball.tfvars` (so it cannot drift from the RDS master password),
hashes the admin password with `werkzeug`, generates `ADMIN_SESSION_SECRET` itself, and writes the
JSON to Secrets Manager. Nothing is echoed, and nothing is written to disk. Two things to know before
re-running it: it **overwrites** the secret every time (a fresh `ADMIN_SESSION_SECRET` invalidates
every live admin session, and `ADMIN_USERNAME` reverts to `admin` unless you pass it), and ESO copies
the vault into the cluster at ExternalSecret creation and then only hourly — which is why deployment
seeds the secret **before** the resources that consume it, not after.

If you want to see the Secret without applying anything:

```bash
kubectl get secret app-secret -n devops-app -o jsonpath='{.data}' | jq 'keys'   # key NAMES only
```

## CI/CD — Jenkins (in-cluster) → ECR → ArgoCD

```
git push (services/**) → webhook → application-ci (test/build/scan/push) → application-cd (promote/deploy/verify) → ArgoCD → pods roll
```

CI/CD is **Jenkins**, running inside the cluster itself (namespace `ci`), installed by Terraform as a
`helm_release` of the official chart, split since 2026-08-04 into **two pipelines**: `application-ci`
tests, builds, scans and pushes; `application-cd` promotes a tag, has ArgoCD deploy it, verifies the
live site, and rolls back automatically on failure. Neither can do the other's job — CI holds no
cluster credentials at all, CD holds a strictly read-only Kubernetes Role and cannot build an image.
The full walkthrough — every stage of both pipelines, the two agent pod templates, the rollback
mechanism, install/verify/uninstall, the secrets, the security posture and why ArgoCD (not
`helm upgrade --install`) stays the applier — is in the dedicated
**[Task 4 — CI/CD with Jenkins in Kubernetes](#task-4--cicd-with-jenkins-in-kubernetes)** section
below; this section stays a summary.

Three decisions worth calling out here:

- **Jenkins never deploys and holds no cluster-write credentials in either pipeline.** CI stops at
  "push images, hand the tag to CD"; CD stops at "ask ArgoCD to sync, then read the result back."
  **ArgoCD** performs every write. A compromised build pod cannot touch the rest of the cluster — its
  ServiceAccount has zero RBAC anywhere. A compromised deploy pod can ask ArgoCD to sync a commit and
  read `devops-app`, and nothing more.
- **No stored AWS keys anywhere.** CI's agent authenticates through **IRSA** scoped to ECR push;
  CD's agent through a *separate* IRSA role scoped to ECR **read-only**; the controller itself carries
  **no AWS role at all**. A NetworkPolicy separately denies the whole `ci` namespace any route to RDS
  or the app namespace.
- **The `buildkit` container is the one exception to "no privilege escalation" in the whole project.**
  Rootless BuildKit needs `allowPrivilegeEscalation: true` + `SETUID`/`SETGID` to create its own user
  namespace — still uid 1000, no host access, nothing like Docker-in-Docker's `privileged: true`, which
  was rejected for exactly that reason. See `docs/security.md`.

The most important check is the one that runs unattended: **Jenkins has no native `[skip ci]`** — that
is a GitHub Actions feature — so without an explicit Guard stage in `application-ci`, `application-cd`'s
own tag-bump commit would retrigger `application-ci`, which would retrigger `application-cd` again, in
an unbounded, billable loop across both jobs that also rolls production pods continuously.

Full pipeline walkthrough, stage-by-stage, the first-time setup runbook, and a failure-modes table are
in **[`docs/cicd.md`](docs/cicd.md)**; the design rationale for the pipeline's original *logic* is in
[`docs/design/2026-07-20-jenkins-migration-design.md`](docs/design/2026-07-20-jenkins-migration-design.md),
the rationale (and verification outcome) for running it *in the cluster instead of on a dedicated
EC2 host* is in
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](docs/design/2026-07-30-jenkins-on-eks-design.md),
and the rationale for the **two-pipeline split** — including why ArgoCD stays the applier — is in
[`docs/design/2026-08-04-cicd-split-design.md`](docs/design/2026-08-04-cicd-split-design.md).

**The controller is disposable, but `JENKINS_HOME` is not.** The node group is 100% Spot, reclaimed
roughly once a day; `JENKINS_HOME` is a PersistentVolumeClaim backed by **EFS** (not EBS — an EBS
volume is AZ-locked and would hang the pod `Pending` on a reschedule into the "wrong" AZ; EFS has a
mount target in every AZ), so build history now survives a routine reclaim. What is unchanged: the
controller's *configuration* still rebuilds entirely from JCasC on every boot, never from the UI, and
losing the volume entirely (a full teardown of the EFS resources) is still a recoverable event, not a
disaster — the durable record of what was *deployed* is the `ci: image tag <sha> [skip ci]` commits on
`master`, which never expire. Two things remain **deliberately deferred**: SSM Session Manager (moot —
there is no SSH access to anything Jenkins runs on), and build-failure notifications — Jenkins sends no
email without SMTP, so verification means checking the Jenkins UI or ArgoCD's state (and, for CD, the
fact that a failed deploy rolls itself back) rather than assuming success.

## Task 4 — CI/CD with Jenkins in Kubernetes

This section is the self-contained answer to the course's CI/CD assignment (*משימה 4*), in the order
its own brief asks for. It overlaps deliberately with material earlier in this document — the brief is
graded as its own unit, so this section does not assume a grader has read the rest first.

### Architecture, and why EKS

The CI/CD platform is not a separate system bolted onto the EKS deployment — it runs **on the same
cluster**, in its own namespace (`ci`, alongside `devops-app`), provisioned by the same Terraform
stack. That was the deciding factor for keeping it on EKS rather than standing up a separate host or
managed CI service: the assignment's thesis is that everything is Kubernetes-native and
configuration-as-code, and a hand-run CI box (the project's own EC2-hosted Jenkins predecessor, retired
2026-07-31) is the one thing that would have contradicted it. Running in-cluster also means Jenkins'
build agents can reach the same OIDC provider the application pods use for IRSA, so "no static AWS
keys anywhere" extends to CI/CD without inventing a second credential mechanism.

Two Jenkins **jobs**, each with its own **Jenkinsfile** at the repo root and its own **agent pod
template** in JCasC: `application-ci` (`Jenkinsfile-ci`, template `voteball-build`) tests, builds,
scans and pushes; `application-cd` (`Jenkinsfile-cd`, template `voteball-deploy`) promotes, deploys via
ArgoCD, verifies, and rolls back. They hand off through Jenkins' own `build job:` trigger — one of the
brief's permitted CI→CD connection mechanisms — passing the image tag, digest and originating CI build
number as parameters. See [`docs/eks/architecture.md`](docs/eks/architecture.md) diagrams 5 (Pipeline
Flow) and 6 (Deployment View) for the two required diagrams, drawn directly from the stage names in
`Jenkinsfile-ci`/`Jenkinsfile-cd` rather than summarized from memory.

### Prerequisites and tool versions

Nothing beyond what the rest of this repo already needs: `terraform` (`>= 1.11.0`, pinned in
`terraform/versions.tf`), the `aws` CLI (logged in), `kubectl`, `helm`. To operate Jenkins directly —
optional, only needed for manual verification or the runbook steps below — the `argocd` CLI matching
server v3.4.5 (the CD pipeline carries its own copy inside the agent pod, so this is only for a human
running commands from a laptop) and `jq`. Pinned component versions, so the same run of `terraform
apply` is reproducible: EKS **1.36** (standard support until 2027-08-02, `terraform/variables.tf`),
Jenkins Helm chart **5.9.45** (app v2.568.1), ArgoCD Helm chart **10.2.1** (app v3.4.5),
`moby/buildkit:v0.19.0-rootless`, `aquasec/trivy:0.58.1`, `alpine/k8s:1.31.3` for the CD agent's
`deploy` container. No component pulls `latest`, checked mechanically by `application-ci`'s Validation
stage.

### Install / configure / verify / uninstall

```bash
./scripts/jenkins/install-jenkins.sh      # targeted terraform apply: EFS + both helm_releases
./scripts/jenkins/verify-jenkins.sh       # asserts the brief's whole §10 checklist, non-zero on failure
./scripts/jenkins/uninstall-jenkins.sh    # targeted terraform destroy: removes Jenkins, leaves the app
```

All three are **thin wrappers around Terraform**, not a parallel install path — Jenkins is a platform
add-on Terraform owns (like ArgoCD, ESO and external-dns), not an application ArgoCD deploys, so a
second install mechanism would misrepresent how the repo actually works. `install-jenkins.sh` is for
the case where the cluster already exists and only the Jenkins add-on needs (re)installing; a full
first deploy uses `./scripts/deploy.sh`, which calls the same underlying `terraform apply`.

**Configuring** Jenkins after the first install means editing `ci/jenkins/jenkins.yaml` (JCasC) or the
Helm values in `terraform/addon-jenkins.tf`, committing, then running `terraform apply` again — **not**
committing to `master` and walking away, which is how `charts/voteball` is updated but is a no-op here.

**Verifying** is not a checklist for a human to eyeball. `verify-jenkins.sh` runs every command the
brief's §10 lists (`kubectl get namespaces`, `pods -n ci -o wide`, `service,ingress,pvc -n ci`,
`serviceaccount,role,rolebinding -n ci`, `helm list -n ci`, plus an authenticated Jenkins API check)
and **asserts** on the results: both namespaces exist, the controller is Ready, the home PVC is
`Bound`, the webhook Ingress routes only `/github-webhook` (the UI is not internet-facing),
`jenkins-cd-agent` genuinely cannot patch `devops-app` (and genuinely can read it), the `jenkins`
release is installed, exactly the two expected jobs exist (`application-cd`, `application-ci` — no
stale leftovers, see Security below), and `numExecutors` is `0`. **Evidence runs must set
`VERIFY_STRICT=1`**, which turns a credential-less skip into a hard failure — without it, a run with no
Jenkins admin credentials on hand still prints `ALL CHECKS PASSED`, which would misrepresent an
incomplete check as a complete one for anyone reading the evidence later.

**Uninstalling** removes the Jenkins and jenkins-support Helm releases (and their Ingress) without
touching `devops-app`, RDS, or the ArgoCD Application. It does **not** delete the EFS filesystem or its
data — only a full `terraform destroy` of the EFS resources does that — see "Full teardown" below and
the storage-survival table in `docs/cicd.md`.

### How the two jobs are created from code

**Neither job was ever created by clicking in the Jenkins UI.** Both are declared in the `jobs:` block
of `ci/jenkins/jenkins.yaml`, using the Job DSL plugin's `pipelineJob(...)` syntax, applied by the
Helm release's `controller.JCasC.configScripts` at every controller boot:

```groovy
pipelineJob('application-ci') {
  // properties, parameters, triggers { githubPush() }, logRotator { numToKeep(20) }
  definition {
    cpsScm {
      scm { git { remote { url('git@github.com:${GITHUB_REPO}.git'); credentials('voteball-deploy-key') }; branch('*/master') } }
      scriptPath('Jenkinsfile-ci')
    }
  }
}
```

`application-cd`'s declaration is identical in shape, minus the `githubPush()` trigger (it is started
by `application-ci`'s `build job:` call, or by hand — a push trigger on CD would deploy every commit
regardless of whether CI passed). Both jobs are deliberately **thin**: everything about *how* to build
or deploy lives in `Jenkinsfile-ci`/`Jenkinsfile-cd`, in the repository; the JCasC blocks only say where
to find them and when to run them. A UI-created job would not survive the next controller restart
anyway (roughly daily, on Spot) — JCasC is not a convenience here, it is the only mechanism that
persists.

### How to create the secrets

Two independent secrets, both in AWS Secrets Manager, both synced into the cluster by External Secrets
Operator — nothing secret ever enters git, Terraform state, or a Jenkinsfile:

```bash
./scripts/seed-eks-secret.sh       # the APPLICATION secret: DB password, admin credentials
./scripts/seed-jenkins-secret.sh   # the JENKINS secret: admin login, GitHub deploy key, webhook secret, ArgoCD token
```

Their shapes are documented, with every value replaced by a placeholder, in
[`charts/voteball/secret-example.yaml`](charts/voteball/secret-example.yaml) and
[`ci/jenkins/secret.example.yaml`](ci/jenkins/secret.example.yaml) — neither file is ever applied; they
exist so the schema is reviewable without the values being readable. `seed-jenkins-secret.sh` is a
no-op once a real deploy key exists (it prints two confirming lines and changes nothing), specifically
so `deploy.sh` can call it on every run without rotating a key GitHub already trusts; the ArgoCD token
field is filled in separately, after ArgoCD exists — see the first-time setup runbook in
`docs/cicd.md`, which this section does not repeat in full.

### Running CI

Trigger: a GitHub webhook on every push to `master`, or *Build with Parameters* → `FORCE_BUILD` by
hand. Stage list, in order (from `Jenkinsfile-ci`): **Guard** (refuses its own tag-bump commits) →
**Validation** (repo-shape checks) → **Lint/Static Analysis** (`ruff`, `hadolint`) → **Tests** (153
pytest tests against a real, ephemeral Postgres sidecar) → **Resolve tag and account** → **Already
built?** (skip if this SHA's images already exist in the immutable ECR repos) → **Build images**
(rootless BuildKit, four contexts) → **Trivy scan** (blocking on HIGH/CRITICAL for the app images) →
**Push to ECR** → **Publish Metadata** (digests, archived as `image-metadata.json`) → **Trigger CD**.

**The image tag is the short git commit SHA, resolved with `git rev-parse --short HEAD` — never
`latest`.** Every deployed pod therefore maps to an exact commit, and `application-ci`'s own Validation
stage fails the build if any Dockerfile pins (or implicitly resolves to) `:latest`.

### Running CD

Parameters: `IMAGE_TAG` (required — must already exist in ECR, checked, not trusted), `IMAGE_DIGEST`
and `SOURCE_BUILD` (traceability, optional), `NAMESPACE` (default and only allowed value:
`devops-app`), `ROLLBACK_DEPTH` (internal, never set by hand). Target: the `voteball` ArgoCD
Application, which applies to `devops-app`. Stage list: **Checkout** → **Input Validation** (rejects
`latest`, non-SHA values, and tags not present in ECR) → **Manifest Validation** (`helm lint` +
`helm template` + `kubectl apply --dry-run=client`) → **Promote** (writes `image.tag`, commits
`ci: image tag <sha> [skip ci]`, pushes) → **Deploy** (`argocd app sync --revision <promote-sha>`) →
**Rollout** (`argocd app wait --sync --health`) → **Verify** (reads ArgoCD's own sync/health verdict,
then one read-only `kubectl get` purely to capture evidence) → **Smoke Test** (real HTTPS requests
against the live site — root, `/api/options`, `/api/results?by=all` — not just a probe check).

**Success is verified three separate ways, deliberately redundant**: ArgoCD reports `Synced` +
`Healthy` at the revision just promoted (platform-level); the `kubectl get` in Verify shows the
Deployments actually running (evidence, not a second opinion); and the smoke test proves the *product*
answers correctly over HTTPS, which is the one thing ArgoCD's health model cannot see — healthy pods
serving a broken page are `Healthy` to ArgoCD.

### The rollback procedure, and the evidence that it fired

**Automatic**: any failure in Deploy, Rollout, Verify or Smoke Test triggers `post { failure }` in
`Jenkinsfile-cd`, which dumps diagnostics (`kubectl get events`, the last 200 log lines per Deployment)
and then re-runs `application-cd` itself against the previous promoted tag (found by
`scripts/ci/previous-tag.sh` reading `git log` on `charts/voteball/values.yaml`), with
`ROLLBACK_DEPTH` incremented. If *that* rollback also fails verification, the pipeline stops rather
than oscillating between two tags forever, and reports that production needs a human — see Rollback in
`docs/cicd.md` for the b/c/b/c cycle this bound was written against.

**Manual**, and it is the same mechanism, not a separate one:

> Run `application-cd` with `IMAGE_TAG` set to any older commit SHA. That is the whole procedure; it
> is the same machinery the automatic rollback uses.

**Evidence.** The mechanism is exercised as part of the graded evidence capture (design doc
Verification item 7: deploy a backend image whose health endpoint deliberately fails, watch the
Failure Handling stage detect it, roll back automatically, and re-verify green), archived under
`docs/eks/evidence/2026-08-04-task4-*.txt` alongside the rest of this submission's evidence — see
[`docs/eks/live-cluster-snapshot.md`](docs/eks/live-cluster-snapshot.md) for the readable excerpts and
`docs/eks/evidence/` for the raw command output.

### Security

- **Image security.** Trivy scans every app image before it can be pushed (`backend`/`worker`/`nginx`
  block the build on fixable `CRITICAL`/`HIGH`; the third-party `backup` base is report-only). ECR
  repositories for the four app images are `IMMUTABLE`, so a tag, once pushed, cannot be silently
  retargeted. `skopeo` pushes the **exact file Trivy scanned** — no rebuild between scan and push.
- **RBAC, including the read-only claim.** CI's `jenkins-agent` ServiceAccount carries **zero**
  Kubernetes RBAC anywhere in the cluster. CD's `jenkins-cd-agent` carries a namespaced `Role` in
  `devops-app` (`charts/jenkins-support/templates/rbac.yaml`) with only `get`/`list`/`watch` on
  deployments, replicasets, pods, services, events and ingresses, plus `get` on pod logs — **no
  `patch`, no `create`, no `delete`, no ClusterRole anywhere.** `verify-jenkins.sh` does not just
  document this claim, it **tests** it: `kubectl auth can-i patch deployments
  --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app` must return `no`, and the script fails
  if it doesn't.
- **Secrets.** Both application and Jenkins secrets live in AWS Secrets Manager, synced into the
  cluster by External Secrets Operator, never in git or Terraform state. The GitHub deploy key and the
  ArgoCD API token reach agent pods only for the one stage that needs each (`sshagent()`,
  `withCredentials()`), never as a standing pod environment variable.
- **Agent isolation.** The two agent templates cannot do each other's job — CI can push images but has
  no path to the cluster; CD can read the cluster and ask ArgoCD to sync but cannot build or push an
  image (its IRSA role is ECR **read-only**). Every container drops all Linux capabilities and runs
  `allowPrivilegeEscalation: false` **except** `buildkit`, whose narrow, documented exception (uid
  1000, `SETUID`/`SETGID` only, no host access) is what rootless BuildKit needs to avoid
  Docker-in-Docker's `privileged: true`.
- **Network exposure — stated accurately, not flatteringly.** The `ci` namespace's egress
  NetworkPolicy denies any route to RDS or `devops-app`'s own pods, verified live: a pod in `ci` cannot
  reach the backend or the database. It **can** reach `argocd-server` — necessarily, since CD has to
  call it — on port 443 (used) and, verified live, also on port 80, which is looser than the policy's
  own comment (which lists only 443/8080/50000 for the re-allowed service-CIDR rule) implies. The
  practical impact is nil: CD's three `argocd` CLI calls all use `--grpc-web` over 443, and `--plaintext`
  (port 80) is never invoked. This is recorded here rather than glossed over, because the claim this
  submission makes is "CD cannot write to the cluster," not "CD's network path is minimal" — the first
  is enforced by RBAC and is absolute; the second is not, and should not be asserted as if it were.
  Only `/github-webhook` is reachable from the internet on the Jenkins Ingress; the UI, script console
  and credential store have no ALB rule and are reached only via `kubectl port-forward`.

### Full teardown

```bash
./scripts/destroy.sh                    # everything, including Jenkins and its EFS filesystem
./scripts/jenkins/uninstall-jenkins.sh   # Jenkins only, leaves devops-app and RDS untouched
```

`destroy.sh` deletes the ArgoCD Application first (so `selfHeal` cannot recreate what is being
removed), then both Ingresses sharing the `voteball` ALB group (the app's and the CI webhook's — an
ALB is de-provisioned only once its group has no members left), waits for the ALB to actually
disappear, and only then runs `terraform destroy` — which removes the Jenkins releases, the EFS
filesystem and its mount targets along with everything else. RDS takes a final snapshot first, so a
subsequent `deploy.sh` restores the votes; nothing in the Jenkins/CI teardown is treated as backup
insurance, because none of it needs to be — the durable record of every deploy is the git history on
`master`, which teardown cannot touch.

### Trade-offs and significant architectural decisions

#### Why ArgoCD is the applier and Jenkins CD is not

The brief's worked example uses `helm upgrade --install` for the deploy step. This project deliberately
does not: `application-cd` never runs `helm upgrade`, `kubectl apply`, or `kubectl rollout` against
`devops-app`. It asks ArgoCD to sync, waits on ArgoCD's own health verdict, and reads ArgoCD's own
status back. The instructor confirmed (2026-08-04) that the deploy *mechanism* is free as long as the
CI/CD pipeline works, provided everything stays configured as code — which drove the decision, recorded
in full in `docs/design/2026-08-04-cicd-split-design.md` §7.

Three reasons, in order of weight:

1. **A direct `helm upgrade` would now fail outright.** ArgoCD already owns this release with
   server-side apply; a manual upgrade loses on field ownership (`conflict with "argocd-controller"`).
2. **`selfHeal` would fight it.** ArgoCD continuously reconciles `charts/voteball` against `master`. A
   Jenkins-applied change that the git state didn't already describe would be reverted within the next
   reconciliation window — a green Jenkins pipeline and an un-deployed change.
3. **It is a stronger answer to the brief's own criteria, not a weaker one.** ArgoCD itself is fully
   declared in code (`terraform/addon-argocd.tf` + `argocd/voteball-application.yaml.tmpl`), with
   `render-argocd-app.sh --check` failing the build on any UI-made drift. Nothing about using it
   involves clicking.

The governing rule adopted for the whole CD design: **whatever ArgoCD can do, ArgoCD does; Jenkins CD
is scoped to exactly what a reconciler structurally cannot do.**

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

The practical consequence in `Jenkinsfile-cd`: Deploy, Rollout and Verify are three `argocd` CLI calls,
not a hand-rolled rollout loop. The only `kubectl` call in the happy path is one read, in Verify,
purely to capture evidence — and even that runs through a ServiceAccount that cannot write anything.

#### Other decisions worth recording

- **EFS over EBS for `JENKINS_HOME`, over staying on `emptyDir`.** The brief requires persistent
  Jenkins-home storage; `emptyDir` cannot provide it. EBS was rejected in the predecessor design
  because it is AZ-locked on a 100%-Spot node group reclaimed roughly daily; EFS avoids that at a
  measured cost of roughly $1–2/month.
- **Rollback is bounded to one retry, not unbounded.** An unbounded retry loop was considered and
  rejected — a second consecutive verification failure means the *tag* is not the problem, and
  continuing to bounce between two tags would flap production and push a commit every cycle with no
  human aware it was happening.
- **Rollback demonstrated by actually breaking the live site**, not by simulating the failure. The
  public site is degraded for the few minutes this takes; accepted deliberately, because evidence that
  the mechanism *fires* is worth more than evidence that it merely compiles.
- **No staging environment, no PR pipeline.** Both are conditional in the brief on already existing;
  Voteball is deliberately single-environment, and the repo owner works solo, committing straight to
  `master` — a PR-triggered pipeline would never fire.
- **The `postgres` test sidecar is ephemeral and per-build**, not a shared test database — it holds no
  real data and dies with the pod, so `application-ci`'s Tests stage adds no new attack surface and no
  new route to the real RDS instance.

## How to verify

Live outputs captured from the running cluster are in
**[`docs/eks/live-cluster-snapshot.md`](docs/eks/live-cluster-snapshot.md)** — `kubectl get
nodes / namespaces / pods / deployments / services / ingress`, plus `describe pod`, `logs`, the IRSA
ServiceAccount annotations, the ExternalSecret sync, the ArgoCD Application status, and the monitoring
pods. Quick live checks:

All of the below is also **scripted** — `./scripts/capture-evidence.sh` runs the eight required
`kubectl` commands, every demo, and the pod-restart poll, and writes them to
`docs/eks/evidence/<date>-*.txt`. It exists because the evidence has to be re-captured after each
rebuild (every pod name, ALB hostname and certificate is new), and a hand-run list drifts. Or by hand:

```bash
kubectl get pods -n devops-app                                  # all Running
curl -sf https://voteball.latnook.com/api/options | head -c 120 # leagues/clubs/parties (backend↔RDS)
# NetworkPolicy: worker must NOT reach backend. Uses a python socket connect, NOT `wget` -- wget is
# absent from the worker image, so `wget ... || echo BLOCKED` printed BLOCKED unconditionally and
# would have "passed" with the NetworkPolicy deleted. Pair it with the RDS control below.
kubectl exec -n devops-app deploy/worker -- python -c "import socket;s=socket.socket();s.settimeout(6);
try: s.connect(('backend',5000)); print('REACHABLE <- policy NOT enforcing')
except Exception as e: print('BLOCKED by NetworkPolicy:', type(e).__name__)"
kubectl exec -n devops-app deploy/worker -- python -c "import os,socket;s=socket.socket();s.settimeout(6);
s.connect((os.environ['DB_HOST'],5432)); print('RDS REACHABLE (control: the probe works)')"
kubectl create job --from=cronjob/voteball-backup t -n devops-app && aws s3 ls s3://voteball-rollups-590183895228/backups/  # backup lands
```

**Demos shown — captured output, not claims.** The current set is **2026-08-03**, captured either
side of one deliberate `destroy.sh` → `deploy.sh` cycle on EKS 1.36 with Jenkins in-cluster. An
older **2026-07-27** set is kept as a second, independent lifecycle record. Raw output for both is
under [`docs/eks/evidence/`](docs/eks/evidence/); readable excerpts in
[`docs/eks/live-cluster-snapshot.md`](docs/eks/live-cluster-snapshot.md).

That rebuild needed **three** `deploy.sh` invocations and the log keeps all three, unedited: an EKS
access-entry propagation race on the first, then an `IMMUTABLE`-tag push rejection that made the
script unable to re-run at all, then a clean pass. Both are fixed
(`terraform/addon-jenkins.tf` `depends_on`, and `build-push-ecr.sh` now skipping tags already in
ECR via CI's existing G1 check). A deploy path that has only ever been run on a clean slate has not
been shown to recover — this one has.

| Demo | Evidence |
|---|---|
| HTTPS with a valid ACM certificate | `HTTP/2 200`; issuer `Amazon RSA 2048 M04`, valid Aug 3 2026 → Feb 16 2027. HTTP → `301` at the ALB |
| frontend → backend → RDS | `/api/options` returns seeded league/club/party data in one unauthenticated request; `/api/results?by=all` returns the worker-computed rollups |
| NetworkPolicy isolation | worker → backend:5000 `BLOCKED (TimeoutError)`, **with a control**: worker → RDS:5432 `REACHABLE` |
| S3 + SNS via IRSA | backup Job writes a new object under `backups/`; SNS `Delivered: 10, Failed: 0` over 7 days; only `worker`/`backup` hold an AWS role |
| **Pod restart, site stays up** | **2,218** consecutive HTTP 200s, `non-200: 0`, across a window that contained a CI-driven rolling update of *all three* Deployments **and** a deliberate `kubectl delete pod` — plus a dedicated, narrower restart poll in the same set |
| **Full delete/rebuild lifecycle** | `destroy.sh` **132 destroyed** → `deploy.sh` rebuilt, RDS restored from the automatic final snapshot: **18 previous-party / 23 upcoming votes before, identical after**. New certificate, new ALB, new cluster, every pod name new. Post-rebuild: **124** probes, all 200, across a pod delete |

The NetworkPolicy row carries a control deliberately. The check previously documented here was
`wget ... || echo BLOCKED`, which printed `BLOCKED` because **`wget` is absent from the worker
image** — it would have passed with the NetworkPolicy deleted. A test that cannot fail is not a test.

The pod-restart row has the mirror-image trap: an uptime poll dense enough to prove continuity is
dense enough to look like an attack. An unthrottled probe loop crossed the WAF's site-wide ceiling of
2,000 requests / 5 min per IP (`terraform/waf.tf` rule 2, which counts *every* path) and the next 558
probes returned `403` from the ALB — indistinguishable, in the log, from the site going down during
the restart. CloudWatch named the culprit: `voteball-rate-sitewide` blocked 1,299 requests in that
window, `voteball-rate-vote` none. `capture-evidence.sh` throttles to 2 requests/second for that
reason.

## How to delete everything

```bash
./scripts/destroy.sh
```

Removes the cluster, add-ons, VPC, RDS, ECR, S3, SNS, Secrets Manager and IAM. (S3/ECR have
`force_destroy`/`force_delete` so a non-empty bucket/repo doesn't block it.)

The script exists because the order is not obvious and getting it wrong wastes 20+ minutes: the ArgoCD
Application must go **first** (or `selfHeal` recreates whatever you delete), then **both** Ingresses —
`devops-app/voteball` and `ci/jenkins-webhook` share ALB group `voteball`, and an ALB is de-provisioned
only once its group has no members left, so removing one leaves it running — then a poll until the ALB
is actually gone, and only then `terraform destroy`. It also reaps the detached
CNI network interfaces that otherwise stall subnet deletion, and takes a final RDS snapshot so the next
deploy restores the votes. Each of those steps was added after a real teardown failed on it — see
[`docs/design/2026-07-20-deployment-hardening-design.md`](docs/design/2026-07-20-deployment-hardening-design.md).

## Security (summary — full detail in `docs/security.md`)

- **Least privilege / IRSA:** no workload is `cluster-admin`; each component has its own ServiceAccount;
  only `worker` and `backup` carry an AWS role (scoped to one SNS topic + one S3 prefix each);
  backend/frontend carry **none**.
- **Secrets:** in AWS Secrets Manager, synced by ESO; never in git or Terraform state; Jenkins' agent
  pods use **IRSA** (no stored keys anywhere, ECR push only), the controller holds no AWS role and no
  cluster-deploy access, and its own credentials (deploy key, webhook secret) reach it only through
  ESO, never Secrets Manager calls made by Jenkins itself. Grafana/ArgoCD passwords auto-generated.
- **Network:** only frontend is internet-facing; default-deny NetworkPolicies; RDS private, node-SG-only,
  `sslmode=require`, encrypted.
- **Ingress:** ALB + ACM HTTPS, HTTP→HTTPS redirect, **AWS WAF** rate-limiting `/api/vote` to 100
  requests / 5 min per address (verified live: a 300-request burst returned `403` while the rest of the
  site stayed `200` from the same address).
- **Alerting:** Alertmanager → SNS via IRSA (`sns:Publish` on one topic, no SMTP credentials on the
  cluster); seven rules covering crashloops, degraded Deployments, and failed or *absent* backups.
- **Containers:** non-root, no-priv-esc, read-only rootfs, all capabilities dropped.
- **Images:** git-SHA tags (never `latest`), ECR scan-on-push + Trivy in CI (app images 0 CRITICAL/HIGH).

## Trade-offs & compromises

Documented in full in [`docs/security.md`](docs/security.md#deliberate-trade-offs-demo-vs-production) —
notably: reused (not rotated) credentials, a single-AZ RDS (now with 7-day point-in-time recovery;
deletion protection stays off on purpose because it would break the destroy/rebuild workflow), a public
(IAM-authed) API endpoint, a single NAT gateway, Spot nodes without On-Demand fallback, and report-only
Trivy on the third-party backup image. Each is a deliberate demo decision, not an oversight.
