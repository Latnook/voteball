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

grep -qE 'storageClassName:[[:space:]]*"?gp3"?[[:space:]]*$' <<<"$out" || fail "Elasticsearch volume must use the gp3 StorageClass"
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

# --- Kibana ------------------------------------------------------------------------------------
grep -q 'kind: Kibana' <<<"$out" || fail "no Kibana resource rendered"
pass "Kibana resource present"

grep -qE 'elasticsearchRef:' <<<"$out" || fail "Kibana must carry an elasticsearchRef so ECK wires its credentials"
pass "Kibana references Elasticsearch"

# The ALB group name is the teardown-critical field. A grouped ALB is de-provisioned only when NO
# member Ingress remains; a typo here leaves a second ALB billing after destroy, and its ENIs then
# block VPC deletion.
grep -qE 'alb\.ingress\.kubernetes\.io/group\.name:[[:space:]]*"?voteball"?[[:space:]]*$' <<<"$out" \
  || fail "Kibana Ingress must join ALB group 'voteball' exactly (a substring match like voteball-kibana is a DIFFERENT ALB group)"
pass "Kibana Ingress joins ALB group voteball"

# ALB terminates real ACM TLS, so Kibana itself must serve plain HTTP -- otherwise the ALB health
# check hits a self-signed HTTPS listener and the target never goes healthy.
# Scoped to the Kibana template with --show-only, NOT with a positional window on $out. This is
# immune to comment placement AND to another template later adding an unrelated `disabled:` field
# -- a chart-wide grep for `disabled: true` holds only while that string happens to be unique.
kb="$(helm template logging "$CHART" --namespace logging --set enabled=true --show-only templates/kibana.yaml)"
grep -qE 'selfSignedCertificate:' <<<"$kb" || fail "Kibana must disable its self-signed certificate (ALB terminates TLS)"
grep -qE '^[[:space:]]*disabled:[[:space:]]*true' <<<"$kb" || fail "Kibana selfSignedCertificate.disabled must be true"
pass "Kibana self-signed TLS disabled (ALB terminates)"

# --- Fluentd -----------------------------------------------------------------------------------
# Scoped to the Fluentd template with --show-only, and every check below anchored at end of line --
# the same rigor the Kibana block above already applies. Unanchored / whole-output checks would
# pass on a renamed object (fluentd-aggregator), a substring match (the ES host name is itself a
# substring of the CA secret name mounted a few lines below), or another template landing the same
# field name later (Task 4's ILM Job carries the same runAsNonRoot/readOnlyRootFilesystem keys).
fd="$(helm template logging "$CHART" --namespace logging --set enabled=true --show-only templates/fluentd.yaml)"

grep -qE '^[[:space:]]*name:[[:space:]]*"?fluentd"?[[:space:]]*$' <<<"$fd" || fail "no fluentd objects rendered"
pass "Fluentd present"

# The Service and Deployment must each be named EXACTLY fluentd (global constraint) -- Task 6's
# Fluent Bit targets fluentd.logging.svc.cluster.local by that name. Scoped to each object's own
# metadata block (from `kind: X` to that object's own top-level `spec:`, a structural boundary, not
# a fixed line count) so the Deployment's container -- itself also named "fluentd" -- cannot
# satisfy a check meant to verify the OBJECT's name if only the object's metadata.name were renamed.
svc_meta="$(sed -n '/^kind: Service$/,/^spec:$/p' <<<"$fd")"
grep -qE '^[[:space:]]*name:[[:space:]]*"?fluentd"?[[:space:]]*$' <<<"$svc_meta" || fail "Fluentd Service must be named fluentd"
deploy_meta="$(sed -n '/^kind: Deployment$/,/^spec:$/p' <<<"$fd")"
grep -qE '^[[:space:]]*name:[[:space:]]*"?fluentd"?[[:space:]]*$' <<<"$deploy_meta" || fail "Fluentd Deployment must be named fluentd"
pass "Fluentd Service and Deployment named fluentd"

# Port 24224 is Fluent Bit's `forward` output target. A mismatch here means Fluent Bit reports
# healthy and ships nothing -- the exact silent-failure shape addon-cloudwatch.tf warns about.
grep -qE '^[[:space:]]*containerPort:[[:space:]]*24224[[:space:]]*$' <<<"$fd" || fail "Fluentd must listen on 24224 (forward protocol)"
grep -qE '^[[:space:]]*port:[[:space:]]*24224[[:space:]]*$' <<<"$fd" || fail "Fluentd Service must expose 24224"
pass "Fluentd forward port 24224"

# Matches the fluent.conf `host` DIRECTIVE specifically. A plain substring grep for
# voteball-logs-es-http would ALSO match voteball-logs-es-http-certs-public (the CA secret name
# mounted a few lines below) and would still pass with the host line deleted entirely.
grep -qE '^[[:space:]]*host[[:space:]]+voteball-logs-es-http[[:space:]]*$' <<<"$fd" \
  || fail "fluent.conf must point at the Elasticsearch Service voteball-logs-es-http"
pass "Fluentd targets Elasticsearch"

# ES keeps ECK's self-signed HTTP TLS, so Fluentd must mount the operator-generated public CA.
# Without it Fluentd retries forever on certificate verification and logs never arrive.
grep -qE 'secretName:[[:space:]]*"?voteball-logs-es-http-certs-public"?[[:space:]]*$' <<<"$fd" \
  || fail "Fluentd must mount the Elasticsearch CA secret"
grep -qE 'name:[[:space:]]*"?voteball-logs-es-elastic-user"?[[:space:]]*$' <<<"$fd" \
  || fail "Fluentd must read the elastic user password secret"
pass "Fluentd mounts the ES CA and credentials"

grep -qE '^[[:space:]]*runAsNonRoot:[[:space:]]*true[[:space:]]*$' <<<"$fd" || fail "Fluentd must run as non-root"
grep -qE '^[[:space:]]*readOnlyRootFilesystem:[[:space:]]*true[[:space:]]*$' <<<"$fd" \
  || fail "Fluentd must set readOnlyRootFilesystem: true (emptyDirs cover the two paths it writes)"
pass "Fluentd runs non-root on a read-only root filesystem"

# --- ILM ---------------------------------------------------------------------------------------
# Without a retention policy the 20Gi volume fills in ~130 days, Elasticsearch flips the index
# read-only at its flood-stage watermark, and ingestion stops SILENTLY from the writer's side.
grep -q 'voteball-logs-7d' <<<"$out" || fail "no ILM policy rendered -- the volume would fill and ingestion would stop silently"
pass "ILM policy present"

grep -qE 'kind:[[:space:]]*Job' <<<"$out" || fail "ILM must be applied by a Job (StackConfigPolicy needs an Enterprise licence)"
pass "ILM applied by a Job"

# The delete phase's real ILM key is min_age, not max_age (max_age governs the hot-phase
# rollover, which is deliberately 1d, not 7d) -- checking max_age here would never match the
# Job's own delete phase.
grep -qE '"min_age":[[:space:]]*"7d"|min_age.*7d' <<<"$out" || fail "ILM delete phase must be 7 days"
pass "7-day retention"

# helm hook weights: the Job must run AFTER the Elasticsearch resource exists, or it curls nothing.
grep -qE '"?helm\.sh/hook"?:' <<<"$out" || fail "ILM Job must be a post-install/post-upgrade hook"
pass "ILM Job is a hook"

# Scoped to the ILM template with --show-only, following the Kibana/Fluentd shape above.
ilm="$(helm template logging "$CHART" --namespace logging --set enabled=true --show-only templates/ilm.yaml)"

grep -qE '"?helm\.sh/hook"?:[[:space:]]*"?post-install,post-upgrade"?[[:space:]]*$' <<<"$ilm" \
  || fail "ILM Job must be a post-install,post-upgrade hook, never pre-install -- Elasticsearch must exist first"
pass "ILM Job hooks post-install,post-upgrade"

# Every curl that must succeed uses -f, so a rejected policy FAILS the Job instead of printing an
# error body and reporting success (the swallowed-exit-status shape CLAUDE.md warns about three
# times over). Count the -f/-sf occurrences against the curl calls that are supposed to carry it:
# the health-check wait, the ILM policy PUT, and the index template PUT -- three in total. The
# fourth curl (the alias bootstrap) deliberately omits it because HTTP 400 is a normal case there.
# Restricted to lines that are actual curl invocations against the ES endpoint (they all reference
# "$ES/"), not a whole-file text grep -- a future comment mentioning "curl ... -f" would otherwise
# inflate this count without a matching real call.
# Real invocations reference the ES endpoint ($ES/...); a comment merely mentioning "curl ... -f"
# does not, so this can't be inflated by prose the way a bare text grep could be.
curl_f_count="$(grep -vE '^\s*#' <<<"$ilm" | grep -E '\$ES/' | grep -cE -- '-s?f\b')"
[ "$curl_f_count" -ge 3 ] || fail "expected at least 3 curl calls with -f (health wait, ILM policy, index template); found $curl_f_count -- a curl without -f reports success on an HTTP 400"
pass "ILM policy and index template curls use -f"

# --- alias / index-template / shard-replica assertions -----------------------------------------
# The alias voteball-logs is a SUBSTRING of the policy name voteball-logs-7d, so these must be
# anchored (no bare `grep voteball-logs`) or they assert nothing -- proven by the negative check
# that renames the rollover alias to voteball-logs-7d and confirms the test still fails.
grep -qE '"index\.lifecycle\.rollover_alias":[[:space:]]*"voteball-logs"' <<<"$ilm" \
  || fail "index template must set the ILM rollover alias to voteball-logs"
pass "index template sets rollover alias voteball-logs"

grep -qE '"number_of_shards":[[:space:]]*1[[:space:]]*,?[[:space:]]*$' <<<"$ilm" || fail "single shard"
pass "single shard"

grep -qE '"number_of_replicas":[[:space:]]*0[[:space:]]*,?[[:space:]]*$' <<<"$ilm" \
  || fail "no replica -- single-node ES by design"
pass "no replica (single-node ES)"


# --- NetworkPolicy -------------------------------------------------------------------------------
# Helm strips only {{/* */}} template comments -- plain YAML `#` comments render straight through,
# and this template's prose comments mention every one of the strings below (amazon-cloudwatch,
# allow-dns-egress, the CIDRs, default-deny). Scoping with --show-only AND stripping full-line `#`
# comments is required, or these assertions pass even with the real policy deleted. Anchoring on
# STRUCTURE (name:/cidr:/port: values, not bare substrings) is what survives the inline trailing
# comments (e.g. `port: 9200 }  # Elasticsearch ...`) that full-line stripping does not touch.
np="$(helm template logging "$CHART" --namespace logging --set enabled=true \
       --show-only templates/networkpolicy.yaml | grep -vE '^[[:space:]]*#')"

grep -qE '^kind:[[:space:]]*"?NetworkPolicy"?[[:space:]]*$' <<<"$np" \
  || fail "logging namespace must be default-deny like every other namespace here"
pass "NetworkPolicies present"

grep -qE '^[[:space:]]*name:[[:space:]]*"?default-deny"?[[:space:]]*$' <<<"$np" \
  || fail "missing the default-deny policy"
pass "default-deny"

grep -qE '^[[:space:]]*name:[[:space:]]*"?allow-dns-egress"?[[:space:]]*$' <<<"$np" \
  || fail "missing DNS egress"
pass "DNS egress policy present"

# Fluent Bit lives in amazon-cloudwatch. Without this ingress rule it connects, times out, buffers
# and reports healthy -- shipping nothing. Assert both the policy name and the namespaceSelector
# VALUE that actually admits it, anchored so a typo'd namespace (e.g. amazon-cloudwatch-x) fails.
grep -qE '^[[:space:]]*name:[[:space:]]*"?allow-fluentbit-ingest"?[[:space:]]*$' <<<"$np" \
  || fail "missing the allow-fluentbit-ingest policy"
pass "allow-fluentbit-ingest policy present"

grep -qE '^[[:space:]]*kubernetes\.io/metadata\.name:[[:space:]]*"?amazon-cloudwatch"?[[:space:]]*$' <<<"$np" \
  || fail "must admit Fluent Bit from the amazon-cloudwatch namespace"
pass "admits Fluent Bit from the amazon-cloudwatch namespace"

grep -qE 'port:[[:space:]]*24224[[:space:]]*\}' <<<"$np" \
  || fail "Fluent Bit ingest must open TCP 24224"
pass "Fluent Bit ingest opens port 24224"

# The ALB reaches Kibana from the PUBLIC subnets -- both CIDRs, as cidr: values inside an ipBlock,
# not comment prose.
grep -qE 'cidr:[[:space:]]*"?10\.0\.0\.0/20"?[[:space:]]*\}' <<<"$np" \
  || fail "must admit the ALB from public subnet CIDR 10.0.0.0/20"
pass "admits the ALB from 10.0.0.0/20"

grep -qE 'cidr:[[:space:]]*"?10\.0\.16\.0/20"?[[:space:]]*\}' <<<"$np" \
  || fail "must admit the ALB from public subnet CIDR 10.0.16.0/20"
pass "admits the ALB from 10.0.16.0/20"

# Service-CIDR egress: load-bearing because the VPC CNI evaluates egress PRE-DNAT -- against the
# ClusterIP the client dialled, not the pod IP the Service routes to -- so a same-namespace
# podSelector rule does not cover pod-to-pod traffic that goes via a ClusterIP. Each port must be
# individually enumerated; omitting one is a runtime timeout with nothing in any log to point at it.
grep -qE 'cidr:[[:space:]]*"?172\.20\.0\.0/16"?[[:space:]]*\}' <<<"$np" \
  || fail "must open egress to the Service CIDR 172.20.0.0/16"
pass "Service CIDR egress present"

grep -qE 'port:[[:space:]]*9200[[:space:]]*\}' <<<"$np" \
  || fail "Service-CIDR egress must include TCP 9200 (Elasticsearch) -- omitting it times out silently"
pass "Service-CIDR egress includes port 9200 (Elasticsearch)"

grep -qE 'port:[[:space:]]*5601[[:space:]]*\}' <<<"$np" \
  || fail "Service-CIDR egress must include TCP 5601 (Kibana)"
pass "Service-CIDR egress includes port 5601 (Kibana)"

grep -qE 'port:[[:space:]]*443[[:space:]]*\}' <<<"$np" \
  || fail "Service-CIDR egress must include TCP 443 (Kubernetes API)"
pass "Service-CIDR egress includes port 443 (Kubernetes API)"

echo "PASS: charts/logging"
