# VoteballHighLatencyP95

**95th-percentile latency on the voting journey (`/api/options`, `/api/vote`, `/api/results*`) has
been above 1 second for 10 minutes.**

## What this means

Requests are succeeding but slow. This is not `VoteballHighErrorRate` — nobody is getting an error
page, they are just waiting. That still costs votes: a slow ballot page is one people abandon rather
than retry. The 1s threshold is a real bucket edge in the latency histogram, so this number is
measured, not estimated.

## What to check first

```bash
kubectl get pods -n devops-app -o wide
kubectl top pods -n devops-app
```

Then find which endpoint is actually slow, rather than guessing:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# in the UI at localhost:9090, run:
#   histogram_quantile(0.95, sum by (le, endpoint) (rate(
#     voteball_http_request_duration_seconds_bucket{endpoint=~"/api/(options|vote|results.*)"}[5m]
#   )))
```

If `/api/results*` is the slow one specifically, check whether the worker's rollup tables are the
bottleneck — a stale-but-not-yet-alerting rollup recompute can still leave the read query itself slow.
If `/api/vote` is slow, that is very likely the database, since it is the one write on the path.

## How to fix it

- **RDS under load** — check CPU/connections in the AWS console (RDS → your instance → Monitoring).
  A connection-count spike usually means something opened connections and never closed them; check
  recent backend pod restarts, since each one indicates a crash that may have leaked connections
  before this alert fired.
- **A specific backend pod is slow, not all of them** — `kubectl top pods -n devops-app` shows CPU per
  pod; if one is pegged, delete it and let the Deployment replace it.
- **Traffic spike** — check the HPA: `kubectl get hpa -n devops-app`. If it is already at max replicas
  and still saturated, that is a capacity problem, not a bug; raising `maxReplicas` in
  `charts/voteball/values.yaml` is the fix, not a rollback.

## When to roll back instead

If latency stepped up sharply right after a deploy (not a gradual climb with traffic), treat it like a
bad release: revert `image.tag` in `charts/voteball/values.yaml` to the previous `ci: image tag` commit
and push; ArgoCD syncs it. A gradual climb that tracks rising traffic is a capacity problem, and
rolling back changes nothing.
