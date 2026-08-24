#!/usr/bin/env bash
# Offline test for scripts/restart-grafana-datasources.sh. No cluster, no kubectl: every external
# command the script runs is injected through GRAFANA_*_CMD.
#
# The branch that matters most is #3: the Secret exists AND the running pod predates it, which is
# the ONLY case that should restart anything. Every other branch must leave Grafana alone --
# restarting it on a Spot cluster is nearly free but not literally free, and a restart on every
# routine re-run of deploy.sh is exactly the cargo-cult step this design forbids.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT_UNDER_TEST=scripts/restart-grafana-datasources.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ok   $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*" >&2; fail=$((fail+1)); }

run() { # runs the script with the given stubs, capturing output and rc
  set +e
  OUT="$(env "$@" bash "$SCRIPT_UNDER_TEST" 2>&1)"
  RC=$?
  set -e
}

echo "1. Secret does not exist yet -> skip, exit 0, no restart"
run GRAFANA_GET_SECRET_CMD='exit 1' \
    GRAFANA_GET_DEPLOYMENT_CMD='true' \
    GRAFANA_CHECK_ENV_CMD='echo set' \
    GRAFANA_RESTART_CMD="touch $TMP/restarted-1" \
    GRAFANA_ROLLOUT_STATUS_CMD='true'
[ "$RC" = 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $OUT"
[ -e "$TMP/restarted-1" ] && bad "restarted Grafana with no Secret present" || ok "no restart"
grep -qi "nothing to project" <<<"$OUT" && ok "explains why it skipped" || bad "no explanation: $OUT"

echo "2. Secret exists but Grafana isn't deployed yet -> skip, exit 0, no restart"
run GRAFANA_GET_SECRET_CMD='true' \
    GRAFANA_GET_DEPLOYMENT_CMD='exit 1' \
    GRAFANA_CHECK_ENV_CMD='echo set' \
    GRAFANA_RESTART_CMD="touch $TMP/restarted-2" \
    GRAFANA_ROLLOUT_STATUS_CMD='true'
[ "$RC" = 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $OUT"
[ -e "$TMP/restarted-2" ] && bad "restarted Grafana with no deployment present" || ok "no restart"

echo "3. Secret exists, deployment exists, already projected -> skip, exit 0, no restart"
run GRAFANA_GET_SECRET_CMD='true' \
    GRAFANA_GET_DEPLOYMENT_CMD='true' \
    GRAFANA_CHECK_ENV_CMD='echo set' \
    GRAFANA_RESTART_CMD="touch $TMP/restarted-3" \
    GRAFANA_ROLLOUT_STATUS_CMD='true'
[ "$RC" = 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $OUT"
[ -e "$TMP/restarted-3" ] && bad "restarted Grafana when the env var was already projected" || ok "no restart"
grep -qi "already projected" <<<"$OUT" && ok "says why it skipped" || bad "no explanation: $OUT"

echo "4. Secret exists, deployment exists, NOT yet projected -> restart, verify, exit 0"
run GRAFANA_GET_SECRET_CMD='true' \
    GRAFANA_GET_DEPLOYMENT_CMD='true' \
    GRAFANA_CHECK_ENV_CMD="if [ -e $TMP/restarted-4 ]; then echo set; fi" \
    GRAFANA_RESTART_CMD="touch $TMP/restarted-4" \
    GRAFANA_ROLLOUT_STATUS_CMD='true'
[ "$RC" = 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $OUT"
[ -e "$TMP/restarted-4" ] && ok "restarted Grafana" || bad "did not restart despite an unprojected env var"
grep -qi "verified" <<<"$OUT" && ok "confirms the projection landed" || bad "did not verify: $OUT"

echo "5. restart happens but the var is STILL unset afterwards -> warn, exit 1 (non-fatal to the caller)"
run GRAFANA_GET_SECRET_CMD='true' \
    GRAFANA_GET_DEPLOYMENT_CMD='true' \
    GRAFANA_CHECK_ENV_CMD='true' \
    GRAFANA_RESTART_CMD="touch $TMP/restarted-5" \
    GRAFANA_ROLLOUT_STATUS_CMD='true'
[ "$RC" = 1 ] && ok "exit 1" || bad "expected exit 1, got $RC: $OUT"
[ -e "$TMP/restarted-5" ] && ok "still attempted the restart" || bad "never restarted"
grep -qi "still not set" <<<"$OUT" && ok "says the verification failed" || bad "no failure explanation: $OUT"

echo
if [ "$fail" -gt 0 ]; then echo "FAIL — $fail of $((pass+fail)) checks failed" >&2; exit 1; fi
echo "PASS — all $pass checks green"
