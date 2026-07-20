# Security design

How Voteball on EKS handles identity, secrets, network isolation, and images — and the trade-offs made
deliberately for a course/demo deployment. Everything here is enforced by code in `terraform/` and
`charts/voteball/`; nothing is aspirational.

## Guiding principle: least privilege, everywhere

Every workload gets only what it needs. Concretely: **no workload has `cluster-admin`**, each app
component has its **own ServiceAccount**, and only the two components that actually call AWS APIs carry
an IAM role — the rest carry none.

## Identity & AWS permissions (IRSA)

**IRSA** (IAM Roles for Service Accounts) maps a Kubernetes ServiceAccount to an AWS IAM role via the
cluster's OIDC provider. Each role's trust policy is federated to **one specific** `namespace:serviceaccount`.

| ServiceAccount (`devops-app`) | AWS role? | Permissions |
|---|---|---|
| `frontend` | **none** | serves static files + proxies to backend; never calls AWS |
| `backend` | **none** | talks only to RDS over the network; needs no AWS API access |
| `worker` | `voteball-worker-irsa` | `sns:Publish` (the topic) + `s3:PutObject` on **`snapshots/`** only |
| `backup` | `voteball-backup-irsa` | `s3:PutObject` on **`backups/`** only — *no SNS, separate role* |

That backend/frontend carry **no role at all** is the concrete least-privilege proof. And the worker and
backup jobs touch the *same bucket under different prefixes with different roles* — a much stronger
answer to "are all services on the same permissions?" than one shared bucket-wide role. The IAM policy
JSON is hand-written (not a module default) in `terraform/irsa.tf` precisely so it's auditable.

Add-on controllers (ALB Controller, External Secrets Operator, Cluster Autoscaler, CloudWatch,
external-dns) each get their own scoped IRSA role via the community `iam-role-for-service-accounts-eks`
helper, which attaches **AWS's own published policies** for each controller (the authoritative
least-privilege definition). external-dns is scoped to the configured hosted zone only
(`route53_zone_name`); the
Autoscaler to this cluster's ASG only; ESO to the one app secret only.

## Secrets

- **Where they live:** AWS **Secrets Manager** (`voteball/app-secret`) holds the DB password + admin
  login. **External Secrets Operator** syncs it into a Kubernetes `Secret` (`app-secret`) via IRSA;
  backend/worker read it with `envFrom`. Terraform never sees the values.
- **Never in git or Terraform state:** Terraform creates only the secret *container* with a placeholder
  and `lifecycle { ignore_changes = [secret_string] }`. The real values are seeded out-of-band by
  `scripts/seed-eks-secret.sh` (a documented manual op). A `charts/voteball/secret-example.yaml` shows
  the shape with placeholders.
- **ConfigMap vs Secret:** non-sensitive config (DB host/name/user, region, topic/bucket names) is a
  `ConfigMap`; only the passwords are a `Secret`. No secret is ever in a ConfigMap.
- **Grafana / ArgoCD:** neither admin password is hardcoded; both are chart-auto-generated and live only
  in in-cluster Secrets, retrieved on demand.
- **CI:** GitHub Actions uses **OIDC federation** to a repo-scoped IAM role — **no long-lived AWS keys**
  are stored in GitHub. The role ARN (not a secret) is a repo *variable*.

**The honest caveat (documented, not hidden):** the repo is public, and until 2026-07-20 it carried the
retired k3s Ansible vault (`secrets.yml`) as `AES256` ciphertext. Its 256-bit password (`.vault_pass`)
was never committed, so no value was ever exposed, and the file has since been **deleted** — the EKS
design has no vault in the deploy path at all (Secrets Manager + ESO, seeded from the environment by
`scripts/seed-eks-secret.sh`). But **git history is permanent**: that ciphertext still exists in old
commits. Any credential that was ever in it should be treated as compromised-on-disclosure and
**rotated** — which is exactly what a fresh deploy now does, since `db_password` is generated per
install and the admin password is entered at seed time rather than read from a committed file.

## Vote integrity

One ballot per visitor is enforced in two layers, because neither is sufficient alone:

- **Cookie (primary).** `voteball_token` is set `HttpOnly` (the page cannot read or forge it),
  `Secure` (never sent over plain HTTP) and `SameSite=Lax` (a third-party page cannot spend a
  visitor's ballot), with a `UNIQUE` constraint on `votes.cookie_token` enforcing it in the database
  rather than in application logic. A repeat vote gets `409`.
- **Per-address cap (secondary).** A cookie is client-side, so clearing it buys another ballot. Each
  vote also stores a **salted SHA-256 of the client address** (`VOTE_IP_SALT`; never the raw address)
  and `MAX_VOTES_PER_IP` (5) ballots per `VOTE_IP_WINDOW_HOURS` (24) are allowed per source, after
  which the API returns `429`. Not 1-per-address: Israeli mobile carriers use CGNAT heavily and
  households share an address, so a hard limit of 1 would lock out many genuine voters.

The client address is taken as the **second-from-right** `X-Forwarded-For` entry, because each hop
(ALB, then nginx) appends. The leftmost entry is attacker-supplied — using it, the common mistake,
would make the cap trivially bypassable by sending a different fake value each request. There is a
regression test for exactly that.

**Honest limitation:** this raises the cost of ballot stuffing, it does not eliminate it. A
determined attacker with many addresses can still vote repeatedly. Genuinely one-vote-per-person on
an anonymous public poll requires authenticating people, which this deliberately does not do.

## Network security

- **Only the frontend is internet-facing.** Traffic path: Internet → **ALB** (public subnets, TLS
  terminated by ACM) → `frontend` Service (ClusterIP) → nginx :8080 → `/api/*` proxied to the `backend`
  Service (ClusterIP :5000). Backend and worker have **no** internet-facing Service.
- **NetworkPolicies** (`charts/voteball/templates/networkpolicy.yaml`), enforced by the VPC CNI
  network-policy engine (enabled on the `vpc-cni` addon): the namespace is **default-deny** (ingress +
  egress), then explicit allows — ALB→frontend:8080, frontend→backend:5000, DNS egress, and app→RDS +
  app→AWS-APIs (443) egress. **Backend is reachable only from frontend** — verified: a pod that isn't
  `frontend` cannot reach `backend:5000`.
- **RDS:** endpoint comes from the Terraform `rds_endpoint` output (→ the ConfigMap's `DB_HOST`). It sits
  in **isolated DB subnets** (no NAT/IGW route), is **not publicly accessible**, and its security group
  accepts `5432` **only from the EKS node security group**. Connections use `sslmode=require`. Storage is
  **encrypted at rest** (KMS, inherited from the encrypted snapshot).

## Ingress security

The app is exposed via an **ALB Ingress** (`charts/voteball/templates/ingress.yaml`). HTTPS is provided
by an **ACM** certificate (DNS-validated, auto-renewing — replacing the k3s certbot mechanism and its
rate limits); HTTP is redirected to HTTPS at the ALB (`ssl-redirect`). external-dns manages the Route53
alias to the ALB. The EKS API server endpoint is public but **IAM-authenticated** and scoped to a
tunable CIDR allow-list (`cluster_endpoint_public_access_cidrs`); private in-VPC access is always on.

## Container security

Every app container (`charts/voteball/templates/*-deployment.yaml`, `backup-cronjob.yaml`) runs with:
`runAsNonRoot: true` (uid 1000; frontend uid 101 via `nginx-unprivileged`), `allowPrivilegeEscalation:
false`, `capabilities.drop: ["ALL"]`, and `readOnlyRootFilesystem: true` with an `emptyDir` mounted only
where a write is genuinely needed (`/tmp` for gunicorn's worker dir, the worker heartbeat file, nginx's
cache, and the backup job's aws-cli config).

## Image security

- **Source & build:** three own images (`backend`, `worker`, `nginx`) each have their own `Dockerfile`,
  build non-root, and use a `.dockerignore` so no secrets/venvs enter the image. The `backup` image is a
  small `postgres:17-alpine` + aws-cli.
- **Tags:** never `latest` — every image is tagged with the **git SHA** and pushed to **ECR**
  (`IMMUTABLE` tags).
- **Scanning:** ECR scan-on-push is enabled, and the CI pipeline runs **Trivy** on every build. The three
  app images scan **clean** (0 CRITICAL/HIGH) and the gate **blocks** on any finding in them; the
  third-party `backup` image is scanned in report-only mode (its CVEs are upstream Go-tooling issues
  outside our control — see Trade-offs).

## RBAC

The app uses namespace-scoped ServiceAccounts with no bound Roles beyond Kubernetes defaults (the app
needs no Kubernetes API access). ArgoCD and the controllers ship their own scoped RBAC from their charts.
No app workload is granted `cluster-admin`.

## Deliberate trade-offs (demo vs production)

These are conscious choices for a torn-down-between-sessions demo; a real production deployment would
change them:

| Choice | Demo (here) | Production would |
|---|---|---|
| App credentials | Generated per install (`db_password` in tfvars, admin password entered at seed time) | Managed rotation (Secrets Manager rotation lambda) |
| EKS RDS | Single-AZ, no deletion protection (a final snapshot IS taken on destroy, so destroy/rebuild preserves data) | Multi-AZ, deletion protection, PITR |
| EKS API endpoint | Public (IAM-authed), CIDR = `0.0.0.0/0` | Lock CIDR to operator/CI, or private-only + bastion |
| Node group | Spot, diversified types (no On-Demand fallback) | Add On-Demand fallback for guaranteed capacity |
| NAT gateway | Single (one AZ) | One per AZ |
| Trivy on backup image | Report-only (upstream third-party CVEs) | Pin/patch a controlled base or waive CVEs explicitly |
| Grafana/ArgoCD UIs | port-forward only, chart-default passwords | SSO, private ingress, rotated secrets |

All are documented rather than hidden — the point is that each was a decision, not an oversight.
