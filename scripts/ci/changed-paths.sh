#!/usr/bin/env bash
# Did anything under <path-prefix> change since the last SUCCESSFUL build?
#
# G3c. Jenkins' `when { changeset 'services/**' }` diffs against the PREVIOUS build, not the
# previous SUCCESSFUL one. So a build that FAILS consumes its changeset: the next build's changelog
# starts at the failed build's commit, whatever that build was carrying now sits BEHIND the range,
# and no later `changeset` can ever see it again. The pipeline goes green and ships nothing.
#
# This is the same shape as the 2026-08-21 incident the Guard stage was hardened against
# (Jenkinsfile-ci G2, scripts/ci/should-skip-build.sh --subjects) -- there a promotion commit hid a
# source commit behind the tip; here a failed build hides its own changes behind the range base. The
# Guard was given GIT_PREVIOUS_SUCCESSFUL_COMMIT and the `when` conditions were not, which is why
# the same trap fired twice. Observed 2026-09-08: seed.sql changed in a build that failed on an
# unrelated broken test, the follow-up commit touched only scripts/tests/**, and the green build
# skipped Build, Push and Trigger CD -- a party stayed on a live public ballot after being taken off
# it in git.
#
# usage: changed-paths.sh <base-ref> <path-prefix>
#
# Prints "true" or "false" on stdout, and nothing else -- it is read with returnStdout.
#
# It prints "true", explaining on stderr, whenever the base is missing or unusable: an empty
# GIT_PREVIOUS_SUCCESSFUL_COMMIT (the first build of a job, or the first after a controller rebuild)
# or a base that no longer exists after a history rewrite. "Cannot tell what changed" must BUILD --
# the same fail-safe direction as G3b's NO_CHANGELOG and images-exist.sh, and for the same reason: a
# redundant build is harmless and bounded by G1, a green build that shipped nothing is not.
set -euo pipefail

base="${1-}"
prefix="${2-}"

[ -n "$prefix" ] || { echo "usage: $0 <base-ref> <path-prefix>" >&2; exit 2; }

if [ -z "$base" ]; then
  echo "changed-paths: no base ref (first build of this job?) -- cannot tell what changed, assuming yes." >&2
  echo true
  exit 0
fi

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  echo "changed-paths: base ${base} is not in this repository (history rewritten?) -- assuming yes." >&2
  echo true
  exit 0
fi

# --diff-filter is deliberately absent: a DELETED file under services/ changes the image too.
if git diff --name-only "${base}" HEAD -- "$prefix" | grep -q .; then
  echo true
else
  echo false
fi
