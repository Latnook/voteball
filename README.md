# Voteball

A public poll correlating football fandom with Israeli political-party voting,
timed to the runup to the next Knesset election. Deployed on a single-EC2 k3s
cluster at https://voteball.latnook.com.

Bootstrapped from infra patterns proven in the `Rolling AWS Project files`
(S3App) repo — see that repo's `docs/superpowers/specs/2026-07-11-voteball-design.md`
for the full design rationale. From this initial commit onward, this repo is
fully independent: no shared code, no shared Terraform state, no shared
Ansible roles.

## Architecture

Three containers on one k3s node:

- **frontend** — nginx serving a static voting form and results dashboard
  (plain HTML/CSS/vanilla JS, no build step), reverse-proxying `/api/*` to the backend.
- **backend** — Flask app exposing the voting/results/admin API, backed by Postgres (RDS).
- **worker** — periodically recomputes results rollups and sends milestone
  notifications (SNS) as vote totals cross thresholds.

Provisioned by a standalone Terraform stack (`terraform/`) and deployed with a
standalone Ansible playbook (`ansible-project/`) + Helm chart (`charts/voteball/`).

## Documentation

- `docs/plan.md` — the implementation plan this repo was built from, task by task.
- `docs/deploy.md` — deploy/destroy runbook (provisioning, secrets, teardown).
- `CLAUDE.md` — architecture notes, conventions, and commands for anyone (human or
  agentic) working in this codebase.
