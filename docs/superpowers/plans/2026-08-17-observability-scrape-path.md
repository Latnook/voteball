# Observability Scrape Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the metrics that plan 1 emits actually reachable and stored — Prometheus scraping the
backend, worker, frontend and Jenkins, keeping 15 days of history on a real disk.

**Architecture:** Terraform owns the stack (namespace, EBS CSI driver, PVC, retention); the app chart
owns the Services, ServiceMonitors and NetworkPolicies that describe the application; the
jenkins-support chart owns the same for the `ci` namespace. The end state is every declared target
`UP` in Prometheus. No dashboards, no alert rules, no pipeline changes — those are plans 3 and 4.

**Tech Stack:** Terraform (aws ~> 5.0), Helm, kube-prometheus-stack 87.21.0, EKS 1.36, nginx,
Jenkins JCasC.

**Spec:** `docs/design/2026-08-17-observability-design.md` — sections 1, 2, 3, 5 (frontend exporter),
6 and 7. Sections 8-10 are plan 3; 11-13 are plan 4.

## Global Constraints

- **`PROMETHEUS_MULTIPROC_DIR` goes on the backend Deployment's own `env:`, NEVER in the `app-config`
  ConfigMap.** `charts/voteball/templates/migrate-job.yaml` consumes that ConfigMap via `envFrom` and
  runs `readOnlyRootFilesystem: true` with no writable `/tmp`. Putting it in the ConfigMap sends it to
  the migration Job, which gates every release. `metrics.py` degrades safely now, but do not rely on
  that — put it in the right place.
- **Every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` must carry the label
  `release: kube-prometheus-stack`.** Without it, Prometheus ignores the object: it is created, it
  appears in `kubectl get servicemonitors`, and it is silently never scraped.
- **A ServiceMonitor's `endpoints[].port` is a *Service port name*, not a number.** Every Service it
  targets must therefore have named ports.
- **Never write an empty list literal (`to: []`, `imagePullSecrets: []`) in a chart template.** The API
  server drops it on write, so the applied value can never equal the stored value, and every
  server-side apply conflicts forever. `scripts/ci/validate-repo.sh` fails the build on this.
- **`_helpers.tpl` output may never reach a `selector` or a pod template's labels.** Selectors are
  immutable after creation.
- **No image may be unpinned.** `scripts/ci/validate-repo.sh` fails on `:latest` or a missing tag.
- **`charts/voteball/values.yaml`'s ten sync-managed fields are written by
  `scripts/sync-values-from-tf.sh`** — `image.registry`, `image.tag`, `config.DB_HOST`,
  `config.S3_BUCKET`, `config.SNS_TOPIC`, `ingress.host`, `ingress.certificateArn`,
  `ingress.wafAclArn`, `backup.roleArn`, `worker.roleArn`. Never hand-edit those ten. New values you
  add are NOT sync-managed and are edited normally.
- **ArgoCD owns the `voteball` release.** Changes reach the cluster by committing to `master`, never
  by `helm upgrade`.
- **Terraform owns the Jenkins and monitoring releases.** Changes there reach the cluster by
  `terraform apply`, never by committing.
- **`terraform apply` creates billed resources (~$9.70/day).** Task 9 is the only task that applies,
  and it stops for explicit approval first.
- Commit and push as you go. Never force-push. No `Claude-Session:` trailer in any commit message.
- Run test suites ONE AT A TIME against the shared `voteball-test-db` container; two at once deadlock.

---

### Task 1: nginx stub_status and the frontend exporter sidecar

**Files:**
- Modify: `services/frontend/nginx.conf`
- Modify: `charts/voteball/templates/frontend-deployment.yaml`
- Modify: `charts/voteball/templates/frontend-service.yaml`
- Modify: `charts/voteball/values.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: frontend pods exposing nginx metrics on port `9113`, named `metrics` on the Service

- [ ] **Step 1: Add a stub_status endpoint bound to localhost**

nginx's own metrics come from its built-in `stub_status` module. Add this as a SECOND `server` block
at the end of `services/frontend/nginx.conf`, after the existing `server { listen 8080; ... }` block:

```nginx
# Metrics-only listener for the nginx-prometheus-exporter sidecar (see the frontend Deployment).
# Separate server block on its own port, never on 8080: the ALB forwards to 8080, so a /stub_status
# location there would be reachable from the internet. This one accepts only loopback, which in a
# pod means only a container in the SAME pod -- the exporter sidecar and nothing else.
server {
    listen 127.0.0.1:8081;
    server_name _;

    location = /stub_status {
        stub_status;
        access_log off;
    }

    location / { return 404; }
}
```

- [ ] **Step 2: Verify nginx accepts the config**

```bash
docker build -t voteball-nginx-check services/frontend
docker run --rm voteball-nginx-check nginx -t
docker rmi voteball-nginx-check
```

Expected: `syntax is ok` / `test is successful`. If it fails, the second `server` block is malformed —
fix it before continuing. (`nginx.conf` is already on the Dockerfile's `COPY` line; no change needed
there.)

- [ ] **Step 3: Resolve the exporter image tag**

Do not invent a version. Find the current release tag:

```bash
curl -s https://hub.docker.com/v2/repositories/nginx/nginx-prometheus-exporter/tags?page_size=20 \
  | python3 -c "import json,sys;[print(t['name']) for t in json.load(sys.stdin)['results']]"
```

Pick the newest plain semver tag (e.g. `1.4.2`, not `latest`, not a `-alpine` variant unless that is
all that exists). Record which you chose and why in your report.

- [ ] **Step 4: Add the exporter to values.yaml**

In `charts/voteball/values.yaml`, inside the existing `frontend:` block, after `resources:`:

```yaml
  # nginx metrics sidecar. Reads nginx's built-in stub_status over loopback and re-exposes it in
  # Prometheus format on 9113. Pinned by tag like every other image here -- validate-repo.sh fails
  # the build on an unpinned one.
  exporter:
    image: "nginx/nginx-prometheus-exporter:<the tag you resolved in Step 3>"
    resources:
      requests: { cpu: 10m, memory: 16Mi }
      limits: { cpu: 50m, memory: 32Mi }
```

- [ ] **Step 5: Add the sidecar container**

In `charts/voteball/templates/frontend-deployment.yaml`, add a second entry to the `containers:` list,
after the existing `frontend` container (match the file's existing indentation exactly — the container
list items are indented 8 spaces):

```yaml
        - name: exporter
          image: {{ .Values.frontend.exporter.image | quote }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            - --nginx.scrape-uri=http://127.0.0.1:8081/stub_status
          ports:
            - name: metrics
              containerPort: 9113
          resources:
            requests: { cpu: {{ .Values.frontend.exporter.resources.requests.cpu }}, memory: {{ .Values.frontend.exporter.resources.requests.memory }} }
            limits: { cpu: {{ .Values.frontend.exporter.resources.limits.cpu }}, memory: {{ .Values.frontend.exporter.resources.limits.memory }} }
          securityContext:
            # Same posture as every other container in this namespace. The exporter needs no
            # privileges at all -- it makes one loopback HTTP request and serves one endpoint.
            runAsNonRoot: true
            runAsUser: 101
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

- [ ] **Step 6: ADD a metrics port to the frontend Service — do not touch the existing one**

The existing entry is already named and already correct:

```yaml
    - name: http
      port: 80
      targetPort: 8080
```

**Leave those three lines exactly as they are.** `port: 80` is not a typo and is not interchangeable
with 8080: `charts/voteball/templates/ingress.yaml` routes to this Service by `port: number: 80`, so
changing it breaks the ALB target group and takes the site down. Only APPEND a second entry:

```yaml
    # The nginx exporter sidecar. Named because a ServiceMonitor selects an endpoint by Service port
    # NAME, never by number.
    - name: metrics
      port: 9113
      targetPort: 9113
```

- [ ] **Step 7: Render and lint**

```bash
helm lint charts/voteball
helm template voteball charts/voteball --namespace devops-app > /tmp/render-t1.yaml
grep -A3 "name: metrics" /tmp/render-t1.yaml | head -20
```

Expected: `helm lint` passes; the render shows the `metrics` port on both the Deployment and the
Service. Now confirm you did not disturb the path the site actually serves on:

```bash
grep -A4 "name: http" /tmp/render-t1.yaml | grep -A2 "port: 80"
grep -A6 "backend:" /tmp/render-t1.yaml | grep -A3 "name: frontend"
```

Expected: the frontend Service still publishes `port: 80` → `targetPort: 8080`, and the Ingress still
names `port: number: 80`. **If those two disagree the site is down** — the ALB target group points at
a port the Service no longer publishes. This is the one way this task can break production, so verify
it rather than assuming.

- [ ] **Step 8: Commit**

```bash
git add services/frontend/nginx.conf charts/voteball/templates/frontend-deployment.yaml \
        charts/voteball/templates/frontend-service.yaml charts/voteball/values.yaml
git commit -m "feat(frontend): expose nginx metrics via a stub_status sidecar

The design's first draft skipped this on the grounds that errors originate
in the backend. That reasoning fails for the case it matters: nginx serves
the HTML and proxies /api/*, so when the frontend is broken no request
reaches the backend at all -- and backend metrics therefore show nothing,
which on a graph is indistinguishable from a quiet night.

stub_status listens on 127.0.0.1:8081, not on 8080. The ALB forwards to
8080, so a status endpoint there would be public; loopback in a pod means
the sidecar and nothing else."
git push origin master
```

---

### Task 2: Wire the backend and worker for scraping

**Files:**
- Modify: `charts/voteball/templates/backend-service.yaml`
- Modify: `charts/voteball/templates/backend-deployment.yaml`
- Create: `charts/voteball/templates/worker-service.yaml`
- Modify: `charts/voteball/templates/worker-deployment.yaml`

**Interfaces:**
- Consumes: `services/backend/metrics.py` and `services/worker/metrics.py` from plan 1, which serve
  `/metrics` on backend port 5000 and worker port 9100
- Produces: Services named `backend` (port name `http`) and `worker` (port name `metrics`);
  backend pods carrying `APP_VERSION` and `PROMETHEUS_MULTIPROC_DIR`

- [ ] **Step 1: Name the backend Service's port**

In `charts/voteball/templates/backend-service.yaml`, replace the `ports:` list with:

```yaml
  ports:
    # Named because a ServiceMonitor selects an endpoint by Service port NAME, never by number.
    - name: http
      port: 5000
      targetPort: 5000
```

- [ ] **Step 2: Give the backend its two metrics environment variables**

In `charts/voteball/templates/backend-deployment.yaml`, add an `env:` block to the `backend`
container, immediately after the existing `envFrom:` block:

```yaml
          env:
            # NOT in the app-config ConfigMap, deliberately. migrate-job.yaml consumes that ConfigMap
            # via envFrom and runs readOnlyRootFilesystem with no writable /tmp, so a multiproc dir
            # set there would reach the migration Job -- the hook that gates every release.
            - name: PROMETHEUS_MULTIPROC_DIR
              value: /tmp/prom
            # gunicorn runs 2 workers per pod, each with its own counters. Without the directory
            # above, /metrics is answered by whichever worker accepts the connection, so the counter
            # alternates between two independent series -- non-monotonic, which rate() reads as
            # repeated counter resets and turns into meaningless spikes. Nothing fails loudly if this
            # is removed; see docs/design/2026-08-17-observability-design.md section 4.
            - name: APP_VERSION
              value: {{ .Values.image.tag | quote }}
```

The `/tmp` emptyDir this needs is already mounted on this container — do not add another volume.

- [ ] **Step 3: Give the worker a containerPort**

In `charts/voteball/templates/worker-deployment.yaml`, add a `ports:` block to the `worker`
container, immediately after `imagePullPolicy:`:

```yaml
          ports:
            - name: metrics
              containerPort: 9100
```

- [ ] **Step 4: Create the worker Service**

The worker has never had one — it makes no inbound connections. It needs one now only so a
ServiceMonitor has something to select. Create `charts/voteball/templates/worker-service.yaml`:

```yaml
# The worker serves no traffic; this Service exists solely so a ServiceMonitor can select it, since a
# ServiceMonitor selects Services rather than Pods. clusterIP: None (headless) because there is
# nothing to load-balance -- the worker is a singleton by design (see values.yaml's worker.replicas),
# and a headless Service means Prometheus scrapes the pod directly rather than through a virtual IP.
apiVersion: v1
kind: Service
metadata:
  name: worker
  namespace: {{ .Release.Namespace }}
  labels:
    app: worker
    {{- include "voteball.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  clusterIP: None
  selector:
    app: worker
  ports:
    - name: metrics
      port: 9100
      targetPort: 9100
```

- [ ] **Step 5: Render and check the three things that break silently**

```bash
helm lint charts/voteball
helm template voteball charts/voteball --namespace devops-app > /tmp/render-t2.yaml
echo "--- multiproc dir must NOT be in the ConfigMap ---"
awk '/kind: ConfigMap/,/^---/' /tmp/render-t2.yaml | grep -c PROMETHEUS_MULTIPROC_DIR
echo "--- it must be on the backend Deployment ---"
awk '/name: backend/,/^---/' /tmp/render-t2.yaml | grep -c PROMETHEUS_MULTIPROC_DIR
echo "--- APP_VERSION must carry the real image tag ---"
grep -A1 "name: APP_VERSION" /tmp/render-t2.yaml
```

Expected: `0` for the ConfigMap check, at least `1` for the Deployment check, and an `APP_VERSION`
whose value equals `image.tag` in `values.yaml`. **A non-zero ConfigMap count is a stop condition** —
it means the variable would reach the migration Job.

- [ ] **Step 6: Commit**

```bash
git add charts/voteball/templates/backend-service.yaml charts/voteball/templates/backend-deployment.yaml \
        charts/voteball/templates/worker-service.yaml charts/voteball/templates/worker-deployment.yaml
git commit -m "feat(chart): give backend and worker a scrapeable surface

Named Service ports, because a ServiceMonitor selects an endpoint by port
NAME -- an unnamed port matches nothing and looks healthy doing it. The
worker gets its first Service ever: it serves no traffic, but a
ServiceMonitor selects Services, not Pods.

PROMETHEUS_MULTIPROC_DIR is set on the backend Deployment and deliberately
NOT in the app-config ConfigMap, which the migration Job consumes via
envFrom while running a read-only root filesystem with no writable /tmp."
git push origin master
```

---

### Task 3: ServiceMonitors

**Files:**
- Create: `charts/voteball/templates/servicemonitor.yaml`
- Create: `charts/jenkins-support/templates/servicemonitor.yaml`
- Modify: `charts/voteball/values.yaml`
- Modify: `charts/jenkins-support/values.yaml`

**Interfaces:**
- Consumes: the named Service ports from Tasks 1 and 2
- Produces: three ServiceMonitors in `devops-app` and one in `ci`, all labelled
  `release: kube-prometheus-stack`

- [ ] **Step 1: Add the feature flag to values.yaml**

The chart must still render on a cluster with no Prometheus CRDs, exactly as `alerts.enabled` already
allows. In `charts/voteball/values.yaml`, next to the existing `alerts:` block:

```yaml
# ServiceMonitors (charts/voteball/templates/servicemonitor.yaml). Requires kube-prometheus-stack's
# ServiceMonitor CRD, which terraform/addon-monitoring.tf installs. Set false to render the chart
# against a cluster without it -- `helm template` succeeds either way, but `helm install` fails on an
# unknown kind. Same escape hatch, same reason, as alerts.enabled above.
serviceMonitors:
  enabled: true
```

And in `charts/jenkins-support/values.yaml`, at the end:

```yaml
# ServiceMonitor for the Jenkins controller's /prometheus endpoint (the `prometheus` plugin, added to
# ci/jenkins/plugins.txt). Requires the ServiceMonitor CRD; set false to render offline. Terraform
# passes the real value.
serviceMonitor:
  enabled: true
```

- [ ] **Step 2: Create the app ServiceMonitors**

Create `charts/voteball/templates/servicemonitor.yaml`:

```yaml
# Tells Prometheus what to scrape in this namespace. One ServiceMonitor per component, rather than one
# with three selectors, so each carries its own interval and path and a broken one takes only itself
# down.
#
# EVERY OBJECT HERE MUST CARRY `release: kube-prometheus-stack`. kube-prometheus-stack sets
# serviceMonitorSelectorNilUsesHelmValues=true by default, so Prometheus only picks up ServiceMonitors
# bearing its release label. Without it the object is created, looks correct in
# `kubectl get servicemonitors`, and is silently never scraped -- the same trap the PrometheusRule in
# prometheusrule.yaml documents.
#
# `port` names a SERVICE PORT NAME, never a number. The Services in this chart name their ports for
# exactly this reason.
{{- if .Values.serviceMonitors.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: backend
  namespace: {{ .Release.Namespace }}
  labels:
    app: backend
    release: kube-prometheus-stack
    {{- include "voteball.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels: { app: backend }
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: worker
  namespace: {{ .Release.Namespace }}
  labels:
    app: worker
    release: kube-prometheus-stack
    {{- include "voteball.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels: { app: worker }
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: frontend
  namespace: {{ .Release.Namespace }}
  labels:
    app: frontend
    release: kube-prometheus-stack
    {{- include "voteball.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels: { app: frontend }
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
{{- end }}
```

- [ ] **Step 3: Create the Jenkins ServiceMonitor**

It lives in `charts/jenkins-support` rather than in a separate observability chart: that chart already
owns every `ci`-namespace object this depends on (the Ingress and both NetworkPolicies), and it is
already wired to Terraform. Create `charts/jenkins-support/templates/servicemonitor.yaml`:

```yaml
# Scrapes the Jenkins controller's /prometheus endpoint, served by the `prometheus` plugin baked into
# the controller image (ci/jenkins/plugins.txt).
#
# The `release: kube-prometheus-stack` label is REQUIRED -- without it Prometheus ignores this object
# entirely while `kubectl get servicemonitors` still lists it.
#
# The selector matches the Service the official Jenkins chart creates, whose labels are set by that
# chart and not by this one. If the scrape target never appears, check the live Service's labels
# first: `kubectl get svc -n ci jenkins --show-labels`.
{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: jenkins
  namespace: {{ .Release.Namespace }}
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: jenkins-controller
      app.kubernetes.io/instance: jenkins
  endpoints:
    - port: http
      path: /prometheus
      interval: 30s
{{- end }}
```

- [ ] **Step 4: Verify both charts render, with and without the flag**

```bash
helm lint charts/voteball charts/jenkins-support
helm template voteball charts/voteball --namespace devops-app | grep -c "kind: ServiceMonitor"
helm template voteball charts/voteball --namespace devops-app --set serviceMonitors.enabled=false | grep -c "kind: ServiceMonitor"
helm template js charts/jenkins-support --namespace ci | grep -c "kind: ServiceMonitor"
```

Expected: `3`, then `0`, then `1`.

- [ ] **Step 5: Prove every ServiceMonitor carries the release label**

This is the check that pays for itself. Run it against the rendered output, not by eye:

```bash
helm template voteball charts/voteball --namespace devops-app > /tmp/r1.yaml
helm template js charts/jenkins-support --namespace ci > /tmp/r2.yaml
python3 - <<'PY'
import re, sys
missing = []
for path in ('/tmp/r1.yaml', '/tmp/r2.yaml'):
    for doc in open(path).read().split('\n---'):
        if 'kind: ServiceMonitor' in doc or 'kind: PrometheusRule' in doc:
            name = re.search(r'^\s+name:\s*(\S+)', doc, re.M)
            if 'release: kube-prometheus-stack' not in doc:
                missing.append(name.group(1) if name else '<unnamed>')
print('MISSING release label:', missing or 'none')
sys.exit(1 if missing else 0)
PY
```

Expected: `MISSING release label: none`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add charts/voteball/templates/servicemonitor.yaml charts/voteball/values.yaml \
        charts/jenkins-support/templates/servicemonitor.yaml charts/jenkins-support/values.yaml
git commit -m "feat(chart): declare what Prometheus should scrape

Four ServiceMonitors -- backend, worker, frontend exporter, Jenkins
controller -- each carrying release: kube-prometheus-stack. That label is
not decoration: the stack sets serviceMonitorSelectorNilUsesHelmValues,
so an object without it is created, listed by kubectl, and never scraped.

Gated behind serviceMonitors.enabled for the same reason alerts.enabled
exists: the chart must still render against a cluster with no Prometheus
CRDs installed."
git push origin master
```

---

### Task 4: NetworkPolicies — open the scrape path, and close what was never meant to be open

**Files:**
- Modify: `charts/voteball/templates/networkpolicy.yaml`
- Modify: `charts/jenkins-support/templates/networkpolicy.yaml`
- Modify: `charts/voteball/values.yaml`
- Modify: `charts/jenkins-support/values.yaml`
- Modify: `terraform/addon-jenkins.tf`

**Interfaces:**
- Consumes: the ports declared in Tasks 1-3
- Produces: `observability` namespace admitted to backend:5000, worker:9100, frontend:9113 and
  Jenkins:8080; the ALB rules narrowed from the whole VPC to the two public subnets; `ci` allowed
  egress to Prometheus on 9090

- [ ] **Step 1: Add the subnet CIDRs to both charts' values**

In `charts/voteball/values.yaml`, near the top-level keys:

```yaml
# The two PUBLIC subnet CIDRs from terraform/vpc.tf. Used by the frontend ingress policy to admit the
# ALB's network interfaces and nothing else.
#
# These are not sync-managed and change only if someone edits terraform/vpc.tf's `public_subnets`.
# A mismatch fails loudly and immediately -- the ALB's health checks are dropped and the target group
# goes unhealthy -- rather than silently.
network:
  albSubnetCidrs:
    - "10.0.0.0/20"
    - "10.0.16.0/20"
```

In `charts/jenkins-support/values.yaml`:

```yaml
# The two PUBLIC subnet CIDRs, where the ALB's network interfaces live. Terraform passes the real
# values; this default exists only so `helm template` runs offline, like vpcCidr above.
albSubnetCidrs:
  - "10.0.0.0/20"
  - "10.0.16.0/20"
```

- [ ] **Step 2: Narrow the app's ALB rule and admit the scrape**

In `charts/voteball/templates/networkpolicy.yaml`, replace the `allow-alb-to-frontend` policy's
`ingress:` block with:

```yaml
  ingress:
    # The ALB's network interfaces, and nothing else. Previously this said 10.0.0.0/16 -- the whole
    # VPC -- which reads as "the load balancer" but is not: the AWS VPC CNI gives every POD a VPC
    # address, so that rule also admitted every pod in the cluster. Both Ingresses are
    # scheme: internet-facing with target-type: ip, so the ALB's interfaces can only ever be in the
    # public subnets, which contain no pods.
    - from:
        {{- range .Values.network.albSubnetCidrs }}
        - ipBlock: { cidr: {{ . | quote }} }
        {{- end }}
      ports:
        - { protocol: TCP, port: 8080 }
```

Then append a new policy to the same file (after the last existing document, separated by `---`):

```yaml
---
# Prometheus scraping the application, granted BY NAME rather than inherited from an address range.
# After the narrowing above, this is the only thing that lets the observability namespace in, so the
# grant is deliberate and reviewable.
#
# The three ports are exactly the metrics endpoints: backend /metrics on 5000, worker /metrics on
# 9100, and the frontend's nginx exporter on 9113. Nothing else in this namespace is reachable from
# observability.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: {{ .Release.Namespace }}
spec:
  podSelector:
    matchExpressions:
      - { key: app, operator: In, values: [backend, worker, frontend] }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - { protocol: TCP, port: 5000 }
        - { protocol: TCP, port: 9100 }
        - { protocol: TCP, port: 9113 }
```

- [ ] **Step 3: Narrow the Jenkins ALB rule, admit the scrape, and allow CD to read Prometheus**

In `charts/jenkins-support/templates/networkpolicy.yaml`, in the `jenkins-ingress` policy, replace the
`ipBlock: {{ .Values.vpcCidr | quote }}` entry (the one commented as being for the ALB's ENIs) with:

```yaml
    - from:
        # The ALB reaches the controller from its own ENIs, which live in the PUBLIC subnets. This
        # used to say vpcCidr -- the whole VPC -- and because the AWS VPC CNI gives pods VPC
        # addresses, that admitted every pod in the cluster to the Jenkins controller on 8080. The
        # comment said "the ALB"; the rule said "the network". Narrowed to where the ALB actually is.
        {{- range .Values.albSubnetCidrs }}
        - ipBlock: { cidr: {{ . | quote }} }
        {{- end }}
        # Prometheus, granted by name now that the address range no longer grants it implicitly.
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 8080
```

Then, in the `jenkins-egress` policy, add one entry to the end of its `egress:` list:

```yaml
    # Prometheus, for the CD pipeline's post-deploy monitoring gate (plan 4). This is the one hole in
    # "CI/CD cannot reach anything inside the VPC" -- deliberately narrow: one namespace, one port,
    # read-only by nature. CD gains the ability to read metrics and keeps its inability to reach RDS
    # or the application.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 9090
```

- [ ] **Step 4: Pass the real subnet CIDRs from Terraform**

In `terraform/addon-jenkins.tf`, inside `resource "helm_release" "jenkins_support"`'s `set` list, add:

```hcl
    # The PUBLIC subnet CIDRs, where the ALB's ENIs live. The ingress rule that admits the load
    # balancer is scoped to these rather than to the whole VPC -- pods get VPC addresses from the
    # PRIVATE subnets, so the old vpcCidr rule admitted every pod in the cluster to the controller.
    { name = "albSubnetCidrs[0]", value = module.vpc.public_subnets_cidr_blocks[0] },
    { name = "albSubnetCidrs[1]", value = module.vpc.public_subnets_cidr_blocks[1] },
```

- [ ] **Step 5: Render, and check for the empty-list trap**

```bash
helm lint charts/voteball charts/jenkins-support
helm template voteball charts/voteball --namespace devops-app > /tmp/np1.yaml
helm template js charts/jenkins-support --namespace ci > /tmp/np2.yaml
echo "--- no whole-VPC rule should remain on an ALB path ---"
grep -n "10.0.0.0/16" /tmp/np1.yaml /tmp/np2.yaml
echo "--- empty list literals (must print nothing) ---"
grep -nE ":\s*\[\]" /tmp/np1.yaml /tmp/np2.yaml
bash scripts/ci/validate-repo.sh
```

Expected: the `10.0.0.0/16` grep still matches the jenkins **egress** exclusion (that one is correct
and must stay — it is what denies CI the VPC) but must NOT match any ingress rule. The empty-list grep
must print nothing. `validate-repo.sh` must pass.

- [ ] **Step 6: Run the existing chart test**

```bash
bash scripts/tests/test-jenkins-chart.sh
```

Expected: passes. If it asserts on the old `vpcCidr` ingress rule, update the assertion to the new
public-subnet form — the test is pinning the behaviour this task deliberately changes, so it must move
with it. Say in your report which assertions you changed and why.

- [ ] **Step 7: Commit**

```bash
git add charts/voteball/templates/networkpolicy.yaml charts/voteball/values.yaml \
        charts/jenkins-support/templates/networkpolicy.yaml charts/jenkins-support/values.yaml \
        terraform/addon-jenkins.tf scripts/tests/test-jenkins-chart.sh
git commit -m "feat(netpol): grant the scrape by name, and stop granting it by accident

Both ALB rules said 10.0.0.0/16 -- the whole VPC -- to mean 'the load
balancer'. The AWS VPC CNI gives every pod a VPC address, so what they
actually granted was 'any pod in the cluster may reach the Jenkins
controller on 8080'. Both Ingresses are internet-facing with
target-type: ip, so the ALB's interfaces can only be in the two public
subnets, which contain no pods.

With that narrowed, Prometheus is admitted explicitly by namespace label
to exactly four ports, and the CD agent gets one egress rule to
Prometheus on 9090 while keeping its inability to reach RDS or the app."
git push origin master
```

---

### Task 5: Jenkins exposes metrics

**Files:**
- Modify: `ci/jenkins/plugins.txt`

**Interfaces:**
- Consumes: the ServiceMonitor from Task 3, which scrapes `/prometheus` on the controller
- Produces: a controller image serving `/prometheus`

- [ ] **Step 1: Add the plugin**

In `ci/jenkins/plugins.txt`, add to the "what the Jenkinsfile uses" section (entries are bare artifact
ids; comments go on their own line, never trailing — `jenkins-plugin-cli` parses a trailing comment as
part of the id):

```
# exposes /prometheus on the controller: queue length and wait, executor and agent counts, build
# results and durations, JVM health. Scraped by the ServiceMonitor in charts/jenkins-support.
prometheus
```

- [ ] **Step 2: Confirm the plugin resolves**

The controller image bakes plugins at build time, so a bad id fails the image build, not the boot:

```bash
docker build -t voteball-jenkins-check ci/jenkins
docker run --rm voteball-jenkins-check jenkins-plugin-cli --list 2>&1 | grep -i prometheus
docker rmi voteball-jenkins-check
```

Expected: a line naming the prometheus plugin and its resolved version. If the build fails on an
unknown plugin id, the correct id may be `prometheus` or a renamed successor — check
`https://plugins.jenkins.io/prometheus/` and record what you used.

- [ ] **Step 3: Commit**

```bash
git add ci/jenkins/plugins.txt
git commit -m "feat(jenkins): add the prometheus plugin

Serves /prometheus on the controller -- queue, executors, agents, build
results and JVM. The ServiceMonitor scraping it already exists in
charts/jenkins-support.

Plugins are baked into the controller image, so this reaches the cluster
only via a rebuilt image and a terraform apply. Committing it alone
changes nothing."
git push origin master
```

---

### Task 6: Terraform — the EBS CSI driver and a gp3 StorageClass

**Files:**
- Create: `terraform/addon-ebs.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: a `gp3` StorageClass the Prometheus PVC in Task 7 will name

- [ ] **Step 1: Write the add-on**

EKS has shipped no in-tree EBS provisioner since 1.23, so without this a PVC sits `Pending` forever
with no error naming the cause. This mirrors `terraform/addon-efs.tf`'s structure exactly. Create
`terraform/addon-ebs.tf`:

```hcl
# EBS CSI driver + a gp3 StorageClass, for the Prometheus PVC in addon-monitoring.tf.
#
# WHY EBS HERE AND EFS FOR JENKINS -- opposite choices from the same constraint, deliberately.
# addon-efs.tf chose EFS for JENKINS_HOME because an EBS volume is locked to a single Availability
# Zone and this node group is 100% Spot. That reasoning does not transfer: Prometheus' TSDB is
# explicitly unsupported on network filesystems, where its memory-mapped, fsync-ordered writes can
# corrupt the database. The price is the AZ lock-in -- if the node holding the volume is reclaimed
# and its replacement lands in the other AZ, the Prometheus pod sits Pending until an AZ-a node
# exists again. That is acceptable ONLY because the data is disposable: 15 days of metrics, not 15
# days of votes. Recovery is deleting the PVC and losing history. Do not "make these consistent".
module "ebs_csi_irsa" {
  # Submodule path, matching every other IRSA role in this stack. The registry-root form
  # "terraform-aws-modules/iam-role-for-service-accounts-eks/aws" does not exist and fails at init.
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
}

resource "kubernetes_storage_class" "gp3" {
  metadata { name = "gp3" }

  storage_provisioner = "ebs.csi.aws.com"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # WaitForFirstConsumer, not Immediate: the volume must be created in the SAME Availability Zone as
  # the node that will mount it. Immediate binding picks an AZ before the scheduler has chosen a
  # node, which can strand the pod in Pending forever with a volume it cannot reach.
  volume_binding_mode = "WaitForFirstConsumer"

  # Delete, NOT the Retain that efs-sc uses. Retain exists for Jenkins so an accidental uninstall
  # cannot take the build history with it. Here it would mean a teardown that silently leaves a
  # billed EBS volume behind with nothing in Terraform's records pointing at it -- and unlike a
  # leftover ENI, an orphaned volume blocks nothing, so the destroy reports success.
  reclaim_policy = "Delete"

  depends_on = [aws_eks_addon.ebs_csi]
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform
terraform fmt -recursive
terraform init -backend-config=backend.hcl -upgrade
terraform validate
```

Expected: `Success! The configuration is valid.` Do NOT run `terraform apply` — Task 9 owns that.

- [ ] **Step 3: Commit**

```bash
git add terraform/addon-ebs.tf
git commit -m "feat(terraform): EBS CSI driver and a gp3 StorageClass

Prometheus needs a real disk and EKS has shipped no in-tree EBS
provisioner since 1.23, so a PVC without this driver sits Pending forever
with no error naming the cause.

EBS here where Jenkins uses EFS, on purpose: Prometheus' TSDB is
unsupported on network filesystems, where its mmap/fsync writes can
corrupt the database. The AZ lock-in that ruled EBS out for Jenkins is
acceptable for 15 days of disposable metrics. reclaim_policy is Delete,
not efs-sc's Retain -- an orphaned EBS volume bills forever and blocks
nothing, so a teardown would report success while leaking it."
git push origin master
```

---

### Task 7: Terraform — rename the namespace, give Prometheus a disk

**Files:**
- Modify: `terraform/addon-monitoring.tf`
- Modify: `terraform/irsa.tf`

**Interfaces:**
- Consumes: `kubernetes_storage_class.gp3` from Task 6
- Produces: kube-prometheus-stack in the `observability` namespace with a 10Gi PVC and 15-day
  retention

- [ ] **Step 1: Rename the namespace in the release**

In `terraform/addon-monitoring.tf`, change the `namespace` argument:

```hcl
  # The brief names this namespace. Renaming REPLACES the release: Terraform destroys and recreates
  # it, so the stack is down for the length of one apply. Nothing is lost -- see the storage block
  # below for what is and is not persistent.
  namespace        = "observability"
  create_namespace = true
```

- [ ] **Step 2: Update the Alertmanager IRSA trust condition**

In `terraform/irsa.tf`, the Alertmanager role's OIDC condition names the old namespace. Change:

```hcl
      values = ["system:serviceaccount:observability:kube-prometheus-stack-alertmanager"]
```

**This is load-bearing and easy to miss.** The trust policy names the namespace, so leaving it as
`monitoring` means Alertmanager's ServiceAccount can no longer assume the role — and the failure is
silent in exactly the worst way: alerts still evaluate, still fire, still show as firing in the UI,
and no SNS notification is ever delivered.

- [ ] **Step 3: Add storage and retention**

In `terraform/addon-monitoring.tf`, replace the three existing `set` entries with:

```hcl
  set = [
    {
      # Time-based retention. See retentionSize below -- this alone does not bound bytes.
      name  = "prometheus.prometheusSpec.retention"
      value = "15d"
    },
    {
      # Byte-based retention, at ~80% of the volume. Without it, a growing series count fills the
      # PVC and Prometheus CRASHES rather than dropping old data -- time-based retention has no
      # reason to delete anything still inside its window. Whichever limit binds first does the work.
      name  = "prometheus.prometheusSpec.retentionSize"
      value = "8GiB"
    },
    {
      name  = "prometheus.prometheusSpec.resources.requests.memory"
      value = "400Mi"
    },
    {
      name  = "prometheus.prometheusSpec.resources.limits.memory"
      value = "900Mi"
    },
    # A real disk, so history survives the roughly-daily Spot reclaim. Without it the TSDB lives in
    # the pod's ephemeral storage and every reclaim erases it -- "the error rate rose at 14:03" is
    # not a statement an ephemeral Prometheus can support.
    #
    # This is a StatefulSet volumeClaimTemplate, which means the PVC is NOT deleted by
    # `helm uninstall` or by deleting the StatefulSet. scripts/destroy.sh deletes it explicitly; see
    # the step added there.
    {
      name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
      value = kubernetes_storage_class.gp3.metadata[0].name
    },
    {
      name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]"
      value = "ReadWriteOnce"
    },
    {
      name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
      value = "10Gi"
    },
  ]
```

Note the existing `values = [yamlencode({...})]` block (the Alertmanager routing) stays exactly as it
is. Do not move the storage settings into it — `set` entries and `values` merge, and the routing tree
is in `values` only because it is deeply nested.

- [ ] **Step 4: Add the dependency on the StorageClass**

In the same resource, extend `depends_on`:

```hcl
  depends_on = [
    helm_release.aws_load_balancer_controller,
    # The PVC names this StorageClass; without the ordering, a from-scratch apply can create the
    # release first and leave Prometheus Pending on a class that does not exist yet.
    kubernetes_storage_class.gp3,
  ]
```

- [ ] **Step 5: Validate, and confirm the rename is complete**

```bash
cd terraform
terraform fmt -recursive
terraform validate
cd ..
grep -rn '"monitoring"' terraform/*.tf
grep -rn "serviceaccount:monitoring" terraform/*.tf
```

Expected: `terraform validate` succeeds, and BOTH greps return nothing. A surviving reference to the
old namespace is the failure this step exists to catch.

- [ ] **Step 6: Commit**

```bash
git add terraform/addon-monitoring.tf terraform/irsa.tf
git commit -m "feat(terraform): observability namespace, and a real disk for Prometheus

Renames the namespace to the one the brief names, which replaces the
release -- the stack is down for one apply and loses nothing, since it
had no persistent storage to lose.

The IRSA trust condition moves with it. That one is load-bearing: the
trust policy names the namespace, and leaving it behind means
Alertmanager cannot assume its role, which fails silently in the worst
way -- alerts still fire, still show as firing, and no notification is
ever delivered.

Storage is a 10Gi gp3 PVC with both retention limits set. Time-based
retention does not bound bytes: a growing series count would fill the
volume and crash Prometheus rather than dropping old data."
git push origin master
```

---

### Task 8: Teardown must not leak the volume

**Files:**
- Modify: `scripts/destroy.sh`
- Modify: `docs/deploy.md`

**Interfaces:**
- Consumes: the PVC created by Task 7
- Produces: a teardown that deletes it

- [ ] **Step 1: Find the insertion point**

```bash
grep -n '^\s*step "' scripts/destroy.sh
```

The new step goes immediately BEFORE the step that uninstalls this stack's Helm releases, and
therefore well before `terraform destroy`. Record the step numbers you see — they shift whenever a
step is inserted, which is why this plan does not name them.

- [ ] **Step 2: Add the cleanup step**

Insert into `scripts/destroy.sh`, in the position identified above, matching the file's existing
`step "..."` idiom:

```bash
step "Deleting the observability PVCs"
# A PVC created by a StatefulSet's volumeClaimTemplate is NOT removed by `helm uninstall`, by
# deleting the StatefulSet, or by deleting the namespace's workloads -- Kubernetes deliberately keeps
# it so a recreated StatefulSet re-binds its data. Left alone it becomes an orphaned EBS volume that
# bills forever, and unlike a leftover ENI it blocks nothing, so `terraform destroy` reports complete
# success while leaking it. The gp3 StorageClass's reclaim policy is Delete, so removing the PVC here
# is what actually deletes the volume.
#
# || true throughout: a cluster that is already gone, or was never built with this stack, must not
# fail the teardown.
kubectl delete pvc --all -n observability --ignore-not-found --timeout=60s || true
```

- [ ] **Step 3: Check the script still parses**

```bash
bash -n scripts/destroy.sh && echo "destroy.sh parses"
```

Expected: `destroy.sh parses`. This matters more than it looks — this repo has had a shell block that
did not parse pass a linter, a structural check and manual review.

- [ ] **Step 4: Document it**

`docs/deploy.md` lists what `destroy.sh` does that a manual `terraform destroy` does not. Add a bullet
to that list, in the voice of its neighbours:

```markdown
- **Deletes the `observability` PVCs.** A StatefulSet's volume claim survives `helm uninstall` and
  the StatefulSet itself, by design. Left behind it is an orphaned EBS volume that bills forever and
  blocks nothing — so the teardown would report success while leaking it.
```

Then check the step-count claim in that file has not drifted:

```bash
grep -c '^\s*step "' scripts/destroy.sh
grep -n "step" docs/deploy.md | grep -i destroy | head
```

If `docs/deploy.md` states a number of teardown steps, update it to what you just counted.

- [ ] **Step 5: Commit**

```bash
git add scripts/destroy.sh docs/deploy.md
git commit -m "fix(destroy): delete the observability PVCs before teardown

A PVC from a StatefulSet volumeClaimTemplate is not removed by helm
uninstall, by deleting the StatefulSet, or by deleting its workloads --
Kubernetes keeps it so a recreated StatefulSet rebinds its data. Left
alone it is an orphaned EBS volume that bills forever and, unlike a
leftover ENI, blocks nothing -- so terraform destroy reports complete
success while leaking it."
git push origin master
```

---

### Task 9: Apply, and prove every target is UP

**STOP. This task spends money and changes the live cluster. Do not begin it without the repo owner's
explicit go-ahead in this session.** It runs `terraform apply` against billed infrastructure
(~$9.70/day ongoing; this apply adds ~$1/month of EBS), and it briefly takes the monitoring stack down
while the namespace is replaced. The application itself is unaffected — the app chart's changes reach
the cluster through ArgoCD independently.

**Files:** none — this task changes no code.

**Interfaces:**
- Consumes: everything from Tasks 1-8
- Produces: a running observability stack with every declared target `UP`

- [ ] **Step 1: Show the plan and read it before applying**

```bash
cd terraform
terraform plan -var-file=voteball.tfvars -out=/tmp/obs.tfplan 2>&1 | tail -40
```

Expected to see, at minimum: the `kube_prometheus_stack` release **replaced** (namespace change), a
new `aws_eks_addon.ebs_csi`, a new `kubernetes_storage_class.gp3`, a new IRSA role, and an update to
the Alertmanager role's trust policy. **If the plan proposes destroying anything else — the RDS
instance, the EKS cluster, the node group, the ECR repositories — STOP and report it.** Nothing in
this plan should touch those.

- [ ] **Step 2: Apply**

```bash
cd terraform
terraform apply /tmp/obs.tfplan
```

Expect roughly 5-10 minutes. Stream the output; do not pipe it through `tail`, which masks the exit
code and can report a failed run as success.

- [ ] **Step 3: Confirm the stack came back in the new namespace**

```bash
kubectl get pods -n observability
kubectl get pvc -n observability
kubectl get storageclass gp3
```

Expected: Prometheus, Grafana, Alertmanager, node-exporter and kube-state-metrics all `Running`; one
`Bound` PVC of 10Gi on the `gp3` class. A PVC stuck `Pending` means the CSI driver or the StorageClass
is missing — check `kubectl describe pvc` for the reason before doing anything else.

- [ ] **Step 4: Push the chart changes through ArgoCD and wait**

The app chart changes (Tasks 1-4) are already on `master`, so ArgoCD may have synced them already.
Confirm, and wait if not:

```bash
kubectl get application voteball -n argocd -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
kubectl get pods -n devops-app
```

Expected: `Synced Healthy`, and frontend pods now showing `2/2` containers (nginx + exporter).

- [ ] **Step 5: Rebuild and redeploy Jenkins for the prometheus plugin**

The plugin is baked into the controller image, so Task 5's commit alone changed nothing:

```bash
cd terraform
terraform apply -var-file=voteball.tfvars -target=helm_release.jenkins
```

Then confirm the endpoint exists:

```bash
kubectl -n ci exec deploy/jenkins -c jenkins -- curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/prometheus
```

Expected: `200`. A `404` means the plugin is not installed — check that the image was actually rebuilt.

- [ ] **Step 6: THE ACCEPTANCE CHECK — every target UP, verified by query**

This is what the whole plan is for. Do not check it by eye in a UI:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF=$!
sleep 5
curl -s 'http://localhost:9090/api/v1/query?query=up' \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)['data']['result']
for s in sorted(d, key=lambda r: r['metric'].get('job','')):
    print(f\"{s['metric'].get('job','?'):45} {s['metric'].get('namespace','-'):15} {s['value'][1]}\")
"
kill $PF
```

Expected: rows for `backend`, `worker`, `frontend` (namespace `devops-app`) and `jenkins` (namespace
`ci`), each with value `1`. **A job that is absent entirely is the `release: kube-prometheus-stack`
label failure** — the ServiceMonitor exists and Prometheus never looked at it. **A job present with
value `0` is a NetworkPolicy or port problem** — the target was discovered but could not be reached.
The two failures look nothing alike; do not confuse them.

- [ ] **Step 7: Confirm the application metrics actually have values**

Targets being UP only proves the scrape connects. Confirm real data:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
PF=$!
sleep 5
for q in 'voteball_http_requests_total' 'voteball_votes_cast_total' 'voteball_app_info' \
         'voteball_worker_last_success_timestamp_seconds' 'nginx_up' 'jenkins_queue_size_value'; do
  n=$(curl -s "http://localhost:9090/api/v1/query?query=$q" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['data']['result']))")
  echo "$q -> $n series"
done
kill $PF
```

Expected: every one returns at least 1 series. `voteball_app_info` should carry the current image tag
as its `version`/`git_sha` labels — check that it matches `image.tag` in `values.yaml`, because that
correspondence is the commit→build→pod→dashboard chain the final defense asks you to demonstrate.

- [ ] **Step 8: Confirm the narrowed NetworkPolicy actually denies what it should**

A negative test, since the positive one above cannot distinguish "policy correct" from "policy
missing". Note the CNI fails OPEN for the first seconds of a pod's life, so the pod must wait before
connecting or a working policy and a missing one look identical:

```bash
kubectl -n devops-app run netcheck --image=busybox:1.36 --restart=Never --rm -it --command -- \
  sh -c 'sleep 75; echo "--- jenkins:8080 (expect FAIL) ---"; \
         wget -q -T 5 -O /dev/null http://jenkins.ci.svc.cluster.local:8080/ && echo REACHED || echo blocked'
```

Expected: `blocked`. `REACHED` means the ALB rule narrowing did not take effect — report it.

- [ ] **Step 9: Record the evidence**

Capture the output of Steps 6, 7 and 8 into `docs/eks/evidence/2026-08-17-scrape-path.txt`, with a
header naming the date and the commit. Follow the format of the existing files in that directory.

```bash
git add docs/eks/evidence/2026-08-17-scrape-path.txt
git commit -m "evidence: every observability target UP after the scrape-path apply"
git push origin master
```

- [ ] **Step 10: Delete this plan**

Per the standing rule, an executed plan is deleted in the same commit as its last task — a plan that
outlives its execution reads like pending work. The design doc is the durable record.

```bash
git rm -r docs/superpowers
git commit -m "chore: remove the executed scrape-path plan

Standing rule: a plan is deleted the moment it is executed. Git history is
the archive; docs/design/2026-08-17-observability-design.md is the record."
git push origin master
```

---

## What the next plans cover (not this one)

**Deferred from this plan, deliberately: the `observability` namespace's own default-deny
NetworkPolicy** (design §7d). It belongs with the `charts/observability` chart, which does not exist
until plan 3, and its egress list is the dangerous half — Prometheus needs the API server for service
discovery, Grafana needs Prometheus, and **Alertmanager needs the public internet** for SNS and STS.
Omit that last one and every alert still evaluates, still fires, and is never delivered. Writing it
before there is a chart to hold it, and before there are alerts to prove delivery with, would mean
shipping the most silent failure mode in this design with nothing able to detect it. It is listed in
plan 3's scope for that reason, not forgotten.

**Plan 3 — dashboards and alerts:** the `charts/observability` chart and its ArgoCD Application, the
three dashboard JSONs provisioned via the Grafana sidecar, the SLI/SLO recording rules, the eight
alert rules with `runbook_url` annotations, `defaultRules.disabled` entries for the kube-prometheus-stack
defaults each one replaces, and `docs/runbooks/`.

**Plan 4 — pipeline and drills:** the CI observability-validation stage
(`scripts/ci/validate-observability.sh`), the CD monitoring gate (`scripts/ci/monitoring-gate.sh`),
their offline tests, the four failure drills, and the evidence set.

One handoff that must not be lost: **the CD monitoring gate depends on the `ci` → `observability`
egress rule added in Task 4 of this plan.** Without it the gate cannot reach Prometheus at all, and
the symptom is a timeout rather than a permission error.
