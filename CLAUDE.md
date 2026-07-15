# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Voteball is a public poll correlating football fandom with Israeli political-party voting, deployed
on a single-EC2 k3s cluster at `voteball.latnook.com`. It was bootstrapped from infra patterns proven
in a separate `Rolling AWS Project files` (S3App) repo but is fully independent from this initial
commit onward — no shared code, Terraform state, or Ansible roles with that repo.

**`docs/plan.md` is the master implementation plan** and the source of truth for build order, exact
file contents, and the "Global Constraints" that bind every task (region/AZ, resource naming, non-root
containers, `sslmode=require`, admin auth shape, etc.). It is written as a task-by-task spec intended
to be executed by an agentic worker via `superpowers:subagent-driven-development` or
`superpowers:executing-plans` — read it before making architectural changes, since most design
decisions (why a table/module/route looks the way it does) are explained there, not in code comments.

## Workflow

**Commit and push changes as you make them in this repo** — this is standing,
pre-authorized permission (per the user's explicit request); don't leave work
committed-but-unpushed or uncommitted waiting to be asked. Still use judgment
on grouping related changes into one coherent commit rather than pushing
every single edit separately, and never force-push.

## Architecture

Three containers on one k3s node, provisioned by a standalone Terraform stack and deployed by a
standalone Ansible playbook + Helm chart:

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
the two party tables are also admin-editable after seeding), raw votes (`votes`,
`vote_upcoming_parties`), and worker-computed rollup tables (`rollup_previous`, `rollup_upcoming`,
`rollup_previous_upcoming`) that the backend reads for fast `/api/results` responses.

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
| `/api/vote` | POST | none, cookie-deduped | sets `voteball_token` cookie (1yr); 409 on repeat vote; 400 if `upcoming_vote_status=considering` with no `upcoming_party_ids`, or if `upcoming_party_ids` has more than 3 entries (checked unconditionally, not just when `considering`) — client also validates both before submitting |
| `/api/results` | GET | none | `?by=club\|league\|id=N` or `?by=party&type=previous\|upcoming&id=N` (the latter also returns a global `crosstab` of the other party type); reads the worker-computed rollup tables |
| `/api/admin/login` | POST | none | body `{"username", "password"}`; returns `{"token"}` on success, `401` on any failure |
| `/api/admin/previous-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/previous-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/previous-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; moves every vote's `previous_party_id` from `<id>` to `target_id`, returns `{"reassigned": N}` |
| `/api/admin/upcoming-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/upcoming-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/upcoming-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/upcoming-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; reassigns every vote's `<id>` pick to `target_id` (collision-safe against the ≤3-pick cap), returns `{"reassigned": N}` |
| `/api/admin/votes` | GET | Bearer token | list all votes (no `cookie_token` in the response) |
| `/api/admin/votes/<id>` | DELETE | Bearer token | remove one vote; cascades to its `vote_upcoming_parties` rows |

Frontend pages: `index.html`/`vote.js` (voting form, posts to `/api/vote`), `results.html`/`results.js`
(dashboard, reads `/api/results`), `admin.html`/`admin.js` (unlinked from the public pages — party
CRUD, vote reassignment for merges/splits, and votes list/delete, gated by username/password login
issuing a session-stored Bearer token). All three render backend-derived names via
`createElement`/`textContent`, never `innerHTML` string interpolation — `previous_parties`/
`upcoming_parties` names come from an external API and admin input respectively, neither is safe to
trust as pre-escaped HTML.

## Deployment

Provisioning and deployment are two separate steps, run in this order:

1. **`scripts/find-latest-snapshot.sh`** checks AWS for an RDS snapshot from a prior `terraform destroy`
   and writes (or removes) `terraform/snapshot.auto.tfvars` accordingly — Terraform auto-loads
   `*.auto.tfvars`, so this needs no flag. Run this before `terraform apply` if you want vote data to
   survive a destroy/redeploy cycle (it does by default; see docs/deploy.md).
2. **Terraform** (`terraform/`) creates the AWS infra: EC2 (k3s node), RDS (Postgres, restored from the
   snapshot above if one was found), EIP, Route53 record for `voteball.latnook.com`, IAM role, SNS
   topic. Needs `terraform/voteball.tfvars` (gitignored — copy from `voteball.tfvars.example`) and
   `-var-file=voteball.tfvars` on `plan`/`apply` (it isn't named `terraform.tfvars`, so Terraform won't
   auto-load it). Before `terraform destroy`, run `terraform apply -target=module.database.aws_db_instance.main
   -var="db_final_snapshot_suffix=$(date +%Y%m%d%H%M%S)"` to refresh the final-snapshot name — passing that
   `-var` to `destroy` itself does nothing, since destroy deletes using whatever value is already in state
   from the last apply, not a value recomputed from `-var`s on the destroy call (see docs/deploy.md
   Gotchas). Skip this and repeated destroys collide on the same stale final-snapshot name.
3. **`scripts/generate-inventory.sh`** reads live Terraform outputs and writes the (gitignored,
   generated) Ansible inventory: `ansible-project/inventories/voteball/hosts` and
   `group_vars/all/main.yml`.
4. **Ansible** (`ansible-project/site-k3s.yml`) installs Docker + k3s on the node, then `helm upgrade
   --install`s the `charts/voteball` chart, which deploys the three containers as Kubernetes
   Deployments/Services in the `voteball-app` namespace.

### Secrets: ansible-vault

`ansible-project/inventories/voteball/group_vars/all/secrets.yml` (holds `db_pass`, `admin_username`,
`admin_password_hash`, `admin_session_secret`) is
encrypted with `ansible-vault` and **committed encrypted** — only the vault password itself
(`ansible-project/.vault_pass`, gitignored, never committed) is kept out of git. `ansible.cfg` points
`vault_password_file` at it, so `ansible-playbook`/`ansible-vault view|edit` work transparently once
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

### Terraform (`terraform/`)

```bash
cd terraform
terraform init
terraform validate
terraform fmt -recursive   # run before committing any .tf change
terraform plan             # requires voteball.tfvars (copy from voteball.tfvars.example)
```

`terraform apply` creates real, billed AWS resources (EC2, RDS, EIP, Route53) — treat it as a
confirm-before-running step, not something to run automatically.

### Backend (`ansible-project/roles/backend/files/backend/`)

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
helm template voteball charts/voteball --namespace voteball-app   # renders without a live cluster
```

### Ansible

```bash
cd ansible-project
ansible-playbook --syntax-check site-k3s.yml
```
Requires `.vault_pass` and a generated inventory (see Deployment) to actually run against a host.

## Key constraints (see `docs/plan.md` Global Constraints for the full list)

- Region `il-central-1`; EC2 in AZ `il-central-1c`; RDS in AZ `il-central-1b`.
- Resource name prefix `voteball`; single environment only — no dev/prod split, no multi-instance mode
  (this is deliberately simpler than the S3App precedent it was bootstrapped from).
- All backend/worker containers run as non-root, `uid 1000`; frontend nginx keeps a `CHOWN`/`SETUID`/
  `SETGID` capability exception.
- Postgres connections use `sslmode=require` in production (`DB_SSLMODE` env var; tests override to
  `disable`).
- Admin auth is username/password login (`POST /api/admin/login`) issuing a signed, 12-hour token
  verified via `Authorization: Bearer <token>` — single admin account, password hashed with
  `werkzeug.security`, no server-side session store (rotating `ADMIN_SESSION_SECRET` invalidates all
  outstanding tokens).

## Gitignored / generated files

`terraform/voteball.tfvars`, `terraform/terraform.tfstate*`, `*.pem` files, Ansible's generated
`inventories/voteball/hosts` and `group_vars/all/main.yml` (written by
`scripts/generate-inventory.sh` from live Terraform outputs), and `ansible-project/.vault_pass` are all
gitignored — either real secrets or machine-specific generated output. Note
`group_vars/all/secrets.yml` is **not** gitignored: it's committed, but ansible-vault-encrypted (see
Deployment section above).
