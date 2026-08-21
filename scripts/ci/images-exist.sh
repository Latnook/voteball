#!/usr/bin/env bash
# G1 -- terraform/ecr.tf sets image_tag_mutability = "IMMUTABLE", so pushing an existing tag is
# rejected. Because tags are the commit SHA, re-running a build (routine in Jenkins) would fail at
# the push step for no real reason.
#
# Prints "present" only if EVERY repository already holds this tag, else "missing".
#
# Fails safe in the opposite direction to should-skip-build.sh: any lookup failure yields "missing"
# and the pipeline rebuilds. A redundant build is harmless; a green build that shipped nothing is not.
set -euo pipefail

# AWS CLI v2 pages its output when stdout is a terminal, which would hang this script when it is run
# by hand at a laptop. Set here rather than inherited: this is one of the few scripts that does NOT
# source scripts/lib/config.sh (it must run inside a CI container with no repo checkout layout
# assumptions), so it carries its own guard. See that file for the full reasoning.
export AWS_PAGER=""

: "${ECR_REPOS:?ECR_REPOS must be set (space-separated repository names)}"
: "${TAG:?TAG must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"

# Tests override this to run offline; production uses the real CLI.
describe="${CI_STUB_DESCRIBE_CMD:-}"

for repo in $ECR_REPOS; do
  if [ -n "$describe" ]; then
    "$describe" "$repo" "$TAG" >/dev/null 2>&1 || { echo "missing"; exit 0; }
  else
    aws ecr describe-images \
      --repository-name "$repo" \
      --image-ids "imageTag=$TAG" \
      --region "$AWS_REGION" >/dev/null 2>&1 || { echo "missing"; exit 0; }
  fi
done

echo "present"
