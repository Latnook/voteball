#!/usr/bin/env bash
# Offline test for scripts/ci/argocd-verdict.sh, and for the way Jenkinsfile-cd's Verify stage calls
# it. Pure bash + grep: no cluster, no argocd, no jq (the jq extraction stays in the Jenkinsfile,
# where the `deploy` container has it; the DECISION is what lives in the script and is tested here).
#
# THE CASE THAT MATTERS is case 2: a Synced/Degraded read must come back as "not yet" (75), not as a
# failure. That is live application-cd #2 of 2026-10-06 -- `argocd app wait --health` had just
# returned Healthy, the backend HPA then reported FailedGetResourceMetric for the freshly rolled
# pods (no CPU sample exists for a pod's first ~15-30s), ArgoCD scored the HPA Degraded for exactly
# that window (13:06:01 -> 13:06:31), Verify sampled once at 13:06:03, failed, and rolled back a
# good release. The rollback build hit the same window forty seconds later and passed by luck.
set -uo pipefail

cd "$(dirname "$0")/../.."
SUT="$PWD/scripts/ci/argocd-verdict.sh"
JF="$PWD/Jenkinsfile-cd"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; pass=$((pass+1)); }

SHA="df715a9f0b5591f06325443fe6795952b7aaa4a0"
# run <sync> <health> <revision> [promote_sha]  -> sets $rc and $out
run() {
  out="$(SYNC_STATUS="$1" HEALTH="$2" REVISION="$3" PROMOTE_SHA="${4-$SHA}" bash "$SUT" 2>&1)"
  rc=$?
}

[ -f "$SUT" ] || fail "scripts/ci/argocd-verdict.sh does not exist"

# ---- 1. the happy path --------------------------------------------------------------------------
run Synced Healthy "$SHA"
[ "$rc" -eq 0 ] || fail "Synced/Healthy at the promoted revision must pass (got $rc): $out"
ok "Synced + Healthy passes"

# ---- 2. THE CD #2 REGRESSION: a Degraded read is 'not yet', not a failure ------------------------
run Synced Degraded "$SHA"
[ "$rc" -eq 75 ] || fail "THE CD #2 REGRESSION: Synced/Degraded must return 75 (retry), got $rc: $out"
grep -q "Degraded" <<<"$out" || fail "the not-yet message should name the health it saw: $out"
ok "Synced + Degraded returns 75 so the caller polls again"

# ---- 3. every other not-settled state is also 'not yet' ------------------------------------------
for h in Progressing Missing Suspended Unknown; do
  run Synced "$h" "$SHA"
  [ "$rc" -eq 75 ] || fail "Synced/$h must return 75, got $rc"
done
ok "Progressing / Missing / Suspended / Unknown health all return 75"

run OutOfSync Healthy "$SHA"
[ "$rc" -eq 75 ] || fail "OutOfSync/Healthy must return 75, got $rc: $out"
grep -q "OutOfSync" <<<"$out" || fail "the not-yet message should name the sync status it saw: $out"
ok "OutOfSync returns 75"

# ---- 4. an UNREADABLE verdict is a hard failure, never a retry ------------------------------------
# Build #7's failure mode: jq missing -> every value empty. That must not be mistaken for "not yet"
# and polled for two minutes, and it must never pass.
run "" Healthy "$SHA";  [ "$rc" -eq 1 ] || fail "empty sync status must exit 1, got $rc"
run Synced "" "$SHA";   [ "$rc" -eq 1 ] || fail "empty health must exit 1, got $rc"
run Synced Healthy "";  [ "$rc" -eq 1 ] || fail "empty revision must exit 1, got $rc"
ok "an empty sync status, health or revision exits 1 (hard failure)"

# ---- 5. a revision past the promoted one warns and still passes (I1, 2026-08-04) ------------------
run Synced Healthy "974f8114bccdf07fd37695fefd629cb70f1cc6f4"
[ "$rc" -eq 0 ] || fail "a later revision must not fail on its own (I1), got $rc: $out"
grep -q "WARNING" <<<"$out" || fail "a revision mismatch must be logged as a WARNING: $out"
ok "a revision mismatch is a WARNING, not a failure"

run Synced Healthy "$SHA" "df715a9"
[ "$rc" -eq 0 ] || fail "a short PROMOTE_SHA that prefixes the revision must pass, got $rc"
grep -q "WARNING" <<<"$out" && fail "a prefix match must not warn: $out"
ok "PROMOTE_SHA is matched as a prefix"

# ---- 6. Jenkinsfile-cd actually uses it, inside a BOUNDED loop ------------------------------------
grep -q "scripts/ci/argocd-verdict.sh" "$JF" || fail "Jenkinsfile-cd's Verify stage does not call argocd-verdict.sh"
ok "Jenkinsfile-cd calls argocd-verdict.sh"

# The single-sample check must be gone: if this line returns, Verify is back to deciding on one read.
if grep -qE '\[ "\$health" += "Healthy" \]' "$JF"; then
  fail "Jenkinsfile-cd still has the inline single-sample health check"
fi
ok "the inline single-sample health check is gone from Jenkinsfile-cd"

# An unbounded wait would turn a genuinely broken deploy into a build that never rolls back.
grep -qE 'attempt <= VERDICT_ATTEMPTS' "$JF" || fail "the Verify poll loop in Jenkinsfile-cd is not bounded by VERDICT_ATTEMPTS"
grep -qE 'VERDICT_ATTEMPTS *= *[0-9]+' "$JF" || fail "VERDICT_ATTEMPTS is not a literal number in Jenkinsfile-cd"
ok "the poll loop is bounded by a literal attempt count"

# 75 is the only status the loop may retry on; anything else must end it.
grep -qE 'verdict == 75' "$JF" || fail "the Verify loop does not key its retry on exit status 75"
ok "the loop retries only on 75"

echo "test-argocd-verdict: all $pass checks passed"
