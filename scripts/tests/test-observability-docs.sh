#!/usr/bin/env bash
# Anti-drift gate for docs/observability.md and docs/runbooks/README.md.
#
# WHY THIS EXISTS: the root CLAUDE.md's "Doc claims that drift" section records seven stale claims
# found by two audit passes, and EVERY ONE was mechanically checkable -- a stage list, a step count,
# a test count, a field count. The pattern is always the same: a pass on one concern changes a chart,
# and a document describing that chart from a different angle is not touched, because nothing forces
# it to be. docs/observability.md states more countable facts than any other document here (16
# alerts, 3 dashboards, 4 recording rules, one runbook per alert), so it would drift faster than any
# of them.
#
# A documentation rule enforced only by whoever remembers it is not a check. This is the check.
#
# Offline: reads the repository's own files, renders nothing, needs no cluster. Deliberately uses
# bash + grep + sed + awk ONLY -- no python3, no git, no helm -- so it runs in either CI container.
#
# WHAT IT DOES NOT DO: it does not read prose. It cannot tell you the description of an alert is
# wrong, only that the SET of alerts and the COUNTS stated about them still agree with the charts.
# That is the half that rots silently; a wrong sentence at least reads as wrong.
set -uo pipefail

cd "$(dirname "$0")/../.."   # repo root

DOC=docs/observability.md
RUNBOOK_INDEX=docs/runbooks/README.md
RUNBOOK_DIR=docs/runbooks
APP_RULES=charts/voteball/templates/prometheusrule.yaml
PLATFORM_RULES=charts/observability/templates/prometheusrule.yaml
DASHBOARD_DIR=charts/observability/dashboards

fails=0
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
ok()   { echo "  ok   $*"; }

for f in "$DOC" "$RUNBOOK_INDEX" "$APP_RULES" "$PLATFORM_RULES"; do
  [ -f "$f" ] || { echo "FAIL: $f not found -- has it been renamed?" >&2; exit 1; }
done
[ -d "$RUNBOOK_DIR" ]   || { echo "FAIL: $RUNBOOK_DIR not found" >&2; exit 1; }
[ -d "$DASHBOARD_DIR" ] || { echo "FAIL: $DASHBOARD_DIR not found" >&2; exit 1; }

# --- The ground truth: what the charts actually declare ------------------------------------------
# `- alert: Name`. The charts are Helm templates, but every alert NAME is a literal -- none is
# templated -- so a plain grep is exact here and needs no helm.
chart_alerts() { grep -hoE '^[[:space:]]*-[[:space:]]*alert:[[:space:]]*[A-Za-z][A-Za-z0-9]*' "$@" \
                   | sed -E 's/.*alert:[[:space:]]*//' | sort -u; }

APP_ALERTS="$(chart_alerts "$APP_RULES")"
PLATFORM_ALERTS="$(chart_alerts "$PLATFORM_RULES")"
ALL_ALERTS="$(printf '%s\n%s\n' "$APP_ALERTS" "$PLATFORM_ALERTS" | sort -u)"

n_app=$(printf '%s\n' "$APP_ALERTS" | grep -c . )
n_platform=$(printf '%s\n' "$PLATFORM_ALERTS" | grep -c . )
n_total=$(printf '%s\n' "$ALL_ALERTS" | grep -c . )

# Recording rules: `- record: name`.
SLI_RULES="$(grep -hoE '^[[:space:]]*-[[:space:]]*record:[[:space:]]*[A-Za-z][A-Za-z0-9_:]*' "$APP_RULES" \
               | sed -E 's/.*record:[[:space:]]*//' | sort -u)"
n_sli=$(printf '%s\n' "$SLI_RULES" | grep -c . )

n_dash=$(find "$DASHBOARD_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')

[ "$n_app" -gt 0 ] && [ "$n_platform" -gt 0 ] && [ "$n_sli" -gt 0 ] && [ "$n_dash" -gt 0 ] || {
  echo "FAIL: extracted 0 alerts, recording rules or dashboards -- the file format changed and every" >&2
  echo "      check below would pass vacuously. Fix the extraction before trusting this test." >&2
  exit 1
}

echo "==> charts declare: $n_app application + $n_platform platform = $n_total alerts, $n_sli recording rules, $n_dash dashboards"
echo

# --- 1. Every alert has a runbook, and every runbook has an alert --------------------------------
# The PDF requires each alert to carry a runbook reference, and every rule here sets runbook_url. A
# link to a file that does not exist arrives in the email that wakes someone up, at the worst
# possible moment to discover it.
echo "1. one runbook per alert, one alert per runbook"
while IFS= read -r a; do
  [ -n "$a" ] || continue
  if [ -f "$RUNBOOK_DIR/$a.md" ]; then ok "$a -> $RUNBOOK_DIR/$a.md"
  else fail "$a has no runbook at $RUNBOOK_DIR/$a.md"; fi
done <<< "$ALL_ALERTS"

for rb in "$RUNBOOK_DIR"/*.md; do
  name="$(basename "$rb" .md)"
  [ "$name" = "README" ] && continue
  printf '%s\n' "$ALL_ALERTS" | grep -qx "$name" \
    || fail "$rb describes '$name', which is not an alert in either chart (renamed or deleted?)"
done
echo

# --- 2. Every runbook_url resolves to a file that exists -----------------------------------------
# Checks the ANNOTATION rather than inferring the path from the alert name: the two can disagree,
# and it is the annotation that is actually sent.
echo "2. every runbook_url annotation points at a file that exists"
grep -hoE 'runbook_url:[[:space:]]*"[^"]+"' "$APP_RULES" "$PLATFORM_RULES" \
  | sed -E 's|.*/docs/runbooks/||; s/"$//' | sort -u \
  | while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -f "$RUNBOOK_DIR/$rel" ]; then ok "runbooks/$rel"
      else echo "  FAIL runbook_url points at $RUNBOOK_DIR/$rel, which does not exist"; fi
    done
# The subshell above cannot increment `fails`, so re-derive the verdict here.
missing_urls=$(grep -hoE 'runbook_url:[[:space:]]*"[^"]+"' "$APP_RULES" "$PLATFORM_RULES" \
  | sed -E 's|.*/docs/runbooks/||; s/"$//' | sort -u \
  | while IFS= read -r rel; do [ -f "$RUNBOOK_DIR/$rel" ] || echo x; done | grep -c . )
[ "$missing_urls" -eq 0 ] || fails=$((fails + missing_urls))
echo

# --- 3. docs/observability.md's two alert tables list exactly the charts' alerts ------------------
# The tables live under headings naming the file they describe. Rows are `| `AlertName` | ... |`.
doc_table_alerts() { # $1 = heading substring
  awk -v key="$1" '
    index($0, key) && /^###/ { inside = 1; next }
    inside && /^#/           { inside = 0 }
    inside && /^\|[[:space:]]*`/ {
      if (match($0, /`[A-Za-z][A-Za-z0-9]*`/))
        print substr($0, RSTART + 1, RLENGTH - 2)
    }
  ' "$DOC" | sort -u
}

echo "3. $DOC alert tables match the charts"
for pair in "charts/voteball/templates/prometheusrule.yaml|$APP_ALERTS" \
            "charts/observability/templates/prometheusrule.yaml|$PLATFORM_ALERTS"; do
  key="${pair%%|*}"; expected="${pair#*|}"
  listed="$(doc_table_alerts "$key")"
  if [ "$listed" = "$expected" ]; then
    ok "table for $key lists all $(printf '%s\n' "$expected" | grep -c .)"
  else
    fail "table for $key disagrees with the chart:"
    printf '%s\n' "$expected" > /tmp/.obsdoc-expected.$$
    printf '%s\n' "$listed"   > /tmp/.obsdoc-listed.$$
    comm -23 /tmp/.obsdoc-expected.$$ /tmp/.obsdoc-listed.$$ | sed 's/^/         in the chart, missing from the doc: /'
    comm -13 /tmp/.obsdoc-expected.$$ /tmp/.obsdoc-listed.$$ | sed 's/^/         in the doc, not in the chart:     /'
    rm -f /tmp/.obsdoc-expected.$$ /tmp/.obsdoc-listed.$$
  fi
done
echo

# --- 4. docs/runbooks/README.md's index lists every alert ----------------------------------------
# That table is the other place the full alert set is written out. It drifts for the same reason.
echo "4. $RUNBOOK_INDEX indexes every alert"
while IFS= read -r a; do
  [ -n "$a" ] || continue
  grep -q "\[$a\]($a\.md)" "$RUNBOOK_INDEX" \
    && ok "$a" || fail "$a is missing from the table in $RUNBOOK_INDEX"
done <<< "$ALL_ALERTS"
echo

# --- 5. Every count stated in prose ---------------------------------------------------------------
# Each entry is a phrase the document MUST contain, built from a value computed above. A reworded
# sentence fails here on purpose: the phrase and the number have to be re-checked together, which is
# the entire point. Update the list when you deliberately change the wording.
echo "5. every count stated in $DOC"
require_phrase() { # $1 = phrase, $2 = what it claims
  if grep -qF -- "$1" "$DOC"; then ok "\"$1\" ($2)"
  else fail "$DOC must contain \"$1\" ($2) -- the number moved, or the sentence was reworded"; fi
}
require_phrase "**$n_total alerts"                                            "total alert count"
require_phrase "prometheusrule.yaml\` ($n_app)"                               "application alert count, heading"
require_phrase "prometheusrule.yaml\` ($n_platform)"                          "platform alert count, heading"
require_phrase "the $n_app application alerts"                                "application alert count, §2"
require_phrase "the $n_platform platform alerts"                              "platform alert count, §2"
require_phrase "the $n_sli SLI recording rules"                               "recording-rule count, §2"
require_phrase "The $n_dash dashboards"                                       "dashboard count, §2"
require_phrase "($n_total alerts)"                                            "alert count, §1 diagram"
require_phrase "($n_sli SLIs)"                                                "SLI count, §1 diagram"
echo

# --- 6. Recording rules, dashboards: name, uid and panel count ------------------------------------
echo "6. recording rules and dashboards named in $DOC"
while IFS= read -r r; do
  [ -n "$r" ] || continue
  grep -qF -- "$r" "$DOC" && ok "recording rule $r" || fail "recording rule $r is not mentioned in $DOC"
done <<< "$SLI_RULES"

for d in "$DASHBOARD_DIR"/*.json; do
  # A dashboard's uid is what Grafana and every deep link key on, so it is the identity worth
  # checking. Panels are counted by "gridPos", which every panel carries exactly one of -- no JSON
  # parser needed, and confirmed against the three live dashboards.
  uid="$(grep -oE '"uid"[[:space:]]*:[[:space:]]*"[^"]+"' "$d" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  panels=$(grep -c '"gridPos"' "$d")
  [ -n "$uid" ] || { fail "$(basename "$d") has no uid"; continue; }
  grep -qF -- "\`$uid\`" "$DOC" && ok "dashboard uid $uid" || fail "dashboard uid \`$uid\` is not in $DOC"
  grep -qE "\`$uid\`[^|]*\|[[:space:]]*$panels[[:space:]]*\|" "$DOC" \
    && ok "dashboard $uid panel count ($panels)" \
    || fail "$DOC's row for \`$uid\` does not say $panels panels"
done
echo

# --- 7. No LIVE document cites an alert that does not exist --------------------------------------
# Found on 2026-08-20: `VoteballDeploymentDegraded` was renamed to DeploymentReplicasMismatch and
# moved to charts/observability during the 2026-08-17 pass, and three documents kept citing the old
# name -- including a runbook-adjacent sentence telling the reader which alert would page them. A
# doc naming an alert that cannot fire is worse than an omission: it reads as coverage.
#
# Only tokens beginning `Voteball` are checked, and only inside backticks. That prefix is this repo's
# alert namespace and nothing else -- metrics are lowercase (voteball_http_requests_total), the Helm
# release is lowercase, and the chart directory is lowercase. Verified 2026-08-20: every backticked
# `Voteball<Capital>` token in every .md in this repo was an alert name, with no false positives.
# Platform alerts (NodeNotReady..., DeploymentReplicasMismatch, PrometheusTargetDown,
# JenkinsQueueStuck) are deliberately NOT matched -- those prefixes collide with upstream rule names
# and CRD kinds that documents legitimately discuss.
#
# DATED RECORDS ARE EXEMPT, and that is not an oversight. The root CLAUDE.md is explicit that
# docs/design/*, docs/eks/live-cluster-snapshot.md and docs/eks/evidence/* are frozen evidence which
# must NOT be "corrected" -- a design doc recording that an alert existed under an older name, or a
# snapshot of a cluster as it was, is accurate precisely because it still says the old thing.
echo "7. no live document cites a non-existent alert"
LIVE_DOCS=$(find docs README.md README.submission.md -name '*.md' 2>/dev/null \
  | grep -v '^docs/design/' | grep -v '^docs/eks/live-cluster-snapshot.md' | grep -v '^docs/eks/evidence/' \
  | sort)
[ -n "$LIVE_DOCS" ] || { echo "FAIL: found no live documents to scan" >&2; exit 1; }

cited=$(grep -ohE '`Voteball[A-Z][A-Za-z0-9]*`' $LIVE_DOCS | tr -d '`' | sort -u)
if [ -z "$cited" ]; then
  fail "no \`Voteball*\` alert citations found in any live document -- has the naming convention changed?"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if printf '%s\n' "$ALL_ALERTS" | grep -qx "$c"; then
      ok "$c"
    else
      fail "\`$c\` is cited but is not an alert in either chart. Cited in:"
      grep -ln "\`$c\`" $LIVE_DOCS | sed 's/^/         /'
    fi
  done <<< "$cited"
fi
echo

if [ "$fails" -gt 0 ]; then
  echo "FAIL: $fails observability-documentation check(s) failed." >&2
  echo "      Update docs/observability.md (and docs/runbooks/) in the SAME commit as the chart change." >&2
  exit 1
fi
echo "PASS — observability documentation is in step with the charts"
