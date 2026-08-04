#!/usr/bin/env bash
# Tests scripts/wait-for-webhook.sh. Both branches run in seconds via WEBHOOK_URL +
# VOTEBALL_WEBHOOK_WAIT_SECS, so this needs NO cluster and NO deploy -- same offline-stub spirit as
# test-ci-guards.sh and test-sync-values.sh.
#
# What it is guarding: deploy.sh pushes to master at step 9, GitHub fires the webhook exactly once
# and never retries a failed push delivery. If this wait regresses to "always returns 0", the push
# goes out before Jenkins can answer and the build silently never happens -- which is what occurred
# on the 2026-08-04 06:30 rebuild (502 in 0.05s; the same endpoint answered 200 thirty-five seconds
# later). The failure is invisible from the deploy's side, which is why it needs a test rather than
# an eyeball.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }

# ---- not-ready branch: nothing listening -------------------------------------------------------
# Port 1 on loopback refuses instantly, so curl returns 000 -- the "could not connect" case, which
# is what a not-yet-provisioned ALB target looks like from GitHub's side.
start=$SECONDS
WEBHOOK_URL="http://127.0.0.1:1/github-webhook/" VOTEBALL_WEBHOOK_WAIT_SECS=3 VOTEBALL_WEBHOOK_POLL_SECS=1 \
  ./scripts/wait-for-webhook.sh >/dev/null 2>&1 \
  && fail "an unreachable endpoint must exit non-zero"
took=$((SECONDS - start))
ok "unreachable endpoint fails (exit 1)"
[ "$took" -le 20 ] || fail "should have given up in ~3s, took ${took}s"
ok "honours VOTEBALL_WEBHOOK_WAIT_SECS instead of hanging (${took}s)"

# ---- ready branch: something answers 405 -------------------------------------------------------
# A one-shot netcat serving a 405, so "ready" is proved by the real code path rather than asserted.
if command -v nc >/dev/null 2>&1; then
  PORT=18099
  printf 'HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' \
    | timeout 25 nc -l -p "$PORT" -q 1 >/dev/null 2>&1 &
  nc_pid=$!
  sleep 1
  if WEBHOOK_URL="http://127.0.0.1:${PORT}/github-webhook/" VOTEBALL_WEBHOOK_WAIT_SECS=10 \
       VOTEBALL_WEBHOOK_POLL_SECS=1 ./scripts/wait-for-webhook.sh >/dev/null 2>&1; then
    ok "405 is treated as ready (exit 0)"
  else
    fail "a 405 response must be treated as ready"
  fi
  kill "$nc_pid" 2>/dev/null
  wait "$nc_pid" 2>/dev/null
else
  echo "  skip: nc unavailable, cannot serve the 405 branch"
fi

# ---- deploy.sh must actually call it, and must not treat failure as fatal ----------------------
grep -q 'wait-for-webhook\.sh' scripts/deploy.sh \
  || fail "deploy.sh no longer calls wait-for-webhook.sh -- the race is back"
ok "deploy.sh calls the wait before pushing"

# The call must sit BETWEEN the commit and the push. Before the commit there is nothing to push
# yet; after the push the wait is pointless, which is precisely the bug it exists to prevent.
commit_ln="$(grep -n 'git commit -m "Deploy: sync values.yaml' scripts/deploy.sh | cut -d: -f1)"
wait_ln="$(grep -n 'wait-for-webhook\.sh' scripts/deploy.sh | head -1 | cut -d: -f1)"
push_ln="$(grep -n 'elif ! git push; then' scripts/deploy.sh | cut -d: -f1)"
[ -n "$commit_ln" ] && [ -n "$wait_ln" ] && [ -n "$push_ln" ] || fail "could not locate commit/wait/push in deploy.sh"
[ "$commit_ln" -lt "$wait_ln" ] && [ "$wait_ln" -lt "$push_ln" ] \
  || fail "the wait must be between the commit (${commit_ln}) and the push (${push_ln}), got ${wait_ln}"
ok "the wait runs after the commit and before the push"

grep -q 'if ! ./scripts/wait-for-webhook.sh; then' scripts/deploy.sh \
  || fail "the wait must be non-fatal -- a hard failure would skip the push and leave master stale"
ok "a failed wait warns and still pushes"

echo "PASS: $pass assertions"
