# Deploy / destroy guide (EKS)

How to deploy Voteball to Amazon EKS, verify it, and tear it down. Verified end-to-end against a real
deploy (2026-07-19): cluster provisioned, app live over HTTPS at `voteball.latnook.com`, vote → rollup
→ results confirmed, NetworkPolicy isolation + backup CronJob + pod-restart-stays-up all confirmed.

**Required locally:** `terraform` (≥ 1.5), `aws` CLI (creds for account `590183895228`, region
`il-central-1`), `kubectl`, `helm` (3.x), `docker`, `python3`. The `latnook.com` Route 53 zone must
already exist. **This creates real, billed AWS resources** (~$200/mo while up: EKS control plane, NAT,
2 Spot nodes, RDS, ALB) — treat every `apply`/deploy as a confirm-before-running step.

> The old single-node **k3s** deployment (`terraform/` + `ansible-project/`) is **retired**. Its runbook
> is this file's pre-EKS version in git history. This guide covers the EKS stack in `terraform-eks/` +
> `charts/voteball/`.

## What owns what (Terraform vs Helm — the boundary)

- **Terraform (`terraform-eks/`)** creates all AWS infra + the cluster + platform add-ons:
  dedicated VPC (public/private/DB subnets, single NAT), EKS cluster + managed Spot node group,
  OIDC provider + hand-rolled **IRSA** roles (worker, backup) + community-helper IRSA roles (ALB
  controller, ESO, Cluster Autoscaler, CloudWatch, external-dns), ECR repos, ACM cert (DNS-validated),
  S3 bucket, Secrets Manager secret **container** (placeholder only), SNS topic, RDS (restored from
  snapshot), the VPC CNI **network-policy** enablement, and every platform add-on installed via
  `helm_release`/`aws_eks_addon` (AWS Load Balancer Controller, External Secrets Operator, Cluster
  Autoscaler, Node Termination Handler, CloudWatch Container Insights, metrics-server, external-dns).
- **Helm (`charts/voteball`)** creates the **app** in namespace `devops-app`: the 3 Deployments,
  Services, Ingress (→ ALB), ConfigMap, ExternalSecret (ESO source), 4 ServiceAccounts (worker/backup
  IRSA-annotated), NetworkPolicies, HPA, PDBs, and the nightly backup CronJob.
- **Manual, out-of-band:** seeding the real secret values into Secrets Manager (below) and pinning the
  image tag / RDS endpoint in `values.yaml`. These are deliberate manual ops — see each step.

## Setup (once per checkout)

```bash
# terraform-eks variables (only notification_email is required)
cd terraform-eks
cp voteball-eks.tfvars.example voteball-eks.tfvars
# edit voteball-eks.tfvars: notification_email = "you@example.com"
# (optional, recommended for prod) set cluster_endpoint_public_access_cidrs to your operator/CI CIDR
cd ..
```

The EKS stack uses **local Terraform state** (`terraform-eks/terraform.tfstate`, gitignored) — back it
up (a copy in a password manager is enough) along with `voteball-eks.tfvars`. Losing the state means
cleaning up billed resources by hand.

## Deploy

```bash
# 1. Provision everything (VPC, EKS, node group, IRSA, ECR, ACM, S3, Secrets Manager, SNS, RDS,
#    + all platform add-ons + VPC CNI network policy). RDS restores from the snapshot pinned in
#    var.db_snapshot_identifier so votes survive; set it to null for a fresh empty DB. Update the
#    pin to the newest snapshot after a prior destroy (aws rds describe-db-snapshots ...).
cd terraform-eks
terraform init
terraform plan  -var-file=voteball-eks.tfvars    # review the billed resources
terraform apply -var-file=voteball-eks.tfvars     # ~15-20 min (EKS control plane + node group + RDS)
cd ..
```

On a **cold** apply the in-stack `helm`/`kubernetes` providers authenticate to a cluster that doesn't
exist yet; if the first `apply` errors initializing them (or on an add-on `helm_release`), simply
**re-run `terraform apply`** — the cluster now exists and the add-ons install on the second pass.

The `apply` can hit a first-run ordering race where the CloudWatch add-on is created before the ALB
controller's webhook is ready (`AdmissionRequestDenied ... aws-load-balancer-webhook-service`); a
`depends_on` in `addon-cloudwatch.tf` prevents it on a clean apply. If a stale apply left the add-on
`CREATE_FAILED`, `aws eks delete-addon --cluster-name voteball --addon-name
amazon-cloudwatch-observability`, `terraform state rm aws_eks_addon.cloudwatch`, then re-apply.

```bash
# 2. MANUAL OP — seed the real app secret into Secrets Manager (no secret values ever go in git or
#    terraform state; Terraform only made the empty container). DB_PASS must match the RDS master
#    password (= the k3s db_password baked into the restored snapshot). Generate an admin hash with
#    ansible-project/roles/backend/files/backend/scripts/hash_admin_password.py.
aws secretsmanager put-secret-value --secret-id voteball/app-secret --region il-central-1 \
  --secret-string '{"DB_USER":"postgres","DB_PASS":"<restored-rds-master-pw>","ADMIN_USERNAME":"admin",
    "ADMIN_PASSWORD_HASH":"<werkzeug hash>","ADMIN_SESSION_SECRET":"<openssl rand -hex 32>"}'

# 3. Point kubectl at the cluster
aws eks update-kubeconfig --name voteball --region il-central-1

# 4. Build + push the container images to ECR (git-SHA tagged), then pin that tag in the chart
./scripts/build-push-ecr.sh            # builds+pushes backend/worker/nginx/backup at $(git rev-parse --short HEAD)
# edit charts/voteball/values.yaml: image.tag = the printed SHA

# 5. Pin the RDS endpoint in the chart
terraform -chdir=terraform-eks output -raw rds_endpoint    # -> voteball-eks-db.<...>.rds.amazonaws.com
# edit charts/voteball/values.yaml: config.DB_HOST = that endpoint

# 6. Deploy the app
helm upgrade --install voteball charts/voteball -n devops-app --create-namespace

# 7. Confirm the SNS email subscription (check notification_email's inbox for the confirmation link)
aws sns list-subscriptions-by-topic --region il-central-1 \
  --topic-arn "$(terraform -chdir=terraform-eks output -raw sns_topic_arn)"
```

**Re-deploying after a code change:** rebuild+push (step 4), bump `image.tag`, `helm upgrade`. The
backend bootstraps its own schema idempotently on pod start (gunicorn `on_starting`) — there is no
migration Job (a pre-install hook can't read the ESO-synced secret; see Gotchas).

## Verify

```bash
# Cluster + app
kubectl get nodes                                   # 2 Ready
kubectl get pods -n devops-app                      # backend x2, frontend x2, worker, all Running
kubectl get ingress,hpa,pdb,cronjob,networkpolicy -n devops-app

# Public HTTPS (external-dns creates the Route53 alias to the ALB; allow a few min to propagate)
curl -sf https://voteball.latnook.com/                       # 200
curl -sf https://voteball.latnook.com/api/options | head -c 200   # leagues/clubs/parties
curl -sf "https://voteball.latnook.com/api/results?by=all"        # national totals

# Secret sync (ESO -> K8s Secret)
kubectl get externalsecret -n devops-app            # STATUS SecretSynced, READY True

# NetworkPolicy isolation: worker MUST NOT reach backend (only frontend may)
kubectl exec -n devops-app deploy/worker -- sh -c 'wget -qO- --timeout=5 http://backend:5000/health || echo BLOCKED'

# Backup CronJob: trigger once, confirm a .sql.gz lands under backups/
kubectl create job --from=cronjob/voteball-backup backup-test -n devops-app
kubectl wait --for=condition=complete job/backup-test -n devops-app --timeout=120s
aws s3 ls s3://voteball-rollups-590183895228/backups/ --region il-central-1

# Pod-restart-stays-up: delete ONE frontend pod (by name), the other keeps serving
kubectl delete pod -n devops-app "$(kubectl get pod -n devops-app -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
```

## Destroy

```bash
# 1. Remove the app first (this deletes the Ingress -> the ALB controller de-provisions the ALB).
helm uninstall voteball -n devops-app

# 2. Destroy the infra. The helm/kubernetes providers authenticate to the cluster, so the cluster
#    must still exist while their helm_releases are destroyed — Terraform orders this correctly.
cd terraform-eks
terraform destroy -var-file=voteball-eks.tfvars
cd ..
```

Deletes the cluster, node group, add-ons, VPC/NAT, ECR, ACM, S3, SNS, and RDS. The EKS RDS uses
`skip_final_snapshot = true` (it's a throwaway copy — the k3s snapshot restored in step 1 of Deploy is
the source of truth), so **votes cast on EKS are not preserved on destroy** unless you snapshot first.
Back up `terraform-eks/terraform.tfstate` and `voteball-eks.tfvars` (gitignored, local-only).

## Gotchas (all hit for real during the EKS build, 2026-07-19)

- **Pin the EKS version to a *standard-support* release.** Extended support costs 5× ($0.50 vs
  $0.10/hr). Verify with `aws eks describe-cluster-versions --region il-central-1`; `var.cluster_version`
  is `1.34`. (1.30–1.32 had already aged into extended support.)
- **This stack pins `aws ~> 5.0`, not the k3s stack's `~> 6.0`.** The `terraform-aws-modules/eks` v20
  module caps the AWS provider at `< 6.0.0`. Independent stack = independent lock, so the skew is
  harmless. Adding the EKS module also needs `terraform init -upgrade` (it pulls `cloudinit/null/time/tls`).
- **Community chart/add-on versions drift fast** — verify each against the cluster version at deploy
  time (`helm search repo <chart> --versions`, `aws eks describe-addon-versions`). The pins in
  `terraform-eks/*.tf` and `charts/voteball/values.yaml` were correct on 2026-07-19; newer may exist.
- **NetworkPolicy egress must allow the *Service CIDR* (`172.20.0.0/16`), not just the VPC
  (`10.0.0.0/16`).** The frontend reaches `backend` via its Service ClusterIP (172.20.x), which the VPC
  CNI policy agent evaluates before DNAT-to-pod-IP. Without it the site loads but `/api/*` hangs (nginx
  `499`) and shows no data. (RDS works on the VPC allow because that's a direct pod→RDS-IP connection.)
  The VPC CNI network-policy engine must also be *enabled* (`enableNetworkPolicy=true` on the vpc-cni
  addon) or policies are silently ignored. Kubelet health probes are exempt (pods stay Ready).
- **The backup CronJob needs `HOME=/tmp`.** Under `readOnlyRootFilesystem`, the AWS CLI can't write its
  `~/.aws` config/cache (`[Errno 30] Read-only file system: '/.aws'`). `HOME=/tmp` (the writable
  emptyDir) fixes it.
- **ALB `target-type: ip` throws a transient 502 on pod delete** as it deregisters the dead pod's IP.
  The frontend has a `preStop: sleep 15` + `terminationGracePeriodSeconds: 30` so it keeps serving
  while the ALB deregisters it.
- **No migration Job — schema bootstrap is the backend's `on_starting` hook.** A Helm pre-install hook
  Job can't get the DB password: it comes from the ESO ExternalSecret, populated asynchronously as a
  normal (post-hook) resource, so `app-secret` doesn't exist at pre-install time. `on_starting` is
  idempotent and runs after the pod (and the synced secret) are up; on a restored DB it's a near no-op.
- **`terraform apply` writes secret placeholders, never real values.** The Secrets Manager container is
  created with `lifecycle { ignore_changes = [secret_string] }`; the real values are seeded by hand
  (Deploy step 2) so nothing sensitive lands in `terraform.tfstate`.
