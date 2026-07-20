#!/usr/bin/env bash
# Build the four app images and push them to ECR with a git-SHA tag.
# Requires: docker, aws CLI credentials for your account, and an applied terraform-eks stack.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

. scripts/lib/config.sh
REGISTRY="$(tf_out ecr_registry)"
TAG="$(git rev-parse --short HEAD)"

echo "Logging in to ECR ${REGISTRY}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() {
  local repo="$1" ctx="$2"
  echo "==> ${repo}:${TAG}"
  docker build -t "${REGISTRY}/${repo}:${TAG}" "$ctx"
  docker push "${REGISTRY}/${repo}:${TAG}"
}

build_push "${CLUSTER}-backend" services/backend
build_push "${CLUSTER}-worker"  services/worker
build_push "${CLUSTER}-nginx"   services/frontend
build_push "${CLUSTER}-backup"  services/backup

echo
echo "Pushed all images at tag: ${TAG}"
echo "Run ./scripts/sync-values-from-tf.sh to pin it in charts/voteball/values.yaml"
