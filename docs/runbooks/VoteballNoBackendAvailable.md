# VoteballNoBackendAvailable

**Zero backend replicas are available, for 2 minutes. Voting and results are down.**

## What this means

The `backend` Deployment has no pod that's both running and ready. This is the most severe
application alert: the frontend (nginx) is still up and still serves the static HTML pages, so the
site *looks* reachable, but every `/api/*` call — casting a vote, loading results, loading the
options list — fails. A visitor sees a page that loads and then does nothing when they interact with
it.

## What to check first

```bash
kubectl get deploy -n devops-app backend
kubectl get pods -n devops-app -l app=backend
kubectl describe pod -n devops-app -l app=backend
```

`kubectl describe` on a pod that's `Pending` or `ImagePullBackOff` will show the real cause in the
Events section near the bottom — read that before the logs.

## How to fix it

- **`ImagePullBackOff`** — the image tag in `values.yaml` doesn't exist in ECR (a bad promote, or a
  deploy that ran before the image finished pushing). Check
  `kubectl get pods -n devops-app -o jsonpath='{.items[*].spec.containers[*].image}'` against ECR, and
  roll back if it's wrong (below).
- **`CrashLoopBackOff`** — see `VoteballPodCrashLooping`'s runbook; same underlying condition, just
  every replica at once instead of one.
- **`Pending` with no image pull error** — likely no node has room. `kubectl get nodes` and
  `kubectl describe pod` will show an "Insufficient cpu/memory" or unschedulable event. The Cluster
  Autoscaler should add a node within a couple of minutes; if it doesn't, check `NodeNotReadyOrUnderPressure`.
- **Database unreachable at startup** — the migration Job runs before the Deployment rolls, so this is
  less likely than for a running pod, but check `VoteballMigrationJobFailed` if a release just went out.

## When to roll back instead

If this started right after a deploy — which it usually does, since a bad image is the most common
cause of zero available replicas — don't wait for it to self-heal. Revert `image.tag` in
`charts/voteball/values.yaml` to the previous `ci: image tag` commit's value and push; ArgoCD syncs it.
This alert means the site is fully down for API calls right now — treat every minute as live outage
time, not diagnosis time.
