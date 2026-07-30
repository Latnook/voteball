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
- **CI:** Jenkins runs in-cluster (namespace `ci`) and its agent pods authenticate via **IRSA** — see
  below. **No AWS key material exists anywhere**: not in Jenkins' credentials store, not in git, not on
  any node's disk. Jenkins holds exactly two credentials of its own, a GitHub deploy key and the webhook
  shared secret, both in Secrets Manager (`voteball/jenkins`), synced into the cluster by External
  Secrets Operator and installed by JCasC — never typed into the UI. Because the controller's
  `JENKINS_HOME` is an `emptyDir` (build history is deliberately disposable — see `docs/cicd.md`), those
  credentials living outside Jenkins' own credential store is not a nicety, it is the only reason the
  deploy key survives a daily Spot reclaim at all.

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

**One deliberate, documented exception: the `buildkit` container in a CI agent pod** (`ci` namespace,
`ci/jenkins/jenkins.yaml`). It is the only container in the entire project that runs
`allowPrivilegeEscalation: true` and adds capabilities (`SETUID`, `SETGID`) rather than dropping all of
them. Rootless BuildKit builds each image inside its own Linux user namespace, and constructing that
namespace requires `newuidmap`/`newgidmap` — SETUID binaries that `allowPrivilegeEscalation: false` and
`capabilities.drop: [ALL]` together disable outright. Without the exception the container looks healthy
(`rootlesskit` fails instantly, the pod still reports ready) and the build simply hangs forever with
nothing logged, which is a worse failure mode than an honest, narrow grant.

**What this is not:** it is not Docker-in-Docker, which was the alternative considered and rejected.
DinD needs `privileged: true` — full access to the host's devices, kernel capabilities and namespaces,
effectively root on the node. The `buildkit` container still runs as **uid 1000**, with no host devices,
no host paths, and no `CAP_SYS_ADMIN` — it can only map UIDs inside a namespace that belongs to itself.
The blast radius is bounded further by the `ci` NetworkPolicy, which denies this pod any route to RDS or
the `devops-app` namespace regardless of what runs inside it. Every other container in the project,
including the other three containers in the same CI agent pod (`trivy`, `skopeo`, `awscli`), keeps
`allowPrivilegeEscalation: false` — this is a one-container exception, not a precedent.

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

## CI (Jenkins, in-cluster)

CI runs **inside the EKS cluster**, namespace `ci`, installed by Terraform
(`terraform/addon-jenkins.tf`) as a `helm_release`. It replaced a dedicated EC2 host on 2026-07-30/31.
Design rationale:
[`docs/design/2026-07-20-jenkins-migration-design.md`](design/2026-07-20-jenkins-migration-design.md)
(pipeline logic) and
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md)
(in-cluster move, including what its own security assumptions got wrong in practice — see that doc's
"Verification outcome").

### Identity: IRSA, split narrower than the instance profile it replaces

The old EC2 instance profile held both ECR push and one Secrets Manager permission on a single identity.
In the cluster that is split across two ServiceAccounts:

| ServiceAccount | AWS role | Permissions |
|---|---|---|
| `jenkins` (the controller) | **none** | The controller never touches AWS at all |
| `jenkins-agent` (build pods only) | IRSA | `ecr:GetAuthorizationToken` + push/pull on `repository/<cluster_name>-*`, nothing else — no EKS, RDS, S3, SNS |

Secrets Manager access belongs to **External Secrets Operator's** role, not Jenkins' — Jenkins never
calls `secretsmanager:GetSecretValue` itself; ESO syncs `voteball/jenkins` into a Kubernetes Secret and
JCasC reads it as pod environment variables. This is a narrower design than the EC2 host's single
`GetSecretValue` grant, not a like-for-like port of it.

**Jenkins holds no cluster-deploy access at all**, for a sharper reason than before it moved in-cluster:
it stops at "push images and commit the new tag"; ArgoCD does the deploying, and Jenkins is now
*physically inside* the cluster it must still be unable to change. The controller's own Role (namespace
`ci`) only lets it create/watch/delete/exec into agent pods in that one namespace — verified
(`kubectl auth can-i --as=system:serviceaccount:ci:jenkins get pods -n devops-app` → no).

### Network exposure — only the webhook path, not the UI

The EC2 host exposed the **entire Jenkins UI** — script console, credential store, everything — to
GitHub's CIDR ranges over plaintext HTTP, an accepted risk documented at the time. **That risk is closed,
not carried forward:**

- **Only `/github-webhook` is routed.** The Ingress (`charts/jenkins-support/templates/ingress.yaml`)
  matches exactly that path; the root path and `/script` both return `404` — there is no ALB rule that
  reaches them. Verified: `curl https://jenkins.<app_domain>/` and `.../script` both 404, while
  `.../github-webhook/` reaches Jenkins.
- **HTTPS via ACM**, not plaintext HTTP — a dedicated certificate for `jenkins.<app_domain>`, separate
  from the app's so it never touches `ingress.certificateArn` (keeps `sync-values-from-tf.sh` at ten
  managed fields).
- **The UI is reachable only via `kubectl port-forward -n ci svc/jenkins 8080:8080`** — there is no
  Ingress rule for it at all, so "reach the UI" now requires cluster access (your AWS login) first,
  where before it required only the SSH key and a `/32` allowlist entry.
- **A NetworkPolicy denies CI any route to RDS or `devops-app`**
  (`charts/jenkins-support/templates/networkpolicy.yaml`), written as broad-egress-with-specific-denials
  rather than an IP allowlist — ECR, GitHub and the various registries publish wide, shifting ranges, so
  an allowlist there would be brittle rather than secure (the same reasoning the EC2 security group used
  for its own unrestricted egress). What actually matters and is enforceable: this namespace's three
  RFC1918 ranges are excluded from the "allow the internet" rule, closing the specific routes to RDS and
  the app namespace. Verified from an agent pod: the RDS endpoint times out, ECR and GitHub are
  reachable.

The webhook itself is still authenticated the same way as on EC2: Jenkins verifies the HMAC signature
GitHub attaches to every delivery (signed → 200, unsigned → 400), so a request without the shared secret
is rejected regardless of what path it lands on.

### Blast radius of the credentials Jenkins does hold

- **GitHub deploy key** — repository-scoped, chosen over a personal access token precisely because a PAT
  covers the whole account. Compromise loses exactly this repository.
- **Webhook shared secret** — lets an attacker trigger builds. It cannot make Jenkins build code that is
  not on `master`.
- Both live only in Secrets Manager and the in-cluster Secret ESO writes from it — never in Jenkins' own
  credential store, which is moot anyway now that `JENKINS_HOME` is an `emptyDir` that does not survive
  a Spot reclaim.

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
| Grafana/ArgoCD UIs | port-forward only (ClusterIP, no Ingress); each chart generates its own admin password into a Secret at install — **not** a chart default, and different after every rebuild (verified 2026-07-27: 40 random alphanumerics, not `prom-operator`). Reaching either requires cluster access first, so the passwords are a second layer | SSO, private ingress, rotated secrets |
| Jenkins webhook | HTTPS (ACM) + HMAC shared secret; only `/github-webhook` routed | Already close to production shape here |
| Jenkins UI access | `kubectl port-forward` only, no Ingress rule at all | Same in production — this is the stronger option, not a shortcut |
| Jenkins build history | Disposable — `JENKINS_HOME` is an `emptyDir`, reset roughly daily by Spot reclaim and on every teardown | Accepted permanently, not just for the demo — see `docs/cicd.md` and the design doc's §2 for why a PVC would be worse, not better, at this reclaim rate |
| Jenkins configuration | **JCasC** (`ci/jenkins/jenkins.yaml`), applied via `terraform apply`; credentials from Secrets Manager via ESO. Verified by booting a fresh controller and by a real end-to-end build | Notifications on build failure (G7) |

All are documented rather than hidden — the point is that each was a decision, not an oversight.
