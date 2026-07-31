# charts/voteball — CLAUDE.md

Guidance for the Helm chart. The root `CLAUDE.md` carries the project-wide rules, including the
warning that **`values.yaml`'s ten env-specific fields are written by
`scripts/sync-values-from-tf.sh` and must never be hand-edited.**


```bash
helm lint charts/voteball
helm template voteball charts/voteball --namespace devops-app   # renders without a live cluster
```

**The migration Job is a `post-install,pre-upgrade` hook, and that split is deliberate.** As
`pre-install` it cannot work at all: pre-install hooks run before every normal chart resource, so the
ServiceAccount, ConfigMap and ExternalSecret it needs do not exist yet, and it fails with
`serviceaccount "backend" not found` after burning `activeDeadlineSeconds`. A fresh install has nothing
to order (the schema is built from nothing and `init_db` is idempotent); an upgrade does, and by then
every dependency exists. Its pod is labelled **`app: migrate`, never `app: backend`** — the backend
Service selects that label and would route live HTTP to a one-shot script — and `migrate` is listed in
the `allow-app-egress` NetworkPolicy so it can still reach RDS through the default-deny.

**Every new workload's pod label must be added to the `allow-app-egress` NetworkPolicy's `app In
(...)` list, and the label is the *workload* name, not the CronJob/Job/image name.** The namespace is
default-deny; a pod outside that list keeps only `allow-dns-egress`, so DNS resolves and every TCP
connection is silently dropped — RDS and the AWS APIs alike. The backup CronJob shipped labelled
`app: voteball-backup` while the policy listed `backup`, and its nightly pg_dump was broken from
2026-07-19 until 2026-07-31 (fixed in `1bda7b5`).

**That class of bug does not fail cleanly, it fails *flakily*, so do not conclude from one green run
that a new pod's egress is allowed.** The VPC CNI runs `NETWORK_POLICY_ENFORCING_MODE=standard`,
which fails **open** until the node's policy agent programs the pod's eBPF maps — observed taking
well over 30s under load. Anything connecting in that window succeeds regardless of policy, which is
why `pg_dump` (connects in milliseconds) always worked while the aws-cli (seconds of Python startup
before its first STS call) did not, and why `docs/eks/live-cluster-snapshot.md` legitimately records
`Completed` backup pods that the policy never permitted. To test egress honestly, sleep at least a
minute inside the pod before opening the socket, or check the rendered label against the policy list
instead of testing at all.

**Alert rules must carry `release: kube-prometheus-stack`.** Without that label the PrometheusRule is
created, looks correct in `kubectl get prometheusrules`, and is silently never evaluated. Only write
rules against metrics this cluster actually exposes (kube-state-metrics): RDS, ALB and ACM figures are
CloudWatch-only and nothing scrapes them into Prometheus, so such rules could never fire — worse than no
rule, because the coverage looks complete.

ArgoCD owns this release in the cluster (`argocd/voteball-application.yaml`), so **changes reach the
cluster by committing to `master`**, not by running `helm upgrade` by hand. If you do install manually,
note ArgoCD's `selfHeal` will fight you — concretely, a manual `helm upgrade` now fails with
`conflict with "argocd-controller"` on server-side-apply field ownership. Upgrades go through git.

