#!/usr/bin/env bash
# CD Verify -- decide what ONE read of ArgoCD's verdict means: pass, not yet, or unreadable.
#
# WHY THIS EXISTS. Verify used to read ArgoCD's health once and fail on anything but Healthy. Live
# application-cd #2, 2026-10-06: the Rollout stage's `argocd app wait --health` returned Healthy at
# 13:05:59, the backend HPA then reported FailedGetResourceMetric for the pods it had just been
# given (a new pod has no CPU sample for its first ~15-30s), ArgoCD scores an HPA in that state
# Degraded, the Application went Degraded at 13:06:01 and Healthy again at 13:06:31, and Verify
# sampled at 13:06:03. A good release was rolled back. The rollback build crossed the same window
# (13:07:46 -> 13:08:01) and passed only because its read landed outside it. Every deploy that
# replaces the backend pods opens that window, so the stage failed by timing, not by cause.
#
# A single sample cannot tell "settling" from "broken"; only time can. So this script answers one
# read, and Jenkinsfile-cd's Verify stage calls it in a BOUNDED loop: 75 means read again, and a
# deploy that is still not Synced/Healthy when the attempts run out fails exactly as before.
#
# WHY THE VALUES ARRIVE AS ENVIRONMENT, NOT AS A JSON FILE. jq exists in the CD pod's `deploy`
# container and not in the python:3.12-slim container the script tests run in. Keeping the three
# jq reads in the Jenkinsfile and the DECISION here is what lets scripts/tests/test-argocd-verdict.sh
# run offline with no jq and no stub standing in for one.
#
# Usage:  SYNC_STATUS=<s> HEALTH=<h> REVISION=<sha> PROMOTE_SHA=<sha> argocd-verdict.sh
# Exit:   0   Synced and Healthy
#         75  read fine, not Synced/Healthy yet -- the caller should wait and read again
#         1   a value is empty: ArgoCD's verdict could not be read at all (never retried -- this is
#             build #7's failure mode, jq missing, and it must not be polled or mistaken for a pass)
set -uo pipefail

SYNC_STATUS="${SYNC_STATUS-}"
HEALTH="${HEALTH-}"
REVISION="${REVISION-}"
PROMOTE_SHA="${PROMOTE_SHA-}"

echo "sync=$SYNC_STATUS health=$HEALTH revision=$REVISION"

[ -n "$SYNC_STATUS" ] || { echo "sync_status is empty/missing -- could not read ArgoCD's verdict from app-status.json" >&2; exit 1; }
[ -n "$HEALTH" ]      || { echo "health is empty/missing -- could not read ArgoCD's verdict from app-status.json" >&2; exit 1; }
[ -n "$REVISION" ]    || { echo "revision is empty/missing -- could not read ArgoCD's verdict from app-status.json" >&2; exit 1; }

if [ "$SYNC_STATUS" != "Synced" ]; then
  echo "ArgoCD reports $SYNC_STATUS -- not settled yet." >&2
  exit 75
fi
if [ "$HEALTH" != "Healthy" ]; then
  echo "ArgoCD reports $HEALTH -- not settled yet." >&2
  exit 75
fi

# Deliberately a WARNING and not a failure (I1, fixed 2026-08-04): the Application auto-syncs, so a
# push to master during this build legitimately moves sync.revision past this build's own commit.
# What decides pass/fail on WHICH release is running is verify-deployed-image.sh, the next step.
case "$REVISION" in
  "$PROMOTE_SHA"*) ;;
  *) echo "WARNING: ArgoCD synced $REVISION, not the promoted $PROMOTE_SHA -- a later" >&2
     echo "push to master (auto-synced by ArgoCD while this build was running) has" >&2
     echo "moved the app past this deploy's own commit. NOT failing on this alone: the" >&2
     echo "next check confirms whether the RUNNING images actually match this build." >&2
     ;;
esac
exit 0
