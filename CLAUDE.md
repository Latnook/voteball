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

## Architecture

Three containers on one k3s node, provisioned by a standalone Terraform stack and deployed by a
standalone Ansible playbook + Helm chart:

- **frontend** — nginx serving plain HTML/CSS/vanilla JS (no build step), reverse-proxying `/api/*` to
  the backend.
- **backend** (`ansible-project/roles/backend/files/backend/`) — Flask 3.1 app. `app.py` holds all
  routes; `queries.py` holds all SQL; `db.py` holds only connection setup (`get_db`) and one-time
  schema bootstrap (`init_db`, which loads `schema.sql` then `seed.sql` — the backend is the only
  container that ever creates schema). `knesset_sync.py` is a pure-parsing + HTTP-fetch module for
  syncing `previous_parties` from the Knesset OData API.
- **worker** (`ansible-project/roles/worker/files/worker/`) — Python batch/loop process that
  recomputes the `rollup_previous`/`rollup_upcoming` tables from `votes`/`vote_upcoming_parties`, and
  sends milestone SNS alerts.

**Each container's `files/` directory is independently copied and built — there is no shared Python
package between backend and worker.** The worker has its own near-duplicate `db.py` rather than
importing the backend's. This is a deliberate simplicity choice, not an oversight; don't "fix" it by
introducing a shared module unless the plan says to.

Postgres (RDS) stores: static seed data (`leagues`, `clubs`), synced party lists (`previous_parties`,
`upcoming_parties`), raw votes (`votes`, `vote_upcoming_parties`), and worker-computed rollup tables
(`rollup_previous`, `rollup_upcoming`) that the backend reads for fast `/api/results` responses.

### Backend request-handling pattern

Every route acquires its own `psycopg2` connection via `db.get_db()` (no pooling) and must guarantee
`conn.close()` on every exit path, including unexpected exceptions — use `try/finally`, not scattered
`conn.close()` calls in each branch (see `results()` and `vote()` in `app.py` for the established
shape). `queries.py` functions that mutate data must `conn.rollback()` in a broad `except` before
re-raising, not just catch the one expected constraint-violation error, since this is the failure mode
that leaks connections on a public endpoint (see `insert_vote`'s history in `queries.py`).

Admin endpoints (`/api/admin/...`) are protected by the `require_admin` decorator in `app.py`, which
checks the `X-Admin-Secret` header against the `ADMIN_SECRET` env var. Reuse this decorator for any
new admin route — don't hand-roll the check.

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

`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_SECRET`, etc.) via
`setdefault` and its `conn` fixture drops and recreates every table before each test (see the
`DROP TABLE ... CASCADE` list — keep it in sync with `schema.sql` when adding tables).

### Worker (`ansible-project/roles/worker/files/worker/`)

Same real-Postgres TDD pattern as the backend; reuse the `voteball-test-db` container. The worker's
tests need `schema.sql` (owned by the backend) loaded into that database, since the worker itself
never creates schema.

## Key constraints (see `docs/plan.md` Global Constraints for the full list)

- Region `il-central-1`; EC2 in AZ `il-central-1c`; RDS in AZ `il-central-1b`.
- Resource name prefix `voteball`; single environment only — no dev/prod split, no multi-instance mode
  (this is deliberately simpler than the S3App precedent it was bootstrapped from).
- All backend/worker containers run as non-root, `uid 1000`; frontend nginx keeps a `CHOWN`/`SETUID`/
  `SETGID` capability exception.
- Postgres connections use `sslmode=require` in production (`DB_SSLMODE` env var; tests override to
  `disable`).
- Admin auth is a static shared secret in the `X-Admin-Secret` header vs. `ADMIN_SECRET` env var — not
  per-user auth.

## Gitignored / generated files

`terraform/voteball.tfvars`, `terraform/terraform.tfstate*`, Ansible's generated
`inventories/voteball/hosts` and `group_vars/all/{main,secrets}.yml`, and `*.pem` files are all
gitignored — they're either real secrets or machine-specific generated output
(`scripts/generate-inventory.sh` produces the Ansible inventory from live Terraform outputs).
