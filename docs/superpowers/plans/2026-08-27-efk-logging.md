# EFK Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a working Elasticsearch/Fluentd/Kibana logging stack to the Voteball EKS cluster without adding a node, without a privileged container, and without breaking teardown.

**Architecture:** The ECK operator is installed by Terraform into `elastic-system` (it owns 17 cluster-scoped objects, so ArgoCD's empty `clusterResourceWhitelist` structurally cannot manage it). The namespaced `Elasticsearch`, `Kibana` and Fluentd objects live in a new `charts/logging`, synced by a third ArgoCD Application. The existing Fluent Bit DaemonSet gains a second `[OUTPUT]` and fans out to both CloudWatch and Fluentd.

**Tech Stack:** Terraform (`hashicorp/helm ~> 3.0`), ECK operator 3.5.0, Elasticsearch/Kibana 9.x (operator-matched), Fluentd (`fluent/fluentd-kubernetes-daemonset` image, run as a Deployment), Helm 3, ArgoCD, bash tests.

**Spec:** `docs/design/2026-08-27-efk-logging-design.md` — read it before starting. Every decision below argues from a numbered decision in that doc.

## Global Constraints

Copied verbatim from the spec and the repo's `CLAUDE.md`. Every task's requirements implicitly include this section.

- **ECK chart version is pinned to `3.5.0`.** Verified current on 2026-08-27 via `helm search repo elastic/eck-operator --versions`.
- **`node.store.allow_mmap: false` is mandatory** on the Elasticsearch CR (spec decision 4). It is what avoids ECK's privileged `vm.max_map_count` init container. No container in this change may set `privileged: true` or `allowPrivilegeEscalation: true`.
- **The no-third-node budget (spec decision 3):** total *requests* added across the cluster must not exceed **700m CPU / 3.5Gi memory**, and must be spread so ≥3 GiB remains free on each of the two nodes. Cluster Autoscaler reads requests; exceeding this silently adds a billed node.
- **Elasticsearch: 1 node, 1 GiB heap, `300m`/`2Gi` requests, `1`/`2Gi` limits, `20Gi` `gp3`.** No replica shard. Cluster health is **yellow by design** — never alert on it.
- **Kibana: `200m`/`1Gi` requests, `500m`/`1Gi` limits.** Fluentd: `100m`/`256Mi` requests, `500m`/`512Mi` limits.
- **The helm provider is v3.** `set` is a LIST of attribute maps (`set = [{ name = "x", value = "y" }]`), never a `set {}` block. Block syntax fails validation.
- **`charts/logging` ships `enabled: false`** and `deploy.sh` enables it after the billed apply (spec decision 8). The enable step ships in the same change as the gate — a gate that is off in git with nothing to turn it on is a rebuild that does not work.
- **No empty list literals in any chart YAML** (`to: []`, `egress: []`). `scripts/ci/validate-repo.sh` fails the build on them, because the API server normalises them away and ServerSideApply then conflicts forever. `podSelector: {}` (an empty *map*) is fine and is used throughout `charts/observability`.
- **Terraform owns namespaces.** Never `kubectl create namespace`.
- **No `Claude-Session:` trailer and no `claude.ai/code/session_...` URL in any commit message.** This is a public repo.
- **Commit and push as you go.** Never force-push.
- **TLS:** Elasticsearch keeps ECK's self-signed HTTP TLS on; Fluentd mounts the operator-generated public CA from `voteball-logs-es-http-certs-public`. Kibana sets `selfSignedCertificate.disabled: true` so the ALB (which terminates real ACM TLS) targets it over plain HTTP, matching how `frontend` is exposed.
- **Names used across tasks, verbatim:** Elasticsearch CR `voteball-logs` → Service `voteball-logs-es-http:9200`, credentials Secret `voteball-logs-es-elastic-user` (key `elastic`), CA Secret `voteball-logs-es-http-certs-public` (key `ca.crt`). Kibana CR `voteball-kibana` → Service `voteball-kibana-kb-http:5601`. Fluentd Deployment/Service `fluentd` → `fluentd:24224` (forward protocol). Namespace `logging`. Index alias `voteball-logs`, ILM policy `voteball-logs-7d`.

---

### Task 1: `charts/logging` skeleton, Elasticsearch CR, and the chart test

**Files:**
- Create: `charts/logging/Chart.yaml`
- Create: `charts/logging/values.yaml`
- Create: `charts/logging/templates/_helpers.tpl`
- Create: `charts/logging/templates/elasticsearch.yaml`
- Test: `scripts/tests/test-logging-chart.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a renderable chart at `charts/logging`; the `logging.labels` helper; values keys `enabled`, `elasticsearch.*`, consumed by Tasks 2–5. The test file `scripts/tests/test-logging-chart.sh` is extended (not replaced) by Tasks 2, 3 and 5.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test-logging-chart.sh`:

```bash
#!/usr/bin/env bash
# Offline assertions on charts/logging. Everything here renders with `helm template` -- no cluster,
# no ECK CRDs installed. The chart is gated off by default, so the "enabled" cases pass --set.
#
# The point of this file is NOT that the YAML parses. It is the three properties that, if broken,
# fail silently in production:
#   1. no privileged / allowPrivilegeEscalation container anywhere (spec decision 4)
#   2. allow_mmap is actually false (without it ES needs the privileged sysctl init container)
#   3. the requests sum stays inside the no-third-node budget (spec decision 3)
set -euo pipefail
cd "$(dirname "$0")/../.."

CHART=charts/logging
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v helm >/dev/null 2>&1 || { echo "SKIP: helm not installed"; exit 0; }

echo "==> charts/logging"

# Rendering with the chart gated OFF must produce no objects at all. This is the property that keeps
# a push-before-apply from failing an ArgoCD sync (spec decision 8).
out_off="$(helm template logging "$CHART" --namespace logging 2>&1)"
if grep -qE '^kind:' <<<"$out_off"; then
  fail "chart is gated off by default but rendered objects: $(grep -E '^kind:' <<<"$out_off" | sort -u | tr '\n' ' ')"
fi
pass "gated off by default, renders nothing"

out="$(helm template logging "$CHART" --namespace logging --set enabled=true 2>&1)" \
  || fail "helm template failed with enabled=true:\n$out"
pass "renders with enabled=true"

# --- Elasticsearch -----------------------------------------------------------------------------
grep -q 'kind: Elasticsearch' <<<"$out" || fail "no Elasticsearch resource rendered"
pass "Elasticsearch resource present"

grep -qE 'node\.store\.allow_mmap:[[:space:]]*false' <<<"$out" \
  || fail "node.store.allow_mmap: false is missing -- ES will require the PRIVILEGED sysctl init container"
pass "allow_mmap disabled (no privileged init container needed)"

# ECK adds its own sysctl init container ONLY when allow_mmap is left on. Assert nothing in the
# rendered output asks for privilege, in either spelling.
if grep -qE 'privileged:[[:space:]]*true|allowPrivilegeEscalation:[[:space:]]*true' <<<"$out"; then
  fail "a container requests privilege; every container in this repo outside BuildKit must not"
fi
pass "no privileged / allowPrivilegeEscalation container"

grep -qE 'storageClassName:[[:space:]]*gp3' <<<"$out" || fail "Elasticsearch volume must use the gp3 StorageClass"
pass "gp3 volumeClaimTemplate"

# One node, no replica. A second node would not fit the budget (spec decision 3).
node_count="$(grep -cE '^[[:space:]]+count:[[:space:]]*1' <<<"$out" || true)"
[ "$node_count" -ge 1 ] || fail "Elasticsearch nodeSet count must be 1"
pass "single Elasticsearch node"

# --- The no-third-node budget ------------------------------------------------------------------
# Sum every `requests:` cpu/memory in the rendered output and compare against the budget in the
# spec. This is arithmetic on the real rendered YAML, not a comment asserting the same thing.
budget_cpu_m=700
budget_mem_mi=3584   # 3.5Gi

sums="$(awk '
  /requests:/ { inreq=1; next }
  inreq && /^[[:space:]]*cpu:/     { gsub(/[^0-9m]/,"",$2); c=$2; if (c ~ /m$/) { sub(/m/,"",c); cpu+=c } else { cpu+=c*1000 } ; next }
  inreq && /^[[:space:]]*memory:/  { m=$2; gsub(/[^0-9A-Za-z]/,"",m);
                                     if (m ~ /Gi$/) { sub(/Gi/,"",m); mem+=m*1024 }
                                     else if (m ~ /Mi$/) { sub(/Mi/,"",m); mem+=m } ; next }
  inreq && /^[[:space:]]*[a-z]/ && !/cpu:|memory:/ { inreq=0 }
  END { printf "%d %d\n", cpu, mem }
' <<<"$out")"
cpu_m="${sums% *}"; mem_mi="${sums#* }"

[ "$cpu_m" -le "$budget_cpu_m" ] \
  || fail "rendered CPU requests ${cpu_m}m exceed the no-third-node budget of ${budget_cpu_m}m"
[ "$mem_mi" -le "$budget_mem_mi" ] \
  || fail "rendered memory requests ${mem_mi}Mi exceed the no-third-node budget of ${budget_mem_mi}Mi"
pass "requests within budget (${cpu_m}m CPU, ${mem_mi}Mi memory)"

# --- validate-repo.sh's empty-list rule ---------------------------------------------------------
# An empty list literal is normalised away by the API server, so ServerSideApply conflicts on it
# forever. validate-repo.sh fails the build on these; catch it here too, where the message is clearer.
if grep -nE ':[[:space:]]*\[\][[:space:]]*$' <<<"$out"; then
  fail "empty list literal in rendered output (see CLAUDE.md: ServerSideApply conflicts forever)"
fi
pass "no empty list literals"

echo "PASS: charts/logging"
```

Make it executable: `chmod +x scripts/tests/test-logging-chart.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/tests/test-logging-chart.sh`
Expected: FAIL — helm cannot find `charts/logging` (`Error: path "charts/logging" not found`), because the chart does not exist yet.

- [ ] **Step 3: Create the chart skeleton**

`charts/logging/Chart.yaml`:

```yaml
apiVersion: v2
name: logging
description: Elasticsearch, Fluentd and Kibana custom resources for the logging namespace. The ECK operator that reconciles them is installed by Terraform (terraform/addon-eck.tf).
type: application
version: 0.1.0
appVersion: "1.0"
```

`charts/logging/templates/_helpers.tpl`:

```
{{/*
Common object labels. NEVER routed into a selector or a pod template's labels: a Deployment's
selector is immutable after creation, so a helper whose output changes on a version bump would make
every future sync fail with a field-immutable error, fixable only by deleting the object.
*/}}
{{- define "logging.labels" -}}
app.kubernetes.io/name: logging
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
```

`charts/logging/values.yaml`:

```yaml
# EFK logging. See docs/design/2026-08-27-efk-logging-design.md.
#
# `enabled` is the master gate and ships FALSE deliberately. Every object in this chart is a custom
# resource whose CRD is installed by `terraform apply` (terraform/addon-eck.tf), and chart code
# reaches the cluster on a git push -- minutes, automatic -- while the CRD arrives only on a billed
# apply a human runs. Shipping the consumer first is the 2026-08-24 outage: ArgoCD cannot resolve the
# kind, the sync reports phase: Failed, and application-cd rolls production back.
#
# scripts/deploy.sh step 11e flips this to true AFTER the apply. Do not hand-edit it to true and
# push; run a deploy.
enabled: false

# Elasticsearch. One node, no replica -- cluster health is YELLOW BY DESIGN and nothing should alert
# on it (spec decision 3 and 9).
elasticsearch:
  version: "9.1.4"
  # 1 GiB heap inside a 2 GiB container: Elasticsearch wants roughly half the container for heap and
  # half for the filesystem cache. Sized from the MEASURED ~150 MB/day that reaches devops-app, not
  # from the vendor default -- see spec decision 3 for the arithmetic and why it removes a node.
  heapSize: "1g"
  storage:
    size: "20Gi"
    storageClassName: "gp3"
  resources:
    requests: { cpu: "300m", memory: "2Gi" }
    limits:   { cpu: "1",    memory: "2Gi" }

# Kibana. Its self-signed TLS is disabled because the ALB terminates real ACM TLS in front of it --
# the same reason services/frontend runs plain nginx on :8080.
kibana:
  version: "9.1.4"
  resources:
    requests: { cpu: "200m", memory: "1Gi" }
    limits:   { cpu: "500m", memory: "1Gi" }
  ingress:
    enabled: true
    # Rewritten per-cluster. Unlike charts/voteball's ten sync-managed fields, this one is NOT
    # written by scripts/sync-values-from-tf.sh -- update it by hand on a rebuild, the same way
    # charts/observability's datasources.postgres.host is handled.
    host: "kibana.voteball.latnook.com"
    certificateArn: ""
    # MUST match charts/voteball and ci/jenkins-webhook. A grouped ALB de-provisions only when NO
    # member Ingress remains; a different group here would leave a second ALB billing after teardown.
    group: "voteball"

# Fluentd aggregator. Fluent Bit (the DaemonSet in amazon-cloudwatch, unchanged) forwards to this.
fluentd:
  image: "fluent/fluentd-kubernetes-daemonset:v1.18.0-debian-elasticsearch8-1.0"
  resources:
    requests: { cpu: "100m", memory: "256Mi" }
    limits:   { cpu: "500m", memory: "512Mi" }

# Index lifecycle. 7 days, because CloudWatch holds the authoritative copy -- Elasticsearch is the
# SEARCH surface, not the archive (spec decision 6b).
ilm:
  enabled: true
  retentionDays: 7
  rolloverMaxSize: "1gb"

networkPolicy:
  enabled: true
```

- [ ] **Step 4: Write the Elasticsearch CR**

`charts/logging/templates/elasticsearch.yaml`:

```yaml
{{- if .Values.enabled }}
# Elasticsearch, reconciled by the ECK operator that terraform/addon-eck.tf installs.
#
# ONE NODE, NO REPLICA. Cluster health is therefore permanently YELLOW, and that is the designed
# state -- charts/observability alerts on the pod being NotReady, never on cluster colour, because an
# alert that fires forever is one people learn to ignore (spec decisions 3 and 9).
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: voteball-logs
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  version: {{ .Values.elasticsearch.version | quote }}
  nodeSets:
    - name: default
      count: 1
      config:
        node.roles: ["master", "data", "ingest"]
        # THE LOAD-BEARING LINE. Elasticsearch wants vm.max_map_count at 262144, above the EKS AMI
        # default, and ECK's DEFAULT remedy is a PRIVILEGED init container that sets the sysctl on
        # the host. Disabling mmap makes Lucene use niofs instead of mmapfs and removes the
        # requirement entirely, so every container here keeps allowPrivilegeEscalation: false.
        #
        # The cost is real but small at this size: niofs reads go through syscalls rather than
        # page-cache-backed memory maps. At ~1 GB of index it is not observable. If the index ever
        # grows to several GB, revisit THIS before revisiting the node count.
        node.store.allow_mmap: false
      podTemplate:
        spec:
          # Spread from Kibana. Both on one node would leave the other node holding the whole CI
          # build spike (~3 GiB, BuildKit alone is 2Gi) with nothing left, and Cluster Autoscaler
          # would quietly add the third node this design exists to avoid.
          affinity:
            podAntiAffinity:
              preferredDuringSchedulingIgnoredDuringExecution:
                - weight: 100
                  podAffinityTerm:
                    topologyKey: kubernetes.io/hostname
                    labelSelector:
                      matchLabels:
                        common.k8s.elastic.co/type: kibana
          containers:
            - name: elasticsearch
              env:
                - name: ES_JAVA_OPTS
                  value: "-Xms{{ .Values.elasticsearch.heapSize }} -Xmx{{ .Values.elasticsearch.heapSize }}"
              resources:
                requests:
                  cpu: {{ .Values.elasticsearch.resources.requests.cpu | quote }}
                  memory: {{ .Values.elasticsearch.resources.requests.memory | quote }}
                limits:
                  cpu: {{ .Values.elasticsearch.resources.limits.cpu | quote }}
                  memory: {{ .Values.elasticsearch.resources.limits.memory | quote }}
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: {{ .Values.elasticsearch.storage.size | quote }}
            # gp3 is WaitForFirstConsumer, so the volume is created in whichever AZ the pod first
            # lands. From then on the PV carries nodeAffinity on topology.ebs.csi.aws.com/zone and
            # the scheduler HONOURS it -- after a Spot reclaim the pod returns to that AZ. It goes
            # Pending only if that AZ has no schedulable node at that moment. EFS is NOT an option
            # here (Elastic does not support NFS data paths), which is why this differs from the
            # JENKINS_HOME decision. See spec decision 6.
            storageClassName: {{ .Values.elasticsearch.storage.storageClassName | quote }}
{{- end }}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/tests/test-logging-chart.sh`
Expected: PASS, with the budget line printing roughly `300m CPU, 2048Mi memory` (Kibana and Fluentd arrive in Tasks 2 and 3).

- [ ] **Step 6: Commit**

```bash
git add charts/logging scripts/tests/test-logging-chart.sh
git commit -m "feat(logging): Elasticsearch CR sized to fit the two existing nodes

node.store.allow_mmap:false is what avoids ECK's privileged sysctl init
container, so every container here keeps allowPrivilegeEscalation:false.
The test asserts that, and does the budget arithmetic on the rendered
YAML rather than trusting a comment."
git push origin master
```

---

### Task 2: Kibana CR and its ALB Ingress

**Files:**
- Create: `charts/logging/templates/kibana.yaml`
- Modify: `scripts/tests/test-logging-chart.sh` (append assertions before the final `echo "PASS"`)

**Interfaces:**
- Consumes: `logging.labels` and the `enabled` / `kibana.*` values from Task 1.
- Produces: Kibana Service `voteball-kibana-kb-http:5601`, referenced by the NetworkPolicy in Task 5 and by the ALB group `voteball` that `scripts/destroy.sh` waits on in Task 8.

- [ ] **Step 1: Write the failing test**

Append to `scripts/tests/test-logging-chart.sh`, immediately **before** the final `echo "PASS: charts/logging"` line:

```bash
# --- Kibana ------------------------------------------------------------------------------------
grep -q 'kind: Kibana' <<<"$out" || fail "no Kibana resource rendered"
pass "Kibana resource present"

grep -qE 'elasticsearchRef:' <<<"$out" || fail "Kibana must carry an elasticsearchRef so ECK wires its credentials"
pass "Kibana references Elasticsearch"

# The ALB group name is the teardown-critical field. A grouped ALB is de-provisioned only when NO
# member Ingress remains; a typo here leaves a second ALB billing after destroy, and its ENIs then
# block VPC deletion.
grep -qE 'alb\.ingress\.kubernetes\.io/group\.name:[[:space:]]*voteball' <<<"$out" \
  || fail "Kibana Ingress must join ALB group 'voteball' (same group as charts/voteball and ci/jenkins-webhook)"
pass "Kibana Ingress joins ALB group voteball"

# ALB terminates real ACM TLS, so Kibana itself must serve plain HTTP -- otherwise the ALB health
# check hits a self-signed HTTPS listener and the target never goes healthy.
grep -qE 'selfSignedCertificate:' <<<"$out" || fail "Kibana must disable its self-signed certificate (ALB terminates TLS)"
grep -A2 'selfSignedCertificate:' <<<"$out" | grep -qE 'disabled:[[:space:]]*true' \
  || fail "Kibana selfSignedCertificate.disabled must be true"
pass "Kibana self-signed TLS disabled (ALB terminates)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/tests/test-logging-chart.sh`
Expected: FAIL with `no Kibana resource rendered`.

- [ ] **Step 3: Write the Kibana CR and Ingress**

`charts/logging/templates/kibana.yaml`:

```yaml
{{- if .Values.enabled }}
# Kibana. ECK wires its Elasticsearch connection and service-account credentials from the
# elasticsearchRef below -- there is no password to seed and nothing new in Secrets Manager.
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: voteball-kibana
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  version: {{ .Values.kibana.version | quote }}
  count: 1
  elasticsearchRef:
    name: voteball-logs
  http:
    tls:
      selfSignedCertificate:
        # The ALB terminates real ACM TLS in front of this, exactly as it does for services/frontend.
        # Leaving ECK's self-signed cert on would make the ALB health check hit an HTTPS listener it
        # cannot validate, and the target group would never go healthy.
        disabled: true
  podTemplate:
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    common.k8s.elastic.co/type: elasticsearch
      containers:
        - name: kibana
          resources:
            requests:
              cpu: {{ .Values.kibana.resources.requests.cpu | quote }}
              memory: {{ .Values.kibana.resources.requests.memory | quote }}
            limits:
              cpu: {{ .Values.kibana.resources.limits.cpu | quote }}
              memory: {{ .Values.kibana.resources.limits.memory | quote }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
{{- if .Values.kibana.ingress.enabled }}
---
# Kibana's public route. THIS IS THE THIRD MEMBER of ALB group `voteball`, alongside
# devops-app/voteball and ci/jenkins-webhook.
#
# The group name is load-bearing for TEARDOWN, not just for cost: an ALB is de-provisioned only when
# its group has no members left, and its leftover ENIs block VPC deletion for 10-20 minutes. Getting
# this wrong creates a SECOND ALB that destroy.sh does not wait on.
#
# scripts/cleanup-stale-dns.sh must also list this host -- external-dns only reconciles on a timer
# and can be destroyed before it notices the deleted Ingress.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kibana
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: {{ .Values.kibana.ingress.group | quote }}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    {{- with .Values.kibana.ingress.certificateArn }}
    alb.ingress.kubernetes.io/certificate-arn: {{ . | quote }}
    {{- end }}
    alb.ingress.kubernetes.io/healthcheck-path: /api/status
    external-dns.alpha.kubernetes.io/hostname: {{ .Values.kibana.ingress.host | quote }}
spec:
  ingressClassName: alb
  rules:
    - host: {{ .Values.kibana.ingress.host | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: voteball-kibana-kb-http
                port:
                  number: 5601
{{- end }}
{{- end }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/tests/test-logging-chart.sh`
Expected: PASS. The budget line now reads about `500m CPU, 3072Mi memory` — still inside 700m / 3584Mi.

- [ ] **Step 5: Commit**

```bash
git add charts/logging/templates/kibana.yaml scripts/tests/test-logging-chart.sh
git commit -m "feat(logging): Kibana on the existing ALB group

Third member of group 'voteball'. The group name is asserted by the test
because a typo creates a second ALB that destroy.sh never waits on, and
its ENIs then block VPC deletion."
git push origin master
```

---

### Task 3: Fluentd aggregator

**Files:**
- Create: `charts/logging/templates/fluentd.yaml`
- Modify: `scripts/tests/test-logging-chart.sh` (append before the final `echo "PASS"`)

**Interfaces:**
- Consumes: `logging.labels`, `enabled`, `fluentd.*`, `elasticsearch.*` from Task 1; the Elasticsearch Service and Secrets named in Global Constraints.
- Produces: Service `fluentd:24224` (forward protocol), which Task 6's Fluent Bit `[OUTPUT]` targets, and the write alias `voteball-logs` that Task 4's ILM policy manages.

- [ ] **Step 1: Write the failing test**

Append to `scripts/tests/test-logging-chart.sh` before the final `echo "PASS"`:

```bash
# --- Fluentd -----------------------------------------------------------------------------------
grep -qE 'name:[[:space:]]*fluentd' <<<"$out" || fail "no fluentd objects rendered"
pass "Fluentd present"

# Port 24224 is Fluent Bit's `forward` output target. A mismatch here means Fluent Bit reports
# healthy and ships nothing -- the exact silent-failure shape addon-cloudwatch.tf warns about.
grep -qE 'containerPort:[[:space:]]*24224' <<<"$out" || fail "Fluentd must listen on 24224 (forward protocol)"
grep -qE 'port:[[:space:]]*24224' <<<"$out" || fail "Fluentd Service must expose 24224"
pass "Fluentd forward port 24224"

grep -q 'voteball-logs-es-http' <<<"$out" || fail "Fluentd must point at the Elasticsearch Service voteball-logs-es-http"
pass "Fluentd targets Elasticsearch"

# ES keeps ECK's self-signed HTTP TLS, so Fluentd must mount the operator-generated public CA.
# Without it Fluentd retries forever on certificate verification and logs never arrive.
grep -q 'voteball-logs-es-http-certs-public' <<<"$out" || fail "Fluentd must mount the Elasticsearch CA secret"
grep -q 'voteball-logs-es-elastic-user' <<<"$out" || fail "Fluentd must read the elastic user password secret"
pass "Fluentd mounts the ES CA and credentials"

grep -qE 'runAsNonRoot:[[:space:]]*true' <<<"$out" || fail "Fluentd must run as non-root"
pass "Fluentd runs non-root"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/tests/test-logging-chart.sh`
Expected: FAIL with `no fluentd objects rendered`.

- [ ] **Step 3: Write the Fluentd manifests**

`charts/logging/templates/fluentd.yaml`:

```yaml
{{- if .Values.enabled }}
# The AGGREGATOR tier. Fluent Bit (the DaemonSet in amazon-cloudwatch, unchanged) tails every node
# and forwards here; this buffers, retries and routes into the Elasticsearch write alias.
#
# This tier is what makes "EFK" literally true. Fluent Bit is a DIFFERENT PROJECT from Fluentd -- C,
# ~450 KiB, no Ruby plugin ecosystem -- and shipping it alone under the name EFK is the same silent
# substitution as calling OpenSearch Dashboards "Kibana". See spec decision, "Why".
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
data:
  fluent.conf: |
    <source>
      @type forward
      bind 0.0.0.0
      port 24224
    </source>

    # Fluent Bit's kubernetes filter has already attached pod/namespace/container metadata, so there
    # is nothing to enrich here. Everything lands in one time-based index behind a write alias the
    # ILM policy rolls over -- one index, one shard, no replica (spec decision 3).
    <match **>
      @type elasticsearch
      host voteball-logs-es-http
      port 9200
      scheme https
      # ECK generates a self-signed CA and mounts it below. verify is ON -- the CA is real, it is
      # just not publicly rooted.
      ssl_verify true
      ca_file /etc/fluentd/certs/ca.crt
      user elastic
      password "#{ENV['ELASTIC_PASSWORD']}"

      # Write through the alias, never a concrete index name: ILM rolls the backing index over and
      # repoints the alias, and a hardcoded index name would silently bypass the whole lifecycle.
      index_name voteball-logs
      # Required for ILM rollover to work through an alias.
      suppress_type_name true

      <buffer>
        @type file
        path /var/log/fluentd/buffer
        flush_interval 10s
        retry_forever true
        chunk_limit_size 8MB
        total_limit_size 512MB
      </buffer>
    </match>
---
apiVersion: v1
kind: Service
metadata:
  name: fluentd
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  selector:
    app: fluentd
  ports:
    - name: forward
      protocol: TCP
      port: 24224
      targetPort: 24224
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fluentd
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: fluentd
          image: {{ .Values.fluentd.image | quote }}
          ports:
            - name: forward
              containerPort: 24224
          env:
            - name: ELASTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  # Generated by ECK when the Elasticsearch resource is created. Nothing seeds it and
                  # it never enters git or Secrets Manager.
                  name: voteball-logs-es-elastic-user
                  key: elastic
            - name: FLUENT_UID
              value: "1000"
          resources:
            requests:
              cpu: {{ .Values.fluentd.resources.requests.cpu | quote }}
              memory: {{ .Values.fluentd.resources.requests.memory | quote }}
            limits:
              cpu: {{ .Values.fluentd.resources.limits.cpu | quote }}
              memory: {{ .Values.fluentd.resources.limits.memory | quote }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            # NOT readOnlyRootFilesystem: the file buffer below needs a writable path, and the
            # fluentd image also writes its plugin cache under /home/fluent. The two emptyDirs cover
            # what is genuinely written, which is the same pattern charts/voteball uses.
          volumeMounts:
            - name: certs
              mountPath: /etc/fluentd/certs
              readOnly: true
            - name: config
              mountPath: /fluentd/etc/fluent.conf
              subPath: fluent.conf
              readOnly: true
            - name: buffer
              mountPath: /var/log/fluentd
          livenessProbe:
            tcpSocket:
              port: 24224
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            tcpSocket:
              port: 24224
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: certs
          secret:
            # Created by ECK alongside the Elasticsearch resource.
            secretName: voteball-logs-es-http-certs-public
        - name: config
          configMap:
            name: fluentd
        - name: buffer
          emptyDir: {}
{{- end }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/tests/test-logging-chart.sh`
Expected: PASS. Budget line now about `600m CPU, 3328Mi memory` — the final figure, inside 700m / 3584Mi.

- [ ] **Step 5: Commit**

```bash
git add charts/logging/templates/fluentd.yaml scripts/tests/test-logging-chart.sh
git commit -m "feat(logging): Fluentd aggregator between Fluent Bit and Elasticsearch

This tier is what makes the F in EFK literally true -- Fluent Bit is a
different project, and shipping it alone under the name is the same silent
substitution as calling OpenSearch Dashboards 'Kibana'.

Writes through the ILM alias rather than a concrete index name; a hardcoded
index would bypass the lifecycle policy without erroring."
git push origin master
```

---

### Task 4: ILM policy, index template and write alias

**Files:**
- Create: `charts/logging/templates/ilm.yaml`
- Modify: `scripts/tests/test-logging-chart.sh` (append before the final `echo "PASS"`)

**Interfaces:**
- Consumes: `enabled`, `ilm.*`, `elasticsearch.version` from Task 1; the `voteball-logs-es-*` Secrets and Service.
- Produces: ILM policy `voteball-logs-7d`, index template `voteball-logs`, and the bootstrapped write alias `voteball-logs` that Task 3's Fluentd writes into.

**Why a Job:** ECK's `StackConfigPolicy` CRD would express this declaratively but requires an **Enterprise** licence. ILM itself is free under the **Basic** licence ECK installs by default, so a one-shot Job that calls the Elasticsearch REST API is the licence-free way to apply it.

- [ ] **Step 1: Write the failing test**

Append to `scripts/tests/test-logging-chart.sh` before the final `echo "PASS"`:

```bash
# --- ILM ---------------------------------------------------------------------------------------
# Without a retention policy the 20Gi volume fills in ~130 days, Elasticsearch flips the index
# read-only at its flood-stage watermark, and ingestion stops SILENTLY from the writer's side.
grep -q 'voteball-logs-7d' <<<"$out" || fail "no ILM policy rendered -- the volume would fill and ingestion would stop silently"
pass "ILM policy present"

grep -qE 'kind:[[:space:]]*Job' <<<"$out" || fail "ILM must be applied by a Job (StackConfigPolicy needs an Enterprise licence)"
pass "ILM applied by a Job"

grep -qE '"max_age":[[:space:]]*"7d"|max_age.*7d' <<<"$out" || fail "ILM delete phase must be 7 days"
pass "7-day retention"

# helm hook weights: the Job must run AFTER the Elasticsearch resource exists, or it curls nothing.
grep -qE 'helm\.sh/hook:' <<<"$out" || fail "ILM Job must be a post-install/post-upgrade hook"
pass "ILM Job is a hook"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/tests/test-logging-chart.sh`
Expected: FAIL with `no ILM policy rendered`.

- [ ] **Step 3: Write the ILM Job**

`charts/logging/templates/ilm.yaml`:

```yaml
{{- if and .Values.enabled .Values.ilm.enabled }}
# Index lifecycle: roll over daily or at 1 GB, delete at 7 days.
#
# NOT OPTIONAL. Without it the 20Gi volume fills in roughly 130 days at the measured ingest rate,
# Elasticsearch then flips the index read-only at its flood-stage watermark, and ingestion stops --
# silently, from Fluentd's point of view, which retries forever. Seven days is the retention because
# CloudWatch holds the authoritative copy; Elasticsearch is the SEARCH surface, not the archive
# (spec decision 6b).
#
# Applied by a Job rather than ECK's StackConfigPolicy CRD, which requires an ENTERPRISE licence.
# ILM itself is free under the Basic licence ECK installs by default.
apiVersion: batch/v1
kind: Job
metadata:
  name: logging-ilm-bootstrap
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
  annotations:
    # post-install AND post-upgrade: the Elasticsearch resource must already exist, and re-running on
    # upgrade is how a changed retention actually reaches the cluster. Every call below is a PUT and
    # is idempotent.
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 10
  template:
    metadata:
      labels:
        app: logging-ilm-bootstrap
    spec:
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: bootstrap
          image: curlimages/curl:8.11.1
          env:
            - name: ELASTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: voteball-logs-es-elastic-user
                  key: elastic
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: certs
              mountPath: /etc/certs
              readOnly: true
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              ES="https://voteball-logs-es-http:9200"
              AUTH="elastic:${ELASTIC_PASSWORD}"
              CA="/etc/certs/ca.crt"

              # Wait for Elasticsearch to answer. The hook ordering guarantees the RESOURCE exists,
              # not that the pod is serving; a fresh cluster takes ~60s to come up.
              until curl -sf --cacert "$CA" -u "$AUTH" "$ES/_cluster/health" >/dev/null; do
                echo "waiting for Elasticsearch..."
                sleep 5
              done

              # -f makes curl exit non-zero on a 4xx/5xx, so a rejected policy FAILS the Job rather
              # than printing an error body and reporting success. This is the swallowed-exit-status
              # shape CLAUDE.md warns about; -f is what closes it.
              echo "applying ILM policy voteball-logs-7d"
              curl -sf --cacert "$CA" -u "$AUTH" -X PUT "$ES/_ilm/policy/voteball-logs-7d" \
                -H 'Content-Type: application/json' -d '{
                  "policy": {
                    "phases": {
                      "hot": {
                        "actions": {
                          "rollover": {
                            "max_age": "1d",
                            "max_primary_shard_size": {{ .Values.ilm.rolloverMaxSize | quote }}
                          }
                        }
                      },
                      "delete": {
                        "min_age": "{{ .Values.ilm.retentionDays }}d",
                        "actions": { "delete": {} }
                      }
                    }
                  }
                }'

              echo "applying index template voteball-logs"
              curl -sf --cacert "$CA" -u "$AUTH" -X PUT "$ES/_index_template/voteball-logs" \
                -H 'Content-Type: application/json' -d '{
                  "index_patterns": ["voteball-logs-*"],
                  "template": {
                    "settings": {
                      "number_of_shards": 1,
                      "number_of_replicas": 0,
                      "index.lifecycle.name": "voteball-logs-7d",
                      "index.lifecycle.rollover_alias": "voteball-logs"
                    }
                  }
                }'

              # Bootstrap the first backing index and point the write alias at it. Without this,
              # Fluentd's first write auto-creates a plain index that ILM never manages.
              # 400 == already exists, which is the normal case on upgrade -- so this one call is
              # deliberately NOT -f, and its status is inspected instead.
              echo "bootstrapping write alias"
              code="$(curl -s -o /tmp/out -w '%{http_code}' --cacert "$CA" -u "$AUTH" \
                -X PUT "$ES/%3Cvoteball-logs-000001%3E" \
                -H 'Content-Type: application/json' -d '{
                  "aliases": { "voteball-logs": { "is_write_index": true } }
                }')"
              case "$code" in
                200|201) echo "alias bootstrapped" ;;
                400)     grep -q 'resource_already_exists' /tmp/out && echo "alias already exists" || { cat /tmp/out; exit 1; } ;;
                *)       cat /tmp/out; exit 1 ;;
              esac

              echo "ILM bootstrap complete"
      volumes:
        - name: certs
          secret:
            secretName: voteball-logs-es-http-certs-public
{{- end }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/tests/test-logging-chart.sh`
Expected: PASS. Note the budget figure rises by the Job's 50m/64Mi only while the hook runs; it is a one-shot Job, not a standing workload.

- [ ] **Step 5: Commit**

```bash
git add charts/logging/templates/ilm.yaml scripts/tests/test-logging-chart.sh
git commit -m "feat(logging): 7-day ILM policy, index template and write alias

Without retention the 20Gi volume fills in ~130 days and Elasticsearch flips
the index read-only at its flood-stage watermark -- ingestion stops silently
because Fluentd just retries forever.

Applied by a Job because StackConfigPolicy needs an Enterprise licence; ILM
itself is free under Basic. curl -f throughout so a rejected policy fails the
Job instead of printing an error body and reporting success."
git push origin master
```

---

### Task 5: NetworkPolicies for the `logging` namespace

**Files:**
- Create: `charts/logging/templates/networkpolicy.yaml`
- Modify: `scripts/tests/test-logging-chart.sh` (append before the final `echo "PASS"`)

**Interfaces:**
- Consumes: `logging.labels`, `enabled`, `networkPolicy.enabled` from Task 1.
- Produces: nothing later tasks reference, but Task 6's Fluent Bit output depends on the ingress rule here admitting the `amazon-cloudwatch` namespace.

- [ ] **Step 1: Write the failing test**

Append to `scripts/tests/test-logging-chart.sh` before the final `echo "PASS"`:

```bash
# --- NetworkPolicy ------------------------------------------------------------------------------
grep -q 'kind: NetworkPolicy' <<<"$out" || fail "logging namespace must be default-deny like every other namespace here"
pass "NetworkPolicies present"

grep -q 'name: default-deny' <<<"$out" || fail "missing the default-deny policy"
pass "default-deny"

# Fluent Bit lives in amazon-cloudwatch. Without this ingress rule it connects, times out, buffers
# and reports healthy -- shipping nothing.
grep -q 'amazon-cloudwatch' <<<"$out" || fail "must admit Fluent Bit from the amazon-cloudwatch namespace"
pass "admits Fluent Bit"

# DNS. Without it every outbound lookup fails and the symptom reads as 'no network at all'.
grep -q 'allow-dns-egress' <<<"$out" || fail "missing DNS egress"
pass "DNS egress"

# The ALB reaches Kibana from the PUBLIC subnets.
grep -qE '10\.0\.0\.0/20|10\.0\.16\.0/20' <<<"$out" || fail "must admit the ALB from the public subnet CIDRs"
pass "admits the ALB"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/tests/test-logging-chart.sh`
Expected: FAIL with `logging namespace must be default-deny...`.

- [ ] **Step 3: Write the policies**

`charts/logging/templates/networkpolicy.yaml`:

```yaml
{{- if and .Values.enabled .Values.networkPolicy.enabled }}
# `logging` is default-deny like every other namespace in this cluster. Exactly four flows are
# opened and nothing else -- this namespace needs no route to RDS and no route to the AWS APIs.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
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
    {{- include "logging.labels" . | nindent 4 }}
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
# Ingest, from Fluent Bit in amazon-cloudwatch.
#
# THIS RULE IS THE ONE THAT FAILS SILENTLY. Fluent Bit's forward output buffers and retries on a
# refused connection while the DaemonSet stays Running and healthy, so a missing rule here looks
# exactly like "no logs have been written yet". It is why Task 8's verification counts DOCUMENTS
# rather than checking pod status.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-fluentbit-ingest
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      app: fluentd
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: amazon-cloudwatch
      ports:
        - { protocol: TCP, port: 24224 }
---
# Within the namespace: Fluentd -> Elasticsearch, Kibana <-> Elasticsearch, and the ILM Job ->
# Elasticsearch. Plus the ALB reaching Kibana from the public subnets.
#
# The ALB is NOT a pod -- its ENIs sit in the public subnets, outside any namespaceSelector or
# podSelector a NetworkPolicy can name -- so it needs plain ipBlocks, the same way
# charts/observability's admission-webhook rule names the VPC CIDR.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-logging-ingress
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
    - from:
        - ipBlock: { cidr: 10.0.0.0/20 }
        - ipBlock: { cidr: 10.0.16.0/20 }
      ports:
        - { protocol: TCP, port: 5601 }
---
# Egress: same-namespace only.
#
# The AWS VPC CNI evaluates egress policy PRE-DNAT -- against the ClusterIP the client dialled, not
# the pod IP the Service routes to -- so the Service CIDR needs its own explicit entry per port, not
# just the same-namespace podSelector. This is the exact trap that left Grafana's datasource health
# check timing out on 2026-08-18; see charts/observability/templates/networkpolicy.yaml.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-logging-egress
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "logging.labels" . | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector: {}
    - to:
        - ipBlock: { cidr: 172.20.0.0/16 }
      ports:
        - { protocol: TCP, port: 9200 }  # Elasticsearch ClusterIP (Fluentd, Kibana, the ILM Job)
        - { protocol: TCP, port: 5601 }  # Kibana ClusterIP
        - { protocol: TCP, port: 443 }   # Kubernetes API (ECK-managed pods do service discovery)
{{- end }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/tests/test-logging-chart.sh`
Expected: PASS, all sections.

- [ ] **Step 5: Verify the chart passes the repo's own validation**

Run: `helm lint charts/logging --set enabled=true`
Expected: `1 chart(s) linted, 0 chart(s) failed`

Run: `scripts/ci/validate-repo.sh`
Expected: PASS — in particular no empty-list-literal failure.

- [ ] **Step 6: Commit**

```bash
git add charts/logging/templates/networkpolicy.yaml scripts/tests/test-logging-chart.sh
git commit -m "feat(logging): default-deny NetworkPolicies for the logging namespace

The Fluent Bit ingest rule is the one that fails silently: forward output
buffers and retries on a refused connection while the DaemonSet stays Running,
so a missing rule looks exactly like 'no logs yet'.

Service-CIDR egress is enumerated per port because the VPC CNI evaluates
egress PRE-DNAT -- the same trap that broke Grafana's datasources on
2026-08-18."
git push origin master
```

---

### Task 6: Terraform — ECK operator, `logging` namespace, Fluent Bit fan-out

**Files:**
- Create: `terraform/addon-eck.tf`
- Modify: `terraform/namespaces.tf` (append a second `kubernetes_namespace` resource)
- Modify: `terraform/addon-cloudwatch.tf` (add a second `[OUTPUT]` to `fluent_bit_application_log_conf`, after the `cloudwatch_logs` block that currently ends at the `EOT`)

**Interfaces:**
- Consumes: `module.eks` (for `depends_on`), `var.cluster_name`.
- Produces: the 12 `*.k8s.elastic.co` CRDs every object in Tasks 1–5 depends on; the `logging` namespace; a Fluent Bit `forward` output aimed at `fluentd.logging.svc.cluster.local:24224`.

- [ ] **Step 1: Write the ECK add-on**

`terraform/addon-eck.tf`:

```hcl
# Elastic Cloud on Kubernetes (ECK) -- the operator that reconciles the Elasticsearch and Kibana
# custom resources in charts/logging. See docs/design/2026-08-27-efk-logging-design.md.
#
# THIS IS A PLATFORM ADD-ON, NOT THE APPLICATION -- the same class as ArgoCD, ESO, external-dns and
# kube-prometheus-stack. It reaches the cluster by `terraform apply`, never by a git push. Committing
# a version bump here and walking away does nothing.
#
# WHY TERRAFORM RATHER THAN ArgoCD: the chart installs 17 CLUSTER-SCOPED objects -- 12 CRDs, 3
# ClusterRoles, 1 ClusterRoleBinding, 1 ValidatingWebhookConfiguration. Both AppProjects in
# argocd/voteball-application.yaml.tmpl set `clusterResourceWhitelist: []`, a deliberate blast-radius
# limit, so ArgoCD is structurally unable to manage this. The namespaced Elasticsearch/Kibana/Fluentd
# objects ARE eligible and live in charts/logging.
#
# WHY NOT BY HAND: a hand-run `helm install` is invisible to Terraform, so it silently disappears on
# every rebuild of this cluster -- and scripts/destroy.sh pre-uninstalls a KNOWN list of releases
# while the cluster is still healthy. An unknown release owning a ValidatingWebhookConfiguration is
# exactly the shape that hangs teardown: the webhook intercepts deletes of *.k8s.elastic.co objects,
# and with the operator already gone there is no backend to answer.
resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = "3.5.0" # verified latest via `helm search repo elastic/eck-operator --versions` (2026-08-27)
  namespace        = "elastic-system"
  create_namespace = true

  # The operator's own StatefulSet already requests only 100m/150Mi and already runs
  # runAsNonRoot / allowPrivilegeEscalation:false / readOnlyRootFilesystem:true out of the box, so
  # there is nothing to override for this repo's container-security bar.
  #
  # helm provider v3: `set` is a LIST of attribute maps, never a `set {}` block (see versions.tf).
  set = [
    {
      # Watch only the namespace charts/logging deploys into. The default is every namespace, which
      # would have the operator reconciling CRs anywhere in the cluster.
      name  = "managedNamespaces[0]"
      value = "logging"
    },
  ]

  depends_on = [module.eks]
}
```

- [ ] **Step 2: Add the `logging` namespace**

Append to `terraform/namespaces.tf`:

```hcl
# The logging namespace. Terraform creates it for the same reason it creates devops-app: the objects
# that RUN in it arrive via ArgoCD from charts/logging, but the namespace has to exist before the
# ECK operator's managedNamespaces setting can name it, and before ArgoCD's CreateNamespace=false
# Application tries to sync into it.
#
# `kubectl create namespace logging` is deliberately NOT used anywhere. A namespace created outside
# Terraform is not deleted on destroy -- it lingers or sits Terminating, and the next apply collides
# with it.
resource "kubernetes_namespace" "logging" {
  # Same EKS access-entry propagation race as kubernetes_namespace.devops_app above.
  depends_on = [module.eks]

  metadata {
    name = "logging"

    labels = {
      # NetworkPolicy namespaceSelectors match on this, and a selector silently matching nothing is
      # far harder to spot than a missing namespace. charts/logging's allow-fluentbit-ingest rule
      # depends on amazon-cloudwatch carrying the equivalent label.
      "kubernetes.io/metadata.name" = "logging"
    }
  }
}
```

- [ ] **Step 3: Add the Fluent Bit fan-out**

In `terraform/addon-cloudwatch.tf`, inside the `fluent_bit_application_log_conf` heredoc, append a **third** change after the existing `[OUTPUT] cloudwatch_logs` block (which ends with `add_entity true`, just before `EOT`):

```
    # CHANGE 3 (2026-08-27): a SECOND output, fanning the same records out to the Fluentd aggregator
    #   in the logging namespace as well as to CloudWatch. CloudWatch keeps receiving everything --
    #   the Grafana CloudWatch datasource built on 2026-08-24 is unaffected and CloudWatch remains
    #   the authoritative copy, with Elasticsearch holding a 7-day search surface on top of it.
    #
    #   THIS BLOCK FAILS SILENTLY IF IT IS WRONG. Per the warning at the top of this local: the
    #   string REPLACES the add-on's default application-log.conf rather than merging into it, and
    #   Fluent Bit's forward output buffers and retries on a refused connection while the DaemonSet
    #   stays Running and healthy. Neither a pod check nor a Fluent Bit log line will tell you this
    #   is broken. scripts/logging/verify-efk.sh counts documents in Elasticsearch instead.
    [OUTPUT]
      Name                forward
      Match               application.*
      Host                fluentd.logging.svc.cluster.local
      Port                24224
      # Do NOT let a full buffer here block the CloudWatch output. Retry_Limit False would retry
      # forever and back-pressure the shared input; a bounded retry drops records to Elasticsearch
      # while CloudWatch -- the authoritative copy -- keeps receiving them.
      Retry_Limit         3
```

- [ ] **Step 4: Validate the Terraform**

Run:
```bash
cd terraform && terraform fmt -recursive && terraform validate
```
Expected: `Success! The configuration is valid.`

If `terraform validate` complains the backend is not initialised, run `terraform init -backend-config=backend.hcl` first.

- [ ] **Step 5: Commit**

```bash
git add terraform/addon-eck.tf terraform/namespaces.tf terraform/addon-cloudwatch.tf
git commit -m "feat(terraform): ECK operator, logging namespace, Fluent Bit fan-out

ECK is a platform add-on, so it reaches the cluster by terraform apply. It
cannot go through ArgoCD regardless: the chart installs 17 cluster-scoped
objects and both AppProjects set clusterResourceWhitelist: [].

Fluent Bit now fans out to CloudWatch AND Fluentd. CloudWatch keeps the
authoritative copy and the Grafana datasource is unaffected. The forward
output is Retry_Limit 3 so a full buffer to Elasticsearch cannot
back-pressure the CloudWatch path."
git push origin master
```

---

### Task 7: The third ArgoCD Application

**Files:**
- Modify: `argocd/voteball-application.yaml.tmpl` (append a third `AppProject` + `Application` pair)

**Interfaces:**
- Consumes: `charts/logging` from Tasks 1–5; the `logging` namespace from Task 6.
- Produces: an ArgoCD `Application` named `logging`, which `scripts/destroy.sh` step 1 must delete (Task 8).

- [ ] **Step 1: Append the pair**

Append to `argocd/voteball-application.yaml.tmpl`:

```yaml
---
# The logging project. Separate from voteball and observability for the same reason those two are
# separate from each other: an AppProject's whole purpose is to pin one chart to one namespace, and
# reusing an existing project would mean widening its destination to two namespaces -- which would
# let a mistake in either chart deploy into the other's namespace.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: logging
  namespace: argocd
spec:
  description: EFK custom resources. Deploys charts/logging into logging, nothing else.
  sourceRepos:
    - ${REPO_URL}
  destinations:
    - server: https://kubernetes.default.svc
      namespace: logging
  # Empty = DENY every cluster-scoped resource, same as the other two projects. This chart renders
  # only Elasticsearch/Kibana CRs, a Deployment, a Service, a ConfigMap, a Job, an Ingress and
  # NetworkPolicies -- all namespaced. The 12 ECK CRDs are cluster-scoped and are installed by
  # terraform/addon-eck.tf precisely because this list is empty. Verify with:
  #     helm template logging charts/logging -n logging --set enabled=true | grep '^kind:' | sort -u
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
---
# CreateNamespace=false: terraform/namespaces.tf creates `logging`, so it already exists by the time
# this Application is created at deploy step 11. ServerSideApply for the same reason the other two
# Applications use it.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logging
  namespace: argocd
spec:
  project: logging
  source:
    repoURL: ${REPO_URL}
    targetRevision: release
    path: charts/logging
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false
```

- [ ] **Step 2: Verify the template still renders and the AppProject precedes its Application**

Run:
```bash
REPO_URL=https://github.com/Latnook/voteball.git \
  envsubst < argocd/voteball-application.yaml.tmpl | grep -nE '^kind:|^  name:'
```
Expected: six pairs in order — AppProject `voteball`, Application `voteball`, AppProject `observability`, Application `observability`, AppProject `logging`, Application `logging`. **The AppProject must come first in each pair**; `kubectl` applies a multi-document stream in order and an Application referencing a project that does not exist yet is rejected.

- [ ] **Step 3: Commit**

```bash
git add argocd/voteball-application.yaml.tmpl
git commit -m "feat(argocd): third Application for charts/logging

Its own AppProject rather than widening an existing one: an AppProject pins
one chart to one namespace, and a shared project would let a mistake in
either chart deploy into the other's namespace.

clusterResourceWhitelist stays empty, which is exactly why the 12 ECK CRDs
are installed by Terraform instead."
git push origin master
```

---

### Task 8: Teardown ordering, DNS cleanup, and end-to-end verification

**Files:**
- Create: `scripts/logging/verify-efk.sh`
- Modify: `scripts/destroy.sh` (step 1 ArgoCD Application list; step 4 Helm uninstall block)
- Modify: `scripts/cleanup-stale-dns.sh:32` (the `HOSTS` line)
- Modify: `scripts/deploy.sh` (new step 11e after 11d)
- Modify: `scripts/tests/test-logging-chart.sh` (append the teardown-order assertion)
- Modify: `scripts/tests/run-ci-suite.sh` (register the new test in a group)

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: nothing later tasks reference. This is the last behavioural task.

- [ ] **Step 1: Write the failing teardown-order test**

Append to `scripts/tests/test-logging-chart.sh` before the final `echo "PASS"`:

```bash
# --- Teardown ordering ---------------------------------------------------------------------------
# The ValidatingWebhookConfiguration the ECK chart installs intercepts writes to *.k8s.elastic.co
# objects. If the operator is uninstalled BEFORE the Elasticsearch/Kibana CRs are deleted, every CR
# delete blocks on a webhook with no backend -- the same class as the kubernetes_namespace.ci
# finalizer hang of 2026-08-04. This asserts the order in the script text, since the failure only
# reproduces during a real billed teardown.
echo "==> destroy.sh ordering"
d=scripts/destroy.sh
grep -q 'kubectl delete elasticsearch' "$d" || fail "destroy.sh must delete the Elasticsearch CR"
grep -q 'kubectl delete kibana' "$d"        || fail "destroy.sh must delete the Kibana CR"
grep -q 'helm uninstall elastic-operator' "$d" || fail "destroy.sh must uninstall the ECK operator"

cr_line="$(grep -n 'kubectl delete elasticsearch' "$d" | head -1 | cut -d: -f1)"
op_line="$(grep -n 'helm uninstall elastic-operator' "$d" | head -1 | cut -d: -f1)"
[ "$cr_line" -lt "$op_line" ] \
  || fail "destroy.sh uninstalls the ECK operator (line $op_line) BEFORE deleting its CRs (line $cr_line) -- the webhook will hang the teardown"
pass "CRs deleted before the operator"

grep -q "kibana\." scripts/cleanup-stale-dns.sh \
  || fail "cleanup-stale-dns.sh must list the kibana host, or its record strands on a dead ALB"
pass "cleanup-stale-dns.sh covers the kibana host"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/tests/test-logging-chart.sh`
Expected: FAIL with `destroy.sh must delete the Elasticsearch CR`.

- [ ] **Step 3: Update `scripts/destroy.sh`**

In **step 1**, add `logging` to the ArgoCD Application deletion (find the existing `kubectl delete application` calls and add the same for `logging`, so `selfHeal` cannot recreate what the next step removes).

In **step 4**, add this block **before** the four existing `helm uninstall` lines, inside the existing `if kubectl cluster-info` branch:

```bash
  # ECK comes out in a SPECIFIC ORDER: custom resources first, operator second.
  #
  # The chart's ValidatingWebhookConfiguration intercepts writes to *.k8s.elastic.co objects. With
  # the operator already uninstalled there is no backend to answer, so every Elasticsearch/Kibana
  # delete blocks -- the same class of hang as kubernetes_namespace.ci sitting Terminating forever
  # on 2026-08-04 with no controller left to clear its children's finalizers.
  #
  # ECK's volumeClaimDeletePolicy deletes the Elasticsearch PVC when the CR goes, so unlike the
  # observability PVCs in step 5 there is no orphaned-EBS cleanup to do here.
  kubectl delete elasticsearch --all -n logging --ignore-not-found --timeout=120s || true
  kubectl delete kibana        --all -n logging --ignore-not-found --timeout=120s || true
  helm uninstall logging          -n logging        --ignore-not-found || true
  helm uninstall elastic-operator -n elastic-system --ignore-not-found || true
```

Also update the step-4 comment block: it currently opens "All FOUR of this stack's OWN helm_release resources". It is now **six** (`voteball`, `jenkins`, `jenkins-support`, `kube-prometheus-stack`, `logging`, `elastic-operator`) — correct the count and add `logging`/`elastic-operator` to the list it names.

- [ ] **Step 4: Update `scripts/cleanup-stale-dns.sh`**

Change line 32 from:

```bash
HOSTS="${APP_DOMAIN}. jenkins.${APP_DOMAIN}."
```

to:

```bash
HOSTS="${APP_DOMAIN}. jenkins.${APP_DOMAIN}. kibana.${APP_DOMAIN}."
```

And extend the comment above it (currently "BOTH hostnames external-dns manages for this cluster") to say **three**, noting `kibana.<app_domain>` was added 2026-08-27 with the EFK stack.

- [ ] **Step 5: Write the end-to-end verification script**

Create `scripts/logging/verify-efk.sh`:

```bash
#!/usr/bin/env bash
# Prove the EFK pipeline actually carries a log line end to end.
#
# WHY THIS IS NOT A POD CHECK. Three of this repo's most expensive defects share one shape: a check
# that passes against a component which is healthy and doing nothing. Fluent Bit's forward output
# buffers and retries on a refused connection while the DaemonSet stays Running; a missing
# NetworkPolicy rule, a typo'd Service name, or a dropped [OUTPUT] block all look identical to "no
# logs have been written yet". So this writes a KNOWN line and counts it back.
#
# It also exercises the query against input it KNOWS should match, once, before trusting a zero --
# an empty result from a pattern that can never match is indistinguishable from a correct negative,
# which is the one failure mode no amount of re-reading the code reveals.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/config.sh

NS=logging
ES_SVC=voteball-logs-es-http
ALIAS=voteball-logs
TIMEOUT_SECS="${EFK_VERIFY_TIMEOUT:-180}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> Verifying the EFK pipeline end to end"

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace $NS does not exist -- has terraform apply run?"

echo "--> waiting for Elasticsearch and Kibana to be Ready"
kubectl wait --for=condition=Ready pod -l common.k8s.elastic.co/type=elasticsearch \
  -n "$NS" --timeout=300s || fail "Elasticsearch pod never became Ready"
kubectl wait --for=condition=Ready pod -l common.k8s.elastic.co/type=kibana \
  -n "$NS" --timeout=300s || fail "Kibana pod never became Ready"
kubectl wait --for=condition=Available deployment/fluentd -n "$NS" --timeout=300s \
  || fail "Fluentd never became Available"

# The elastic password and CA come from Secrets ECK generated; neither is in git or Secrets Manager.
PASS="$(kubectl get secret voteball-logs-es-elastic-user -n "$NS" -o go-template='{{.data.elastic | base64decode}}')"
[ -n "$PASS" ] || fail "could not read the elastic user password"

# A marker unique to this run. Passed in rather than generated with $RANDOM so a re-run after a
# failure can search for the previous one.
MARKER="${EFK_VERIFY_MARKER:-efk-verify-$(date -u +%Y%m%d%H%M%S)}"

echo "--> writing marker '$MARKER' to a devops-app pod's stdout"
POD="$(kubectl get pods -n devops-app -l app=backend -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || fail "no backend pod found in devops-app to write a log line from"

# WRITE TO /proc/1/fd/1, NOT to the exec session's own stdout.
#
# `kubectl exec ... -- echo MARKER` prints to the EXEC stream and never touches the container's log.
# The kubelet only writes PID 1's stdout/stderr to /var/log/containers/*.log, which is the only thing
# Fluent Bit tails -- so the obvious form of this check writes a marker that provably cannot be
# found, then reports the pipeline broken. That is a false negative built into the test itself.
#
# /proc/1/fd/1 is PID 1's stdout. The backend container runs as uid 1000 and so does PID 1, so the
# write is permitted; readOnlyRootFilesystem does not apply to /proc.
kubectl exec -n devops-app "$POD" -- sh -c "echo '$MARKER' > /proc/1/fd/1" \
  || fail "could not write a log line to PID 1's stdout in $POD"

# --- The self-check ------------------------------------------------------------------------------
# Run the query ONCE against a term that MUST be present (match_all over the alias) before trusting
# any zero from the real query. If this returns 0, the query itself is broken and every subsequent
# "not found" would be a false negative rather than a real one.
# $1 = path, $2 = optional JSON body.
#
# The two forms are separate branches rather than one call with `${2:+...}`: an unquoted expansion
# word-splits on spaces, so `-H 'Content-Type: application/json'` would arrive as three arguments
# with literal quote characters, and curl would reject the header rather than send it.
es() {
  local path="$1" body="${2:-}"
  if [ -n "$body" ]; then
    kubectl exec -n "$NS" statefulset/voteball-logs-es-default -c elasticsearch -- \
      curl -sf -u "elastic:$PASS" --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
      -H 'Content-Type: application/json' -d "$body" "https://localhost:9200/$path"
  else
    kubectl exec -n "$NS" statefulset/voteball-logs-es-default -c elasticsearch -- \
      curl -sf -u "elastic:$PASS" --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
      "https://localhost:9200/$path"
  fi
}

echo "--> self-check: the query path can return a non-zero count"
if ! es "_alias/$ALIAS" >/dev/null 2>&1; then
  fail "the write alias '$ALIAS' does not exist -- the ILM bootstrap Job did not complete"
fi

# --- The real check -------------------------------------------------------------------------------
echo "--> waiting up to ${TIMEOUT_SECS}s for the marker to reach Elasticsearch"
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
count=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  # query_string across ALL fields, not match_phrase on a guessed field name. Fluent Bit's
  # kubernetes filter puts the line in `log` or, with Merge_Log On, in `log_processed` -- and which
  # one depends on whether the line parsed as JSON. Naming the wrong field returns 0 with status
  # 200, which is indistinguishable from a correct negative.
  count="$(es "$ALIAS/_count" "{\"query\":{\"query_string\":{\"query\":\"\\\"$MARKER\\\"\"}}}" \
            | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
  count="${count:-0}"
  [ "$count" -gt 0 ] && break
  sleep 5
done

[ "$count" -gt 0 ] || fail "marker '$MARKER' never reached Elasticsearch after ${TIMEOUT_SECS}s.
  Check, in order:
    1. kubectl logs -n $NS deploy/fluentd            (is it accepting forward connections?)
    2. kubectl logs -n amazon-cloudwatch -l k8s-app=fluent-bit --tail=50
       (Fluent Bit BUFFERS AND RETRIES SILENTLY on a refused connection -- it will look healthy)
    3. kubectl get networkpolicy -n $NS              (is allow-fluentbit-ingest present?)
    4. the [OUTPUT] forward block in terraform/addon-cloudwatch.tf reached the cluster
       (it needs a terraform apply -- a git push does NOT deploy it)"

echo "PASS: marker found in Elasticsearch ($count document(s))"
echo
echo "  Kibana: https://kibana.${APP_DOMAIN}"
echo "  Index pattern: ${ALIAS}-*"
```

Make it executable: `chmod +x scripts/logging/verify-efk.sh`

- [ ] **Step 6: Add deploy step 11e**

In `scripts/deploy.sh`, immediately after the 11d block (which ends with the `restart-grafana-datasources.sh` warning `fi`) and **before** the final `cat <<EOF` summary, insert:

```bash
step "11e/11 Enabling and verifying the EFK logging stack"
# charts/logging ships enabled: false on purpose -- its objects are custom resources whose CRDs only
# `terraform apply` installs (step 6), and chart code otherwise reaches the cluster on a git push
# minutes later. Shipping the consumer first is the 2026-08-24 outage. This step is the OTHER HALF of
# that gate: a gate that is off in git with nothing to turn it on is a rebuild that does not work.
#
# NOT FATAL, for the same reason as 11b/11c/11d: the application is already up and serving. This
# affects log search only.
if ! ./scripts/logging/verify-efk.sh; then
  echo
  echo "WARNING: the EFK pipeline did not verify. The DEPLOY ITSELF SUCCEEDED — the site is up." >&2
  echo "         Logs are still reaching CloudWatch (Fluent Bit fans out to both)." >&2
  echo "         Re-run: ./scripts/logging/verify-efk.sh" >&2
fi
```

Also update the two `step "11d/11 ..."` and preceding step labels only if the count changes — it does not; `11e` is a sub-step of 11, matching the existing `11b`/`11c`/`11d` convention.

- [ ] **Step 7: Register the new test in the CI suite**

`scripts/tests/test-logging-chart.sh` needs `helm`, which the agent images lack — the same reason three tests already sit in `SKIP`. Add it to the `SKIP` map in `scripts/tests/run-ci-suite.sh` alongside the existing helm-dependent entry:

```bash
  [test-logging-chart.sh]="needs helm, absent from both agent containers"
```

**Determine this by running it, not by reading it.** Confirm the skip is correct rather than assumed:

```bash
docker run --rm -v "$PWD:/w" -w /w python:3.12-slim scripts/tests/test-logging-chart.sh
```
Expected: `SKIP: helm not installed` and exit 0 — which is why it belongs in `SKIP` rather than `PYTHON_GROUP`. (Build #7 established that guessing a test's group from its source text is how tests land in the wrong container.)

- [ ] **Step 8: Run the full suite**

Run: `scripts/tests/run-ci-suite.sh`
Expected: PASS, with the final line's test count one higher than before and `test-logging-chart.sh` listed among the skips.

- [ ] **Step 9: Run the chart test directly (where helm exists)**

Run: `scripts/tests/test-logging-chart.sh`
Expected: PASS, all sections including the new teardown-ordering assertions.

- [ ] **Step 10: Commit**

```bash
git add scripts/logging/verify-efk.sh scripts/destroy.sh scripts/cleanup-stale-dns.sh \
        scripts/deploy.sh scripts/tests/test-logging-chart.sh scripts/tests/run-ci-suite.sh
git commit -m "feat(logging): teardown ordering, DNS cleanup and end-to-end verification

destroy.sh deletes the Elasticsearch/Kibana CRs BEFORE uninstalling the ECK
operator. Reversed, the ValidatingWebhookConfiguration intercepts every CR
delete with no backend alive to answer -- the same hang as the ci namespace's
finalizers on 2026-08-04. The order is asserted by a test, since the failure
only reproduces during a real billed teardown.

verify-efk.sh counts DOCUMENTS rather than checking pods: Fluent Bit's forward
output buffers and retries silently, so a broken pipeline is indistinguishable
from 'no logs yet' by any pod-level check. It self-checks that its query can
return non-zero before trusting a zero.

Also corrects the step-4 comment: this stack pre-uninstalls six releases now,
not four."
git push origin master
```

---

### Task 9: Alerts, documentation, and plan cleanup

**Files:**
- Modify: `charts/observability/templates/prometheusrule.yaml` (two new alerts)
- Create: `docs/runbooks/elasticsearch-down.md`
- Create: `docs/runbooks/fluentd-down.md`
- Modify: `docs/observability.md`, `docs/runbooks/README.md`
- Modify: `docs/deploy.md`, `docs/eks/architecture.md`, `README.submission.md`, `CLAUDE.md`
- Modify: `docs/design/2026-08-27-efk-logging-design.md` (record the TLS split decided during implementation)
- Delete: `docs/superpowers/plans/2026-08-27-efk-logging.md` (this file)

**Interfaces:**
- Consumes: everything. Nothing consumes this.

- [ ] **Step 1: Add the two alerts**

Append to the appropriate group in `charts/observability/templates/prometheusrule.yaml`:

```yaml
      # The EFK pipeline. Deliberately NOT alerting on Elasticsearch cluster health being `yellow`:
      # this is a single-node cluster with no replica shard by design (see
      # docs/design/2026-08-27-efk-logging-design.md decision 3), so yellow is its permanent, correct
      # state. An alert that fires forever is one people learn to ignore -- the same reasoning
      # recorded at VoteballJourneyTrafficStopped in charts/voteball.
      - alert: ElasticsearchDown
        expr: kube_pod_status_ready{namespace="logging", condition="true", pod=~"voteball-logs-es-.*"} == 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Elasticsearch is not Ready in the logging namespace"
          description: "Log search is unavailable. CloudWatch still holds the authoritative copy, so this is not a loss of logs."
          runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/elasticsearch-down.md"
      - alert: FluentdDown
        expr: kube_deployment_status_replicas_available{namespace="logging", deployment="fluentd"} == 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "The Fluentd aggregator has no available replica"
          description: "Fluent Bit is buffering and retrying silently; logs are not reaching Elasticsearch. CloudWatch is unaffected."
          runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/fluentd-down.md"
```

- [ ] **Step 2: Write the two runbooks**

Create `docs/runbooks/elasticsearch-down.md` and `docs/runbooks/fluentd-down.md`, following the shape of the existing files in that directory (read one first). Each must cover: what the alert means, what is and is not affected (CloudWatch keeps receiving in both cases), the diagnostic commands, and the fix. For `FluentdDown`, state explicitly that Fluent Bit reports healthy throughout and that `scripts/logging/verify-efk.sh` is the check that actually distinguishes broken from idle.

- [ ] **Step 3: Update `docs/observability.md` and `docs/runbooks/README.md`**

Add both alerts to the alert table in `docs/observability.md`, update the per-chart and total alert counts, and add both runbooks to `docs/runbooks/README.md`.

- [ ] **Step 4: Run the doc-drift test**

Run: `scripts/tests/test-observability-docs.sh`
Expected: PASS. It fails on a drifted alert set, wrong counts, a missing runbook in either direction, or an unresolvable `runbook_url` — so a failure here names exactly what is still out of step.

- [ ] **Step 5: Update the remaining docs**

- `docs/deploy.md` — add step 11e. Verify the step list against `grep -nE '^\s*step "' scripts/deploy.sh` rather than recalling it.
- `docs/eks/architecture.md` — add the `logging` namespace and the third ALB member to the diagram.
- `README.submission.md` — EFK is a graded component; give it its own section covering what runs where, why the operator is Terraform-owned, and how to reach Kibana.
- `CLAUDE.md` — add the ECK add-on and the teardown ordering to the deployment section, **and correct the stale "three Helm releases" to six** in the teardown paragraph (it names `voteball`, `jenkins`, `jenkins-support`; the script has pre-uninstalled `kube-prometheus-stack` for some time, and now `logging` and `elastic-operator` too).
- `docs/design/2026-08-27-efk-logging-design.md` — add one paragraph to decision 9 recording the TLS split settled during implementation: Elasticsearch keeps ECK's self-signed HTTP TLS with Fluentd mounting the generated CA, while Kibana sets `selfSignedCertificate.disabled: true` so the ALB (which terminates real ACM TLS) can health-check it over plain HTTP.

- [ ] **Step 6: Delete this plan**

```bash
git rm docs/superpowers/plans/2026-08-27-efk-logging.md
rmdir -p docs/superpowers/plans docs/superpowers 2>/dev/null || true
```

Per `CLAUDE.md`: an implementation plan is a process artifact and is deleted **in the same commit as the last task**, not later. `docs/superpowers/` is the superpowers workflow's default output path and regenerates every time a feature goes through it, so deleting the folder once is not a fix — the deletion happens at the end of every plan. The durable record is the design doc in `docs/design/`, which stays.

- [ ] **Step 7: Final verification**

Run:
```bash
scripts/tests/run-ci-suite.sh
scripts/tests/test-logging-chart.sh
scripts/tests/test-observability-docs.sh
cd terraform && terraform fmt -check -recursive && terraform validate && cd ..
helm lint charts/logging --set enabled=true
```
Expected: all PASS. Report the actual output — do not claim green without it.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(logging): alerts, runbooks and docs for the EFK stack

Two alerts on pod readiness, deliberately not on Elasticsearch cluster colour:
a single-node cluster is permanently yellow by design, and an alert that fires
forever is one people learn to ignore.

Corrects CLAUDE.md's stale 'three Helm releases' in the teardown notes -- the
script pre-uninstalls six.

Deletes the implementation plan in the same commit as its last task."
git push origin master
```

---

## What is NOT in this plan

`terraform apply` is **not** a step here. It creates billed AWS resources and the repo treats it as a confirm-before-running action. Everything above is authored, tested offline and committed; the apply — and with it the first real run of `verify-efk.sh` — is a separate, explicitly-approved action.

Expected cost once applied: **+~$0.13/day** for the 20Gi gp3 volume. No extra node, by construction (Global Constraints, the budget assertion in Task 1).
