# Runbooks

One file per alert in `charts/voteball/templates/prometheusrule.yaml` (application) and
`charts/observability/templates/prometheusrule.yaml` (platform: Kubernetes, Jenkins, monitoring).
Every alert carries a `runbook_url` annotation pointing at the matching file here, and **Alertmanager
renders annotations into the SNS message it sends** — so this link is what actually arrives in the
email that wakes someone up, not a wiki page they have to go find.

Each runbook answers exactly four questions, in this order: what the alert means, what to check
first, how to fix it, and when to stop diagnosing and roll back instead.

| Alert | What it means | Severity |
|---|---|---|
| [VoteballHighErrorRate](VoteballHighErrorRate.md) | >5% of voting-journey requests are 5xx for 5m | critical |
| [VoteballHighLatencyP95](VoteballHighLatencyP95.md) | p95 journey latency above the 1s SLO for 10m | warning |
| [VoteballRollupsStale](VoteballRollupsStale.md) | Worker hasn't recomputed results in 10m; site shows stale numbers | warning |
| [VoteballAvailabilitySLOBreach](VoteballAvailabilitySLOBreach.md) | Availability below 99% over a 6h window | warning |
| [VoteballSLIAbsent](VoteballSLIAbsent.md) | The availability SLI itself has no data for 15m — monitoring is blind, not healthy | critical |
| [VoteballPodCrashLooping](VoteballPodCrashLooping.md) | A pod is in `CrashLoopBackOff` for 5m | critical |
| [VoteballNoBackendAvailable](VoteballNoBackendAvailable.md) | Zero backend replicas available for 2m — API fully down | critical |
| [VoteballMigrationJobFailed](VoteballMigrationJobFailed.md) | Schema migration Job failed; release did not deploy | critical |
| [VoteballBackupJobFailed](VoteballBackupJobFailed.md) | Nightly `pg_dump` CronJob run failed | warning |
| [VoteballBackupMissing](VoteballBackupMissing.md) | No successful backup completion in 48h | warning |
| [VoteballContainerOOMKilled](VoteballContainerOOMKilled.md) | A pod restarted more than 3 times in an hour | warning |
| [NodeNotReadyOrUnderPressure](NodeNotReadyOrUnderPressure.md) | A node is NotReady or under memory/disk pressure for 10m | critical |
| [DeploymentReplicasMismatch](DeploymentReplicasMismatch.md) | Any Deployment cluster-wide short of ready replicas for 10m | warning |
| [PrometheusTargetDown](PrometheusTargetDown.md) | Prometheus can't scrape a target for 5m — that target's metrics/alerts are now blind | critical |
| [JenkinsQueueStuck](JenkinsQueueStuck.md) | Jenkins build queue non-empty for 15m; site itself is unaffected | warning |

## Useful for every runbook here

Prometheus, Grafana and Alertmanager have no public URL — they're `ClusterIP`-only, reached by
port-forward:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

Grafana admin password:

```bash
kubectl get secret kube-prometheus-stack-grafana -n observability -o jsonpath='{.data.admin-password}' | base64 -d
```

Namespaces: the application runs in `devops-app`, Jenkins runs in `ci`, and all of the above run in
`observability` (renamed from `monitoring`).
