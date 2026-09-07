#!/usr/bin/env bash
# The Fluentd parse pipeline in charts/logging, exercised against REAL log lines.
#
# WHY THIS FILE EXISTS. charts/logging/templates/fluentd.yaml turns one opaque `log` string into
# http_status / http_path / log_level, and every panel in the Kibana dashboard aggregates on those
# fields. A regexp that cannot match is the worst defect shape this repo has: it produces an empty
# result, which is indistinguishable from a correct negative, and no amount of reading the pattern
# reveals it (CLAUDE.md, "a pattern that can never match ... found ONLY by feeding the check input
# you KNOW should match, once"). So the fixtures below are real lines, copied out of the live index
# on 2026-09-07, and every one of them asserts which pattern claims it and what it yields.
#
# It also pins the two lines whose deletion silently destroys data rather than failing:
#   * `reserve_data true`   -- without it filter_parser DROPS an unmatched record
#   * the trailing `format none` catch-all -- without it every worker line is unmatched
#
# ENGINE. Fluentd runs these through Ruby's Onigmo. This test runs them through Python's `re` after
# rewriting `(?<name>` to `(?P<name>`, which is the ONLY difference in the constructs used here
# (character classes, non-greedy groups, bounded repetition, anchors and alternation behave
# identically). Python is what CI has -- the `python` container is python:3.12-slim and neither it
# nor jnlp carries a Ruby -- so a Ruby-only test would sit in run-ci-suite.sh's SKIP list and protect
# nothing. When `ruby` IS present the same fixtures are re-run through the real engine and the two
# results must agree; that cross-check is what keeps the translation honest.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> charts/logging parse pipeline"

# THE TEMPLATE FILE IS THE SOURCE, not `helm template` output. Every `expression /.../` line is
# literal text -- no Helm action touches one -- so reading the file directly means this test runs in
# CI's python container, which has no helm. run-ci-suite.sh's SKIP list already holds three
# helm-dependent chart tests that consequently protect nothing on any build; a fourth would have
# made the parse pipeline the most silently-breakable thing in the chart.
TEMPLATE=charts/logging/templates/fluentd.yaml
[ -f "$TEMPLATE" ] || fail "missing $TEMPLATE"
rendered="$(cat "$TEMPLATE")"

# When helm IS available, additionally prove templating does not alter the patterns -- the escaping
# in these regexes (backslashes, braces, quotes) is exactly the kind of thing a block scalar or a
# Sprig function can quietly change.
if command -v helm >/dev/null 2>&1; then
  helm_out="$(helm template logging charts/logging --namespace logging \
    --show-only templates/fluentd.yaml)" || fail "helm template failed"
  a="$(grep -E '^\s*expression /' "$TEMPLATE" | sed 's/^[[:space:]]*//')"
  b="$(grep -E '^\s*expression /' <<<"$helm_out" | sed 's/^[[:space:]]*//')"
  [ "$a" = "$b" ] || fail "helm rendering CHANGED the parser expressions:\n--- source ---\n$a\n--- rendered ---\n$b"
  echo "  ok: helm rendering leaves the expressions byte-identical"
fi

FIXTURES=scripts/tests/fixtures/logging-log-lines.txt
[ -f "$FIXTURES" ] || fail "missing fixture file $FIXTURES"

RENDERED="$rendered" FIXTURES="$FIXTURES" python3 - <<'PY'
import os, re, sys

rendered = os.environ["RENDERED"]
ok = lambda m: print(f"  ok: {m}")

def die(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

# --- pull the pipeline out of the rendered chart, never out of a copy kept in this file ----------
# A restated copy would keep passing for as long as it took someone to edit the chart and not this.
exprs = re.findall(r"^\s*expression (/.*/)\s*$", rendered, re.M)
if len(exprs) != 3:
    die(f"expected 3 `expression` patterns in the rendered fluent.conf, found {len(exprs)}")

if not re.search(r"^\s*reserve_data true\s*$", rendered, re.M):
    die("`reserve_data true` is gone -- filter_parser then DROPS every record whose pattern does "
        "not match and every record with no `log` key, silently. This is the log-shredder line.")
ok("reserve_data true (unmatched records survive the filter)")

# The catch-all must be LAST: multi_format tries patterns in order, so a `format none` placed
# earlier would claim every line and the three real patterns would never run.
parse_block = rendered[rendered.index("@type multi_format"):]
if "format none" not in parse_block:
    die("the trailing `format none` catch-all is gone -- worker lines match no other pattern")
if parse_block.index("format none") < parse_block.rindex("format regexp"):
    die("`format none` must come AFTER every `format regexp` -- multi_format takes the first match, "
        "so a catch-all placed first swallows every line and no field is ever parsed")
ok("format none catch-all present and last")

def to_py(fluent_regex):
    body = fluent_regex[1:fluent_regex.rindex("/")]
    return re.compile(body.replace("(?<", "(?P<"))

NGINX, GUNICORN, CANARY = (to_py(e) for e in exprs)
PATTERNS = [("nginx", NGINX), ("gunicorn", GUNICORN), ("canary", CANARY)]

def classify(line):
    for name, rx in PATTERNS:
        m = rx.match(line)
        if m:
            return name, {k: v for k, v in m.groupdict().items() if v is not None}
    return "none", {}

# --- the fixtures: real lines, and what each MUST produce ---------------------------------------
cases = []
for raw in open(os.environ["FIXTURES"], encoding="utf-8"):
    raw = raw.rstrip("\n")
    if not raw or raw.startswith("#"):
        continue
    expect, line = raw.split("\t", 1)
    cases.append((expect, line))
if len(cases) < 10:
    die(f"only {len(cases)} fixtures -- this file is the whole proof, do not thin it out")

for expect, line in cases:
    want_pattern, _, want_fields = expect.partition(" ")
    got_pattern, got = classify(line)
    if got_pattern != want_pattern:
        die(f"expected pattern {want_pattern} for {line!r}, got {got_pattern} ({got})")
    for pair in filter(None, want_fields.split(",")):
        k, _, v = pair.partition("=")
        if got.get(k) != v:
            die(f"{want_pattern} on {line!r}: expected {k}={v!r}, got {got.get(k)!r}")
ok(f"{len(cases)} real log lines classified and captured as expected")

# --- negative controls: prove each pattern CAN fail ---------------------------------------------
# A pattern that matches everything is as useless as one that matches nothing, and reads the same.
if NGINX.match("Rollups recomputed, milestones checked."):
    die("the nginx pattern matches a plain worker line -- it is too loose to mean anything")
if CANARY.match("200 OK"):
    die("the canary pattern matches `200 OK` -- it must require a method AND a path")
if GUNICORN.match("[2026-09-06 18:14:20 +0000] Starting gunicorn"):
    die("the gunicorn pattern matches a line with no [pid] [LEVEL] -- log_level would be absent")
ok("negative controls: each pattern rejects input it must not claim")

# --- the health-check exclusion -----------------------------------------------------------------
# Rendered only when fluentd.dropHealthChecks is on (it ships on). The pattern is EXTRACTED from the
# rendered chart, never restated here: an earlier draft of this test hardcoded "ELB-HealthChecker"
# and therefore stayed green while the real filter was widened to /HTTP/, which would have discarded
# every request line in the index. That is the same restated-copy defect the comment at the top of
# this file warns about, caught by mutation-testing this file rather than by reading it.
excl = re.search(r"<exclude>\s*key (\S+)\s*pattern /(.*?)/\s*</exclude>", rendered, re.S)
if excl:
    key, drop = excl.group(1), re.compile(excl.group(2))
    if key != "log":
        die(f"the exclusion keys on `{key}`, but it runs BEFORE the parser, where only `log` exists")
    health = next(l for _, l in cases if "ELB-HealthChecker" in l)
    kept = [l for e, l in cases if "ELB-HealthChecker" not in l]
    if not drop.search(health):
        die(f"the exclusion /{excl.group(2)}/ does not match a real ELB-HealthChecker line")
    caught = [l for l in kept if drop.search(l)]
    if caught:
        die(f"the exclusion /{excl.group(2)}/ ALSO matches {len(caught)} line(s) that must be kept, "
            f"e.g. {caught[0]!r} -- a filter this broad empties the index and reports nothing")
    ok(f"exclusion /{excl.group(2)}/ drops the checker and keeps all {len(kept)} other fixtures")

# --- types coercion, PER PATTERN ----------------------------------------------------------------
# http_status must reach Elasticsearch as a NUMBER. Dynamic mapping types a field from the FIRST
# value it sees, so one pattern emitting it as a string maps http_status as text forever and every
# `http_status >= 500` filter in the dashboard then matches nothing, with no error anywhere.
#
# Checked inside each <pattern> block, not against the whole file. A chart-wide grep passes as long
# as ANY pattern coerces it -- proven by mutation: dropping the coercion from the nginx pattern (the
# one carrying 100% of the real traffic) left the canary's copy behind and the old check stayed green.
blocks = re.findall(r"<pattern>(.*?)</pattern>", rendered, re.S)
if len(blocks) != 4:
    die(f"expected 4 <pattern> blocks (3 regexp + the catch-all), found {len(blocks)}")
for i, b in enumerate(blocks):
    for field in ("http_status", "http_bytes", "pid"):
        if f"(?<{field}>" in b and not re.search(rf"^\s*types .*\b{field}:integer", b, re.M):
            die(f"<pattern> #{i + 1} captures {field} but does not coerce it to integer; "
                f"Elasticsearch would map it as text and every range query on it returns nothing")
ok(f"every numeric capture across {len(blocks)} patterns is coerced to integer")
PY

# --- cross-check against the engine that actually runs in production -----------------------------
# Python is what CI has; Ruby is what Fluentd uses. When both are present they must agree, which is
# what keeps the `(?<` -> `(?P<` translation above from quietly diverging.
if command -v ruby >/dev/null 2>&1; then
  RENDERED="$rendered" FIXTURES="$FIXTURES" ruby -e '
    rendered = ENV["RENDERED"]
    exprs = rendered.scan(/^\s*expression (\/.*\/)\s*$/).flatten
    pats  = exprs.map { |e| Regexp.new(e[1...e.rindex("/")]) }
    names = %w[nginx gunicorn canary]
    n = 0
    File.readlines(ENV["FIXTURES"], encoding: "UTF-8").each do |raw|
      raw = raw.chomp
      next if raw.empty? || raw.start_with?("#")
      expect, line = raw.split("\t", 2)
      want = expect.split(" ").first
      got  = "none"
      pats.each_with_index { |rx, i| if rx.match(line) then got = names[i]; break end }
      abort "FAIL(ruby): expected #{want} for #{line.inspect}, got #{got}" unless got == want
      n += 1
    end
    puts "  ok: #{n} fixtures agree under Ruby/Onigmo, the engine Fluentd actually uses"
  '
else
  echo "  ok: (ruby absent -- Python-only run; the translated constructs are documented at the top)"
fi

echo "PASS: charts/logging parse pipeline"
