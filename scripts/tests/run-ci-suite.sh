#!/usr/bin/env bash
# Runs the offline script tests as one CI gate. Called by Jenkinsfile-ci's "Script tests" stage.
#
# WHY THIS EXISTS: until 2026-08-11 nothing in the pipeline ran scripts/tests/ at all -- CI ran
# pytest for services/{backend,worker} and nothing else. So the guards that protect the pipeline
# itself (the [skip ci] loop guard, the immutable-tag re-run check, the dirty-tree guard, the
# values.yaml drift check) were covered by tests that only ran when somebody remembered. The root
# CLAUDE.md says "pipeline logic that can only be tested by running the pipeline is exactly what
# this project refuses to accept"; this file is what makes that true of the tests as well.
#
# THE LISTS ARE EXHAUSTIVE ON PURPOSE. Every .sh in scripts/tests/ must appear in RUN or SKIP, and
# this script FAILS if one appears in neither. A glob would silently pick up a future test that
# needs helm and break every build; an unchecked hand-list would silently drop a new test and
# protect nothing. Adding a test therefore forces a one-line decision, which is the point.
set -uo pipefail

cd "$(dirname "$0")/../.."   # repo root

# Offline: bash, coreutils, python3 and git only. Verified 2026-08-11 by running each one inside a
# bare python:3.12-slim + git container -- not by reading the scripts, which mention `aws` and
# `terraform` in comments and stub variables and would mislead a grep.
RUN=(
  check-jenkinsfile-shell.sh
  test-argocd-sync-wait.sh
  test-bootstrap-backend.sh
  test-build-push-ecr.sh
  test-ci-guards.sh
  test-deploy-env.sh
  test-frontend-seo.sh
  test-i18n-parity.sh
  test-render-argocd-app.sh
  test-smoke-test.sh
  test-sync-values.sh
  test-validate-repo.sh
)

# Excluded, each for a tool the build agent does not carry. These still run by hand.
# Moving one into RUN means putting that tool in the agent, not loosening the test.
declare -A SKIP=(
  [test-jenkins-chart.sh]="needs helm (chart template rendering)"
  [test-register-github-ci.sh]="needs the gh CLI"
  [test-webhook-wait.sh]="needs curl, absent from the agent's slim images"
)

fail() { echo "FAIL: $*" >&2; exit 1; }

# Anti-drift: every test file must be classified. This is the check that keeps the lists honest.
missing=()
for f in scripts/tests/*.sh; do
  n="$(basename "$f")"
  [ "$n" = "run-ci-suite.sh" ] && continue
  listed=0
  for r in "${RUN[@]}"; do [ "$r" = "$n" ] && listed=1; done
  [ -n "${SKIP[$n]:-}" ] && listed=1
  [ "$listed" = 1 ] || missing+=("$n")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "FAIL: these tests are in neither RUN nor SKIP in $(basename "$0"):" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Add each to RUN (if it needs only bash/python3/git) or to SKIP with the tool it needs." >&2
  exit 1
fi

# Also catch the reverse: a listed test that no longer exists, which would otherwise pass silently.
for r in "${RUN[@]}"; do
  [ -f "scripts/tests/$r" ] || fail "RUN lists '$r' but scripts/tests/$r does not exist"
done
for s in "${!SKIP[@]}"; do
  [ -f "scripts/tests/$s" ] || fail "SKIP lists '$s' but scripts/tests/$s does not exist"
done

echo "==> Script test suite: ${#RUN[@]} to run, ${#SKIP[@]} skipped"
for s in "${!SKIP[@]}"; do echo "    skip: $s -- ${SKIP[$s]}"; done
echo

failed=()
for t in "${RUN[@]}"; do
  printf '==> %s\n' "$t"
  if bash "scripts/tests/$t" > "/tmp/$t.log" 2>&1; then
    echo "    PASS"
  else
    echo "    FAIL (last 20 lines):"
    tail -20 "/tmp/$t.log" | sed 's/^/      /'
    failed+=("$t")
  fi
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED (${#failed[@]}/${#RUN[@]}): ${failed[*]}" >&2
  exit 1
fi
echo "PASS — all ${#RUN[@]} script tests green"
