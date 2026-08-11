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
[ "$got" = "skip" ] || fail "marker in the SUBJECT must skip (fail safe), got '$got'"; pass=$((pass+1))

# The marker in the BODY must NOT skip. This reverses the original behaviour on purpose: matching
# anywhere meant any commit that *documented* this guard skipped itself, which is not hypothetical --
# it happened twice on 2026-08-11 to the commits adding the dirty-tree guard and this very test
# suite's CI stage. Both reported NOT_BUILT, which reads like a pass, so two CI changes shipped
# without CI ever running. A spurious skip is only cheap when somebody notices it.
multiline="$(printf 'subject line\n\nbody mentioning [skip ci]\n')"
got="$(scripts/ci/should-skip-build.sh "$multiline")"
[ "$got" = "build" ] || fail "marker in the body must NOT skip, got '$got'"; pass=$((pass+1))

# The exact regression: a real commit body describing the guard.
real="$(printf 'feat(ci): run the script tests in the pipeline\n\nprotecting the pipeline itself -- the [skip ci] loop guard, the\nimmutable-tag re-run check ...\n')"
got="$(scripts/ci/should-skip-build.sh "$real")"
[ "$got" = "build" ] || fail "a commit body describing the guard must still build, got '$got'"; pass=$((pass+1))

# Pin CD's ACTUAL tag-bump format. Narrowing to the subject is only safe while the marker lives
# there; Jenkinsfile-cd writes it with a single -m. If that ever moves to a body line, this fails
# loudly instead of the loop guard failing silently.
grep -q 'git commit -m "ci: image tag \$TAG \[skip ci\]"' Jenkinsfile-cd \
  || fail "Jenkinsfile-cd no longer commits the marker in the subject line -- re-check the guard"
got="$(scripts/ci/should-skip-build.sh "ci: image tag deadbee [skip ci]")"
[ "$got" = "skip" ] || fail "CD's own tag-bump commit MUST skip, got '$got'"; pass=$((pass+1))

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
