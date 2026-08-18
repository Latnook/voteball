#!/usr/bin/env bash
# Offline test for scripts/ci/monitoring-gate.sh. PROM_STUB_QUERY_CMD replaces the real curl call to
# Prometheus so no network call is made and every branch can be forced deterministically -- same
# stubbed-hook spirit as ARGOCD_STUB_STATUS_CMD in scripts/tests/test-argocd-sync-wait.sh and
# SMOKE_STUB_CURL in scripts/tests/test-smoke-test.sh.
#
# GATE_REQUESTS=0 skips traffic generation and GATE_WAIT_SECONDS=0 skips the scrape-interval sleep --
# neither is under test here; only the Prometheus-side decision logic is.
#
# THE CASE THAT MATTERS MOST: fewer than GATE_MIN_SAMPLES observed with every target up must PASS,
# with a warning. Anything failing after Promote in Jenkinsfile-cd rolls production back, so a gate
# that fails on thin data turns into an outage generator the first time the metrics pipeline is merely
# slow. Do not "fix" that test case if it looks wrong -- it is the one this whole script exists for.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Stub contract: called as `stub <promql>`, prints the Prometheus /api/v1/query JSON body, exits
# non-zero to signal a transport failure. Mirrors the real curl call in prom_query_raw().
vec() { printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1700000000,"%s"]}]}}' "$1"; }
ABSENT='{"status":"success","data":{"resultType":"vector","result":[]}}'

# All healthy: targets up, plenty of samples, error ratio and p95 both comfortably under threshold.
cat > "$work/healthy" <<STUB
#!/usr/bin/env bash
case "\$1" in
  *'up{namespace='*)  printf '%s' '$(vec 1)' ;;
  *journey_requests*) printf '%s' '$(vec 0.2)' ;;   # 0.2/s * 300s = 60 samples, above GATE_MIN_SAMPLES=20
  *availability*)     printf '%s' '$(vec 0.999)' ;; # error ratio 0.001, under 0.01
  *latency*)          printf '%s' '$(vec 0.3)' ;;   # under 1.0s
esac
STUB

# A target down. Everything else stays healthy so this test proves the targets-up check alone fails
# the release, not a side effect of some other threshold.
cat > "$work/target_down" <<STUB
#!/usr/bin/env bash
case "\$1" in
  *'up{namespace='*)  printf '%s' '$(vec 0)' ;;
  *journey_requests*) printf '%s' '$(vec 0.2)' ;;
  *availability*)     printf '%s' '$(vec 0.999)' ;;
  *latency*)          printf '%s' '$(vec 0.3)' ;;
esac
STUB

# Error ratio over threshold: availability 0.95 -> error ratio 0.05, well past GATE_MAX_ERROR_RATIO
# (0.01). Targets up and samples sufficient so only this check can be responsible for the failure.
cat > "$work/bad_errors" <<STUB
#!/usr/bin/env bash
case "\$1" in
  *'up{namespace='*)  printf '%s' '$(vec 1)' ;;
  *journey_requests*) printf '%s' '$(vec 0.2)' ;;
  *availability*)     printf '%s' '$(vec 0.95)' ;;
  *latency*)          printf '%s' '$(vec 0.3)' ;;
esac
STUB

# p95 over threshold (1.5s > GATE_MAX_P95_SECONDS=1.0), everything else healthy.
cat > "$work/bad_latency" <<STUB
#!/usr/bin/env bash
case "\$1" in
  *'up{namespace='*)  printf '%s' '$(vec 1)' ;;
  *journey_requests*) printf '%s' '$(vec 0.2)' ;;
  *availability*)     printf '%s' '$(vec 0.999)' ;;
  *latency*)          printf '%s' '$(vec 1.5)' ;;
esac
STUB

# Fewer than GATE_MIN_SAMPLES (20) observed -- 0.03/s * 300s = 9 samples -- but every target is up.
# THE load-bearing case: must PASS, with a warning, never fail.
cat > "$work/thin_data" <<STUB
#!/usr/bin/env bash
case "\$1" in
  *'up{namespace='*)  printf '%s' '$(vec 1)' ;;
  *journey_requests*) printf '%s' '$(vec 0.03)' ;;
  *availability*)     printf '%s' '$(vec 1)' ;;
  *latency*)          printf '%s' '$(vec 0.1)' ;;
esac
STUB

# Prometheus unreachable: every query transport-fails. This must FAIL, loudly, and distinctly from
# "insufficient data" -- a broken gate cannot vouch for the release either way.
cat > "$work/unreachable" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB

# The SLI itself is absent -- no series at all for voteball:journey_requests:rate5m, even though the
# targets are up. This is the condition VoteballSLIAbsent pages on: the measurement pipeline is
# broken, not merely quiet. Must FAIL, with a message distinct from the thin-data warning above.
cat > "$work/sli_absent" <<STUB
#!/usr/bin/env bash
case "\$1" in
  *'up{namespace='*)  printf '%s' '$(vec 1)' ;;
  *journey_requests*) printf '%s' '$ABSENT' ;;
  *availability*)     printf '%s' '$(vec 1)' ;;
  *latency*)          printf '%s' '$(vec 0.1)' ;;
esac
STUB

chmod +x "$work"/healthy "$work"/target_down "$work"/bad_errors "$work"/bad_latency \
  "$work"/thin_data "$work"/unreachable "$work"/sli_absent

run() {
  # run <stub-file>  -- prints combined stdout+stderr, sets $out and $rc.
  out="$(GATE_BASE_URL=https://example.test GATE_REQUESTS=0 GATE_WAIT_SECONDS=0 \
    PROM_STUB_QUERY_CMD="$work/$1" "$ROOT/scripts/ci/monitoring-gate.sh" 2>&1)"
  rc=$?
}

echo "--- all healthy passes ---"
run healthy
[ "$rc" -eq 0 ] || fail "a fully healthy release must exit 0, got $rc: $out"
grep -q 'PASS -- all checks within threshold' <<<"$out" || fail "expected the all-clear PASS message: $out"
ok "all healthy -> exit 0 with the all-clear message"

echo "--- a target down fails ---"
run target_down
[ "$rc" -ne 0 ] || fail "a down scrape target must fail the gate"
grep -qi 'scrape target.*devops-app.*up==0\|FAIL.*scrape target' <<<"$out" \
  || fail "expected a message naming the down target, got: $out"
ok "a down target -> non-zero exit, names the target"

echo "--- error ratio over threshold fails ---"
run bad_errors
[ "$rc" -ne 0 ] || fail "an error ratio over GATE_MAX_ERROR_RATIO must fail the gate"
grep -qi 'error ratio.*exceeds' <<<"$out" || fail "expected an error-ratio message, got: $out"
ok "error ratio over threshold -> non-zero exit, names the reason"

echo "--- p95 over threshold fails ---"
run bad_latency
[ "$rc" -ne 0 ] || fail "a p95 over GATE_MAX_P95_SECONDS must fail the gate"
grep -qi 'p95 latency.*exceeds' <<<"$out" || fail "expected a p95 message, got: $out"
ok "p95 over threshold -> non-zero exit, names the reason"

echo "--- fewer than GATE_MIN_SAMPLES with targets up: PASSES with a warning ---"
run thin_data
[ "$rc" -eq 0 ] || fail "thin data with every target up MUST pass (this is the load-bearing case), got $rc: $out"
grep -qi 'WARNING' <<<"$out" || fail "thin data must still warn loudly, got: $out"
grep -qi 'PASS (with warning)' <<<"$out" || fail "expected the explicit pass-with-warning message, got: $out"
ok "thin data + targets up -> exit 0, with a warning (never a failure)"

echo "--- Prometheus unreachable fails, distinctly from insufficient data ---"
run unreachable
[ "$rc" -ne 0 ] || fail "an unreachable Prometheus must fail the gate"
grep -qi 'BROKEN GATE' <<<"$out" || fail "expected the broken-gate message, got: $out"
grep -qi 'not insufficient data' <<<"$out" || fail "expected the message to explicitly distinguish this from insufficient data, got: $out"
ok "unreachable Prometheus -> non-zero exit, explicitly NOT treated as insufficient data"

echo "--- the SLI itself being absent fails distinctly from thin data ---"
run sli_absent
[ "$rc" -ne 0 ] || fail "an absent SLI must fail the gate, not pass with a warning"
grep -qi 'ABSENT' <<<"$out" || fail "expected the ABSENT message, got: $out"
grep -qi 'VoteballSLIAbsent' <<<"$out" || fail "expected the message to tie this to the VoteballSLIAbsent alert, got: $out"
ok "absent SLI -> non-zero exit, distinct message (not folded into the thin-data warning)"

echo "--- GATE_SETTLE_SECONDS: defaults to no wait, and announces itself when set ---"
# REGRESSION TEST for the CD #26/#27 incident of 2026-08-18: the rollback of a slow release failed its
# OWN gate at p95 2.33s while production was already serving 0.12s, because every SLI here is a rate
# over [5m] and that window still contained the incident the rollback was undoing. rollback-target.sh
# had already resolved the next target as the SLOW build; only ROLLBACK_DEPTH stopped production
# oscillating. Jenkinsfile-cd now sets GATE_SETTLE_SECONDS=330 when ROLLBACK_DEPTH > 0.
#
# What is asserted here is the CONTRACT, not the sleep: unset/0 must not wait (or every normal deploy
# silently gets 5 minutes slower), and a set value must be announced in the log (or a 5-minute stall
# looks like a hung stage to whoever is watching an incident).
out="$(GATE_BASE_URL=https://example.test GATE_REQUESTS=0 GATE_WAIT_SECONDS=0 \
  PROM_STUB_QUERY_CMD="$work/healthy" "$ROOT/scripts/ci/monitoring-gate.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "the healthy case must still pass with GATE_SETTLE_SECONDS unset, got: $out"
grep -qi 'Settling' <<<"$out" && fail "GATE_SETTLE_SECONDS must default to 0 -- a normal deploy must not wait. Got: $out"
ok "unset -> no settle wait on a normal deploy"

start=$(date +%s)
out="$(GATE_BASE_URL=https://example.test GATE_REQUESTS=0 GATE_WAIT_SECONDS=0 GATE_SETTLE_SECONDS=2 \
  PROM_STUB_QUERY_CMD="$work/healthy" "$ROOT/scripts/ci/monitoring-gate.sh" 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 0 ] || fail "a settling run must still pass on healthy metrics, got: $out"
grep -qi 'Settling 2s' <<<"$out" || fail "the settle wait must announce itself, or it reads as a hung stage. Got: $out"
[ "$elapsed" -ge 2 ] || fail "GATE_SETTLE_SECONDS=2 should have waited at least 2s, waited ${elapsed}s"
ok "set -> waits, and says why (${elapsed}s)"

echo "--- Jenkinsfile-cd only settles on a rollback ---"
# The wiring is as load-bearing as the flag: settling on EVERY deploy would pay 5 minutes to fix a case
# that only arises after a failed one, and settling on NONE leaves the incident above unfixed.
grep -q 'GATE_SETTLE_SECONDS' "$ROOT/Jenkinsfile-cd" \
  || fail "Jenkinsfile-cd no longer passes GATE_SETTLE_SECONDS -- the rollback fix is disarmed"
grep -q "ROLLBACK_DEPTH ?: '0').toInteger() > 0 ? '330' : '0'" "$ROOT/Jenkinsfile-cd" \
  || fail "Jenkinsfile-cd must gate the settle on ROLLBACK_DEPTH > 0 (330s = 300s rate window + one 30s scrape)"
ok "Jenkinsfile-cd settles only when ROLLBACK_DEPTH > 0"

echo "--- a missing GATE_BASE_URL fails loudly ---"
out="$(GATE_REQUESTS=0 GATE_WAIT_SECONDS=0 PROM_STUB_QUERY_CMD="$work/healthy" \
  "$ROOT/scripts/ci/monitoring-gate.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "missing GATE_BASE_URL must fail"
ok "missing GATE_BASE_URL -> non-zero exit"

echo "ALL TESTS PASSED"
