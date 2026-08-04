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

# ---- G3b: the empty-changelog escape hatch in Jenkinsfile-ci -------------------------------------
# Not a script, so it cannot be exercised like the two above -- but it is the guard whose absence
# caused a green build that shipped nothing (2026-08-03, build 2), and the failure is invisible:
# the pipeline reports SUCCESS. These are static assertions over Jenkinsfile-ci so that removing
# the escape hatch fails here instead of silently in production a Spot reclaim later.
# (Jenkinsfile-ci, not Jenkinsfile -- the single pipeline was split into Jenkinsfile-ci/-cd on
# 2026-08-04; the build/scan/push gates this section checks all stayed on the CI side.)

# Every gate that keys on `changeset 'services/**'` must also accept "no changelog at all".
# Match the gate form specifically -- the plain `env.NO_CHANGELOG == 'true'` also appears in the
# echo that announces the fallback, which is not a gate and must not be counted.
gates="$(grep -c "changeset 'services/\*\*'" Jenkinsfile-ci)"
hatches="$(grep -c "expression { env.NO_CHANGELOG == 'true' }" Jenkinsfile-ci)"
[ "$gates" -gt 0 ] || fail "expected at least one changeset gate in Jenkinsfile-ci, found none"
pass=$((pass+1))
[ "$gates" = "$hatches" ] || \
  fail "every 'changeset services/**' gate needs the NO_CHANGELOG escape hatch: $gates gates, $hatches hatches"
pass=$((pass+1))

# ...and NO_CHANGELOG must actually be assigned from the build's changeSets, not left undefined --
# an unset env var compares false, which would silently restore the old skip-everything behaviour.
grep -q 'env.NO_CHANGELOG = currentBuild.changeSets.isEmpty()' Jenkinsfile-ci || \
  fail "NO_CHANGELOG is referenced but never assigned from currentBuild.changeSets"
pass=$((pass+1))

# The gates must stay OR-ed with the changeset check, never replace it: a normal build with real
# commits that miss services/** still has to skip.
grep -q "anyOf { changeset 'services/\*\*'" Jenkinsfile-ci || \
  fail "changeset gate must remain inside an anyOf, or unrelated commits will rebuild every time"
pass=$((pass+1))

echo "PASS: $pass assertions"
