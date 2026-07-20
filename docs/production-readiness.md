# Production readiness

What separates this deployment from one you could responsibly run for real, ordered by what would
hurt first. Every "current state" below was verified against the repo on 2026-07-20, not assumed.

This is a **hobby project deliberately built to demo-grade**, and most items here are conscious
trade-offs rather than oversights — `docs/security.md` lists the security ones with their reasoning.
This document exists so the gap is written down rather than remembered.

---

## Already production-shaped

Worth stating, because these are the parts that are painful to retrofit and are already done:

- **Identity:** IRSA per workload, least privilege, nothing `cluster-admin`. `frontend`/`backend`
  carry no AWS role at all; `worker` and `backup` have separate roles scoped to one topic/prefix each.
- **Secrets:** AWS Secrets Manager + External Secrets Operator. No secret in git or Terraform state.
  The Jenkins build host authenticates by IAM **instance profile** — no stored AWS keys — and its role
  is scoped to ECR push only; it holds no cluster access.
- **Supply chain:** git-SHA image tags (never `latest`), ECR scan-on-push, Trivy blocking CI on
  CRITICAL/HIGH.
- **Containers:** non-root, read-only rootfs, all capabilities dropped, no privilege escalation.
- **Delivery:** GitOps via ArgoCD, fed by Jenkins; `git push` to live in a few minutes, verified end to
  end (see `docs/cicd.md`).
- **Teardown/rebuild:** verified across three full destroy→deploy cycles with data preserved.

---

## 1. Terraform state is a local file — highest risk

**Current:** no `backend` block in `terraform/`, so `terraform.tfstate` lives on one laptop.

**Why it matters:** losing that file means every AWS resource is orphaned — running, billing, and
unmanageable without importing each one by hand. It also means only one machine can ever run
Terraform, and two concurrent runs would corrupt state with no locking.

**Fix:** S3 backend with DynamoDB locking (versioning + encryption on the bucket). Bootstrap is
slightly chicken-and-egg: create the bucket/table in a small separate stack, or by hand, then
`terraform init -migrate-state`.

---

## 2. The public vote endpoint is trivially abusable

**Current:** `/api/vote` is unauthenticated. Dedup is a cookie (`HttpOnly`, `Secure`, `SameSite=Lax`,
DB-unique) plus a salted per-address cap of 5 per 24h, added 2026-07-20.

**Why it matters:** for a poll, data integrity *is* the product. The cap raises the cost of ballot
stuffing but does not stop it — anyone with a handful of addresses can still vote repeatedly. This
repo contains `scripts/seed-demo-votes.py`, which scripted 664 ballots through the public API in
about two minutes; that is the attack, written down.

**Fix:** AWS WAF on the ALB (rate-based rules, bot control), and consider proof-of-work or a CAPTCHA
on submit. Genuine one-vote-per-person needs authenticating people, which this project deliberately
does not do — so the honest goal is "expensive enough not to be worth it", not "impossible".

---

## 3. Database durability

**Current:** single-AZ, no `multi_az`, no `backup_retention_period` (so no automated backups or PITR),
no deletion protection. A final snapshot is taken on destroy, and a nightly `pg_dump` CronJob writes
to S3.

**Why it matters:** an AZ failure takes the database offline. Without PITR, the recovery granularity
is "last nightly dump or last teardown snapshot" — potentially a day of votes.

**Fix:** `multi_az = true`, `backup_retention_period = 7`, `deletion_protection = true`. Also
**test a restore** — backups that have never been restored are a hypothesis, not a backup.

---

## 4. Schema changes have no migration path

**Current:** `db.init_db()` re-runs `schema.sql` on every backend start. It is idempotent
(`CREATE TABLE IF NOT EXISTS`), and column additions work via `ALTER TABLE ... ADD COLUMN IF NOT
EXISTS` — which is how `ip_hash` reached the live database.

**Why it matters:** that pattern covers additive changes only. Anything else — renaming a column,
changing a type, backfilling data, or reversing a change — has no mechanism and no ordering
guarantees across replicas. There is also no way to know which schema version a database is at.

**Fix:** a real migration tool (Alembic) run as a Helm `pre-upgrade` hook, so migrations run exactly
once per release rather than racing across replicas. `services/backend/migrate.py` already exists as
the standalone entrypoint for that.

---

## 5. Single points of failure in the network

**Current:** `single_nat_gateway = true`; node group is `capacity_type = "SPOT"` with no On-Demand
baseline; EKS API endpoint is public (IAM-authenticated) with the CIDR allow-list defaulting to
`0.0.0.0/0`.

**Why it matters:** the single NAT is both a SPOF and an AZ-failure risk for all egress. Spot-only
means a capacity reclamation event can take every node at once — the Node Termination Handler drains
gracefully, but there is nothing to drain *to*.

**Fix:** one NAT per AZ (roughly +$35/mo each), a small On-Demand baseline with Spot on top, and
narrow `cluster_endpoint_public_access_cidrs` to your operator/CI ranges.

---

## 6. Monitoring without alerting

**Current:** kube-prometheus-stack and CloudWatch Container Insights both collect metrics. No
`PrometheusRule` alerts are defined and Alertmanager routes nowhere.

**Why it matters:** metrics you only look at after someone complains are archaeology, not monitoring.
The SNS topic for milestone alerts already exists and could carry operational alerts too.

**Fix:** alerts for the things that actually page — pods crashlooping, the worker heartbeat going
stale, RDS connections/storage, ALB 5xx rate, certificate expiry — routed to SNS or email.

---

## 7. The CI server is a single instance with no backup, and it fails silently

**Current:** Jenkins runs on one EC2 instance (`terraform/jenkins/`). Its configuration, credentials and
build history live only on that instance's EBS volume. There is no snapshot schedule, no second instance,
and the server is configured by hand through the UI rather than from a file. It also sends **no
notifications** — Jenkins emails nothing without SMTP, and this Jenkins has no public UI to show a red
banner to anyone.

**Why it matters:** two distinct problems.

- *Losing the host* means re-doing the whole first-time setup runbook by hand: plugins, global
  properties, credentials, job definition, webhook secret. The `terraform apply` part is a minute; the
  clicking is not. The volume is protected against the obvious accident
  (`delete_on_termination = false`), so this is a real but low-probability risk — accepted for now.
- *Silent failures are the worse one.* Because the pipeline auto-deploys, a failed build looks exactly
  like a successful one from the outside: the site keeps working, showing the previous version. You can
  believe a change shipped when it did not. This is **G7** in the migration design, and it is an accepted
  trade-off, not an oversight — provisioning mail credentials on a build host is its own surface.

**Fix:** **JCasC** (`jenkins.yaml` + `plugins.txt`) so the host self-configures on boot and the
configuration is reviewable in git — this is the deferred pass that also solves the backup problem, since
a rebuildable server needs no backup. Then either SMTP/SNS notifications on `post { failure }`, or a
scheduled check that the ArgoCD Application's deployed tag matches `master`. **SSM Session Manager**
access, replacing the SSH tunnel and closing port 22, is deferred alongside it.

Until then the compensating practice is explicit: **verification means opening the Jenkins UI or running
`kubectl get application voteball -n argocd`** — never inferring success from the live site still working.

---

## 8. Operational housekeeping

- **Snapshot retention.** Every teardown leaves a final snapshot; six had accumulated by the end of
  2026-07-20. Harmless at this size but unbounded. `find-latest-snapshot.sh` only ever needs the
  newest — prune the rest, keeping N.
- **`seed-demo-votes.py` now trips the rate limit.** It predates the per-address cap and stops after
  5 ballots. Either document raising `MAX_VOTES_PER_IP` temporarily, or have it seed the database
  directly rather than through the API.
- **Log retention.** CloudWatch log groups have no retention policy set, so they grow (and bill)
  forever.
- **Cost.** ~$200/month while up, dominated by the EKS control plane, NAT, ALB and RDS.

---

## Deliberately not doing

- **Authenticating voters.** It would make the poll trustworthy and also kill it — the entire premise
  is a low-friction anonymous ballot.
- **Multi-environment (dev/staging/prod).** A single environment is an explicit project constraint;
  adding environments would multiply cost and complexity for no benefit here.
- **GDPR/DPIA work.** The project owner's assessment: hobby scale, Israel-only, no personal data
  collected. Noted here so the decision is recorded rather than overlooked. (Israel's own Privacy
  Protection Law is the applicable regime if that ever changes.)

---

## Suggested order

1. **Terraform remote state** — cheap, and the only item where the failure mode is unrecoverable.
2. **WAF + rate limiting** — protects the data the project exists to collect.
3. **RDS Multi-AZ + PITR + deletion protection** — one Terraform change, real durability.
4. **Alerting** — so failures surface without someone watching.
5. **Migrations** — before the schema next needs a non-additive change.
6. **NAT/Spot redundancy** — the most expensive, and the least likely to bite at this scale.
