#!/usr/bin/env bash
# Runs the offline script tests as one CI gate. Called by Jenkinsfile-ci's "Script tests" stage.
#
# WHY THIS EXISTS: until 2026-08-11 nothing in the pipeline ran scripts/tests/ at all -- CI ran
# pytest for services/{backend,worker} and stopped. So the guards that protect the pipeline itself
# (the skip-marker loop guard, the immutable-tag re-run check, the values.yaml drift check, the
# dirty-tree guard) were covered by tests that only ran when somebody remembered. The root CLAUDE.md
# says "pipeline logic that can only be tested by running the pipeline is exactly what this project
# refuses to accept"; this file makes that true of the tests as well.
#
# WHY THERE ARE GROUPS: no container in the voteball-build pod has both python3 and git. The `python`
# container (python:3.12-slim) has python3 and no git; the default `jnlp` container has git -- it
# performs the checkout -- and no python3. Build #7 proved this the expensive way: the whole suite ran
# in jnlp and four tests died on "python3: command not found". Rather than add tooling to an image
# (which needs a terraform apply) the suite is split, and each group runs where its dependencies are.
#
# Usage:  run-ci-suite.sh            -- run everything (local; assumes python3 AND git)
#         run-ci-suite.sh python     -- the group needing python3, no git       (container: python)
#         run-ci-suite.sh git        -- the group needing git, no python3       (container: jnlp)
set -uo pipefail

cd "$(dirname "$0")/../.."   # repo root

# Needs python3, does NOT need git. Verified 2026-08-11 by running each inside a bare
# python:3.12-slim -- not by reading the scripts, which mention `aws` and `terraform` in comments and
# stub variables and would mislead a grep. Reading them is exactly how build #7 went wrong.
PYTHON_GROUP=(
  check-jenkinsfile-shell.sh
  test-argocd-sync-wait.sh
  # Needs neither python3 nor git (bash + awk, grep, sort, timeout; aws/kubectl/helm are all
  # replaced by fake executables) -- confirmed passing inside a bare python:3.12-slim on 2026-08-21,
  # per the rule above.
  test-aws-progress-watch.sh
  # Needs neither python3 nor git (bash + find, grep, sed over the repo's own files) -- confirmed
  # passing inside a bare python:3.12-slim on 2026-08-21, per the rule above.
  test-aws-pager-guard.sh
  test-bootstrap-backend.sh
  test-ci-guards.sh
  test-deploy-env.sh
  test-frontend-seo.sh
  test-i18n-parity.sh
  # Needs neither python3 nor git (bash + grep only), so it could sit in either group. Placed here
  # and confirmed passing inside a bare python:3.12-slim on 2026-08-12, per the rule above.
  test-logo-assets.sh
  # Needs neither python3 nor git (bash + curl-free stubbed queries, awk, grep, sed only) -- confirmed
  # passing inside a bare python:3.12-slim on 2026-08-18, per the rule above.
  test-monitoring-gate.sh
  # Needs neither python3 nor git (bash + grep, sed, awk, comm over the repo's own files) -- confirmed
  # passing inside a bare python:3.12-slim AND a bare alpine/git on 2026-08-20, per the rule above.
  # Placed here rather than in GIT_GROUP only because that group runs a two-test container; nothing
  # about this test prefers one.
  test-observability-docs.sh
  # Needs python3 (the script it tests rewrites the tfvars line through a python one-liner) and no
  # git -- confirmed passing inside a bare python:3.12-slim on 2026-08-23, per the rule above. The
  # public-IP lookup is stubbed via VOTEBALL_PUBLIC_IP_CMD, so it never touches the network.
  test-refresh-api-cidr.sh
  test-render-argocd-app.sh
  test-smoke-test.sh
  test-sync-values.sh
  test-validate-repo.sh
)

# Needs git (it builds throwaway repositories), does NOT need python3. Confirmed passing in jnlp by
# build #7 before the suite as a whole failed.
GIT_GROUP=(
  test-build-push-ecr.sh
  # Builds throwaway git repositories with a handmade values.yaml promote history -- the disagreement
  # between git and ECR is the whole point of the test, so it cannot be stubbed without a real repo.
  # Confirmed passing inside a bare alpine/git image (no python3) on 2026-08-17, per the rule above.
  test-rollback-target.sh
)

# Excluded, each for a tool no container in the build pod carries. These still run by hand.
# Moving one into a group means putting that tool in an image, not loosening the test.
declare -A SKIP=(
  [test-jenkins-chart.sh]="needs helm (chart template rendering)"
  [test-register-github-ci.sh]="needs the gh CLI"
  [test-validate-observability.sh]="needs helm (chart template rendering); confirmed absent from both python:3.12-slim and jenkins/inbound-agent (jnlp) on 2026-08-18"
  [test-webhook-wait.sh]="needs curl, absent from the agent's slim images"
)

fail() { echo "FAIL: $*" >&2; exit 1; }

group="${1:-all}"
case "$group" in
  all)    RUN=("${PYTHON_GROUP[@]}" "${GIT_GROUP[@]}") ;;
  python) RUN=("${PYTHON_GROUP[@]}") ;;
  git)    RUN=("${GIT_GROUP[@]}") ;;
  *)      fail "unknown group '$group' (expected: python, git, or no argument)" ;;
esac

# Anti-drift: every test file must be classified, whichever group is being run. This check is
# deliberately independent of `group` -- otherwise `run-ci-suite.sh git` would happily ignore an
# unclassified test and the pipeline would still be green.
missing=()
for f in scripts/tests/*.sh; do
  n="$(basename "$f")"
  [ "$n" = "run-ci-suite.sh" ] && continue
  listed=0
  for r in "${PYTHON_GROUP[@]}" "${GIT_GROUP[@]}"; do [ "$r" = "$n" ] && listed=1; done
  [ -n "${SKIP[$n]:-}" ] && listed=1
  [ "$listed" = 1 ] || missing+=("$n")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "FAIL: these tests are in no group and not skipped, in $(basename "$0"):" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Add each to PYTHON_GROUP, GIT_GROUP, or SKIP with the tool it needs." >&2
  exit 1
fi

# The reverse: a listed test that no longer exists would otherwise pass silently.
for r in "${PYTHON_GROUP[@]}" "${GIT_GROUP[@]}"; do
  [ -f "scripts/tests/$r" ] || fail "'$r' is listed in a group but scripts/tests/$r does not exist"
done
for s in "${!SKIP[@]}"; do
  [ -f "scripts/tests/$s" ] || fail "SKIP lists '$s' but scripts/tests/$s does not exist"
done

echo "==> Script tests [group: ${group}] -- ${#RUN[@]} to run, ${#SKIP[@]} skipped overall"
if [ "$group" != "git" ]; then
  for s in "${!SKIP[@]}"; do echo "    skip: $s -- ${SKIP[$s]}"; done
fi
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
  echo "FAILED (${#failed[@]}/${#RUN[@]}) in group '${group}': ${failed[*]}" >&2
  exit 1
fi
echo "PASS — all ${#RUN[@]} script tests green [group: ${group}]"
