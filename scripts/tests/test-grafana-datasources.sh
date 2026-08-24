#!/usr/bin/env bash
# Anti-drift gate for the Grafana data source provisioning files.
#
# WHY THIS EXISTS: Grafana expands an UNSET environment variable in a provisioning file to an EMPTY
# STRING rather than failing. So a renamed key on either side of the contract -- the ExternalSecret's
# secretKey, terraform's envFromSecret, or the $VAR in the ConfigMap -- produces a data source that
# provisions cleanly, reports no error at startup, and fails only when a human opens a panel. That is
# silent failure #2 in docs/design/2026-08-24-grafana-datasources-design.md.
#
# It also checks the uid contract in the other direction: a dashboard panel naming a data source uid
# that no data source declares renders an empty panel, not an error. That check parses each
# dashboard's JSON with python3 (present in the PYTHON_GROUP container run-ci-suite.sh runs this in)
# and walks every "datasource" object at any depth -- a single-line grep for
# `"datasource":\s*\{[^}]*"uid": "X"` cannot span newlines, so a pretty-printed, multi-line
# "datasource" block passed this check silently until 2026-08-24, matching neither ok() nor fail().
#
# Offline: reads the repository's own files, renders nothing, needs no cluster.
set -uo pipefail

cd "$(dirname "$0")/../.."   # repo root

DS=charts/observability/templates/datasources.yaml
TF=terraform/addon-monitoring.tf
ES=charts/observability/templates/externalsecret.yaml
DASHBOARD_DIR=charts/observability/dashboards

fails=0
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
ok()   { echo "  ok   $*"; }

for f in "$DS" "$TF" "$ES"; do
  [ -f "$f" ] || { echo "FAIL: $f not found -- has it been renamed?" >&2; exit 1; }
done

# --- 1. Every $VAR the ConfigMaps interpolate is actually projected -------------------------------
echo "1. environment variables referenced by $DS"
vars=$(grep -oE '\$GF_DATASOURCE_[A-Z_]+' "$DS" | sed 's/^\$//' | sort -u)
[ -n "$vars" ] || fail "no \$GF_DATASOURCE_* references found -- did the interpolation syntax change?"
# Extract each secretKey's VALUE (not the raw line) and compare for exact equality. An unanchored
# `grep -q "secretKey: $v"` substring match passes when $v is merely a PREFIX of the real key -- e.g.
# renaming GF_DATASOURCE_DB_PASSWORD to GF_DATASOURCE_DB_PASSWORD_RENAMED leaves the old name sitting
# inside the new one, so the check reports the old key as still "produced" when it no longer exists.
secretkeys=$(grep -oE 'secretKey:[[:space:]]*[A-Za-z0-9_]+' "$ES" | sed -E 's/^secretKey:[[:space:]]*//')
for v in $vars; do
  match=0
  while IFS= read -r sk; do
    [ "$sk" = "$v" ] && { match=1; break; }
  done <<< "$secretkeys"
  if [ "$match" = 1 ]; then
    ok "$v is produced by an ExternalSecret"
  else
    fail "$v is interpolated in $DS but no ExternalSecret in $ES produces it"
  fi
done

# --- 2. The Secret those keys live in is projected into the pod -----------------------------------
echo "2. envFromSecret wiring"
if grep -q 'envFromSecret *= *"grafana-datasources"' "$TF"; then
  ok "terraform projects the grafana-datasources Secret"
else
  fail "$TF does not set grafana.envFromSecret to grafana-datasources"
fi
if grep -q 'name: grafana-datasources' "$ES"; then
  ok "the ExternalSecret targets that Secret name"
else
  fail "$ES does not target a Secret named grafana-datasources"
fi

# --- 3. No literal credential anywhere in the ConfigMaps ------------------------------------------
echo "3. no plaintext credential in $DS"
if grep -nE '(password|token):[[:space:]]*["'"'"']?[^$"'"'"'[:space:]][^"'"'"']*' "$DS" \
     | grep -vE '\$GF_DATASOURCE_' | grep -q .; then
  fail "a password/token field in $DS is not an environment reference"
else
  ok "every password/token field is a \$GF_DATASOURCE_* reference"
fi

# --- 4. Declared uids, and every dashboard panel referencing one that exists -----------------------
echo "4. data source uid contract"
# uids the chart declares, plus the two kube-prometheus-stack provisions for itself.
declared=$( { grep -oE '^[[:space:]]+uid:[[:space:]]*[a-z0-9-]+' "$DS" | sed -E 's/.*uid:[[:space:]]*//'
              printf 'prometheus\nalertmanager\n'; } | sort -u )
for u in $declared; do ok "declares uid $u"; done

# Parsed with python3, not grep. A single-line grep for `"datasource":\s*\{[^}]*"uid": "X"` cannot
# span newlines (grep matches per LINE by default), so a pretty-printed, MULTI-LINE "datasource"
# block never matched at all -- the enclosing `if grep -rq ...` was simply false, so neither ok() nor
# fail() ever fired for it. That is silent pass-by-omission, not a false positive, and a reviewer
# proved it both ways (see the sabotage transcript in the Task 6 report). python3 walks the actual
# parsed JSON structure instead, at any depth and regardless of formatting, so it cannot miss one.
if [ -d "$DASHBOARD_DIR" ]; then
  python3 - "$DASHBOARD_DIR" "$declared" <<'PYEOF'
import json
import os
import sys

dashboard_dir = sys.argv[1]
declared = set(sys.argv[2].split())


def find_datasource_uids(obj):
    """Yield every uid named by a {"datasource": {..., "uid": "..."}} object at any depth."""
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if isinstance(ds, dict) and isinstance(ds.get("uid"), str):
            yield ds["uid"]
        for value in obj.values():
            yield from find_datasource_uids(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from find_datasource_uids(item)


fails = 0
for fname in sorted(os.listdir(dashboard_dir)):
    if not fname.endswith(".json"):
        continue
    with open(os.path.join(dashboard_dir, fname)) as f:
        data = json.load(f)
    for uid in sorted(set(find_datasource_uids(data))):
        if uid in declared:
            print(f"  ok   dashboard data source uid {uid} is declared ({fname})")
        else:
            print(f'  FAIL a dashboard panel in {fname} uses data source uid "{uid}", '
                  'which no data source declares')
            fails += 1

sys.exit(min(fails, 255))
PYEOF
  py_rc=$?
  [ "$py_rc" -eq 0 ] || fails=$((fails + py_rc))
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASSED"
