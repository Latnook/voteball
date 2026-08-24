#!/usr/bin/env bash
# CI gate for observability configuration. Every check here corresponds to a mistake this repository
# has actually made, and each one failed SILENTLY when it was made -- the object applied cleanly, the
# dashboard rendered, the rule appeared in `kubectl get`, and nothing worked.
#
# Runs offline against rendered chart output. No cluster, no credentials.
set -uo pipefail

CHARTS="${CHARTS:-charts/voteball charts/observability}"
SERVICES_DIR="${SERVICES_DIR:-services}"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

status=0
fail() { echo "FAIL: $*" >&2; status=1; }

# 1. Everything the Prometheus operator must SEE carries the release label.
#    Without it the object is created, `kubectl get` lists it, and Prometheus ignores it forever.
# 2. Every ServiceMonitor endpoint names a port that exists on the Service it selects.
#    A port name typo yields a monitor with zero targets, which looks identical to a healthy one.
# 3. No application metric label may collide with a prometheus-operator TARGET label.
#    On 2026-08-18 `endpoint` collided: the operator's target label won, the app's own label was
#    renamed `exported_endpoint`, every SLI matched nothing, and availability reported a constant 1
#    from its fallback. A total outage would have shown as green 100%.
# 4. Every dashboard parses, has a uid and title, and every panel has a non-empty query.

command -v helm >/dev/null 2>&1 || { echo "FAIL: helm is not on PATH -- cannot render charts to validate" >&2; exit 1; }

# --- Render every chart. Same working-directory-relative convention as validate-repo.sh, so a test
# can point CHARTS at a throwaway scaffold instead of the real repo. ---
RENDERED_FILES=()
CHART_DIRS=()
for chart in $CHARTS; do
  [ -d "$chart" ] || { fail "$chart does not exist"; continue; }
  name="$(basename "$chart")"
  out="$RENDER_DIR/${name}.yaml"
  err="$RENDER_DIR/${name}.err"
  if ! helm template "$name" "$chart" --namespace devops-app > "$out" 2>"$err"; then
    fail "helm template $chart failed -- nothing under it could be checked:"
    sed 's/^/  /' "$err" >&2
    continue
  fi
  RENDERED_FILES+=("$out")
  CHART_DIRS+=("$chart")
done

if [ "${#RENDERED_FILES[@]}" -eq 0 ]; then
  echo "FAIL: no chart rendered -- cannot validate observability config" >&2
  exit 1
fi

RULES_OUT="$RENDER_DIR/extracted-rules.yaml"

# --- Checks 1-4, in one Python pass over the rendered YAML (checks 1-3) and the dashboard JSON
# sources (check 4). PyYAML is used the way test-jenkins-chart.sh already relies on it elsewhere in
# this repo's test suite. ---
PY_OUT="$RENDER_DIR/py.out"
RESERVED_LABELS='endpoint job namespace pod service container instance' \
SERVICES_DIR="$SERVICES_DIR" \
RULES_OUT="$RULES_OUT" \
python3 - "${RENDERED_FILES[@]}" -- "${CHART_DIRS[@]}" > "$PY_OUT" <<'PYEOF'
import os, sys, json, yaml

argv = sys.argv[1:]
split = argv.index("--")
rendered_files = argv[:split]
chart_dirs = argv[split + 1:]

RESERVED = set(os.environ["RESERVED_LABELS"].split())
SERVICES_DIR = os.environ["SERVICES_DIR"]
RULES_OUT = os.environ["RULES_OUT"]

failures = []
notes = []


def fail(msg):
    failures.append(msg)


def note(msg):
    notes.append(msg)


# Load every rendered document, tagged with which chart file it came from.
docs = []
for path in rendered_files:
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if doc:
                docs.append((path, doc))

# ---------------------------------------------------------------------------
# Check 1: every ServiceMonitor / PodMonitor / PrometheusRule carries
# `release: kube-prometheus-stack`. kube-prometheus-stack's Prometheus CR sets
# serviceMonitorSelectorNilUsesHelmValues / ruleSelectorNilUsesHelmValues true by default, so anything
# missing this label is invisible to Prometheus even though `kubectl get` lists it fine.
# ---------------------------------------------------------------------------
WATCHED_KINDS = {"ServiceMonitor", "PodMonitor", "PrometheusRule"}
for path, doc in docs:
    kind = doc.get("kind")
    if kind not in WATCHED_KINDS:
        continue
    name = doc.get("metadata", {}).get("name", "<unnamed>")
    labels = doc.get("metadata", {}).get("labels") or {}
    if labels.get("release") != "kube-prometheus-stack":
        fail(
            f"{kind} '{name}' ({os.path.basename(path)}) is missing labels.release: "
            f"kube-prometheus-stack -- it will apply cleanly, `kubectl get {kind.lower()}s` will list "
            f"it, and Prometheus will never evaluate or scrape it. Add the label."
        )

# ---------------------------------------------------------------------------
# Check 2: every ServiceMonitor endpoint names a port that exists on the Service it selects.
# A typo here produces a monitor with zero targets -- indistinguishable from a healthy one in
# `kubectl get servicemonitors`.
# ---------------------------------------------------------------------------
services = [
    (path, doc) for path, doc in docs if doc.get("kind") == "Service"
]


def service_matches(service_doc, match_labels):
    svc_labels = service_doc.get("metadata", {}).get("labels") or {}
    return all(svc_labels.get(k) == v for k, v in match_labels.items())


servicemonitors = [(path, doc) for path, doc in docs if doc.get("kind") == "ServiceMonitor"]

for path, sm in servicemonitors:
    name = sm.get("metadata", {}).get("name", "<unnamed>")
    match_labels = (sm.get("spec", {}).get("selector", {}) or {}).get("matchLabels") or {}
    matched_services = [
        svc for _, svc in services if match_labels and service_matches(svc, match_labels)
    ]

    endpoints = sm.get("spec", {}).get("endpoints") or []
    if not matched_services:
        # No Service rendered in this run selects this ServiceMonitor -- can genuinely happen when a
        # ServiceMonitor targets a Service owned by a chart this run did not render (e.g. a
        # third-party release). Cannot verify the port name from here; say so rather than staying
        # silent about the gap.
        note(
            f"ServiceMonitor '{name}' ({os.path.basename(path)}) selects {match_labels or '<no selector>'}, "
            f"which matches no Service in the rendered output -- its endpoint port name(s) could not "
            f"be verified against a real Service by this run."
        )
        continue

    known_port_names = set()
    for svc in matched_services:
        for p in svc.get("spec", {}).get("ports") or []:
            if p.get("name"):
                known_port_names.add(p["name"])

    for i, ep in enumerate(endpoints):
        port_name = ep.get("port")
        if not port_name:
            fail(
                f"ServiceMonitor '{name}' ({os.path.basename(path)}) endpoint[{i}] names no port at "
                f"all -- prometheus-operator cannot resolve it to anything, and the monitor scrapes "
                f"nothing."
            )
        elif port_name not in known_port_names:
            fail(
                f"ServiceMonitor '{name}' ({os.path.basename(path)}) endpoint[{i}] names port "
                f"'{port_name}', which does not exist on the Service(s) it selects "
                f"(known port names: {sorted(known_port_names) or 'none'}). This produces a monitor "
                f"with zero targets that looks identical to a healthy one in `kubectl get "
                f"servicemonitors` -- fix the port name or the Service's port name."
            )

# ---------------------------------------------------------------------------
# Check 3: no application metric label may collide with a prometheus-operator TARGET label.
# Reserved target labels: endpoint, job, namespace, pod, service, container, instance. A
# ServiceMonitor endpoint without honorLabels: true scraping a target whose /metrics emits one of
# these has the operator's value win silently -- the app's own label is renamed `exported_<name>`
# and every query filtering on the original name matches nothing. This is exactly what happened to
# `endpoint` on 2026-08-18: every SLI went empty and availability reported a constant 1 from its
# fallback -- a total outage would have rendered as green 100%.
#
# Where the target is instrumented in this repo (services/<app>/metrics.py), the label set is read
# directly from the prometheus_client Counter/Histogram/Gauge/Summary calls and a real collision
# without honorLabels is a hard FAIL. Where the target is not in-repo code (a third-party exporter,
# e.g. the frontend's nginx-prometheus-exporter sidecar), the label set cannot be introspected from
# the chart alone -- per the plan, the floor here is to flag any such endpoint without
# honorLabels: true for manual review, which does not fail the build on its own.
#
# CRITICAL: "found a metric call and could not statically read its label list" must produce the SAME
# advisory outcome as "no metrics.py at all" -- never silence. prometheus_client accepts the label
# list either positionally (the 3rd constructor argument) or as the `labelnames=` keyword, and either
# form can be written as something this static parser cannot resolve (a variable, a comprehension, a
# module-level constant). Treating an unresolved label-list argument as "no labels" is exactly the
# blind spot that let a `labelnames=[...]`-style collision (the real 2026-08-18 `endpoint` shape)
# through silently as a false "all checks passed" -- reported clean because the check failed to look.
# ---------------------------------------------------------------------------
import ast


def _read_literal_str_list(node):
    """A List/Tuple of only string constants -> the set of strings. Anything else -> None, meaning
    "not something we can read literally" (a variable, a call, a comprehension, a mixed list, ...)."""
    if not isinstance(node, (ast.List, ast.Tuple)):
        return None
    vals = set()
    for elt in node.elts:
        if not (isinstance(elt, ast.Constant) and isinstance(elt.value, str)):
            return None
        vals.add(elt.value)
    return vals


def metric_call_labels(node):
    """Try to statically read one Counter/Histogram/Gauge/Summary call's label-list argument.

    Returns (labels, resolved):
      - resolved=True,  labels=set()   : no label-list argument in ANY form -- prometheus_client's
                                          signature is (name, documentation, labelnames=(), ...), so
                                          this is a genuinely label-free metric, fully verified (this
                                          repo has real examples, e.g. VOTES_CAST in the backend).
      - resolved=True,  labels={...}   : a literal list/tuple of string constants was found, either
                                          positionally (3rd arg) or as `labelnames=` -- fully verified,
                                          whatever it contains.
      - resolved=False                 : a label-list argument is PRESENT in some form but isn't a
                                          literal this parser can read. Cannot tell what it contains.
    """
    if len(node.args) >= 3:
        got = _read_literal_str_list(node.args[2])
        return (got, True) if got is not None else (set(), False)
    for kw in node.keywords:
        if kw.arg == "labelnames":
            got = _read_literal_str_list(kw.value)
            return (got, True) if got is not None else (set(), False)
    return set(), True


def metric_labels(py_path):
    """(labels, unresolved) for every recognised metric constructor call in py_path. unresolved=True
    means at least one call's label list could not be statically determined -- including the file not
    parsing at all -- and the caller must treat that the same as having no metrics.py to look at."""
    labels = set()
    unresolved = False
    try:
        tree = ast.parse(open(py_path).read())
    except (OSError, SyntaxError):
        return labels, True
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        fname = getattr(node.func, "id", None) or getattr(node.func, "attr", None)
        if fname not in ("Counter", "Histogram", "Gauge", "Summary"):
            continue
        got, resolved = metric_call_labels(node)
        if resolved:
            labels |= got
        else:
            unresolved = True
    return labels, unresolved


for path, sm in servicemonitors:
    name = sm.get("metadata", {}).get("name", "<unnamed>")
    match_labels = (sm.get("spec", {}).get("selector", {}) or {}).get("matchLabels") or {}
    app = match_labels.get("app") or sm.get("metadata", {}).get("name", "<unknown>")
    metrics_path = os.path.join(SERVICES_DIR, app, "metrics.py")
    introspectable = os.path.isfile(metrics_path)
    if introspectable:
        app_labels, unresolved = metric_labels(metrics_path)
    else:
        app_labels, unresolved = set(), False
    verified = introspectable and not unresolved

    for i, ep in enumerate(sm.get("spec", {}).get("endpoints") or []):
        if ep.get("honorLabels") is True:
            continue  # satisfies the check regardless of what the target emits
        port_name = ep.get("port")
        if verified:
            collision = app_labels & RESERVED
            if collision:
                fail(
                    f"ServiceMonitor '{name}' ({os.path.basename(path)}) endpoint[{i}] (port="
                    f"{port_name}) has no honorLabels: true, and {metrics_path} defines metric "
                    f"label(s) {sorted(collision)} that collide with prometheus-operator's own "
                    f"TARGET label of the same name. The operator's value wins silently: the app's "
                    f"label is renamed 'exported_{sorted(collision)[0]}' and every PromQL query "
                    f"filtering on the original name matches nothing -- this is the exact 2026-08-18 "
                    f"failure (availability reported a constant 1 from its fallback while the SLI was "
                    f"empty). Add honorLabels: true to this endpoint."
                )
            # else: every metric call's label list was statically readable and none of them collide
            # -- genuinely verified clean, nothing to flag.
        elif introspectable:
            # unresolved: metrics.py exists and was found, but at least one metric's label-list
            # argument could not be read literally -- "found a metric and couldn't tell" is the SAME
            # state as "no metrics.py", not "no labels".
            note(
                f"ServiceMonitor '{name}' ({os.path.basename(path)}) endpoint[{i}] (port={port_name}) "
                f"has no honorLabels: true, and {metrics_path} declares a metric whose label list "
                f"could not be statically determined (labelnames= or a positional label list built "
                f"from something other than a literal list of strings, or the file itself did not "
                f"parse) -- flagged for manual review: confirm its /metrics output carries none of "
                f"{sorted(RESERVED)} before trusting this endpoint's data."
            )
        else:
            note(
                f"ServiceMonitor '{name}' ({os.path.basename(path)}) endpoint[{i}] (port={port_name}) "
                f"has no honorLabels: true and no in-repo {metrics_path} exists to verify its label "
                f"set against (likely a third-party exporter) -- flagged for manual review: confirm "
                f"its /metrics output carries none of {sorted(RESERVED)} before trusting this "
                f"endpoint's data."
            )

# ---------------------------------------------------------------------------
# Check 4: every dashboard parses, has a uid and title, and every panel has a non-empty query.
# Read straight from the dashboard JSON sources (charts/observability/dashboards/*.json and any
# equivalent dashboards/ directory under the other rendered charts) -- that is the file the Grafana
# sidecar provisions verbatim from the ConfigMap this chart wraps it in, so checking it directly is
# equivalent to checking the rendered ConfigMap and avoids re-parsing YAML-embedded JSON text.
# ---------------------------------------------------------------------------
dashboard_files = []
for chart_dir in chart_dirs:
    dpath = os.path.join(chart_dir, "dashboards")
    if os.path.isdir(dpath):
        for fn in sorted(os.listdir(dpath)):
            if fn.endswith(".json"):
                dashboard_files.append(os.path.join(dpath, fn))

for dpath in dashboard_files:
    try:
        with open(dpath) as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        fail(f"dashboard {dpath} does not parse as JSON: {e}")
        continue

    if not d.get("uid"):
        fail(f"dashboard {dpath} has no 'uid' -- Grafana cannot provision it as a stable dashboard.")
    if not d.get("title"):
        fail(f"dashboard {dpath} has no 'title' -- it renders as an unlabelled dashboard in the list.")

    # Each data source type names its "this panel has a real query" field differently -- Prometheus
    # panels carry `expr`, PostgreSQL panels carry `rawSql`, CloudWatch metric panels carry
    # `metricName` (alongside `namespace`), CloudWatch Logs panels carry `expression` (alongside
    # `logGroups`), and GitHub panels carry `queryType` (Commits/Contributors/Issues/...). A panel
    # counts as having a query if ANY of these recognised fields is non-empty on ANY of its targets;
    # a panel whose targets carry none of them still fails, same as an empty-`expr` Prometheus panel
    # always did.
    QUERY_FIELDS = ("expr", "rawSql", "metricName", "expression", "queryType")

    def target_query(t):
        for key in QUERY_FIELDS:
            v = t.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
        return ""

    def check_panel(panel):
        if panel.get("type") == "row":
            # A row panel itself legitimately carries no query. But a COLLAPSED row nests its child
            # panels inside its own "panels" list instead of at the dashboard's top level -- descend
            # into them, or a query-less panel hidden inside a collapsed row passes unseen. None of
            # this repo's three dashboards use collapsed rows today; this is future-proofing.
            for child in panel.get("panels") or []:
                check_panel(child)
            return
        targets = panel.get("targets") or []
        queries = [target_query(t) for t in targets if isinstance(t, dict)]
        if not any(queries):
            fail(
                f"dashboard {dpath} panel '{panel.get('title', panel.get('id'))}' has no non-empty "
                f"query -- it renders as an empty panel with no error, indistinguishable from 'no "
                f"data yet'."
            )

    for panel in d.get("panels") or []:
        check_panel(panel)

# ---------------------------------------------------------------------------
# Extract every PrometheusRule's groups for promtool, regardless of how the checks above went --
# `promtool check rules` catches a different class of mistake (bad PromQL, duplicate recording rule
# names) than any check above.
# ---------------------------------------------------------------------------
all_groups = []
for path, doc in docs:
    if doc.get("kind") != "PrometheusRule":
        continue
    all_groups.extend((doc.get("spec") or {}).get("groups") or [])

with open(RULES_OUT, "w") as f:
    yaml.safe_dump({"groups": all_groups}, f)

for n in notes:
    print(f"NOTE: {n}")
for m in failures:
    print(f"FAIL: {m}")

sys.exit(1 if failures else 0)
PYEOF
py_status=$?

# Echo Python's NOTE/FAIL lines to the same streams validate-repo.sh uses: notes to stdout, failures
# to stderr (and each failure also flips this script's overall status).
while IFS= read -r line; do
  case "$line" in
    "FAIL: "*) echo "$line" >&2; status=1 ;;
    "NOTE: "*) echo "$line" ;;
  esac
done < "$PY_OUT"

if [ "$py_status" -ne 0 ]; then
  status=1
fi

# --- promtool check rules, when available. A skip must never read like a pass. ---
if command -v promtool >/dev/null 2>&1; then
  if [ -s "$RULES_OUT" ]; then
    if promtool check rules "$RULES_OUT" >"$RENDER_DIR/promtool.out" 2>&1; then
      echo "promtool check rules: PASS"
    else
      fail "promtool check rules failed:"
      sed 's/^/  /' "$RENDER_DIR/promtool.out" >&2
    fi
  else
    echo "promtool check rules: SKIPPED -- no PrometheusRule groups were rendered"
  fi
else
  echo "!!! promtool check rules: SKIPPED -- promtool is not on PATH. This is NOT a pass. Install" >&2
  echo "!!! promtool (part of the prometheus release) or run this in a container that provides it" >&2
  echo "!!! before trusting this run to have checked the PromQL in prometheusrule.yaml." >&2
fi

if [ "$status" -eq 0 ]; then
  echo "validate-observability: all checks passed"
else
  echo "validate-observability: FAILED -- see FAIL lines above" >&2
fi
exit "$status"
