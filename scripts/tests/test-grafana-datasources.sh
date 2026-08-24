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
VOTEBALL_ES=charts/voteball/templates/externalsecret.yaml
SEED_SCRIPT=scripts/seed-grafana-secret.sh
DASHBOARD_DIR=charts/observability/dashboards

fails=0
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
ok()   { echo "  ok   $*"; }

for f in "$DS" "$TF" "$ES" "$VOTEBALL_ES" "$SEED_SCRIPT"; do
  [ -f "$f" ] || { echo "FAIL: $f not found -- has it been renamed?" >&2; exit 1; }
done
# A skip must never read like a pass -- check 4 needs this directory and used to silently no-op its
# whole body if it went missing (proven: renaming it away left rc=0). Hard-fail here instead, same
# as the file checks above.
[ -d "$DASHBOARD_DIR" ] || { echo "FAIL: $DASHBOARD_DIR not found -- has it been renamed?" >&2; exit 1; }

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

# --- 2. The Secret those keys live in is projected into the pod, as OPTIONAL --------------------
# Must be the PLURAL `envFromSecrets` (a list of objects), not the singular `envFromSecret` (a bare
# name) -- only the plural form supports `optional`, and this Secret is created only when
# charts/observability is enabled (gated `enabled: false` by default), so a mandatory projection
# takes Grafana down on every `terraform apply` before that chart is ever turned on. Deliberately NOT
# loosened to accept the singular form or a plural block missing `optional: true` -- either of those
# is the exact regression this check exists to catch.
echo "2. envFromSecrets wiring (plural, optional)"
block=$(awk '/envFromSecrets[[:space:]]*=[[:space:]]*\[/{flag=1} flag{print} flag && /\]/{exit}' "$TF")
if [ -z "$block" ]; then
  fail "$TF does not set grafana.envFromSecrets (plural) at all"
elif ! echo "$block" | grep -q 'name[[:space:]]*=[[:space:]]*"grafana-datasources"'; then
  fail "$TF's envFromSecrets block does not name the grafana-datasources Secret"
elif ! echo "$block" | grep -q 'optional[[:space:]]*=[[:space:]]*true'; then
  fail "$TF's envFromSecrets entry for grafana-datasources is missing optional = true -- this takes Grafana down the moment charts/observability is not yet enabled"
else
  ok "terraform projects the grafana-datasources Secret via envFromSecrets, marked optional"
fi
if grep -q 'name: grafana-datasources' "$ES"; then
  ok "the ExternalSecret targets that Secret name"
else
  fail "$ES does not target a Secret named grafana-datasources"
fi

# --- 3. No literal credential anywhere in the ConfigMaps ------------------------------------------
# Case-INSENSITIVE (grep -iE) and covers password|token|secret|apikey, not just the two exact field
# names this file happens to use today. A plain `(password|token):` misses the field Grafana's own
# GitHub data source actually calls a credential -- `accessToken:` -- since "Token" with a capital T
# never matches a lowercase-only alternation. Proven: `accessToken: ghp_realtokenABC123` passed this
# check at rc=0 before this fix.
echo "3. no plaintext credential in $DS"
if grep -inE '(password|token|secret|apikey):[[:space:]]*["'"'"']?[^$"'"'"'[:space:]][^"'"'"']*' "$DS" \
     | grep -vE '\$GF_DATASOURCE_' | grep -q .; then
  fail "a password/token/secret/apikey field in $DS is not an environment reference"
else
  ok "every password/token/secret/apikey field is a \$GF_DATASOURCE_* reference"
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
# ($DASHBOARD_DIR's existence is asserted up top now, not re-checked here -- see the hard-fail block.)
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

echo

# --- 5. remoteRef.property <-> seed-script key contract ---------------------------------------
# Grafana expands an unset environment variable to an empty string rather than erroring, so a
# renamed key on either side of this contract -- the ExternalSecret's remoteRef.property, or the
# JSON key scripts/seed-grafana-secret.sh actually writes into voteball/grafana -- yields an empty
# password/token with Grafana healthy throughout. Proven: renaming db_password -> dbpassword on one
# side passed this file's other checks at rc=0.
echo "5. remoteRef.property <-> seed script key contract"
properties=$(grep -hoE 'property:[[:space:]]*[A-Za-z0-9_]+' "$ES" "$VOTEBALL_ES" \
             | sed -E 's/^property:[[:space:]]*//' | sort -u)
[ -n "$properties" ] || fail "no remoteRef.property keys found in $ES or $VOTEBALL_ES -- did the field name change?"
written=$(grep -oE '"[A-Za-z0-9_]+":[[:space:]]*os\.environ' "$SEED_SCRIPT" \
          | sed -E 's/^"([A-Za-z0-9_]+)".*/\1/' | sort -u)
[ -n "$written" ] || fail "no JSON keys found in $SEED_SCRIPT's payload -- did its shape change?"
for p in $properties; do
  match=0
  while IFS= read -r w; do
    [ "$w" = "$p" ] && { match=1; break; }
  done <<< "$written"
  if [ "$match" = 1 ]; then
    ok "property $p is written by $SEED_SCRIPT"
  else
    fail "property $p is read by an ExternalSecret but $SEED_SCRIPT never writes that key"
  fi
done
if [ "$fails" -gt 0 ]; then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASSED"
