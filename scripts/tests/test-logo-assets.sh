#!/usr/bin/env bash
# Asserts that every self-hosted logo seed.sql points at actually exists in the image.
#
# WHY THIS EXISTS: a `/logos/x.svg` in seed.sql whose file is missing is invisible everywhere it
# could be caught. The seed applies cleanly (it is just a string), every backend test passes (they
# assert the column's value, not that the file resolves), the pod is Healthy, and the smoke test
# passes because the page loads. The only symptom is that the crest silently renders as an initials
# monogram -- logos.js's error handler doing its job -- which looks like "no logo set yet" rather
# than like a bug. Exactly the same class of silent failure as the dead Wikimedia France URL, but
# self-inflicted and, unlike a remote URL, fully checkable offline.
#
# The reverse direction is checked too: a file in services/frontend/logos/ that nothing references
# is dead weight shipped in every image. That is a warning, not a failure -- a crest can legitimately
# be added ahead of the seed statement that uses it.
set -uo pipefail

cd "$(dirname "$0")/../.."   # repo root

SEED=services/backend/seed.sql
LOGO_DIR=services/frontend/logos
fails=0

[ -f "$SEED" ]     || { echo "FAIL: $SEED not found" >&2; exit 1; }
[ -d "$LOGO_DIR" ] || { echo "FAIL: $LOGO_DIR not found" >&2; exit 1; }

echo "==> every /logos/ path in $SEED exists in $LOGO_DIR"
referenced="$(grep -oE "'/logos/[^']+'" "$SEED" | tr -d "'" | sort -u)"
[ -n "$referenced" ] || { echo "FAIL: no /logos/ references found -- has the path convention changed?" >&2; exit 1; }

while IFS= read -r ref; do
  file="services/frontend${ref}"
  if [ -f "$file" ]; then
    echo "  ok   $ref"
  else
    echo "  FAIL $ref -- no such file ($file)"
    fails=$((fails + 1))
  fi
done <<< "$referenced"

# The Dockerfile copies logos/ as a whole directory, so a new crest needs no COPY edit -- but that is
# only true while the directory line is actually there. If someone converts it to a by-name COPY (as
# every other frontend file uses), a new logo would stop shipping with no other signal.
echo "==> services/frontend/Dockerfile still copies logos/ as a directory"
if grep -qE '^COPY[[:space:]]+logos/' services/frontend/Dockerfile; then
  echo "  ok   COPY logos/ present"
else
  echo "  FAIL Dockerfile no longer copies logos/ as a directory -- new crests will not ship"
  fails=$((fails + 1))
fi

echo "==> unreferenced files in $LOGO_DIR (warning only)"
for f in "$LOGO_DIR"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # Dark-theme variants are referenced from logos.js, not seed.sql.
  if grep -q "/logos/$name" "$SEED" services/frontend/logos.js 2>/dev/null; then
    continue
  fi
  echo "  warn $name is referenced by neither seed.sql nor logos.js"
done

echo
if [ "$fails" -gt 0 ]; then
  echo "FAILED: $fails logo assertion(s)" >&2
  exit 1
fi
echo "All logo asset assertions passed."
