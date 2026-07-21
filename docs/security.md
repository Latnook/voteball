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
| `kube-prometheus-stack-alertmanager` (`monitoring`) | `voteball-alertmanager-irsa` | `sns:Publish` on the one topic — nothing else |

That backend/frontend carry **no role at all** is the concrete least-privilege proof. And the worker and
backup jobs touch the *same bucket under different prefixes with different roles* — a much stronger
answer to "are all services on the same permissions?" than one shared bucket-wide role. The IAM policy
JSON is hand-written (not a module default) in `terraform/irsa.tf` precisely so it's auditable.

Alertmanager was added on 2026-07-21 so operational alerts can leave the cluster. It uses Alertmanager's
native `sns_configs`, which signs with the AWS SDK credential chain — so IRSA is sufficient and **no SMTP
credentials exist on the cluster**, which was the reason notifications had been deferred.

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
- **CI:** the Jenkins build host authenticates through an **IAM instance profile** — see below. **No AWS
  key material exists anywhere**: not in Jenkins' credentials store, not in git, not on the host's disk.
  Jenkins holds exactly two credentials of its own, a GitHub deploy key and the webhook shared secret.
  Since 2026-07-21 these are **no longer typed into the UI**: they live in Secrets Manager
  (`voteball/jenkins`) and are installed at boot by JCasC. That closed a real single point of failure —
  the deploy key's only copy used to be inside Jenkins' own credential store, encrypted with a key on
  the same volume, and was recoverable from nowhere if the host was lost.

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

- **WAF rate limit (network).** Added 2026-07-21. AWS WAF on the ALB blocks any address exceeding
  **100 requests / 5 minutes to `/api/vote`**, so a flood is dropped before it reaches a pod. It is
  deliberately different in kind from the cap above: WAF counts *requests* and forgets, the cap counts
  *successful ballots* over 24h and persists. WAF alone would let a patient script vote steadily under
  the limit; the cap alone leaves pods absorbing the flood. Verified live: a 300-request burst returned
  `403` for every request, while the homepage and results API stayed `200` from the same blocked
  address — the block is scoped to the vote endpoint, not the site.

None of this makes the poll un-stuffable; only authenticating people would, which this project
deliberately declines. The honest goal is "expensive enough not to be worth it".

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
alias to the ALB.

**AWS WAF sits in front of the ALB** (`terraform/waf.tf`), attached by the
`alb.ingress.kubernetes.io/wafv2-acl-arn` annotation rather than a Terraform association — the ALB is
created by the load balancer controller and does not exist at apply time. Four rules: the vote-endpoint
rate limit, a looser site-wide ceiling, AWS *KnownBadInputs* blocking, and the AWS *Common Rule Set* in
**count mode**. That last one is deliberately not blocking: it inspects request bodies and can trip on a
large ballot POST, and a false positive there would silently discard a real vote. It counted a match on
ordinary traffic within hours of going live, which is the argument for counting first.

The EKS API server endpoint is public but **IAM-authenticated** and scoped to a
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

## CI build host (Jenkins)

CI runs on a dedicated EC2 host built by `terraform/jenkins/` — a separate Terraform stack, in the
region's **default VPC**, not the application VPC. Design rationale:
[`docs/design/2026-07-20-jenkins-migration-design.md`](design/2026-07-20-jenkins-migration-design.md).

### Identity: instance profile, not federation

The host carries an IAM role attached to the instance itself, so the AWS CLI picks up **temporary**
credentials from the instance metadata service. There is no OIDC provider, no `configure-aws-credentials`
step, and **no stored key material** — which is the same property the previous CI federation gave, reached
a simpler way, because the compute is ours.

The role allows `ecr:GetAuthorizationToken` plus the ECR layer-upload set on `repository/voteball-*`, and
**nothing else — no EKS, RDS, S3 or SNS**, and exactly one Secrets Manager permission:
`secretsmanager:GetSecretValue` on the single ARN `voteball/jenkins`, added 2026-07-21 so JCasC can
install the host's own credentials at boot. No wildcard, no write. That grants the host nothing it did
not already hold — the deploy key and webhook secret were already on its disk — it only means they also
exist somewhere the host's death does not take with them. Verified on the live host: it reads its own
secret and is denied both `voteball/app-secret` and `list-secrets`; `aws ecr get-login-password`
succeeds and `aws eks list-clusters` returns `AccessDeniedException`.

**IMDSv2 is required** (`http_tokens = "required"`), so a server-side request forgery against something
running on the host cannot trivially read those credentials.

**Jenkins holds no cluster access at all.** It stops at "push images and commit the new tag"; ArgoCD does
the deploying. This is the same boundary the GitOps model already gave us, and it means replacing or
compromising CI never reaches the cluster.

### Network posture

| Direction | Port | Source / destination | Purpose |
|---|---|---|---|
| inbound | 8080 | GitHub's hook CIDRs only, fetched from `api.github.com/meta` at apply time | receive push webhooks |
| inbound | 22 | the maintainer's IP as a `/32` | SSH tunnel to the UI |
| outbound | all | anywhere | ECR, GitHub, Docker Hub, ghcr.io, OS packages |

**The Jenkins UI is never publicly reachable.** Access is `ssh -L 8080:localhost:8080`; tunnelled traffic
arrives from `localhost` and so is never evaluated against the security group. Verified: `curl` to port
8080 from the maintainer's own IP times out.

The property that makes this defensible is that exactly **one** thing in the world can initiate a
connection to this host, and it is GitHub.

### Two accepted positions, stated rather than left implicit

- **Egress is unrestricted.** Docker Hub, ghcr.io and GitHub publish wide and frequently changing IP
  ranges. An egress allowlist against them would break builds regularly without meaningfully constraining
  an attacker who already has code execution on a build host. Standard practice, and a deliberate choice.
- **The webhook is plain HTTP, authenticated by a shared secret rather than by TLS.** Jenkins verifies the
  HMAC signature GitHub attaches to every delivery, so an unsigned or wrongly signed request is rejected
  (verified: signed → 200, unsigned → 400). The payload contains no secrets, and the signature is what
  actually establishes authenticity — TLS would add confidentiality for a public commit notification, at
  the price of a certificate lifecycle on a host with no DNS name.

### Accepted risk: `docker` group membership is effectively root

The `jenkins` user is in the `docker` group so it can build images. Anyone who can define or edit a
Jenkins job can therefore run a privileged container and take the host. This is **inherent** to building
container images on a Jenkins agent, not something this setup got wrong.

It is mitigated by there being **no inbound access to the host except GitHub's webhook** — no public UI,
no other open port — and by Jenkins requiring authentication. It is also bounded by the previous section:
the worst an attacker on this host gains is ECR push on four repositories and a deploy key for one
repository. No cluster, no database, no secrets.

### Blast radius of the credentials Jenkins does hold

- **GitHub deploy key** — repository-scoped, chosen over a personal access token precisely because a PAT
  covers the whole account. Compromise loses exactly this repository.
- **Webhook shared secret** — lets an attacker trigger builds. It cannot make Jenkins build code that is
  not on `master`.

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
| EKS RDS | Single-AZ. **PITR is now on** (7-day retention, added 2026-07-21). Deletion protection stays **off** on purpose: it makes `terraform destroy` fail, and this stack is torn down between sessions | Multi-AZ; deletion protection only if the destroy/rebuild workflow is retired |
| EKS API endpoint | Public (IAM-authed), CIDR = `0.0.0.0/0` | Lock CIDR to operator/CI, or private-only + bastion |
| Node group | Spot, diversified types (no On-Demand fallback) | Add On-Demand fallback for guaranteed capacity |
| NAT gateway | Single (one AZ) | One per AZ |
| Trivy on backup image | Report-only (upstream third-party CVEs) | Pin/patch a controlled base or waive CVEs explicitly |
| Grafana/ArgoCD UIs | port-forward only, chart-default passwords | SSO, private ingress, rotated secrets |
| Jenkins webhook | Plain HTTP, authenticated by HMAC shared secret | TLS in front of Jenkins (ALB/reverse proxy + ACM) |
| Jenkins host access | SSH tunnel on port 22 from one IP | SSM Session Manager, port 22 closed entirely |
| Jenkins configuration | **JCasC** (`terraform/jenkins/casc/`), applied at every boot; credentials from Secrets Manager. Verified by booting a throwaway host from the config | Notifications on build failure (G7); SSM Session Manager |

All are documented rather than hidden — the point is that each was a decision, not an oversight.
