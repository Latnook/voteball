#!/usr/bin/env bash
# Rollback support. Prints the image tag that values.yaml named BEFORE the most recent change to it.
#
# Rollback goes through git rather than `argocd app rollback` (design doc section 8): reverting only
# in ArgoCD would leave master asserting a version the cluster is not running, and selfHeal would
# then reapply the bad tag at the next reconciliation. Rewriting git keeps one source of truth.
set -euo pipefail

values="${VALUES_FILE:-charts/voteball/values.yaml}"

# -2 not -1: the most recent revision is the tag we just promoted and are rolling back FROM.
#
# The capture group is [^"]* (stop at the first closing quote), not .* -- the line carries a
# trailing comment ("tag: "abc1234" # git-SHA tag pushed by ..."), and a greedy .* would match past
# that comment's own characters, leaving it stuck to the captured SHA instead of stripped.
prev="$(git log -p --format='%H' -- "$values" \
        | grep -E '^\+\s*tag: "' \
        | sed -E 's/^\+\s*tag: "([^"]*)".*/\1/' \
        | sed -n '2p')"

if [ -z "$prev" ]; then
  echo "no-previous-tag" >&2
  exit 1
fi

echo "$prev"
