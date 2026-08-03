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
  all, and ephemeral pod agents (rootless BuildKit + Trivy + skopeo + aws-cli) that build, scan and push
  the four app images. It is a **platform add-on like ArgoCD**, not the graded application namespace, so
  it is installed by `terraform apply` alongside the other add-ons rather than by ArgoCD.
- **Terraform vs Helm boundary:** Terraform builds the AWS infra + cluster + platform add-ons (Jenkins
  included); the Helm chart is the app, delivered by **ArgoCD** (GitOps) from this repo's `master`. See
  `docs/deploy.md`.
- **Terraform state lives in S3** (versioned, encrypted, S3-native locking), one bucket, one key. The
  bucket belongs to no stack and is never destroyed.
- **CI config is code too:** Jenkins configures itself from `ci/jenkins/jenkins.yaml` (JCasC), applied
  via the Helm release's `controller.JCasC.configScripts`, with its credentials read from Secrets
  Manager through External Secrets Operator. Its controller is deliberately disposable —
  `JENKINS_HOME` is an `emptyDir`, not a volume, because the node group is 100% Spot and reclaimed
  roughly daily; see `docs/cicd.md` for why a PersistentVolumeClaim would make that worse, not better.

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
git push (services/**) → GitHub webhook → Jenkins pod agent (BuildKit) → Trivy → ECR → values.yaml tag bump → ArgoCD → pods roll
```

CI is **Jenkins**, running inside the cluster itself (namespace `ci`), installed by Terraform as a
`helm_release` of the official chart. Ephemeral pod agents — not a Docker daemon, which EKS nodes don't
have — build with **rootless BuildKit**, scan with Trivy, and push with skopeo. The pipeline is a
declarative [`Jenkinsfile`](Jenkinsfile) in this repo — the job is *Pipeline script from SCM*, so the
build definition is reviewable here rather than hidden in Jenkins' database. Its five real steps: guard
against its own commit → build four images tagged with the git SHA → **Trivy** scan (blocking on the
app images) → push to **ECR** → commit the new tag to `charts/voteball/values.yaml`.

Three decisions worth calling out:

- **Jenkins never deploys and holds no cluster-deploy credentials.** It stops at "push images, commit
  the tag"; **ArgoCD** observes that commit and rolls the Deployments. A compromised build pod cannot
  touch the rest of the cluster — its ServiceAccount's Role is scoped to creating/watching/exec'ing its
  own agent pods in the `ci` namespace, nothing else.
- **No stored AWS keys anywhere.** Agent pods authenticate through **IRSA** scoped to ECR push on
  `voteball-*` and nothing else; the controller itself carries **no AWS role at all**. Verified:
  `aws ecr get-login-password` works from an agent, `aws eks list-clusters` is denied.
  A NetworkPolicy separately denies the whole namespace any route to RDS or the app namespace.
- **This build container is the one exception to "no privilege escalation" in the whole project.**
  Rootless BuildKit needs `allowPrivilegeEscalation: true` + `SETUID`/`SETGID` to create its own user
  namespace — still uid 1000, no host access, nothing like Docker-in-Docker's `privileged: true`, which
  was rejected for exactly that reason. See `docs/security.md`.

**Evidence of a green run.** A real GitHub webhook push built four images, scanned them clean
(`backend`/`worker`/`nginx`: 0 HIGH, 0 CRITICAL), pushed them, and committed the tag bump. ArgoCD synced
unprompted and rolled all three Deployments with zero downtime; the site and `/api/options` both
returned 200. The tag-bump commit's own webhook delivery was then correctly refused by the Guard stage —
**exactly one bump commit exists per build; there was no loop.**

The most important check is the one that runs unattended: **Jenkins has no native `[skip ci]`** — that is
a GitHub Actions feature — so without an explicit guard, the pipeline's own tag-bump commit retriggers it
in an unbounded, billable loop that also rolls production pods continuously.

Full pipeline walkthrough, the first-time setup runbook, and a failure-modes table are in
**[`docs/cicd.md`](docs/cicd.md)**; the design rationale for the pipeline's *logic* is in
[`docs/design/2026-07-20-jenkins-migration-design.md`](docs/design/2026-07-20-jenkins-migration-design.md),
and the rationale (and verification outcome) for running it *in the cluster instead of on a dedicated
EC2 host* is in
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](docs/design/2026-07-30-jenkins-on-eks-design.md).

**The controller is deliberately disposable.** The node group is 100% Spot, reclaimed roughly once a
day; `JENKINS_HOME` is an `emptyDir`, not a PersistentVolume, because an EBS volume is AZ-locked and
would preserve almost nothing at that reclaim rate while adding a pod that can hang `Pending` forever.
Build history resets on reclaim and on every teardown — the durable record is the `ci: image tag <sha>
[skip ci]` commits on `master`, which never expire. Two things remain **deliberately deferred**: SSM
Session Manager (moot now — there is no SSH access to anything Jenkins runs on), and build-failure
notifications — Jenkins sends no email without SMTP, so verification means checking the Jenkins UI or
ArgoCD's state rather than assuming success.

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
