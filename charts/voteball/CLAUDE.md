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

**All three Deployments carry startup, readiness and liveness probes, and the three are sized
independently on purpose — do not normalise them.** Four rules that are not obvious from reading the
YAML:

- **Never re-add `initialDelaySeconds` to a readiness or liveness probe here.** A startup probe
  *suppresses* both — neither is scheduled until it passes — so an initial delay on them is dead
  config that reads like a live tuning knob. The boot window is owned entirely by
  `failureThreshold × periodSeconds` on the startup probe, and that product is a hard wall: exceed it
  and the kubelet kills the container with 10s→5min backoff.
- **Liveness on frontend/backend is a `tcpSocket` check, deliberately weaker than readiness.** Don't
  "improve" it to hit `/health`. Readiness going false removes one pod from the Service; liveness
  going false *kills* it, so a liveness probe that touched the database would turn one RDS blip into
  a simultaneous crash loop across every replica. For the same reason `/health` itself must stay a
  static response that opens no connection.
- **The worker's 120s staleness threshold lives inside the `test` expression, not the schedule.** Its
  probes only begin failing once `/tmp/heartbeat` is already 120s stale, so the real time-to-kill is
  120s + `failureThreshold × periodSeconds` ≈ 3.5 min — not the 90s the schedule suggests. Budget
  from the sum, and remember all three probes `stat` that path independently (see
  `docs/eks/ro-fs-writable-paths.md`).
- **The worker's probes set `timeoutSeconds: 3`, not the default 1.** Each forks `sh` + `date` +
  `stat`, and an exec probe that times out counts as a **failure** — on a CPU-throttled Spot node the
  default would kill a perfectly healthy worker for being slow to fork.

The per-workload numbers and the reasoning behind each are in `docs/eks/architecture.md` §2
("Health checking"); `docs/eks/live-cluster-snapshot.md` shows the *pre-2026-08-06* probe config and
is frozen evidence — don't "correct" it.

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

**`_helpers.tpl` output may never reach a `selector`, and never a pod template's labels.** A
Deployment's `spec.selector.matchLabels` is immutable after creation: route a helper into it and the
next chart-version bump changes the rendered label, ArgoCD's sync fails with a field-immutable error
rather than rolling, and the only fix is deleting the Deployment in production. The same helper in a
pod template would silently roll every replica on each version bump. So `voteball.labels` is applied
to **object** metadata only, and the selectors stay the plain literal `app: <component>`. The way to
prove a helper change is safe is `helm template` before and after, diffed — a pure refactor
(`voteball.image` was one) shows *no* diff at all.

**Alert rules must carry `release: kube-prometheus-stack`.** Without that label the PrometheusRule is
created, looks correct in `kubectl get prometheusrules`, and is silently never evaluated. Only write
rules against metrics this cluster actually exposes (kube-state-metrics): RDS, ALB and ACM figures are
CloudWatch-only and nothing scrapes them into Prometheus, so such rules could never fire — worse than no
rule, because the coverage looks complete.

ArgoCD owns this release in the cluster (`argocd/voteball-application.yaml.tmpl`, rendered by
`scripts/render-argocd-app.sh` — do not `kubectl apply` the template directly), so **changes reach the
cluster by committing to `master`**, not by running `helm upgrade` by hand. If you do install manually,
note ArgoCD's `selfHeal` will fight you — concretely, a manual `helm upgrade` of a chart that
**differs** from `master` fails with `conflict with "argocd-controller"` on server-side-apply field
ownership. Upgrades go through git.

**Never write an empty list literal (`to: []`, `imagePullSecrets: []`) in a template.** The API server
drops it on write, so the value Helm applies can never equal the value stored — and since both Helm
(`deploy.sh` step 10) and ArgoCD apply this chart server-side, that mismatch conflicts against
whichever manager owns the field on *every* upgrade, even though the chart is otherwise identical.
One `- to: []` in `allow-dns-egress` failed a deploy this way on 2026-08-10. An omitted field and an
empty list mean the same thing to Kubernetes here, so omit it; an empty **map** (`podSelector: {}`) is
meaningful, is preserved, and is fine. `scripts/ci/validate-repo.sh` gates this in CI.

**Adding a CLUSTER-SCOPED resource to this chart takes two commits, not one.** Since 2026-08-03 the
Application runs in the `voteball` AppProject, whose `clusterResourceWhitelist` is empty — every kind
this chart renders today is namespaced, so nothing cluster-scoped is permitted. Add a `ClusterRole`,
`ClusterRoleBinding`, `CRD` or `StorageClass` and the chart still lints, still templates, and ArgoCD
refuses the sync with `resource ... is not permitted in project voteball` — an error that reads like an
ArgoCD fault rather than a missing whitelist entry. Whitelist the kind in
`argocd/voteball-application.yaml.tmpl` first. That friction is the point: cluster scope should be a
deliberate, reviewable act.

