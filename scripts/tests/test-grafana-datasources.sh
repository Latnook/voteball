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

# --- 2. Both Secrets are projected into the pod, EACH marked OPTIONAL, EACH targeted by its own ---
# ExternalSecret ------------------------------------------------------------------------------------
# Must be the PLURAL `envFromSecrets` (a list of objects), not the singular `envFromSecret` (a bare
# name) -- only the plural form supports `optional`, and each Secret is created only when its own
# ExternalSecret is enabled (charts/observability/values.yaml's dbEnabled/githubEnabled), so a
# mandatory projection takes Grafana down the moment either one is not yet enabled. Deliberately NOT
# loosened to accept the singular form or an entry missing `optional: true` -- either of those is the
# exact regression this check exists to catch.
#
# TWO Secrets, not one: charts/observability/templates/externalsecret.yaml splits what used to be a
# single two-key ExternalSecret (grafana-datasources, both db_password and github_token) into two
# independent ones -- ESO fails an ExternalSecret's ENTIRE sync if any one `data` entry cannot be
# resolved, so the combined resource took the PostgreSQL data source down on any deploy with no
# GitHub token supplied (the normal, unattended case -- the token is optional). Checked per-entry
# (not "optional = true appears somewhere in the block") so one entry missing it cannot hide behind
# the other having it.
echo "2. envFromSecrets wiring (plural, optional, one entry per Secret)"
block=$(awk '/envFromSecrets[[:space:]]*=[[:space:]]*\[/{flag=1} flag{print} flag && /\]/{exit}' "$TF")
if [ -z "$block" ]; then
  fail "$TF does not set grafana.envFromSecrets (plural) at all"
else
  for secret_name in grafana-datasources grafana-datasources-github; do
    # The single { ... } object naming this secret -- accumulated between the nearest "{" and the
    # matching "}", so `optional = true` is checked WITHIN that one entry, never borrowed from the
    # other entry sitting elsewhere in the same list.
    # The closing quote in `want` is itself the boundary: "grafana-datasources" (with its trailing
    # quote) does not match inside "grafana-datasources-github" because a literal `-github` sits
    # between the prefix and ITS closing quote, so no extra end-of-token anchor is needed -- and none
    # was used, deliberately, after an anchor of `([ \t]|$)` was tried and failed here: `$` in awk's
    # ERE anchors the end of the whole (multi-line) `buf` string, not the end of a line within it, so
    # it never matched the name line at all.
    entry=$(awk -v want="\"${secret_name}\"" '
      /\{/ { buf="" }
      { buf = buf $0 "\n" }
      /\}/ {
        if (buf ~ ("name[ \t]*=[ \t]*" want)) { print buf }
        buf = ""
      }
    ' <<<"$block")
    if [ -z "$entry" ]; then
      fail "$TF's envFromSecrets block does not name the ${secret_name} Secret"
    elif ! echo "$entry" | grep -q 'optional[[:space:]]*=[[:space:]]*true'; then
      fail "$TF's envFromSecrets entry for ${secret_name} is missing optional = true -- this takes Grafana down the moment that Secret's ExternalSecret is not yet enabled"
    else
      ok "terraform projects the ${secret_name} Secret via envFromSecrets, marked optional"
    fi
  done
fi
# Bounded by whitespace/EOL (never a bare substring match) so "grafana-datasources" cannot match the
# "grafana-datasources-github" target line -- a plain substring check here would report the db target
# present even if only the github one existed. Allows a trailing inline comment (the target lines
# carry one) or end of line.
if grep -qE 'name: grafana-datasources([[:space:]]|$)' "$ES"; then
  ok "an ExternalSecret targets the grafana-datasources Secret"
else
  fail "$ES has no ExternalSecret targeting a Secret named grafana-datasources"
fi
if grep -qE 'name: grafana-datasources-github([[:space:]]|$)' "$ES"; then
  ok "an ExternalSecret targets the grafana-datasources-github Secret"
else
  fail "$ES has no ExternalSecret targeting a Secret named grafana-datasources-github"
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
