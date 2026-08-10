#!/usr/bin/env bash
# Tests scripts/wait-for-argocd-sync.sh. Every branch runs in seconds via ARGOCD_STUB_STATUS_CMD +
# VOTEBALL_ARGOCD_WAIT_SECS, so this needs NO cluster and NO deploy -- same offline-stub spirit as
# test-webhook-wait.sh and test-ci-guards.sh.
#
# What it is guarding: deploy.sh step 10 hands the apply to ArgoCD whenever ArgoCD already manages
# the release, because a `helm upgrade` there conflicts with argocd-controller over the image field
# on every single re-run (see the header of the script under test). This wait is the only thing that
# then decides whether the deploy actually shipped. Two ways it could regress are both silent:
#
#   * "always returns 0" -- the deploy reports success while the images step 8 just built are still
#     unreferenced by anything running.
#   * "accepts Synced/Healthy at ANY revision" -- same outcome, because an Application that has not
#     noticed the new commit yet reports Synced/Healthy quite truthfully about the OLD one.
#
# Neither is visible from the deploy's own output, which is why they need a test and not an eyeball.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SCRIPT=./scripts/wait-for-argocd-sync.sh
TARGET=1111111111111111111111111111111111111111
STALE=2222222222222222222222222222222222222222

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ok: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The refresh annotation is stubbed out everywhere below: it is a `kubectl annotate` against a real
# cluster, and it is deliberately best-effort in the script (a failed nudge just means waiting for
# ArgoCD's own poll), so it must never be what decides the outcome.
export ARGOCD_STUB_REFRESH_CMD='true'
export VOTEBALL_ARGOCD_POLL_SECS=1

# ---- the happy path: already reconciled at the target -------------------------------------------
out="$(ARGOCD_STUB_STATUS_CMD="echo '$TARGET Synced Healthy'" \
  VOTEBALL_ARGOCD_WAIT_SECS=3 "$SCRIPT" "$TARGET" 2>&1)" \
  || fail "Synced/Healthy at the target revision must exit 0"
grep -q 'synced' <<<"$out" || fail "expected a success line, got: $out"
ok "Synced/Healthy at the target revision exits 0"

# ---- the regression that matters most: right status, WRONG commit -------------------------------
# This is the one a naive implementation gets wrong. ArgoCD is perfectly healthy -- just not on the
# commit this deploy built. Accepting it would green-light a deploy that shipped nothing.
start=$SECONDS
out="$(ARGOCD_STUB_STATUS_CMD="echo '$STALE Synced Healthy'" \
  VOTEBALL_ARGOCD_WAIT_SECS=3 "$SCRIPT" "$TARGET" 2>&1)" \
  && fail "Synced/Healthy at the WRONG revision must NOT be treated as success"
took=$((SECONDS - start))
ok "Synced/Healthy at a stale revision fails (exit 1)"
grep -q "${STALE:0:7}" <<<"$out" || fail "the failure must name the revision ArgoCD is stuck on: $out"
ok "names the stale revision so the cause is obvious"
grep -qi 'master' <<<"$out" || fail "expected the 'deploys master, not this disk' hint: $out"
ok "hints that an unpushed commit is the usual cause"
[ "$took" -le 20 ] || fail "should have given up in ~3s, took ${took}s"
ok "honours VOTEBALL_ARGOCD_WAIT_SECS instead of hanging (${took}s)"

# ---- right commit, but not healthy --------------------------------------------------------------
out="$(ARGOCD_STUB_STATUS_CMD="echo '$TARGET Synced Degraded'" \
  VOTEBALL_ARGOCD_WAIT_SECS=3 "$SCRIPT" "$TARGET" 2>&1)" \
  && fail "a Degraded application must not be reported as a finished deploy"
ok "Degraded health fails even at the correct revision"

out="$(ARGOCD_STUB_STATUS_CMD="echo '$TARGET OutOfSync Healthy'" \
  VOTEBALL_ARGOCD_WAIT_SECS=3 "$SCRIPT" "$TARGET" 2>&1)" \
  && fail "an OutOfSync application must not be reported as a finished deploy"
ok "OutOfSync fails even at the correct revision"

# ---- it actually POLLS, rather than deciding once -----------------------------------------------
# ArgoCD is mid-reconciliation for the first two reads and converges on the third. A script that
# sampled once and gave up would fail this; so would one that never re-read.
counter="$work/n"
printf '0' > "$counter"
poll_stub="n=\$(cat '$counter'); n=\$((n+1)); printf '%s' \"\$n\" > '$counter';
  if [ \"\$n\" -ge 3 ]; then echo '$TARGET Synced Healthy'; else echo '$STALE OutOfSync Progressing'; fi"
out="$(ARGOCD_STUB_STATUS_CMD="$poll_stub" VOTEBALL_ARGOCD_WAIT_SECS=30 "$SCRIPT" "$TARGET" 2>&1)" \
  || fail "should have succeeded once the stub converged: $out"
[ "$(cat "$counter")" -ge 3 ] || fail "expected at least 3 polls, saw $(cat "$counter")"
ok "polls until it converges rather than sampling once ($(cat "$counter") reads)"

# ---- an empty status (application missing / kubectl failing) is a timeout, not a crash ----------
out="$(ARGOCD_STUB_STATUS_CMD="echo ''" VOTEBALL_ARGOCD_WAIT_SECS=2 "$SCRIPT" "$TARGET" 2>&1)" \
  && fail "an unreadable application must exit non-zero"
grep -q 'none' <<<"$out" || fail "expected 'none' placeholders for the empty read: $out"
ok "an empty/unreadable status times out cleanly instead of crashing under set -u"

# ---- a missing target revision is a usage error, not a 300-second wait ---------------------------
( unset ARGOCD_STUB_STATUS_CMD
  ARGOCD_STUB_STATUS_CMD="echo ''" VOTEBALL_ARGOCD_WAIT_SECS=2 "$SCRIPT" "" >/dev/null 2>&1 )
[ "$?" -ne 0 ] || fail "an empty target revision must not be accepted"
ok "an empty target revision is rejected"

echo "ALL TESTS PASSED"
