#!/usr/bin/env bash
# Capture the observability evidence from the LIVE cluster into
# docs/eks/evidence/<date>-observability-*.txt.
#
# WHY THIS IS A SCRIPT. The 2026-08-18 observability evidence was captured by hand, and by the time
# the cluster had been destroyed and rebuilt twice it was the oldest evidence in the repository while
# describing the newest work. Every pod name, PVC, ALB and image digest changes on a rebuild, so a
# hand-run capture is stale the moment the stack is replaced. Re-running this is the cheap path, and
# it is the ONLY thing that keeps "the dashboards show real data" a checked claim rather than a
# remembered one.
#
# READ-ONLY. Nothing here mutates the cluster -- no pod is deleted, no quota applied, no release
# rolled. The failure DRILLS are deliberately not automated here: they break production on purpose
# and belong to a human who is watching. This script proves the steady state.
#
# Captured evidence is DATED and never edited afterwards. A digest in an old file that no longer
# resolves is the file working as intended; capture a new set rather than "correcting" an old one.
#
# Usage:
#   ./scripts/capture-observability-evidence.sh
#   ./scripts/capture-observability-evidence.sh --label post-rebuild   # suffix the filenames
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh
. scripts/lib/config.sh

LABEL=""
[ "${1:-}" = "--label" ] && LABEL="-$2"
DATE="$(date +%Y-%m-%d)"
OUT="docs/eks/evidence/${DATE}-observability${LABEL}.txt"
NS_OBS=observability
NS_APP=devops-app

# --- port-forwards -------------------------------------------------------------------------------
# Prometheus, Grafana and Alertmanager are ClusterIP-only by design (nothing in this stack is exposed
# to the internet), so every query below goes through a temporary local tunnel that dies with the
# script. Fixed high ports, chosen not to collide with the ones docs/observability.md tells a human
# to use, so running this while someone has Grafana open does not fight them for a port.
PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

forward() { # svc localport remoteport
  kubectl -n "$NS_OBS" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  for _ in $(seq 1 40); do
    curl -sf -m 1 "localhost:$2/" >/dev/null 2>&1 && return 0
    curl -sf -m 1 "localhost:$2/-/ready" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}
forward kube-prometheus-stack-prometheus   19090 9090 || echo "WARN: no Prometheus tunnel" >&2
forward kube-prometheus-stack-grafana      13000 80   || echo "WARN: no Grafana tunnel" >&2
forward kube-prometheus-stack-alertmanager 19093 9093 || echo "WARN: no Alertmanager tunnel" >&2
PROM=http://localhost:19090
GRAF=http://localhost:13000
ALERT=http://localhost:19093
GRAF_PW="$(kubectl get secret kube-prometheus-stack-grafana -n "$NS_OBS" -o jsonpath='{.data.admin-password}' | base64 -d)"

exec > >(tee "$OUT") 2>&1
echo "# Observability evidence, captured $(date -Is) against the live cluster."
echo "# Repository HEAD: $(git rev-parse HEAD)  ($(git log -1 --format=%s))"
echo "# Read-only capture. See the drill transcripts for the deliberate-failure evidence."
echo

echo "=== 1. The stack itself ==="
kubectl get pods -n "$NS_OBS" -o wide
echo
kubectl get pvc -n "$NS_OBS"
echo
echo "--- Prometheus retention and storage, as configured AND as consumed ---"
kubectl get prometheus -n "$NS_OBS" -o jsonpath='{range .items[*]}retention={.spec.retention}  retentionSize={.spec.retentionSize}  requested={.spec.storage.volumeClaimTemplate.spec.resources.requests.storage}{"\n"}{end}'
curl -sS -G --data-urlencode 'query=prometheus_tsdb_storage_blocks_bytes' "$PROM/api/v1/query" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('on-disk blocks: %s bytes (%.1f MiB)'%(r[0]['value'][1], float(r[0]['value'][1])/1048576) if r else 'on-disk blocks: no data')"
curl -sS -G --data-urlencode 'query=kubelet_volume_stats_used_bytes{namespace="observability"} / kubelet_volume_stats_capacity_bytes{namespace="observability"}' "$PROM/api/v1/query" \
  | python3 -c "
import json,sys
for x in json.load(sys.stdin)['data']['result']:
    print('PVC %s: %.2f%% used' % (x['metric'].get('persistentvolumeclaim','?'), float(x['value'][1])*100))
"
echo

echo "=== 2. Every scrape target, and its health ==="
# A target that is DOWN makes a dashboard blind rather than red, so this is the first thing to prove.
curl -sS "$PROM/api/v1/targets?state=any" | python3 -c "
import json,sys,collections
d=json.load(sys.stdin)['data']['activeTargets']
by=collections.Counter(t['health'] for t in d)
print('active targets: %d  (%s)' % (len(d), ', '.join('%s=%d'%(k,v) for k,v in sorted(by.items()))))
for t in sorted(d, key=lambda t:(t['health']!='up', t['labels'].get('job',''))):
    print('  %-4s %-42s %s' % (t['health'], t['labels'].get('job','?'), t['scrapeUrl']))
    if t['health']!='up' and t.get('lastError'): print('        lastError: '+t['lastError'])
"
echo

echo "=== 3. Every rule loaded, and its health ==="
# A rule with a typo reports health != 'ok' and silently never fires.
curl -sS "$PROM/api/v1/rules" | python3 -c "
import json,sys,collections
g=json.load(sys.stdin)['data']['groups']
rules=[r for x in g for r in x['rules']]
print('groups: %d  rules: %d  (%s)' % (len(g), len(rules),
      ', '.join('%s=%d'%(k,v) for k,v in sorted(collections.Counter(r['health'] for r in rules).items()))))
for r in rules:
    if r['type']=='alerting':
        print('  alert  %-34s health=%-3s state=%s' % (r['name'], r['health'], r.get('state','?')))
    else:
        print('  record %-34s health=%s' % (r['name'], r['health']))
"
echo

echo "=== 4. The SLIs return numbers ==="
# VoteballSLIAbsent exists because an EMPTY result and a healthy 100% look identical on a stat panel.
for rule in voteball:journey_requests:rate5m voteball:journey_errors:rate5m voteball:availability:ratio5m voteball:latency:p95_5m; do
  printf '  %-38s ' "$rule"
  curl -sS -G --data-urlencode "query=$rule" "$PROM/api/v1/query" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'EMPTY -- this is what VoteballSLIAbsent catches')"
done
echo

echo "=== 5. commit -> image digest -> running Pod -> metric ==="
# The chain the final-project brief asks to be demonstrable from a single commit.
echo "--- what the chart pins ---"
grep -A5 '^  digests:' charts/voteball/values.yaml | sed 's/^/  /'
echo "--- what the Deployment resolved ---"
kubectl get deploy -n "$NS_APP" -o custom-columns='DEPLOYMENT:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' --no-headers | sed 's/^/  /'
echo "--- what the running pod reports as its own identity ---"
curl -sS -G --data-urlencode 'query=voteball_app_info' "$PROM/api/v1/query" | python3 -c "
import json,sys
for x in json.load(sys.stdin)['data']['result']:
    m=x['metric']; print('  pod=%s version=%s git_sha=%s release=%s' % (m.get('pod'), m.get('version'), m.get('git_sha'), m.get('release')))
"
echo

echo "=== 6. Grafana: dashboards registered, datasource healthy ==="
curl -sS -u "admin:$GRAF_PW" "$GRAF/api/search?type=dash-db" | python3 -c "
import json,sys
for d in sorted(json.load(sys.stdin), key=lambda d:d['title']):
    print('  %-34s uid=%s' % (d['title'], d['uid']))
"
echo "--- datasource health (registration proves nothing about whether a panel can query) ---"
curl -sS -u "admin:$GRAF_PW" "$GRAF/api/datasources" | python3 -c "
import json,sys
for d in json.load(sys.stdin): print('  %s (%s) uid=%s' % (d['name'], d['type'], d['uid']))
" 
curl -sS -u "admin:$GRAF_PW" "$GRAF/api/datasources/uid/prometheus/health" | sed 's/^/  /'
echo; echo
echo "--- the ConfigMaps they are provisioned from (no import button was pressed) ---"
kubectl get cm -n "$NS_OBS" -l grafana_dashboard=1 --no-headers | sed 's/^/  /'
echo

echo "=== 7. Every panel of every dashboard, queried for real data ==="
# THE point of this section. A registered dashboard with an empty panel looks identical to a working
# one in `kubectl get` and in Grafana's search API. This runs each panel's OWN query against the same
# Prometheus Grafana would use and reports how many series came back. Template variables are expanded
# to `.*`, which is exactly what the dashboards' `All` option sends.
python3 - "$PROM" <<'PYEOF'
import json, sys, glob, urllib.parse, urllib.request, re
prom = sys.argv[1]
total = empty = 0
for path in sorted(glob.glob('charts/observability/dashboards/*.json')):
    d = json.load(open(path))
    print('  --- %s (uid=%s) ---' % (d['title'], d['uid']))
    for p in d.get('panels', []):
        for t in p.get('targets', []):
            expr = t.get('expr', '')
            if not expr:
                continue
            # `All` sends .* for every variable; $__rate_interval is not used by these dashboards.
            q = re.sub(r'\$(\w+)', '.*', expr)
            url = prom + '/api/v1/query?' + urllib.parse.urlencode({'query': q})
            try:
                r = json.load(urllib.request.urlopen(url, timeout=20))
                n = len(r.get('data', {}).get('result', []))
                status = r.get('status')
            except Exception as e:
                n, status = 0, 'ERROR: %s' % e
            total += 1
            mark = 'ok  '
            if status != 'success':
                mark = 'FAIL'
            elif n == 0:
                mark = 'EMPTY'; empty += 1
            print('    %-5s %-46s series=%-3s %s' % (mark, p['title'][:46], n, t.get('refId', '')))
print('  %d panel queries run, %d returned no series.' % (total, empty))
if empty:
    print('  NOTE: an empty panel is not automatically a defect -- a counter for an event that has')
    print('  not happened in the window (OOMKills, rejected ballots) is legitimately empty. Read the')
    print('  names above rather than the count.')
PYEOF
echo

echo "=== 8. Alertmanager: where an alert actually goes ==="
curl -sS "$ALERT/api/v2/status" | python3 -c "
import json,sys,yaml
s=json.load(sys.stdin)
cfg=yaml.safe_load(s['config']['original'])
print('  receivers: %s' % ', '.join(r['name'] for r in cfg.get('receivers',[])))
for r in cfg.get('receivers',[]):
    for sns in r.get('sns_configs',[]) or []:
        print('  sns topic: %s' % sns.get('topic_arn'))
print('  inhibit_rules: %d' % len(cfg.get('inhibit_rules',[]) or []))
" 2>/dev/null || curl -sS "$ALERT/api/v2/status" | head -c 400
echo
echo "--- currently firing (a quiet system firing nothing is the expected steady state) ---"
curl -sS "$ALERT/api/v2/alerts" | python3 -c "
import json,sys
a=json.load(sys.stdin)
print('  %d active alert(s)' % len(a))
for x in a: print('    %s severity=%s' % (x['labels'].get('alertname'), x['labels'].get('severity')))
"
echo
echo "--- notification failures since start (0 is the number that matters) ---"
curl -sS -G --data-urlencode 'query=alertmanager_notifications_failed_total' "$PROM/api/v1/query" | python3 -c "
import json,sys
r=json.load(sys.stdin)['data']['result']
print('  ' + ('; '.join('%s=%s'%(x['metric'].get('integration'), x['value'][1]) for x in r) if r else 'no data'))
"
echo
echo "Captured to $OUT"
