# Monitoring & observability

How this project answers three questions — *is the new release hurting users?*, *is the fault in the
app or the platform?*, *is delivery healthy?* — and what to do when the answer is bad.

This is the **operational reference**: what exists, how to reach it, how to verify it, how to fix it.
Two neighbouring documents deliberately hold other things, and neither is a duplicate of this one:

- **Why it is shaped this way** — [`docs/design/2026-08-17-observability-design.md`](design/2026-08-17-observability-design.md).
  A dated design record, including a "Verification outcome" section describing what broke when the
  design met reality. It is **not** updated as the system changes; it says what was decided then.
- **What to do when a specific alert fires** — [`docs/runbooks/`](runbooks/), one file per alert.
  Alertmanager puts the link in the email.

The course requirement this satisfies is *DevOps on AWS — Final Project, Task 5* (`DevOps_on_AWS_Final_Project_Task_5.pdf`
at the repo root). [`README.submission.md` § Task 5](../README.submission.md#task-5--monitoring--observability)
is the graded standalone answer; this document is the depth behind it.

---

## 1. The short version

Nothing here is polled by a human. Every layer emits, Prometheus scrapes, rules evaluate, and
Alertmanager mails a person only when something is worth interrupting them for.

```
 EMITTERS                     SCRAPE / SHIP            STORE + EVALUATE        REACH A HUMAN
 ─────────────────────────    ─────────────────────    ────────────────────    ─────────────────
 backend    /metrics :5000  ┐
 worker     /metrics :9100  ├─ ServiceMonitor ────┐
 frontend   nginx exp :9113 ┘  (charts/voteball)  │
                                                  │
 kube-state-metrics         ┐                     ├─► Prometheus ──► recording rules (4 SLIs)
 node-exporter              ├─ bundled with       │   10Gi gp3 PVC   alert rules   (16 alerts)
 kubelet / cAdvisor         │  kube-prometheus-   │   15d / 8GiB           │
 kube-apiserver             ┘  stack              │                        │
                                                  │                        ▼
 Jenkins /prometheus :8080 ─── ServiceMonitor ────┘                  Alertmanager
                               (charts/jenkins-support)                     │
                                                                            ├─► SNS ─► email
 pod stdout/stderr ─────────── Fluent Bit ──► CloudWatch Logs                │
 (devops-app only)                            7-day retention               ▼
                                                                        Grafana
                                                                    4 dashboards
                                                                     (port-forward)
```

Two things in that picture are easy to miss and both are load-bearing:

- **A synthetic canary pod** hits the real public site every 30 seconds. It is not a test — it is what
  guarantees the availability ratio has a denominator. See §7.
- **CloudWatch carries logs only.** It is not a second metrics system here, and the parts of it that
  *would* be are deliberately switched off because they are metered. See §9.

---

## 2. Where the configuration lives

The PDF's rule is *"a dashboard, alert or datasource created by hand in the UI does not count as a
deliverable."* This repo makes that structural rather than a promise: **there is no UI path.** Grafana
has no persistent storage, so anything clicked into it is gone at the next pod restart — which on a
100% Spot node group is roughly daily.

Three homes, and which one a change belongs in decides whether it ships as a commit or as a billed
`terraform apply`:

| Home | Holds | Reaches the cluster by |
|---|---|---|
| `terraform/addon-monitoring.tf` | The stack itself: the Helm release, PVC, retention, resource limits, Alertmanager→SNS routing, the disabled-defaults list | `terraform apply` |
| `charts/voteball` (ArgoCD) | The app's three ServiceMonitors, the 12 application alerts, the 4 SLI recording rules, the scrape NetworkPolicy, the canary | `git push` |
| `charts/observability` (ArgoCD, a **second** Application with its own AppProject) | The 4 dashboards, the 4 platform alerts, that namespace's default-deny NetworkPolicies | `git push` |
| `charts/jenkins-support` (Terraform) | The Jenkins ServiceMonitor — the one exception, see §4 | `terraform apply` |
| `terraform/addon-cloudwatch.tf` | Fluent Bit's log pipeline and the three log groups | `terraform apply` |

The split is the same boundary this repo draws everywhere: **the platform arrives by `terraform apply`,
the configuration on top of it by `git push`.** A threshold change or a new dashboard is a normal
commit — nobody should have to run Terraform against billed infrastructure to move an alert from 5% to
6%.

`charts/observability` is a second ArgoCD Application because it targets a different namespace, and
the `voteball` AppProject pins its destination namespace on purpose. Both Applications are declared in
`argocd/voteball-application.yaml.tmpl`; `./scripts/render-argocd-app.sh --check` fails if anything in
the cluster disagrees with that file.

---

## 3. The stack itself

`kube-prometheus-stack` (chart `87.21.0`, prometheus-community) in namespace **`observability`**,
installed as `helm_release.kube_prometheus_stack`. It brings Prometheus, Grafana, Alertmanager,
kube-state-metrics and node-exporter in one release.

### Storage and retention

| Setting | Value | Why it is that value |
|---|---|---|
| PVC | 10Gi, `gp3`, `ReadWriteOnce` | A real disk, so history survives the roughly-daily Spot reclaim. Without it *"the error rate rose at 14:03"* is not a statement this Prometheus could support. |
| `retention` | `15d` | Time-based limit. |
| `retentionSize` | `8GiB` | Byte-based limit, ~80% of the volume. **Both are set on purpose.** Time-based retention alone has no reason to delete anything still inside its window, so a growing series count fills the disk and Prometheus *crashes* rather than dropping old data. Whichever limit binds first does the work. |
| memory | request `400Mi`, limit `900Mi` | Keeps the two-node Spot RAM budget sane. |

**What it actually consumes**, as opposed to what it is allowed to: the capture script reports both,
so the number is measured rather than estimated. On the 2026-08-24 cluster, a few hours in, the PVC
was at **0.19% of 10Gi** with no compacted blocks on disk yet
([`2026-08-24-observability-post-dns-fix.txt`](eks/evidence/2026-08-24-observability-post-dns-fix.txt)
section 1). That is the shape to expect here: this stack is destroyed and rebuilt often enough that
Prometheus rarely lives long enough to approach either limit, which is exactly why `retentionSize`
matters anyway — the one time it does approach them, the failure without it is a crash, not a
trim.

**Grafana has no PVC at all, deliberately.** Dashboards come from git; a disk would only preserve
hand-made ones, which is precisely the thing that must not survive.

**The Prometheus PVC is a StatefulSet `volumeClaimTemplate`, which means `helm uninstall` does not
delete it.** `scripts/destroy.sh` deletes it explicitly. Left behind, it is a billed EBS volume that
belongs to no stack.

### Scrape targets switched off

EKS runs the scheduler, controller-manager, etcd and kube-proxy on AWS-managed infrastructure
Prometheus cannot reach. Scraping them yields nothing but a permanently-firing `KubeSchedulerDown` /
`KubeControllerManagerDown` / etcd / `KubeProxyDown`. Each is disabled in `addon-monitoring.tf`, which
drops both the unreachable ServiceMonitor **and** its `*Down` rule — the chart gates the rule file on
the same flag.

`kubeApiServer` is deliberately **left enabled**: its metrics *are* exposed on EKS, and its recording
rules feed real dashboards.

### Default alert rules switched off

Five kube-prometheus-stack defaults are disabled by name, each replaced by a rule in
`charts/observability` that is tuned to this cluster and carries a `runbook_url`:

| Disabled default | Replaced by |
|---|---|
| `KubeNodeNotReady`, `KubeNodeUnreachable`, `KubeNodePressure` | `NodeNotReadyOrUnderPressure` |
| `KubeDeploymentReplicasMismatch` | `DeploymentReplicasMismatch` |
| `TargetDown` | `PrometheusTargetDown` |

A duplicate alert is not redundancy — it is two emails about one problem, which trains the reader to
stop opening them. Note that **Alertmanager's inhibit rules key on `equal: [namespace, alertname]`**,
so a replacement rule never inhibits the default it replaces; they must be disabled, not merely
out-tuned. `NodeNotReadyOrUnderPressure` must keep covering `PIDPressure` for the same reason —
`KubeNodePressure` covered it, and disabling that default without matching the condition set drops
PID-pressure coverage silently.

---

## 4. What is scraped

Three layers, and one of them exists because of a specific failure mode.

### Application (`charts/voteball/templates/servicemonitor.yaml`)

| Component | Port name | Port | Path | Interval |
|---|---|---|---|---|
| backend | `http` | 5000 | `/metrics` | 30s |
| worker | `metrics` | 9100 | `/metrics` | 30s |
| frontend | `metrics` | 9113 | `/metrics` | 30s |

The frontend's metrics come from an **`nginx-prometheus-exporter` sidecar**, added for a reason worth
stating: *a broken frontend makes backend metrics go quiet rather than red.* Zero requests reaching the
backend is indistinguishable from a slow night unless something is watching the edge the user actually
hits.

One ServiceMonitor per component rather than one with three selectors, so each carries its own path and
interval and a broken one takes only itself down.

### Kubernetes

kube-state-metrics, node-exporter and kubelet/cAdvisor, all shipped with kube-prometheus-stack.
Nothing in this repo configures them beyond where they persist to and who may reach them.

### Jenkins (`charts/jenkins-support/templates/servicemonitor.yaml`)

The `prometheus` plugin serves `/prometheus` on the controller's existing port 8080.

**Turning this on is a platform change with two moving parts, not a chart flag.** The plugin is baked
into the controller *image* (`ci/jenkins/plugins.txt` → an image rebuild), and the ServiceMonitor is
gated on `serviceMonitor.enabled`, which Terraform flips to `true` only once `jenkins_image_tag` (in
the gitignored `terraform/voteball.tfvars`) points at an image that actually contains `prometheus.jpi`.
Committing `plugins.txt` alone changes nothing. Enabling the flag ahead of the image would page
`PrometheusTargetDown` every scrape, forever, for a target nobody can fix without a separate build.

The ServiceMonitor lives in `charts/jenkins-support` rather than `charts/observability` because it
deploys with the release it scrapes.

### Two traps that make a ServiceMonitor silently do nothing

1. **Every ServiceMonitor and PrometheusRule must carry `release: kube-prometheus-stack`.** The chart
   sets `serviceMonitorSelectorNilUsesHelmValues=true` / `ruleSelectorNilUsesHelmValues=true`, so
   Prometheus only picks up objects bearing its release label. Without it the object is created,
   `kubectl get servicemonitors` lists it looking perfectly correct, and it is never scraped.
2. **`port:` names a Service port *name*, never a number.** A typo yields a monitor with zero targets,
   which looks identical to a healthy one.

Both are checked by CI — see §10.

### `honorLabels: true`, on the backend only

prometheus-operator attaches its own *target* label named `endpoint`, taken from the Service port
name. Without `honorLabels`, that target label wins over the application's own `endpoint` label (the
route, e.g. `/api/vote`); the app's value is renamed `exported_endpoint` and every series collapses
onto one `endpoint="http"`.

That silently emptied every rule filtering on `endpoint=~"/api/..."` — which is all four SLIs and every
alert built on them. **It shipped on 2026-08-18, and a total outage would have rendered as a green
100%.** CI now fails the build on the collision.

It is deliberately **not** added to worker or frontend: the worker emits no `endpoint` label at all,
and the nginx exporter's `endpoint` label is one in name only (it means "scrape endpoint config", not
an HTTP route) — honouring it would relabel the wrong thing.

### The scrape path through NetworkPolicy

Every namespace here is default-deny. `allow-prometheus-scrape` in `charts/voteball` grants the
`observability` namespace ingress **by name**, on exactly the three metrics ports (5000, 9100, 9113)
and nothing else.

`charts/observability/templates/networkpolicy.yaml` closes the other side. Two things in it fail in
delayed, confusing ways:

- **The AWS VPC CNI evaluates egress policy pre-DNAT** — against the ClusterIP the client dialled, not
  the pod IP the Service routes to. So every ClusterIP the namespace's own components talk to each
  other on needs its own port listed: 443 (API server), 9090 (Prometheus), 9093 (Alertmanager), 3000
  (Grafana). Restricting it to 443 left Grafana's datasource health check timing out with every panel
  erroring.
- **The SNS/STS egress rule is load-bearing.** Alertmanager assumes its IRSA role via STS and publishes
  to SNS over the public internet through the NAT gateway. Remove it and alerts fire forever and are
  never delivered — the exact failure this whole design exists to avoid, in the component that exists
  to avoid it.

NetworkPolicy does not sever established connections, so a mistake in either only breaks *reconnects* —
which is why a target-count check run immediately after applying shows everything healthy.

`kubectl port-forward` goes through the API server and is not subject to NetworkPolicy at all, so
locking ingress down does not lock the operator out.

---

## 5. Instrumentation

`/metrics` is a **separate endpoint from the health probes**, as the PDF requires: readiness hits
`/health` (a static JSON response touching no database), liveness is a bare TCP check, and neither is
the scrape path.

### Backend (`services/backend/metrics.py`)

| Metric | Type | Labels |
|---|---|---|
| `voteball_http_requests_total` | Counter | `method`, `endpoint`, `status` |
| `voteball_http_request_duration_seconds` | Histogram | `method`, `endpoint` |
| `voteball_votes_cast_total` | Counter | — |
| `voteball_votes_rejected_total` | Counter | `reason` |
| `voteball_db_errors_total` | Counter | `operation` |
| `voteball_app_info` | Gauge (always 1) | `version`, `git_sha`, `release` |

`voteball_votes_cast_total` is the PDF's required **business metric** — the action this site exists
for, not a technical proxy for it.

Three properties that cost real debugging time if changed:

- **Multiprocess mode is mandatory.** gunicorn runs 2 workers per pod, each a separate process with
  its own counters, and a scrape is served by whichever accepts the connection. Without multiprocess
  mode a counter alternates between two independently-resetting series — and a non-monotonic series is
  what `rate()` reads as a repeated counter reset, producing wildly inflated rates rather than merely
  under-counted ones. Wrong in a plausible way, which is the worst kind.
- **Histogram bucket `1.0` is the latency SLO boundary and must stay a real bucket edge.** Remove it
  and `histogram_quantile` interpolates the SLO between 0.5 and 2.5, reporting a number nothing
  measured.
- **Every label has a bounded value set.** `endpoint` is Flask's URL *rule*, not the request path —
  `/api/admin/clubs/<int:club_id>` is one series where `/api/admin/clubs/42` would be one series per
  club. Requests matching no rule collapse to `unmatched`, so a 404 flood cannot mint series either.
  **Never add a label carrying a user id, a request id, or a raw URL.**

`voteball_app_info` is a Gauge with `multiprocess_mode='max'` rather than an Info/Enum — those are
unsupported in multiprocess mode, and the default `'all'` would label each series with the worker's
PID, which changes on every restart.

**Of its three labels only `release` is not a duplicate.** `version` and `git_sha` are both the image
tag, which this project sets to the short git SHA, so they carry the same value by construction.
`release` comes from `APP_RELEASE`, which `backend-deployment.yaml` fills with the image **digest**
when `image.digests.backend` is pinned and the tag when it is not — deliberately mirroring
`voteball.image`'s own fallback, because if the two ever diverged the metric would describe a
different artefact than the container it came from. The tag is a label a human chose; the digest is
what the container runtime actually resolved, and it is what the Application Overview's `Release`
variable groups by.

### Worker (`services/worker/metrics.py`)

| Metric | Type | Labels |
|---|---|---|
| `voteball_worker_recompute_total` | Counter | `result` |
| `voteball_worker_recompute_duration_seconds` | Histogram | — |
| `voteball_worker_last_success_timestamp_seconds` | Gauge | — |
| `voteball_worker_notifications_received_total` | Counter | — |

`voteball_worker_last_success_timestamp_seconds` is the one signal in this system built on **elapsed
time rather than counted events**, and that turned out to matter: during the 2026-08-18 outage drill it
was the only alert that fired, because a signal built on counting events needs events to count and
degrades into silence exactly when it matters most.

### Frontend

`nginx/nginx-prometheus-exporter:1.5.3` as a sidecar, reading nginx's `stub_status` and serving
`nginx_*` on 9113.

---

## 6. Dashboards

Grafana's sidecar watches for ConfigMaps labelled `grafana_dashboard: "1"`. `charts/observability`
renders one per JSON file under `dashboards/` via `.Files.Glob`, so **adding a dashboard is adding a
file** — no API call, no import button, nothing for a human to click. Do not add a per-dashboard
template.

| Dashboard | uid | Panels | Answers |
|---|---|---|---|
| Application Overview | `voteball-app` | 14 | Is the new release hurting users? Request rate, 5xx rate, availability vs SLO, p95 vs SLO, p50/p95/p99, votes cast, results freshness, ballots rejected by reason, DB errors, nginx rate, running `version`/`git_sha`/`release`, request rate **by release**, container CPU and memory. |
| Kubernetes / Cluster | `voteball-k8s` | 10 | Is the fault in the app or the platform? Nodes ready, pending pods, node CPU/memory, pods by phase, desired vs available replicas, pod restarts, OOMKills, CPU throttling, PVC usage. |
| Jenkins & Delivery | `voteball-delivery` | 8 | Is delivery healthy and is something stuck? Queue length and wait, executors total vs busy, online agents, build outcomes, build duration, controller JVM heap, last successful release. |
| Service Health & Alerts | `voteball-alerts` | 10 | Is anything wrong right now, and would I have been told? Critical/warning/pending alert counts, a table of what's firing, availability vs 99% SLO, p95 vs 1s SLO, the canary's journey request and error rate, a 6h alert-firing history from Prometheus' `ALERTS` series, and an Alertmanager panel covering grouping/silences/inhibition — what Prometheus' history can't show. |

Deleting the `observability` ArgoCD Application and re-syncing brings all four back with zero manual
steps. That round trip is what proves they are provisioned rather than clicked together.

**The Service Health & Alerts dashboard's Alertmanager panel is text, not a live query, and that is a
deliberate, verified limitation, not an oversight.** Grafana's built-in `alertmanager` data source
(uid `alertmanager`, provisioned by kube-prometheus-stack since the stack's first deploy and unused by
any panel until this dashboard) cannot be queried from a dashboard panel — its `query()` method is a
stub that unconditionally returns empty data (confirmed against Grafana 13.1.1's own source,
`public/app/plugins/datasource/alertmanager/DataSource.ts`), and the core Alert List panel's
"Alertmanager" picker offers only Grafana-managed alert-forwarding targets, not a data source of this
plugin type (`grafana/grafana#108531`, closed *not planned*). Only Grafana's own **Alerting →
Alertmanager** page reaches it, via a resource-proxy call the panel query model does not expose. The
panel still carries `"datasource": {"type": "alertmanager", "uid": "alertmanager"}` — so the uid is no
longer provisioned-and-unreferenced — and its markdown body says exactly where to look instead:
**Alerting → Alertmanager**, picking **Alertmanager** from the data source selector at the top, which
shows real grouping, silences and the notification-policy tree.

Rendered captures, with live data, live alongside the text evidence:
[`2026-08-24-grafana-application-overview.png`](eks/evidence/2026-08-24-grafana-application-overview.png),
[`-kubernetes-cluster.png`](eks/evidence/2026-08-24-grafana-kubernetes-cluster.png),
[`-jenkins-delivery.png`](eks/evidence/2026-08-24-grafana-jenkins-delivery.png). They are the weaker
half of the proof and are kept anyway: section 7 of
[`2026-08-24-observability-post-dns-fix.txt`](eks/evidence/2026-08-24-observability-post-dns-fix.txt)
runs **every panel's own query** and records the series count, which proves a panel *can* query rather
than showing what it drew at one instant. A screenshot cannot tell you a panel is about to go blank;
the query count can.

**Application Overview carries three template variables — `Service`, `Pod` and `Release` — and one
class of panel deliberately ignores them.** The per-pod panels (request rate, 5xx, latency
histogram, votes, rejections, DB errors, nginx, CPU, memory) filter on `$pod`, so a single misbehaving
replica can be isolated without leaving the dashboard. The two SLO panels (`Availability vs SLO`,
`p95 vs 1s SLO`) read recording rules and are **not** filtered: the SLO is defined service-wide, and a
pod filter on them would report one replica's availability under a panel titled "vs SLO" — a wrong
number under a right label, which is worse than no number.

`Release` works through a join, because a request counter has no release label of its own:

```promql
sum by (release) (
  rate(voteball_http_requests_total{namespace="devops-app",pod=~"$pod"}[5m])
  * on (namespace, pod) group_left (release) voteball_app_info{namespace="devops-app",release=~"$release"}
)
```

That join lives in its own panel (`Request rate by release`) rather than in the headline `Request
rate` panel, and that separation is deliberate: a panel whose query depends on `voteball_app_info`
goes **blank** rather than red if app_info ever stops being scraped, and a blank traffic panel reads
as "quiet" instead of "broken". The headline panels stay on the raw counter for that reason.

**Jenkins exposes two metric families that are not interchangeable, and picking the wrong one shows a
flat, healthy-looking zero.** The bundled Metrics plugin's `jenkins_*_value` gauges read `0` almost all
the time on this cluster — truthfully, since the Kubernetes cloud provisions agents on demand and
nothing sits queued or connected between builds — while the `prometheus` plugin's own
`default_jenkins_builds_*` family carries real data over the same window. Verify which family a metric
belongs to by querying it live, never by guessing from the name. This has been gotten wrong once
already.

---

## 7. SLI / SLO

Four recording rules, in the `voteball.sli` group of `charts/voteball/templates/prometheusrule.yaml`.
Computing them once and referencing them everywhere means the dashboard panel, the alert, the CD gate
and this document all read the same definition.

| Rule | Expression (shortened) |
|---|---|
| `voteball:journey_requests:rate5m` | `sum(rate(voteball_http_requests_total{endpoint=~"/api/(options\|vote\|results.*)"}[5m]))` |
| `voteball:journey_errors:rate5m` | same, `status=~"5.."`, `or vector(0)` |
| `voteball:availability:ratio5m` | `1 - (errors / clamp_min(requests, 1e-7)) or vector(1)` |
| `voteball:latency:p95_5m` | `histogram_quantile(0.95, sum by (le) (rate(..._bucket{same filter}[5m])))` |

| SLI | SLO | Alert |
|---|---|---|
| Availability | 99% of voting-journey requests return non-5xx, over 6h | `VoteballAvailabilitySLOBreach` |
| Latency | 95% of voting-journey requests complete under 1s | `VoteballHighLatencyP95` |

**"The journey" is the three endpoints a voter actually traverses** — load the options, cast the
ballot, read the results — not every route the API exposes. Both SLIs use the same filter: an admin
500 should not count against availability, and a heavy bulk vote-reassign should not drag the p95 that
pages someone.

**Six hours, not the 30 days a textbook SLO would use.** The primary reason is that a slow-moving
average is the wrong shape for something meant to page while recovery is still possible; the secondary
one is that this cluster is destroyed and rebuilt for demonstrations, so a long window would sit mostly
empty and read as a broken panel.

### The two fallbacks are different on purpose

`voteball:journey_errors:rate5m` ends `or vector(0)`; `voteball:availability:ratio5m` ends
`or vector(1)`. That asymmetry is deliberate:

- **Zero errors is a real, measured value** — the label combination was scraped and nothing 5xx'd. So
  the errors rule defaults to `0`, which lets availability compute arithmetically whenever traffic
  exists.
- **An absent vector means it was never scraped at all** — e.g. right after a fresh deploy, before the
  first request — where the division yields an empty result rather than a number. A genuinely quiet
  window must not read as a breach in every panel and alert downstream, so availability substitutes
  `1`: no requests means nothing failed.

### Why the canary is not optional

That `or vector(1)` is also the system's sharpest edge, and it is why
`charts/voteball/templates/canary-deployment.yaml` exists.

Voteball has close to no organic traffic. An outage with zero requests in flight makes the numerator
and denominator vanish together, and the fallback then reports a **confident, wrong `1`**. That is not
hypothetical: the 2026-08-18 drill produced a two-hour total API outage that rendered as
`availability = 1`, perfect, on the dashboard that exists to catch exactly this.

The canary is one long-lived pod curling the **real public site** (`/`, `/api/options`,
`/api/results?by=all`) every `canary.intervalSeconds` (30s), purely so the ratio always has a real
denominator. A Deployment rather than a CronJob, which would create ~2,880 Pod objects a day for a
workload that is really "start once, loop forever". It deliberately never calls `/api/vote` — a canary
casting real ballots would pollute the poll's own results, the one thing this site exists to measure
honestly.

**Setting `canary.enabled: false` does not just remove a metric source. It silently makes
`voteball:availability:ratio5m` untrustworthy again**, and takes `VoteballJourneyTrafficStopped` with
it — that alert is gated on the same flag, because "zero requests" is this site's normal state without
the canary and the alert would either fire constantly or be tuned so loose it caught nothing. The two
are coupled on purpose; do not decouple them.

The canary's CPU *limit* was raised 20m → 150m → 500m after measurement: at 150m it was still throttled
in 72.8% of periods while averaging 0.0055 cores. A limit is a quota per 100ms period, and one curl
(DNS + TLS + HTTP) bursts well past 15ms inside a single period. The cost was observable —
`journey_requests:rate5m` sat at 0.0667/s against an intended 0.1/s, so throttling was suppressing a
third of the traffic the SLIs depend on.

---

## 8. Alerts and routing

**16 alerts, every one carrying `summary`, `description` and a `runbook_url`.** Alertmanager renders
those annotations into the SNS message, so what arrives is *"here's what broke, here's the exact page
to open"* rather than a bare metric name.

### Application — `charts/voteball/templates/prometheusrule.yaml` (12)

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `VoteballHighErrorRate` | journey 5xx ratio > 5% | 5m | critical |
| `VoteballHighLatencyP95` | `voteball:latency:p95_5m > 1` | 10m | warning |
| `VoteballRollupsStale` | last successful recompute > 10m ago | 5m | warning |
| `VoteballAvailabilitySLOBreach` | 6h availability < 99% | 15m | warning |
| `VoteballSLIAbsent` | `absent(voteball:journey_requests:rate5m)` | 15m | critical |
| `VoteballJourneyTrafficStopped` | journey rate `== 0` despite the canary | 10m | critical |
| `VoteballPodCrashLooping` | a container in `CrashLoopBackOff` | 5m | critical |
| `VoteballNoBackendAvailable` | zero backend replicas available | 2m | critical |
| `VoteballMigrationJobFailed` | the schema-migration Job failed | 1m | critical |
| `VoteballBackupJobFailed` | the nightly `pg_dump` Job failed | 1m | warning |
| `VoteballBackupMissing` | no successful backup in 48h | — | warning |
| `VoteballContainerOOMKilled` | > 3 restarts in an hour | 5m | warning |

### Platform — `charts/observability/templates/prometheusrule.yaml` (4)

| Alert | Fires when | For | Severity |
|---|---|---|---|
| `NodeNotReadyOrUnderPressure` | node not `Ready`, or under memory/disk/PID pressure | 10m | critical |
| `DeploymentReplicasMismatch` | available < desired **and** updated-replica count unchanged for 10m | 15m | warning |
| `PrometheusTargetDown` | `up == 0` | 5m | critical |
| `JenkinsQueueStuck` | `jenkins_queue_size_value > 0` | 15m | warning |

These four are **cluster-wide on purpose**, matching the scope of the defaults they replace. A rule
scoped to one namespace cannot replace a cluster-wide default without silently dropping coverage of
every other namespace.

### Three alerts that exist because a metric can lie

- **`VoteballSLIAbsent`** is *"we can no longer tell"*, not *"the site is down"*. It exists because
  availability **cannot self-report this failure**: with numerator and denominator both empty,
  `or vector(1)` returns a confident 1, indistinguishable from a perfect score.
- **`VoteballJourneyTrafficStopped`** is meaningful only because the canary guarantees traffic.
- **`VoteballBackupMissing`** measures the *absence of success*, not the presence of failure. A CronJob
  that never runs emits no failure at all, so `VoteballBackupJobFailed` cannot catch a suspended or
  mis-scheduled backup.

`DeploymentReplicasMismatch`'s second clause matters as much as the first. On a two-node 100%-Spot
group, an HPA scale-up where Cluster Autoscaler takes 10+ minutes to add capacity is a *healthy,
still-progressing* rollout. `changes(kube_deployment_status_replicas_updated[10m]) == 0` is what
actually encodes "stalled" — a bare `ready < desired` pages on ordinary autoscaling.

### Routing (`terraform/addon-monitoring.tf`)

Alertmanager → SNS → email, using IRSA to assume a role and sign the publish.

| Setting | Value | Why |
|---|---|---|
| `group_by` | `[alertname, namespace]` | A node going away fires several alerts at once. One message about five problems is read; five messages about one problem are filtered out. |
| `group_wait` | 30s | |
| `group_interval` | 5m | |
| `repeat_interval` | **12h** | Deliberately long. A 4-hourly reminder about a known problem is how an alert channel becomes background noise. |

Two alerts are **null-routed**: `Watchdog` (Prometheus' always-firing heartbeat — it exists to prove
the pipeline is alive when scraped by a dead-man's-switch, and is pure noise in a mailbox) and
`InfoInhibitor` (machinery for the inhibit rules, never human-facing).

**The `config` block replaces the chart's default Alertmanager config wholesale**, which silently
dropped its default `inhibit_rules`. They are re-added by hand: a firing critical mutes matching
warning/info in the same namespace+alertname; a firing warning mutes the matching info; `InfoInhibitor`
mutes info alerts that are alone in a namespace.

The SNS message template renders `summary`, `description` **and** `runbook_url`. That last line was
added after the fact — 14 rules carried the annotation and `docs/runbooks/README.md` stated as fact
that the link "arrives in the email that wakes someone up", but the template only ever rendered the
first two, so it never actually did.

---

## 9. CloudWatch — what it carries, and what is deliberately off

CloudWatch is **logs, not metrics**. Metrics are Prometheus' job here; keeping logs out of the cluster
means AWS-native, IAM-gated storage and a lighter node RAM budget than an in-cluster Loki would need.

### What ships

The AWS-managed `amazon-cloudwatch-observability` add-on (`v6.3.0-eksbuild.1`) deploys **Fluent Bit
only**, tailing container logs to CloudWatch Logs.

| Log group | Retention | Contents |
|---|---|---|
| `/aws/containerinsights/<cluster>/application` | 7 days | pod stdout/stderr — **`devops-app` only** |
| `/aws/containerinsights/<cluster>/dataplane` | 7 days | kubelet, containerd, CNI |
| `/aws/containerinsights/<cluster>/host` | 7 days | node host logs |

Reading them:

```bash
aws logs tail /aws/containerinsights/voteball/application --follow --region il-central-1
aws logs tail /aws/containerinsights/voteball/application --since 1h \
  --filter-pattern '"Traceback"' --region il-central-1
```

**Three-line summary of the scoping decision:** the tail was originally
`/var/log/containers/*.log` — every pod in every namespace. `ci` (Jenkins + BuildKit build output),
`argocd`, `monitoring`, `kube-system` and `external-secrets` were ~95% of the volume. Losing the
Jenkins build logs is consistent with this repo's existing position that `JENKINS_HOME` is disposable
and the durable CI record is the `ci: image tag <sha>` commits on `master`, not console output.

The 7-day retention is chosen against how this stack is actually used: it is rebuilt often enough that
month-old pod logs describe infrastructure that no longer exists, and Grafana holds the metrics. The
log groups are declared in Terraform rather than left to Fluent Bit's `auto_create_group`, which
creates them as **"Never expire"** — before they were declared they survived `terraform destroy` and
kept accumulating across every rebuild, billed forever, owned by no stack.

### What is off, and what turning it back on costs

Everything else the add-on can do is disabled, because this stack already collects the same signals for
free. Measured on this account **before** the change:

| Disabled | Was costing | Duplicated by |
|---|---|---|
| `containerInsights` | ~3.1 GB/day of logs **and $3.00/day of `CW:ObservationUsage` ($30.03 in July)**. 61% of records were `Type=ControlPlane`. | kube-prometheus-stack's apiserver scrape, at no charge |
| `applicationSignals` | the sole source of ~89k monthly X-Ray traces, ~25 MB/day | — |
| `kubeStateMetrics` | — | the stack's own kube-state-metrics |
| `nodeExporter` | a DaemonSet requesting 256m CPU / 128Mi, billed in Spot node capacity | the stack's own node-exporter |
| `dcgmExporter`, `neuronMonitor` | — | this node group has no GPUs or Inferentia |

**Do not flip `containerInsights` or `applicationSignals` back on to "get more observability" without
checking Grafana first — it is almost certainly already there, for free.**

### Two ways this configuration fails silently

- **`agents = []` is not implied by the flags above.** Those turn off what the agent would *collect*;
  `agents` is a separate list (default `[{name: "cloudwatch-agent"}]`) deciding whether the workload
  exists at all. Leave it at the default with everything else off and the agent still lands on every
  node, translates an empty config, finds no `amazon-cloudwatch-agent.yaml`, and CrashLoopBackOffs
  forever — which then trips `VoteballPodCrashLooping` and pages SNS about a pod that is not supposed
  to be running. Observed live on 2026-08-03: 5 restarts in 4 minutes. Fluent Bit is a separate
  DaemonSet under `containerLogs` and is unaffected.
- **The `application-log.conf` override *replaces* the add-on's default, it does not merge into it.**
  A dropped `[FILTER]` or `[OUTPUT]` block therefore does not error: Fluent Bit starts, reports
  healthy, and ships nothing. If the add-on version is ever bumped, re-copy the config from the live
  cluster (`kubectl get cm fluent-bit-config -n amazon-cloudwatch`) and re-apply the two marked
  changes, rather than editing the old copy blind.

### What is *not* alerted on, and why

No alert in this repo uses a CloudWatch metric. RDS connection counts, RDS free storage, ALB 5xx rates
and ACM certificate expiry are all CloudWatch metrics, and **nothing scrapes CloudWatch into Prometheus
here.** Writing those rules anyway would produce alerts that can never fire — worse than no alert,
because the dashboard looks covered. Adding the CloudWatch exporter is the prerequisite, not the rule.

### Also billed, also not metrics

The add-on's mutating webhook injects an OpenTelemetry agent per language into every pod by default.
Pods that do not want one opt out with the four
`instrumentation.opentelemetry.io/inject-{java,python,nodejs,dotnet}: "false"` annotations — the canary
does exactly this, being a plain shell/curl loop.

---

## 10. The two CI/CD gates

Observability is not only *watched* by the pipeline, it is *validated* by it. Both gates are ordinary
shell scripts with offline tests, so neither can only be exercised by running a real build.

### CI — `Observability Validation` (stage 3 of `Jenkinsfile-ci`)

`scripts/ci/validate-observability.sh`. Runs offline against rendered chart output — no cluster, no
credentials. **Every check corresponds to a mistake this repository has actually made, and each one
failed silently when it was made.**

1. Every ServiceMonitor and PrometheusRule carries `release: kube-prometheus-stack`.
2. Every ServiceMonitor endpoint names a port that exists on the Service it selects.
3. No application metric label collides with a prometheus-operator target label (the `endpoint`
   collision of §4).
4. Every dashboard parses, has a `uid` and `title`, and every panel has a non-empty query.
5. `promtool check rules` against the rendered alert rules.

CI **validates** observability config and never deploys it — ArgoCD is the only applier, same rule as
everywhere else in this repo.

### CD — `Monitoring Gate` (stage 9 of `Jenkinsfile-cd`, after Smoke Test)

`scripts/ci/monitoring-gate.sh`. Smoke Test asks *"does the product answer?"*; this asks *"does it
answer well, at the rate the SLOs promise?"* It runs after ArgoCD reports Healthy — which means the old
pods are gone and everything it measures is served by the new build.

It generates its own burst of traffic (`GATE_REQUESTS`, default 60), waits for a scrape, then queries
**the same recording rules the dashboard and alerts use** — never new PromQL, so there is exactly one
definition of each SLI in this repo:

| Check | Default threshold |
|---|---|
| targets up in `devops-app` | all, checked first and unconditionally |
| error ratio | `GATE_MAX_ERROR_RATIO` = 0.01 |
| p95 latency | `GATE_MAX_P95_SECONDS` = 1.0 |
| sample floor | `GATE_MIN_SAMPLES` = 20 |

**The most important property of this script is that it passes when it has too little data to judge.**
In `Jenkinsfile-cd`, anything that fails after the Promote stage triggers an automatic rollback of
production — Promote is the point of no return. A gate that failed on missing data would roll back a
perfectly healthy release every time the metrics pipeline hiccuped, turning a safety feature into an
outage generator that fires on nothing. Below `GATE_MIN_SAMPLES`, with every target up, is a **pass
with a loud warning**. Do not tighten this.

A genuinely broken scrape needs no traffic to detect — that is what the targets-up check is for, and it
runs first. And the one case that is *not* "insufficient data" is the SLI being **absent** (no series at
all): that means the measurement pipeline itself is broken, and the gate fails on it distinctly.

`GATE_REQUESTS` defaults to 60 rather than 40 because a live review measured 40 landing only ~29
estimated samples against a floor of 20 — Prometheus' `rate()` extrapolation over the 5m window shaves
a fraction off the true count, so a healthy run could land in the warn-and-pass branch routinely rather
than rarely.

Drill 4 is this gate's proof of purpose: a release with a 1.5s sleep injected into one endpoint passed
**every check that existed before it** — healthy pods, ArgoCD `Synced`, 200s on the smoke test — and was
caught only here, and rolled back automatically within the same pipeline run.

---

## 11. Reaching Grafana, Prometheus and Alertmanager

Nothing is public — same reasoning as ArgoCD: a private tunnel plus your AWS login is the front door.
All three are `ClusterIP`.

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana      3000:80    # http://localhost:3000
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus   9090:9090  # http://localhost:9090
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093  # http://localhost:9093

# Grafana password (username is `admin`)
kubectl get secret kube-prometheus-stack-grafana -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The Grafana password is **generated fresh at install time and changes on every rebuild** — there is
deliberately no fixed one anywhere in the repo or in `terraform.tfstate`. Prometheus and Alertmanager
have no login at all; the only way to reach either is to already hold cluster access.

`grafana-cli` lives inside the Grafana container, if you need to inspect a plugin:

```bash
kubectl exec -it -n observability deploy/kube-prometheus-stack-grafana -c grafana -- grafana-cli --help
```

**Use it read-only.** Grafana has no PVC here (§3), so anything it writes — `plugins install` above
all — is gone at the next pod restart, which on a 100% Spot node group is roughly daily. A plugin
that has to stay belongs in `helm_release.kube_prometheus_stack`'s values in
`terraform/addon-monitoring.tf`; a dashboard belongs in `charts/observability/dashboards/` (§6).
`grafana-cli admin reset-admin-password` is a trap in particular: it rewrites the running password
but not the `kube-prometheus-stack-grafana` Secret, so the Secret that
`scripts/capture-observability-evidence.sh` reads silently stops being the real password — and the
next restart discards the new one regardless.

---

## 12. Verifying it works

```bash
# 1. Every scrape target is UP. Anything not "up" here makes a dashboard blind, not red.
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets \
  | python3 -c 'import json,sys; t=json.load(sys.stdin)["data"]["activeTargets"]; \
print(sum(1 for x in t if x["health"]=="up"), "/", len(t), "up"); \
[print("  DOWN:", x["labels"], x["lastError"]) for x in t if x["health"]!="up"]'

# 2. Every rule loaded and healthy (a rule with a typo reports health != "ok").
curl -s localhost:9090/api/v1/rules \
  | python3 -c 'import json,sys; g=json.load(sys.stdin)["data"]["groups"]; \
r=[x for gr in g for x in gr["rules"]]; \
print(len(r), "rules;", sum(1 for x in r if x["health"]!="ok"), "unhealthy")'

# 3. The SLIs actually return numbers (not an empty result — see VoteballSLIAbsent).
for q in voteball:journey_requests:rate5m voteball:availability:ratio5m voteball:latency:p95_5m; do
  echo -n "$q = "; curl -s --data-urlencode "query=$q" localhost:9090/api/v1/query \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "ABSENT")'
done

# 4. All four dashboards are present as ConfigMaps.
kubectl -n observability get cm -l grafana_dashboard=1

# 5. Alertmanager has the SNS receiver and has not failed a notification.
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &
curl -s localhost:9093/api/v2/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["original"][:400])'

# 6. Logs are arriving in CloudWatch.
aws logs tail /aws/containerinsights/voteball/application --since 10m --region il-central-1 | head
```

Offline, with no cluster at all:

```bash
scripts/tests/test-validate-observability.sh   # the CI validator's own tests (needs helm)
scripts/tests/test-monitoring-gate.sh          # the CD gate's threshold logic, Prometheus stubbed
scripts/tests/test-observability-docs.sh       # this document's counts vs the charts
scripts/ci/validate-observability.sh           # the validator itself, against the real charts
```

**An alert that fires and is never delivered is the exact silent failure this design exists to catch**,
so the acceptance test was a real alert all the way to a received email — not a screenshot of a healthy
system. An unschedulable canary Deployment tripped `DeploymentReplicasMismatch`; Alertmanager published
to SNS with zero failed notifications, and the email arrived with its `Runbook:` line. Full output in
[`docs/eks/evidence/2026-08-18-observability-as-code.txt`](eks/evidence/2026-08-18-observability-as-code.txt).

---

## 13. Troubleshooting: the things that look healthy and are not

Every row here has been hit for real. The common shape: **the object applies cleanly, `kubectl get`
lists it, and nothing works.**

| Symptom | Cause | Fix |
|---|---|---|
| A ServiceMonitor/PrometheusRule exists but is never scraped or evaluated | Missing `release: kube-prometheus-stack` label | Add it. CI check 1 catches this. |
| A ServiceMonitor has zero targets | `port:` names a number, or a port name that does not exist on the Service | Name the Service port. CI check 2. |
| **Availability reads a flat, confident `1` during an outage** | `honorLabels: true` removed from the backend endpoint, so every SLI filters on a label that no longer carries routes | Restore it. CI check 3. |
| Availability reads `1` after a rebuild, and the canary logs `curl: (6) Could not resolve host` | CoreDNS cached a NOERROR-with-no-A answer from before external-dns created the record; the name already existed (a TXT record), so it was NODATA rather than NXDOMAIN, cached against the zone's SOA minimum of 86400s | `./scripts/verify-public-dns.sh` (deploy.sh step 11c runs it). The tell: **TXT resolves, A does not.** |
| Availability reads `1` with no traffic at all | The `or vector(1)` fallback, working as designed — with the canary off there is no denominator | `canary.enabled: true`. `VoteballSLIAbsent` and `VoteballJourneyTrafficStopped` exist for this. |
| A total API outage is invisible; no error counter moves | `psycopg2.connect()` without `connect_timeout` **hangs** rather than failing, so nothing is ever counted | `connect_timeout=5` on both services. **Never remove it.** |
| Every Grafana panel errors with `dial tcp <clusterIP>:9090: i/o timeout` | The `observability` egress policy lists only 443; the VPC CNI evaluates egress pre-DNAT | Keep 443/9090/9093/3000 in the Service-CIDR egress block. |
| Alerts fire in Prometheus but no email arrives | The SNS/STS egress rule removed, or Alertmanager's IRSA role broken | Check `curl localhost:9093/api/v2/status` and the pod's logs for STS errors. |
| A Jenkins dashboard panel shows a flat, healthy zero | Wrong metric family — `jenkins_*_value` vs `default_jenkins_builds_*` | Query the live label list; do not guess from the name. |
| The `cloudwatch-agent` pod CrashLoopBackOffs and pages SNS | `agents = []` was reverted to the default while its collectors stayed off | Restore `agents = []`. |
| Fluent Bit is healthy but no logs reach CloudWatch | The `application-log.conf` override dropped an `[OUTPUT]` block — it replaces, not merges | Re-copy from the live ConfigMap and re-apply the two marked changes. |
| Prometheus is `Pending` after a rebuild | The `gp3` StorageClass does not exist yet, or the PVC's AZ has no capacity | `kubectl -n observability describe pvc`. Terraform's `depends_on` covers the first case. |
| History vanished after a Helm uninstall/reinstall | The PVC is a StatefulSet `volumeClaimTemplate`; a reinstall provisions a **new, empty** one | Expected. `scripts/destroy.sh` deletes it deliberately so it is not silently billed. |
| `PrometheusTargetDown` for Jenkins, forever | `serviceMonitor.enabled` turned on ahead of a controller image containing `prometheus.jpi` | Rebuild the image, bump `jenkins_image_tag`, `terraform apply`. |
| A malformed PrometheusRule is admitted instead of rejected, after a ~20s pause | The admission-webhook ingress rule is missing; both webhooks are `failurePolicy: Ignore` | Keep `allow-admission-webhook-ingress`. |

---

## 14. What it costs

Observability is a small share of the stack's **≈$8.50/day** while up:

| Item | Cost |
|---|---|
| Prometheus PVC (10Gi gp3) | ~$0.03/day |
| CloudWatch Logs, `devops-app` only, 7-day retention | cents/day |
| kube-prometheus-stack compute | no marginal cost — it fits in the existing two-node Spot group |
| **`containerInsights` if re-enabled** | **+$3.00/day** plus ~3.1 GB/day of ingestion |
| **`applicationSignals` if re-enabled** | ~89k X-Ray traces/month, ~25 MB/day |

The two metered knobs are the reason §9 is written the way it is: both were on once, both were paying
for a second copy of what Prometheus already collects.

---

## 15. Failure drills

The design was tested by breaking things, and the transcripts are committed. `docs/design/2026-08-17-observability-design.md`
carries the narrative; these are the artefacts:

| Drill | What it proved | Evidence |
|---|---|---|
| 1 — controlled 5xx | **Found two real defects** (the `connect_timeout` hang and the ratio-with-no-denominator blind spot) before either could matter in production | [`2026-08-18-drill-1-controlled-5xx.txt`](eks/evidence/2026-08-18-drill-1-controlled-5xx.txt) |
| 2 — pod readiness | Zero non-200 responses across 60 polls while Kubernetes replaced a pod in 54s, behind a PDB | [`-2-pod-readiness.txt`](eks/evidence/2026-08-18-drill-2-pod-readiness.txt) |
| 3 — Jenkins agent loss | The site stayed at 200 throughout and Jenkins re-provisioned an agent on its own | [`-3-jenkins-agent-loss.txt`](eks/evidence/2026-08-18-drill-3-jenkins-agent-loss.txt) |
| 4 — monitoring gate | A 1.5s latency regression passed every pre-existing check and was caught and rolled back by the gate alone | [`-4-monitoring-gate.txt`](eks/evidence/2026-08-18-drill-4-monitoring-gate.txt) |
| 5 — Jenkins queue stuck | Alert fired end to end on a genuinely stuck queue, 12m53s after the condition began — see below | [`-5-jenkins-queue-stuck.txt`](eks/evidence/2026-08-18-drill-5-jenkins-queue-stuck.txt), [`rerun-drill-5`](eks/evidence/2026-08-18-rerun-drill-5-jenkins-queue-stuck.txt) |

Re-runs after the fixes are in the matching `2026-08-18-rerun-drill-*.txt` files, plus
[`-4b-settle-fix-proof.txt`](eks/evidence/2026-08-18-rerun-drill-4b-settle-fix-proof.txt).

**Drills 1 and 3 were re-run on 2026-08-24, on the cluster rebuilt that afternoon, and they are now
scripts rather than a sequence of commands somebody remembered.** `scripts/drills/` holds
`drill-1-controlled-5xx.sh`, `drill-3-jenkins-agent-loss.sh` and `drill-5-jenkins-queue-stuck.sh`;
each puts its own restore in a `trap`, which matters most for drill 1 — it suspends ArgoCD's selfHeal
so the break can outlive a reconcile, and leaving that suspended is a worse state than the outage it
creates. A drill nobody can re-run is a drill that expires, which is exactly what had happened to the
August set.

| Drill | 2026-08-24 outcome | Evidence |
|---|---|---|
| 1 — controlled 5xx | `VoteballHighErrorRate` fired at 15:24:55Z; availability fell 1.00 → 0.10 as the site served 500s. **Two caveats are written into the transcript**: the outage was ended externally at 15:22:03Z by a second operator, so the alert fired on the tail of a 5-minute rate window rather than against a still-broken site; and the `HEALTH` column was reading the public `/health`, which is a 404 because nginx proxies only `/api/*`. | [`2026-08-24-drill-1-controlled-5xx.txt`](eks/evidence/2026-08-24-drill-1-controlled-5xx.txt) |
| 3 — Jenkins agent loss | A 9-container build agent was force-deleted mid-build; the site held 200 across every poll and Jenkins provisioned a replacement agent on its own within ~2 minutes. | [`2026-08-24-drill-3-jenkins-agent-loss.txt`](eks/evidence/2026-08-24-drill-3-jenkins-agent-loss.txt) |
| 4 — monitoring gate | A release with 1.5s injected into `/api/options` passed pods-Ready, ArgoCD Synced and all three smoke-test endpoints, then failed the gate on **p95 2.315s vs the 1.0s SLO with an error ratio of 0.000000**, and was rolled back automatically. Site degraded (slow, never failing) for 2m45s. | [`2026-08-24-drill-4-monitoring-gate.txt`](eks/evidence/2026-08-24-drill-4-monitoring-gate.txt) |
| 5 — Jenkins queue stuck | `JenkinsQueueStuck` fired at 16:03:10Z, exactly its `for: 15m` after a `ResourceQuota` of `pods=1` blocked agent provisioning at 15:48:10Z. The queue reached 4 and `ci` fell to the controller pod alone, while the site returned 200 on every poll of the window. | [`2026-08-24-drill-5-jenkins-queue-stuck.txt`](eks/evidence/2026-08-24-drill-5-jenkins-queue-stuck.txt) |

The 2026-08-24 run of drill 1 is **narrower** than the August one, and the transcript says so rather
than presenting a pass as a clean pass. That is the same discipline as drill 5's first attempt below:
a drill that does not reach its own condition, or reaches it by accident, looks identical to a proof
unless someone writes down which one happened.

**Drill 5 took two attempts, and the first failure is the more useful half.** The morning run tried to
reach a stuck queue by killing an agent that already existed — which *aborts* its build rather than
queueing it, so the queue-length metric never moved. A drill can fail to reach its own condition and
look exactly like a disproved design; that run was recorded as "unproven" rather than as a pass.

Reaching the condition needs agent **provisioning** to fail, not an agent to die. The re-run applied a
`ResourceQuota` of `pods=1` to the `ci` namespace and triggered a build: Jenkins had nowhere to put an
agent, `jenkins_queue_size_value` held at `1` for the full window, and `JenkinsQueueStuck` went
`pending` at 17:42:50Z and **`FIRING` at 17:55:34Z** — the rule's own `for: 15m`, end to end. The
quota was namespace-scoped to `ci`, so `devops-app` was untouched and the site stayed up throughout,
which is exactly why that alert is `severity: warning` and its description says the website is
unaffected.

The re-run was only possible once the Jenkins ServiceMonitor was enabled, which was gated on a
controller-image rebuild containing `prometheus.jpi` — committing `plugins.txt` alone changes nothing,
because plugins are baked into the image and Terraform owns the release.

---

## 16. Keeping this document true

A stale doc is a defect, and the counts here move. Two mechanisms, because a rule on its own is not one:

- **`scripts/tests/test-observability-docs.sh`** runs in CI (`scripts/tests/run-ci-suite.sh`,
  `python` group) and **fails the build** when this file drifts from the charts: an alert added,
  renamed or removed; a dashboard added or a panel added to one; a recording rule added; a
  `runbook_url` pointing at a file that does not exist; an alert with no runbook or a runbook with no
  alert; or any of the counts stated in §1, §2 and §8 moving. It also guards the alert table in
  `docs/runbooks/README.md`, which carries the same list from a different angle.

  It refuses to run — rather than passing vacuously — if it extracts zero alerts, which is what would
  happen if the chart format changed underneath it.
- The **"Doc claims that drift"** section of the root `CLAUDE.md` lists the mechanical check for each
  remaining claim (retention, PVC size, chart version, cost).

If you change an alert, a dashboard, a recording rule, a scrape target or a CloudWatch setting, update
this file **in the same commit**. Not as a follow-up — a doc that describes a system that no longer
exists misdirects effort worse than no doc at all.
