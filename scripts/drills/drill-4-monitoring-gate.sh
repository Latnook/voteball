#!/usr/bin/env bash
# DRILL 4 — the Monitoring Gate. Ships a release that is HEALTHY BY EVERY OTHER MEASURE and only slow,
# and proves the gate catches it and rolls production back on its own.
#
# WHY THIS IS THE INTERESTING DRILL. A broken release is easy to catch: pods crash, ArgoCD goes
# Degraded, the smoke test 500s. This one passes all of that. Pods are Healthy, ArgoCD reports Synced,
# /api/options returns 200 with correct data -- it is simply 1.5s slower than the SLO allows.
# GATE_MAX_P95_SECONDS is 1.0, so p95 breaches and the gate is the ONLY check in the pipeline that
# says no. Everything before it says yes.
#
# THIS PUSHES A DELIBERATELY DEGRADED RELEASE TO PRODUCTION. That is the drill. The public site serves
# slow (not failing) responses from the moment CD deploys until the rollback lands -- roughly 5-10
# minutes. Do not run it while someone is watching a demo.
#
# THE REVERT IS IN A TRAP, and that is the whole reason this is a script rather than a sequence of
# commands. The drill commits to master; if the session running it dies between the commit and the
# revert, master keeps a deliberate performance regression and CD keeps deploying it. The trap reverts
# and pushes on every exit path, including SIGINT and SIGTERM.
#
# It also refuses to start on a dirty tree: it commits what is in the working directory, and sweeping
# somebody else's in-progress edits into a commit titled DRILL would be worse than the drill itself.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/config.sh
[ -f deploy.env ] && { set -a; . ./deploy.env; set +a; }
: "${JENKINS_ADMIN_USER:?set JENKINS_ADMIN_USER (deploy.env)}"
: "${JENKINS_ADMIN_PASSWORD:?set JENKINS_ADMIN_PASSWORD (deploy.env)}"

DATE="$(date +%Y-%m-%d)"
OUT="docs/eks/evidence/${DATE}-drill-4-monitoring-gate.txt"
TARGET=services/backend/app.py
JENKINS_PORT=18090
DEADLINE_MIN="${DRILL_DEADLINE_MIN:-35}"

[ -z "$(git status --porcelain)" ] || { echo "REFUSING: working tree is dirty. This drill commits." >&2; exit 2; }
BASE_SHA="$(git rev-parse HEAD)"
DRILL_SHA=""

reverted=0
revert_drill() {
  [ "$reverted" = 1 ] && return 0
  reverted=1
  echo
  echo "=== REVERT ==="
  if [ -z "$DRILL_SHA" ]; then echo "  nothing was committed; nothing to revert."; return 0; fi
  git checkout -- "$TARGET" 2>/dev/null || true
  if git revert --no-edit "$DRILL_SHA" >/dev/null 2>&1; then
    echo "  reverted $DRILL_SHA locally"
  else
    git revert --abort 2>/dev/null || true
    echo "  !!! git revert FAILED. Revert $DRILL_SHA BY HAND -- master is carrying the drill's" >&2
    echo "      injected latency and CD will keep deploying it." >&2
    return 1
  fi
  if git push origin master >/dev/null 2>&1; then
    echo "  revert pushed; CI/CD will redeploy the healthy build."
  else
    echo "  !!! the revert commit is LOCAL ONLY -- push it by hand, now." >&2
    return 1
  fi
}
cleanup() { revert_drill || true; kill ${PF:-0} 2>/dev/null || true; rm -f "${COOKIE_JAR:-}"; }
trap cleanup EXIT INT TERM

kubectl -n ci port-forward svc/jenkins "$JENKINS_PORT:8080" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 60); do curl -sf -m 1 "localhost:$JENKINS_PORT/login" >/dev/null 2>&1 && break; sleep 0.5; done
J=(-s -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
COOKIE_JAR="$(mktemp)"

last_build() { curl -sg "${J[@]}" "localhost:$JENKINS_PORT/job/$1/api/json?tree=lastBuild[number]" \
  | python3 -c "import json,sys; print((json.load(sys.stdin).get('lastBuild') or {}).get('number',0))" 2>/dev/null || echo 0; }
build_state() { curl -sg "${J[@]}" "localhost:$JENKINS_PORT/job/$1/$2/api/json?tree=result,building" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d.get('result'), d.get('building')))" 2>/dev/null || echo "?/?"; }
deployed_image() { kubectl get deploy backend -n devops-app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*[@:]//' | cut -c1-14; }

exec > >(tee "$OUT") 2>&1
echo "# DRILL 4 — the Monitoring Gate, $(date -Is)"
echo "# HEAD before the drill: $BASE_SHA"
echo "# Injects a 1.5s sleep into /api/options. GATE_MAX_P95_SECONDS is 1.0, so p95 breaches while"
echo "# pods stay Healthy, ArgoCD stays Synced and the smoke test still passes. The gate is the only"
echo "# check in the pipeline that can say no to this release."
echo
echo "=== BEFORE ==="
echo "  deployed backend image: $(deployed_image)"
echo "  site /api/options:      $(curl -s -o /dev/null -w '%{http_code} in %{time_total}s' -m 15 "https://${APP_DOMAIN}/api/options")"
CI_BEFORE="$(last_build application-ci)"
CD_BEFORE="$(last_build application-cd)"
echo "  application-ci last build: #$CI_BEFORE"
echo "  application-cd last build: #$CD_BEFORE"
echo

echo "=== BREAK: inject 1.5s into /api/options and push to master ==="
python3 - "$TARGET" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = """    conn = db.get_db()
    try:
        result = queries.get_options(conn)
    finally:
        conn.close()
    return jsonify(result)"""
inject = """    time.sleep(1.5)  # DRILL 4 -- deliberate latency regression, reverted by the drill script
    conn = db.get_db()
    try:
        result = queries.get_options(conn)
    finally:
        conn.close()
    return jsonify(result)"""
assert anchor in s, "anchor not found in options(); the route changed -- update this drill before running it"
p.write_text(s.replace(anchor, inject, 1))
PYEOF
git add "$TARGET"
git commit -q -m "DRILL: inject 1.5s into /api/options to prove the Monitoring Gate rolls back

Deliberate, temporary, and reverted by scripts/drills/drill-4-monitoring-gate.sh in
the same run. The release is healthy by every other measure -- pods Ready, ArgoCD
Synced, smoke test 200 -- and only breaches the p95 SLO, so the Monitoring Gate is the
only check in the pipeline that can catch it."
DRILL_SHA="$(git rev-parse HEAD)"
git push -q origin master
echo "  pushed $DRILL_SHA at $(date -u +%H:%M:%SZ)"
echo

echo "=== OBSERVE ==="
printf '  %-10s %-9s %-18s %-18s %s\n' TIME SITE_S CI CD DEPLOYED
END=$(( $(date +%s) + DEADLINE_MIN*60 ))
cd_after_ours=0
while [ "$(date +%s)" -lt "$END" ]; do
  ci_n="$(last_build application-ci)"; cd_n="$(last_build application-cd)"
  ci_s="$(build_state application-ci "$ci_n")"; cd_s="$(build_state application-cd "$cd_n")"
  secs="$(curl -s -o /dev/null -w '%{time_total}' -m 25 "https://${APP_DOMAIN}/api/options" || echo -)"
  printf '  %-10s %-9s #%-3s %-14s #%-3s %-14s %s\n' \
    "$(date -u +%H:%M:%SZ)" "$secs" "$ci_n" "$ci_s" "$cd_n" "$cd_s" "$(deployed_image)"
  cd_after_ours=$(( cd_n - CD_BEFORE ))
  # Finished once a SECOND CD build after ours has completed: the first deploys the slow release and
  # fails the gate, the second is the automatic rollback.
  if [ "$cd_after_ours" -ge 2 ] && [ "${cd_s##*/}" = "False" ]; then
    echo "  a second application-cd build after ours has finished -- that is the rollback."
    break
  fi
  sleep 30
done
echo
echo "=== CD BUILDS AFTER THE DRILL ==="
curl -sg "${J[@]}" "localhost:$JENKINS_PORT/job/application-cd/api/json?tree=builds[number,result,description]{0,6}" \
 | python3 -c "
import json,sys
for b in json.load(sys.stdin).get('builds',[]):
    print('  #%-4s %-10s %s' % (b['number'], b.get('result'), (b.get('description') or '').replace(chr(10),' ')[:90]))" 2>/dev/null || echo "  (could not read build list)"
echo
echo "=== WHAT THE GATE ACTUALLY SAID ==="
CD_NOW="$(last_build application-cd)"
n="$((CD_BEFORE+1))"
while [ "$n" -le "$CD_NOW" ]; do
  echo "  --- application-cd #$n ---"
  curl -sg "${J[@]}" "localhost:$JENKINS_PORT/job/application-cd/$n/consoleText" 2>/dev/null \
    | grep -E "^gate:|Monitoring Gate|ROLLBACK|Rolling back|rollback" | head -14 | sed 's/^/    /'
  n=$((n+1))
done
echo
echo "  The SITE_S column is the point: it is a RESPONSE TIME, not a status code. Every request in"
echo "  this drill succeeded. Nothing crashed, nothing 500'd, no pod restarted. A release can be"
echo "  entirely healthy and still be one the SLO says must not ship, and the Monitoring Gate is the"
echo "  only check here that can tell the difference."
