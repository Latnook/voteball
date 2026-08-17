#!/usr/bin/env bash
# Resolve the tag an automatic rollback should target -- and refuse to name one that cannot actually
# be deployed.
#
# WHY THIS IS NOT JUST previous-tag.sh. That script answers "what did values.yaml say before this
# deploy?" from git history alone, which is the right question but not a sufficient one. Git history
# survives a teardown; ECR does not. `terraform destroy` deletes the ECR repositories
# (terraform/ecr.tf sets force_delete = true) and the next `deploy.sh` pushes exactly ONE tag, so
# between a rebuild and the first successful CD promote, the tag git names as "previous" is a tag
# from the PREVIOUS cluster's registry and is not present in this one at all.
#
# Observed on 2026-08-17, immediately after a rebuild: previous-tag.sh returned 61256d4 while ECR
# held only 480ee8b.
#
# Left unchecked, post { failure } triggers a rollback build against that missing tag. The rollback
# build then dies in Input Validation -- which runs BEFORE Promote, so PROMOTE_SHA is never set, the
# depth-bounded retry logic never runs, and the pipeline reports "Images for <tag> are NOT all in ECR"
# as though someone had typed a bad parameter. The real cause ("the image you want to roll back to was
# deleted with the old cluster") appears nowhere, and production stays on the broken version.
#
# Usage:
#   rollback-target.sh            resolve the previous tag from git history, then check ECR
#   rollback-target.sh <tag>      check ECR for <tag> only -- caller already resolved it
#
# The second form exists because of a container split, not for convenience. This runs from
# Jenkinsfile-cd's post { failure }, and NO single container in the voteball-deploy pod is proven to
# do both halves against this workspace: `git` is exercised in jnlp (the Promote stage pushes from
# there) and `aws` in the `deploy` container (Input Validation calls images-exist.sh there). Rather
# than assume one image covers both, the pipeline resolves the tag in jnlp and passes it here, run
# in `deploy`. Same split, same reason, as Jenkinsfile-ci running its script suite twice.
#
# Output contract:
#   <tag>                 exit 0 -- this tag is in ECR; rolling back to it is safe to attempt
#   NO_ROLLBACK_TARGET <tag>  exit 3 -- <tag> is named as previous, but it is not in ECR
#   NO_PREVIOUS_TAG       exit 4 -- there is no previous tag at all (nothing has been promoted yet)
#
# FAILS SAFE TOWARD "NEEDS A HUMAN", which is the OPPOSITE direction to images-exist.sh's own
# fail-safe (any lookup failure there yields "missing" so the pipeline rebuilds -- a redundant build
# is cheap). Here a lookup failure yields "do not roll back" instead, because the alternative is
# launching a build that will fail confusingly several minutes later. A human is already required at
# this point -- a deploy just failed verification -- so the useful thing to optimise for is telling
# them the truth immediately, not attempting a recovery that cannot work.
set -uo pipefail

cd "$(dirname "$0")/../.."

: "${ECR_REPOS:?ECR_REPOS must be set (space-separated repository names)}"
: "${AWS_REGION:?AWS_REGION must be set}"

if [ $# -ge 1 ]; then
  prev="$1"
else
  prev="$(scripts/ci/previous-tag.sh 2>/dev/null)"
fi

if [ -z "$prev" ]; then
  echo "NO_PREVIOUS_TAG"
  exit 4
fi

# TAG is what images-exist.sh checks; override it for the ROLLBACK target rather than the tag being
# deployed. Everything else (ECR_REPOS, AWS_REGION, CI_STUB_DESCRIBE_CMD) is inherited unchanged.
if [ "$(TAG="$prev" scripts/ci/images-exist.sh 2>/dev/null)" = "present" ]; then
  echo "$prev"
  exit 0
fi

echo "NO_ROLLBACK_TARGET $prev"
exit 3
