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

failed = False
checked = 0
for path in sys.argv[1:]:
    src = open(path).read()
    blocks = PATTERN.findall(src)
    for i, body in enumerate(blocks, 1):
        checked += 1
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

if failed:
    sys.exit(1)
print(f"check-jenkinsfile-shell: {checked} sh block(s) across {len(sys.argv) - 1} file(s) "
      f"parse cleanly ({', '.join(sys.argv[1:])})")
PY
