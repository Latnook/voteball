#!/usr/bin/env bash
# Wait until ArgoCD has reconciled a SPECIFIC commit and reports Synced/Healthy. Exit 1 on timeout.
#
# WHY THIS EXISTS. deploy.sh step 10 used to run `helm upgrade` unconditionally. On a fresh cluster
# that is right -- the ArgoCD Application does not exist until step 11, so Helm is the only applier
# and there is nothing to collide with. On a cluster that ALREADY has ArgoCD, it is wrong, and
# guaranteed-wrong rather than occasionally so:
#
#   UPGRADE FAILED: conflict occurred while applying object devops-app/backend apps/v1,
#   Kind=Deployment: Apply failed with 1 conflict: conflict with "argocd-controller":
#   .spec.template.spec.containers[name="backend"].image
#
# Helm 4 applies server-side, and server-side apply grants two managers co-ownership of a field only
# while they apply the SAME value. Step 9 pushes a NEW image tag to master and step 10 immediately
# applies it, while ArgoCD -- which has not reconciled that commit yet -- still owns `.image` at the
# PREVIOUS tag. Steps 9->10 exist precisely to change that tag, so the values can never match and
# the conflict fires on every re-run. (Observed 2026-08-10; all three Deployments plus the backup
# CronJob.) Helm 3 hid this for years by patching client-side, which never consults field ownership.
#
# WHY NOT `--force-conflicts`. It resolves the conflict by tearing ownership away from ArgoCD, which
# is the single thing this repo's delivery model forbids: ArgoCD is the only applier, and the one
# drift GitOps cannot self-correct is a human applying something git does not describe. The real
# answer is that Helm has no business applying at all once ArgoCD owns the release -- ArgoCD
# reconciles the commit step 9 just pushed and rolls the images out itself. On the run that exposed
# this it had already finished doing so before the Helm failure was even read.
#
# WHY A NUDGE AND NOT JUST A WAIT. ArgoCD polls its source on a timer (3 minutes by default), so a
# plain wait would idle for up to that long after a push that has already landed. Annotating the
# Application with `argocd.argoproj.io/refresh=normal` asks it to look now. The annotation is a
# request, not a guarantee, which is why the poll below is still the thing that decides.
#
# WHY IT CHECKS THE REVISION AND NOT JUST "Synced". An Application that has not yet noticed the new
# commit reports Synced/Healthy -- truthfully, about the OLD commit. Accepting that would declare a
# deploy finished while the images it just built were still unreferenced, which is precisely the
# failure this is here to catch. Synced/Healthy AT THE TARGET SHA is the only useful condition.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP="${ARGOCD_APP:-voteball}"
NS="${ARGOCD_APP_NAMESPACE:-argocd}"
WAIT="${VOTEBALL_ARGOCD_WAIT_SECS:-300}"
INTERVAL="${VOTEBALL_ARGOCD_POLL_SECS:-5}"
TARGET="${1:-$(git rev-parse HEAD 2>/dev/null)}"

if [ -z "$TARGET" ]; then
  echo "ERROR: no target revision given, and 'git rev-parse HEAD' produced nothing." >&2
  exit 2
fi

# Both cluster calls are indirected through a stub hook so the poll/timeout logic can be tested
# offline -- same reason scripts/ci/should-skip-build.sh takes CI_STUB_DESCRIBE_CMD. A wait that can
# only be exercised by running a real 15-minute billed deploy is a wait that goes untested until it
# fails in production.
refresh() {
  if [ -n "${ARGOCD_STUB_REFRESH_CMD:-}" ]; then eval "$ARGOCD_STUB_REFRESH_CMD"; return; fi
  kubectl annotate application "$APP" -n "$NS" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1
}

# Prints one line: "<sync.revision> <sync.status> <health.status>"
status() {
  if [ -n "${ARGOCD_STUB_STATUS_CMD:-}" ]; then eval "$ARGOCD_STUB_STATUS_CMD"; return; fi
  kubectl get application "$APP" -n "$NS" \
    -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status}' 2>/dev/null
}

echo "==> Waiting up to ${WAIT}s for ArgoCD to reconcile ${TARGET:0:7} (application ${NS}/${APP})"
refresh || true

rev=""; sync=""; health=""
deadline=$((SECONDS + WAIT))
while :; do
  read -r rev sync health <<<"$(status || true)"
  if [ "$rev" = "$TARGET" ] && [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    echo "    synced: ArgoCD is on ${TARGET:0:7} and reports Synced/Healthy"
    exit 0
  fi
  [ "$SECONDS" -ge "$deadline" ] && break
  sleep "$INTERVAL"
done

echo "    NOT synced after ${WAIT}s (last seen: rev=${rev:0:7} sync=${sync:-none} health=${health:-none})" >&2
if [ -n "$rev" ] && [ "$rev" != "$TARGET" ]; then
  echo "    ArgoCD is still on ${rev:0:7}. It deploys what is on master, not what is on this disk --" >&2
  echo "    if ${TARGET:0:7} was never pushed, push it and re-run this script." >&2
fi
exit 1
