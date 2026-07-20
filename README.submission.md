# Voteball on EKS — submission

A public poll correlating football fandom with Israeli political-party voting, deployed on **Amazon EKS**.
This is the turn-in document: architecture, how to run/verify/delete it, how security is handled, and the
trade-offs made. (For the plain-language deploy walkthrough see [`docs/deploy.md`](docs/deploy.md); for
the full security design see [`docs/security.md`](docs/security.md).)

## Architecture

- **In Kubernetes** (`devops-app` namespace, chart `charts/voteball`): 3 Deployments — **frontend**
  (nginx, static site + `/api` proxy), **backend** (Flask/gunicorn API), **worker** (batch rollup poller)
  — plus their Services, an **Ingress→ALB**, ConfigMap, an ESO **ExternalSecret**, 4 ServiceAccounts,
  NetworkPolicies, HPA, PDBs, and a nightly **backup CronJob**.
- **Outside Kubernetes (AWS, via `terraform-eks/`):** the EKS cluster + Spot node group, a dedicated VPC
  (public/private/DB subnets, NAT), **RDS** Postgres, **ECR**, **ACM** cert, **S3**, **SNS**, **Secrets
  Manager**, and the platform add-ons (AWS Load Balancer Controller, External Secrets Operator, Cluster
  Autoscaler, Node Termination Handler, CloudWatch Container Insights, metrics-server, external-dns,
  ArgoCD, kube-prometheus-stack).
- **Terraform vs Helm boundary:** Terraform builds the AWS infra + cluster + platform add-ons; the Helm
  chart is the app, delivered by **ArgoCD** (GitOps) from this repo's `master`. See `docs/deploy.md`.

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

**CI/CD:** pushing app-code to `master` runs GitHub Actions (OIDC → build → **Trivy** → ECR → bump image
tag → **ArgoCD** auto-syncs). No stored AWS keys.

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
kubectl delete application voteball -n argocd     # stop GitOps self-heal
kubectl delete ingress voteball -n devops-app     # de-provision the ALB first
cd terraform-eks && terraform destroy -var-file=voteball-eks.tfvars
```

Removes the cluster, add-ons, VPC, RDS, ECR, S3, SNS, Secrets Manager, IAM. (S3/ECR have
`force_destroy`/`force_delete` so a non-empty bucket/repo doesn't block the destroy.)

## Security (summary — full detail in `docs/security.md`)

- **Least privilege / IRSA:** no workload is `cluster-admin`; each component has its own ServiceAccount;
  only `worker` and `backup` carry an AWS role (scoped to one SNS topic + one S3 prefix each);
  backend/frontend carry **none**.
- **Secrets:** in AWS Secrets Manager, synced by ESO; never in git or Terraform state; CI uses OIDC (no
  stored keys). Grafana/ArgoCD passwords auto-generated.
- **Network:** only frontend is internet-facing; default-deny NetworkPolicies; RDS private, node-SG-only,
  `sslmode=require`, encrypted.
- **Ingress:** ALB + ACM HTTPS, HTTP→HTTPS redirect.
- **Containers:** non-root, no-priv-esc, read-only rootfs, all capabilities dropped.
- **Images:** git-SHA tags (never `latest`), ECR scan-on-push + Trivy in CI (app images 0 CRITICAL/HIGH).

## Trade-offs & compromises

Documented in full in [`docs/security.md`](docs/security.md#deliberate-trade-offs-demo-vs-production) —
notably: reused (not rotated) credentials, a throwaway single-AZ RDS with `skip_final_snapshot`, a public
(IAM-authed) API endpoint, a single NAT gateway, Spot nodes without On-Demand fallback, and report-only
Trivy on the third-party backup image. Each is a deliberate demo decision, not an oversight.
