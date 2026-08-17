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
- **CI/CD:** Jenkins runs in-cluster (namespace `ci`), split since 2026-08-04 into two pipelines
  (`application-ci`, `application-cd`), and its agent pods authenticate via **IRSA** — see below.
  **No AWS key material exists anywhere**: not in Jenkins' credentials store, not in git, not on any
  node's disk. Jenkins holds three credentials of its own — a GitHub deploy key (used by both
  pipelines), the webhook shared secret, and an ArgoCD API token scoped to the `voteball` Application
  (used only by `application-cd`) — all in Secrets Manager (`voteball/jenkins`), synced into the
  cluster by External Secrets Operator and installed by JCasC, never typed into the UI. The controller's
  `JENKINS_HOME` is a PersistentVolumeClaim on EFS (not an `emptyDir` — see `docs/cicd.md`), so build
  history now survives a routine Spot reclaim; credentials still live outside Jenkins' own credential
  store regardless, since that store is not what ESO writes to and is not what would need to be
  re-registered after a genuine loss of the volume.

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

**The site-wide rule blocks the whole site for the offending address, not just the API** — 2,000
requests / 5 minutes per IP, counted across *every* path including static assets. Confirmed the hard
way on 2026-08-03: an unthrottled uptime-probe loop from one machine crossed it, and the next 558
requests to `/` returned `403` from `awselb`. CloudWatch attributed them precisely —
`voteball-rate-sitewide` blocked 1,299 requests in that window, `voteball-rate-vote` none. Two things
follow. Operationally, a monitoring probe dense enough to prove uptime is dense enough to be blocked,
and its `403`s look exactly like an outage (`scripts/capture-evidence.sh` throttles to 2 req/s for
this reason). And as a policy question, a large shared NAT — a university or corporate egress — could
plausibly reach 2,000 requests / 5 min across many genuine users at ~15 requests per page load; the
limit is set where it is deliberately, but it is a ceiling on *addresses*, not on people.

The EKS API server endpoint is public but **IAM-authenticated** and scoped to a
tunable CIDR allow-list (`cluster_endpoint_public_access_cidrs`); private in-VPC access is always on.

## Container security

Every app container (`charts/voteball/templates/*-deployment.yaml`, `backup-cronjob.yaml`) runs with:
`runAsNonRoot: true` (uid 1000; frontend uid 101 via `nginx-unprivileged`), `allowPrivilegeEscalation:
false`, `capabilities.drop: ["ALL"]`, and `readOnlyRootFilesystem: true` with an `emptyDir` volume
mounted only where a write is genuinely needed (`/tmp` for gunicorn's worker dir, the worker heartbeat
file, nginx's cache, and the backup job's aws-cli config) — unrelated to Jenkins' own storage, covered
separately below.

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

### Base-image patching

**`backend` and `worker` run `apt-get upgrade` as their first build step, and removing it will start
failing every build within weeks.** Both are `FROM python:3.12-slim`; the official image is rebuilt on
its own cadence and therefore lags Debian's security feed. The Trivy gate is
`--severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed`, and `--ignore-unfixed` is what makes this
sharp: a base-package CVE is invisible while it is unfixed, then becomes **instantly blocking** the
moment Debian publishes a fix. So CI can go from green to red with **no change to this repository at
all**.

That is not hypothetical. `application-ci` **#1 on 2026-08-17** failed on `CVE-2026-53615` —
9 HIGH findings across Debian 13.6's `util-linux` family (`bsdutils`, `libblkid1`, `libmount1`,
`libsmartcols1`, `libuuid1`, `mount`, `util-linux`, `util-linux-extra`), installed `1:2.41-5` against
an available `2.41.5-0+deb13u1`. The previous green build was six days earlier and nothing in
`services/` had changed. Captured in
[`eks/evidence/2026-08-17-task4-ci-scan-blocks-deploy-run.txt`](eks/evidence/2026-08-17-task4-ci-scan-blocks-deploy-run.txt),
which is also the evidence that a failed scan **blocks the deploy**: `Push to ECR`, `Publish Metadata`
and `Trigger CD` all report `skipped due to earlier failure(s)`, so nothing reached ECR and
`application-cd` never ran.

**Why the fix is `apt-get upgrade` and not a `.trivyignore`.** The findings carried status `fixed`
with a named fixed version — a `.trivyignore` would have suppressed a vulnerability that had a patch
sitting in the archive, which is the exact case the gate exists to catch. Patching at source clears
all nine (verified: `Total: 0 (HIGH: 0, CRITICAL: 0)` on both rebuilt images against the same gate)
and clears the *next* base CVE too, instead of needing a new waiver each time.

**The trade-off, stated plainly:** the image is no longer a pure function of the git SHA — two builds
of the same commit on different days can contain different package versions. That is bounded here
because ECR tags are `IMMUTABLE` and CI's G1 guard (`scripts/ci/images-exist.sh`) skips any tag
already present, so a given SHA is built exactly once and the image that SHA names never changes
after the fact. The alternative — pinning every apt package — would trade a reproducibility gain for
a standing obligation to hand-bump pins ahead of each CVE, which is the failure this section exists
to describe.

`frontend` (`nginx-unprivileged:alpine`) needs none of this and does not do it: Alpine's package set
scans clean, and adding an upgrade step there would be cargo-culting.

## CI/CD (Jenkins, in-cluster, two pipelines)

CI/CD runs **inside the EKS cluster**, namespace `ci`, installed by Terraform
(`terraform/addon-jenkins.tf`) as a `helm_release`. It replaced a dedicated EC2 host on 2026-07-30/31,
and split from one pipeline into two (`application-ci`, `application-cd`) on 2026-08-04. Design
rationale:
[`docs/design/2026-07-20-jenkins-migration-design.md`](design/2026-07-20-jenkins-migration-design.md)
(pipeline logic) and
[`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md)
(in-cluster move, including what its own security assumptions got wrong in practice — see that doc's
"Verification outcome"), and
[`docs/design/2026-08-04-cicd-split-design.md`](design/2026-08-04-cicd-split-design.md) (the split
itself, including why ArgoCD remains the sole applier).

### Identity: IRSA, split narrower than the instance profile it replaces, then split again by job

The old EC2 instance profile held both ECR push and one Secrets Manager permission on a single identity.
In the cluster that is split across the controller and, since the 2026-08-04 CI/CD split, **two separate
agent ServiceAccounts** — one per pipeline, each holding only what that pipeline's job needs:

| ServiceAccount | Used by | AWS role (IRSA) | Kubernetes RBAC |
|---|---|---|---|
| `jenkins` (the controller) | both jobs' scheduling | **none** | namespace-scoped `Role` in `ci`: create/watch/delete/exec its own agent pods, nothing else, nothing in any other namespace |
| `jenkins-agent` (`application-ci` agents) | build/test/scan/push | `ecr:GetAuthorizationToken` + push/pull on `repository/<cluster_name>-*`, nothing else — no EKS, RDS, S3, SNS | **none** — no Role or ClusterRole binds this ServiceAccount anywhere |
| `jenkins-cd-agent` (`application-cd` agents) | promote/deploy/verify | `ecr:DescribeImages`/`ecr:BatchGetImage` **read-only** on the four app repos — no push | namespaced, **strictly read-only** `Role` in `devops-app` (`get`/`list`/`watch` on deployments, replicasets, pods, services, events, ingresses, plus `get` on pod logs — no `patch`, `create`, or `delete`, no ClusterRole) |

Secrets Manager access belongs to **External Secrets Operator's** role, not Jenkins' — neither job ever
calls `secretsmanager:GetSecretValue` itself; ESO syncs `voteball/jenkins` into a Kubernetes Secret and
JCasC reads it as pod environment variables. This is a narrower design than the EC2 host's single
`GetSecretValue` grant, not a like-for-like port of it.

**Neither pipeline holds cluster-*write* access**, for a sharper reason than before Jenkins moved
in-cluster: `application-ci` stops at "push images and hand the tag to CD"; `application-cd` stops at
"ask ArgoCD to sync a git revision, then read the result back" — its Role has no verb that changes
state. ArgoCD does every apply, and Jenkins is *physically inside* the cluster it must still be unable
to change. This is asserted, not just documented: `scripts/jenkins/verify-jenkins.sh` runs
`kubectl auth can-i patch deployments --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app` and
fails the check if the answer is ever `yes`.

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
- **`application-cd` can reach `argocd-server` on port 443 (used) and, verified live, also on port
  80** — looser than the NetworkPolicy's own comment implies, since the rule that re-admits the EKS
  service CIDR lists only ports 443/8080/50000. Stated here plainly rather than glossed over: the claim
  this document makes is that CD **cannot write to the cluster** (enforced by its read-only RBAC, and
  absolute), not that its network path to ArgoCD is minimal (it is not, and the practical impact of that
  gap is nil — every `argocd` CLI call in `Jenkinsfile-cd` uses `--grpc-web` over 443, and `--plaintext`,
  which would use port 80, is never invoked).

The webhook itself is still authenticated the same way as on EC2: Jenkins verifies the HMAC signature
GitHub attaches to every delivery (signed → 200, unsigned → 400), so a request without the shared secret
is rejected regardless of what path it lands on.

### Blast radius of the credentials Jenkins does hold

- **GitHub deploy key** — repository-scoped, chosen over a personal access token precisely because a PAT
  covers the whole account. Compromise loses exactly this repository, and grants write access to
  `master` — the same access level a compromised laptop with a valid GitHub session already has.
- **Webhook shared secret** — lets an attacker trigger `application-ci` builds. It cannot make Jenkins
  build code that is not on `master`, and cannot reach `application-cd` directly (that job has no
  webhook trigger at all).
- **ArgoCD API token (`jenkins-cd` account)** — new with the 2026-08-04 split. Scoped in
  `argocd-rbac-cm` to `get`/`sync` on the `voteball` Application only: no other Application, no admin
  scope, and the account is `apiKey`-only so a stolen token cannot be used to log into the ArgoCD UI.
  Compromise lets an attacker force a sync of whatever `master` currently says — which they could
  already do more directly with the GitHub deploy key above — but grants no ability to change *what*
  gets synced independent of git, and no ability to touch any other Application.
- All three live only in Secrets Manager and the in-cluster Secret ESO writes from it — never in
  Jenkins' own credential store. `JENKINS_HOME` is a PersistentVolumeClaim on EFS, not an `emptyDir`
  (see `docs/cicd.md`), so this is a design choice rather than a consequence of the volume being wiped
  daily: even with build history now surviving a routine reclaim, no credential is ever stored where
  only Jenkins' own database would have it.

## RBAC

The app uses namespace-scoped ServiceAccounts with no bound Roles beyond Kubernetes defaults (the app
needs no Kubernetes API access). ArgoCD and the controllers ship their own scoped RBAC from their charts.
No app workload is granted `cluster-admin`.

### The delivery path is itself an authorization boundary

ArgoCD holds broad rights in the cluster, so what it is *permitted to deploy* matters as much as what
the app can do. Since 2026-08-03 the `voteball` Application runs inside a dedicated **`AppProject`**
(`argocd/voteball-application.yaml.tmpl`) that pins three things — live values, not aspirations:

| Constraint | Value | Effect |
|---|---|---|
| `sourceRepos` | `https://github.com/Latnook/voteball` | It can deploy only from this repo |
| `destinations` | `devops-app` on the in-cluster API server | It can write only into that one namespace |
| `clusterResourceWhitelist` | `[]` (empty) | **It may create no cluster-scoped object at all** |

The empty whitelist is the load-bearing one. It means a commit to `master` cannot introduce a
`ClusterRole`, `ClusterRoleBinding`, CRD or `StorageClass` through the app's own delivery path —
widening that blast radius takes a deliberate, reviewable edit to the AppProject first. It is also
why the chart does **not** ship a `Namespace` template even though the namespace is part of the
deliverable: a `Namespace` is cluster-scoped, so shipping it would mean handing the app's release
permission to create cluster-scoped resources in order to save one `--create-namespace` flag.

**Nothing here is configured through the ArgoCD UI, and that is enforced rather than asserted.**
`./scripts/render-argocd-app.sh --check` fails on any live/template mismatch, on any
`Application`/`AppProject` this repo does not declare, and on any hand-registered repository or
cluster credential. It has to be a separate check because ArgoCD cannot do it itself: `selfHeal`
reconciles the *contents* of `charts/voteball`, but nothing reconciles the `Application` pointing at
it — so a UI edit to sync policy or destination is the one drift GitOps cannot self-correct.

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
| Jenkins build history | Persists across a routine Spot reclaim — `JENKINS_HOME` is a PersistentVolumeClaim on EFS (not EBS, which stays AZ-locked on this 100%-Spot node group) — but is lost if the Jenkins release itself is removed, and gone for good only on a full teardown of the EFS resources | See `docs/cicd.md`'s storage-survival table; the durable record of what was *deployed* was never the build log anyway |
| Jenkins configuration | **JCasC** (`ci/jenkins/jenkins.yaml`), applied via `terraform apply`; credentials from Secrets Manager via ESO. Verified by booting a fresh controller and by a real end-to-end build | Notifications on build failure (G7) |

All are documented rather than hidden — the point is that each was a decision, not an oversight.
