#!/usr/bin/env bash
# DRILL 5 — Jenkins queue stuck. Proves JenkinsQueueStuck fires on a genuinely stuck queue.
#
# THE MECHANISM MATTERS, and getting it wrong is what made the first attempt at this drill look like
# a disproved design. Killing an agent that already exists ABORTS its build rather than queueing it,
# so the queue-length metric never moves and the alert can never reach its condition. Reaching it
# needs agent PROVISIONING to fail. A ResourceQuota of pods=1 on the `ci` namespace does that: the
# controller pod already occupies the quota, so the Kubernetes cloud cannot create an agent, and the
# build sits in the queue for as long as we let it.
#
# The site is NOT affected. The quota is namespace-scoped to `ci`; `devops-app` is untouched
# throughout. That is why JenkinsQueueStuck is severity: warning -- CI being unable to build does not
# take the product down.
#
# COSTS ~18 MINUTES: the rule is `for: 15m`. Nothing else can build during it.
#
# Requires JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD (deploy.env supplies both).
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/config.sh
[ -f deploy.env ] && { set -a; . ./deploy.env; set +a; }
: "${JENKINS_ADMIN_USER:?set JENKINS_ADMIN_USER (deploy.env)}"
: "${JENKINS_ADMIN_PASSWORD:?set JENKINS_ADMIN_PASSWORD (deploy.env)}"

DATE="$(date +%Y-%m-%d)"
OUT="docs/eks/evidence/${DATE}-drill-5-jenkins-queue-stuck.txt"
QUOTA=drill-block-agents
DEADLINE_MIN="${DRILL_DEADLINE_MIN:-22}"
PROM_PORT=19091
JENKINS_PORT=18080

cleanup() {
  echo
  echo "=== RESTORE ==="
  kubectl delete resourcequota "$QUOTA" -n ci --ignore-not-found
  echo "  quota lifted at $(date -u +%H:%M:%SZ) -- agents can be provisioned again"
  kill ${PF1:-0} ${PF2:-0} 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus "$PROM_PORT:9090" >/dev/null 2>&1 & PF1=$!
kubectl -n ci            port-forward svc/jenkins                          "$JENKINS_PORT:8080" >/dev/null 2>&1 & PF2=$!
for _ in $(seq 1 40); do curl -sf -m 1 "localhost:$PROM_PORT/-/ready" >/dev/null 2>&1 && break; sleep 0.5; done
for _ in $(seq 1 60); do curl -sf -m 1 "localhost:$JENKINS_PORT/login" >/dev/null 2>&1 && break; sleep 0.5; done

J=(-s -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
promq() { curl -sS -m 10 -G --data-urlencode "query=$1" "localhost:$PROM_PORT/api/v1/query" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'EMPTY')"; }
alert_state() { curl -sS -m 10 "localhost:$PROM_PORT/api/v1/rules?type=alert" | python3 -c "
import json,sys
for g in json.load(sys.stdin)['data']['groups']:
    for r in g['rules']:
        if r['name']=='JenkinsQueueStuck': print(r.get('state','?')); raise SystemExit
print('absent')"; }

exec > >(tee "$OUT") 2>&1
echo "# DRILL 5 — Jenkins queue stuck, $(date -Is)"
echo "# HEAD $(git rev-parse HEAD)"
echo "# Method: ResourceQuota pods=1 on namespace ci, so agent PROVISIONING fails and the build"
echo "# queues. Killing an existing agent aborts its build instead and never moves the queue metric."
echo
echo "=== BEFORE ==="
echo "  jenkins_queue_size_value  $(promq 'jenkins_queue_size_value')"
echo "  JenkinsQueueStuck         $(alert_state)"
echo "  pods in ci                $(kubectl get pods -n ci --no-headers | wc -l)"
echo "  site /api/options         $(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options")"
echo
echo "=== BREAK ==="
kubectl create quota "$QUOTA" -n ci --hard=pods=1
APPLIED="$(date -u +%H:%M:%SZ)"
echo "  quota applied at $APPLIED"
CRUMB="$(curl "${J[@]}" "localhost:$JENKINS_PORT/crumbIssuer/api/json" | python3 -c "import json,sys; print(json.load(sys.stdin)['crumb'])" 2>/dev/null || echo '')"
code="$(curl "${J[@]}" -o /dev/null -w '%{http_code}' -X POST \
  ${CRUMB:+-H "Jenkins-Crumb: $CRUMB"} \
  "localhost:$JENKINS_PORT/job/application-ci/buildWithParameters?FORCE_BUILD=true")"
echo "  triggered application-ci with FORCE_BUILD=true (HTTP $code)"
echo
echo "=== OBSERVE (every 30s until JenkinsQueueStuck fires, or ${DEADLINE_MIN}m) ==="
printf '  %-10s %-6s %-8s %-10s %s\n' TIME QUEUE CI_PODS SITE ALERT
END=$(( $(date +%s) + DEADLINE_MIN*60 ))
fired=""
while [ "$(date +%s)" -lt "$END" ]; do
  st="$(alert_state)"
  printf '  %-10s %-6.4s %-8s %-10s %s\n' "$(date -u +%H:%M:%SZ)" "$(promq 'jenkins_queue_size_value')" \
    "$(kubectl get pods -n ci --no-headers 2>/dev/null | wc -l)" \
    "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options" || echo 000)" "$st"
  if [ "$st" = firing ]; then fired="$(date -u +%H:%M:%SZ)"; break; fi
  sleep 30
done
echo
if [ -n "$fired" ]; then
  echo "RESULT: PASS. JenkinsQueueStuck fired at $fired (queue blocked from $APPLIED) -- the rule's own for: 15m."
else
  echo "RESULT: the alert did NOT reach firing within ${DEADLINE_MIN}m. Check the QUEUE column: if it"
  echo "never left 0, the build never queued and the drill did not reach its own condition."
fi
echo
echo "  The SITE column is the other half of the point: the quota is scoped to ci, so devops-app was"
echo "  untouched for the whole window. CI being unable to build does not take the product down,"
echo "  which is why this alert is severity: warning."
