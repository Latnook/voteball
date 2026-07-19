# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Voteball is a public poll correlating football fandom with Israeli political-party voting, deployed on
**Amazon EKS** at `voteball.latnook.com`. It was bootstrapped from infra patterns proven in a separate
`Rolling AWS Project files` (S3App) repo but is fully independent — no shared code or state.

> **The single-node k3s deployment is RETIRED.** `terraform/` (k3s stack) and `ansible-project/`'s
> playbook/roles remain in the repo for history, but the live deployment is the EKS stack in
> `terraform-eks/` + `charts/voteball/`. The app *source* still lives under
> `ansible-project/roles/{backend,worker,frontend}/files/` (that's just where the Dockerfiles/code sit;
> Ansible itself is no longer used to deploy).

**Plans live in `docs/superpowers/plans/`** — the EKS migration was built as a sequence of task-by-task
specs (app-code foundation → EKS infra → add-ons → app deploy → expose/harden → GitOps/observability →
docs). `docs/plan.md` is the *original k3s-era* plan and is now historical. Read the relevant plan
before making architectural changes: most design decisions (and the bugs they avoid) are explained
there, not in code comments.

Submission/reference docs: `README.submission.md`, `docs/security.md`, `docs/eks/architecture.md`,
`docs/deploy.md` (plain-language runbook), `docs/eks/live-cluster-snapshot.md`.

## Workflow

**Commit and push changes as you make them in this repo** — this is standing,
pre-authorized permission (per the user's explicit request); don't leave work
committed-but-unpushed or uncommitted waiting to be asked. Still use judgment
on grouping related changes into one coherent commit rather than pushing
every single edit separately, and never force-push.

## Architecture

Three containers in the `devops-app` namespace on EKS, provisioned by the `terraform-eks/` stack and
delivered by the `charts/voteball` Helm chart (synced by ArgoCD):

- **frontend** — nginx serving plain HTML/CSS/vanilla JS (no build step), reverse-proxying `/api/*` to
  the backend.
- **backend** (`ansible-project/roles/backend/files/backend/`) — Flask 3.1 app. `app.py` holds all
  routes; `queries.py` holds all SQL; `db.py` holds only connection setup (`get_db`) and one-time
  schema bootstrap (`init_db`, which loads `schema.sql` then `seed.sql` — the backend is the only
  container that ever creates schema).
- **worker** (`ansible-project/roles/worker/files/worker/`) — Python batch/loop process that
  recomputes the `rollup_previous`/`rollup_upcoming`/`rollup_previous_upcoming` tables from
  `votes`/`vote_upcoming_parties`, and sends milestone SNS alerts.

**Each container's `files/` directory is independently copied and built — there is no shared Python
package between backend and worker.** The worker has its own near-duplicate `db.py` rather than
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

- **Terraform (`terraform-eks/`)** builds everything AWS: dedicated VPC, EKS cluster + Spot node group,
  OIDC/IRSA roles, ECR, ACM, S3, SNS, Secrets Manager (container only), RDS (restored from a pinned
  snapshot), **and every platform add-on** via `helm_release`/`aws_eks_addon` (AWS Load Balancer
  Controller, External Secrets Operator, Cluster Autoscaler, Node Termination Handler, CloudWatch
  Container Insights, metrics-server, external-dns, ArgoCD, kube-prometheus-stack). Needs
  `terraform-eks/voteball-eks.tfvars` (gitignored) and `-var-file=voteball-eks.tfvars`.
- **Helm (`charts/voteball`)** is the app itself (namespace `devops-app`): 3 Deployments, Services,
  Ingress→ALB, ConfigMap, ExternalSecret, 4 ServiceAccounts, NetworkPolicies, HPA, PDBs, backup CronJob.
  **ArgoCD** syncs it from `master` (GitOps) — the chart is the single authoring path.
- **Two manual ops:** `./scripts/seed-eks-secret.sh` (copies app passwords into Secrets Manager; nothing
  secret ever enters git or tfstate) and pinning `image.tag` + `config.DB_HOST` in `values.yaml`.
- **CI/CD:** pushing app code to `master` runs `.github/workflows/ci.yml` (OIDC → build → Trivy → ECR →
  bump `image.tag` `[skip ci]` → ArgoCD auto-syncs). `./scripts/build-push-ecr.sh` does it by hand.

**Teardown order matters:** delete the ArgoCD Application, then the Ingress (so the ALB de-provisions —
a leftover ALB's ENIs block VPC deletion), *then* `terraform destroy`. If destroy hangs uninstalling a
`helm_release` ("context deadline exceeded" — Helm can't cleanly uninstall while the cluster is being
deleted), `terraform state rm` that release and re-run destroy; it dies with the cluster anyway.

### Reverse-seeding: keeping seed.sql in sync with admin-UI edits

Admin-curated data (party/club/league logo URLs, renames, etc.) lives only in the live RDS instance
until someone backfills it into `seed.sql` — a fresh install or `terraform destroy`+restore-from-
empty-DB would otherwise miss it. **`scripts/sync-seed-from-rds.sh`** automates this: it opens an SSH
tunnel through the EC2 node to RDS (private subnet, not directly reachable), diffs the live data
against what the current working tree's `schema.sql`/`seed.sql` would produce in a fresh
`voteball-test-db` container, and reports every difference in three categories — safe NULL-backfills
(a field the admin set that `seed.sql` still has as NULL; pass `--apply` to write these in), value
conflicts (both sides set but different — e.g. a rename; always needs a human fix, since a guarded
`WHERE col IS NULL` statement can't touch an already-populated field), and rows that exist on only one
side (added or deleted on purpose — also always needs a human call). Needs the same `.vault_pass`,
`Voteball-EC2-pem.pem`, and Terraform state as the rest of this section, plus a running
`voteball-test-db` container (see the Backend common-commands section below).

### Secrets

**On EKS, secrets live in AWS Secrets Manager** (`voteball/app-secret`) and are synced into the
`app-secret` Kubernetes Secret by External Secrets Operator via IRSA. Terraform creates only the empty
container (`ignore_changes = [secret_string]`), so **no secret value ever enters git or tfstate**. Seed
real values with `./scripts/seed-eks-secret.sh`. See `docs/security.md`.

The ansible-vault file below is the **retired k3s** mechanism — still the origin of the credential
values (the seed script reads it), so keep `.vault_pass` around, but it is no longer in the deploy path.

`ansible-project/inventories/voteball/group_vars/all/secrets.yml` (holds `db_pass`, `admin_username`,
`admin_password_hash`, `admin_session_secret`) is
encrypted with `ansible-vault` and **committed encrypted** — only the vault password itself
(`ansible-project/.vault_pass`, gitignored, never committed) is kept out of git. `ansible.cfg` points
`vault_password_file` at it, so `ansible-vault view|edit` works transparently once
that file exists locally. To bootstrap a fresh checkout:

```bash
cd ansible-project
openssl rand -hex 32 > .vault_pass
ansible-vault edit inventories/voteball/group_vars/all/secrets.yml --vault-password-file .vault_pass
```

`db_pass` must match whatever `db_password` is set to in `terraform/voteball.tfvars` (Terraform is the
source of truth for the RDS master password; Ansible only ever reads it, never sets it independently).

See `docs/deploy.md` for the full deploy/destroy runbook.

## Common commands

### Terraform (`terraform-eks/` — the live stack)

```bash
cd terraform-eks
terraform init             # use `init -upgrade` after adding a module (pulls its provider deps)
terraform validate
terraform fmt -recursive   # run before committing any .tf change
terraform plan  -var-file=voteball-eks.tfvars
```

`terraform apply` creates real, billed AWS resources (EKS control plane, NAT, nodes, RDS, ALB ≈
$200/mo) — treat it as a confirm-before-running step, never automatic. Pins that matter: **`aws ~> 5.0`**
(the EKS module v20 caps the provider at `< 6.0`, unlike the k3s stack's `~> 6.0`) and
**`cluster_version`** — keep it on a *standard-support* EKS release or the control plane costs 5×
(`aws eks describe-cluster-versions --region il-central-1`). Community chart/add-on versions drift fast;
verify with `helm search repo <chart> --versions` before pinning.

`terraform/` is the retired k3s stack — left for history, not deployed.

### Backend (`ansible-project/roles/backend/files/backend/`)

**Adding a new backend or worker source file requires updating TWO lists, not one:** the
service's `Dockerfile` `COPY` line **and** the explicit per-file `loop:` in
`ansible-project/roles/k3s/tasks/main.yml` ("Copy backend build context" / "Copy worker build
context"). The k3s role deliberately ships an explicit file list (not a directory copy, to avoid
dragging local `.venv`/`__pycache__` into the build context), so a file the Dockerfile references
but Ansible didn't copy is **absent on the node** and `docker build` fails there with
`"/<file>": not found` — even though a local `docker build` succeeds (every file is present
locally). This is the backend/worker analogue of the frontend Dockerfile-`COPY` gap noted below;
it shipped once (`migrate.py`, fixed in `4c56d04`).

Tests run TDD-style against a **real** Postgres, not mocks:

```bash
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd ansible-project/roles/backend/files/backend
python -m venv .venv && source .venv/bin/activate   # or use uv if pip is unavailable
pip install -r requirements.txt
python -m pytest tests/ -v                          # full suite
python -m pytest tests/test_app.py::test_health -v   # single test
```

`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_USERNAME`,
`ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET`, etc.) via
`setdefault` and its `conn` fixture drops and recreates every table before each test (see the
`DROP TABLE ... CASCADE` list — keep it in sync with `schema.sql` when adding tables).

### Worker (`ansible-project/roles/worker/files/worker/`)

Same real-Postgres TDD pattern as the backend; reuse the `voteball-test-db` container. The worker's
tests need `schema.sql` (owned by the backend) loaded into that database, since the worker itself
never creates schema.

### Frontend (`ansible-project/roles/frontend/files/nginx/`)

Plain HTML/CSS/vanilla JS, no build step, no automated test suite (matches the S3App precedent) —
verify by driving the real page in a browser (or during Task 21-style end-to-end deploy verification).

**Adding a new frontend file (JS/CSS/HTML) requires updating `files/nginx/Dockerfile`'s `COPY`
line too** — Ansible ships the whole `files/nginx/` directory to the node as-is, but the
`Dockerfile` itself lists every file it bakes into the image by name, not by directory. A file
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

### Ansible (retired)

Only used to *deploy* the old k3s stack; not part of the EKS path. The app source under
`ansible-project/roles/*/files/` is still live — that's just where the code and Dockerfiles live.

## Key constraints (see `docs/plan.md` Global Constraints for the full list)

- Region `il-central-1`; EKS VPC `10.0.0.0/16` across AZs `il-central-1a`/`1b` (public / private /
  isolated-DB subnets, single NAT). Kubernetes namespace **`devops-app`** (never `default`).
- Resource name prefix `voteball`; single environment only — no dev/prod split, no multi-instance mode
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
`terraform-eks/voteball-eks.tfvars`, `terraform-eks/terraform.tfstate*` and `terraform/terraform.tfstate*`
(the `*` glob matters — Terraform writes *timestamped* backups like `terraform.tfstate.1784477786.backup`
that a bare `.backup` pattern misses), `*.tfplan`/`tfplan`, `*.pem`, `*.pdf` (course reference material),
`ansible-project/.vault_pass`, the generated Ansible inventory, and `EXPLAINER.md` (personal
presentation notes, not part of the submission).

Note `group_vars/all/secrets.yml` is **not** gitignored: it's committed, but ansible-vault-encrypted
(see Secrets above).
