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
- **`curl: (6) Could not resolve host`** — start here after any rebuild; this is now the most common
  cause. See "the cluster cannot resolve its own hostname" below. One command settles it:
  `./scripts/verify-public-dns.sh`.
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
- **The cluster cannot resolve its own hostname** (`curl: (6) Could not resolve host`). Run
  `./scripts/verify-public-dns.sh`; it diagnoses and repairs this case, and refuses to act on any
  other. What happens, first seen on the 2026-08-24 rebuild:

  1. The app is installed and its pods start resolving `<app_domain>` at once.
  2. external-dns has not created the A record yet — it reconciles only after the Ingress exists.
  3. `<app_domain>` **already exists** in Route53 for an unrelated reason (this zone carries a
     `google-site-verification` TXT record on that exact name), so the query returns
     **NOERROR with an empty answer**, not NXDOMAIN. That is a negative answer, and RFC 2308 caps
     its lifetime at `min(SOA record TTL, SOA MINIMUM)` = `min(900, 86400)` = **15 minutes**. (This
     step said 86400 / twenty-four hours until 2026-08-26 — the MINIMUM field alone. It is 15
     minutes, and that difference is the difference between waiting and escalating.)
  4. Both caches keep serving it, but for very different lengths of time: CoreDNS caps a denial at
     30s, the **VPC resolver holds its own copy for the full 15 minutes**, and nothing in the cluster
     can clear that one. Measured 2026-08-24: a direct query to `10.0.0.2` still answered correctly.
     Measured 2026-08-26 on the next rebuild: it did **not** — 19s left on CoreDNS's copy against
     691s on the VPC resolver's, so restarting CoreDNS was powerless and the script said so.

  The tell that distinguishes it from every other cause: **TXT resolves and A does not.**

  ```bash
  POD=$(kubectl get pods -n devops-app -l app=canary -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n devops-app "$POD" -- nslookup -type=a   <app_domain> 172.20.0.10   # empty
  kubectl exec -n devops-app "$POD" -- nslookup -type=txt <app_domain> 172.20.0.10   # answers
  kubectl exec -n devops-app "$POD" -- nslookup -type=a   <app_domain> 10.0.0.2      # answers
  ```

  The repair is a rolling restart of CoreDNS, which drops the cache:
  `kubectl rollout restart deployment coredns -n kube-system`. Do **not** make that unconditional —
  if a public resolver also cannot resolve the name, the record genuinely does not exist yet and the
  answer is to wait for external-dns, not to restart anything. `deploy.sh` step 11c runs this check
  automatically at the end of every deploy for exactly this reason.

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
