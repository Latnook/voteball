#!/usr/bin/env bash
# Tests scripts/ci/changed-paths.sh against REAL throwaway git repositories -- the decision it makes
# is entirely about git ranges, so stubbing git would test nothing. GIT_GROUP in run-ci-suite.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRIPT="$(pwd)/scripts/ci/changed-paths.sh"
pass=0
fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; echo "       $2"; fail=$((fail + 1)); }

want() { # want <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

echo "changed-paths.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

repo="$TMP/repo"
mkdir -p "$repo/services/backend" "$repo/charts/voteball" "$repo/scripts/tests"
cd "$repo"
git init -q .
git config user.email t@example.invalid
git config user.name test

commit() { git add -A; git commit -q -m "$1"; git rev-parse HEAD; }

echo 'seed' > services/backend/seed.sql
echo 'chart' > charts/voteball/values.yaml
echo 'test' > scripts/tests/t.sh
BASE="$(commit base)"

# --- 1. A change under the prefix is seen -----------------------------------------------------
echo 'seed v2' > services/backend/seed.sql
SEEDC="$(commit 'change seed')"
want "sees a change under services/"  true  "$("$SCRIPT" "$BASE" services/)"
want "ignores an unrelated prefix"    false "$("$SCRIPT" "$BASE" charts/)"

# --- 2. THE REGRESSION: a failed build must not strand its changes -----------------------------
# The 2026-09-08 incident. seed.sql changed in a build that FAILED, the next commit touched only
# scripts/, and Jenkins' own `changeset` (which diffs against the PREVIOUS build, i.e. $SEEDC)
# reported "nothing under services/ changed" -- so the pipeline went green and shipped nothing.
# Basing the range on the last SUCCESSFUL build ($BASE) instead keeps the change in view.
echo 'test v2' > scripts/tests/t.sh
commit 'fix the test only' >/dev/null
want "a failed build's changes stay visible from the last SUCCESSFUL base" \
     true "$("$SCRIPT" "$BASE" services/)"
want "...and are NOT visible from the previous BUILD's base (the bug being fixed)" \
     false "$("$SCRIPT" "$SEEDC" services/)"

# --- 3. Fail-safe: an unusable base must answer "yes", never "no" ------------------------------
# "Cannot tell what changed" has to build. Answering false here is the green-build-that-shipped-
# nothing failure this whole script exists to prevent, so both cases are pinned in BOTH directions.
want "empty base is fail-safe"        true "$("$SCRIPT" "" services/)"
want "unknown base is fail-safe"      true "$("$SCRIPT" 0000000000000000000000000000000000000000 services/)"
want "empty base is fail-safe for charts too" true "$("$SCRIPT" "" charts/)"

# stderr must carry the explanation, and stdout must stay parseable -- Jenkins reads it with
# returnStdout and compares to the literal 'true', so one stray line of prose breaks the gate open
# in the WRONG direction (never equal to 'true' -> never builds).
out="$("$SCRIPT" "" services/ 2>/dev/null)"
want "stdout is exactly the verdict, explanation goes to stderr" true "$out"
if "$SCRIPT" "" services/ 2>&1 >/dev/null | grep -q 'cannot tell'; then
  ok "explains itself on stderr"
else
  bad "explains itself on stderr" "no explanation found"
fi

# --- 4. A DELETED file counts ------------------------------------------------------------------
# --diff-filter is deliberately absent from the script: removing a file from services/ changes the
# image just as much as editing one, and a filter of A|M would have missed it.
git rm -q services/backend/seed.sql
DEL_BASE="$(git rev-parse HEAD~0)"
commit 'delete seed' >/dev/null
want "a deleted file under the prefix counts" true "$("$SCRIPT" "$DEL_BASE" services/)"

# --- 5. Argument handling ----------------------------------------------------------------------
if "$SCRIPT" "$BASE" >/dev/null 2>&1; then
  bad "rejects a missing prefix" "exited 0"
else
  ok "rejects a missing prefix"
fi

cd - >/dev/null
echo
if [ "$fail" -eq 0 ]; then
  echo "All $pass checks passed."
else
  echo "$fail of $((pass + fail)) checks FAILED."
  exit 1
fi
