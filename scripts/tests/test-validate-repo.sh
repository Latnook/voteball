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
    # Digest-pinned, because the clean scaffold must satisfy every rule the real repo does -- the
    # digest requirement landed 2026-08-23 (Task 3 review T3-2). The digest itself is a fixed dummy;
    # nothing here resolves it, and using the real one would make this scaffold need updating every
    # time an upstream base moves.
    printf 'FROM python:3.12-slim@sha256:%s\n' "$(printf '0%.0s' $(seq 64))" > "services/$svc/Dockerfile"
    printf '__pycache__\n' > "services/$svc/.dockerignore"
  done
  mkdir -p charts/voteball/templates
  printf 'apiVersion: v2\nname: voteball\nversion: 0.1.0\n' > charts/voteball/Chart.yaml
  # An empty MAP is in the clean scaffold on purpose: `podSelector: {}` is meaningful (it selects
  # every pod) and the API server keeps it, so the empty-list check below must not fire on it.
  printf 'kind: NetworkPolicy\nspec:\n  podSelector: {}\n  policyTypes: [Egress]\n' \
    > charts/voteball/templates/networkpolicy.yaml
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

echo "--- an empty list literal in a chart template fails ---"
scaffold
printf 'kind: NetworkPolicy\nspec:\n  egress:\n    - to: []\n' \
  > charts/voteball/templates/networkpolicy.yaml
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "\`to: []\` should fail"

echo "--- ... including one that is not the first thing on its line ---"
scaffold
printf 'kind: Deployment\nspec:\n  template:\n    spec:\n      imagePullSecrets: []\n' \
  > charts/voteball/templates/backend-deployment.yaml
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "\`imagePullSecrets: []\` should fail"

# --- base image digest pinning ---------------------------------------------------------------
echo "--- a base image pinned by TAG ONLY fails ---"
# Allowed by the brief's no-latest rule and still a reproducibility hole: python:3.12-slim is a
# different image every few weeks, so a git-SHA image tag describes the source exactly and the base
# not at all. Task 3 review finding T3-2.
scaffold
printf 'FROM python:3.12-slim\n' > services/backend/Dockerfile
out="$("$ROOT/scripts/ci/validate-repo.sh" 2>&1)" && fail "a tag-only base image should fail"
grep -q "by tag only" <<<"$out" || fail "the failure should say the base is tag-only, got: $out"

echo "--- ... and the fix it suggests is the one that exists ---"
grep -q "refresh-base-digests.sh" <<<"$out" || fail "the failure should name ./scripts/refresh-base-digests.sh"
[ -x "$ROOT/scripts/refresh-base-digests.sh" ] || fail "validate-repo points at scripts/refresh-base-digests.sh, which is missing or not executable"

echo "--- a build-arg base reference is still allowed ---"
# Multi-stage builds and ARG-driven bases cannot be digest-pinned in the FROM line; rejecting them
# would make the check unusable rather than strict.
scaffold
printf 'ARG BASE=python:3.12-slim\nFROM $BASE\n' > services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "a build-arg base reference should still pass"

echo "--- ci/jenkins/Dockerfile is scanned too, not just services/ ---"
# It was outside this loop until 2026-08-23, which is how the controller base sat on a floating
# lts-jdk21 tag through several reviews -- the one drift the Task 4 review actually caught.
scaffold
mkdir -p ci/jenkins
printf 'FROM jenkins/jenkins:lts-jdk21\n' > ci/jenkins/Dockerfile
out="$("$ROOT/scripts/ci/validate-repo.sh" 2>&1)" && fail "an unpinned ci/jenkins/Dockerfile should fail"
grep -q "ci/jenkins/Dockerfile" <<<"$out" || fail "the controller Dockerfile must be scanned, got: $out"

echo "--- ... and latest is still rejected everywhere ---"
scaffold
mkdir -p ci/jenkins
printf 'FROM jenkins/jenkins:latest\n' > ci/jenkins/Dockerfile
out="$("$ROOT/scripts/ci/validate-repo.sh" 2>&1)" && fail "FROM ...:latest in ci/jenkins should fail"
grep -q "latest tag" <<<"$out" || fail "expected the latest-tag message, got: $out"

# --- egress coverage -------------------------------------------------------------------------
# The 2026-08-23 split of allow-app-egress into four per-workload policies (Task 3 review T3-1) made
# it four times easier to add a workload and forget its egress rule. That failure is invisible at
# runtime -- default-deny plus a DNS-for-everyone policy means the pod resolves names fine and has
# every TCP connection dropped with no event and no log -- so it has to be caught here or not at all.
#
# The scaffold below is the shape that matters: a real pod-bearing kind carrying an `app:` label,
# alongside a networkpolicy.yaml holding a DNS-for-all policy and one selective egress policy.
egress_scaffold() {   # egress_scaffold <selector-yaml-fragment>
  scaffold
  cat > charts/voteball/templates/worker-deployment.yaml <<'YAML'
kind: Deployment
metadata:
  name: worker
spec:
  template:
    metadata:
      labels: { app: worker }
YAML
  cat > charts/voteball/templates/networkpolicy.yaml <<YAML
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
spec:
  podSelector: {}
  policyTypes: [Egress]
---
kind: NetworkPolicy
metadata:
  name: allow-db-egress
spec:
  podSelector:
$1
  policyTypes: [Egress]
YAML
}

echo "--- a workload named by an egress policy passes (matchExpressions list form) ---"
egress_scaffold '    matchExpressions:
      - { key: app, operator: In, values: [backend, worker, backup] }'
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "a workload inside a values: [...] list should pass"

echo "--- ... and the matchLabels form ---"
egress_scaffold '    matchLabels: { app: worker }'
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "a workload named by matchLabels should pass"

echo "--- a workload named by NO egress policy fails ---"
# This is the backup CronJob's real 2026-07-19 bug, reproduced: the pod exists, the policy exists,
# and the label is simply not in the list.
egress_scaffold '    matchExpressions:
      - { key: app, operator: In, values: [backend, backup] }'
out="$("$ROOT/scripts/ci/validate-repo.sh" 2>&1)" && fail "a workload absent from every egress selector should fail"
grep -q "app: worker" <<<"$out" || fail "the failure should name the uncovered label, got: $out"

echo "--- being covered ONLY by the all-pods DNS policy is not coverage ---"
# The whole point. allow-dns-egress selects {} -- every pod -- so a check that counted it would pass
# on precisely the broken state it exists to catch.
egress_scaffold '    matchLabels: { app: something-else }'
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "allow-dns-egress must not count as egress coverage"

echo "--- a label that appears only in a COMMENT does not count as coverage ---"
# This file's own policy comments quote `app: backend` and `app: migrate` while explaining the rules.
# Counting comment text would make the check pass on a repo whose real selector had been deleted.
egress_scaffold '    matchLabels: { app: something-else }'
cat >> charts/voteball/templates/networkpolicy.yaml <<'YAML'
      # a prose mention of app: worker must not satisfy the check
YAML
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "a commented-out label must not count as coverage"

echo "--- an INGRESS-only policy naming the label does not count as egress coverage ---"
egress_scaffold '    matchLabels: { app: something-else }'
cat >> charts/voteball/templates/networkpolicy.yaml <<'YAML'
---
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-worker
spec:
  podSelector:
    matchLabels: { app: worker }
  policyTypes: [Ingress]
YAML
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "an Ingress policy must not satisfy the egress check"

echo "--- a Service manifest's app label is not treated as a workload ---"
# Services carry `app:` selectors too, but a Service is not a pod and has no egress of its own.
# Counting them would demand egress policies for things that cannot send traffic.
egress_scaffold '    matchLabels: { app: worker }'
cat > charts/voteball/templates/orphan-service.yaml <<'YAML'
kind: Service
metadata:
  name: orphan
spec:
  selector: { app: nonexistent }
YAML
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "a Service-only label must not require an egress policy"

echo "--- the REAL chart passes its own gate ---"
cd "$ROOT"
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "charts/voteball itself fails the egress-coverage gate"

echo "ALL TESTS PASSED"
