# Voteball on EKS — submission

A public poll correlating football fandom with Israeli political-party voting, deployed on **Amazon EKS**.
This is the turn-in document: architecture, how to run/verify/delete it, how security is handled, and the
trade-offs made. (For the plain-language deploy walkthrough see [`docs/deploy.md`](docs/deploy.md); for
the full security design see [`docs/security.md`](docs/security.md).)

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
  Autoscaler, Node Termination Handler, CloudWatch Container Insights, metrics-server, external-dns,
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

Both stop and ask for confirmation before Terraform touches billed resources. `deploy.sh` runs, in order:
resolve the newest DB snapshot → `terraform apply` → seed Secrets Manager → connect kubectl → build/push
the 4 images to ECR (git-SHA tags) → **sync `values.yaml` from Terraform outputs** → `helm upgrade
--install` → bootstrap **ArgoCD**, which owns the release from then on.

That sync step matters: the RDS endpoint, ACM certificate ARN, S3 bucket and IRSA role ARNs are all
regenerated on every rebuild, so `charts/voteball/values.yaml` is **generated, never hand-edited**
(`./scripts/sync-values-from-tf.sh --check` fails on drift and verifies the image tag exists in ECR).

`destroy.sh` encodes the order that actually works — ArgoCD Application first (or `selfHeal` recreates
what you delete), then the Ingress (releasing the ALB and its DNS records), then Terraform — and takes a
final DB snapshot, so a destroy/rebuild cycle preserves the votes.

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

**Demos shown — captured output, not claims.** Every one below was run twice on 2026-07-27: once on
the running cluster, then again on a cluster rebuilt from scratch. Both captures are in
[`docs/eks/live-cluster-snapshot.md`](docs/eks/live-cluster-snapshot.md), with the raw command output
under [`docs/eks/evidence/`](docs/eks/evidence/).

| Demo | Evidence |
|---|---|
| HTTPS with a valid ACM certificate | `HTTP/2 200`; issuer `Amazon RSA 2048 M01`. HTTP → `301` at the ALB |
| frontend → backend → RDS | `/api/options` returns seeded league/club/party data in one unauthenticated request |
| NetworkPolicy isolation | worker → backend:5000 `BLOCKED (TimeoutError)`, **with a control**: worker → RDS:5432 `REACHABLE` |
| S3 + SNS via IRSA | backup Job writes an object to a bucket created minutes earlier; SNS `Delivered: 1, Failed: 0`; only `worker`/`backup` hold an AWS role |
| **Pod restart, site stays up** | **1,050** consecutive HTTP 200s (pre) and **700** (post) spanning `kubectl delete pod` of a frontend replica through to the replacement reaching `1/1 Ready` — `non-200: 0` |
| **Full delete/rebuild lifecycle** | `destroy.sh` 112 destroyed → `deploy.sh` 112 added, RDS restored from the final snapshot, **5 votes before, 5 votes after** |

The NetworkPolicy row carries a control deliberately. The check previously documented here was
`wget ... || echo BLOCKED`, which printed `BLOCKED` because **`wget` is absent from the worker
image** — it would have passed with the NetworkPolicy deleted. A test that cannot fail is not a test.

## How to delete everything

```bash
./scripts/destroy.sh
```

Removes the cluster, add-ons, VPC, RDS, ECR, S3, SNS, Secrets Manager and IAM. (S3/ECR have
`force_destroy`/`force_delete` so a non-empty bucket/repo doesn't block it.)

The script exists because the order is not obvious and getting it wrong wastes 20+ minutes: the ArgoCD
Application must go **first** (or `selfHeal` recreates whatever you delete), then the Ingress (freeing
the ALB and letting external-dns remove its records — a leftover ALB's ENIs block VPC deletion), then a
poll until the ALB is actually gone, and only then `terraform destroy`. It also reaps the detached
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
