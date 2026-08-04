#!/usr/bin/env bash
# Checks that every `sh '''...'''` body (including the inline `sh(script: '''...''')` form) inside
# every Jenkinsfile-* in the repo actually parses as shell.
#
# WHY THIS EXISTS: the Jenkins Declarative linter (pipeline-model-converter/validate) validates
# pipeline SCHEMA only -- stage/when/steps nesting, directive names -- and has zero visibility into
# the text inside an sh block. On 2026-08-04 a shell script with an unterminated quote in
# Jenkinsfile-ci's 'Publish Metadata' stage got through three separate validation gates -- the
# Declarative linter, this repo's own brace-balance/stage-presence structural check, and manual
# review -- because none of them ever actually parsed the shell text. It would have failed on the
# stage's very first live run, aborting before Trigger CD ever ran, defeating the entire point of
# splitting CI from CD. This script is the gate that actually parses the shell, closing that gap.
#
# Checks every Jenkinsfile-* by glob, not a hardcoded filename, so Jenkinsfile-cd (arriving in the
# next task) and any future pipeline file are covered automatically with no edit needed here.
#
# Usage: check-jenkinsfile-shell.sh [file ...]
#   No args  -- glob every Jenkinsfile-* in the repo root (the normal, CI-facing mode).
#   With args -- check exactly those files instead (used by this script's own verification, to
#   point it at a specific git revision's content without touching the working tree).
set -uo pipefail
cd "$(dirname "$0")/../.."

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  shopt -s nullglob
  files=(Jenkinsfile-*)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    echo "check-jenkinsfile-shell: no Jenkinsfile-* found in repo root" >&2
    exit 1
  fi
fi

python3 - "${files[@]}" <<'PY'
import re
import subprocess
import sys
import tempfile
import os

# Groovy ''' (triple-single-quoted) strings do no interpolation, and every Jenkinsfile in this repo
# uses them both for multi-line `sh '''...'''` step bodies AND for the one-line inline
# `sh(script: '''...''', ...)` form -- a plain '''(.*?)''' scan over the whole file catches both.
# That distinction matters: the bug this script exists to catch was in the inline form, and an
# extraction narrowed to `sh '''` alone would have missed it.
#
# $TAG / ${env.X} tokens inside these blocks are untouched by Groovy (no interpolation in '''
# strings), so bash -n sees them as ordinary, currently-unset-but-syntactically-valid shell variable
# references -- exactly what -n needs to see to check syntax without executing anything.
PATTERN = re.compile(r"'''(.*?)'''", re.DOTALL)

# THE RAW FILE TEXT IS NOT WHAT THE SHELL RECEIVES. Groovy parses the ''' body as a string literal
# before Jenkins ever hands it to `sh`, and that parse applies Groovy's normal single-quoted-string
# escape processing: `\\` collapses to a single `\`, `\n`/`\t`/`\r`/`\b`/`\f`/`\'`/`\"`/`\$` become
# real control characters, and a `\` immediately followed by an actual source newline (a
# line-continuation, used throughout these files for multi-line shell commands) is removed entirely
# rather than passed through. Testing the raw text -- as this script did before 2026-08-04 -- checks
# a string bash never actually sees. On 2026-08-04, `bash -n` on the raw text of a block passed, a
# manually Groovy-unescaped copy of the same block also passed, and the block still failed live in
# Jenkins -- so this unescaping closes a real gap between "looks fine on disk" and "what executes",
# even though it did not turn out to be the whole story for that incident.
ESCAPES = {
    '\\': '\\', "'": "'", '"': '"', 'n': '\n', 't': '\t',
    'r': '\r', 'b': '\b', 'f': '\f', '$': '$',
}


def groovy_unescape(body):
    out = []
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c == '\\' and i + 1 < n:
            nxt = body[i + 1]
            if nxt == '\n':
                # Line continuation inside the Groovy string literal: both characters vanish.
                i += 2
                continue
            if nxt in ESCAPES:
                out.append(ESCAPES[nxt])
                i += 2
                continue
            # An escape Groovy does not recognise -- leave both characters untouched rather than
            # guess, since misinterpreting an escape here would make this check less trustworthy
            # than testing the raw text.
        out.append(c)
        i += 1
    return ''.join(out)


# The class of bug that produced the 2026-08-04 incident: long WHY comments inside a shell body,
# written in prose, accumulate apostrophes/backticks/double-quotes that something between Groovy and
# the executed script (durable-task's script.sh.copy, the file copy, the exec channel -- never
# conclusively pinned down) can mangle. The fix applied that day was to move that prose into Groovy
# `//` comments above the `sh` call and keep shell comments short and plain. This check makes that
# mechanical rather than a convention someone has to remember: see
# docs/design/2026-08-04-cicd-split-design.md and the Publish Metadata stage history in
# Jenkinsfile-ci for the incident this guards against.
FLAGGED_CHARS = ("'", '`', '"')


def find_comment_violations(body):
    violations = []
    for lineno, line in enumerate(body.splitlines(), 1):
        stripped = line.strip()
        if not stripped.startswith('#'):
            continue
        if any(ch in stripped for ch in FLAGGED_CHARS):
            violations.append((lineno, stripped))
    return violations


failed = False
checked = 0
for path in sys.argv[1:]:
    src = open(path).read()
    blocks = PATTERN.findall(src)
    for i, raw_body in enumerate(blocks, 1):
        checked += 1
        body = groovy_unescape(raw_body)
        first_line = next((l for l in body.strip().splitlines() if l.strip()), "(empty)")
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write(body)
            tmp = f.name
        try:
            result = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
        finally:
            os.unlink(tmp)
        if result.returncode != 0:
            failed = True
            print(f"FAIL: {path} block {i} does not parse as shell -- starts: {first_line[:70]!r}")
            for line in result.stderr.strip().splitlines():
                print(f"      {line}")

        for lineno, comment in find_comment_violations(body):
            failed = True
            print(f"FAIL: {path} block {i} line {lineno}: shell comment contains an apostrophe, "
                  f"backtick or double quote -- this is the exact fragility that broke CI build 12 "
                  f"in Jenkinsfile-ci's 'Publish Metadata' stage on 2026-08-04. Move this prose to a "
                  f"Groovy // comment immediately above the sh call instead.")
            print(f"      {comment}")

if failed:
    sys.exit(1)
print(f"check-jenkinsfile-shell: {checked} sh block(s) across {len(sys.argv) - 1} file(s) "
      f"parse cleanly with no flagged shell comments ({', '.join(sys.argv[1:])})")
PY
