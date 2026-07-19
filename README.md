# Voteball

A public poll correlating **football fandom** with **Israeli political-party voting**, timed to the
run-up to the next Knesset election. Live at **https://voteball.latnook.com** (when deployed), running on
**Amazon EKS**.

## How the poll works

A visitor casts one ballot with three parts:

1. **Your teams** — pick the football club(s) you support: up to 3 specific clubs per league, across any
   number of leagues (or just "this league, no specific club").
2. **Last election** — did you vote, and for which party?
3. **Next election** — who are you considering (up to 3 parties), or undecided?

The **results dashboard** then correlates the two: which parties a club's fans lean toward, how support
splits by league, national totals, and analytics tabs (fan-base **diversity**, **political-lean**, and
**vote-switch** between the last and next election). One vote per visitor (cookie-deduped).

## How it's built

Three containers, plus managed AWS services:

- **frontend** — nginx serving a static voting form + results dashboard (plain HTML/CSS/vanilla JS, no
  build step), proxying `/api/*` to the backend.
- **backend** — Flask/gunicorn API for voting, results, and admin, backed by **RDS** Postgres.
- **worker** — recomputes results rollups on a loop and sends **SNS** milestone alerts as totals cross
  thresholds; snapshots results to **S3**.

It runs on **EKS** in a dedicated VPC: an **ALB Ingress** (HTTPS via **ACM**) fronts the app; secrets
come from **Secrets Manager** via External Secrets Operator; images live in **ECR**; delivery is **GitOps**
(ArgoCD) fed by a **GitHub Actions** pipeline (build → Trivy scan → ECR → auto-sync); monitoring is
Prometheus/Grafana + CloudWatch.

## Documentation

- **[`README.submission.md`](README.submission.md)** — the turn-in doc: architecture, run/verify/delete, security, trade-offs.
- **[`docs/deploy.md`](docs/deploy.md)** — plain-language deploy/verify/teardown guide.
- **[`docs/security.md`](docs/security.md)** — security design (IRSA, secrets, network, images, trade-offs).
- **[`docs/eks/architecture.md`](docs/eks/architecture.md)** — architecture diagram.
- **`CLAUDE.md`** — conventions and commands for anyone (human or agentic) working in this codebase.
