#!/usr/bin/env bash
# Tests the two pipeline decision helpers with NO AWS access. ECR lookups are stubbed via the
# CI_STUB_DESCRIBE_CMD env var the script honours -- same pattern as test-sync-values.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0

# ---- G2: the [skip ci] guard -------------------------------------------------------------------
got="$(scripts/ci/should-skip-build.sh 'ci: image tag abc1234 [skip ci]')"
[ "$got" = "skip" ] || fail "bot commit should skip, got '$got'"; pass=$((pass+1))

got="$(scripts/ci/should-skip-build.sh 'feat: add a league filter')"
[ "$got" = "build" ] || fail "normal commit should build, got '$got'"; pass=$((pass+1))

got="$(scripts/ci/should-skip-build.sh 'fix: mention [skip ci] in the docs')"
[ "$got" = "skip" ] || fail "substring anywhere must skip (fail safe), got '$got'"; pass=$((pass+1))

multiline="$(printf 'subject line\n\nbody mentioning [skip ci]\n')"
got="$(scripts/ci/should-skip-build.sh "$multiline")"
[ "$got" = "skip" ] || fail "multi-line message body should skip, got '$got'"; pass=$((pass+1))

got="$(scripts/ci/should-skip-build.sh '')"
[ "$got" = "build" ] || fail "empty message should build, got '$got'"; pass=$((pass+1))

# ---- G1: the already-built check ---------------------------------------------------------------
export AWS_REGION=il-central-1 TAG=abc1234 ECR_REPOS="voteball-backend voteball-worker"

export CI_STUB_DESCRIBE_CMD="true"      # every lookup succeeds
got="$(scripts/ci/images-exist.sh)"
[ "$got" = "present" ] || fail "all images found should be present, got '$got'"; pass=$((pass+1))

export CI_STUB_DESCRIBE_CMD="false"     # every lookup fails
got="$(scripts/ci/images-exist.sh)"
[ "$got" = "missing" ] || fail "no images found should be missing, got '$got'"; pass=$((pass+1))

# Partial: backend present, worker absent. Must be 'missing' -- a partial push must rebuild.
cat > /tmp/ci-stub-partial.sh <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "voteball-backend" ] && exit 0; done
exit 1
STUB
chmod +x /tmp/ci-stub-partial.sh
export CI_STUB_DESCRIBE_CMD=/tmp/ci-stub-partial.sh
got="$(scripts/ci/images-exist.sh)"
[ "$got" = "missing" ] || fail "partial push must rebuild, got '$got'"; pass=$((pass+1))

echo "PASS: $pass assertions"
