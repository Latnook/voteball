#!/usr/bin/env bash
# Offline test for scripts/ci/smoke-test.sh. SMOKE_STUB_CURL replaces the real curl so no network
# call is made and both outcomes can be forced deterministically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Stub contract: called as `stub <url>`, prints the body, exits non-zero to signal a transport error.
cat > "$work/ok" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  */api/options)       echo '200 {"clubs":[],"leagues":[]}' ;;
  */api/results\?by=all) echo '200 {"previous":[],"upcoming":[]}' ;;
  *)                   echo '200 <!doctype html>' ;;   # the site root
esac
STUB

# The failure this whole design exists to catch: the site LOOKS up (root and /health fine, pods
# Ready, ArgoCD reports Healthy) but the data path is broken.
cat > "$work/sick" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  */api/options)       echo '200 {"clubs":[],"leagues":[]}' ;;
  */api/results\?by=all) echo '503 upstream unavailable' ;;
  *)                   echo '200 <!doctype html>' ;;
esac
STUB

cat > "$work/down" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB

chmod +x "$work"/ok "$work"/sick "$work"/down

echo "--- a healthy site passes ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/ok" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null || fail "healthy site should pass"

echo "--- a 503 on /api/results fails, even though the root still serves ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/sick" SMOKE_RETRIES=2 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 && fail "a 503 must fail the smoke test"

echo "--- an unreachable site fails rather than hanging ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/down" SMOKE_RETRIES=2 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 && fail "transport failure must fail the smoke test"

echo "--- a missing base URL fails loudly ---"
SMOKE_STUB_CURL="$work/ok" "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 \
  && fail "missing SMOKE_BASE_URL must fail"

echo "ALL TESTS PASSED"
