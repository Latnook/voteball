#!/usr/bin/env bash
# Offline test for scripts/ci/validate-repo.sh. Same stub pattern as test-ci-guards.sh: the script
# under test is pointed at a throwaway tree, so nothing here touches the real repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

scaffold() {
  rm -rf "$work"/repo && mkdir -p "$work"/repo
  cd "$work"/repo
  for svc in backend worker frontend backup; do
    mkdir -p "services/$svc"
    printf 'FROM python:3.12-slim\n' > "services/$svc/Dockerfile"
    printf '__pycache__\n' > "services/$svc/.dockerignore"
  done
  mkdir -p charts/voteball
  printf 'apiVersion: v2\nname: voteball\nversion: 0.1.0\n' > charts/voteball/Chart.yaml
}

echo "--- a well-formed tree passes ---"
scaffold
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "clean tree should pass"

echo "--- a missing .dockerignore fails ---"
scaffold
rm services/worker/.dockerignore
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "missing .dockerignore should fail"

echo "--- a missing Dockerfile fails ---"
scaffold
rm services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "missing Dockerfile should fail"

echo "--- a floating base image fails ---"
scaffold
printf 'FROM python:latest\n' > services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "FROM ...:latest should fail"

echo "--- an untagged base image fails ---"
scaffold
printf 'FROM python\n' > services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "untagged FROM should fail"

echo "ALL TESTS PASSED"
