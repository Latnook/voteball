# VoteballBackupMissing

**No database backup has completed successfully in 48 hours.**

## What this means

This is a different signal from `VoteballBackupJobFailed`: that alert fires on a Job *failing*; this
one fires on the *absence* of any successful completion, which also catches a CronJob that never ran
at all — suspended, deleted, or mis-scheduled — since a Job that never runs never logs a failure
either. The backup is scheduled daily at 02:00 UTC, so two days of silence means at least one, likely
two, scheduled runs never completed.

## What to check first

```bash
kubectl get cronjob -n devops-app voteball-backup
kubectl get jobs -n devops-app -l job-name=voteball-backup
```

Check specifically whether the CronJob is suspended (`SUSPEND` column showing `True`) — that alone
fully explains this alert and needs no further digging.

## How to fix it

- **CronJob suspended** — `kubectl patch cronjob -n devops-app voteball-backup -p '{"spec":{"suspend":false}}'`.
  Check `charts/voteball/values.yaml`'s `backup.schedule`/`backup.suspend` (if present) to see whether
  this was set intentionally by a chart change — if so, fix the chart rather than patching around it,
  since the next ArgoCD sync will just re-suspend it.
- **CronJob exists but every run is failing** — this is really `VoteballBackupJobFailed`; follow that
  runbook to find why.
- **CronJob was deleted or never created** — check `kubectl get events -n devops-app` for anything
  around the migration/sync history, and confirm `charts/voteball/templates/backup-cronjob.yaml` still
  renders (`helm template charts/voteball | grep -A2 'kind: CronJob'`).

## When to roll back instead

There's nothing to roll back — a missing backup isn't caused by the running application version.
Fix the CronJob directly per above. Once you trigger a successful manual run
(`kubectl create job -n devops-app voteball-backup-manual --from=cronjob/voteball-backup`), this alert
clears in about a minute once Prometheus scrapes the new completion timestamp.
