#!/usr/bin/env bash
# Offline assertions on the rendered Jenkins release. Same pattern as test-sync-values.sh and
# test-ci-guards.sh: the dangerous properties are checked without touching a cluster.
#
# EXTEND THIS whenever the chart version is bumped. Its whole job is to catch a chart default
# quietly widening Jenkins' permissions -- a change that would deploy green and be invisible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template jenkins jenkins/jenkins --namespace ci \
  --version 5.9.45 \
  --set controller.installPlugins=false \
  --set controller.numExecutors=0 \
  --set persistence.enabled=false \
  --set rbac.create=true \
  --set rbac.readSecrets=false > "$rendered"

check "no ClusterRole is created"        "! grep -q '^kind: ClusterRole$' '$rendered'"
check "no ClusterRoleBinding is created" "! grep -q '^kind: ClusterRoleBinding$' '$rendered'"
check "a namespaced Role is created"     "grep -q '^kind: Role$' '$rendered'"
check "no PersistentVolumeClaim"         "! grep -q '^kind: PersistentVolumeClaim$' '$rendered'"
check "pods/exec is grantable"           "grep -q 'pods/exec' '$rendered'"

# The support chart renders offline with no cluster.
helm template jenkins-support "$REPO_ROOT/charts/jenkins-support" --namespace ci > "$rendered"
check "ExternalSecret rendered"  "grep -q 'kind: ExternalSecret' '$rendered'"
check "NetworkPolicy rendered"   "grep -q 'kind: NetworkPolicy' '$rendered'"
check "VPC range is excluded"    "grep -q '10.0.0.0/16' '$rendered'"

exit "$fail"
