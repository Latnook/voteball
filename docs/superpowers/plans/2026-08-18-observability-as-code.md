# Observability as Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the metrics now being scraped into things a human acts on — three dashboards, an
SLI/SLO pair, eight alerts each carrying a runbook, all provisioned from files in git.

**Architecture:** A new `charts/observability` chart, synced by a second ArgoCD Application, holds the
dashboards (as ConfigMaps the Grafana sidecar discovers), the platform alerts, and the namespace's own
NetworkPolicies. App-specific alerts and SLO recording rules stay in `charts/voteball`, next to the
application they describe. Terraform keeps owning the stack itself.

**Tech Stack:** Helm, ArgoCD, kube-prometheus-stack 87.21.0, Grafana sidecar dashboard discovery,
PromQL, Jenkins JCasC.

**Spec:** `docs/design/2026-08-17-observability-design.md` — sections 6, 7d, 8, 9, 10. Sections 1-5 and
7a-c shipped in the previous two plans; 11-13 are plan 4.

## Global Constraints

- **Every `PrometheusRule`, `ServiceMonitor` and `PodMonitor` must carry the label
  `release: kube-prometheus-stack`.** Without it Prometheus ignores the object: it is created, it
  appears in `kubectl get`, and it is silently never evaluated.
- **Grafana discovers dashboards by the label `grafana_dashboard: "1"` on a ConfigMap.** The chart
  already sets `sidecar.dashboards.searchNamespace: ALL` as its default — do not add a Terraform
  override for it.
- **Only write rules and panels against metrics this cluster actually exposes.** RDS, ALB and ACM
  figures are CloudWatch-only and nothing scrapes them into Prometheus; a rule against them can never
  fire, which is worse than no rule because the coverage looks complete.
- **`charts/observability` must render offline**, with a feature flag for anything requiring a CRD, the
  same escape hatch `alerts.enabled` and `serviceMonitors.enabled` already provide.
- **The new AppProject's `clusterResourceWhitelist` stays empty** unless a task explicitly whitelists a
  kind. Adding a cluster-scoped resource without one fails the sync closed with
  `resource ... is not permitted in project`, which is the intended behaviour.
- **Never write an empty list literal (`to: []`) in a chart template.** The API server drops it, so the
  applied value can never equal the stored value and every server-side apply conflicts forever.
- Alert annotations must include `summary`, `description` and `runbook_url`. Alertmanager's SNS
  template renders annotations, so the runbook link reaches the email.
- Commit and push as you go, stage only your task's files (the repo owner works in this tree), never
  force-push, no `Claude-Session:` trailer.
- **Only Tasks 1 and 10 run `terraform apply`.** Both stop for the repo owner's explicit approval.

## Current live state (verified 2026-08-18)

- Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter run in namespace
  `observability`; Prometheus has a 10Gi `gp3` PVC, `retention: 15d`, `retentionSize: 8GiB`.
- 24/24 targets UP. Application series confirmed present: `voteball_http_requests_total`,
  `voteball_http_request_duration_seconds_bucket`, `voteball_votes_cast_total`,
  `voteball_votes_rejected_total`, `voteball_db_errors_total`, `voteball_app_info{version,git_sha}`,
  `voteball_worker_recompute_total`, `voteball_worker_recompute_duration_seconds`,
  `voteball_worker_last_success_timestamp_seconds`, `voteball_worker_notifications_received_total`,
  `nginx_up`, `nginx_http_requests_total`.
- **Jenkins metrics do NOT exist yet** and `charts/jenkins-support`'s ServiceMonitor is switched off.
  Task 1 fixes that; the Jenkins dashboard and the Jenkins alert both depend on it.
- 32 default `PrometheusRule` objects from kube-prometheus-stack are live and route to SNS.
- `charts/voteball/templates/prometheusrule.yaml` holds 7 existing app rules, none with a
  `runbook_url`.

---

### Task 1: Ship the Jenkins prometheus plugin

**⚠ STOPS FOR APPROVAL.** This rebuilds the Jenkins controller image and applies it. `plugins.txt`
pins no versions, so the rebuild re-resolves **every** plugin to its latest compatible version — a bad
resolution takes CI/CD down until someone notices. Do not begin without the repo owner's go-ahead in
this session.

**Files:**
- Modify: `terraform/voteball.tfvars` (gitignored — **do not commit it**)
- Modify: `terraform/addon-jenkins.tf`

- [ ] **Step 1: Record the rollback point**

```bash
grep -n "jenkins_image_tag" terraform/voteball.tfvars
aws ecr describe-images --repository-name voteball-jenkins \
  --query 'sort_by(imageDetails,&imagePushedAt)[].imageTags' --output text
```

Write the current tag in your report. If anything below goes wrong, restoring that value and
re-applying is the way back.

- [ ] **Step 2: Build and push the controller image**

```bash
git status --porcelain    # must be empty; the script refuses a dirty tree
./scripts/build-push-ecr.sh jenkins
```

The script tags the image `git rev-parse --short HEAD`. Record the tag it pushed. If it refuses
because the tree is dirty, stop and report — do not use `ALLOW_DIRTY_BUILD=1`, which suffixes the tag
`-dirty` and would put a lying tag in `voteball.tfvars`.

- [ ] **Step 3: Confirm the new image actually carries the plugin**

Do not assume the build included it:

```bash
REG=$(cd terraform && terraform output -raw ecr_registry)
docker run --rm "$REG/voteball-jenkins:<the tag from step 2>" \
  sh -c 'ls /usr/share/jenkins/ref/plugins/ | grep -i prometheus'
```

Expected: a `prometheus.jpi` (or `.hpi`) entry. Nothing printed means the image does not have it and
applying would be pointless.

- [ ] **Step 4: Point Terraform at the new image**

Edit `jenkins_image_tag` in `terraform/voteball.tfvars` to the tag from Step 2. **This file is
gitignored and must never be committed** — it holds the database password.

- [ ] **Step 5: Re-enable the ServiceMonitor**

In `terraform/addon-jenkins.tf`, flip the `serviceMonitor.enabled` entry in `helm_release`
`jenkins_support`'s `set` list from `"false"` to `"true"`, and rewrite its comment: the monitor is on
because the controller image now serves `/prometheus`; it was off only while that was untrue.

- [ ] **Step 6: Plan, and read it before applying**

```bash
cd terraform && terraform plan -var-file=voteball.tfvars -out=/tmp/jenkins.tfplan 2>&1 | tail -30
```

Expected: `helm_release.jenkins` updated (new image tag) and `helm_release.jenkins_support` updated.
**If the plan proposes destroying anything, or touches RDS, EKS, the node group or ECR, STOP and
report it.**

- [ ] **Step 7: Apply, then verify the endpoint exists**

```bash
cd terraform && terraform apply /tmp/jenkins.tfplan
kubectl -n ci rollout status sts/jenkins --timeout=300s
kubectl -n ci exec sts/jenkins -c jenkins -- \
  curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/prometheus
```

Jenkins is a **StatefulSet**, not a Deployment — `deploy/jenkins` errors. Expected: `200`. A **403 or
404 both mean the plugin is absent or unreachable** (403 is what this controller's authorization
strategy returns for an unknown path), so treat either as failure and report it rather than proceeding.

- [ ] **Step 8: Confirm the scrape target comes up, and learn the real metric prefix**

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
curl -s -G http://localhost:9090/api/v1/query --data-urlencode 'query=up{namespace="ci"}' \
  | python3 -c "import json,sys; [print(s['metric'].get('job'), s['value'][1]) for s in json.load(sys.stdin)['data']['result']]"
curl -s http://localhost:9090/api/v1/label/__name__/values \
  | python3 -c "import json,sys; print([n for n in json.load(sys.stdin)['data'] if 'jenkins' in n][:25])"
pkill -f "port-forward svc/kube-prometheus-stack"
```

Expected: the `ci`/`jenkins` target reports `1`, and a list of real Jenkins metric names.
**Record those names verbatim in your report — later tasks write PromQL against them.** The plugin
prefixes metrics with a configurable namespace that commonly defaults to `default_`, so the queue
gauge is likely `default_jenkins_queue_size_value` rather than `jenkins_queue_size_value`. Do not
guess; report what the cluster actually has.

- [ ] **Step 9: Commit (the tf file only)**

```bash
git add terraform/addon-jenkins.tf
git commit -m "feat(jenkins): turn the ServiceMonitor on now that the image serves /prometheus

The monitor was off because plugins are baked into the controller image
and no image had been built from the plugins.txt change -- leaving it on
would have produced a permanently-failing target and paged SNS every 12
hours forever.

The image is built and jenkins_image_tag now points at it, so the
endpoint exists and the monitor is back on."
git push origin master
```

`terraform/voteball.tfvars` stays uncommitted — confirm with `git status` that it is not staged.

---

### Task 2: The observability chart and its ArgoCD Application

**Files:**
- Create: `charts/observability/Chart.yaml`, `charts/observability/values.yaml`
- Create: `charts/observability/templates/_helpers.tpl`
- Modify: `argocd/voteball-application.yaml.tmpl`
- Modify: `scripts/render-argocd-app.sh`

**Interfaces:**
- Produces: a chart that renders empty-but-valid, and an ArgoCD Application syncing it into
  `observability`

- [ ] **Step 1: Create the chart**

`charts/observability/Chart.yaml`:

```yaml
apiVersion: v2
name: observability
description: Dashboards, platform alert rules and network policy for the observability namespace.
type: application
version: 0.1.0
appVersion: "1.0"
```

`charts/observability/values.yaml`:

```yaml
# Everything in this chart is gated, so `helm template` works against a cluster with no
# kube-prometheus-stack CRDs installed -- the same escape hatch charts/voteball's alerts.enabled
# provides, and for the same reason: `helm template` succeeds either way, but `helm install` fails on
# an unknown kind.

# Grafana dashboards, shipped as ConfigMaps the Grafana sidecar discovers by label.
dashboards:
  enabled: true

# Platform alert rules (Kubernetes, Jenkins, the monitoring system itself). Application rules live in
# charts/voteball, next to the application they describe.
alerts:
  enabled: true

# NetworkPolicies for this namespace. See templates/networkpolicy.yaml -- the EGRESS list is the
# dangerous half.
networkPolicy:
  enabled: true

# The two PUBLIC subnet CIDRs, matching charts/voteball. Only used if a policy ever needs to admit the
# load balancer; kept here so both charts state the fact the same way.
network:
  albSubnetCidrs:
    - "10.0.0.0/20"
    - "10.0.16.0/20"
```

`charts/observability/templates/_helpers.tpl`:

```
{{/*
Common object labels. NEVER routed into a selector or a pod template's labels: a Deployment's
selector is immutable after creation, so a helper whose output changes on a version bump would make
every future sync fail with a field-immutable error, fixable only by deleting the object.
*/}}
{{- define "observability.labels" -}}
app.kubernetes.io/name: observability
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
```

- [ ] **Step 2: Verify it renders empty and valid**

```bash
helm lint charts/observability
helm template observability charts/observability --namespace observability
```

Expected: lint passes; template output is empty (no templates yet). Both must succeed before wiring
ArgoCD to it — an Application pointing at a chart that does not render is a sync error loop.

- [ ] **Step 3: Add the AppProject and Application**

Append to `argocd/voteball-application.yaml.tmpl`, as two more documents (`---` separated). Order
matters within the file: the AppProject must precede its Application, because kubectl applies a
stream top to bottom.

```yaml
---
# The observability project. Separate from `voteball` because it deploys a different chart into a
# different namespace, and an AppProject's whole purpose is to pin exactly that pair. Reusing the
# voteball project would mean widening its destination to two namespaces, which would let a mistake in
# either chart deploy into the other's namespace.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: observability
  namespace: argocd
spec:
  description: Dashboards, platform alerts and network policy. Deploys charts/observability into observability, nothing else.
  sourceRepos:
    - ${REPO_URL}
  destinations:
    - server: https://kubernetes.default.svc
      namespace: observability
  # Empty = DENY every cluster-scoped resource, same as the voteball project. This chart renders only
  # ConfigMaps, PrometheusRules and NetworkPolicies -- all namespaced. Verify with:
  #     helm template observability charts/observability -n observability | grep '^kind:' | sort -u
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
---
# CreateNamespace=false: Terraform's kube-prometheus-stack release created `observability` with
# create_namespace, so it already exists. ServerSideApply for the same reason the voteball Application
# uses it -- these objects share a namespace with resources Helm created, and field ownership has to
# be shared rather than fought over.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability
  namespace: argocd
spec:
  project: observability
  source:
    repoURL: ${REPO_URL}
    targetRevision: master
    path: charts/observability
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false
```

- [ ] **Step 4: Teach `--check` about the second Application**

Read `scripts/render-argocd-app.sh` first. It asserts that the live cluster matches the template AND
that no Application or AppProject exists which this repo does not declare. Adding a second pair will
break whichever assertion assumes exactly one. Update it so both pairs are expected, keeping the
"fails on anything undeclared" property intact — that property is the whole point of the script,
since ArgoCD's selfHeal watches the chart but nothing watches the Application.

- [ ] **Step 5: Render and check**

```bash
./scripts/render-argocd-app.sh | grep -E "^kind:|name:" | head -20
bash scripts/tests/test-render-argocd-app.sh
```

Expected: two AppProjects and two Applications in the rendered stream, AppProject before Application
in each pair, and the existing test still passing. If that test pins "exactly one Application",
update it to the new expectation and say so in your report.

- [ ] **Step 6: Apply the Application to the cluster and confirm it syncs**

```bash
./scripts/render-argocd-app.sh | kubectl apply -f -
kubectl -n argocd get application observability \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
./scripts/render-argocd-app.sh --check
```

Expected: `Synced Healthy` (an empty chart syncs to nothing, which is healthy), and `--check` passes.

- [ ] **Step 7: Commit**

```bash
git add charts/observability argocd/voteball-application.yaml.tmpl scripts/render-argocd-app.sh scripts/tests/test-render-argocd-app.sh
git commit -m "feat(observability): a chart and an ArgoCD Application to deliver it

Dashboards and platform alerts belong in git, not in a UI, and they
belong on the git-push path rather than behind a terraform apply -- the
same argument prometheusrule.yaml already makes for app alerts.

Its own AppProject rather than widening voteball's: an AppProject exists
to pin one repo to one namespace, and reusing it would let a mistake in
either chart deploy into the other's namespace."
git push origin master
```

---

### Task 3: The observability namespace's own default-deny

**Files:**
- Create: `charts/observability/templates/networkpolicy.yaml`

**Interfaces:**
- Consumes: the chart skeleton from Task 2
- Produces: default-deny in `observability`, with the egress every component genuinely needs

**THE EGRESS LIST IS THE DANGEROUS HALF.** Prometheus needs its scrape targets and the Kubernetes API
for service discovery; Grafana needs Prometheus; and **Alertmanager needs the public internet** — SNS
through the NAT gateway, and STS to assume its IRSA role. Omit that last one and every alert still
evaluates, still fires, still shows as firing in the UI, and no notification is ever delivered. That
is the identical shape as the `allow-app-egress` bug that left the nightly backup broken for twelve
days.

- [ ] **Step 1: Write the policies**

Create `charts/observability/templates/networkpolicy.yaml`:

```yaml
# Until this chart existed, `observability` was the one unrestricted namespace in a cluster where
# every other namespace is default-deny. These policies close that, but the egress list below is the
# half that can fail silently -- read its comments before narrowing anything.
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "observability.labels" . | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# DNS. Without this every outbound name lookup fails and the symptom looks like "no network at all".
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "observability.labels" . | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
# Everything this namespace legitimately reaches OUTWARD.
#
# Written as broad egress rather than an enumerated allowlist, for the same reason
# charts/jenkins-support does: Prometheus scrapes pod IPs across several namespaces, the kubelet on
# every node, and the Kubernetes API; Alertmanager reaches SNS and STS on public AWS endpoints whose
# addresses shift. An IP allowlist here would be brittle rather than secure.
#
# THE AWS RULE IS LOAD-BEARING. Alertmanager assumes its IRSA role via STS and publishes to SNS, both
# over the public internet through the NAT gateway. Remove it and alerts fire forever and are never
# delivered -- the failure mode this whole design exists to avoid, in the component that exists to
# avoid it.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-observability-egress
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "observability.labels" . | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    # Scrape targets and the Kubernetes API, both inside the VPC.
    - to:
        - ipBlock: { cidr: 10.0.0.0/16 }
    # SNS and STS. Public AWS endpoints reached through the NAT gateway.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/16
              - 172.16.0.0/12
              - 192.168.0.0/16
---
# Ingress: within the namespace (Grafana -> Prometheus, Prometheus -> Alertmanager), and from `ci` so
# the CD monitoring gate of the next plan can query Prometheus. Nothing else. The UIs are reached by
# `kubectl port-forward`, which goes through the API server and is not subject to NetworkPolicy at
# all -- so restricting ingress here does not lock the operator out.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-observability-ingress
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "observability.labels" . | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ci
      ports:
        - { protocol: TCP, port: 9090 }
{{- end }}
```

- [ ] **Step 2: Render and check for the empty-list trap**

```bash
helm lint charts/observability
helm template observability charts/observability --namespace observability > /tmp/obs-np.yaml
grep -nE ":\s*\[\]" /tmp/obs-np.yaml            # must print nothing
grep -c "kind: NetworkPolicy" /tmp/obs-np.yaml  # expect 4
bash scripts/ci/validate-repo.sh
```

- [ ] **Step 3: Commit, then watch what it does to the live cluster**

This lands through ArgoCD within minutes and can break metric collection if wrong. After pushing:

```bash
git add charts/observability/templates/networkpolicy.yaml
git commit -m "feat(observability): default-deny, with the egress Alertmanager actually needs

This namespace was the one unrestricted space in a cluster where every
other namespace is locked down.

The egress list is the half that fails silently: Alertmanager assumes its
IRSA role via STS and publishes to SNS over the public internet, so
without that rule every alert still evaluates, still fires, still shows as
firing -- and is never delivered."
git push origin master
```

Then wait for the sync and verify nothing broke:

```bash
kubectl -n argocd get application observability -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
curl -s -G http://localhost:9090/api/v1/query --data-urlencode 'query=up' \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['result']; print('targets',len(d),'up',sum(1 for s in d if s['value'][1]=='1'))"
pkill -f "port-forward svc/kube-prometheus-stack"
kubectl -n observability logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --tail=50 | grep -ciE "denied|error|refused"
```

Expected: `Synced Healthy`, the same target count as before with all UP, and zero Alertmanager errors.
**A drop in the UP count means the egress rule is too narrow — report it immediately with the numbers
before and after.**

---

### Task 4: SLI/SLO recording rules and the application alerts

**Files:**
- Modify: `charts/voteball/templates/prometheusrule.yaml`

**Interfaces:**
- Consumes: the metrics confirmed live above
- Produces: recording rules `voteball:*` and four application alerts, all with `runbook_url`

- [ ] **Step 1: Add the recording rules**

Recording rules, not expressions typed into panels, so the dashboard, the alert, the CD gate of the
next plan and the writeup all cite one definition. Add a new group at the top of `spec.groups` in
`charts/voteball/templates/prometheusrule.yaml`:

```yaml
    # The SLIs, computed once and referenced everywhere. The journey is the three endpoints a voter
    # actually traverses -- load the options, cast the ballot, read the results -- not every route the
    # API happens to expose, because an admin endpoint erroring does not mean a voter was failed.
    - name: voteball.sli
      rules:
        - record: voteball:journey_requests:rate5m
          expr: |
            sum(rate(voteball_http_requests_total{
              namespace="{{ .Release.Namespace }}",
              endpoint=~"/api/(options|vote|results.*)"
            }[5m]))

        - record: voteball:journey_errors:rate5m
          expr: |
            sum(rate(voteball_http_requests_total{
              namespace="{{ .Release.Namespace }}",
              endpoint=~"/api/(options|vote|results.*)", status=~"5.."
            }[5m]))

        # Availability as a ratio in 0..1. `or vector(1)` covers the quiet-night case: with no traffic
        # the division is 0/0 = NaN, and a NaN availability would read as a breach in every panel and
        # alert that consumes it. No requests means nothing failed.
        - record: voteball:availability:ratio5m
          expr: |
            1 - (
              voteball:journey_errors:rate5m
              / clamp_min(voteball:journey_requests:rate5m, 0.0000001)
            ) or vector(1)

        - record: voteball:latency:p95_5m
          expr: |
            histogram_quantile(0.95, sum by (le) (rate(
              voteball_http_request_duration_seconds_bucket{namespace="{{ .Release.Namespace }}"}[5m]
            )))
```

- [ ] **Step 2: Add the four application alerts**

Append a new group. Every alert carries `runbook_url` pointing at the file Task 6 creates:

```yaml
    - name: voteball.slo
      rules:
        - alert: VoteballHighErrorRate
          # 5% of the voting journey failing. Deliberately NOT "any 5xx": a single error on a public
          # site is noise, a sustained ratio is an outage.
          expr: |
            (voteball:journey_errors:rate5m
             / clamp_min(voteball:journey_requests:rate5m, 0.0000001)) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "More than 5% of voting-journey requests are failing"
            description: "The site may still render: /health is a static response and the liveness probe is a bare TCP check, so pods stay Ready while every API call fails."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/VoteballHighErrorRate.md"

        - alert: VoteballHighLatencyP95
          expr: voteball:latency:p95_5m > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "95th-percentile latency above the 1s SLO"
            description: "p95 has been over 1s for 10 minutes. The 1s boundary is a real histogram bucket edge, so this number is measured rather than interpolated."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/VoteballHighLatencyP95.md"

        - alert: VoteballRollupsStale
          # The worker is notification-driven with a 30s polling backstop. If LISTEN stops delivering
          # AND the poll wedges, the site serves stale results with every pod Ready and every other
          # alert quiet. Age of this gauge is the only signal that sees it.
          expr: |
            time() - max(voteball_worker_last_success_timestamp_seconds{namespace="{{ .Release.Namespace }}"}) > 600
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Results are more than 10 minutes stale"
            description: "The worker has not completed a successful recompute in over 10 minutes. Votes are still being recorded; the published results are frozen."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/VoteballRollupsStale.md"

        - alert: VoteballAvailabilitySLOBreach
          # The SLO itself: 99% of journey requests succeed. Evaluated over 6h rather than the stated
          # 7-day window because a 7d average moves too slowly to act on -- the window that matters
          # for paging is the one where recovery is still possible.
          expr: avg_over_time(voteball:availability:ratio5m[6h]) < 0.99
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Availability below the 99% SLO over the last 6 hours"
            description: "Sustained failures rather than a spike. Check whether an alert above already fired and was not acted on."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/VoteballAvailabilitySLOBreach.md"
```

- [ ] **Step 3: Add `runbook_url` to the seven existing rules**

The rules already in this file have `summary` and `description` but no runbook. Add one to each,
pointing at `docs/runbooks/<AlertName>.md`:

- `VoteballPodCrashLooping`
- `VoteballNoBackendAvailable`
- `VoteballMigrationJobFailed`
- `VoteballBackupJobFailed`
- `VoteballBackupMissing`
- `VoteballContainerOOMKilled`

**`VoteballDeploymentDegraded` is deliberately NOT in that list** — Task 5 deletes it, replacing it
with a cluster-wide `DeploymentReplicasMismatch` that carries its own runbook. Adding a link here
would create a reference to a file whose alert stops existing one task later.

List the runbook paths you referenced in your report, so Task 6 has the exact set.

- [ ] **Step 4: Validate the rules before they reach the cluster**

`promtool` is the only thing that will catch a malformed expression before Prometheus silently drops
the whole group:

```bash
helm template voteball charts/voteball --namespace devops-app > /tmp/vb.yaml
python3 - <<'PY' > /tmp/rules.yaml
import yaml, sys
docs = [d for d in yaml.safe_load_all(open('/tmp/vb.yaml')) if d and d.get('kind') == 'PrometheusRule']
print(yaml.safe_dump({'groups': [g for d in docs for g in d['spec']['groups']]}))
PY
docker run --rm -v /tmp/rules.yaml:/rules.yaml prom/prometheus:latest promtool check rules /rules.yaml
```

Expected: `SUCCESS` and a count of rules found. Fix anything it reports.

- [ ] **Step 5: Confirm every rule carries the release label, then commit**

```bash
grep -c "release: kube-prometheus-stack" /tmp/vb.yaml   # at least 1, on the PrometheusRule
helm lint charts/voteball
git add charts/voteball/templates/prometheusrule.yaml
git commit -m "feat(alerts): SLI/SLO recording rules and the four application alerts

Recording rules rather than expressions in panels, so the dashboard, the
alert, the CD gate and the writeup all cite one definition.

Availability carries `or vector(1)`: with no traffic the ratio is 0/0,
and a NaN would read as a breach on every quiet night.

Every rule here, and the seven that already existed, now carries a
runbook_url -- Alertmanager renders annotations into the SNS message, so
the link reaches the email that wakes someone up."
git push origin master
```

- [ ] **Step 6: Verify the rules loaded, not just that they applied**

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
curl -s http://localhost:9090/api/v1/rules \
  | python3 -c "
import json,sys
for g in json.load(sys.stdin)['data']['groups']:
    if g['name'].startswith('voteball'):
        print(g['name'], len(g['rules']), 'rules')
"
curl -s -G http://localhost:9090/api/v1/query --data-urlencode 'query=voteball:availability:ratio5m' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('availability =', r[0]['value'][1] if r else 'NO DATA')"
pkill -f "port-forward svc/kube-prometheus-stack"
```

Expected: the `voteball.sli` and `voteball.slo` groups listed, and an availability value between 0 and
1. **`NO DATA` means the recording rule has not evaluated or is broken** — do not proceed to the
dashboards, which consume it.

---

### Task 5: Platform alerts, and one rule per condition

**Files:**
- Create: `charts/observability/templates/prometheusrule.yaml`
- Modify: `charts/voteball/templates/prometheusrule.yaml` (remove one rule)
- Modify: `terraform/addon-monitoring.tf`

**Interfaces:**
- Consumes: the Jenkins metric names recorded in Task 1 Step 8
- Produces: four platform alerts, and the kube-prometheus-stack defaults they replace switched off

**Why this task exists:** 32 default `PrometheusRule` objects already run and route to SNS. Adding
rules that duplicate them means two emails for one condition, which is how an alert channel becomes
noise — the same instinct that already null-routed `Watchdog` and set `repeat_interval` to 12h. So
each new rule here replaces a specific default, and that default is switched off.

**The scope trap:** the defaults are cluster-wide. `VoteballDeploymentDegraded` in `charts/voteball` is
scoped to `devops-app`, so disabling the cluster-wide `KubeDeploymentReplicasMismatch` in its favour
would silently drop coverage of `ci`, `argocd` and `observability`. The fix is to move that rule here
and widen it, not to disable a broader rule in favour of a narrower one.

- [ ] **Step 1: Write the platform rules**

Create `charts/observability/templates/prometheusrule.yaml`:

```yaml
# Platform alerts: Kubernetes, Jenkins, and the monitoring system itself. Application alerts live in
# charts/voteball, next to the application they describe.
#
# EVERY RULE HERE REPLACES A kube-prometheus-stack DEFAULT, which terraform/addon-monitoring.tf
# switches off by name. One rule per condition: two emails about one problem trains the reader to
# stop opening them, which costs more than the second rule adds.
#
# These are deliberately CLUSTER-WIDE, matching the scope of the defaults they replace. A rule scoped
# to one namespace cannot replace a cluster-wide default without silently dropping coverage of every
# other namespace.
{{- if .Values.alerts.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-alerts
  namespace: {{ .Release.Namespace }}
  labels:
    # REQUIRED. Without it Prometheus never evaluates this object, while `kubectl get prometheusrules`
    # still lists it looking perfectly correct.
    release: kube-prometheus-stack
    {{- include "observability.labels" . | nindent 4 }}
spec:
  groups:
    - name: platform.kubernetes
      rules:
        - alert: NodeNotReadyOrUnderPressure
          # Replaces KubeNodeNotReady and KubeNodeUnreachable. The node group is 100% Spot, so a node
          # going away is routine -- 10m of NotReady is not.
          expr: |
            kube_node_status_condition{condition="Ready", status="true"} == 0
            or kube_node_status_condition{condition=~"MemoryPressure|DiskPressure", status="true"} == 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Node {{ `{{ $labels.node }}` }} is not Ready or is under resource pressure"
            description: "On a 100% Spot node group a brief NotReady is normal; ten minutes is not. Check whether the Cluster Autoscaler has replaced it."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/NodeNotReadyOrUnderPressure.md"

        - alert: DeploymentReplicasMismatch
          # Replaces KubeDeploymentReplicasMismatch. Cluster-wide on purpose -- this moved here from
          # charts/voteball, where it covered only devops-app and could not have replaced the default
          # without dropping ci, argocd and observability.
          expr: |
            kube_deployment_status_replicas_ready
              < kube_deployment_spec_replicas
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Deployment {{ `{{ $labels.namespace }}` }}/{{ `{{ $labels.deployment }}` }} is short of replicas"
            description: "Ready replicas below desired for 10 minutes. A rollout that never completed looks exactly like this."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/DeploymentReplicasMismatch.md"

    - name: platform.monitoring
      rules:
        - alert: PrometheusTargetDown
          # Replaces the default TargetDown. Cluster-wide, matching it: a scrape target being down is
          # how you learn the metrics you are about to trust are missing.
          expr: up == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Scrape target {{ `{{ $labels.job }}` }} in {{ `{{ $labels.namespace }}` }} is down"
            description: "Prometheus cannot reach this target. Any dashboard or alert built on its metrics is now blind rather than green."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/PrometheusTargetDown.md"

    - name: platform.jenkins
      rules:
        - alert: JenkinsQueueStuck
          # NOTE: the metric name below MUST match what the Jenkins prometheus plugin actually
          # exposes on this cluster -- it prefixes metrics with a configurable namespace. Use the
          # name recorded in Task 1 Step 8, not this placeholder, if they differ.
          expr: {{ .Values.jenkins.queueMetric }} > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Jenkins build queue has been non-empty for 15 minutes"
            description: "Builds are queued with nothing draining them. Usually no agent can be scheduled; the website is unaffected."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/JenkinsQueueStuck.md"
{{- end }}
```

Add to `charts/observability/values.yaml`:

```yaml
# The Jenkins queue-length metric name. The prometheus plugin prefixes its metrics with a configurable
# namespace (commonly `default_`), so this is a value rather than a literal in the template -- set it
# to whatever the live cluster actually exposes, recorded during the plugin rollout.
jenkins:
  queueMetric: "default_jenkins_queue_size_value"
```

**Correct that default to the real name from Task 1 Step 8 before committing.** A wrong name produces
an alert that can never fire — the exact failure this project's own rule comments warn against.

- [ ] **Step 2: Remove the now-duplicated rule from the app chart**

Delete the `VoteballDeploymentDegraded` rule from `charts/voteball/templates/prometheusrule.yaml`. It
is replaced by the cluster-wide `DeploymentReplicasMismatch` above. Leave every other rule there
alone — they describe the application specifically and have no default equivalent.

- [ ] **Step 3: Switch off the defaults these replace**

In `terraform/addon-monitoring.tf`, add to the `set` list:

```hcl
    # One rule per condition. Each of these defaults is replaced by a rule in
    # charts/observability/templates/prometheusrule.yaml that carries a runbook_url and is tuned to
    # this cluster. Leaving both on means two SNS emails for one problem, which is how an alert
    # channel becomes background noise.
    { name = "defaultRules.disabled.KubeNodeNotReady", value = "true" },
    { name = "defaultRules.disabled.KubeNodeUnreachable", value = "true" },
    { name = "defaultRules.disabled.KubeDeploymentReplicasMismatch", value = "true" },
    { name = "defaultRules.disabled.TargetDown", value = "true" },
```

Do NOT apply — Task 10 owns that.

- [ ] **Step 4: Validate and commit**

```bash
helm lint charts/observability
helm template observability charts/observability --namespace observability > /tmp/obs.yaml
grep -c "release: kube-prometheus-stack" /tmp/obs.yaml    # expect 1
cd terraform && terraform fmt -recursive && terraform validate && cd ..
```

Run the same `promtool check rules` extraction from Task 4 Step 4 against `/tmp/obs.yaml`. Expected:
`SUCCESS`.

```bash
git add charts/observability/templates/prometheusrule.yaml charts/observability/values.yaml \
        charts/voteball/templates/prometheusrule.yaml terraform/addon-monitoring.tf
git commit -m "feat(alerts): platform rules, one per condition

32 default rules already run and route to SNS. Each rule added here
replaces a specific default, which terraform switches off by name -- two
emails about one problem trains the reader to stop opening them.

DeploymentReplicasMismatch moves here from charts/voteball and widens to
the whole cluster. A rule scoped to devops-app could not have replaced the
cluster-wide default without silently dropping ci, argocd and
observability."
git push origin master
```

---

### Task 6: Runbooks

**Files:**
- Create: `docs/runbooks/README.md` and one file per alert

**Interfaces:**
- Consumes: the exact `runbook_url` paths referenced in Tasks 4 and 5
- Produces: a file at every referenced path

- [ ] **Step 1: Collect the exact set**

```bash
grep -rho "runbooks/[A-Za-z]*\.md" charts/ | sort -u
```

That list is the set of files you must create — no more, no fewer. A referenced file that does not
exist is a 404 in the email that wakes someone at 2am.

- [ ] **Step 2: Write each runbook**

One file per alert, written for the repo owner at 2am rather than for a platform engineer. Each
answers four questions in this order, and nothing else:

1. **What this means** — in plain language, one or two sentences.
2. **What to check first** — the exact commands, copy-pasteable.
3. **How to fix it** — the likely causes, most common first.
4. **When to roll back instead** — the condition under which stopping is better than diagnosing.

Use this shape (`docs/runbooks/VoteballHighErrorRate.md`):

```markdown
# VoteballHighErrorRate

**More than 5% of voting-journey requests are returning 5xx, for 5 minutes.**

## What this means

Visitors are being failed. The site may still *look* fine — `/health` is a static response and the
liveness probe is a bare TCP check, so neither touches the database. Pods stay `Ready` while every API
call fails. That gap is exactly why this alert exists.

## What to check first

```bash
kubectl get pods -n devops-app
kubectl logs -n devops-app -l app=backend --tail=50 | grep -i error
```

Then which endpoint is failing, and whether it is the database:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# in the UI at localhost:9090, run:
#   sum by (endpoint, status) (rate(voteball_http_requests_total{status=~"5.."}[5m]))
#   rate(voteball_db_errors_total[5m])
```

A non-zero `voteball_db_errors_total` means the backend cannot reach RDS. That is a different problem
from application errors, and the fix is different.

## How to fix it

- **Database unreachable** — check the RDS instance is available in the AWS console, and that
  `allow-app-egress` still permits it: `kubectl get networkpolicy -n devops-app allow-app-egress -o yaml`.
- **A bad release** — compare the running build against the last known good:
  `kubectl get deploy -n devops-app backend -o jsonpath='{.spec.template.spec.containers[0].image}'`.
  If it changed recently, roll back (below).
- **One bad pod** — if only one backend pod is erroring, delete it; the Deployment replaces it.

## When to roll back instead

If the error rate started within minutes of a deploy, roll back first and diagnose afterwards. Revert
`image.tag` in `charts/voteball/values.yaml` to the previous `ci: image tag` commit's value and push;
ArgoCD syncs it. Do not spend the outage reading logs.
```

Write the remaining runbooks to the same shape. For each, the "what to check first" commands must be
real and specific to that alert — a runbook that says "investigate the issue" is worse than no runbook,
because it consumed the reader's attention and returned nothing.

- [ ] **Step 3: Add the index**

`docs/runbooks/README.md`: a table of alert name → what it means → severity, plus a line explaining
that Alertmanager renders annotations into the SNS message, so these links arrive in the email.

- [ ] **Step 4: Verify every link resolves**

```bash
for f in $(grep -rho "runbooks/[A-Za-z]*\.md" charts/ | sort -u); do
  [ -f "docs/$f" ] && echo "ok   $f" || echo "MISSING $f"
done
```

Expected: every line `ok`. Any `MISSING` is a dead link in a production alert.

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/
git commit -m "docs(runbooks): one per alert, written for 2am

Each answers four questions and stops: what this means, what to check
first, how to fix it, when to roll back instead. The commands are real and
specific -- a runbook that says 'investigate the issue' is worse than none,
because it spent the reader's attention and returned nothing.

Alertmanager renders annotations into the SNS message, so these links
arrive in the email rather than sitting in a wiki nobody opens."
git push origin master
```

---

### Task 7: Dashboard — Application Overview

**Files:**
- Create: `charts/observability/dashboards/application-overview.json`
- Create: `charts/observability/templates/dashboards.yaml`

**Interfaces:**
- Consumes: `voteball:*` recording rules from Task 4
- Produces: a dashboard visible in Grafana, provisioned from git

- [ ] **Step 1: Write the ConfigMap wrapper**

One template renders every dashboard file, so Tasks 8 and 9 add JSON only. Create
`charts/observability/templates/dashboards.yaml`:

```yaml
# Grafana's sidecar container watches for ConfigMaps carrying `grafana_dashboard: "1"` and writes
# their contents into its provisioning directory. So a committed JSON file becomes a dashboard with no
# API call, no import button, and nothing for a human to click -- which is the brief's
# "Observability as Code" requirement made structural: there is nowhere for a hand-made dashboard to
# hide.
#
# `.Files.Glob` means adding a dashboard is adding a file. Do not add a per-dashboard template.
{{- if .Values.dashboards.enabled }}
{{- range $path, $bytes := .Files.Glob "dashboards/*.json" }}
{{- $name := base $path | trimSuffix ".json" }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-{{ $name }}
  namespace: {{ $.Release.Namespace }}
  labels:
    grafana_dashboard: "1"
    {{- include "observability.labels" $ | nindent 4 }}
data:
  {{ $name }}.json: |
{{ $.Files.Get $path | indent 4 }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Author the dashboard**

Create `charts/observability/dashboards/application-overview.json` as a valid Grafana dashboard with
`"uid": "voteball-app"`, `"title": "Application Overview"`, `"tags": ["voteball"]`, a 30s refresh, and
a default time range of the last 6 hours. Every panel's datasource is the Prometheus datasource the
stack provisions — reference it as `{"type": "prometheus", "uid": "${DS_PROMETHEUS}"}` or by the
concrete uid you read from the live Grafana; whichever you choose, verify it renders with data in
Step 4 rather than assuming.

The panels, with the exact query each must use:

| Panel | Type | Query |
|---|---|---|
| Request rate | timeseries | `sum by (endpoint) (rate(voteball_http_requests_total{namespace="devops-app"}[5m]))` |
| Error rate (5xx) | timeseries | `sum(rate(voteball_http_requests_total{namespace="devops-app",status=~"5.."}[5m]))` |
| Availability vs SLO | stat | `voteball:availability:ratio5m` — unit `percentunit`, threshold red below `0.99` |
| Latency p50 / p95 / p99 | timeseries | `histogram_quantile(0.50, sum by (le) (rate(voteball_http_request_duration_seconds_bucket{namespace="devops-app"}[5m])))` and the same with `0.95`, `0.99`; unit `s` |
| p95 vs 1s SLO | stat | `voteball:latency:p95_5m` — unit `s`, threshold red above `1` |
| **Votes cast** | stat | `sum(increase(voteball_votes_cast_total{namespace="devops-app"}[24h]))` — the business metric, 24h window |
| Ballots rejected by reason | timeseries | `sum by (reason) (rate(voteball_votes_rejected_total{namespace="devops-app"}[15m]))` |
| Database errors | timeseries | `sum(rate(voteball_db_errors_total{namespace="devops-app"}[5m]))` |
| Results freshness | stat | `time() - max(voteball_worker_last_success_timestamp_seconds{namespace="devops-app"})` — unit `s`, red above `600` |
| **Running build** | table | `voteball_app_info{namespace="devops-app"}` — instant, showing the `version`/`git_sha` labels |
| Frontend (nginx) request rate | timeseries | `sum(rate(nginx_http_requests_total{namespace="devops-app"}[5m]))` |

The "Running build" panel is what makes the brief's defense chain — commit → build → image → pod →
dashboard — a thing you point at rather than describe.

- [ ] **Step 3: Validate the JSON before it reaches Grafana**

```bash
python3 -c "
import json
d = json.load(open('charts/observability/dashboards/application-overview.json'))
assert d.get('uid'), 'no uid'
assert d.get('title'), 'no title'
panels = d.get('panels', [])
assert panels, 'no panels'
empty = [p['title'] for p in panels if not any(t.get('expr') for t in p.get('targets', []))]
assert not empty, f'panels with no query: {empty}'
print(f\"ok: {d['title']} ({d['uid']}) — {len(panels)} panels\")
"
helm template observability charts/observability --namespace observability | grep -c "grafana_dashboard"
```

Expected: the `ok:` line, and at least 1 for the label count.

- [ ] **Step 4: Commit, then confirm it appears in Grafana WITH DATA**

Push, wait for the ArgoCD sync, then:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1 &
sleep 8
PW=$(kubectl get secret kube-prometheus-stack-grafana -n observability -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$PW" http://localhost:3000/api/search?query=Application | python3 -m json.tool | head -20
pkill -f "port-forward svc/kube-prometheus-stack-grafana"
```

Expected: the dashboard listed. **A dashboard that exists but renders empty panels does not satisfy
the brief** — open it in a browser (`kubectl port-forward` then `localhost:3000`) and confirm the
panels have lines and numbers, not "No data". Report which panels, if any, are empty and why.

- [ ] **Step 5: Commit**

```bash
git add charts/observability/dashboards/application-overview.json charts/observability/templates/dashboards.yaml
git commit -m "feat(dashboards): Application Overview, provisioned from git

The sidecar discovers ConfigMaps labelled grafana_dashboard, so a
committed JSON file becomes a dashboard with no API call and no import
button -- there is nowhere for a hand-made dashboard to hide.

Hand-authored rather than imported: a 120KB community dashboard cannot be
defended panel by panel, and half its queries reference exporters this
cluster does not run, which renders as empty panels -- the visual
equivalent of an alert that can never fire."
git push origin master
```

---

### Task 8: Dashboard — Kubernetes / Cluster

**Files:**
- Create: `charts/observability/dashboards/kubernetes-cluster.json`

- [ ] **Step 1: Author it**

`"uid": "voteball-k8s"`, `"title": "Kubernetes / Cluster"`. Answers one question: *is the fault in the
app or the platform?*

| Panel | Type | Query |
|---|---|---|
| Nodes ready | stat | `sum(kube_node_status_condition{condition="Ready",status="true"})` |
| Node CPU used | timeseries | `1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` — unit `percentunit` |
| Node memory used | timeseries | `1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` — unit `percentunit` |
| Pods by phase | timeseries | `sum by (phase) (kube_pod_status_phase)` |
| Pod restarts (1h) | table | `sort_desc(sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0)` |
| Containers OOMKilled | timeseries | `sum by (namespace, pod) (increase(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[1h]))` |
| CPU throttling | timeseries | `sum by (namespace, pod) (rate(container_cpu_cfs_throttled_seconds_total{namespace=~"devops-app\|ci\|observability"}[5m]))` |
| Pending pods | stat | `sum(kube_pod_status_phase{phase="Pending"})` — red above 0 |
| Desired vs available replicas | timeseries | `kube_deployment_spec_replicas` and `kube_deployment_status_replicas_available` |
| PVC usage | timeseries | `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes` — unit `percentunit` |

The PVC panel matters more than it looks: Prometheus' own volume is on it, and filling it crashes
Prometheus rather than dropping old data, which is what `retentionSize` guards against.

- [ ] **Step 2: Validate, commit, and confirm data**

Same JSON validation as Task 7 Step 3, the same Grafana check as Step 4, then commit.

```bash
git add charts/observability/dashboards/kubernetes-cluster.json
git commit -m "feat(dashboards): Kubernetes / Cluster

Answers one operational question -- is the fault in the app or the
platform. The PVC panel is not filler: Prometheus' own volume is on it,
and a full volume crashes Prometheus rather than dropping old data."
git push origin master
```

---

### Task 9: Dashboard — Jenkins & Delivery

**Files:**
- Create: `charts/observability/dashboards/jenkins-delivery.json`

**Depends on Task 1.** If Jenkins metrics are not being scraped, this dashboard renders empty and does
not satisfy the brief. Confirm before authoring:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
curl -s http://localhost:9090/api/v1/label/__name__/values \
  | python3 -c "import json,sys; print([n for n in json.load(sys.stdin)['data'] if 'jenkins' in n])"
pkill -f "port-forward svc/kube-prometheus-stack"
```

- [ ] **Step 1: Author it against the REAL metric names**

`"uid": "voteball-delivery"`, `"title": "Jenkins & Delivery"`. **Use the names the query above
returned, not the ones written here** — the plugin prefixes its metrics with a configurable namespace,
so these are the shape to look for rather than literals to copy:

| Panel | Type | Metric to find |
|---|---|---|
| Queue length | timeseries | the queue-size gauge (`*_jenkins_queue_size_value`) |
| Queue wait time | timeseries | the queue-waiting gauge (`*_jenkins_queue_waiting_value` or similar) |
| Executors: total vs busy | timeseries | `*_jenkins_executor_count_value` and `*_jenkins_executor_in_use_value` |
| Online agents | stat | `*_jenkins_node_online_value` or the node-count gauge |
| Build outcomes | timeseries | the per-result build counters (success/failure/unstable) |
| Build duration | timeseries | the build-duration summary or gauge |
| Controller JVM heap | timeseries | `*_vm_memory_heap_used` / `*_vm_memory_heap_max` |
| **Last successful release** | stat | `time() - max(voteball_app_info)` is NOT this — use the `ci: image tag` deploy signal available to you, or omit the panel and say why in your report |

For that last row: if no metric genuinely captures "last successful release", **leave the panel out and
say so**. An empty panel labelled with an important question is worse than its absence — it reads as
coverage that does not exist. Plan 4 adds a CD-side signal that would fill it honestly.

- [ ] **Step 2: Validate, confirm data, commit**

Same validation and Grafana check as Task 7. In your report, state for every panel whether it rendered
real data — this is the dashboard most likely to have empty panels, and the brief explicitly fails
dashboards without real data.

```bash
git add charts/observability/dashboards/jenkins-delivery.json
git commit -m "feat(dashboards): Jenkins & Delivery

Written against the metric names this cluster actually exposes, read from
the live label API rather than assumed -- the plugin prefixes its metrics
with a configurable namespace, so a guessed name renders an empty panel,
which is the visual equivalent of an alert that can never fire."
git push origin master
```

---

### Task 10: Apply, verify, and prove a clean install

**⚠ STOPS FOR APPROVAL.** Runs `terraform apply` to switch off the duplicated default rules. Small
change, but it touches the live monitoring release.

- [ ] **Step 1: Plan and apply the default-rule changes**

```bash
cd terraform && terraform plan -var-file=voteball.tfvars -out=/tmp/rules.tfplan 2>&1 | tail -25
```

Expected: `helm_release.kube_prometheus_stack` updated in place. **If it proposes REPLACING it, stop**
— a replacement would destroy and recreate the release, which now has a PVC attached. Report it.

```bash
cd terraform && terraform apply /tmp/rules.tfplan
```

- [ ] **Step 2: Confirm exactly one rule per condition**

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
curl -s http://localhost:9090/api/v1/rules | python3 -c "
import json,sys
names=[r['name'] for g in json.load(sys.stdin)['data']['groups'] for r in g['rules'] if r['type']=='alerting']
for n in ['KubeNodeNotReady','KubeNodeUnreachable','KubeDeploymentReplicasMismatch','TargetDown']:
    print(f'{n:35} {\"STILL PRESENT (should be off)\" if n in names else \"disabled ok\"}')
for n in ['NodeNotReadyOrUnderPressure','DeploymentReplicasMismatch','PrometheusTargetDown','JenkinsQueueStuck','VoteballHighErrorRate','VoteballHighLatencyP95','VoteballRollupsStale','VoteballAvailabilitySLOBreach']:
    print(f'{n:35} {\"present\" if n in names else \"MISSING\"}')
print('total alerting rules:', len(names))
"
pkill -f "port-forward svc/kube-prometheus-stack"
```

Expected: all four defaults `disabled ok`, all eight replacements `present`.

- [ ] **Step 3: Confirm every alert has a runbook that resolves**

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 8
curl -s http://localhost:9090/api/v1/rules | python3 -c "
import json,sys
for g in json.load(sys.stdin)['data']['groups']:
    for r in g['rules']:
        if r['type']=='alerting' and (r['name'].startswith(('Voteball','Node','Deployment','Prometheus','Jenkins'))):
            a=r.get('annotations',{})
            missing=[k for k in ('summary','description','runbook_url') if k not in a]
            print(f\"{r['name']:35} {'ok' if not missing else 'MISSING '+','.join(missing)}\")
"
pkill -f "port-forward svc/kube-prometheus-stack"
```

- [ ] **Step 4: Fire one alert for real and confirm it is delivered**

The design's named silent failure is an alert that fires and never arrives. Prove otherwise. Scale a
non-critical Deployment down so `DeploymentReplicasMismatch` fires, wait, then restore:

```bash
kubectl -n devops-app scale deploy/frontend --replicas=1
# wait 11 minutes, then:
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null 2>&1 &
sleep 5
curl -s http://localhost:9093/api/v2/alerts | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    print(a['labels'].get('alertname'), a['status']['state'])
"
pkill -f "port-forward svc/kube-prometheus-stack-alertmanager"
kubectl -n devops-app scale deploy/frontend --replicas=2
```

Expected: the alert appears in Alertmanager. **Then confirm the SNS email actually arrived** — ask the
repo owner, since only they can see the mailbox. Record their answer; an alert that fires and is not
delivered is the failure this whole design exists to prevent, and nothing short of a received message
proves the chain.

- [ ] **Step 5: Prove a clean install (the brief's requirement)**

Delete the Application and re-sync. The dashboards must come back on their own, which is what
distinguishes provisioned dashboards from ones somebody clicked together:

```bash
kubectl -n argocd delete application observability
kubectl -n observability get configmap -l grafana_dashboard=1 --no-headers | wc -l   # expect 0
./scripts/render-argocd-app.sh | kubectl apply -f -
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/observability --timeout=180s
kubectl -n observability get configmap -l grafana_dashboard=1 --no-headers | wc -l   # expect 3
```

- [ ] **Step 6: Capture evidence**

Write `docs/eks/evidence/2026-08-18-observability-as-code.txt` covering: the rule inventory from Step 2,
the annotation check from Step 3, the alert firing and its delivery answer from Step 4, the clean-install
proof from Step 5, and a screenshot list of the three dashboards with a note on which panels carried
real data. Follow the format of the existing files in that directory.

- [ ] **Step 7: Update the docs**

- `docs/design/2026-08-17-observability-design.md` — add a "Verification outcome" section recording
  what actually broke, as the other design docs in this repo do. If §3's table still places the
  Jenkins ServiceMonitor in `charts/observability`, correct it to `charts/jenkins-support`.
- `README.submission.md` — a section on the observability stack: what is monitored, the three
  dashboards, the SLI/SLO, the eight alerts, and how to reach Grafana.
- `CLAUDE.md` — add `charts/observability` to the deployment section, and note that the Jenkins
  ServiceMonitor's enablement is coupled to a controller-image rebuild.
- `docs/deploy.md` — the port-forward commands for the new Application, and how to add a dashboard
  (add a JSON file; the sidecar and `.Files.Glob` do the rest).

- [ ] **Step 8: Commit, then delete this plan**

```bash
git add docs/
git commit -m "docs: record the observability stack and what verifying it found"
git push origin master
git rm -r docs/superpowers
git commit -m "chore: remove the executed observability-as-code plan

Standing rule: a plan is deleted the moment it is executed. Git history is
the archive; the design doc and the evidence file are the durable record."
git push origin master
```

---

## What plan 4 covers (not this plan)

The CI observability-validation stage (`scripts/ci/validate-observability.sh` — promtool on the rules,
dashboard JSON validation, and the `release: kube-prometheus-stack` label check that turns this plan's
most dangerous silent failure into a build failure), the CD post-deploy monitoring gate
(`scripts/ci/monitoring-gate.sh`, which depends on the `ci` → `observability` egress rule already in
place), their offline tests, and the four failure drills with their evidence.
