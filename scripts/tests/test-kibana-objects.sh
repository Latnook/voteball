#!/usr/bin/env bash
# charts/logging/kibana/*.json -- the data view, saved searches and dashboard that make Kibana show
# something. Offline: `helm template` only, no cluster.
#
# The failure this file guards against is the one this repo keeps finding: a name that is a silent
# contract with something off-screen. A panel aggregating on `http_path.keyword` when the parser
# emits `path`, a dashboard referencing a panel id that is not in the file, a saved object with no
# version stamp -- none of these produce an error. They produce an empty panel, an error card, or an
# HTTP 500 buried in the Kibana server log, and all three read like "there is nothing to show".
#
# Every check here therefore compares TWO SIDES that must agree, rather than asserting one side
# looks reasonable.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> charts/logging Kibana saved objects"

# Read the AUTHORED files, not `helm template` output, so this runs in CI's python container (no
# helm there, and run-ci-suite.sh's SKIP list already neutralises three chart tests for that reason).
# The round-trip check below needs a real render, so it runs only when helm is present -- and says
# so, rather than passing silently on a check it did not perform.
fd="$(cat charts/logging/templates/fluentd.yaml)" || fail "missing fluentd template"
if command -v helm >/dev/null 2>&1; then
  cm="$(helm template logging charts/logging --namespace logging \
    --show-only templates/kibana-objects.yaml)" || fail "helm template failed"
else
  cm=""
fi

CM="$cm" FD="$fd" python3 - <<'PY'
import json, os, re, sys, glob

def die(m): print(f"FAIL: {m}", file=sys.stderr); sys.exit(1)
def ok(m): print(f"  ok: {m}")

cm, fd = os.environ["CM"], os.environ["FD"]

# --- 1. the Helm JSON -> NDJSON round trip must be lossless -------------------------------------
# The committed file is a pretty JSON array; the ConfigMap holds one compact object per line,
# produced by Helm's fromJsonArray/toJson. That is a re-encode through Go's json package, and a
# re-encode is a place where numbers quietly become floats and a dashboard grid turns into
# {"w":2.4e+01}. Compare the parsed structures, not the text.
sources = sorted(glob.glob("charts/logging/kibana/*.json"))
if not sources:
    die("charts/logging/kibana/*.json is empty -- the ConfigMap would render with no objects and "
        "the import Job would report success over an empty Kibana")
objs = [o for p in sources for o in json.load(open(p))]

if cm:
    lines = [l.strip() for l in cm.splitlines() if l.strip().startswith("{")]
    if len(lines) != len(objs):
        die(f"ConfigMap holds {len(lines)} NDJSON lines but the source files hold {len(objs)} objects")
    for line, src in zip(lines, objs):
        if json.loads(line) != src:
            die(f"Helm's re-encode changed object {src['id']} -- compare {json.dumps(src)[:200]}")
    ok(f"{len(objs)} objects survive the JSON -> NDJSON round trip unchanged")
else:
    print("  ok: (helm absent -- round-trip check NOT performed; every other check below did run)")

by_id = {o["id"]: o for o in objs}
if len(by_id) != len(objs):
    die("duplicate saved-object id -- the second import silently overwrites the first")

# --- 2. every object must carry a version stamp -------------------------------------------------
# Without typeMigrationVersion, /api/saved_objects/_import runs the ENTIRE migration chain from the
# beginning. Proven live on Kibana 9.1.4 (2026-09-07): the import answered HTTP 500 and the reason
# ("Cannot read properties of undefined (reading 'currentIndexPatternId')") appeared only in the
# Kibana server log -- a migration from before Lens renamed its datasource to `formBased`.
for o in objs:
    if not o.get("typeMigrationVersion"):
        die(f"{o['type']}/{o['id']} has no typeMigrationVersion -- _import will run every migration "
            f"from the beginning and answer 500 with the reason only in the Kibana server log")
ok("every object carries a typeMigrationVersion")

# --- 3. every reference must resolve inside the same import -------------------------------------
# A dangling reference imports CLEANLY. Kibana reports success and the panel renders as an error
# card, which is why this is checked here and not left to the import's own exit status.
for o in objs:
    for r in o.get("references", []):
        if r["id"] not in by_id:
            die(f"{o['type']}/{o['id']} references {r['type']}/{r['id']}, which no source file "
                f"defines -- this imports successfully and renders as an error card")
ok("every saved-object reference resolves within the shipped set")

dashboards = [o for o in objs if o["type"] == "dashboard"]
if not dashboards:
    die("no dashboard object -- a data view alone still leaves Kibana's home screen empty")

# Each dashboard panel must have a matching reference, in BOTH directions.
for d in dashboards:
    panels = json.loads(d["attributes"]["panelsJSON"])
    refnames = {r["name"] for r in d["references"]}
    for p in panels:
        want = f"{p['panelIndex']}:{p['panelRefName']}"
        if want not in refnames:
            die(f"dashboard {d['id']} panel {p['panelIndex']} expects reference {want!r}, "
                f"which is missing -- the panel renders as an error card")
    if len(panels) != len(d["references"]):
        die(f"dashboard {d['id']} has {len(panels)} panels but {len(d['references'])} references")
    # Grid: Kibana's dashboard grid is 48 columns. A panel running past the edge is silently
    # wrapped, which is how a carefully described layout arrives looking nothing like the plan.
    for p in panels:
        g = p["gridData"]
        if g["x"] + g["w"] > 48:
            die(f"dashboard {d['id']} panel {p['panelIndex']} spans to column {g['x'] + g['w']} "
                f"(the grid is 48 wide) and will be wrapped")
    ok(f"dashboard {d['id']}: {len(panels)} panels, references and 48-column grid consistent")

# --- 4. THE CROSS-FILE CHECK: panels may only use fields the parser actually produces ------------
# This is the one that catches the defect class the others cannot. charts/logging's Fluentd config
# and its Kibana objects are edited independently, and nothing at runtime connects them: a panel
# aggregating on a field no parser emits returns zero rows with status ok, which is indistinguishable
# from "no errors in the last 24 hours" -- a legitimate result nobody investigates.
parsed = set(re.findall(r"\(\?<([a-zA-Z_][a-zA-Z0-9_]*)>", fd))
if len(parsed) < 10:
    die(f"only {len(parsed)} capture groups found in the rendered fluent.conf -- the parser config "
        f"is not being read correctly, so this whole check is vacuous")
# Fields that arrive already attached by Fluent Bit's kubernetes filter rather than from a capture
# group. Verified against the live index mapping on 2026-09-07; they come from a component outside
# this chart (terraform/addon-cloudwatch.tf), so they cannot be derived from anything here.
FLUENT_BIT = {"log", "stream", "time", "_p", "message",
              "kubernetes.pod_name", "kubernetes.namespace_name", "kubernetes.container_name",
              "kubernetes.container_image", "kubernetes.container_hash", "kubernetes.docker_id",
              "kubernetes.host", "kubernetes.pod_id", "kubernetes.pod_ip",
              "kubernetes.aws_entity_cluster", "kubernetes.aws_entity_platform",
              "kubernetes.aws_entity_workload",
              "aws_entity_account_id", "aws_entity_ec2_instance_id"}
# Lens' pseudo-field for a document count, and Elasticsearch's own metadata fields.
BUILTIN = {"___records___", "_index", "_id", "_score", "_source"}
known = parsed | FLUENT_BIT | BUILTIN

KUERY_WORDS = {"and", "or", "not", "true", "false", "null"}
def check(field, where):
    base = field[:-len(".keyword")] if field.endswith(".keyword") else field
    if base not in known:
        die(f"{where} uses field {field!r}, which no Fluentd pattern emits and Fluent Bit does not "
            f"attach. It would return zero rows with status ok -- identical to 'nothing happened'. "
            f"Parser captures: {', '.join(sorted(parsed))}")

used = q_used = 0
for o in objs:
    a = o["attributes"]
    if o["type"] == "lens":
        for layer in a["state"]["datasourceStates"]["formBased"]["layers"].values():
            for cid, col in layer["columns"].items():
                if col.get("sourceField"):
                    check(col["sourceField"], f"lens/{o['id']} column {cid}"); used += 1
        blob = json.dumps(a["state"])
    elif o["type"] == "search":
        for c in a.get("columns", []):
            check(c, f"search/{o['id']} column"); used += 1
        for f, _ in a.get("sort", []):
            check(f, f"search/{o['id']} sort"); used += 1
        blob = a["kibanaSavedObjectMeta"]["searchSourceJSON"]
    elif o["type"] == "index-pattern":
        check(a["timeFieldName"], f"index-pattern/{o['id']} timeFieldName"); used += 1
        for f in json.loads(a.get("fieldFormatMap", "{}")):
            check(f, f"index-pattern/{o['id']} fieldFormatMap"); used += 1
        continue
    else:
        continue
    # Every KQL string in the object: filters columns, panel queries, saved-search queries.
    #
    # A KQL field is an identifier IMMEDIATELY FOLLOWED BY AN OPERATOR. Matching bare identifiers
    # instead flags the values too: `log_level : (ERROR or CRITICAL)` has one field and two values,
    # and the first version of this check failed on `ERROR`. Anchoring on the operator is also what
    # keeps it from silently skipping everything -- see the vacuity guard below.
    for q in re.findall(r'"query"\s*:\s*"((?:[^"\\]|\\.)*)"', blob):
        q = json.loads(f'"{q}"')
        for tok in re.findall(r"([a-zA-Z_][a-zA-Z0-9_.]*)\s*(?::|>=|<=|>|<)", q):
            if tok.lower() in KUERY_WORDS:
                continue
            check(tok, f"{o['type']}/{o['id']} query {q!r}"); q_used += 1
if q_used < 6:
    die(f"only {q_used} field references extracted from KQL queries -- the shipped objects contain "
        f"more than that, so the extractor is matching nothing and this check is vacuous")
ok(f"{used + q_used} field references ({q_used} from KQL) across {len(objs)} objects all exist "
   f"in the parse pipeline")

# --- 5. the dashboard must be reachable from the data the parser produces ------------------------
# Sanity in the other direction: if the parser gained http_status but no panel ever used it, the
# parse work would be dead weight. Assert the fields the design turns on are actually consumed.
consumed = json.dumps(objs)
for f in ("http_status", "http_path", "kubernetes.container_name", "log_level"):
    if f not in consumed:
        die(f"nothing in the saved objects uses {f!r} -- either a panel was dropped or the parser "
            f"is producing a field for nobody")
ok("http_status / http_path / container / log_level are each consumed by at least one object")
PY

echo "PASS: charts/logging Kibana saved objects"
