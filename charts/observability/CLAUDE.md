# charts/observability — CLAUDE.md

*Moved verbatim from the root `CLAUDE.md` on 2026-10-02 so it loads only when working here. Where a paragraph says "above" or "below" about something not in this file, it is in one of: `terraform/CLAUDE.md`, `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`, `charts/observability/CLAUDE.md`, `charts/voteball/CLAUDE.md`, or the `voteball-cicd` skill.*

## What this chart is

**Helm (`charts/observability`)** is dashboards-and-alerts-as-code for the `observability` namespace:
the six Grafana dashboards (provisioned as ConfigMaps via `.Files.Glob`, not clicked together), the
Kubernetes/Jenkins/monitoring-system `PrometheusRule`s, that namespace's own default-deny
NetworkPolicies, and — since the 2026-08-24 Grafana data sources pass — the PostgreSQL/CloudWatch/
GitHub datasource ConfigMaps (`templates/datasources.yaml`) and the ExternalSecret/SecretStore that
project `grafana_ro`'s password and the GitHub PAT into the Grafana pod (`templates/
externalsecret.yaml`, gated `enabled: false` by default — see `docs/deploy.md`'s "Optional, manual"
section and `docs/design/2026-08-24-grafana-datasources-design.md`). It is a **second ArgoCD
Application with its own `AppProject`** (both declared in
`argocd/voteball-application.yaml.tmpl` alongside `voteball`'s), synced from `release` the same way —
the app's own ServiceMonitors and SLI/SLO recording rules stay in `charts/voteball` instead, next to
the Services and alerts they describe. kube-prometheus-stack itself (Prometheus/Grafana/Alertmanager,
the PVC, retention, SNS routing) is a `helm_release` in `terraform/addon-monitoring.tf`, not this
chart — same Terraform-vs-Helm boundary as everywhere else: the platform reaches the cluster by
`terraform apply`, the configuration on top of it by `git push`.
**The Jenkins ServiceMonitor lives in `charts/jenkins-support`, not here** — it deploys with the
Jenkins release it scrapes — and its enablement is coupled to a controller-image rebuild: the
`prometheus` plugin is baked into the image from `ci/jenkins/plugins.txt`, and the ServiceMonitor is
gated on `serviceMonitor.enabled`, which Terraform only flips to `true` once `jenkins_image_tag` (in
the gitignored `terraform/voteball.tfvars`) points at an image that actually contains
`prometheus.jpi`. **Committing `plugins.txt` alone changes nothing** — plugins are baked into the
controller image, and (per the Jenkins note below) the release is owned by Terraform, not ArgoCD;
turning the ServiceMonitor on ahead of the matching image/tag rebuild would scrape a target that
404s forever and page `PrometheusTargetDown` on a repeating schedule for nobody to fix without that
build.

## Jenkins metric families

**Jenkins exposes two Prometheus metric families that are not interchangeable, and picking the wrong
one for a dashboard panel or alert shows a flat, healthy-looking zero instead of an error.** The
bundled Metrics plugin's `jenkins_*_value` gauges (`jenkins_queue_size_value`,
`jenkins_executor_count_value`, `jenkins_node_online_value`) read `0` almost all the time on this
cluster — truthfully, since the Kubernetes cloud provisions agents on demand and nothing sits queued or
connects between builds — while the `prometheus` plugin's own `default_jenkins_builds_*` family
(build counts, durations, health scores) carries real non-zero data throughout the same window. Both
are correct for what they measure; verify which family a metric actually belongs to by querying it
live, never by guessing from the name (`docs/design/2026-08-17-observability-design.md`'s "Drill
outcomes" section and `charts/observability/values.yaml`'s `queueMetric` comment both record this being
gotten wrong once already). `JenkinsQueueStuck` (`jenkins_queue_size_value > 0` for 15m) is proven,
but only on the second attempt, and the way it was proven is the point: killing an agent mid-build
*aborts* the build rather than queueing it, so a drill built around that mechanism can never reach a
non-zero queue size. Reaching the condition needs agent **provisioning** to fail — a `ResourceQuota`
of `pods=1` on the `ci` namespace — after which the alert fired end to end
(re-runnable via `scripts/drills/drill-5-jenkins-queue-stuck.sh`). It also depends on the Jenkins
ServiceMonitor being enabled, which is gated on a controller-image rebuild carrying `prometheus.jpi`.
