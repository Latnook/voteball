# Raw evidence captures

Unedited command output backing the claims in
[`../live-cluster-snapshot.md`](../live-cluster-snapshot.md). That file carries readable, trimmed
excerpts; these are the full captures, so a reader can check a summary rather than take it on trust.

**Like the snapshot document, these are dated evidence and are never "corrected".** The cluster they
describe is destroyed and rebuilt regularly, which regenerates every pod name, ALB hostname, ACM
certificate and WAF id. A value here that no longer resolves is the file working as intended.

| File | What it is |
|---|---|
| `2026-07-27-pre-teardown-kubectl.txt` | All eight required `kubectl` outputs, untrimmed — including the complete `describe pod` for a backend replica |
| `2026-07-27-pre-teardown-demos.txt` | The demo runs: HTTPS + certificate, `/api/options` and `/api/results`, the S3 backup job, ServiceAccount IRSA roles, SNS delivery counters, alert rules, and the NetworkPolicy probe with its control |
| `2026-07-27-pod-restart-poll.txt` | 1,050 timestamped HTTP status probes spanning a deliberate `kubectl delete pod` of a frontend replica through to the replacement reaching `1/1 Ready` |

## Checking the pod-restart claim yourself

The claim is "the site stayed up across a pod restart". Verify it rather than believe it:

```bash
wc -l docs/eks/evidence/2026-07-27-pod-restart-poll.txt          # 1050 probes
awk '$2!=200' docs/eks/evidence/2026-07-27-pod-restart-poll.txt  # no output == no failed request
```

Two frontend replicas plus a PodDisruptionBudget are what make losing one invisible.

## No credentials here

These captures were scanned before being committed. `describe pod` renders environment variable
**names** only — the values arrive via `envFrom` referencing a ConfigMap and a Secret, so they are
never printed. The `app-secret` contents (which hold `ADMIN_PASSWORD_HASH`, not a password) appear
nowhere in this directory.
