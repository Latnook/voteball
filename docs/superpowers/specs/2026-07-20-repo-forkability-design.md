# Repo cleanup and forkability

**Date:** 2026-07-20
**Status:** approved, pending implementation

## Problem

The repository still carries the shape of its history rather than its current design: the app source
lives under a retired automation tool, the superseded k3s stack is still present, and the maintainer's
identity (AWS account, domain, Route53 zone) is hardcoded across scripts, chart values and CI. Someone
who forks it cannot run it.

### Fork blockers

1. **Secrets cannot be supplied.** `scripts/seed-eks-secret.sh` reads credentials from an
   `ansible-vault`-encrypted file using `ansible-project/.vault_pass`. A forker has neither, and there
   is no alternative path to populate `voteball/app-secret`.
2. **The maintainer's encrypted credentials are committed**
   (`ansible-project/inventories/voteball/group_vars/all/secrets.yml`). A fork inherits ciphertext it
   cannot decrypt and has no business holding.
3. **`charts/voteball/values.yaml` hardcodes identity** — `image.registry` (account number) and
   `ingress.host` (domain). Neither is written by `sync-values-from-tf.sh`, so both survive a rebuild
   in someone else's account and point at the wrong place.
4. **CI hardcodes the registry** — `.github/workflows/ci.yml` sets
   `REGISTRY: 590183895228.dkr.ecr.il-central-1.amazonaws.com`.
5. **A from-scratch database cannot be created.** `aws_db_instance.app` sets only
   `snapshot_identifier`; there is no `username`/`password`. Every deploy so far restored from a
   snapshot, so this never surfaced. With `db_snapshot_identifier = null` — the only option a forker
   has — RDS creation fails for lack of master credentials. **The from-zero path has never been run.**
6. **Required inputs have maintainer-specific defaults** — `app_domain` defaults to
   `voteball.latnook.com`, and the Route53 zone is looked up by a hardcoded name.

### Dead weight (~35 tracked files)

- `terraform/` — the retired k3s stack (23 files).
- Retired Ansible — `site-k3s.yml`, `ansible.cfg`, `roles/{k3s,common,app-compose}`, `inventories/`.
- `k8s/namespace.yaml` — referenced only by the retired k3s role; the Helm chart owns the namespace.
- `scripts/generate-inventory.sh` — generates an Ansible inventory nothing consumes.
- `docs/plan.md` — the superseded k3s-era plan.

### Structure

The application source sits in `ansible-project/roles/{backend,worker,frontend}/files/` — 50 files
under a tool the project no longer uses — while the backup image sits separately in `docker/backup/`.

## Non-goals

- No application behaviour changes. This is packaging, layout and configuration only.
- No multi-environment support; single environment remains a deliberate project constraint.
- The engineering history in `docs/superpowers/plans` and `specs` is kept — it is the design rationale
  CLAUDE.md points readers to.

## Design

### 1. Deletions

Remove `terraform/`, the retired Ansible tree (including the committed encrypted secrets),
`k8s/namespace.yaml`, `scripts/generate-inventory.sh`, and `docs/plan.md`. After the move in §2,
`ansible-project/` and `docker/` cease to exist.

### 2. Restructure

```
services/backend/    <- ansible-project/roles/backend/files/backend/
services/worker/     <- ansible-project/roles/worker/files/worker/
services/frontend/   <- ansible-project/roles/frontend/files/nginx/
services/backup/     <- docker/backup/
```

Each directory remains its own Docker build context, so the Dockerfiles' internal `COPY` lines are
unaffected. Consumers to update: `.github/workflows/ci.yml` (path filters + build contexts),
`scripts/build-push-ecr.sh`, `CLAUDE.md`, and the docs that cite these paths.

### 3. One configuration source

`scripts/lib/config.sh`, sourced by every script, is the single place identity is resolved:

- **Before Terraform exists** — `region`, `cluster_name`, `app_domain`, `route53_zone_name` are parsed
  from `terraform/voteball.tfvars`, falling back to the variable defaults in `variables.tf`.
  This indirection is required because `find-latest-snapshot.sh` runs *before* `terraform apply`, so
  `terraform output` is not yet available.
- **After apply** — account ID and ECR registry come from `terraform output`.

New Terraform outputs `ecr_registry` (derived from `aws_caller_identity` + region) and `app_domain`.
`sync-values-from-tf.sh` gains `image.registry` and `ingress.host` as managed fields, so
`values.yaml` contains no hardcoded identity at all.

`app_domain` and `route53_zone_name` become **required** variables (no default). `cluster_name` keeps
its `voteball` default — it is the project name, not maintainer identity.

CI reads `vars.ECR_REGISTRY` and `vars.AWS_REGION` (GitHub repo variables), documented in the README
alongside the existing `AWS_ROLE_ARN`.

### 4. Secrets without Ansible

`seed-eks-secret.sh` is rewritten to take `DB_PASS`, `ADMIN_USERNAME`, `ADMIN_PASSWORD` from
environment variables, prompting silently (`read -s`) when absent. It derives
`ADMIN_PASSWORD_HASH` via `werkzeug.security.generate_password_hash` and generates
`ADMIN_SESSION_SECRET` with `openssl rand -hex 32`, then writes the JSON to Secrets Manager. No
`ansible-vault` dependency, and no secret is ever echoed or written to disk.

### 5. Make the from-zero database path work

Add `db_username` (default `postgres`) and `db_password` (required, sensitive, no default) and set
`username`/`password` on `aws_db_instance.app`.

Setting `password` also applies when restoring from a snapshot, where it **resets** the master
password to the configured value. That is desirable: it guarantees the `DB_PASS` seeded into Secrets
Manager always matches the database, removing a standing mismatch footgun. `username` cannot change on
a restore, so it carries `ignore_changes` to avoid a spurious replacement diff.

> This is the one change that cannot be verified without an apply — `terraform validate` and a plan
> are the limit. First real proof is the next deploy.

### 6. Repo hygiene

- `README.md` gains a Quickstart: fork → set four values in `voteball.tfvars` → export three
  secrets → `./scripts/deploy.sh`.
- `terraform/voteball.tfvars.example` updated with every required variable and comments.
- Add a `LICENSE` (MIT).
- `.gitignore` gains `.remember/` and `.claude/settings.local.json` — currently untracked but one
  `git add -A` away from being committed.
- Note the benign ArgoCD CRD `resource-policy: keep` warning in `docs/deploy.md` so it does not read
  as a teardown failure.

## Verification

AWS is torn down, so acceptance is local:

1. `docker build` succeeds for all four `services/*` contexts (proves the move didn't break contexts).
2. `pytest` passes for `services/backend` and `services/worker` against a local Postgres container.
3. `helm lint` and `helm template` succeed; rendered output contains no literal `590183895228` or
   `latnook.com`.
4. `terraform fmt -check`, `terraform validate`.
5. `bash -n` on every script; `scripts/tests/test-sync-values.sh` passes with the two new fields.
6. `git grep` for the account number and domain returns hits only in `docs/` history and the tfvars
   example — never in code, chart, CI or scripts.

## Risks

- **The `services/` move breaks a path nothing tests.** Mitigated by building all four images and
  running both test suites; the CI path filters are the likeliest miss and get read line by line.
- **§5 is unproven until an apply.** Accepted and flagged above.
- **Deleting the retired Ansible tree loses k3s history.** Accepted: it remains in git history, and
  CLAUDE.md already documents the k3s deployment as retired.
