# VoteballMigrationJobFailed

**The schema-migration Job failed. The release did not deploy.**

## What this means

`voteball-migrate` is a Helm hook Job that runs the schema migration before the new backend/worker
pods roll out (`post-install,pre-upgrade`). If it fails, ArgoCD stops there — the new pods never
start, and the site keeps running the *previous* version. This is quiet by design: nothing about the
running site looks broken, because it isn't. The danger is that whoever pushed the change thinks it
shipped when it didn't.

## What to check first

```bash
kubectl get jobs -n devops-app -l job-name=voteball-migrate
kubectl logs -n devops-app job/voteball-migrate
```

If the Job's pod was already cleaned up, `hook-succeeded` deletion only applies on success — a failed
Job's pod is kept around specifically so you can read this log. If `kubectl logs` returns nothing,
check `kubectl get pods -n devops-app -l job-name=voteball-migrate --show-labels` for the actual pod
name and try `kubectl logs -n devops-app <pod-name>`.

## How to fix it

- **A bad migration statement** — the log will show the failing SQL directly (psycopg2 prints the
  statement and the Postgres error). Fix the schema change in `services/backend/schema.sql` or
  `seed.sql`, commit, and push; the next sync retries the Job.
- **Migration is fine, but it can't reach the database** — check RDS status and
  `kubectl get networkpolicy -n devops-app allow-app-egress -o yaml`, same as `VoteballHighErrorRate`.
- **ArgoCD stuck retrying the same failed Job** — Helm hook Jobs are immutable once created
  (`before-hook-creation` delete policy handles this on the *next* release, not automatically). If
  ArgoCD's sync is stuck, force a resync from the ArgoCD UI or
  `kubectl -n argocd delete job -n devops-app voteball-migrate` to let a re-sync recreate it cleanly.

## When to roll back instead

If the migration is failing because the new schema change is simply wrong, there's nothing to roll
back — the old release is already what's running, since the Job blocked before anything changed. Fix
the SQL and re-push. Rollback only matters here if you need to abandon the change entirely: revert the
commit that introduced the bad schema change (not just `image.tag`, since the problem is in
`schema.sql`/`seed.sql`) and push.
