#!/usr/bin/env bash
# Wait until an EXTERNAL client could deliver a webhook to Jenkins, then exit 0. Exit 1 on timeout.
#
# WHY THIS EXISTS. deploy.sh step 9 pushes values.yaml to master, and that push fires the repo's
# webhook. GitHub delivers a push event exactly once and NEVER retries it -- so if Jenkins is not
# reachable at that instant, the build for that commit never happens. Nothing reports it: the push
# succeeds, the deploy succeeds, and GitHub's delivery log is the only place the failure shows.
#
# Observed on the 2026-08-04 06:30 rebuild:
#   03:45:42Z  push  status=502  dur=0.05s  "failed to connect to host"
#   03:46:17Z  ping  status=200  dur=1.22s
# The push lost the race by 35 seconds and the delivery had to be replayed by hand.
#
# WHY IT RESOLVES THROUGH A PUBLIC RESOLVER. The first version of this script just curled the URL,
# which asks "can THIS MACHINE reach Jenkins" -- the wrong question. On the 2026-08-04 11:18 rebuild
# it timed out after a full 180s and warned, while GitHub delivered the very same push with
# status=200 in 1.44s. The deploying laptop's stub resolver was still holding the negative answer it
# cached while the record did not exist (teardown deletes it; Route53 pins negative caching at 15
# minutes), so curl got 000 and the check reported a failure that was purely local. Resolving through
# 1.1.1.1/8.8.8.8 and pinning that address with --resolve approximates what an outside sender sees,
# which is the only thing that actually matters here.
#
# WHAT COUNTS AS READY: HTTP 405. /github-webhook/ is POST-only, so a GET that actually reaches
# Jenkins is refused Method Not Allowed -- which proves DNS resolved, the ALB routed, and Jenkins
# answered. The two not-ready cases that matter are 000 (could not connect) and 502/503/504 (ALB up,
# no healthy target yet -- Jenkins still starting). A 401/403 would mean something is answering that
# is not the webhook endpoint; waiting will not fix that, so it is reported rather than retried into
# a hang.
#
# This does NOT verify the shared secret, and no status code can -- Jenkins answers a badly-signed
# webhook with 200 and silently discards it. See scripts/register-github-ci.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh
require_config

HOST="${WEBHOOK_HOST:-jenkins.${APP_DOMAIN}}"
URL="${WEBHOOK_URL:-https://${HOST}/github-webhook/}"
WAIT="${VOTEBALL_WEBHOOK_WAIT_SECS:-240}"
INTERVAL="${VOTEBALL_WEBHOOK_POLL_SECS:-5}"
RESOLVERS="${VOTEBALL_WEBHOOK_RESOLVERS:-1.1.1.1 8.8.8.8}"

# Public-resolver lookup, so a stale negative answer in this machine's cache cannot fail the check.
public_ip() {
  command -v dig >/dev/null 2>&1 || return 1
  local r ip
  for r in $RESOLVERS; do
    ip="$(dig +short +time=2 +tries=1 "@${r}" "$HOST" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# NOTE: no `|| echo 000` here. curl already prints 000 on a connection failure AND exits non-zero, so
# the fallback appended a second 000 and the script reported the nonsense code "000000" (seen in the
# 2026-08-04 11:18 deploy log). Swallow the exit status instead.
probe() {
  local ip="$1"
  if [ -n "$ip" ]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${HOST}:443:${ip}" "$URL" 2>/dev/null
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null
  fi
}

echo "==> Waiting up to ${WAIT}s for ${URL}"
code=""
ip=""
deadline=$((SECONDS + WAIT))
while :; do
  ip="$(public_ip || true)"
  code="$(probe "$ip")"
  [ "$code" = "405" ] && break
  [ "$SECONDS" -ge "$deadline" ] && break
  sleep "$INTERVAL"
done

if [ "$code" = "405" ]; then
  echo "    ready (405 = POST-only endpoint reached${ip:+ via ${ip}}: DNS, ALB and Jenkins all answering)"
  exit 0
fi

echo "    NOT ready after ${WAIT}s (last code: ${code:-none}${ip:+, resolved ${ip}})" >&2
[ -z "$ip" ] && echo "    ${HOST} did not resolve from ${RESOLVERS// /, } either -- external-dns may not have written the record yet." >&2
exit 1
