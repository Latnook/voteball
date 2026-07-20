#!/usr/bin/env bash
# Build the three app images and push to ECR with a git-SHA tag. Run from the repo root.
# Requires: docker, aws CLI creds for account 590183895228, the Plan-2 ECR repos.
set -euo pipefail

REGION=il-central-1
ACCOUNT=590183895228
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TAG="$(git rev-parse --short HEAD)"

echo "Logging in to ECR ${REGISTRY}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() {
  local repo="$1" ctx="$2"
  echo "==> ${repo}:${TAG}"
  docker build -t "${REGISTRY}/${repo}:${TAG}" "$ctx"
  docker push "${REGISTRY}/${repo}:${TAG}"
}

build_push voteball-backend services/backend
build_push voteball-worker  services/worker
build_push voteball-nginx   services/frontend
build_push voteball-backup  services/backup

echo
echo "Pushed all images at tag: ${TAG}"
echo "Set image.tag=\"${TAG}\" in charts/voteball/values.yaml"
