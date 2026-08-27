# ElasticsearchDown

**The Elasticsearch pod in the `logging` namespace has not been Ready for 15 minutes.**

## What this means

This is **not** the same thing as cluster health being `yellow` — this cluster is a single node with
no replica shard by design (see `docs/design/2026-08-27-efk-logging-design.md` decision 3), so `yellow`
is its permanent, correct state and nothing alerts on it. This alert fires only when the pod itself
stops being Ready — the whole search backend is gone, not just under-replicated.

**What is affected:** log *search* via Kibana. Nobody can query recent log lines while this is down.

**What is NOT affected:** the public site, and logs themselves. `CloudWatch is the authoritative copy`
— Fluent Bit (the DaemonSet that tails every node) fans out to CloudWatch and to the Fluentd
aggregator independently (decision 5, "Fluent Bit fans out; it does not switch"), so CloudWatch keeps
receiving every log line the whole time Elasticsearch is down. Nothing in `devops-app` talks to
Elasticsearch at all — `frontend`/`backend`/`worker` have no dependency on it, so this alert can never
be the cause of a user-facing outage.

**This alert also fires if the Elasticsearch resource no longer EXISTS.** The rule is
`kube_pod_status_ready{...} == 0 or absent(...)`, and the `absent()` half is deliberate: a deleted
`Elasticsearch` custom resource takes its kube-state-metrics series with it, and a bare `== 0` against
a series that does not exist matches nothing — no data, no alert, on a stack that is completely gone.
Check *existence* first (`kubectl get elasticsearch -n logging`) before debugging a pod that may not
be there. A deliberate teardown or an ArgoCD prune will fire this after 15 minutes; that is intended.

## What to check first

```bash
kubectl get pods -n logging -l common.k8s.elastic.co/type=elasticsearch
kubectl describe pod -n logging -l common.k8s.elastic.co/type=elasticsearch
kubectl get elasticsearch -n logging voteball-logs -o jsonpath='{.status}'
```

The `Elasticsearch` custom resource's `.status` field (from the ECK operator, not from `kubectl get
pods`) usually names the problem directly — a health colour, a phase, and the reconciled version.

Two failure shapes are specific to this component and worth ruling in or out early:

- **Pod stuck `Pending`** — the data volume is `gp3`, `WaitForFirstConsumer`, so the PV is pinned to
  whichever Availability Zone the pod first landed in (`topology.ebs.csi.aws.com/zone` node affinity —
  decision 6). If that AZ currently has no schedulable node (a Spot reclaim mid-replacement), the pod
  waits for Cluster Autoscaler rather than rescheduling elsewhere — EFS was not an option here because
  Elastic does not support an NFS data path, so this differs from how `JENKINS_HOME` recovers.
  `kubectl get nodes -o wide` and `kubectl describe pod` (look for `FailedScheduling` events) confirm
  this quickly.
- **Pod `CrashLoopBackOff`** — check `kubectl logs -n logging voteball-logs-es-default-0 -c
  elasticsearch --previous`. The two settings most likely to matter here are the fixed heap
  (`ES_JAVA_OPTS`, sized at `1g`/`1g` for a 2Gi container) and `node.store.allow_mmap: false` (chosen
  specifically to avoid a privileged init container — see decision 4); a version bump that changes
  either assumption is the most likely self-inflicted cause.

## How to fix it

- **Pod Pending on AZ capacity** — wait for Cluster Autoscaler to add a node in that AZ, or check
  whether the node group's AZ balance has drifted. There is nothing to roll back here; this resolves
  itself once a node is schedulable.
- **CrashLoopBackOff after a chart change** — revert the offending commit to `charts/logging` (heap
  size, resource limits, or the Elasticsearch version) and let ArgoCD (the `logging` Application)
  re-sync.
- **Operator itself unhealthy** — `kubectl get pods -n elastic-system`. The ECK operator is a Terraform-
  owned platform add-on (`terraform/addon-eck.tf`), not an ArgoCD one — the chart installs
  cluster-scoped CRDs and RBAC that both AppProjects' `clusterResourceWhitelist: []` structurally
  forbid ArgoCD from touching, so a broken operator needs `terraform apply`, not a git push.
- **Volume genuinely lost** — this is a single node with no replica, so a lost EBS volume loses the
  index. That is an accepted trade-off (decision 3): re-run `./scripts/logging/verify-efk.sh` once the
  pod is back to confirm the pipeline carries a log line end to end again; there is nothing to restore
  from, since Elasticsearch here is a convenience search copy, not the source of truth.

## When to roll back instead

If this started right after a `charts/logging` values change (version bump, resource limits, heap
size), reverting that commit and letting ArgoCD re-sync the `logging` Application is faster than
debugging forward. If it started right after a `terraform apply` (an ECK operator version bump), the
fix is a Terraform revert and another apply — there is no `helm upgrade` shortcut, the same as every
other platform add-on in this repo.
