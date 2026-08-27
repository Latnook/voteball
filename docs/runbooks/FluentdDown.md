# FluentdDown

**The Fluentd aggregator Deployment in the `logging` namespace has had zero available replicas for
15 minutes.**

## What this means

Fluentd is the aggregator tier of the EFK pipeline — Fluent Bit (the DaemonSet in
`amazon-cloudwatch`, unchanged, a **different project** from Fluentd) tails every node and forwards to
this Deployment, which buffers, retries, and writes into the Elasticsearch write alias. When this
Deployment has no available replica, nothing reaches Elasticsearch.

**What is affected:** log *search* via Kibana stops updating — new log lines are not indexed.

**What is NOT affected:** the public site, and logs themselves. `CloudWatch is the authoritative
copy` and is completely independent of Fluentd — Fluent Bit fans out to CloudWatch and to this
aggregator separately (decision 5, "Fluent Bit fans out; it does not switch"), so CloudWatch keeps
receiving every log line the entire time this alert is firing. `devops-app` has no dependency on
Fluentd at all.

**Fluent Bit itself reports healthy throughout this alert.** Its `forward` output buffers and retries
against a refused TCP connection on port 24224 exactly the way it would sit quietly if there were
simply no new log lines to ship — from `kubectl get pods` alone, "Fluentd is down and logs are being
dropped" and "everything is fine and idle" look identical. **`scripts/logging/verify-efk.sh` is the
check that actually distinguishes the two** — it writes a known marker line to a `devops-app` pod's
stdout and confirms that exact line comes back out of an Elasticsearch query, which a healthy-but-idle
Fluent Bit can never fake. Do not conclude "this is fine" from Fluent Bit's own pod status.

## What to check first

```bash
kubectl get deploy -n logging fluentd
kubectl get pods -n logging -l app=fluentd
kubectl describe pod -n logging -l app=fluentd
kubectl logs -n logging -l app=fluentd --tail=100
```

The readiness probe is a plain `tcpSocket` check on port 24224, so "not Ready" here almost always
means the container itself failed to start rather than a slow dependency. Things specific to this
component worth checking:

- **The `ELASTIC_PASSWORD` env var** comes from `voteball-logs-es-elastic-user`, a Secret the ECK
  operator generates when the `Elasticsearch` resource is created — Fluentd never gets a fresh value
  after pod start, so if that Secret was ever deleted and regenerated (a full Elasticsearch resource
  recreate), a running Fluentd pod would be authenticating with a stale password. A pod restart picks
  up the current one.
- **The CA cert mount** (`voteball-logs-es-http-certs-public`), also ECK-generated — if the
  Elasticsearch resource was recreated, this Secret's contents changed too, and `ssl_verify true`
  against a stale CA fails the TLS handshake on every write attempt.
- **The `/tmp` and buffer `emptyDir` mounts** — Fluentd's Ruby runtime writes a lock file under `/tmp`
  on every start regardless of config; a container image change that drops one of these mounts fails
  immediately with a read-only-filesystem error, not a slow degradation.

## How to fix it

- **Stale credential/CA after an Elasticsearch resource recreate** — delete the Fluentd pod so the
  Deployment recreates it and re-reads both Secrets: `kubectl delete pod -n logging -l app=fluentd`.
- **CrashLoopBackOff after a `charts/logging` change** (image tag, resource limits, the `fluent.conf`
  ConfigMap) — revert the offending commit and let the `logging` ArgoCD Application re-sync.
- **Elasticsearch itself is unreachable** — Fluentd's own readiness does not depend on Elasticsearch
  being up (only its writes do), so if Fluentd is Ready but nothing is landing, check
  `ElasticsearchDown` instead; that is a different alert with a different runbook.
- **Confirm the fix actually worked** — a healthy pod is necessary but not sufficient here, per the
  section above. Run `./scripts/logging/verify-efk.sh` and confirm it reports the marker line was
  found, not just that pods are Running.

## When to roll back instead

If this started right after a `charts/logging` values or template change (the Fluentd image tag,
resources, or `fluent.conf`), reverting that commit and letting ArgoCD re-sync the `logging`
Application is faster than debugging forward. If it started right after an Elasticsearch resource
recreate (a `terraform apply` touching the ECK operator, or a manual `kubectl delete elasticsearch`),
the credential/CA staleness above is the most likely cause and a pod restart is the fix, not a
rollback.
