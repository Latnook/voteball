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

# NOBODY WRITES THE MARKER ANY MORE, and the guard stays anyway. Until 2026-08-23 Jenkinsfile-cd
# pushed `ci: image tag $TAG [skip ci]` to master and this line pinned that exact string. CD now
# promotes to the `release` branch instead (Task 4 review P1/P2), so it never touches the branch the
# CI webhook watches and has no reason to mark anything.
#
# The guard is deliberately NOT removed -- the root CLAUDE.md is explicit about that, and the reason
# survives the branch change: it is the only thing standing between a master-pushing promotion and an
# unbounded billable build loop, so it must already be in place if anyone ever reintroduces one.
# deploy.sh step 9 also still commits to master today.
#
# So the assertion inverts. Instead of pinning a producer that no longer exists, assert that CD does
# NOT push to master -- which is the property that made the marker unnecessary. If someone restores a
# master push, this fails loudly and points at the two things that then need re-deciding together.
grep -qE 'push[^\n]*(HEAD:master|origin master)' Jenkinsfile-cd \
  && fail "Jenkinsfile-cd pushes to master again. The 2026-08-21 queued-build race comes back with it: CD's commit can become the branch tip that a queued CI build checks out, hiding the source commit that triggered it. Either promote to the release branch (scripts/ci/promote-to-release.sh) or restore a [skip ci] subject marker AND re-pin it here."
pass=$((pass+1))

# The loop guard itself must still work on the canonical string, whoever writes it next.
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
# COMMENTS STRIPPED FIRST. Jenkinsfile-ci's own prose quotes `changeset 'services/**'` while
# explaining these gates, and counting those lines makes the two totals disagree for a reason that
# has nothing to do with the code -- which is exactly the sort of false alarm that gets a real check
# deleted. (Same trap, same fix, as the egress-coverage check in scripts/ci/validate-repo.sh, which
# would otherwise have been satisfied by a label mentioned only in a comment.)
uncommented="$(sed -e 's|^[[:space:]]*//.*$||' Jenkinsfile-ci)"
gates="$(printf '%s\n' "$uncommented" | grep -c "changeset 'services/\*\*'")"
hatches="$(printf '%s\n' "$uncommented" | grep -c "expression { env.NO_CHANGELOG == 'true' }")"
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

# ---- G2, range form: the 2026-08-21 queued-build race -------------------------------------------
# The incident, reproduced as data. CI #1 was building b09a05d when a558113 was pushed and queued; CD
# pushed its promotion commit e9e5c7a at 15:45:59; the queued build started its checkout at 15:46:46
# and, seeing only the TIP, matched the marker and reported NOT_BUILT. a558113 was never built by
# that build or by any later one -- it sits behind the tip, so no subsequent changeset contains it.
#
# The range form is what makes that impossible: a range holding even one unmarked commit builds.
range_verdict() { printf '%s\n' "$@" | scripts/ci/should-skip-build.sh --subjects; }

got="$(range_verdict 'feat: a real source commit' 'ci: image tag e9e5c7a [skip ci]')"
[ "$got" = "build" ] || fail "THE 2026-08-21 RACE: a source commit hidden behind a promotion commit must still build, got '$got'"
pass=$((pass+1))

# ...and the loop guard itself must survive that change, or this trade is not worth making.
got="$(range_verdict 'ci: image tag e9e5c7a [skip ci]')"
[ "$got" = "skip" ] || fail "a range of nothing but promotion commits must still skip (loop guard), got '$got'"
pass=$((pass+1))

got="$(range_verdict 'ci: image tag aaa1111 [skip ci]' 'ci: image tag bbb2222 [skip ci]')"
[ "$got" = "skip" ] || fail "several consecutive promotion commits must still skip, got '$got'"
pass=$((pass+1))

got="$(range_verdict 'ci: image tag e9e5c7a [skip ci]' 'feat: pushed after the bump')"
[ "$got" = "build" ] || fail "an unmarked commit AFTER the promotion commit must build, got '$got'"
pass=$((pass+1))

# An empty range cannot reopen the loop: had CD pushed a promotion commit it would BE in the range,
# so empty means the tip already built. Building is the safe answer and costs one redundant run.
got="$(printf '' | scripts/ci/should-skip-build.sh --subjects)"
[ "$got" = "build" ] || fail "an empty range must build, not skip, got '$got'"
pass=$((pass+1))

# Blank lines are not commits. A caller assembling the subject list by other means can emit one, and
# counting it as an unmarked commit would rebuild on every single run -- a loop by another route.
got="$(printf 'ci: image tag abc1234 [skip ci]\n\n' | scripts/ci/should-skip-build.sh --subjects)"
[ "$got" = "skip" ] || fail "a trailing blank line must not be counted as an unmarked commit, got '$got'"
pass=$((pass+1))

# The single-message form must keep working unchanged -- the Jenkinsfile falls back to it whenever
# GIT_PREVIOUS_SUCCESSFUL_COMMIT is unset (first build) or names a commit that no longer exists.
got="$(scripts/ci/should-skip-build.sh 'ci: image tag abc1234 [skip ci]')"
[ "$got" = "skip" ] || fail "the legacy single-message form regressed, got '$got'"
pass=$((pass+1))

# The Jenkinsfile must actually USE the range form, and must fall back rather than failing when the
# base is unavailable. A guard that silently reverts to tip-only reintroduces the race with no signal.
grep -q 'GIT_PREVIOUS_SUCCESSFUL_COMMIT' Jenkinsfile-ci || \
  fail "Jenkinsfile-ci's Guard no longer uses GIT_PREVIOUS_SUCCESSFUL_COMMIT -- the 2026-08-21 race is back"
pass=$((pass+1))
grep -q 'should-skip-build.sh --subjects' Jenkinsfile-ci || \
  fail "Jenkinsfile-ci's Guard does not call the range form of should-skip-build.sh"
pass=$((pass+1))
# git cat-file guards against a base that was rewritten out of history; without it the git log fails
# and the whole Guard stage errors out, which Jenkins reports as a FAILED build rather than a skip.
grep -q 'git cat-file -e' Jenkinsfile-ci || \
  fail "Jenkinsfile-ci's Guard must verify the range base still exists before using it"
pass=$((pass+1))

# ---- the CI/CD credential boundary --------------------------------------------------------------
# Task 4 review finding P1: both jobs were configured with voteball-deploy-key, a WRITE-capable
# credential. The split's entire claim is that CI cannot affect what is deployed -- carefully true on
# the IRSA axis (CI pushes to ECR, CD is ECR read-only) and the Kubernetes RBAC axis (CD's
# ServiceAccount is read-only in devops-app), and quietly false on the credential axis.
#
# The repository is public, so CI checks out over anonymous HTTPS with no credential at all.
JY="ci/jenkins/jenkins.yaml"
if [ -f "$JY" ]; then
  # Comments stripped: this file's own prose names the credential while explaining why CI no longer
  # uses it, and counting that would make the assertion pass on a config where CI still holds it.
  jy_code="$(sed -e 's|^[[:space:]]*//.*$||' -e 's|^[[:space:]]*#.*$||' "$JY")"
  uses="$(printf '%s\n' "$jy_code" | grep -c "credentials('voteball-deploy-key')" || true)"
  [ "$uses" = "1" ] || \
    fail "expected EXACTLY ONE job to use voteball-deploy-key (application-cd, which pushes promotions); found $uses. If application-ci has it again, CI can push to the repository and the CI/CD split is decorative."
  pass=$((pass+1))

  # ...and it must be the CD job that has it, not CI. Counting alone would pass if the two swapped.
  ci_block="$(printf '%s\n' "$jy_code" | awk "/pipelineJob\\('application-ci'\\)/,/scriptPath\\('Jenkinsfile-ci'\\)/")"
  printf '%s\n' "$ci_block" | grep -q "credentials(" && \
    fail "application-ci's SCM block configures a credential again. It must check out anonymously (public repo) so CI holds nothing that can write to the repository."
  pass=$((pass+1))

  printf '%s\n' "$ci_block" | grep -q "url('https://github.com" || \
    fail "application-ci must check out over anonymous HTTPS. An SSH remote implies a credential, which is what finding P1 was about."
  pass=$((pass+1))
fi

echo "PASS: $pass assertions"
