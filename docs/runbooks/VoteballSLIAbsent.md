# VoteballSLIAbsent

**`voteball:journey_requests:rate5m` has returned no data at all for 15 minutes.**

## What this means

We cannot measure availability. This is not "the site is down" — `VoteballHighErrorRate` and
`VoteballNoBackendAvailable` already cover that. This is worse in one specific way: whatever number
`voteball:availability:ratio5m` and every dashboard panel built on it currently show, **do not trust
it.** With both the error count and the request count empty, that ratio's `or vector(1)` fallback
returns a confident `1` — 100% available, the same number a perfectly healthy site would show. This
alert exists because availability cannot self-report its own blindness; only watching for the SLI's
*absence*, rather than its value, catches it.

This shipped for real on 2026-08-18: a target label silently renamed the application's `endpoint`
label to `exported_endpoint`. Every SLI filter (`endpoint=~"/api/(options|vote|results.*)"`) stopped
matching anything, and a total outage would have rendered as green 100% and paged nobody.

## What to check first

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# in the UI at localhost:9090, run:
count by (endpoint) (voteball_http_requests_total)
```

- **Healthy**: real route values — `/api/options`, `/api/vote`, `/api/results`, etc.
- **Broken**: a single series labelled `http` (or no series at all).

If it's broken, check whether the routes moved to a different label:

```
count by (exported_endpoint) (voteball_http_requests_total)
```

If the real route values show up under `exported_endpoint` instead of `endpoint`, a target label
(scrape metadata) is shadowing the application's own `endpoint` label — this is exactly what happened
on 2026-08-18. If neither label shows real routes and there's no `voteball_http_requests_total` series
at all, the backend isn't emitting metrics or Prometheus isn't scraping it — check
`kubectl get pods -n devops-app` and `PrometheusTargetDown` first instead.

## How to fix it

**Label shadowing (`exported_endpoint` has the real values):** the fix is `honorLabels: true` on the
backend's ServiceMonitor endpoint, so the application's own `endpoint` label wins over
prometheus-operator's scrape-target label of the same name. This is exactly the 2026-08-18 incident,
and the fix is already in the chart — confirm it's still there before assuming it needs to be added:

```bash
grep -n honorLabels charts/voteball/templates/servicemonitor.yaml
```

If it's missing (removed by an unrelated chart edit, or never applied on a fork), add
`honorLabels: true` to the `backend` ServiceMonitor's endpoint block in
`charts/voteball/templates/servicemonitor.yaml`, commit and push (ArgoCD syncs it), then re-run the
`count by (endpoint)` query above once the next scrape has happened (~30s) to confirm real route
values are back under `endpoint`. If it's already `true` and the routes are still shadowed, check
whether the Service's port is still named `http` (`port: http` in the ServiceMonitor must match the
backend Service's named port) — a port rename breaks the selector this fix depends on.

**No `voteball_http_requests_total` series at all:** the backend pods aren't being scraped or aren't
emitting the metric — this is a scrape/target problem, not a label problem. Check
`PrometheusTargetDown` and `kubectl get pods -n devops-app` first.

## When to roll back instead

If this started right after a chart or ServiceMonitor change, roll back that change rather than
patching `honorLabels` under pressure — revert the commit and push; ArgoCD syncs it. If it started
with no recent deploy to this repo, suspect a change to `kube-prometheus-stack` or its relabeling
config instead (that's platform, not app — check `terraform/addon-monitoring.tf`).

Because this alert can only tell you monitoring is blind, not whether the site itself is up, **also
check the site directly** (`curl https://voteball.latnook.com/api/options`) for the duration of the
incident — a real outage happening at the same time as the SLI going blind is the worst case, and
nothing else will catch it while this alert is firing.
