#!/usr/bin/env bash
# Capture the submission evidence from the LIVE cluster into docs/eks/evidence/<date>-*.txt.
#
# Why this is a script and not a list of commands in a doc: the evidence has to be re-captured after
# every destroy/rebuild (every pod name, ALB hostname and certificate is new), and hand-running
# fifteen commands drifts -- the 2026-07-27 set was captured by hand and by 2026-08-03 no longer
# showed the `ci` namespace or the 1.36 control plane. Re-running this is the cheap path.
#
# Captured evidence is DATED and never edited afterwards. A value in an old file that no longer
# resolves is the file working as intended; capture a new set rather than "correcting" an old one.
#
# Usage:
#   ./scripts/capture-evidence.sh                 # everything, including the pod-restart demo
#   ./scripts/capture-evidence.sh --no-restart    # skip the pod-restart demo (it deletes a pod)
#   ./scripts/capture-evidence.sh --label pre-teardown   # suffix the filenames
#
# The pod-restart demo deliberately deletes one frontend replica. Two replicas plus a
# PodDisruptionBudget are what make that invisible to users -- that IS the demo. It is the only
# mutating action here, and it is skippable.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib/config.sh
require_config

NS=devops-app
OUT_DIR=docs/eks/evidence
DATE="$(date +%F)"
LABEL=""
DO_RESTART=1
DO_STATIC=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) DO_RESTART=0 ;;
    # For re-taking just the pod-restart poll -- the one part with a plausible reason to be redone
    # on its own (a WAF rate-limit block, a Spot reclaim mid-window) without spending another few
    # hundred requests re-running the demos that already captured cleanly.
    --only-restart) DO_STATIC=0 ;;
    --label) LABEL="-$2"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

KUBECTL_OUT="${OUT_DIR}/${DATE}${LABEL}-kubectl.txt"
DEMOS_OUT="${OUT_DIR}/${DATE}${LABEL}-demos.txt"
POLL_OUT="${OUT_DIR}/${DATE}${LABEL}-pod-restart-poll.txt"

kubectl get ns "$NS" >/dev/null 2>&1 || { echo "ERROR: cannot reach the cluster / namespace $NS." >&2; exit 1; }

# Config the demos need. Read from the live ConfigMap rather than `terraform output`, so this works
# against any cluster kubectl is pointed at and needs no Terraform state.
S3_BUCKET="$(kubectl -n "$NS" get cm app-config -o jsonpath='{.data.S3_BUCKET}')"
SNS_TOPIC="$(kubectl -n "$NS" get cm app-config -o jsonpath='{.data.SNS_TOPIC}')"
BACKEND_POD="$(kubectl -n "$NS" get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')"

if [ "$DO_STATIC" = "1" ]; then

# ---------------------------------------------------------------- the eight required kubectl outputs
echo "Capturing kubectl outputs -> $KUBECTL_OUT"
{
  echo "# Captured $(date -Is) against cluster '${CLUSTER}' in ${REGION}. Frozen evidence -- do not edit."
  echo
  for cmd in "get nodes" "get namespaces" "get pods -n $NS" "get deployments -n $NS" \
             "get services -n $NS" "get ingress -n $NS" \
             "describe pod $BACKEND_POD -n $NS" "logs $BACKEND_POD -n $NS --tail=40"; do
    echo "### kubectl $cmd"
    # shellcheck disable=SC2086
    kubectl $cmd 2>&1 || true
    echo
  done
} > "$KUBECTL_OUT"

# `describe pod` prints environment variable NAMES only -- values arrive via envFrom referencing a
# ConfigMap and a Secret. Fail loudly rather than commit a capture that proves otherwise.
if grep -qE 'ADMIN_PASSWORD_HASH:[[:space:]]*\S|ADMIN_SESSION_SECRET:[[:space:]]*\S|DB_PASS:[[:space:]]*\S' "$KUBECTL_OUT"; then
  echo "ERROR: a secret VALUE appears in $KUBECTL_OUT -- not committing it." >&2
  exit 1
fi

# ------------------------------------------------------------------------------------------- demos
echo "Capturing demos -> $DEMOS_OUT"
{
  echo "# Captured $(date -Is). Frozen evidence -- do not edit."
  echo

  echo "### Demo 1 — HTTPS with a valid ACM certificate"
  curl -sI "https://${APP_DOMAIN}/" | head -1 || true
  echo | openssl s_client -connect "${APP_DOMAIN}:443" -servername "${APP_DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates || true
  echo

  echo "### Demo 1b — HTTP is redirected to HTTPS"
  curl -sI "http://${APP_DOMAIN}/" | head -2 || true
  echo

  echo "### Demo 2+3 — frontend -> backend -> RDS (/api/options returns seeded DB data)"
  curl -s "https://${APP_DOMAIN}/api/options" | head -c 200 || true
  echo; echo

  echo "### Demo 3b — vote totals read from the worker-computed rollup tables"
  # `by` is required -- bare /api/results is a deliberate 400, which would look like a broken demo.
  curl -s "https://${APP_DOMAIN}/api/results?by=all" | head -c 300 || true
  echo; echo

  echo "### Demo 4 — S3 via IRSA (the backup CronJob writes to s3://${S3_BUCKET}/backups/)"
  # `| tail` swallows an empty listing into a blank line, which reads as "the command failed"
  # rather than "the prefix is empty" -- say which it is.
  s3_backups() { aws s3 ls "s3://${S3_BUCKET}/backups/" --region "$REGION" 2>&1 | tail -3 | grep . || echo "   (no objects under this prefix)"; }
  echo "-- objects before:"
  s3_backups
  kubectl -n "$NS" delete job evidence-backup --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NS" create job --from=cronjob/voteball-backup evidence-backup || true
  kubectl -n "$NS" wait --for=condition=complete job/evidence-backup --timeout=300s || true
  echo "-- objects after:"
  s3_backups
  echo

  echo "### Demo 4b — IRSA: only worker and backup carry an AWS role"
  kubectl -n "$NS" get sa -o custom-columns='NAME:.metadata.name,ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn' || true
  echo

  echo "### Demo 5 — NetworkPolicy isolation, with a control"
  echo "-- policies in force:"
  # BOTH selector forms. The 2026-08-23 split (Task 3 review T3-1) uses matchExpressions for the
  # multi-workload policies, and the old custom-columns showed only matchLabels -- so the four most
  # important policies rendered as <none> and the evidence proved nothing about who they select.
  kubectl -n "$NS" get networkpolicy -o custom-columns='NAME:.metadata.name,MATCHLABELS:.spec.podSelector.matchLabels,MATCHEXPR:.spec.podSelector.matchExpressions,TYPES:.spec.policyTypes' || true
  echo "-- egress rules, per policy (who may reach what, on which port):"
  kubectl -n "$NS" get networkpolicy -o jsonpath='{range .items[?(@.spec.egress)]}{.metadata.name}{"\n"}{range .spec.egress[*]}{"    -> "}{range .to[*]}{.ipBlock.cidr}{" "}{end}{"  ports: "}{range .ports[*]}{.protocol}{"/"}{.port}{" "}{end}{"\n"}{end}{end}' || true
  # The VPC CNI fails OPEN until the node's policy agent programs the pod's eBPF maps (observed >30s).
  # Probing a pod younger than that can succeed regardless of policy, so record the pod's age here:
  # a young pod makes this demo inconclusive, not passing.
  echo "-- worker pod age (must be > ~2m for this probe to mean anything):"
  kubectl -n "$NS" get pods -l app=worker -o custom-columns='NAME:.metadata.name,AGE:.status.startTime' || true
  echo "-- real probe: worker -> backend:5000 (must NOT connect):"
  kubectl exec -n "$NS" deploy/worker -- python -c "
import socket
s = socket.socket(); s.settimeout(8)
try:
    s.connect(('backend', 5000)); print('   REACHABLE <- policy NOT enforcing')
except Exception as e:
    print('   BLOCKED by NetworkPolicy:', type(e).__name__)
" 2>&1 || true
  # A test that cannot fail is not a test: `wget || echo BLOCKED` printed BLOCKED here for weeks
  # because wget is absent from the worker image. This control proves the probe itself works.
  echo "-- control: worker -> RDS:5432 (must connect — allow-db-egress permits it):"
  kubectl exec -n "$NS" deploy/worker -- python -c "
import os, socket
s = socket.socket(); s.settimeout(8)
s.connect((os.environ['DB_HOST'], 5432)); print('   RDS REACHABLE (the probe works)')
" 2>&1 || true
  echo

  echo "### Demo 5b — the FRONTEND cannot reach the database (Task 3 review T3-1)"
  # The specific hole the 2026-08-23 egress split closed. `allow-app-egress` used to grant all six
  # workloads every port across the whole VPC, and the RDS security group admits anything arriving
  # from the node security group -- so the one workload the public internet can reach could open a
  # socket straight to Postgres. It never needed to: nginx.conf has exactly one proxy_pass, to
  # backend:5000.
  #
  # A CONTROL FIRST, for the reason the worker probe above learned the hard way: a negative result
  # from a tool that is not installed looks identical to a negative result from a policy. If the
  # control does not connect, this demo is inconclusive, not passing.
  # THE HOST COMES FROM THE CONFIGMAP, NOT FROM THE FRONTEND'S OWN ENVIRONMENT. The first version of
  # this demo used "$DB_HOST" inside the frontend container and printed a confident BLOCKED -- while
  # nc was actually reporting `bad address ''`, because the frontend has no DB_HOST at all (correctly:
  # it never talks to the database, which is the entire point of the policy). The probe never
  # attempted a connection, so the pass meant nothing. Caught live on 2026-08-23, and it is precisely
  # the "a test that cannot fail is not a test" failure the worker probe above already learned once.
  EV_DB_HOST="$(kubectl -n "$NS" get cm app-config -o jsonpath='{.data.DB_HOST}' 2>/dev/null)"
  echo "-- resolved RDS host from the ConfigMap: ${EV_DB_HOST:-<EMPTY -- demo is INCONCLUSIVE>}"

  # TWO controls, because this demo asserts a negative and both halves can lie independently:
  #   A. backend -> RDS on the SAME host must CONNECT   (proves the host is right and RDS is up)
  #   B. frontend -> backend must CONNECT               (proves nc works in the frontend image)
  echo "-- control A: backend -> RDS:5432 on that host (must connect):"
  kubectl exec -n "$NS" deploy/backend -- python -c "
import socket
s = socket.socket(); s.settimeout(10)
try:
    s.connect(('${EV_DB_HOST}', 5432)); print('   RDS REACHABLE from backend (host correct, RDS up)')
except Exception as e:
    print('   backend could NOT reach RDS:', type(e).__name__, '-- this demo is INCONCLUSIVE')
" 2>&1 || true
  echo "-- control B: frontend -> backend:5000 (must connect — allow-frontend-to-backend-egress permits it):"
  kubectl exec -n "$NS" deploy/frontend -c frontend -- sh -c '
    if nc -z -w 8 backend 5000; then echo "   BACKEND REACHABLE (nc works in this image)";
    else echo "   control FAILED to connect — this demo is INCONCLUSIVE, not a pass"; fi' 2>&1 || true
  echo "-- real probe: frontend -> RDS:5432, same host as control A (must NOT connect):"
  kubectl exec -n "$NS" deploy/frontend -c frontend -- sh -c "
    if nc -z -w 20 '${EV_DB_HOST}' 5432; then echo '   RDS REACHABLE <- policy NOT enforcing, T3-1 has regressed';
    else echo '   BLOCKED — the frontend has no route to the database'; fi" 2>&1 || true
  echo

  echo "### Demo 5c — no Kubernetes API token is mounted where it is not needed (T3-3)"
  # frontend/backend/canary make no Kubernetes API calls, so the projected kube-api-access volume
  # kubelet mounts by default was a credential sitting in a pod with no use for it. The review found
  # it in a captured backend pod.
  for d in frontend backend; do
    printf '%-10s automountServiceAccountToken on the ServiceAccount: ' "$d"
    kubectl -n "$NS" get sa "$d" -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null || true
    printf '\n%-10s kube-api-access volume present in the pod: ' "$d"
    kubectl -n "$NS" get pod -l "app=$d" -o jsonpath='{.items[0].spec.volumes[*].name}' 2>/dev/null \
      | tr ' ' '\n' | grep -c 'kube-api-access' || true
  done
  echo

  echo "### Demo 5d — workloads run by DIGEST, not by tag (Task 4 review P2)"
  # image.digests in values.yaml is written by application-cd (and by deploy.sh step 9) from
  # scripts/ci/resolve-digests.sh. A repo@sha256:... reference here means the execution identity is
  # content, not a label. A :tag reference means the digest map was empty and the chart fell back.
  kubectl -n "$NS" get deploy,cronjob -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null || true
  kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].imageID}{"\n"}{end}' 2>/dev/null || true
  echo

  echo "### Demo 6 — SNS topic, subscriptions and delivery over the last 7 days"
  aws sns get-topic-attributes --topic-arn "$SNS_TOPIC" --region "$REGION" \
    --query 'Attributes.{Topic:DisplayName,SubsConfirmed:SubscriptionsConfirmed,SubsPending:SubscriptionsPending}' --output table || true
  for metric in NumberOfNotificationsDelivered NumberOfNotificationsFailed; do
    printf '%-32s ' "$metric"
    aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/SNS --metric-name "$metric" \
      --dimensions "Name=TopicName,Value=${SNS_TOPIC##*:}" \
      --start-time "$(date -u -d '7 days ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
      --period 604800 --statistics Sum --query 'Datapoints[0].Sum' --output text || true
  done
  echo

  echo "### Demo 7 — alert rules shipped by the app chart (PrometheusRule)"
  kubectl -n "$NS" get prometheusrule -o jsonpath='{range .items[*].spec.groups[*].rules[*]}{.alert}{"\n"}{end}' || true
  echo
} > "$DEMOS_OUT"

kubectl -n "$NS" delete job evidence-backup --ignore-not-found >/dev/null 2>&1 || true

fi  # DO_STATIC

# ------------------------------------------------------- pod restart, with the site staying up
if [ "$DO_RESTART" = "1" ]; then
  echo "Capturing the pod-restart demo -> $POLL_OUT"
  VICTIM="$(kubectl -n "$NS" get pods -l app=frontend -o jsonpath='{.items[0].metadata.name}')"

  : > "$POLL_OUT"
  # THROTTLED ON PURPOSE -- do not remove the sleep to get a denser sample.
  # The WAF's RateLimitSiteWide rule (terraform/waf.tf, rule 2) blocks an IP at 2000 requests per
  # 5 minutes, and it counts every path, not just /api/vote. An unthrottled `while :; do curl`
  # loop runs at roughly 200 requests/minute, so two back-to-back captures put this machine's
  # address over the ceiling and every probe came back 403 from awselb -- which reads exactly like
  # "the site went down during the restart" when it means "the site defended itself against the
  # measurement". At 2/second a 3-minute capture spends ~360 of the 2000 allowance.
  ( while :; do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://${APP_DOMAIN}/" || echo 000)"
      echo "$(date +%T) $code" >> "$POLL_OUT"
      sleep 0.5
    done ) &
  POLLER=$!
  trap 'kill $POLLER 2>/dev/null || true' EXIT

  # Poll either side of the event, not just during it. The replacement pod can be Ready in ~12
  # seconds, and a capture that starts at the delete and stops at `successfully rolled out` is 18
  # probes long -- too short to distinguish "no requests failed" from "we barely looked". The
  # baseline before and the tail after are what make the middle mean something.
  sleep 15
  kubectl -n "$NS" delete pod "$VICTIM" --wait=false
  # `rollout status` alone is the finish line. A `kubectl wait --for=condition=ready pod -l
  # app=frontend` here looks like a useful belt-and-braces check and is a trap: the label selector
  # still matches the TERMINATING pod, which never reports Ready again, so the wait sits there for
  # its full timeout while the poller keeps writing. It cost 5 minutes on the first run.
  kubectl -n "$NS" rollout status deploy/frontend --timeout=300s
  sleep 45

  kill $POLLER 2>/dev/null || true
  trap - EXIT

  TOTAL="$(wc -l < "$POLL_OUT")"
  BAD="$(awk '$2!=200' "$POLL_OUT" | wc -l)"
  echo "Deleted pod ${VICTIM}: ${TOTAL} probes, ${BAD} non-200."
  [ "$BAD" = "0" ] || echo "WARNING: ${BAD} probes did not return 200 -- read $POLL_OUT before quoting it as a clean run." >&2
fi

echo
echo "Done. Wrote:"
ls -la "$KUBECTL_OUT" "$DEMOS_OUT" $([ "$DO_RESTART" = "1" ] && echo "$POLL_OUT") 2>/dev/null || true
