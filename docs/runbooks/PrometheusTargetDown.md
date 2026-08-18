# PrometheusTargetDown

**Prometheus has been unable to scrape a target for 5 minutes.**

## What this means

This is cluster-wide and matches the metrics themselves, not the application. If Prometheus can't
reach something, it isn't just that one thing that's blind — every dashboard panel and every other
alert built from that target's metrics is also silently wrong for as long as this is firing, because
they're all reading nothing instead of a number. This is worth treating with more urgency than its
"warning"-adjacent feel suggests: an outage that also breaks your ability to see the outage is worse
than either alone.

## What to check first

**There are two failure shapes here that look identical from `kubectl get pods` but have completely
different fixes — telling them apart first saves real time (this cost real time on this project once
already):**

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# browse http://localhost:9090/targets
```

- **Target is ABSENT from the list entirely** — Prometheus doesn't know it exists. This is almost
  always a missing `release: kube-prometheus-stack` label on the target's `ServiceMonitor` —
  `ruleSelectorNilUsesHelmValues`/its ServiceMonitor equivalent means kube-prometheus-stack only
  discovers ServiceMonitors and PrometheusRules that carry its own release label. Check:
  ```bash
  kubectl get servicemonitor -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" labels="}{.metadata.labels}{"\n"}{end}'
  ```
- **Target is PRESENT but shows `up == 0`** — Prometheus knows about it and can't reach it right now.
  This is a network problem, not a labeling problem: the pod may be down, or a NetworkPolicy is
  blocking the scrape. Check `kubectl get networkpolicy -n <target-namespace>` — specifically whether
  `allow-prometheus-scrape` (or an equivalent) exists and permits traffic from the `observability`
  namespace.

## How to fix it

- **Missing label (target absent)** — add `release: kube-prometheus-stack` to the ServiceMonitor's
  labels in whichever chart defines it, commit, push.
- **NetworkPolicy blocking scrape (`up == 0`, target present)** — confirm the policy allows ingress
  from `observability` on the metrics port; see `charts/voteball/templates/networkpolicy.yaml`'s
  `allow-prometheus-scrape` rule as the working example for `devops-app`.
- **Target pod itself is down** — `kubectl get pods -n <target-namespace>`; this is really whatever
  that workload's own runbook covers (e.g. `VoteballPodCrashLooping` if it's a voteball pod).

## When to roll back instead

There's no single "roll back" for this alert — the fix depends entirely on which target and which of
the two shapes above. If the target went dark right after a chart change to that workload's
ServiceMonitor or NetworkPolicy, reverting that specific commit is the fastest fix.
