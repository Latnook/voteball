# VoteballRollupsStale

**The worker has not completed a successful results recompute in over 10 minutes.**

## What this means

Votes are still being recorded, but the numbers on the results page are frozen. The worker is
notification-driven — the backend sends `NOTIFY votes_changed` on every vote and the worker `LISTEN`s
for it — with a 30-second poll as a backstop for a missed notification. This alert only fires when
*both* have stopped working: no notification arrived, and the 30-second backstop also didn't run. That
combination is why nothing else catches it — pods look `Ready`, the site looks up, and only the age of
the results is wrong.

## What to check first

```bash
kubectl get pods -n devops-app -l app=worker
kubectl logs -n devops-app -l app=worker --tail=80
```

The worker's readiness probe requires a completed loop iteration, so if it's `NotReady` the pod itself
already knows something is wrong — check for a stuck DB query or a crash loop instead of chasing this
alert further. If it's `Ready`, look for whether it's actually looping:

```bash
kubectl logs -n devops-app -l app=worker --tail=200 | grep -i "recompute\|listen\|notify"
```

## How to fix it

- **Worker pod crash-looping or wedged** — `kubectl get pods -n devops-app -l app=worker` shows
  restarts. Delete the pod; the Deployment replaces it and a fresh `LISTEN` connection is established.
- **Database connection exhausted or unreachable** — the worker holds a long-lived `LISTEN`
  connection separate from its recompute connection; if RDS is under load or unreachable, both stall.
  Check RDS status in the AWS console the same way you would for `VoteballHighErrorRate`.
- **Notifications silently stopped but the worker looks fine** — this is the case the 30s poll should
  have caught and didn't. Restart the worker pod (`kubectl delete pod -n devops-app -l app=worker`);
  a fresh boot re-establishes both the `LISTEN` and the poll loop from a clean state.

## When to roll back instead

If staleness started right after a deploy touching `services/worker/`, treat it as a bad release:
revert `image.tag` in `charts/voteball/values.yaml` to the previous `ci: image tag` commit and push;
ArgoCD syncs it. Votes are not being lost while this alert is firing — they're queued in the raw
`votes` table and will be picked up by the next successful recompute — so there is no urgency to avoid
a clean rollback in favor of live debugging.
