#!/usr/bin/env bash
# DRILL 3 — Jenkins agent loss. Kills a build agent mid-build and proves two things:
#   1. The PRODUCT is unaffected. CI and the app share a cluster, not a failure domain.
#   2. Jenkins re-provisions an agent on its own -- the Kubernetes cloud is not a pet.
#
# WHAT THIS DRILL CANNOT DO, and the reason drill 5 exists: killing an agent that already exists
# ABORTS its build. It does not queue it. So jenkins_queue_size_value never moves and this drill can
# never exercise JenkinsQueueStuck, however long you watch. Reaching that condition needs agent
# PROVISIONING to fail, which is drill 5's ResourceQuota. Reading this drill's flat queue metric as
# "the alert is broken" is the mistake the 2026-08-18 run made.
#
# The site is not touched. Requires JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD (deploy.env).
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/config.sh
[ -f deploy.env ] && { set -a; . ./deploy.env; set +a; }
: "${JENKINS_ADMIN_USER:?set JENKINS_ADMIN_USER (deploy.env)}"
: "${JENKINS_ADMIN_PASSWORD:?set JENKINS_ADMIN_PASSWORD (deploy.env)}"

DATE="$(date +%Y-%m-%d)"
OUT="docs/eks/evidence/${DATE}-drill-3-jenkins-agent-loss.txt"
PROM_PORT=19092
JENKINS_PORT=18081
WAIT_AGENT_SEC="${DRILL_WAIT_AGENT_SEC:-300}"

cleanup() { kill ${PF1:-0} ${PF2:-0} 2>/dev/null || true; }
trap cleanup EXIT INT TERM
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus "$PROM_PORT:9090" >/dev/null 2>&1 & PF1=$!
kubectl -n ci            port-forward svc/jenkins                          "$JENKINS_PORT:8080" >/dev/null 2>&1 & PF2=$!
for _ in $(seq 1 40); do curl -sf -m 1 "localhost:$PROM_PORT/-/ready"  >/dev/null 2>&1 && break; sleep 0.5; done
for _ in $(seq 1 60); do curl -sf -m 1 "localhost:$JENKINS_PORT/login" >/dev/null 2>&1 && break; sleep 0.5; done

J=(-s -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
promq() { curl -sS -m 10 -G --data-urlencode "query=$1" "localhost:$PROM_PORT/api/v1/query" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'EMPTY')"; }
agent_pod() { kubectl get pods -n ci --no-headers 2>/dev/null | awk '/^voteball-build/ {print $1; exit}'; }

exec > >(tee "$OUT") 2>&1
echo "# DRILL 3 — Jenkins agent loss, $(date -Is)"
echo "# HEAD $(git rev-parse HEAD)"
echo
echo "=== BEFORE ==="
echo "  pods in ci        $(kubectl get pods -n ci --no-headers | wc -l)"
echo "  queue size        $(promq 'jenkins_queue_size_value')"
echo "  site /api/options $(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options")"
echo
echo "=== TRIGGER A BUILD ==="
CRUMB="$(curl "${J[@]}" "localhost:$JENKINS_PORT/crumbIssuer/api/json" | python3 -c "import json,sys; print(json.load(sys.stdin)['crumb'])" 2>/dev/null || echo '')"
BEFORE_N="$(curl "${J[@]}" "localhost:$JENKINS_PORT/job/application-ci/api/json" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('lastBuild') or {}).get('number',0))")"
code="$(curl "${J[@]}" -o /dev/null -w '%{http_code}' -X POST ${CRUMB:+-H "Jenkins-Crumb: $CRUMB"} \
  "localhost:$JENKINS_PORT/job/application-ci/buildWithParameters?FORCE_BUILD=true")"
echo "  application-ci triggered (HTTP $code); last build before was #$BEFORE_N"
echo "  waiting up to ${WAIT_AGENT_SEC}s for an agent pod to reach Running"
POD=""
END=$(( $(date +%s) + WAIT_AGENT_SEC ))
while [ "$(date +%s)" -lt "$END" ]; do
  p="$(agent_pod)"
  if [ -n "$p" ] && [ "$(kubectl get pod "$p" -n ci -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; then POD="$p"; break; fi
  sleep 5
done
[ -n "$POD" ] || { echo "  no agent pod appeared within ${WAIT_AGENT_SEC}s -- drill cannot proceed"; exit 1; }
echo "  agent pod Running: $POD ($(kubectl get pod "$POD" -n ci -o jsonpath='{range .spec.containers[*]}{.name} {end}'))"
echo
echo "=== KILL THE AGENT MID-BUILD ==="
kubectl delete pod "$POD" -n ci --grace-period=0 --force 2>&1 | sed 's/^/  /'
KILLED="$(date -u +%H:%M:%SZ)"
echo "  killed at $KILLED"
echo
echo "=== OBSERVE (5 minutes) ==="
printf '  %-10s %-6s %-8s %-8s %s\n' TIME SITE QUEUE CI_PODS AGENT
for _ in $(seq 1 20); do
  printf '  %-10s %-6s %-8.4s %-8s %s\n' "$(date -u +%H:%M:%SZ)" \
    "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://${APP_DOMAIN}/api/options" || echo 000)" \
    "$(promq 'jenkins_queue_size_value')" \
    "$(kubectl get pods -n ci --no-headers 2>/dev/null | wc -l)" \
    "$(agent_pod || echo '-')"
  sleep 15
done
echo
echo "=== AFTER ==="
curl -g "${J[@]}" "localhost:$JENKINS_PORT/job/application-ci/api/json?tree=builds[number,result,building]{0,4}" \
  | python3 -c "
import json,sys
for b in json.load(sys.stdin).get('builds',[]):
    print('  build #%s  result=%s  building=%s' % (b['number'], b.get('result'), b.get('building')))"
echo
echo "  Read the QUEUE column before concluding anything about JenkinsQueueStuck: killing an existing"
echo "  agent aborts its build rather than queueing it, so a flat 0 here is the drill's mechanism, not"
echo "  a broken alert. Drill 5 is the one that reaches that condition."
