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

# A realistic multi-line HTML root -- nginx's real index.html is always several lines, with spaces
# in most of them. This is the shape that broke the original status-code extraction
# (`awk '{print $1}'` with no NR==1 guard): it printed field 1 of EVERY line joined by newlines, so
# "code" became "200\n<html lang=\"en\">\n..." instead of "200", the string comparison against "200"
# always failed, and a healthy site would false-fail the smoke test -- which triggers an automatic
# rollback of a perfectly working deploy.
cat > "$work/ok_multiline" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  */api/options)       echo '200 {"clubs":[],"leagues":[]}' ;;
  */api/results\?by=all) echo '200 {"previous":[],"upcoming":[]}' ;;
  *)
    printf '200 <!doctype html>\n<html lang="en">\n  <head><title>Voteball</title></head>\n  <body>Hello world</body>\n</html>\n'
    ;;
esac
STUB

chmod +x "$work"/ok "$work"/sick "$work"/down "$work"/ok_multiline

echo "--- a healthy site passes ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/ok" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null || fail "healthy site should pass"

echo "--- a healthy site with a realistic multi-line body still passes ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/ok_multiline" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null || fail "multi-line healthy body should pass"

echo "--- a 503 on /api/results fails, even though the root still serves ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/sick" SMOKE_RETRIES=2 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 && fail "a 503 must fail the smoke test"

echo "--- an unreachable site fails rather than hanging ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/down" SMOKE_RETRIES=2 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 && fail "transport failure must fail the smoke test"

# Transport failures must name curl's exit code. On 2026-09-15 CD #1 logged 25 bare "transport
# failure" lines, and telling "could not resolve" (6) from "could not connect" (7) took an hour of
# external-dns and load-balancer log archaeology instead of one log line.
cat > "$work/nxhost" <<'STUB'
#!/usr/bin/env bash
exit 6
STUB

# Resolves only after a few tries -- a negative DNS answer expiring from a cache. COUNT_FILE holds
# how many calls have failed so far; FAIL_TIMES and EXIT_CODE shape the stub per case.
cat > "$work/flaky" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
if [ "$n" -lt "$FAIL_TIMES" ]; then echo $((n + 1)) > "$COUNT_FILE"; exit "$EXIT_CODE"; fi
case "$1" in
  */api/options)       echo '200 {"clubs":[],"leagues":[]}' ;;
  */api/results\?by=all) echo '200 {"previous":[],"upcoming":[]}' ;;
  *)                   echo '200 <!doctype html>' ;;
esac
STUB
chmod +x "$work"/nxhost "$work"/flaky

echo "--- a transport failure names curl's exit code ---"
out="$(SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/nxhost" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  SMOKE_DNS_WAIT=0 "$ROOT/scripts/ci/smoke-test.sh" 2>&1)" && fail "exit 6 must fail when there is no DNS budget"
printf '%s' "$out" | grep -q 'curl exit 6' || fail "exit 6 not named in output: $out"
printf '%s' "$out" | grep -q 'could not resolve host' || fail "exit 6 not described: $out"
out="$(SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/down" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" 2>&1)" && fail "exit 7 must fail"
printf '%s' "$out" | grep -q 'curl exit 7' || fail "exit 7 not named in output: $out"

echo "--- an unresolvable host is waited out (cached negative DNS answer), not rolled back ---"
rm -f "$work/count"
COUNT_FILE="$work/count" FAIL_TIMES=4 EXIT_CODE=6 \
  SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/flaky" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  SMOKE_DNS_WAIT=10 "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 \
  || fail "exit 6 that clears inside SMOKE_DNS_WAIT must pass even with SMOKE_RETRIES=1"

echo "--- the DNS wait is bounded: a host that never resolves still fails, and terminates ---"
rc=0
timeout 20 env SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/nxhost" SMOKE_RETRIES=1 \
  SMOKE_DELAY=0 SMOKE_DNS_WAIT=3 "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 124 ] || fail "the DNS wait did not terminate (timeout fired)"
[ "$rc" -ne 0 ] || fail "a host that never resolves must fail once SMOKE_DNS_WAIT is spent"

echo "--- the DNS wait is specific to exit 6: a connect failure gets no extra time ---"
rm -f "$work/count"
COUNT_FILE="$work/count" FAIL_TIMES=4 EXIT_CODE=7 \
  SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/flaky" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  SMOKE_DNS_WAIT=100 "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 \
  && fail "exit 7 must consume normal retries, not the DNS budget"

echo "--- a missing base URL fails loudly ---"
SMOKE_STUB_CURL="$work/ok" "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 \
  && fail "missing SMOKE_BASE_URL must fail"

echo "ALL TESTS PASSED"
