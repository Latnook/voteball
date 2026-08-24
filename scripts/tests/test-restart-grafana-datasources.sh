#!/usr/bin/env bash
# Offline test for scripts/restart-grafana-datasources.sh. No cluster, no kubectl: every external
# command the script runs is injected through GRAFANA_*_CMD.
#
# The branch that matters most is #3: the Secret exists AND the running pod predates it, which is
# the ONLY case that should restart anything. Every other branch must leave Grafana alone --
# restarting it on a Spot cluster is nearly free but not literally free, and a restart on every
# routine re-run of deploy.sh is exactly the cargo-cult step this design forbids.
set -euo pipefail


# The waiter's budget is 180s in production (see wait_for_secret). Left at that, the "Secret never
# appears" cases below would each sit out the full three minutes and add ~3 min to every CI build.
# Zero here disables the wait; the one case that must actually exercise retrying sets its own budget.
export GRAFANA_WAIT_SECONDS=0
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

# --- the waiter itself: it must RETRY, not check once -------------------------------------------
# This is the case the 2026-08-25 rebuild needed and did not have. Step 11d ran moments after ArgoCD
# was bootstrapped, found no Secret, and gave up -- while the credential arrived about 90 seconds
# later. A single check is always too early on a fresh deploy, so "does it come back and look again"
# is the property worth pinning.
echo "--- wait_for_secret retries until the Secret appears ---"
_probe="$(mktemp)"; printf '0' > "$_probe"
# `env` is REQUIRED here. A `VAR=x out="$(cmd)"` prefix is NOT a temporary environment -- that form
# only exports for a COMMAND, and `out=...` is an assignment, so the stubs would never reach the
# script and it would silently run real kubectl against the live cluster (which is exactly what
# happened while writing this).
# The stub reports "absent" on the first two probes and "present" from the third, so the case can
# only pass by looking again.
out="$(env \
  GRAFANA_WAIT_SECONDS=20 \
  GRAFANA_GET_SECRET_CMD='n=$(cat '"$_probe"'); n=$((n+1)); printf %s "$n" > '"$_probe"'; [ "$n" -ge 3 ]' \
  GRAFANA_GET_DEPLOYMENT_CMD='true' \
  GRAFANA_ENV_CMD='echo notset' \
  GRAFANA_RESTART_CMD='echo restarted' \
  GRAFANA_ROLLOUT_STATUS_CMD='true' \
  bash scripts/restart-grafana-datasources.sh 2>&1)" || true
probes="$(cat "$_probe")"; rm -f "$_probe"
case "$out" in
  *"appeared after"*) echo "  ok   waited and found it on a later probe" ;;
  *) echo "  FAIL did not report waiting:"; echo "$out" | sed 's/^/       /'; exit 1 ;;
esac
[ "${probes:-0}" -ge 3 ] && echo "  ok   probed $probes times (proves it retried, did not check once)" \
                    || { echo "  FAIL only probed ${probes:-0} time(s)"; exit 1; }
