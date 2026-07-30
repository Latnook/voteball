#!/usr/bin/env bash
# Build the four app images and push them to ECR with a git-SHA tag.
# Pass "jenkins" as the sole argument to instead build the Jenkins controller image
# (ci/jenkins) into ${CLUSTER}-jenkins -- not part of the per-commit pipeline, so it is a
# separate, by-hand target rather than a fifth entry below.
#
# "jenkins" takes an optional second argument: the tag to push under. Default is the current
# git SHA, matching the normal by-hand workflow (build, note the SHA, hand-bump
# jenkins_image_tag in voteball.tfvars to match). deploy.sh's fresh-rebuild step instead PASSES
# the tag already pinned in voteball.tfvars, so it reproduces that exact image under that exact
# tag with no tfvars edit needed -- required because ECR repos are force_delete'd on destroy, so
# a fresh rebuild's helm_release.jenkins has nothing to pull otherwise (see deploy.sh step 2).
#
# Requires: docker, aws CLI credentials for your account, and an applied terraform stack.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

. scripts/lib/config.sh
REGISTRY="$(tf_out ecr_registry)"
TAG="$(git rev-parse --short HEAD)"

echo "Logging in to ECR ${REGISTRY}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() {
  local repo="$1" ctx="$2" tag="${3:-$TAG}"
  echo "==> ${repo}:${tag}"
  docker build -t "${REGISTRY}/${repo}:${tag}" "$ctx"
  docker push "${REGISTRY}/${repo}:${tag}"
}

if [ "${1:-}" = "jenkins" ]; then
  JTAG="${2:-$TAG}"
  build_push "${CLUSTER}-jenkins" ci/jenkins "$JTAG"
  echo
  echo "Pushed jenkins image at tag: ${JTAG}"
  exit 0
fi

build_push "${CLUSTER}-backend" services/backend
build_push "${CLUSTER}-worker"  services/worker
build_push "${CLUSTER}-nginx"   services/frontend
build_push "${CLUSTER}-backup"  services/backup

echo
echo "Pushed all images at tag: ${TAG}"
echo "Run ./scripts/sync-values-from-tf.sh to pin it in charts/voteball/values.yaml"
