# Observability: making the cluster answer questions about itself

Design for *פרויקט גמר — Adding Monitoring & Observability with Prometheus and Grafana*
(`DevOps_on_AWS_Final_Project_Task_5.pdf`, at the repo root).

The brief's organising sentence is its quality bar, not its feature list:

> *איכות: ה-dashboard צריך לענות על שאלה תפעולית. אוסף panels ללא קשר ל-release, למשתמש או לפעולת
> recovery אינו מספיק.*

So the test each piece below has to pass is not "does the metric exist" but **"which question does it
answer, and what do you do when it moves."**

## Problem

`terraform/addon-monitoring.tf` has installed kube-prometheus-stack since the 2026-07-20 EKS
migration, and it works: Prometheus, Grafana, Alertmanager, node-exporter and kube-state-metrics all
run in the `monitoring` namespace, and Alertmanager routes to SNS with a properly-built inhibition
tree. What it monitors is **the platform, and only the platform**.

1. **The application emits nothing.** `prometheus_client` is not a dependency of either service.
   There is no `/metrics` endpoint, no request counter, no latency histogram, and no metric
   describing the one thing this site exists to do — recording a vote. Every alert in
   `charts/voteball/templates/prometheusrule.yaml` is derived from kube-state-metrics, which means
   every one of them describes *Kubernetes' opinion of the pods*, not the application's behaviour.
   That gap has a concrete shape: `/health` is a static response, and the backend's liveness probe is
   a bare `tcpSocket` check, so **the backend can 500 on every single API call while Kubernetes
   reports all pods `Ready` and every existing alert stays silent.**
2. **Nothing scrapes Jenkins.** The `prometheus` plugin is not in `ci/jenkins/plugins.txt`. Queue
   length, executor and agent counts, and build outcomes exist only as HTML in a web UI that no
   history survives — the controller is reclaimed roughly daily by Spot.
3. **No dashboard exists in this repository.** Grafana runs with its bundled kube-prometheus-stack
   dashboards and nothing else. Nothing is authored, reviewed, or recoverable from git.
4. **Prometheus has no disk.** `prometheusSpec.storageSpec` is unset, so the TSDB lives in the pod's
   ephemeral storage with `retention: 6h`. Every Spot reclaim erases it. "The error rate rose at
   14:03" is not a statement this cluster can currently support.
5. **The pipeline never asks whether the release is healthy.** `Jenkinsfile-cd`'s smoke test
   (`scripts/ci/smoke-test.sh`) checks that three URLs return `200`. A release that is up but
   degraded — slow, or erroring on the paths the smoke test does not hit — is promoted, marked good,
   and discovered by visitors.
6. **No SLI, no SLO, no runbook.** The seven existing alert rules carry `summary` and `description`
   but no `runbook_url`, so an SNS email tells the operator what broke and nothing about what to do.

## What already satisfies the brief (do not rebuild these)

Recorded so the implementation plan does not redo solved work:

- **kube-prometheus-stack runs in-cluster** (chart 87.21.0, app v0.92.1), installed as a Terraform
  `helm_release` — the brief's hard condition that Prometheus and Grafana run inside the cluster is
  already met.
- **kube-state-metrics, node-exporter, and kubelet/cAdvisor scraping** are all live, which covers the
  brief's entire Kubernetes metrics row.
- **The unreachable EKS control-plane scrapes are already disabled** (`kubeScheduler`,
  `kubeControllerManager`, `kubeEtcd`, `kubeProxy`), with `kubeApiServer` deliberately left on. This
  is exactly the "no alert that can never fire" discipline the rest of this design extends.
- **Alertmanager already has a real receiver** (SNS via IRSA), a re-created inhibition tree, and
  `Watchdog`/`InfoInhibitor` null-routed.
- **Seven application alert rules exist** and ship through ArgoCD in the app chart, each written
  against a metric this cluster actually exposes.
- **Grafana's admin password is auto-generated into a Kubernetes Secret**, never in git or tfstate.
- The `devops-app` and `ci` namespaces are already **default-deny** with reviewed NetworkPolicies.

## Non-goals

- **No CloudWatch metrics exporter.** RDS connection counts, ALB 5xx and ACM expiry remain
  CloudWatch-only, and the existing comment in `prometheusrule.yaml` explaining why no rule may be
  written against them stays true.
- **No distributed tracing.** Application Signals was deliberately switched off on 2026-08-03 for
  costing $3.00/day (`terraform/addon-cloudwatch.tf`); re-introducing traces under a different name
  would undo a measured decision.
- **No public exposure of Grafana, Prometheus or Alertmanager.** Decided 2026-08-17 — see §3.
- **No multi-window multi-burn-rate SLO alerting.** The brief asks for a *minimal* SLI/SLO. A simple
  window that the repo owner can explain beats a four-window burn-rate lattice that they cannot.

## Design

### 1. Namespace: `monitoring` → `observability`

The brief names the namespace. Only two places in the repo reference the current one
(`terraform/addon-monitoring.tf:10` and the Alertmanager IRSA trust condition at
`terraform/irsa.tf:118`), so the rename is mechanical. Terraform replaces the release; the stack is
down for the length of one apply and loses nothing, because there is no persistent data in it today.

The rename happens **before** the PVC is introduced (§2), so no volume is ever provisioned into a
namespace that is about to disappear.

### 2. Storage: a real disk for Prometheus, none for Grafana

| Component | Storage | Why |
|---|---|---|
| Prometheus | 10Gi EBS gp3 PVC, `retention: 15d`, `retentionSize: 8GiB` | The brief requires a PVC + retention, and history that survives a Spot reclaim is the difference between a graph and an anecdote. |
| Grafana | none | Every dashboard is provisioned from a file in git (§8). A Grafana pod that dies rebuilds itself identically. |
| Alertmanager | none | Only active silences are lost on restart; acceptable for a single operator. |

**Both retention limits are set, not just the time one.** `retention: 15d` bounds age; it does not
bound bytes. If the series count grows — a new exporter, a label that turns out wider than expected —
Prometheus fills the volume and crashes, because time-based retention has no reason to delete data
that is still inside its window. `retentionSize` at roughly 80% of the volume makes whichever limit
binds first do the work, which is the difference between losing the oldest day and losing the pod.

**EBS, not EFS — the opposite of the Jenkins decision, on purpose.** `terraform/addon-efs.tf` chose
EFS for `JENKINS_HOME` because an EBS volume is locked to one Availability Zone and the node group is
100% Spot. That reasoning does not transfer: Prometheus' TSDB is explicitly unsupported on network
filesystems, where its memory-mapped, `fsync`-ordered writes can corrupt the database. The cost of
choosing EBS is accepting the AZ lock-in — if the node holding the volume is reclaimed and the
autoscaler brings its replacement up in the other AZ, the Prometheus pod sits `Pending` until an AZ-a
node exists again. That is tolerable **only because the data is disposable**: 15 days of metrics, not
15 days of votes. The documented recovery is deleting the PVC and losing history, which would be an
unacceptable answer for Jenkins and is a fine one here.

Three mechanical consequences:

- **The EBS CSI driver is not installed.** Only `aws-efs-csi-driver` is (`terraform/addon-efs.tf`).
  EKS has shipped no in-tree EBS provisioner since 1.23, so a PVC today would sit `Pending` forever
  with no error that names the cause. This adds `aws_eks_addon.ebs_csi` plus its IRSA role, mirroring
  the EFS block.
- **The `gp3` StorageClass uses `reclaimPolicy: Delete`**, unlike `efs-sc`'s `Retain`. `Retain` exists
  for Jenkins so build history survives an uninstall; here it would mean a teardown that leaves a
  billed EBS volume behind with nothing in Terraform's records pointing at it.
- **`scripts/destroy.sh` must delete the `observability` PVCs before `terraform destroy`.** A PVC
  created by a StatefulSet's `volumeClaimTemplates` is *not* removed by `helm uninstall` or by
  deleting the StatefulSet — Kubernetes deliberately keeps it. Left alone it becomes an orphaned
  volume that quietly bills forever, and unlike a leftover ENI it blocks nothing, so the teardown
  reports success. This is the same class of silent teardown residue the ENI reaper already exists
  for.

### 3. Where the configuration lives: three homes, along a line this repo already drew

`charts/voteball/templates/prometheusrule.yaml` already argues that alert rules belong in the app
chart, not in Terraform, because "they describe the application, so a threshold change ships with a
normal commit through ArgoCD instead of needing a Terraform apply against billed infrastructure."
This design extends that same boundary rather than inventing a second one.

| Home | Holds | Reaches the cluster by |
|---|---|---|
| `terraform/addon-monitoring.tf` | The stack itself: PVC, retention, resource limits, dashboard sidecar config, Alertmanager→SNS routing | `terraform apply` |
| `charts/voteball` (ArgoCD) | The app's ServiceMonitors, app alert rules, SLO recording rules, the scrape NetworkPolicy | `git push` |
| `charts/observability` (**new**, ArgoCD) | The three dashboards, the Jenkins ServiceMonitor, platform + monitoring-system alerts | `git push` |

The new chart is a **second ArgoCD Application**, which is the cost of this choice: it needs its own
`AppProject` entry, and `scripts/render-argocd-app.sh --check` — which fails on any Application this
repo does not declare — has to learn about it. That friction is acceptable; the alternative, holding
dashboards in Terraform, makes adjusting a graph a billed apply.

`charts/observability` deploys **into the `observability` namespace**, so each ServiceMonitor names
its target namespace explicitly (`namespaceSelector.matchNames: [devops-app]` / `[ci]`). The app's own
ServiceMonitors stay in `charts/voteball` next to the Services they describe, on the same reasoning
that put the alert rules there.

**Every ServiceMonitor and PrometheusRule must carry `release: kube-prometheus-stack`.**
kube-prometheus-stack sets `serviceMonitorSelectorNilUsesHelmValues: true`, so Prometheus ignores any
ServiceMonitor without that label — the object is created, `kubectl get servicemonitors` lists it, and
it is silently never scraped. This is the identical trap the PrometheusRule label already documents,
one kind further along. §11 turns it into a build failure rather than a comment.

### 4. Backend instrumentation

`prometheus_client` is added to `services/backend/requirements.txt`, and a `metrics.py` module holds
the registry, the metric definitions, and the `before_request`/`after_request` hooks. `app.py` gains
one route.

| Metric | Type | Labels | Question it answers |
|---|---|---|---|
| `voteball_http_requests_total` | counter | `method`, `endpoint`, `status` | request rate, 5xx rate, availability |
| `voteball_http_request_duration_seconds` | histogram | `method`, `endpoint` | p50/p95/p99 latency |
| `voteball_app_info` | gauge (`1`) | `version`, `git_sha` | which build is serving right now |
| `voteball_votes_cast_total` | counter | — | **the business metric**: ballots successfully recorded |
| `voteball_votes_rejected_total` | counter | `reason` | ballots refused, by validation rule |
| `voteball_db_errors_total` | counter | `operation` | dependency failures |

Histogram buckets are `.05, .1, .25, .5, 1, 2.5, 5` seconds — chosen around this app's measured
behaviour (the results endpoint measured 1.2s after the 2026-07-21 optimisation, down from 30s), not
copied from a default. A bucket boundary sits exactly on the 1s latency SLO of §9, so the SLO is read
off a real bucket edge rather than interpolated between two distant ones.

**`endpoint` is Flask's URL rule, never the request path.** `/api/admin/clubs/<int:club_id>` is one
series; `/api/admin/clubs/42` would be one per club. The brief bans unbounded-cardinality labels and
names raw URL, user id and request id explicitly; `request.url_rule.rule` is the bounded form, and
requests that match no rule are labelled `unmatched` so a 404 flood cannot mint series either.

**Gunicorn runs 2 workers, so multiprocess mode is mandatory.** Each worker is a separate process with
its own counters, and a scrape is served by whichever one accepts the connection — a naive setup
reports roughly half the traffic and wobbles between scrapes. `prometheus_client`'s multiprocess mode
fixes it by having workers write to a shared directory that `/metrics` sums:

- `PROMETHEUS_MULTIPROC_DIR=/tmp/prom`, created at startup. `/tmp` is already an `emptyDir` mounted
  for gunicorn's `worker_tmp_dir`, so `readOnlyRootFilesystem: true` needs no new exception.
- `gunicorn.conf.py` gains a `child_exit` hook calling `multiprocess.mark_process_dead(worker.pid)`.
  Without it, a departed worker's counters are summed forever and the rate of a dead process reads as
  live traffic.
- `/metrics` builds a fresh `CollectorRegistry` with a `MultiProcessCollector` per request rather than
  using the default global registry.

**`voteball_app_info` must be declared `multiprocess_mode='max'`, and it cannot be an `Info` metric.**
This is the multiprocess trap's second half. A `Gauge` in multiprocess mode defaults to
`multiprocess_mode='all'`, which exports **one series per worker process, labelled by PID** — and PIDs
change on every restart, so the metric introduced to demonstrate disciplined labelling would mint a
new series on every pod restart forever. `'max'` collapses them to one series. `Info` is the natural
type for this and is **unsupported in multiprocess mode entirely** (`prometheus_client` raises), so
the Gauge is not a stylistic choice and must not be "corrected" into an `Info` later.

**The backend Service's port must be given a name (`http`).** It is currently unnamed, and a
ServiceMonitor's `endpoints[].port` refers to the *Service port name* — so a ServiceMonitor written
against the Service as it stands today matches nothing, is created successfully, appears in
`kubectl get servicemonitors`, and never scrapes. Same silent-success failure mode as the missing
`release:` label, one layer down.

`voteball_app_info`'s `git_sha` comes from a new `APP_VERSION` environment variable, set by the chart
from `.Values.image.tag` — which `scripts/sync-values-from-tf.sh` and `Jenkinsfile-cd`'s promote step
already own. That is what makes the brief's defense chain (`commit → CI build → image digest → Pod →
dashboard/alert`) a query rather than a story.

### 5. Worker and frontend instrumentation

The worker has no HTTP server. `prometheus_client.start_http_server(9100)` runs once at startup in a
background thread, and a new ClusterIP Service with a **named** port (`metrics`, per §4's last point)
gives the ServiceMonitor something to select. The worker Deployment must also declare
`containerPort: 9100`, and `worker` must appear in the scrape NetworkPolicy of §7b.

| Metric | Type | Question it answers |
|---|---|---|
| `voteball_worker_recompute_total{result}` | counter | is the rollup loop running, and succeeding |
| `voteball_worker_recompute_duration_seconds` | histogram | is a recompute getting slower as votes accumulate |
| `voteball_worker_last_success_timestamp_seconds` | gauge | **how stale the published results are right now** |
| `voteball_worker_notifications_received_total` | counter | is `LISTEN/NOTIFY` still delivering |

The staleness gauge is the point of this section. The worker is notification-driven with a 30s
polling backstop; if `LISTEN` silently stops delivering *and* the poll loop wedges, the site keeps
serving stale rollups with every pod `Ready` and every existing alert quiet. `time() - gauge` is the
only signal that catches it.

**The frontend gets an `nginx-prometheus-exporter` sidecar**, reading nginx's built-in `stub_status`.
An earlier draft of this design listed it as a non-goal on the grounds that errors originate in the
backend. That reasoning does not survive contact with the failure it matters for: nginx serves the
HTML *and* proxies `/api/*`, so when the frontend is broken, no request ever reaches the backend —
and backend metrics therefore show **nothing**, which on a graph is indistinguishable from a quiet
night. The availability SLI of §9 also claims to measure a user journey, and the honest place to
measure a journey is the edge the user actually arrives at. Cost: one more container per frontend
pod, pinned and Trivy-scanned like every other image, plus its scrape rule.

### 6. Jenkins metrics

Add `prometheus` to `ci/jenkins/plugins.txt`, rebuild the controller image, `terraform apply`. The
plugin serves `/prometheus` on the controller's existing port 8080, giving queue length and wait
time, executor and agent counts, build results/rate/duration, and JVM health.

**This is a platform change, so committing `plugins.txt` alone does nothing** — plugins are baked into
the controller image, and the release is owned by Terraform, not ArgoCD.

### 7. Scrape paths, and NetworkPolicies that say what they mean

Adding a scrape means opening a path into two default-deny namespaces, and doing that honestly first
requires fixing something the audit for this design turned up: **two existing rules are wider than
their own comments.**

The AWS VPC CNI gives every pod a real VPC address, so an `ipBlock` naming the VPC does not mean "the
load balancer" — it means "anything on this network, pods included". The subnet layout is what makes
the fix available:

| Range | Holds |
|---|---|
| `10.0.0.0/20`, `10.0.16.0/20` (public) | ALB network interfaces, NAT gateway — **no pods, ever** |
| `10.0.32.0/20`, `10.0.48.0/20` (private) | every node and every pod |
| `10.0.64.0/24`, `10.0.65.0/24` (database) | RDS |

**(a) Narrow both ALB rules from the VPC to the public subnets.** `charts/voteball`'s
`allow-alb-to-frontend` and `charts/jenkins-support`'s `jenkins-ingress` both admit `10.0.0.0/16` on
8080 to let the load balancer through. Both Ingresses are `scheme: internet-facing` with
`target-type: ip`, so the ALB's interfaces can only ever be in the two public subnets — which contain
no pods. Replacing the one `/16` with those two `/20`s makes each rule mean what its comment already
claims, and incidentally removes the standing ability of any pod in the cluster to reach the Jenkins
controller on 8080.

The two CIDRs are plain values in each chart, not an eleventh field for
`scripts/sync-values-from-tf.sh` to manage: they change only if someone edits `terraform/vpc.tf`, and
a mismatch fails loudly and immediately — the ALB's health checks are dropped and the target group
goes unhealthy — rather than silently. `charts/jenkins-support` already receives `vpcCidr` and
`serviceCidr` from Terraform, so its copy is passed the same way.

**(b) Grant the scrape by name, not by address.** New ingress rules admit
`namespaceSelector: kubernetes.io/metadata.name: observability` to exactly four ports:
`backend:5000`, `worker:9100`, the frontend exporter's `9113` (in `charts/voteball`) and the Jenkins
controller's `8080` (in `charts/jenkins-support`). After (a), this is the *only* thing that lets Prometheus in — the grant is
deliberate and reviewable instead of a side effect of network geography.

**(c) Let the CD monitoring gate read Prometheus, and nothing else.** `jenkins-egress` allows the
internet but excludes the VPC and RFC1918 ranges, precisely so CI can never reach RDS or the app —
which also blocks Prometheus. One targeted egress rule permits `ci` → `observability` on 9090. CD
gains the ability to read metrics and keeps its inability to reach the database or the application.

**(d) `observability` gets its own default-deny.** kube-prometheus-stack supports NetworkPolicies
natively, and without them the new namespace would arrive as the one unrestricted space in a cluster
where every other namespace is locked down. Ingress is limited to Grafana/Prometheus/Alertmanager's
own ports from within the namespace (plus port-forward, which goes through the API server and is not
subject to NetworkPolicy at all).

**Its egress list is the dangerous half, and must be written before the ingress rules feel finished.**
Prometheus needs the four scrape targets *and* the Kubernetes API for service discovery; Grafana
needs Prometheus; and **Alertmanager needs the public internet** — SNS through the NAT gateway, and
STS to assume its IRSA role. Omit that last one and the failure is completely silent: every alert
still evaluates, still fires, still shows as firing in the UI, and no notification is ever delivered.
That is the identical shape of the `allow-app-egress` bug that left the nightly backup broken from
2026-07-19 to 2026-07-31, and it is why the drills of §13 verify that an alert **arrived**, not merely
that it fired.

The end state is that "who may reach what" is one table in which every row names a namespace or the
load balancer, and no row says "the VPC".

`/metrics` needs no authentication because it is unreachable from outside: nginx proxies only
`/api/*`, so the backend's metrics path has no public route at all, and in-cluster only the
`observability` namespace is permitted to it. That satisfies the brief's "separate from
readiness/liveness, exposed only through an approved scrape route" without inventing an auth layer.

### 8. Three dashboards, hand-authored, provisioned from git

Grafana's sidecar container watches for ConfigMaps labelled `grafana_dashboard: "1"` and writes their
contents into its provisioning directory, so a committed JSON file becomes a dashboard with no API
call and no import button. kube-prometheus-stack 87.21.0 already ships
`grafana.sidecar.dashboards.searchNamespace: ALL` as its default (verified against `helm show
values`), so no Terraform override is needed and none should be added — a setting that restates a
default reads like a live tuning knob.

| Dashboard | Operational question |
|---|---|
| **Application Overview** | Is the new release hurting users? Traffic, 5xx rate, p50/p95/p99, availability against SLO, votes cast, and the running `version`/`git_sha`, filterable by service and pod. |
| **Kubernetes / Cluster** | Is the fault in the app or the platform? Node readiness and capacity, pod restarts and OOMKills, CPU throttling, pending pods, desired-vs-available replicas, PVC usage. |
| **Jenkins & Delivery** | Is delivery healthy, and is something stuck? Queue length and wait, executors, dynamic agents, build outcomes and duration, CI/CD failures, last successful release. |

Dashboards are **hand-written against metrics this cluster demonstrably exposes**, not imported from
grafana.com. A 120KB community dashboard cannot be defended panel by panel, and typically half its
queries reference exporters that are not installed — producing empty panels, which is the visual
equivalent of an alert that can never fire.

### 9. SLI/SLO

| SLI | SLO | Where it appears |
|---|---|---|
| Availability | 99% of voting-journey requests (`/api/options`, `/api/vote`, `/api/results`) return non-5xx, over 7 days | recording rule → dashboard panel → `VoteballAvailabilitySLOBreach` |
| Latency | 95% of requests complete under 1s | recording rule → `histogram_quantile` panel → `VoteballHighLatencyP95` |

Both are **recording rules**, not expressions typed into panels, so the dashboard, the alert, the CD
gate and the writeup all cite one definition. The window is 7 days rather than 30 because the cluster
is rebuilt for demonstrations; a 30-day window would be mostly empty and would read as a broken panel.

### 10. Alerts and runbooks

Four domains, eight alerts. The brief's minimum is two application, two Kubernetes, one Jenkins and
one monitoring-system rule. Every rule — including the seven that already exist — gains a
`runbook_url` annotation, and Alertmanager's SNS template already renders
annotations, so the email carries the link.

| Alert | Domain | Fires when | Severity |
|---|---|---|---|
| `VoteballHighErrorRate` | Application | 5xx ratio > 5% for 5m | critical |
| `VoteballHighLatencyP95` | Application | p95 > 1s for 10m | warning |
| `VoteballRollupsStale` | Application | worker's last success > 10m ago | warning |
| `VoteballAvailabilitySLOBreach` | Application | 7-day availability below 99% | warning |
| `VoteballDeploymentDegraded` *(exists)* | Kubernetes | available < desired for 10m | warning |
| `NodeNotReadyOrUnderPressure` | Kubernetes | node not `Ready`, or under memory/disk pressure, for 10m | critical |
| `JenkinsQueueStuck` | Jenkins | queue non-empty with wait > 15m | warning |
| `PrometheusTargetDown` | Monitoring | a declared target `up == 0` for 5m | critical |

App-domain rules live in `charts/voteball`; the Kubernetes, Jenkins and monitoring-system rules live
in `charts/observability`, matching §3's split.

**Every new rule must be checked against the ~100 default rules already running, and the default it
replaces switched off.** `defaultRules.create` is `true` and 30 `PrometheusRule` objects are live in
the cluster right now (counted 2026-08-17), all routed to the same SNS topic. Three of this design's
rules collide with them — `NodeNotReadyOrUnderPressure` with `KubeNodeNotReady`/`KubeNodeUnreachable`,
`PrometheusTargetDown` with `TargetDown` — and one **existing** rule already does:
`VoteballDeploymentDegraded` duplicates `KubeDeploymentReplicasMismatch`, which has been double-paging
since it was written. The chart exposes `defaultRules.disabled` (a map keyed by alert name), so each
condition ends up with exactly one rule: ours, tuned to this cluster, carrying a `runbook_url`.

The rule this expresses is worth stating plainly, because it is not intuitive: **a duplicate alert is
not redundancy, it is noise.** Two emails for one condition train the reader to stop opening them,
which costs more than the second rule ever adds. The same instinct already null-routed `Watchdog` and
set `repeat_interval` to 12h.

Runbooks go in `docs/runbooks/`, one file per alert, each answering four questions: what this means,
what to check first, how to fix it, and when to roll back instead. They are written for the repo
owner at 2am, not for a platform engineer.

### 11. CI: validate observability config, never deploy it

`Jenkinsfile-ci` gains an **Observability validation** stage, extracted into
`scripts/ci/validate-observability.sh` with an offline test, matching the existing rule that every
pipeline decision must be testable without triggering a build:

1. `promtool check rules` against the rendered `PrometheusRule`s (a new `prom/prometheus` container in
   the CI pod template provides `promtool`).
2. Every dashboard JSON parses, and carries a `uid`, a `title`, and at least one panel with a
   non-empty query.
3. **Every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` carries `release: kube-prometheus-stack`.**
   This is the check that pays for the stage: without the label the object is created, looks correct
   in `kubectl get`, and is silently never used.
4. **Every ServiceMonitor's `endpoints[].port` names a port that exists on the Service it selects.**
   Checkable entirely from rendered Helm output, and it catches the unnamed-port failure of §4 before
   it reaches a cluster, where it would present as a healthy object scraping nothing.
5. **No alert name collides with a kube-prometheus-stack default that has not been disabled** (§10),
   so a duplicate paging path fails the build instead of arriving as a second email.

CI still never deploys and still holds no cluster credentials.

### 12. CD: a post-deploy monitoring gate

`Jenkinsfile-cd` gains a **Monitoring gate** stage after the smoke test, implemented as
`scripts/ci/monitoring-gate.sh` (offline-testable via `PROM_STUB_*`, matching
`scripts/tests/test-argocd-sync-wait.sh`). It runs *after* ArgoCD reports Healthy, which means the old
pods are gone and every request it measures is served by the new build — that is what lets the gate
attribute what it sees to this release without per-version metric filtering.

It generates a short burst of real traffic against the public URL, then asks Prometheus three
questions:

| Check | Fails the release when |
|---|---|
| Targets up | any declared target (`backend`, `worker`, `jenkins`) reports `up == 0` |
| Error ratio | 5xx ratio over the gate window exceeds 1% |
| Latency | p95 over the gate window exceeds 1s |

The error threshold is deliberately **tighter** than the `VoteballHighErrorRate` alert's 5%: the gate
controls its own traffic against a freshly-deployed release and expects zero errors, whereas the alert
must tolerate the noise of real internet traffic.

**If fewer than 20 requests were observed and all targets are up, the gate warns and passes.** This
follows directly from the lesson recorded in `2026-08-04-cicd-split-design.md`: anything that can fail
after Promote is a rollback trigger, so a gate that fails on missing data would roll back healthy
releases whenever the metrics pipeline hiccuped. A genuinely broken scrape is caught by the
targets-up check, which does not depend on traffic volume.

On failure the release is not marked good, and the existing rollback path
(`scripts/ci/rollback-target.sh`, bounded by `ROLLBACK_DEPTH`) takes over.

### 13. Four failure drills

The brief requires drills with evidence, not screenshots of a healthy system.

| Drill | Mechanism | What it proves |
|---|---|---|
| **Controlled 5xx** | Remove the RDS egress rule from `allow-app-egress` for a short announced window (ArgoCD auto-sync paused), then re-enable self-heal | Pods stay `Ready` while every API call 500s. The error-rate metric, the dashboard and `VoteballHighErrorRate` catch what pod health structurally cannot — and **GitOps performs the recovery** |
| **Pod readiness failure** | Delete one backend pod (2 replicas + PDB) | Restart and rollout metrics move; service availability never dips |
| **Jenkins agent loss** | Kill an agent pod mid-build | Queue and agent metrics move, `JenkinsQueueStuck` fires, the website is untouched |
| **Failed release** | Deploy a build that is **slow, not broken** | The smoke test passes — it checks for `200` — and the **monitoring gate** is what fails the release, triggering rollback |

The fourth drill is designed around a specific distinction: an erroring build would be caught by the
existing smoke test and would prove nothing new. A build that returns correct responses 1.5s too
slowly is invisible to every check that existed before this design, which is precisely the case the
gate is for.

The first drill is the only one that affects the live site, and it is the one the repo owner
explicitly approved on 2026-08-17 in preference to an admin-gated error-injection endpoint — real 5xx
on real pods, exercising the whole chain through to the SNS email, over a simulation.

**Its mechanism must not restart a pod, and the obvious mechanism does.** An earlier draft broke the
database by pointing `DB_HOST` at a dead host. That does not work, and it fails in the most misleading
possible direction: `gunicorn.conf.py`'s `on_starting` hook runs `db.init_db()` in the master process
*before workers fork*, so a new pod with a bad `DB_HOST` never boots. The rollout stalls, the **old
healthy pods keep serving**, the site stays up, no error metric moves, and the alert that eventually
fires is `VoteballPodCrashLooping` — a different scenario, already covered, proving nothing about
application-level observability.

Withdrawing the RDS egress rule instead leaves every running pod running: `/health` still returns its
static 200, the `tcpSocket` liveness probe still passes, and every API call fails because
`db.get_db()` opens a fresh connection per request. That is the exact state this design exists to make
visible. Two practical notes: the CNI's fail-open window means the break can take up to ~30 seconds to
take effect (harmless inside a 10-minute window, but do not conclude from the first few seconds that
the drill failed), and recovery is performed by re-enabling ArgoCD self-heal rather than by hand — the
recovery *is* part of the evidence.

### 14. Deliverables

- Helm values for Prometheus/Grafana/Alertmanager with resources, PVC and retention →
  `terraform/addon-monitoring.tf`
- ServiceMonitors for the application and Jenkins → `charts/voteball`, `charts/observability`
- PrometheusRules for all alerts → both charts, per §10
- Three provisioned dashboard JSONs → `charts/observability`
- Instrumentation code and the PromQL behind each SLI/SLO → `services/{backend,worker}`, §9, plus the
  frontend's `nginx-prometheus-exporter` sidecar → `charts/voteball`
- NetworkPolicy tightening and the scrape grants → `charts/voteball`, `charts/jenkins-support`,
  `charts/observability` (§7)
- Runbooks → `docs/runbooks/`
- Evidence: targets UP, dashboards, alerts firing and resolved, all four drills →
  `docs/eks/evidence/2026-08-17-*`
- Updated architecture diagram and README (install, verify, troubleshoot) → `docs/eks/architecture.md`,
  `README.submission.md`

## Verification

Offline, before anything is applied:

- `pytest` in `services/backend` and `services/worker`, including new tests asserting the metric
  names, the bounded `endpoint` label, and multiprocess aggregation across two workers
- `helm template` and `helm lint` for both charts
- `scripts/ci/validate-observability.sh` against the rendered output
- `scripts/tests/run-ci-suite.sh` — the new tests must be assigned to `PYTHON_GROUP` or `GIT_GROUP`,
  which the suite enforces
- `terraform fmt -recursive` and `terraform validate`

Live, after apply:

- Every declared target `UP` in Prometheus, verified by query rather than by eye
- Each of the three dashboards rendering with non-empty panels
- Each alert forced to fire once and observed **arriving** at SNS, not merely firing — §7d is the
  reason those are different claims
- **Every ServiceMonitor resolves to at least one live target.** A zero-target ServiceMonitor is what
  a mis-named Service port and a missing `release:` label both look like, and both look healthy in
  `kubectl get`
- **A negative network test for §7(a)**: a pod in `devops-app` must fail to reach the Jenkins
  controller on 8080, where today it succeeds. Per `charts/voteball/CLAUDE.md`, the CNI fails *open*
  for the first seconds of a pod's life, so the test pod must sleep at least a minute before opening
  the socket — otherwise a denial and a not-yet-programmed policy look identical
- The four drills of §13, captured as evidence
- A **fresh-install proof**: delete the `charts/observability` Application, re-sync, and confirm the
  dashboards return — the brief's "prove a clean installation" requirement, and the thing that
  distinguishes provisioned dashboards from ones somebody clicked together

## Risks

1. **The AZ lock-in of the Prometheus PVC** (§2). Mitigated by disposability, documented in the
   runbook, and visible as `PrometheusTargetDown` if it ever strands.
2. **The 5xx drill affects the live site** for its announced window. Bounded by pausing ArgoCD
   auto-sync for the window only, and recovered by re-enabling it. The mechanism is deliberately the
   one that leaves pods running (§13) — a mechanism that restarts them produces a stalled rollout and
   no outage at all.
3. **The monitoring gate can roll back a healthy release** if its thresholds are wrong. Mitigated by
   the ≥20-sample rule, by thresholds set from measured behaviour rather than guessed, and by the
   bounded `ROLLBACK_DEPTH` that already exists.
4. **Node memory pressure.** Prometheus already has a 900Mi limit on a two-node t3.large group also
   running ArgoCD, Jenkins and the app. Longer retention increases resident memory; the limit stays,
   and Cluster Autoscaler adds a node if the scheduler needs one.
5. **Cardinality growth.** Bounded by construction today, but a future route added with a raw path
   label would not fail any test. The `endpoint`-label rule is stated in `services/backend/CLAUDE.md`
   as part of this work.

## Decisions taken (2026-08-17)

1. **Namespace renamed to `observability`** — the brief names it, and only two references exist.
2. **Grafana, Prometheus and Alertmanager stay ClusterIP**, reached by `kubectl port-forward`. The
   repo owner chose this over a public `grafana.<domain>` host on the existing shared ALB. Nothing new
   faces the internet, which makes the security section a short paragraph rather than a defence.
3. **EBS for Prometheus, EFS for Jenkins** — opposite choices from the same constraint, for the
   reasons in §2. Recorded together so neither is later "made consistent" with the other.
4. **The 5xx drill breaks the real site briefly** rather than using an admin-gated injection endpoint,
   chosen by the repo owner for honesty of evidence.
5. **A second ArgoCD Application** rather than holding dashboards in Terraform, so a dashboard change
   is a git push and not a billed apply.
6. **The gate passes on insufficient data.** Never roll back a healthy release for lack of
   measurement; the targets-up check covers the case where measurement itself is broken.
7. **Both ALB NetworkPolicy rules narrow from the VPC to the public subnets**, and the Prometheus
   scrape is granted by namespace label rather than inherited from an address range (§7a, §7b). Raised
   by the repo owner on reviewing the design: an access path that exists by accident cannot be
   explained, and this one had a pod-to-Jenkins route nobody intended. The namespace *layout* is
   unchanged — it was already clean; what changes is that each rule now names its intent.
8. **The `observability` namespace ships default-deny from the start** (§7d), so the namespace added by
   this design does not become the one permissive space in the cluster.
9. **The frontend gets an nginx exporter after all** (§5), reversing this design's own first draft. The
   brief asks for a monitor per application service, and the case for skipping it was weaker than it
   read: a frontend outage makes backend metrics go *quiet*, which looks like low traffic rather than
   an outage.
10. **One rule per condition** (§10): every default alert this design replaces is switched off through
    `defaultRules.disabled`, rather than left to page alongside its replacement.

## Audit note (2026-08-17)

Sections 2, 4, 5, 7d, 8, 10 and 13 were revised after a review pass over the first draft, prompted by
the repo owner asking whether anything else deserved the treatment §7 got. Six of the seven findings
shared one signature — **the failure is silent and looks like success**: a drill that proves nothing,
a ServiceMonitor that scrapes nothing, a metric that grows unbounded, an alert that fires but never
arrives, a disk limit that does not bind, a config line that restates a default. That signature is the
thing to hunt for when reviewing the implementation, and it is why as many of these as possible become
CI checks (§11) rather than sentences in this document.
