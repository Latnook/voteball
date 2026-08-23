# Production readiness

What separates this deployment from one you could responsibly run for real, ordered by what would
hurt first. Every "current state" below was verified against the repo, not assumed — originally on
2026-07-20, re-checked 2026-07-26 and 2026-07-29, and again on 2026-07-31 (§3's restore evidence and
§8's snapshot count come from the 2026-07-27 teardown/rebuild cycle).

This is a **hobby project deliberately built to demo-grade**, and most items here are conscious
trade-offs rather than oversights — `docs/security.md` lists the security ones with their reasoning.
This document exists so the gap is written down rather than remembered.

---

## Already production-shaped

Worth stating, because these are the parts that are painful to retrofit and are already done:

- **Identity:** IRSA per workload, least privilege, nothing `cluster-admin`. `frontend`/`backend`
  carry no AWS role at all; `worker` and `backup` have separate roles scoped to one topic/prefix each.
- **Secrets:** AWS Secrets Manager + External Secrets Operator. No secret in git or Terraform state.
  Jenkins (in-cluster since 2026-07-31, namespace `ci`) authenticates its agent pods by **IRSA** — no
  stored AWS keys — scoped to ECR push only; the controller itself holds no AWS role and no cluster
  access beyond managing its own agent pods.
- **Supply chain:** git-SHA image tags (never `latest`), ECR scan-on-push, Trivy blocking CI on
  CRITICAL/HIGH.
- **Containers:** non-root, read-only rootfs, all capabilities dropped, no privilege escalation — with
  one documented, narrowly-scoped exception for the CI `buildkit` container; see `docs/security.md`.
- **Delivery:** GitOps via ArgoCD, fed by an in-cluster Jenkins; `git push` to live in a few minutes,
  verified end to end (see `docs/cicd.md`).
- **Self-healing:** startup, readiness and liveness probes on all three Deployments (added
  2026-08-06; before that, liveness and readiness only). Sized per workload rather than copied — the
  backend gets the longest startup budget because gunicorn runs the schema bootstrap before it binds
  its port, and liveness on frontend/backend is a deliberately weaker `tcpSocket` check so an RDS
  outage cannot restart healthy pods. A failed rollout stalls on the old pods instead of taking the
  site down (`maxUnavailable` rounds to 0 at 2 replicas). See `docs/eks/architecture.md` §2.
  **The remaining gap is detection latency on the worker**, not the probes themselves: it runs a
  single replica, its heartbeat check tolerates 120s of staleness before it can start failing, and
  `DeploymentReplicasMismatch` then waits 15m — so a wedged worker is ~17 minutes from paging. Votes
  are still recorded throughout (the backend writes `votes` directly); only rollup freshness lags.
- **Teardown/rebuild:** verified across three full destroy→deploy cycles with data preserved.

---

## 1. Terraform state is a local file — ~~highest risk~~ RESOLVED 2026-07-21

**Resolved.** Both stacks now use an S3 backend with versioning, encryption and S3-native locking;
the Jenkins stack's 14 live resources were migrated and verified. See
`docs/design/2026-07-21-terraform-remote-state-design.md`. The original text is kept below because
the reasoning still explains why the bucket is protected the way it is.

> **Correction to what this section assumed:** it named only `terraform/`. At the time of the fix
> that was the *less* exposed of the two stacks then in play — the cluster was destroyed, so its state
> described nothing. The Jenkins EC2 stack's own local state file was the one that actually held live
> resources, and this section did not mention it. Remote state covered both stacks while they were
> separate; since 2026-07-31 there is only the one stack and one state file (see the update below).

**Current (before the fix):** no `backend` block in `terraform/`, so `terraform.tfstate` lives on one
laptop.

**Why it matters:** losing that file means every AWS resource is orphaned — running, billing, and
unmanageable without importing each one by hand. It also means only one machine can ever run
Terraform, and two concurrent runs would corrupt state with no locking.

**Fix:** S3 backend with DynamoDB locking (versioning + encryption on the bucket). Bootstrap is
slightly chicken-and-egg: create the bucket/table in a small separate stack, or by hand, then
`terraform init -migrate-state`.

**What was actually built:** the same, minus DynamoDB — Terraform 1.11 deprecated `dynamodb_table`
in favour of S3-native `use_lockfile`, so there is no lock table. Bootstrap is
`scripts/bootstrap-tf-backend.sh` (idempotent, no state of its own). The bucket
(`<cluster_name>-tfstate-<account_id>`) **belongs to no stack and must never be added to
`scripts/destroy.sh`** — deleting it mid-teardown would delete the record of what is being deleted.

> **Update 2026-07-31:** the separate `voteball/jenkins.tfstate` key this section originally referred
> to no longer exists. Jenkins moved into the main stack (namespace `ci`) and is destroyed and rebuilt
> with everything else — there is now only one key, `voteball/main.tfstate`, in this same bucket.

---

## 2. The public vote endpoint is trivially abusable — mitigated 2026-07-21

**Current:** `/api/vote` is unauthenticated. Dedup is a cookie (`HttpOnly`, `Secure`, `SameSite=Lax`,
DB-unique) plus a salted per-address cap of 5 per 24h, added 2026-07-20.

**Why it matters:** for a poll, data integrity *is* the product. The cap raises the cost of ballot
stuffing but does not stop it — anyone with a handful of addresses can still vote repeatedly. This
repo contains `scripts/seed-demo-votes.py`, which scripted 664 ballots through the public API in
about two minutes; that is the attack, written down.

**Fix:** AWS WAF on the ALB (rate-based rules, bot control), and consider proof-of-work or a CAPTCHA
on submit. Genuine one-vote-per-person needs authenticating people, which this project deliberately
does not do — so the honest goal is "expensive enough not to be worth it", not "impossible".

**Done 2026-07-21** (`terraform/waf.tf`, ~$10/mo): 100 requests/5min/IP blocked on `/api/vote`, a
looser site-wide ceiling, AWS KnownBadInputs blocking, and the AWS Common Rule Set in **COUNT** mode.
Counting rather than blocking that last group is deliberate — it can trip on a large ballot POST, and
a false positive silently discards a real vote. Promote it to blocking after reading its CloudWatch
metric against real traffic. The ACL attaches via an Ingress annotation, not a Terraform association:
the ALB is created by the load balancer controller and does not exist at apply time.

**Verified live on 2026-07-21:** the ACL is attached to the running ALB, a 300-request burst against
`/api/vote` returned `403` for every request, and from that same blocked address the homepage,
`/api/options` and `/api/results` all still returned `200` — the block is scoped to the endpoint, not
the site. The Common Rule Set counted a match on ordinary traffic within hours, which is the argument
for shipping it in count mode.

---

## 3. Database durability — PITR added 2026-07-21

**Current:** single-AZ, no `multi_az`, no `backup_retention_period` (so no automated backups or PITR),
no deletion protection. A final snapshot is taken on destroy, and a nightly `pg_dump` CronJob writes
to S3.

**Why it matters:** an AZ failure takes the database offline. Without PITR, the recovery granularity
is "last nightly dump or last teardown snapshot" — potentially a day of votes.

**Fix:** `multi_az = true`, `backup_retention_period = 7`, `deletion_protection = true`. Also
**test a restore** — backups that have never been restored are a hypothesis, not a backup.

**Done 2026-07-21: PITR.** `backup_retention_period = 7`, windows placed clear of the 02:00 pg_dump
CronJob. Confirmed on the running instance (`BackupRetentionPeriod: 7`). Recovery granularity is now any
second in the last week rather than "the last nightly dump".

**Deliberately NOT done: `deletion_protection`.** It is free and correct for a server that stays up, and
wrong here — it makes `terraform destroy` fail outright and would wedge `scripts/destroy.sh` on every
rebuild cycle. Turn it on only alongside retiring the destroy/rebuild workflow. The reasoning is in
`database.tf` next to the setting.

**Multi-AZ remains open** — a deliberate cost decision (~+$12/mo), not an oversight.

**The restore path is well tested**, if not by the mechanism this section imagined: every rebuild cycle
restores from the previous teardown's final snapshot, and the 2026-07-21 rebuild brought the votes and
seed data back intact. **Re-verified with counted evidence on 2026-07-27** — 5 votes recorded before
teardown (party 10 with two votes; parties 5, 4 and 14 with one each), then re-queried on the rebuilt
cluster and found byte-identical. Captured in `docs/eks/live-cluster-snapshot.md`, with the raw
before/after API responses in `docs/eks/evidence/`. That closes the
"backups that have never been restored are a hypothesis" item above with a number rather than a claim.

### ⚠️ The nightly `pg_dump` is NOT teardown insurance

The line above lists the S3 `pg_dump` alongside the final snapshot as if both protect the data. They
do not protect against the same thing. `terraform/s3.tf:9` sets `force_destroy = true`, so
`terraform destroy` deletes the rollups bucket **and every backup object in it** — in the same
operation the dump would supposedly be insuring against. Verified on the 2026-07-27 teardown:
`head-bucket` returned 404 and the `backups/` prefix went from 5 objects to 0.

What each layer actually covers:

| Layer | Protects against | Survives `destroy.sh`? |
|---|---|---|
| Final snapshot (`skip_final_snapshot = false`) | planned teardown | **yes** |
| Automated backups / PITR (`delete_automated_backups = false`) | teardown **and** unplanned loss; stays in `retained` state after the instance is deleted | **yes** |
| Nightly `pg_dump` → S3 | application-level loss while the stack is up (bad migration, errant DELETE) | **no** |

Verify the final snapshot by **`SnapshotCreateTime`, never by its identifier** — the name embeds
`time_static.deploy`, so a snapshot taken today is named after the day the stack was *deployed*. On
2026-07-27 the fresh snapshot was called `voteball-eks-db-final-20260722065933`; reading the name
alone would suggest the final snapshot had failed and the newest was five days old.

Making the dumps genuine off-stack insurance means moving the bucket out of the stack it insures —
the same argument that keeps the tfstate bucket out of `scripts/destroy.sh`.

---

## 4. Schema changes have no migration path — half done 2026-07-21

**Current:** `db.init_db()` re-runs `schema.sql` on every backend start. It is idempotent
(`CREATE TABLE IF NOT EXISTS`), and column additions work via `ALTER TABLE ... ADD COLUMN IF NOT
EXISTS` — which is how `ip_hash` reached the live database.

**Why it matters:** that pattern covers additive changes only. Anything else — renaming a column,
changing a type, backfilling data, or reversing a change — has no mechanism and no ordering
guarantees across replicas. There is also no way to know which schema version a database is at.

**Fix:** a real migration tool (Alembic) run as a Helm `pre-upgrade` hook, so migrations run exactly
once per release rather than racing across replicas. `services/backend/migrate.py` already exists as
the standalone entrypoint for that.

**Half done 2026-07-21.** The *exactly-once* half is in:
`charts/voteball/templates/migrate-job.yaml` is a **`post-install,pre-upgrade`** hook Job running
`python migrate.py`, so schema work happens once per release, before the Deployments roll, instead of
every replica racing on startup. ArgoCD maps Helm hooks onto its PreSync phase, so it works under GitOps.

The `post-install` half is not a typo: as a `pre-install` hook it failed outright with
`serviceaccount "backend" not found`, because pre-install hooks run before every normal chart resource.
A fresh install has nothing to order anyway; an upgrade does, and by then the dependencies exist.
Verified on a real upgrade: `job/voteball-migrate  Job completed` before the pods rolled.

**Still missing: Alembic itself** — versioning, ordering and down-steps. This Job is what will run
it. Two things make that its own piece of work rather than an afterthought: an existing database has
to be baselined (`alembic stamp`) so the first migration does not try to recreate live tables, and
`gunicorn.conf.py`'s `on_starting` hook must stop calling `init_db` at the same moment, or replicas
will still race the migrator. Until then the Job runs the same idempotent bootstrap as before, so it
buys ordering, not versioning.

---

## 5. Single points of failure in the network

**Current:** `single_nat_gateway = true`; node group is `capacity_type = "SPOT"` with no On-Demand
baseline. The EKS API endpoint is public (IAM-authenticated) but **no longer defaults to
`0.0.0.0/0`** — `cluster_endpoint_public_access_cidrs` lost its default on 2026-08-23 and Terraform
now refuses to plan until `voteball.tfvars` names a CIDR (`./scripts/refresh-api-cidr.sh` writes the
current one).

**Why it matters:** the single NAT is both a SPOF and an AZ-failure risk for all egress. Spot-only
means a capacity reclamation event can take every node at once — the Node Termination Handler drains
gracefully, but there is nothing to drain *to*.

**Fix:** one NAT per AZ (roughly +$35/mo each) and a small On-Demand baseline with Spot on top. The
API allow-list is already narrowed; the residual gap there is that it is pinned to a *home* address,
so the honest production answer is a private-only endpoint reached through an approved administration
path rather than a /32 that changes whenever an ISP feels like it.

---

## 6. Monitoring without alerting — ~~gap~~ RESOLVED 2026-07-21

**Current (before the fix):** kube-prometheus-stack and CloudWatch Container Insights both collect
metrics. No `PrometheusRule` alerts are defined and Alertmanager routes nowhere.

**Why it matters:** metrics you only look at after someone complains are archaeology, not monitoring.
The SNS topic for milestone alerts already exists and could carry operational alerts too.

**Fix:** alerts for the things that actually page — pods crashlooping, the worker heartbeat going
stale, RDS connections/storage, ALB 5xx rate, certificate expiry — routed to SNS or email.

**Done 2026-07-21.** Alertmanager publishes to the existing SNS topic via IRSA (`sns:Publish` on that
one topic, nothing else) — native `sns_configs`, so no SMTP credentials on the build cluster. Seven
rules ship in the app chart (`charts/voteball/templates/prometheusrule.yaml`), so a threshold changes
with a commit rather than a Terraform apply: crashlooping, degraded/zero-replica Deployments, failed
migration and backup Jobs, **absent** backups (48h without a success — a suspended CronJob emits no
failure at all), and restart storms.

**⚠️ Every rebuild requires confirming the SNS email subscription again.** `destroy.sh` deletes the
topic; the next apply recreates it with a **`PendingConfirmation`** subscription, and AWS does not
deliver to an unconfirmed endpoint. Alerting then silently publishes into the void — invisible,
because it only matters when something else is already wrong. Verified on the 2026-07-21 rebuild:
`NumberOfMessagesPublished: 2`, `NumberOfNotificationsDelivered: 0`. Check the inbox after every
deploy, or verify with:

```bash
aws sns list-subscriptions-by-topic --topic-arn "$(terraform -chdir=terraform output -raw sns_topic_arn)" \
  --region <region> --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output text
# SubscriptionArn == "PendingConfirmation" means no alert will ever arrive.
```

**A second limitation, stated rather than hidden:** `VoteballBackupMissing` alerts on a backup that
*stopped*, not one that never started. It compares against `max(kube_job_status_completion_time...)`,
and on a cluster with no successful backup that series does not exist, so the expression returns
nothing and cannot fire.

> **This stopped being hypothetical on 2026-07-31.** The nightly `pg_dump` had been failing its S3
> upload since 2026-07-19 — twelve days — because the CronJob's pods were labelled
> `app: voteball-backup` while the `allow-app-egress` NetworkPolicy allowed only `app: backup`
> (fixed in `1bda7b5`). Every rebuild in that window started from zero successful backups, so the
> series the alert compares against never existed and **no alert ever fired**. `BackupJobFailed`
> did not cover it either: the job's own `set -e` did not trip, because a failed `pg_dump` piped
> into `gzip` still produced a valid empty archive and the pipeline exited 0 (fixed in `d44aa53`,
> which adds `pipefail` and checks for `pg_dump`'s completion trailer). Two independent alert rules,
> a twelve-day outage, and silence from both — the argument for checking that a signal *can* fire,
> not just that a rule exists.

**Deliberately NOT written: RDS connections/storage, ALB 5xx and certificate expiry.** Those are
CloudWatch metrics and nothing scrapes CloudWatch into Prometheus here, so those rules could never
fire — worse than no alert, because the coverage would look complete. They need a CloudWatch exporter
first. The `Watchdog` heartbeat is routed to a null receiver; delivered to a mailbox it is pure noise.

---

## 7. The CI server is a single instance with no backup, and it fails silently — mostly RESOLVED 2026-07-21

**Current (as of 2026-07-21):** Jenkins ran on one EC2 instance, its own separate Terraform stack. Its configuration, credentials and
build history live only on that instance's EBS volume. There is no snapshot schedule, no second instance,
and the server is configured by hand through the UI rather than from a file. It also sends **no
notifications** — Jenkins emails nothing without SMTP, and this Jenkins has no public UI to show a red
banner to anyone.

**Why it matters:** two distinct problems.

- *Losing the host* means re-doing the whole first-time setup runbook by hand: plugins, global
  properties, credentials, job definition, webhook secret. The `terraform apply` part is a minute; the
  clicking is not. The volume is protected against the obvious accident
  (`delete_on_termination = false`), so this is a real but low-probability risk — accepted for now.
  **Revised 2026-07-21: it is not low-probability.** A plan run during the state migration showed
  `aws_instance.jenkins` *must be replaced*, because `data.aws_ssm_parameter.al2023` resolves to
  whatever the newest Amazon Linux 2023 image is and `ami` forces replacement. Nothing was applied,
  and the state was accurate — the live host still runs the recorded `ami-05471ba2d056f72c5` — but
  **`terraform apply` on that separate stack would today destroy and rebuild the CI server**, on
  Amazon's release schedule rather than yours. The preserved volume does not save you: the
  replacement instance does not attach it. This makes the JCasC pass below the fix, not a nicety;
  pinning the AMI is the narrower stopgap.
- *Silent failures are the worse one.* Because the pipeline auto-deploys, a failed build looks exactly
  like a successful one from the outside: the site keeps working, showing the previous version. You can
  believe a change shipped when it did not. This is **G7** in the migration design, and it is an accepted
  trade-off, not an oversight — provisioning mail credentials on a build host is its own surface.

**Fix:** **JCasC** (`jenkins.yaml` + `plugins.txt`) so the host self-configures on boot and the
configuration is reviewable in git — this is the deferred pass that also solves the backup problem, since
a rebuildable server needs no backup. Then either SMTP/SNS notifications on `post { failure }`, or a
scheduled check that the ArgoCD Application's deployed tag matches `master`. **SSM Session Manager**
access, replacing the SSH tunnel and closing port 22, is deferred alongside it.

**Status 2026-07-21 — JCasC done, and the AMI foot-gun above is disarmed.** Configuration now lives in
that stack's own JCasC config file, applied at every start; credentials come from Secrets Manager
(`voteball/jenkins`) via a single-ARN, read-only IAM grant. The deploy key — whose only copy was inside
Jenkins' own credential store, recoverable from nowhere — was extracted and is now stored outside the
host, verified byte-for-byte including the trailing newline that OpenSSH requires.

Three things remain open, and the first is the one that matters:

- ~~**The rebuild path is unverified.**~~ **Verified 2026-07-21** by booting a throwaway instance
  from this configuration. It found a real security hole first: the fresh host enforced **no webhook
  signature at all** (unsigned deliveries accepted with 200), because the hook secret is read from
  `github-plugin-configuration.xml` and the bootstrap wrote only
  `org.jenkinsci.plugins.github.config.GitHubPluginConfig.xml`. It passed on the already-configured
  host because that host had the right value from its original UI setup — a test that passed for a
  reason present nowhere in the shipped config. Fixed, then re-verified on a clean instance
  (signed/unsigned/bad-signature → 200/400/400) and re-applied to the real host.
- **The plugin set is trimmed on a rebuild, not in place.** `plugins.txt` yields **70** plugins on a
  fresh host (8 top-level + dependencies); the running host still carries the 95 the setup wizard
  installed, because nothing removes what is already there. Both sets are now tested.
- **Notifications (G7) are still absent**, and **SSM Session Manager** is still deferred.

Until then the compensating practice is explicit: **verification means opening the Jenkins UI or running
`kubectl get application voteball -n argocd`** — never inferring success from the live site still working.

**Status 2026-07-31 — the single-instance premise of this whole section is gone.** Jenkins moved from
its dedicated EC2 host into the cluster itself (namespace `ci`, `terraform/addon-jenkins.tf`), and that
closes the *first* problem this section identified outright rather than mitigating it further:

- **"Losing the host" is no longer a scenario.** There is no host — Jenkins is pods on the same Spot
  node group as everything else, and it is torn down and rebuilt with the rest of the stack by the same
  `terraform apply`/`destroy`. Its configuration lives in git as JCasC and nothing depends on one
  instance's EBS volume any more. **Its credentials are the one thing that does not survive a
  teardown**, and that is a new operational cost rather than a leftover of the old design:
  `voteball/jenkins` carries `recovery_window_in_days = 0`, so `terraform destroy` hard-deletes it and
  the next deploy mints a fresh deploy key and webhook secret that must both be re-registered on GitHub
  (`docs/cicd.md`, first-time setup steps 1 and 4). Until they are, CI is unreachable and unable to
  push, on a cluster that reports itself healthy.
- **The rebuild path is no longer a special case that needs separate verification.** Every
  `terraform apply` *is* a rebuild of the controller from JCasC — it is not a rare disaster-recovery
  path exercised once and hoped to still work later.
- **The plugin-set-drifts-on-a-running-host problem (item two above) cannot recur.** Plugins are baked
  into the controller image at build time (`ci/jenkins/Dockerfile`); there is no long-lived host for a
  plugin set to diverge on.
- **Two items remain open, unchanged by the move:** notifications (G7) are still absent, and SSM
  Session Manager is now moot rather than solved — there is no SSH access to anything Jenkins runs on
  to begin with.

See [`docs/design/2026-07-30-jenkins-on-eks-design.md`](design/2026-07-30-jenkins-on-eks-design.md) for
the full design and its "Verification outcome" section for what the move itself broke in practice.

---

## 8. Operational housekeeping

- **Snapshot retention.** Every teardown leaves a final snapshot; **nine** had accumulated by
  2026-07-29 (six of them by the end of 2026-07-20). Harmless at this size but unbounded.
  `find-latest-snapshot.sh` only ever needs the newest — prune the rest, keeping N, and sort by
  `SnapshotCreateTime` rather than by name (see §3).
- **`seed-demo-votes.py` now trips the rate limit.** It predates the per-address cap and stops after
  5 ballots. Either document raising `MAX_VOTES_PER_IP` temporarily, or have it seed the database
  directly rather than through the API.
- **Log retention.** CloudWatch log groups have no retention policy set, so they grow (and bill)
  forever.
- **Cost.** **$8.52 per full 24h with everything up** — measured from Cost Explorer on 2026-08-18 for
  2026-08-07, which is verifiable as a complete 24h because that day's EKS control-plane charge was
  exactly $2.40 and that item bills a flat $0.10/hour. Run continuously that is **≈$256/month**.
  Per day: EKS control plane $2.40 (28%), EC2-Other $1.82 (21%, mostly NAT gateway + EBS), Spot nodes
  $1.59 (19%), CloudWatch $0.78 (9%), ALB $0.64 (8%), RDS $0.58 (7%), VPC $0.36, WAF $0.29,
  KMS + Secrets Manager $0.06.

  **What actually billed: $285.07 in July 2026** — lower than 30 × $8.52 because the cluster was only
  up ~63% of the month (467 EKS-hours). **Torn down it costs ≈$0.19/day** (S3, ECR, Secrets Manager,
  Route 53, KMS), observed 14–16 August at $0.19/$0.19/$0.18. Tax is billed separately (~15%; $43.48
  in July).

  *(A previous revision of this note claimed "~$290/month (~$9.70/day), measured 2026-08-04" with a
  breakdown summing to exactly $290. That was a monthly extrapolation, not a measurement: $9.70/day is
  $290÷30, and the itemisation inflated Spot nodes, ALB and NAT while omitting CloudWatch entirely.
  The figures above are per-day billing data.)*

  The single largest lever is still not any line item — it is **not running the stack overnight**;
  `destroy.sh`/`deploy.sh` round-trip in ~30 minutes and preserve votes via the final snapshot. The
  largest *irreducible* item is the EKS control plane, which is a flat fee for the managed control
  plane and is exactly what is being bought.

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

*Re-checked against the code on 2026-07-26. Four of the seven were done during the 2026-07-21 passes
but the list had not caught up — item 2 in particular still called a disarmed foot-gun "live", which
contradicted the §7 status note above it.*

1. ~~**Terraform remote state**~~ — **done 2026-07-21.**
2. ~~**JCasC + Jenkins AMI**~~ (§7) — **done 2026-07-21, then the whole EC2 host retired 2026-07-31.**
   Configuration lived in that stack's own JCasC file, and `lifecycle.ignore_changes = [user_data, ami]` stopped a routine
   apply from churning the host. Ignored rather than pinned, so a *new* host still gets the latest
   image.
3. ~~**WAF + rate limiting**~~ — **done 2026-07-21.** `terraform/waf.tf`, four rules; see
   `docs/security.md`.
4. **RDS durability** — *partially done.* PITR is on (7-day retention). **Multi-AZ and deletion
   protection remain open, and deletion protection is deliberately off** because it makes
   `terraform destroy` fail on a stack that is torn down between sessions. Closing this one means
   deciding to retire the destroy/rebuild workflow first — it is a workflow decision, not a
   Terraform change.
5. ~~**Alerting**~~ — **mechanism done 2026-07-21.** Alertmanager publishes to SNS via IRSA (no SMTP
   on the cluster) and the chart ships 7 alert rules in `prometheusrule.yaml`. What remains is
   narrower and is tracked as **G7** in `docs/cicd.md`: nothing notifies on a failed *build*.
6. **Migrations** — **half done (§4), and now the top of the open list.** The *exactly-once* half
   shipped 2026-07-21: the `post-install,pre-upgrade` hook Job runs schema work once per release
   instead of every replica racing at startup. **Alembic itself is still missing** — versioning,
   ordering and down-steps — and this Job is what will run it. Needed before the schema next takes a
   non-additive change.
7. **NAT/Spot redundancy** — the most expensive, and the least likely to bite at this scale.
