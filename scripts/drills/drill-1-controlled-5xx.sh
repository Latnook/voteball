#!/usr/bin/env bash
# DRILL 1 — controlled 5xx. Cuts the backend's route to RDS and proves the whole chain moves:
# the metric rises, the SLI falls, and VoteballHighErrorRate fires.
#
# THIS DEGRADES THE PUBLIC SITE, deliberately, for about 6-8 minutes (VoteballHighErrorRate is
# `for: 5m` and its rate window is another 5). Run it knowingly. `/health` keeps answering 200 --
# it touches no database, which is itself the point: liveness probes that depend on RDS would
# restart every pod during a database outage.
#
# WHY A SCRIPT. The 2026-08-18 drills were hand-run, and by 2026-08-24 they were the oldest evidence
# in the repository while describing the newest work. A drill nobody can re-run is a drill that
# expires. It also means the RESTORE is a trap rather than a step someone has to remember while
# watching a site serve errors.
#
# ArgoCD's selfHeal would put the NetworkPolicy back within ~3 minutes -- sooner than the alert can
# fire -- so auto-sync is suspended for the duration and restored by the same trap.
#
# SUSPENDING AUTO-SYNC IS NECESSARY AND NOT SUFFICIENT, learned on the 2026-08-24 run. It governs only
# ArgoCD's own reconciliation. An EXPLICIT `argocd app sync` goes through regardless -- and that is
# exactly what Jenkinsfile-cd's Deploy stage issues, as user `jenkins-cd`. On that run a deploy landed
# 3m54s in, restored the deleted NetworkPolicy and ended the outage before the alert fired. The
# trigger was this drill's own repository activity: pushing the drill scripts to master started CI,
# which triggered CD, which synced.
#
# So the script now refuses to start while a CD deploy is in flight, and records the Application's
# sync history on both sides of the drill so an interfering sync is visible in the evidence rather
# than being guessed at afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/config.sh

NS=devops-app
POLICY=allow-db-egress
APP=voteball
DATE="$(date +%Y-%m-%d)"
OUT="docs/eks/evidence/${DATE}-drill-1-controlled-5xx.txt"
DEADLINE_MIN="${DRILL_DEADLINE_MIN:-14}"
PROM_PORT=19090

restored=0
restore() {
  [ "$restored" = 1 ] && return 0
  restored=1
  echo
  echo "=== RESTORE ==="
  kubectl patch application "$APP" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
  echo "  ArgoCD auto-sync re-enabled at $(date -u +%H:%M:%SZ); waiting for it to put $POLICY back"
  for _ in $(seq 1 60); do
    kubectl get networkpolicy "$POLICY" -n "$NS" >/dev/null 2>&1 && break
    sleep 5
  done
  if kubectl get networkpolicy "$POLICY" -n "$NS" >/dev/null 2>&1; then
    echo "  $POLICY is back."
  else
    echo "  !!! $POLICY DID NOT COME BACK. Restore it by hand: ArgoCD app '$APP', hard refresh + sync." >&2
  fi
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options" || echo 000)"
    echo "  recovery poll: $code"
    [ "$code" = 200 ] && break
    sleep 5
  done
}
trap restore EXIT INT TERM

kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus "$PROM_PORT:9090" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true; restore' EXIT INT TERM
for _ in $(seq 1 40); do curl -sf -m 1 "localhost:$PROM_PORT/-/ready" >/dev/null 2>&1 && break; sleep 0.5; done

promq() { curl -sS -m 10 -G --data-urlencode "query=$1" "localhost:$PROM_PORT/api/v1/query" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'EMPTY')"; }
alert_state() { curl -sS -m 10 "localhost:$PROM_PORT/api/v1/rules?type=alert" | python3 -c "
import json,sys
for g in json.load(sys.stdin)['data']['groups']:
    for r in g['rules']:
        if r['name']=='$1': print(r.get('state','?')); raise SystemExit
print('absent')"; }

exec > >(tee "$OUT") 2>&1
echo "# DRILL 1 — controlled 5xx, $(date -Is)"
echo "# HEAD $(git rev-parse HEAD)"
echo "# Method: remove the backend's RDS egress NetworkPolicy ($POLICY) so every database-backed"
echo "# request fails fast (connect_timeout=5) instead of hanging. Site degraded on purpose."
echo
echo "=== BEFORE ==="
echo "  availability      $(promq 'voteball:availability:ratio5m')"
echo "  journey requests  $(promq 'voteball:journey_requests:rate5m')"
echo "  journey errors    $(promq 'voteball:journey_errors:rate5m')"
echo "  HighErrorRate     $(alert_state VoteballHighErrorRate)"
echo "  site /api/options $(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options")"
echo
echo "=== BREAK ==="
# Refuse to start under an in-flight deploy: it would end the outage and the evidence would show a
# short, unexplained recovery. Checked here rather than trusted, because the 2026-08-24 run lost its
# window to exactly this.
opphase="$(kubectl get application "$APP" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo '')"
if [ "$opphase" = "Running" ] || [ "$opphase" = "Terminating" ]; then
  echo "REFUSING TO START: an ArgoCD operation is $opphase. A deploy in flight will restore whatever" >&2
  echo "  this drill deletes, regardless of syncPolicy. Wait for it to finish and re-run." >&2
  exit 2
fi
echo "  ArgoCD sync history before the break:"
kubectl get application "$APP" -n argocd -o jsonpath='{range .status.history[*]}    {.deployedAt}  {.revision}{"\n"}{end}' | tail -3
kubectl patch application "$APP" -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
echo "  ArgoCD auto-sync suspended -- this stops selfHeal ONLY. An explicit `argocd app sync` from"
echo "  application-cd is unaffected by it, so a deploy landing mid-drill will still end the outage."
kubectl delete networkpolicy "$POLICY" -n "$NS"
BROKE_AT="$(date -u +%H:%M:%SZ)"
echo "  $POLICY deleted at $BROKE_AT"
echo
echo "=== OBSERVE (every 30s until VoteballHighErrorRate fires, or ${DEADLINE_MIN}m) ==="
printf '  %-10s %-6s %-8s %-8s %-10s %s\n' TIME HTTP ERRORS AVAIL HEALTH ALERT
END=$(( $(date +%s) + DEADLINE_MIN*60 ))
fired=""
while [ "$(date +%s)" -lt "$END" ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options" || echo 000)"
  # IN-CLUSTER, deliberately. nginx proxies only /api/*, so https://<app_domain>/health is a 404
  # from the frontend and never reaches the backend -- the 2026-08-24 run recorded a column of 404s
  # and drew the wrong conclusion from them. /health is the probe target, so it has to be asked the
  # way the kubelet asks it.
  bpod="$(kubectl get pods -n "$NS" -l app=backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  hc="$(kubectl exec -n "$NS" "$bpod" -- python -c "
import urllib.request
print(urllib.request.urlopen('http://localhost:5000/health', timeout=5).status)" 2>/dev/null || echo ERR)"
  st="$(alert_state VoteballHighErrorRate)"
  printf '  %-10s %-6s %-8.4s %-8.6s %-10s %s\n' "$(date -u +%H:%M:%SZ)" "$code" \
    "$(promq 'voteball:journey_errors:rate5m')" "$(promq 'voteball:availability:ratio5m')" "$hc" "$st"
  if [ "$st" = firing ]; then fired="$(date -u +%H:%M:%SZ)"; break; fi
  sleep 30
done
echo
echo "  ArgoCD sync history after the break (a new row here means a deploy interfered):"
kubectl get application "$APP" -n argocd -o jsonpath='{range .status.history[*]}    {.deployedAt}  {.revision}{"\n"}{end}' | tail -3
echo
if [ -n "$fired" ]; then
  echo "RESULT: PASS. VoteballHighErrorRate fired at $fired (broken at $BROKE_AT)."
else
  echo "RESULT: the alert did NOT reach firing within ${DEADLINE_MIN}m. Read the table above before"
  echo "concluding the alert is wrong -- a drill that fails to reach its own condition looks exactly"
  echo "like a disproved design. That is what happened to drill 5 on 2026-08-18."
fi
echo
echo "  The HEALTH column is the backend's own /health, asked from inside the cluster the way the"
echo "  kubelet asks it. It should stay 200 for the whole outage: /health touches no database, which"
echo "  is what stops a database outage from restarting every pod through the liveness probe."
