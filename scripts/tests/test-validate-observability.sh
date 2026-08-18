#!/usr/bin/env bash
# Offline test for scripts/ci/validate-observability.sh. NOT actually offline in the "no network"
# sense -- it needs `helm` on PATH the same way test-jenkins-chart.sh needs `helm`, which is why this
# test is classified into SKIP in run-ci-suite.sh rather than PYTHON_GROUP or GIT_GROUP: neither of
# Jenkinsfile-ci's containers carries helm (confirmed 2026-08-18 by running `which helm` inside both
# python:3.12-slim and the jnlp/inbound-agent image -- absent from both).
#
# Same stub pattern as test-validate-repo.sh: build a throwaway chart + services tree and point the
# script under test at it via CHARTS / SERVICES_DIR, so nothing here touches the real repo's charts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v helm >/dev/null 2>&1 || fail "this test needs helm on PATH (see the header comment)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

CHART_DIR="charts/test"
SM_FILE="$CHART_DIR/templates/servicemonitor.yaml"
SVC_FILE="$CHART_DIR/templates/service.yaml"
RULE_FILE="$CHART_DIR/templates/prometheusrule.yaml"
DASH_FILE="$CHART_DIR/dashboards/dash.json"

# Backend metrics.py used by the collision check (check 3). `collide` toggles whether it declares an
# `endpoint` label -- the exact label that collided for real on 2026-08-18.
write_metrics() {
  local collide="$1"
  mkdir -p services/backend
  if [ "$collide" = "yes" ]; then
    cat > services/backend/metrics.py <<'PY'
from prometheus_client import Counter
REQUESTS = Counter('app_requests_total', 'requests', ['method', 'endpoint', 'status'])
PY
  else
    cat > services/backend/metrics.py <<'PY'
from prometheus_client import Counter
REQUESTS = Counter('app_requests_total', 'requests', ['method', 'route', 'status'])
PY
  fi
}

write_service() {
  local port_name="${1:-http}"
  mkdir -p "$(dirname "$SVC_FILE")"
  cat > "$SVC_FILE" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: default
  labels:
    app: backend
spec:
  selector:
    app: backend
  ports:
    - name: $port_name
      port: 5000
EOF
}

write_servicemonitor() {
  local release_label="$1" honor="$2" sm_port="${3:-http}"
  mkdir -p "$(dirname "$SM_FILE")"
  {
    echo "apiVersion: monitoring.coreos.com/v1"
    echo "kind: ServiceMonitor"
    echo "metadata:"
    echo "  name: backend"
    echo "  namespace: default"
    echo "  labels:"
    echo "    app: backend"
    if [ "$release_label" = "yes" ]; then
      echo "    release: kube-prometheus-stack"
    fi
    echo "spec:"
    echo "  selector:"
    echo "    matchLabels: { app: backend }"
    echo "  endpoints:"
    echo "    - port: $sm_port"
    if [ "$honor" = "yes" ]; then
      echo "      honorLabels: true"
    fi
  } > "$SM_FILE"
}

write_rule() {
  local release_label="$1"
  mkdir -p "$(dirname "$RULE_FILE")"
  {
    echo "apiVersion: monitoring.coreos.com/v1"
    echo "kind: PrometheusRule"
    echo "metadata:"
    echo "  name: test-alerts"
    echo "  namespace: default"
    echo "  labels:"
    if [ "$release_label" = "yes" ]; then
      echo "    release: kube-prometheus-stack"
    fi
    echo "spec:"
    echo "  groups:"
    echo "    - name: test.rules"
    echo "      rules:"
    echo "        - alert: TestAlwaysFine"
    echo "          expr: vector(1) == 1"
    echo "          for: 5m"
    echo "          labels:"
    echo "            severity: info"
    echo "          annotations:"
    echo "            summary: \"test\""
  } > "$RULE_FILE"
}

write_dashboard() {
  mkdir -p "$(dirname "$DASH_FILE")"
  printf '%s' "$1" > "$DASH_FILE"
}

GOOD_DASHBOARD='{"uid":"test-dash","title":"Test Dashboard","panels":[{"id":1,"title":"Panel A","type":"timeseries","targets":[{"expr":"up","refId":"A"}]}]}'

scaffold() {
  rm -rf "$work"/repo && mkdir -p "$work"/repo
  cd "$work"/repo
  mkdir -p "$CHART_DIR/templates"
  printf 'apiVersion: v2\nname: test\nversion: 0.1.0\n' > "$CHART_DIR/Chart.yaml"
  write_service "http"
  write_servicemonitor "yes" "yes" "http"
  write_rule "yes"
  write_dashboard "$GOOD_DASHBOARD"
  write_metrics "no"
}

run() {
  CHARTS="$CHART_DIR" SERVICES_DIR="services" "$ROOT/scripts/ci/validate-observability.sh"
}

echo "--- a well-formed chart passes ---"
scaffold
out="$(run 2>&1)" || fail "clean fixture should pass. Output:
$out"
echo "$out" | grep -q "all checks passed" || fail "clean fixture: missing the pass banner. Output:
$out"

echo "--- missing release label on a ServiceMonitor fails, naming the object ---"
scaffold
write_servicemonitor "no" "yes" "http"
out="$(run 2>&1)" && fail "missing release label should fail. Output:
$out"
echo "$out" | grep -q "ServiceMonitor 'backend'.*missing labels.release: kube-prometheus-stack" \
  || fail "wrong/missing error message for check 1 (ServiceMonitor). Output:
$out"

echo "--- missing release label on a PrometheusRule fails, naming the object ---"
scaffold
write_rule "no"
out="$(run 2>&1)" && fail "missing release label on PrometheusRule should fail. Output:
$out"
echo "$out" | grep -q "PrometheusRule 'test-alerts'.*missing labels.release: kube-prometheus-stack" \
  || fail "wrong/missing error message for check 1 (PrometheusRule). Output:
$out"

echo "--- a ServiceMonitor endpoint naming a nonexistent port fails ---"
scaffold
write_servicemonitor "yes" "yes" "does-not-exist"
out="$(run 2>&1)" && fail "a typo'd port name should fail. Output:
$out"
echo "$out" | grep -q "names port 'does-not-exist', which does not exist on the Service" \
  || fail "wrong/missing error message for check 2 (bad port name). Output:
$out"

echo "--- a colliding metric label without honorLabels fails ---"
scaffold
write_metrics "yes"
write_servicemonitor "yes" "no" "http"
out="$(run 2>&1)" && fail "a reserved-label collision without honorLabels should fail. Output:
$out"
echo "$out" | grep -q "collide with prometheus-operator's own TARGET label" \
  || fail "wrong/missing error message for check 3 (label collision). Output:
$out"
echo "$out" | grep -q "honorLabels: true" || fail "check 3 failure should tell the reader to add honorLabels: true. Output:
$out"

echo "--- the SAME collision with honorLabels: true is accepted ---"
scaffold
write_metrics "yes"
write_servicemonitor "yes" "yes" "http"
out="$(run 2>&1)" || fail "honorLabels: true should satisfy check 3 even with a colliding label. Output:
$out"
echo "$out" | grep -q "all checks passed" || fail "honorLabels fixture: missing the pass banner. Output:
$out"

echo "--- an endpoint with no local metrics.py and no honorLabels is flagged for review, not failed ---"
scaffold
write_servicemonitor "yes" "no" "http"
rm -f services/backend/metrics.py
out="$(run 2>&1)" || fail "an unintrospectable target without honorLabels must not fail the build (advisory only). Output:
$out"
echo "$out" | grep -q "NOTE:.*flagged for manual review" \
  || fail "expected an advisory NOTE for the unintrospectable case. Output:
$out"

echo "--- a dashboard that does not parse fails ---"
scaffold
write_dashboard '{not valid json'
out="$(run 2>&1)" && fail "invalid dashboard JSON should fail. Output:
$out"
echo "$out" | grep -q "does not parse as JSON" || fail "wrong/missing error message for check 4 (bad JSON). Output:
$out"

echo "--- a dashboard with no uid fails ---"
scaffold
write_dashboard '{"title":"Test Dashboard","panels":[{"id":1,"title":"Panel A","type":"timeseries","targets":[{"expr":"up","refId":"A"}]}]}'
out="$(run 2>&1)" && fail "dashboard with no uid should fail. Output:
$out"
echo "$out" | grep -q "has no 'uid'" || fail "wrong/missing error message for check 4 (no uid). Output:
$out"

echo "--- a dashboard with no title fails ---"
scaffold
write_dashboard '{"uid":"test-dash","panels":[{"id":1,"title":"Panel A","type":"timeseries","targets":[{"expr":"up","refId":"A"}]}]}'
out="$(run 2>&1)" && fail "dashboard with no title should fail. Output:
$out"
echo "$out" | grep -q "has no 'title'" || fail "wrong/missing error message for check 4 (no title). Output:
$out"

echo "--- a panel with no query fails ---"
scaffold
write_dashboard '{"uid":"test-dash","title":"Test Dashboard","panels":[{"id":1,"title":"Empty Panel","type":"timeseries","targets":[]}]}'
out="$(run 2>&1)" && fail "a panel with no query should fail. Output:
$out"
echo "$out" | grep -q "panel 'Empty Panel' has no non-empty query" \
  || fail "wrong/missing error message for check 4 (empty query). Output:
$out"

echo "--- a row panel legitimately has no query and is accepted ---"
scaffold
write_dashboard '{"uid":"test-dash","title":"Test Dashboard","panels":[{"id":1,"title":"Section","type":"row"}]}'
out="$(run 2>&1)" || fail "a row panel with no targets should not fail. Output:
$out"
echo "$out" | grep -q "all checks passed" || fail "row-panel fixture: missing the pass banner. Output:
$out"

echo "--- promtool is either run or its absence is reported loudly, never silently ---"
scaffold
out="$(run 2>&1)" || fail "clean fixture should still pass. Output:
$out"
echo "$out" | grep -qE "promtool check rules: (PASS|SKIPPED)" \
  || fail "expected an explicit promtool PASS or SKIPPED line, got:
$out"
if ! command -v promtool >/dev/null 2>&1; then
  echo "$out" | grep -q "SKIPPED -- promtool is not on PATH. This is NOT a pass" \
    || fail "promtool absent must be reported LOUDLY as a skip, not silently. Output:
$out"
fi

echo "ALL TESTS PASSED"
