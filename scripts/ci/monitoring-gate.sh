#!/usr/bin/env bash
# CD Monitoring Gate stage. Runs after the Smoke Test, once ArgoCD reports Healthy -- which means the
# OLD pods are gone and every request this script measures is served by the NEW build, so it can
# attribute what it sees to this release without per-version metric filtering.
#
# Smoke Test asks "does the product answer?" This asks a different question: "does the product answer
# WELL, at the rate the SLOs promise?" It generates a short burst of real traffic against the public
# journey endpoints, waits for Prometheus to scrape it, then asks three questions of the SAME recording
# rules the dashboard and the alerts already use (voteball:journey_requests:rate5m,
# voteball:availability:ratio5m, voteball:latency:p95_5m, plus the bare `up` metric for the targets
# check) -- never new PromQL, so there is exactly one definition of each SLI in this repo.
#
# ##################################################################################################
# THE MOST IMPORTANT PROPERTY OF THIS SCRIPT: IT PASSES WHEN IT HAS TOO LITTLE DATA TO JUDGE.
#
# In Jenkinsfile-cd, anything that fails after the Promote stage triggers an automatic rollback of
# PRODUCTION. Promote is the point of no return. A gate that failed on missing data would roll back a
# perfectly healthy release every single time the metrics pipeline merely hiccuped -- a slow scrape, a
# cold cache, a quiet minute -- turning a safety feature into an outage generator that fires on
# nothing. A genuinely broken scrape needs NO traffic to detect: that is what the targets-up check is
# for, and it runs first, unconditionally. So: below GATE_MIN_SAMPLES observed requests, with every
# target up, is a PASS with a loud warning, not a failure. Do not "tighten" this later -- it is the
# single property this whole script exists to get right. See docs/design/2026-08-17-observability-
# design.md section 12 and docs/design/2026-08-04-cicd-split-design.md for why a post-Promote failure
# is never free.
#
# The one case that is NOT "insufficient data" is the SLI being ABSENT (no series at all for
# voteball:journey_requests:rate5m). That is the exact condition the VoteballSLIAbsent alert pages on
# -- it means the measurement pipeline itself is broken (instrumentation, scrape, or a label
# collision), not "quiet traffic". This script fails on it, distinctly, rather than folding it into
# the insufficient-samples warm-and-pass path.
# ##################################################################################################
#
# Every query goes through PROM_STUB_QUERY_CMD when set, the same insertion point
# scripts/wait-for-argocd-sync.sh uses for ARGOCD_STUB_STATUS_CMD -- so the poll/threshold logic below
# can be exercised offline, in seconds, with no cluster and no real Prometheus. See
# scripts/tests/test-monitoring-gate.sh.
set -uo pipefail

PROM_URL="${PROM_URL:-http://kube-prometheus-stack-prometheus.observability:9090}"
: "${GATE_BASE_URL:?GATE_BASE_URL must be set (e.g. https://voteball.example.com, or a port-forwarded http://localhost:8080 for a by-hand run)}"
GATE_REQUESTS="${GATE_REQUESTS:-40}"
GATE_MAX_ERROR_RATIO="${GATE_MAX_ERROR_RATIO:-0.01}"
GATE_MAX_P95_SECONDS="${GATE_MAX_P95_SECONDS:-1.0}"
GATE_MIN_SAMPLES="${GATE_MIN_SAMPLES:-20}"

# Not part of the task's env-var contract, but real knobs with sane defaults rather than literals
# buried in the logic below:
#   - GATE_NAMESPACE: the release's own namespace (never "default", per the root CLAUDE.md). The
#     targets-up check is scoped here, not cluster-wide -- this gate judges ONE release, and a
#     platform-wide scrape problem outside devops-app already has its own alert (PrometheusTargetDown).
#   - GATE_WAIT_SECONDS: servicemonitor.yaml scrapes backend/worker/frontend every 30s. Traffic
#     generated and queried in the same breath will not be reflected yet, so the gate always waits at
#     least one interval (+ a small buffer for scrape/eval jitter) before asking Prometheus anything.
#     Tests override this to 0 -- the sleep itself is not what is under test.
GATE_NAMESPACE="${GATE_NAMESPACE:-devops-app}"
GATE_WAIT_SECONDS="${GATE_WAIT_SECONDS:-35}"

# The lookback window baked into the recording rules (rate5m = a 5-minute rate). Needed to turn the
# per-second rate voteball:journey_requests:rate5m reports back into an approximate request COUNT,
# which is what GATE_MIN_SAMPLES is expressed in.
RATE_WINDOW_SECONDS=300

status=0

# --------------------------------------------------------------------------------------------------
# Traffic generation. Same journey endpoints scripts/ci/smoke-test.sh uses -- deliberately NOT
# /health: nginx proxies only /api/*, so it 404s publicly, and it's already the in-cluster probe
# target rather than a user-facing path. Spread across ~20s, comfortably under the 30s scrape
# interval, so the whole burst has a real chance of landing in a single scrape window instead of being
# split unpredictably across two.
# --------------------------------------------------------------------------------------------------
generate_traffic() {
  local n="$1" base="$2"
  if [ "$n" -le 0 ]; then
    echo "gate: GATE_REQUESTS=${n} -- skipping traffic generation"
    return
  fi
  local paths=(/ /api/options '/api/results?by=all')
  local spread=20
  local delay
  delay="$(awk -v s="$spread" -v n="$n" 'BEGIN{d=s/n; if (d<0) d=0; printf "%.3f", d}')"
  echo "gate: sending ${n} requests to ${base} (journey endpoints) over ~${spread}s"
  local i=0 path
  while [ "$i" -lt "$n" ]; do
    path="${paths[$((i % ${#paths[@]}))]}"
    curl -sS --max-time 5 -o /dev/null "${base}${path}" >/dev/null 2>&1 || true
    i=$((i + 1))
    [ "$i" -lt "$n" ] && sleep "$delay"
  done
}

# --------------------------------------------------------------------------------------------------
# Prometheus HTTP API. prom_query_raw is the ONLY thing PROM_STUB_QUERY_CMD needs to replace -- same
# shape as SMOKE_STUB_CURL in scripts/ci/smoke-test.sh: an executable receiving the query text as $1,
# printing the same JSON body the real /api/v1/query endpoint would, exiting non-zero for a transport
# failure.
# --------------------------------------------------------------------------------------------------
prom_query_raw() {
  local promql="$1"
  if [ -n "${PROM_STUB_QUERY_CMD:-}" ]; then
    "$PROM_STUB_QUERY_CMD" "$promql"
  else
    curl -sS --max-time 10 -G "${PROM_URL}/api/v1/query" --data-urlencode "query=${promql}"
  fi
}

# prom_scalar QUERY
# Runs one instant query expected to yield at most one series (every query below is either a bare
# recording-rule name or wrapped in an outer aggregator like min(...), by design).
#   exit 0, value on stdout : got a number
#   exit 2                  : the query succeeded but returned no series at all ("absent")
#   exit 3                  : the query itself could not be answered -- transport failure, or
#                             Prometheus's own {"status":"error",...} envelope. This is Prometheus (or
#                             the network to it) being broken, NOT "no data" -- callers must treat it
#                             as a failure, never as insufficient-data-so-pass.
prom_scalar() {
  local promql="$1" raw val
  if ! raw="$(prom_query_raw "$promql")"; then
    return 3
  fi
  case "$raw" in
    *'"status":"success"'*) ;;
    *) return 3 ;;
  esac
  val="$(printf '%s' "$raw" | grep -oE '"value":\[[^,]+,"[^"]*"\]' | head -n1 | sed -E 's/.*,"([^"]*)"\]/\1/')"
  if [ -z "$val" ] || [ "$val" = "NaN" ]; then
    return 2
  fi
  printf '%s\n' "$val"
}

die_unreachable() {
  echo "gate: FAIL -- Prometheus at ${PROM_URL} could not answer the ${1} query (transport failure or a non-success response). This is a BROKEN GATE, not insufficient data: we cannot tell whether the release is healthy, and 'cannot tell' is not the same as 'looks fine' -- so it fails. (Insufficient traffic is handled separately below, once we know Prometheus itself is answering.)" >&2
  exit 1
}

echo "==> monitoring-gate: PROM_URL=${PROM_URL} GATE_BASE_URL=${GATE_BASE_URL} namespace=${GATE_NAMESPACE}"
generate_traffic "$GATE_REQUESTS" "$GATE_BASE_URL"

echo "==> Waiting ${GATE_WAIT_SECONDS}s for at least one scrape (interval: 30s) to pick up that traffic"
[ "$GATE_WAIT_SECONDS" -gt 0 ] && sleep "$GATE_WAIT_SECONDS"

# ---- Question 1: are the declared targets up? -----------------------------------------------------
# Needs NO traffic -- this is what catches a genuinely broken scrape, which is exactly why the
# insufficient-samples case below is allowed to pass instead of failing blind.
targets_query="min(up{namespace=\"${GATE_NAMESPACE}\"})"
targets_val="$(prom_scalar "$targets_query")"; rc=$?
case "$rc" in
  3) die_unreachable "targets" ;;
  2)
    echo "gate: FAIL -- no scrape targets are registered for namespace ${GATE_NAMESPACE} at all (query returned no series). Nothing is even being monitored, which is worse than one target being down." >&2
    exit 1
    ;;
esac
targets_up=1
if awk -v v="$targets_val" 'BEGIN{exit !(v>=1)}'; then
  echo "gate: OK   -- all scrape targets in ${GATE_NAMESPACE} report up (min(up)=${targets_val})"
else
  echo "gate: FAIL -- at least one scrape target in ${GATE_NAMESPACE} reports up==0 (min(up)=${targets_val})" >&2
  targets_up=0
  status=1
fi

# ---- Question 2 (gate): is the SLI itself present? -------------------------------------------------
# Absence here is distinct from "not enough samples yet" -- it is the same condition
# VoteballSLIAbsent pages on: the pipeline that produces this number is broken, not merely quiet.
sli_query="voteball:journey_requests:rate5m"
rate_val="$(prom_scalar "$sli_query")"; rc=$?
case "$rc" in
  3) die_unreachable "journey-requests SLI" ;;
  2)
    echo "gate: FAIL -- ${sli_query} is ABSENT, not just low. This is the same condition the VoteballSLIAbsent alert pages on: the measurement pipeline itself (instrumentation, scrape, or a label collision) is broken, and the gate cannot judge this release at all. Not treating this as 'insufficient data' -- see docs/runbooks/VoteballSLIAbsent.md." >&2
    exit 1
    ;;
esac

samples="$(awk -v r="$rate_val" -v w="$RATE_WINDOW_SECONDS" 'BEGIN{printf "%.2f", r*w}')"
echo "gate: observed ~${samples} journey requests over the last ${RATE_WINDOW_SECONDS}s (rate=${rate_val}/s)"

below_min=0
awk -v s="$samples" -v m="$GATE_MIN_SAMPLES" 'BEGIN{exit !(s < m)}' && below_min=1

if [ "$below_min" -eq 1 ]; then
  if [ "$targets_up" -eq 1 ]; then
    echo "gate: WARNING -- only ~${samples} journey requests observed, below GATE_MIN_SAMPLES=${GATE_MIN_SAMPLES}."
    echo "gate: WARNING -- PASSING ANYWAY. This is deliberate: anything failing after Promote in Jenkinsfile-cd triggers an automatic rollback of production, so a gate that failed on thin data would roll back a perfectly healthy release every time the metrics pipeline was merely slow or quiet. Real breakage with zero traffic is already caught by the targets-up check above, which needs none."
    echo "gate: PASS (with warning) -- insufficient samples, but every target is up"
    exit 0
  fi
  echo "gate: FAIL -- insufficient samples AND a scrape target is down; the targets-up failure above stands (thin data does not excuse a target that is actually down)." >&2
  exit 1
fi

# ---- Question 3: is the error ratio under threshold? -----------------------------------------------
avail_query="voteball:availability:ratio5m"
avail_val="$(prom_scalar "$avail_query")"; rc=$?
case "$rc" in
  3) die_unreachable "availability" ;;
  2)
    echo "gate: WARNING -- ${avail_query} returned no data even though ${sli_query} shows traffic; skipping the error-ratio check this run."
    ;;
  *)
    error_ratio="$(awk -v a="$avail_val" 'BEGIN{printf "%.6f", 1-a}')"
    if awk -v e="$error_ratio" -v t="$GATE_MAX_ERROR_RATIO" 'BEGIN{exit !(e > t)}'; then
      echo "gate: FAIL -- error ratio ${error_ratio} exceeds GATE_MAX_ERROR_RATIO=${GATE_MAX_ERROR_RATIO} (availability=${avail_val})" >&2
      status=1
    else
      echo "gate: OK   -- error ratio ${error_ratio} is within GATE_MAX_ERROR_RATIO=${GATE_MAX_ERROR_RATIO}"
    fi
    ;;
esac

# ---- Question 4: is p95 latency under threshold? -----------------------------------------------
p95_query="voteball:latency:p95_5m"
p95_val="$(prom_scalar "$p95_query")"; rc=$?
case "$rc" in
  3) die_unreachable "p95 latency" ;;
  2)
    echo "gate: WARNING -- ${p95_query} returned no data even though ${sli_query} shows traffic; skipping the latency check this run."
    ;;
  *)
    if awk -v p="$p95_val" -v t="$GATE_MAX_P95_SECONDS" 'BEGIN{exit !(p > t)}'; then
      echo "gate: FAIL -- p95 latency ${p95_val}s exceeds GATE_MAX_P95_SECONDS=${GATE_MAX_P95_SECONDS}s" >&2
      status=1
    else
      echo "gate: OK   -- p95 latency ${p95_val}s is within GATE_MAX_P95_SECONDS=${GATE_MAX_P95_SECONDS}s"
    fi
    ;;
esac

if [ "$status" -eq 0 ]; then
  echo "gate: PASS -- all checks within threshold"
else
  echo "gate: FAIL -- see FAIL lines above" >&2
fi
exit "$status"
