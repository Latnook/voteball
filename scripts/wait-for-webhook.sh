#!/usr/bin/env bash
# Wait until Jenkins can RECEIVE a GitHub webhook, then exit 0. Exit 1 on timeout.
#
# WHY THIS EXISTS. deploy.sh step 9 pushes values.yaml to master, and that push fires the repo's
# webhook. GitHub delivers a push event exactly once and NEVER retries it -- so if Jenkins is not
# reachable at that instant, the build for that commit simply never happens. Nothing reports it:
# the push succeeds, the deploy succeeds, GitHub's delivery log is the only place the failure shows.
#
# Observed on the 2026-08-04 06:30 rebuild:
#   03:45:42Z  push  status=502  dur=0.05s  "failed to connect to host"
#   03:46:17Z  ping  status=200  dur=1.22s
# The push lost the race by 35 seconds. The 00:22 rebuild the same night passed only because Jenkins
# happened to win it. Same shape as the deploy-key race that moved registration to step 3c: pushing
# to master before the thing that must react is ready. There, GitHub did not yet know the key; here,
# the ALB does not yet have a healthy target.
#
# WHAT COUNTS AS READY: HTTP 405. /github-webhook/ is POST-only, so a GET that actually reaches
# Jenkins is refused with Method Not Allowed -- which proves DNS resolved, the ALB routed, and
# Jenkins answered. Anything else is not ready, and the two that matter are:
#   000            curl could not connect at all (DNS, or nothing listening)
#   502/503/504    the ALB is up but has no healthy target yet -- Jenkins still starting
# A 401/403 would mean something is answering that is not the webhook endpoint; that is not "not
# ready yet" and waiting will not fix it, but it is reported rather than special-cased, because
# guessing at unfamiliar codes is how a wait loop turns into a hang.
#
# This does NOT verify the shared secret, and no status code can -- Jenkins answers a badly-signed
# webhook with 200 and silently discards it. See scripts/register-github-ci.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh
require_config

URL="${WEBHOOK_URL:-https://jenkins.${APP_DOMAIN}/github-webhook/}"
WAIT="${VOTEBALL_WEBHOOK_WAIT_SECS:-180}"
INTERVAL="${VOTEBALL_WEBHOOK_POLL_SECS:-5}"

echo "==> Waiting up to ${WAIT}s for ${URL}"
code=000
deadline=$((SECONDS + WAIT))
while :; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null || echo 000)"
  [ "$code" = "405" ] && break
  [ "$SECONDS" -ge "$deadline" ] && break
  sleep "$INTERVAL"
done

if [ "$code" = "405" ]; then
  echo "    ready (405 = POST-only endpoint reached: DNS, ALB and Jenkins all answering)"
  exit 0
fi

echo "    NOT ready after ${WAIT}s (last code: ${code})" >&2
exit 1
