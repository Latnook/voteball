#!/usr/bin/env bash
# Print `name<TAB>sha256:...` for each of this project's four application images at a given TAG.
#
# WHY THIS IS SAFE TO DO BY LOOKUP rather than by plumbing digests between pipeline jobs:
# terraform/ecr.tf sets image_tag_mutability = "IMMUTABLE" on the four application repositories, so a
# tag names exactly one manifest for the lifetime of the repository. Resolving a tag to a digest is
# therefore repeatable and authoritative -- the answer cannot change under us, which is the whole
# property digest-pinning is trying to buy.
#
# The alternative (passing four digests from application-ci to application-cd as build parameters)
# was rejected because it has no answer for a chart-only promotion: there is no upstream CI build with
# freshly built images in that case, yet the chart still has to render digest-pinned workloads.
# Looking them up needs no special case, and rollback gets it for free -- re-resolving the previous
# tag yields precisely the digests that tag always had.
#
# Output is deliberately `name<TAB>digest`, not JSON: every consumer is shell, and the two callers
# that matter (deploy.sh step 9 and Jenkinsfile-cd's Promote) are writing values.yaml with sed.
#
# Names are the CHART's names (backend, worker, nginx, backup) -- note the frontend image is
# `voteball-nginx`, matching charts/voteball/templates/_helpers.tpl and build-push-ecr.sh.
set -euo pipefail

# AWS CLI v2 pages its output when stdout is a terminal, which hangs this script when run by hand.
# Set here rather than inherited: like images-exist.sh, this must run inside a CI container that has
# no repo checkout layout to source scripts/lib/config.sh from. See that file for the full reasoning.
export AWS_PAGER=""

: "${TAG:?TAG must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${ECR_PREFIX:=voteball}"

IMAGES="${IMAGES:-backend worker nginx backup}"

# Tests override this to run offline. Contract: <cmd> <repository> <tag> prints the digest, or exits
# non-zero if the tag is absent.
describe="${CI_STUB_DIGEST_CMD:-}"

status=0
for name in $IMAGES; do
  repo="${ECR_PREFIX}-${name}"
  if [ -n "$describe" ]; then
    digest="$("$describe" "$repo" "$TAG" 2>/dev/null)" || digest=""
  else
    digest="$(aws ecr describe-images \
      --repository-name "$repo" \
      --image-ids "imageTag=$TAG" \
      --region "$AWS_REGION" \
      --query 'imageDetails[0].imageDigest' \
      --output text 2>/dev/null)" || digest=""
  fi

  # `--output text` prints the literal string None for a null result rather than failing, so an
  # absent tag arrives here as "None", not as a non-zero exit. Checking only the exit code would
  # write the four-character string "None" into values.yaml as an image digest.
  case "$digest" in
    sha256:*) printf '%s\t%s\n' "$name" "$digest" ;;
    *)        echo "resolve-digests: $repo:$TAG has no digest (got '${digest:-<empty>}')" >&2
              status=1 ;;
  esac
done

exit "$status"
