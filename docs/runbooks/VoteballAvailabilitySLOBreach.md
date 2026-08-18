# VoteballAvailabilitySLOBreach

**Fewer than 99% of voting-journey requests have succeeded, averaged over the last 6 hours.**

## What this means

This is the slow-burn version of `VoteballHighErrorRate` — not a spike, a sustained pattern. It
usually means an error-rate or backend-down alert already fired earlier and either wasn't seen or
wasn't fully fixed. Because it's a 6-hour average, this alert can still be firing well after the
underlying problem is gone — the average takes hours to recover even once errors stop.

## What to check first

Check whether this is old news or ongoing:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# in the UI at localhost:9090, run:
#   voteball:availability:ratio5m
# and compare to:
#   avg_over_time(voteball:availability:ratio5m[6h])
```

If the 5-minute ratio is back near 1 and only the 6-hour average is still below 0.99, the incident is
over and this alert will clear on its own as the window rolls forward — no action needed beyond
confirming it.

If the 5-minute ratio is *also* low, this is a live, ongoing outage. Go straight to the
`VoteballHighErrorRate` or `VoteballNoBackendAvailable` runbook depending on what
`kubectl get pods -n devops-app` shows.

## How to fix it

There is nothing specific to fix here — this alert has no independent cause of its own. It is a
symptom of one of the other application alerts (`VoteballHighErrorRate`, `VoteballNoBackendAvailable`,
`VoteballPodCrashLooping`) either firing right now or having fired recently enough that the 6-hour
average hasn't recovered. Check Alertmanager for what else is or was firing:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &
# then browse http://localhost:9093
```

## When to roll back instead

If a live outage is confirmed (5-minute ratio also low) and it started at or shortly after a deploy,
roll back per `VoteballHighErrorRate`'s guidance rather than diagnosing live. If the 5-minute ratio is
already healthy, there is nothing to roll back — rolling back a resolved incident achieves nothing and
risks reintroducing whatever the last deploy fixed.
