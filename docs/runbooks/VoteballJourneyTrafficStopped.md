# VoteballJourneyTrafficStopped

**`voteball:journey_requests:rate5m` has been 0 for 10 minutes, despite the synthetic canary.**

## What this means

This alert only exists because the `canary` Deployment
(`charts/voteball/templates/canary-deployment.yaml`) hits `https://<app_domain>/`,
`/api/options` and `/api/results?by=all` every `canary.intervalSeconds` (30s by default) — the real
public path a voter takes: ALB → nginx → backend → RDS. Before the canary existed, "zero journey
requests" was this site's *normal* state — it has almost no organic traffic — so an alert on
`rate == 0` would have fired constantly and meant nothing. It was the reason the 2026-08-18
RDS-egress drill (the RDS egress NetworkPolicy removed, cutting the backend's route to RDS)
rendered as a **perfect green dashboard**: `voteball:journey_requests:rate5m` and
`voteball:journey_errors:rate5m` both sat at 0, so every ratio-based alert (`VoteballHighErrorRate`,
`VoteballAvailabilitySLOBreach`) was mathematically blind, and `VoteballSLIAbsent` didn't catch it
either — the series was *present* with value 0, not absent.

With the canary running, a steady non-zero request rate is the expected baseline, so a drop to zero
is now a real signal: either the canary pod itself stopped running/hung, or every request it sends is
failing before nginx or the backend can even record it (DNS, TLS, the ALB, or a NetworkPolicy egress
break — exactly the 2026-08-18 cause).

**This alert is only meaningful because `canary.enabled: true` in `values.yaml` guarantees traffic.**
If the canary is ever turned off, this alert is templated `{{- if .Values.canary.enabled }}` right
alongside it in `prometheusrule.yaml` and disappears with it — don't re-enable one without the other.

## What to check first

```bash
kubectl get deploy -n devops-app canary
kubectl get pods -n devops-app -l app=canary
kubectl logs -n devops-app -l app=canary --tail=50
```

The canary logs one line per request (`<http_code> GET <path>`) every `intervalSeconds`. Read those
before anything else:

- **No pod, or pod not Running** — the canary itself is down. `kubectl describe pod -l app=canary`
  for the reason (ImagePullBackOff, scheduling, OOM).
- **Pod Running but no recent log lines** — the loop is hung, most likely inside a `curl` call that
  never times out. Restart it: `kubectl delete pod -n devops-app -l app=canary` (the Deployment
  replaces it immediately).
- **Log lines show curl failures (exit via `|| true`, so check the line itself) or non-2xx codes on
  every request** — this is a real problem on the request path, not the canary's own health. Move to
  `VoteballHighErrorRate` / `VoteballNoBackendAvailable`'s runbooks, or if nothing is reaching the
  backend at all, suspect a NetworkPolicy: `kubectl get networkpolicy -n devops-app allow-db-egress
  -o yaml` and confirm `canary` is still in the `app In (...)` list this alert's own fix depends on.

## How to fix it

- **Canary pod crash-looping or stuck** — treat it like any other pod (`VoteballPodCrashLooping`'s
  runbook applies), then confirm traffic resumed: `voteball:journey_requests:rate5m` should go
  non-zero within one scrape interval of the pod becoming healthy again.
- **Canary healthy but every request errors** — this is very likely a real outage on the voting
  journey itself. Check `VoteballNoBackendAvailable` and `VoteballHighErrorRate` — if either is also
  firing, follow that runbook instead; this alert is corroborating evidence, not the primary signal.
- **Canary's NetworkPolicy egress broken** — confirm `allow-canary-egress` exists and selects
  `app In (...)` (`charts/voteball/templates/networkpolicy.yaml`). A pod outside that list keeps only
  `allow-dns-egress`: DNS resolves, every TCP connection to the public ALB silently drops, and the
  canary looks identical to a real outage from inside the cluster. This is the exact class of bug that
  broke the backup CronJob's egress for 12 days (2026-07-19 to 2026-07-31) before anyone noticed.

## When to roll back instead

If this started right after a chart change (to the canary Deployment, the NetworkPolicy, or
`ingress.host`), roll back that commit and push rather than debugging under pressure — ArgoCD syncs
the revert. If it started with no recent deploy to this repo, treat it as a real outage: check
`VoteballHighErrorRate` and `VoteballNoBackendAvailable` first, and verify the site directly
(`curl -I https://<app_domain>/api/options`) rather than trusting this alert alone to tell you whether
voters are actually affected — its job is only to notice that the signal went quiet, not to diagnose
why.
