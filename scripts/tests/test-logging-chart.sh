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

grep -qE 'storageClassName:[[:space:]]*"?gp3"?' <<<"$out" || fail "Elasticsearch volume must use the gp3 StorageClass"
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
grep -qE 'alb\.ingress\.kubernetes\.io/group\.name:[[:space:]]*voteball' <<<"$out" \
  || fail "Kibana Ingress must join ALB group 'voteball' (same group as charts/voteball and ci/jenkins-webhook)"
pass "Kibana Ingress joins ALB group voteball"

# ALB terminates real ACM TLS, so Kibana itself must serve plain HTTP -- otherwise the ALB health
# check hits a self-signed HTTPS listener and the target never goes healthy.
grep -qE 'selfSignedCertificate:' <<<"$out" || fail "Kibana must disable its self-signed certificate (ALB terminates TLS)"
grep -A2 'selfSignedCertificate:' <<<"$out" | grep -qE 'disabled:[[:space:]]*true' \
  || fail "Kibana selfSignedCertificate.disabled must be true"
pass "Kibana self-signed TLS disabled (ALB terminates)"

echo "PASS: charts/logging"
