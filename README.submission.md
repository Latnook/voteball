# Voteball on EKS — submission

A public poll correlating football fandom with Israeli political-party voting, deployed on **Amazon EKS**.
This is the turn-in document: architecture, how to run/verify/delete it, how security is handled, and the
trade-offs made. (For the plain-language deploy walkthrough see [`docs/deploy.md`](docs/deploy.md); for
the full security design see [`docs/security.md`](docs/security.md).)

## Architecture

- **In Kubernetes** (`devops-app` namespace, chart `charts/voteball`): 3 Deployments — **frontend**
  (nginx, static site + `/api` proxy), **backend** (Flask/gunicorn API), **worker** (batch rollup poller)
  — plus their Services, an **Ingress→ALB**, ConfigMap, an ESO **ExternalSecret**, 4 ServiceAccounts,
  NetworkPolicies, HPA, PDBs, a nightly **backup CronJob**, a **pre-upgrade schema-migration Job** (so
  schema work runs once per release rather than every replica racing on startup), and a
  **PrometheusRule** carrying the operational alerts.
- **Outside Kubernetes (AWS, via `terraform/`):** the EKS cluster + Spot node group, a dedicated VPC
  (public/private/DB subnets, NAT), **RDS** Postgres (7-day PITR), **ECR**, **ACM** cert, **AWS WAF** in
  front of the ALB, **S3**, **SNS**, **Secrets Manager**, and the platform add-ons (AWS Load Balancer Controller, External Secrets Operator, Cluster
  Autoscaler, Node Termination Handler, CloudWatch Container Insights, metrics-server, external-dns,
  ArgoCD, kube-prometheus-stack).
- **Terraform vs Helm boundary:** Terraform builds the AWS infra + cluster + platform add-ons; the Helm
  chart is the app, delivered by **ArgoCD** (GitOps) from this repo's `master`. See `docs/deploy.md`.
- **Terraform state lives in S3** (versioned, encrypted, S3-native locking), one bucket with a separate
  key per stack. The bucket belongs to no stack and is never destroyed.
- **CI host config is code too:** the Jenkins server configures itself at boot from
  `terraform/jenkins/casc/` (JCasC), with its credentials read from Secrets Manager. Verified by booting
  a throwaway instance from that config and checking it came up fully configured.

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

## CI/CD — Jenkins → ECR → ArgoCD

```
git push (services/**) → GitHub webhook → Jenkins on EC2 → ECR → values.yaml tag bump → ArgoCD → pods roll
```

CI is **Jenkins**, running on a dedicated EC2 host built by its own Terraform stack (`terraform/jenkins/`).
The pipeline is a declarative [`Jenkinsfile`](Jenkinsfile) in this repo — the job is *Pipeline script from
SCM*, so the build definition is reviewable here rather than hidden in Jenkins' database. Its five real
steps: guard against its own commit → build four images tagged with the git SHA → **Trivy** scan
(blocking on the app images) → push to **ECR** → commit the new tag to `charts/voteball/values.yaml`.

Three decisions worth calling out:

- **Jenkins never deploys and holds no cluster credentials.** It stops at "push images, commit the tag";
  **ArgoCD** observes that commit and rolls the Deployments. A compromised build host cannot touch EKS.
- **No stored AWS keys anywhere.** The host authenticates through an **IAM instance profile** scoped to
  ECR push on `voteball-*` and nothing else — verified live: `aws ecr get-login-password` works,
  `aws eks list-clusters` returns `AccessDeniedException`. IMDSv2 is required.
- **Jenkins is a separate Terraform stack in a separate VPC.** `./scripts/destroy.sh` rebuilds the
  application stack constantly; a CI server owned by that stack would lose its history every cycle.

**Evidence of a green run (2026-07-20).** Build 4 was triggered by a real GitHub webhook on `09827ca`:
four images built and pushed, Trivy clean on `backend`/`worker`/`nginx` (0 HIGH, 0 CRITICAL), tag bumped
as `3c4cd93 ci: image tag 09827ca [skip ci]`. ArgoCD then synced unprompted and rolled all three
Deployments to `09827ca` with zero downtime; the site and `/api/options` both returned 200.

The most important check is the one that runs unattended: **Jenkins has no native `[skip ci]`** — that is
a GitHub Actions feature — so without an explicit guard, the pipeline's own tag-bump commit retriggers it
in an unbounded, billable loop. Build 5 was the webhook firing on Jenkins' own commit `3c4cd93`: the
Guard stage fired and the build finished `NOT_BUILT`, with no human involved. Build 6 confirmed it
manually. **Exactly one bump commit exists; there was no loop.**

Full pipeline walkthrough, the first-time setup runbook, and a failure-modes table (including the three
problems actually hit during the migration) are in **[`docs/cicd.md`](docs/cicd.md)**; the design
rationale is in
[`docs/design/2026-07-20-jenkins-migration-design.md`](docs/design/2026-07-20-jenkins-migration-design.md).

Honest notes: four empty commits (`9bed4f1`, `1b16a45`, `a76fbb3`, `09827ca`) sit on `master` from
debugging the webhook — history was not rewritten, because this repo never force-pushes. And three things
are **deliberately deferred**: Jenkins Configuration as Code (the server is configured by the documented
runbook, not a file), SSM Session Manager access, and build-failure notifications — Jenkins sends no
email without SMTP, so verification means checking the Jenkins UI or ArgoCD's state rather than assuming
success.

## How to verify

Live outputs captured from the running cluster are in
**[`docs/eks/live-cluster-snapshot.md`](docs/eks/live-cluster-snapshot.md)** — `kubectl get
nodes / namespaces / pods / deployments / services / ingress`, plus `describe pod`, `logs`, the IRSA
ServiceAccount annotations, the ExternalSecret sync, the ArgoCD Application status, and the monitoring
pods. Quick live checks:

```bash
kubectl get pods -n devops-app                                  # all Running
curl -sf https://voteball.latnook.com/api/options | head -c 120 # leagues/clubs/parties (backend↔RDS)
kubectl exec -n devops-app deploy/worker -- sh -c 'wget -qO- --timeout=5 http://backend:5000/health || echo BLOCKED'  # NetworkPolicy: BLOCKED
kubectl create job --from=cronjob/voteball-backup t -n devops-app && aws s3 ls s3://voteball-rollups-590183895228/backups/  # backup lands
```

**Demos shown:** HTTPS access (valid ACM cert), frontend→backend→RDS (`/api/options` with data),
NetworkPolicy isolation (worker blocked from backend), S3/SNS via IRSA (snapshots + backup objects,
milestone email), and **pod-restart-stays-up** (`kubectl delete pod` a frontend replica → site stays up).

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
- **Secrets:** in AWS Secrets Manager, synced by ESO; never in git or Terraform state; the Jenkins build
  host uses an IAM **instance profile** (no stored keys anywhere), holds no cluster access, and reads
  exactly one secret ARN (its own credentials, for JCasC). Grafana/ArgoCD passwords auto-generated.
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
