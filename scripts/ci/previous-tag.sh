#!/usr/bin/env bash
# Rollback support. Prints the image tag that values.yaml named BEFORE the most recent change to it.
#
# Rollback goes through git rather than `argocd app rollback` (design doc section 8): reverting only
# in ArgoCD would leave master asserting a version the cluster is not running, and selfHeal would
# then reapply the bad tag at the next reconciliation. Rewriting git keeps one source of truth.
set -euo pipefail

values="${VALUES_FILE:-charts/voteball/values.yaml}"

# WHICH BRANCH'S history to read. Since 2026-08-23 the deployed branch is `release`, not `master` --
# promotions are written there by scripts/ci/promote-to-release.sh, so that is where the sequence of
# deployed tags lives. Defaults to HEAD so a local run and the existing tests behave as before;
# Jenkinsfile-cd passes origin/release explicitly, because its workspace is checked out on master and
# master's values.yaml history no longer records what was deployed.
ref="${VALUES_REF:-HEAD}"

# -2 not -1: the most recent revision is the tag we just promoted and are rolling back FROM.
#
# The capture group is [^"]* (stop at the first closing quote), not .* -- the line carries a
# trailing comment ("tag: "abc1234" # git-SHA tag pushed by ..."), and a greedy .* would match past
# that comment's own characters, leaving it stuck to the captured SHA instead of stripped.
prev="$(git log -p --format='%H' "$ref" -- "$values" \
        | grep -E '^\+\s*tag: "' \
        | sed -E 's/^\+\s*tag: "([^"]*)".*/\1/' \
        | sed -n '2p')"

if [ -z "$prev" ]; then
  echo "no-previous-tag" >&2
  exit 1
fi

echo "$prev"
