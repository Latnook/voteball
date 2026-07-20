# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Voteball is a public poll correlating football fandom with Israeli political-party voting, deployed on
**Amazon EKS**. It was bootstrapped from infra patterns proven in a separate `Rolling AWS Project files`
(S3App) repo but is fully independent — no shared code or state.

**The repo is designed to be forkable**: no AWS account, region or domain is hardcoded anywhere in
code. Identity lives in exactly two places — `terraform/voteball.tfvars` (pre-apply) and
`terraform output` (post-apply) — both read through `scripts/lib/config.sh`. The env-specific fields of
`charts/voteball/values.yaml` are marked `FILLED-BY-SYNC` and written by
`scripts/sync-values-from-tf.sh`. **If you add a hardcoded ARN, bucket, registry or domain anywhere,
that is a bug.**

> **The single-node k3s deployment is RETIRED and its code was removed on 2026-07-20** (the `terraform/`
> stack, the Ansible playbook/roles, and the SSH-based reverse-seed script — all recoverable from git
> history). The live deployment is `terraform/` + `charts/voteball/`, and the app source is in
> `services/{backend,worker,frontend,backup}/`, one Docker build context each.

**Plans live in `docs/superpowers/plans/`** — the EKS migration was built as a sequence of task-by-task
specs (app-code foundation → EKS infra → add-ons → app deploy → expose/harden → GitOps/observability →
docs), followed by the deployment-hardening and repo-forkability passes. Read the relevant plan before
making architectural changes: most design decisions (and the bugs they avoid) are explained there, not
in code comments.

Submission/reference docs: `README.submission.md`, `docs/security.md`, `docs/eks/architecture.md`,
`docs/deploy.md` (plain-language runbook), `docs/eks/live-cluster-snapshot.md`.

## Workflow

**Commit and push changes as you make them in this repo** — this is standing,
pre-authorized permission (per the user's explicit request); don't leave work
committed-but-unpushed or uncommitted waiting to be asked. Still use judgment
on grouping related changes into one coherent commit rather than pushing
every single edit separately, and never force-push.

## Architecture

Three containers in the `devops-app` namespace on EKS, provisioned by the `terraform/` stack and
delivered by the `charts/voteball` Helm chart (synced by ArgoCD):

- **frontend** — nginx serving plain HTML/CSS/vanilla JS (no build step), reverse-proxying `/api/*` to
  the backend.
- **backend** (`services/backend/`) — Flask 3.1 app. `app.py` holds all
  routes; `queries.py` holds all SQL; `db.py` holds only connection setup (`get_db`) and one-time
  schema bootstrap (`init_db`, which loads `schema.sql` then `seed.sql` — the backend is the only
  container that ever creates schema).
- **worker** (`services/worker/`) — Python batch/loop process that
  recomputes the `rollup_previous`/`rollup_upcoming`/`rollup_previous_upcoming` tables from
  `votes`/`vote_upcoming_parties`, and sends milestone SNS alerts.

**Each service directory is its own Docker build context — there is no shared Python package
between backend and worker.** The worker has its own near-duplicate `db.py` rather than
importing the backend's. This is a deliberate simplicity choice, not an oversight; don't "fix" it by
introducing a shared module unless the plan says to.

Postgres (RDS) stores: static seed data (`leagues`, `clubs`, `previous_parties`, `upcoming_parties` —
the two party tables are also admin-editable after seeding), raw votes (`votes`, `vote_clubs`,
`vote_leagues`, `vote_upcoming_parties` — a ballot can name up to 3 clubs per league across any
number of leagues, so `votes` itself carries no league/club column; `vote_clubs` records each
specific-club pick with the league tab it was picked under, `vote_leagues` records "just this
league, no specific club" picks), and worker-computed rollup tables (`rollup_previous`,
`rollup_upcoming`, `rollup_previous_upcoming` — each carries a league-scope row per distinct league
a vote touched, `club_id IS NULL`, deduped per vote+league, plus a club-scope row per specific pick
— and `rollup_national_previous`/`rollup_national_upcoming`/`rollup_national_previous_upcoming`,
counted one row per vote with no league/club dimension, since summing the league/club-scoped
rollups for national totals would over-count a multi-team ballot) that the backend reads for fast
`/api/results` responses.

### Backend request-handling pattern

Every route acquires its own `psycopg2` connection via `db.get_db()` (no pooling) and must guarantee
`conn.close()` on every exit path, including unexpected exceptions — use `try/finally`, not scattered
`conn.close()` calls in each branch (see `results()` and `vote()` in `app.py` for the established
shape). `queries.py` functions that mutate data must `conn.rollback()` in a broad `except` before
re-raising, not just catch the one expected constraint-violation error, since this is the failure mode
that leaks connections on a public endpoint (see `insert_vote`'s history in `queries.py`).

Admin endpoints (`/api/admin/...`) are protected by the `require_admin` decorator in `app.py`, which
verifies an `Authorization: Bearer <token>` header — a signed, 12-hour-expiring token
(`itsdangerous.URLSafeTimedSerializer`) issued by `POST /api/admin/login` after checking a username
and `werkzeug`-hashed password (`ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH`/`ADMIN_SESSION_SECRET` env
vars). Reuse this decorator for any new admin route — don't hand-roll the check.

### API surface

| Route | Method | Auth | Notes |
|---|---|---|---|
| `/health` | GET | none | liveness/readiness probe target |
| `/api/options` | GET | none | leagues/clubs/previous_parties/upcoming_parties, consumed by both frontend pages |
| `/api/vote` | POST | none, cookie-deduped | body `{"team_picks": [{"league_id", "club_id"}, ...], "previous_vote_status", "previous_party_id", "upcoming_vote_status", "upcoming_party_ids"}`; `team_picks` needs ≥1 entry, ≤3 non-null `club_id` picks per distinct `league_id`, and a `club_id: null` ("just this league") entry can't coexist with specific-club entries in the same league; each `club_id`/`league_id` pair is validated against that club's real `{league_id, domestic_league_id}`; sets `voteball_token` cookie (1yr); 409 on repeat vote; 400 if `upcoming_vote_status=considering` with no `upcoming_party_ids`, or if `upcoming_party_ids` has more than 3 entries — client also validates all of this before submitting |
| `/api/results` | GET | none | `?by=club\|league&id=N`, `?by=party&type=previous\|upcoming&id=N` (also returns a national `crosstab` of the other party type), or `?by=all` (national totals); reads the worker-computed rollup tables — `by=league` and `by=all` read the dedup/national-scoped rows so a multi-team ballot isn't over-counted |
| `/api/results/segment` | GET | none | `?previous_party_id=P[&club_id=C\|&league_id=L]`; the "voters like you" migration cut — club/league-scoped if given, else national; returns `{"upcoming": [...], "total": N}` |
| `/api/admin/login` | POST | none | body `{"username", "password"}`; returns `{"token"}` on success, `401` on any failure |
| `/api/admin/previous-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/previous-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/previous-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; moves every vote's `previous_party_id` from `<id>` to `target_id`, returns `{"reassigned": N}` |
| `/api/admin/upcoming-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/upcoming-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/upcoming-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/upcoming-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; reassigns every vote's `<id>` pick to `target_id` (collision-safe against the ≤3-pick cap), returns `{"reassigned": N}` |
| `/api/admin/votes` | GET | Bearer token | list all votes (no `cookie_token` in the response); each vote carries `team_picks: [{"league_id", "club_id"}, ...]` (assembled from separate queries against `vote_clubs`/`vote_leagues`, not a joined `array_agg`, to avoid cartesian-inflating `upcoming_party_ids` alongside it) |
| `/api/admin/votes/<id>` | DELETE | Bearer token | remove one vote; cascades to its `vote_clubs`/`vote_leagues`/`vote_upcoming_parties` rows |

Frontend pages: `index.html`/`vote.js` (voting form, posts to `/api/vote`), `results.html`/`results.js`
(dashboard, reads `/api/results`), `admin.html`/`admin.js` (unlinked from the public pages — party
CRUD, vote reassignment for merges/splits, and votes list/delete, gated by username/password login
issuing a session-stored Bearer token). All three render backend-derived names via
`createElement`/`textContent`, never `innerHTML` string interpolation — `previous_parties`/
`upcoming_parties` names come from an external API and admin input respectively, neither is safe to
trust as pre-escaped HTML.

## Deployment

**`docs/deploy.md` is the plain-language runbook** — follow it for real deploys. Summary of the split:

- **Terraform (`terraform/`)** builds everything AWS: dedicated VPC, EKS cluster + Spot node group,
  OIDC/IRSA roles, ECR, ACM, S3, SNS, Secrets Manager (container only), RDS (restored from a pinned
  snapshot), **and every platform add-on** via `helm_release`/`aws_eks_addon` (AWS Load Balancer
  Controller, External Secrets Operator, Cluster Autoscaler, Node Termination Handler, CloudWatch
  Container Insights, metrics-server, external-dns, ArgoCD, kube-prometheus-stack). Needs
  `terraform/voteball.tfvars` (gitignored) and `-var-file=voteball.tfvars`.
- **Helm (`charts/voteball`)** is the app itself (namespace `devops-app`): 3 Deployments, Services,
  Ingress→ALB, ConfigMap, ExternalSecret, 4 ServiceAccounts, NetworkPolicies, HPA, PDBs, backup CronJob.
  **ArgoCD** syncs it from `master` (GitOps) — the chart is the single authoring path.
- **`./scripts/deploy.sh` / `./scripts/destroy.sh`** run the full ordered sequence (both stop for
  confirmation before Terraform touches billed resources). The env-specific fields of `values.yaml`
  (`image.tag`, `config.DB_HOST`, `config.S3_BUCKET`, `ingress.certificateArn`, `backup.roleArn`,
  `worker.roleArn`) are written by **`./scripts/sync-values-from-tf.sh`** from Terraform outputs —
  **never hand-edit them**; they change on every rebuild. `--check` mode fails on drift, and also
  verifies `image.tag` names an image that actually exists in ECR.
- **Secrets:** `./scripts/seed-eks-secret.sh` copies app passwords into Secrets Manager; nothing
  secret ever enters git or tfstate.
- **CI/CD:** pushing app code to `master` runs `.github/workflows/ci.yml` (OIDC → build → Trivy → ECR →
  bump `image.tag` `[skip ci]` → ArgoCD auto-syncs). `./scripts/build-push-ecr.sh` does it by hand.

**Teardown order matters** and `./scripts/destroy.sh` encodes it: delete the ArgoCD Application (else
`selfHeal` recreates what you remove), then the Ingress (so the ALB de-provisions and external-dns
removes its records — a leftover ALB's ENIs block VPC deletion), wait for the ALB to disappear, *then*
`terraform destroy`. If destroy hangs uninstalling a `helm_release` ("context deadline exceeded" — Helm
can't cleanly uninstall while the cluster is being deleted), `terraform state rm` that release and
re-run destroy; it dies with the cluster anyway.

RDS takes a **final snapshot on destroy** (since 2026-07-20), so destroy→rebuild preserves votes;
`find-latest-snapshot.sh` picks the newest one up automatically before the next apply.

Two teardown behaviours `destroy.sh` handles that a manual `terraform destroy` does not:
- **`./scripts/cleanup-stale-dns.sh`** removes this cluster's Route53 records if external-dns didn't get
  to it first (it only reconciles on a timer and can be destroyed before noticing the deleted Ingress).
  Gated on the ownership TXT (`external-dns/owner=voteball`), so apex/MX/DKIM records are never eligible.
- **An orphaned-ENI reaper** runs in the background during destroy. The VPC CNI leaves detached
  `aws-K8S-*` interfaces when nodes terminate, and they make Terraform retry `DeleteSubnet` against a
  `DependencyViolation` for 10–20 minutes. See `docs/deploy.md` troubleshooting for the manual command.

**Do not add `ignore_changes` to `final_snapshot_identifier`** in `database.tf` — the provider reads it
from state at destroy time, so that silently disables the final snapshot *and* wedges the VPC teardown.
There's a comment there explaining why; keep it.

### Reverse-seeding: keeping seed.sql in sync with admin-UI edits

Admin-curated data (logo URLs, renames) lives only in the live RDS instance until someone backfills it
into `seed.sql`. `scripts/sync-seed-from-rds.sh` used to automate this, but it tunnelled to RDS over
SSH through the k3s EC2 node — which EKS does not have — so it was **removed on 2026-07-20**. Porting
it would mean replacing the SSH tunnel with `kubectl port-forward` through a backend pod; the original
is in git history.

### Secrets

**On EKS, secrets live in AWS Secrets Manager** (`voteball/app-secret`) and are synced into the
`app-secret` Kubernetes Secret by External Secrets Operator via IRSA. Terraform creates only the empty
container (`ignore_changes = [secret_string]`), so **no secret value ever enters git or tfstate**.
See `docs/security.md`.

Seed the values with `./scripts/seed-eks-secret.sh`, which takes `DB_PASS`, `ADMIN_USERNAME` and
`ADMIN_PASSWORD` from the environment or a silent prompt, hashes the password with `werkzeug` and
generates `ADMIN_SESSION_SECRET` itself. Nothing is echoed or written to disk. **`DB_PASS` must match
`db_password` in `terraform/voteball.tfvars`** — Terraform sets the RDS master password from
that variable (including on a snapshot restore, which is what keeps the two in sync).

*(The old ansible-vault mechanism was removed with the k3s stack on 2026-07-20.)*

See `docs/deploy.md` for the full deploy/destroy runbook.

## Common commands

### Terraform (`terraform/` — the live stack)

```bash
cd terraform
terraform init             # use `init -upgrade` after adding a module (pulls its provider deps)
terraform validate
terraform fmt -recursive   # run before committing any .tf change
terraform plan  -var-file=voteball.tfvars
```

`terraform apply` creates real, billed AWS resources (EKS control plane, NAT, nodes, RDS, ALB ≈
$200/mo) — treat it as a confirm-before-running step, never automatic. Pins that matter: **`aws ~> 5.0`**
(the EKS module v20 caps the provider at `< 6.0`) and
**`cluster_version`** — keep it on a *standard-support* EKS release or the control plane costs 5×
(`aws eks describe-cluster-versions --region il-central-1`). Community chart/add-on versions drift fast;
verify with `helm search repo <chart> --versions` before pinning.

### Backend (`services/backend/`)

**Adding a new backend or worker source file: update that service's `Dockerfile` `COPY` line.** On EKS
the build context *is* the source directory (`scripts/build-push-ecr.sh` / the CI workflow run
`docker build` against it), so the Dockerfile's explicit `COPY` list is the only place that can drop a
file — and a file missing there is simply absent from the image (no build error for the *app* files,
just an `ImportError`/404 at runtime). Same class of gap as the frontend note below.

Tests run TDD-style against a **real** Postgres, not mocks:

```bash
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd services/backend
python -m venv .venv && source .venv/bin/activate   # or use uv if pip is unavailable
pip install -r requirements.txt
python -m pytest tests/ -v                          # full suite
python -m pytest tests/test_app.py::test_health -v   # single test
```

`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_USERNAME`,
`ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET`, etc.) via
`setdefault` and its `conn` fixture drops and recreates every table before each test (see the
`DROP TABLE ... CASCADE` list — keep it in sync with `schema.sql` when adding tables).

### Worker (`services/worker/`)

Same real-Postgres TDD pattern as the backend; reuse the `voteball-test-db` container. The worker's
tests need `schema.sql` (owned by the backend) loaded into that database, since the worker itself
never creates schema.

### Frontend (`services/frontend/`)

Plain HTML/CSS/vanilla JS, no build step, no automated test suite (matches the S3App precedent) —
verify by driving the real page in a browser (or during Task 21-style end-to-end deploy verification).

**Adding a new frontend file (JS/CSS/HTML) requires updating `services/frontend/Dockerfile`'s `COPY`
line too** — the `Dockerfile` lists every file it bakes into the image by name, not by directory. A file
that exists on disk but is missing from that `COPY` line 404s at runtime with no build error and
no obvious symptom beyond "the page is broken" (any script that calls a function the missing file
was supposed to define throws and silently kills the rest of that script's execution) — this
exact gap shipped once (i18n.js, fixed in commit `d02e255`) before being caught.

### Helm chart (`charts/voteball/`)

```bash
helm lint charts/voteball
helm template voteball charts/voteball --namespace devops-app   # renders without a live cluster
```

ArgoCD owns this release in the cluster (`argocd/voteball-application.yaml`), so **changes reach the
cluster by committing to `master`**, not by running `helm upgrade` by hand. If you do install manually,
note ArgoCD's `selfHeal` will fight you.

## Key constraints

- Region and domain come from `terraform/voteball.tfvars` (defaults: `il-central-1`, 2 AZs);
  EKS VPC `10.0.0.0/16` (public / private / isolated-DB subnets, single NAT). Kubernetes namespace **`devops-app`** (never `default`).
- Resource name prefix = `cluster_name` (default `voteball`); single environment only — no dev/prod split, no multi-instance mode
  (this is deliberately simpler than the S3App precedent it was bootstrapped from).
- **All** app containers run non-root with `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`,
  and `readOnlyRootFilesystem:true` (+ an `emptyDir` only where a write is truly needed): backend/worker
  at `uid 1000`, frontend at `uid 101` via `nginxinc/nginx-unprivileged` on **:8080** (the old
  `CHOWN`/`SETUID`/`SETGID` exception is gone — the ALB terminates TLS, so nginx needs no privileges).
- **IRSA least privilege:** only the `worker` and `backup` ServiceAccounts carry an AWS role (SNS-publish
  + S3 `snapshots/`, and S3 `backups/` respectively); `frontend`/`backend` carry **none**. Nothing gets
  `cluster-admin`.
- Postgres connections use `sslmode=require` in production (`DB_SSLMODE` env var; tests override to
  `disable`).
- Admin auth is username/password login (`POST /api/admin/login`) issuing a signed, 12-hour token
  verified via `Authorization: Bearer <token>` — single admin account, password hashed with
  `werkzeug.security`, no server-side session store (rotating `ADMIN_SESSION_SECRET` invalidates all
  outstanding tokens).

## Gitignored / generated files

Gitignored — either real secrets or machine-specific/generated output:
`terraform/voteball.tfvars`, `terraform/terraform.tfstate*`
(the `*` glob matters — Terraform writes *timestamped* backups like `terraform.tfstate.1784477786.backup`
that a bare `.backup` pattern misses), `*.tfplan`/`tfplan`, `*.pem`, `*.pdf` (course reference material),
`.remember/`, `.claude/settings.local.json`, and `EXPLAINER.md`/`PROJECT-QA.md` (personal notes).

