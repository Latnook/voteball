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
# that no data source declares renders an empty panel, not an error.
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
for v in $vars; do
  if grep -q "secretKey: $v" "$ES"; then
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

if [ -d "$DASHBOARD_DIR" ]; then
  used=$(grep -rhoE '"uid":[[:space:]]*"[a-z0-9-]+"' "$DASHBOARD_DIR" \
           | sed -E 's/.*"uid":[[:space:]]*"([a-z0-9-]+)"/\1/' | sort -u)
  for u in $used; do
    # A dashboard's OWN uid also matches this pattern; only flag ones that look like data sources,
    # i.e. those appearing inside a "datasource" object. Grep the enclosing key to be sure.
    if grep -rqE "\"datasource\":[[:space:]]*\{[^}]*\"uid\":[[:space:]]*\"$u\"" "$DASHBOARD_DIR"; then
      if echo "$declared" | grep -qx "$u"; then
        ok "dashboard data source uid $u is declared"
      else
        fail "a dashboard panel uses data source uid \"$u\", which no data source declares"
      fi
    fi
  done
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASSED"
