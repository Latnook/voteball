# VoteballBackupJobFailed

**The nightly database backup CronJob failed.**

## What this means

`voteball-backup` runs a `pg_dump` to S3 daily at 02:00 UTC. A failed run means last night's dump
either didn't happen or is incomplete. This is not an active outage — nothing about the live site is
affected — but it's a gap in your data-loss protection. RDS point-in-time recovery still covers the
last 7 days regardless of this Job, so you are not unprotected, just down to one layer instead of two.

## What to check first

```bash
kubectl get jobs -n devops-app -l job-name=voteball-backup
kubectl logs -n devops-app -l job-name=voteball-backup --tail=100
```

## How to fix it

- **S3 permission error** — the backup ServiceAccount carries an IRSA role scoped to `backups/` in the
  rollups bucket. If the log shows an S3 `AccessDenied`, check
  `kubectl get sa -n devops-app backup -o yaml` for the role annotation and confirm it still matches
  `backup.roleArn` in `charts/voteball/values.yaml` (this field is sync-managed — never hand-edit it,
  re-run `./scripts/sync-values-from-tf.sh` if it looks wrong).
- **`pg_dump` couldn't reach RDS** — same checks as `VoteballHighErrorRate`: RDS availability and the
  `allow-app-egress` NetworkPolicy.
- **Job timed out mid-dump** — if the database has grown significantly, the Job's `activeDeadlineSeconds`
  may now be too short. Check `charts/voteball/templates/backup-cronjob.yaml` for the current value.

## When to roll back instead

There's nothing to roll back — this Job doesn't touch the running application, so a bad backup run
can't be caused by (or fixed by reverting) an application deploy. Fix the underlying cause above and
let tonight's scheduled run try again, or trigger one manually:

```bash
kubectl create job -n devops-app voteball-backup-manual --from=cronjob/voteball-backup
```

If backups keep failing for more than a day, see `VoteballBackupMissing` — that alert is what actually
pages if this one doesn't get fixed in time.
