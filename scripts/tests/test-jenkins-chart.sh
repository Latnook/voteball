#!/usr/bin/env bash
# Assertions on the rendered Jenkins release -- NOT offline: `helm template jenkins/jenkins` fetches
# that chart version from charts.jenkins.io (or your local Helm cache of it) the same as any other
# `helm template` against a repository chart. Same pattern as test-sync-values.sh and
# test-ci-guards.sh in every OTHER respect: the dangerous properties are checked without touching a
# cluster, and it needs no AWS credentials.
#
# EXTEND THIS whenever the chart version is bumped. Its whole job is to catch a chart default
# quietly widening Jenkins' permissions -- a change that would deploy green and be invisible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Derive the chart version from terraform/addon-jenkins.tf's `local.jenkins_chart_version` rather
# than hardcoding a second literal here. Two literals drift apart silently: bump Terraform alone and
# this test would keep asserting the OLD chart, defeating the "EXTEND THIS" comment above. Override
# with JENKINS_CHART_VERSION for a one-off run against a version not yet committed.
JENKINS_CHART_VERSION="${JENKINS_CHART_VERSION:-}"
if [ -z "$JENKINS_CHART_VERSION" ]; then
  TF_ADDON_FILE="$REPO_ROOT/terraform/addon-jenkins.tf"
  JENKINS_CHART_VERSION="$(sed -nE \
    's/^[[:space:]]*jenkins_chart_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$TF_ADDON_FILE" | head -1)"
fi
if [ -z "$JENKINS_CHART_VERSION" ]; then
  echo "FAIL - could not derive jenkins_chart_version from terraform/addon-jenkins.tf" >&2
  echo "       (set JENKINS_CHART_VERSION to override)" >&2
  exit 1
fi
echo "Testing against jenkins/jenkins chart version ${JENKINS_CHART_VERSION}"

# pods/exec must be authorised under BOTH verbs: a SPDY exec upgrade is an HTTP POST (authorises as
# `create`), a WebSocket upgrade is a GET (authorises as `get`), and EKS 1.36 enables
# ExtendWebSocketsToKubelet by default (design doc section 7). The stock chart grants the two verbs
# from two SEPARATE rules on the same Role, so a plain `grep -q pods/exec` passes even if a future
# chart regression drops one of them -- it would still print "ok" while silently reintroducing a 403
# on the first `sh` step of every build. This collects the UNION of verbs across every rule whose
# `resources` list contains "pods/exec" and requires both to be present.
#
# Prefers a real YAML parse (python3 + PyYAML, already a test-suite dependency here -- see
# test-sync-values.sh / test-i18n-parity.sh); falls back to a context-aware awk walk over the
# apiGroups/resources/verbs triplets if PyYAML is unavailable, rather than a bare grep.
pods_exec_verbs() {
  local file="$1"
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$file" <<'PYEOF'
import sys, yaml
verbs = set()
with open(sys.argv[1]) as f:
    for doc in yaml.safe_load_all(f):
        if not doc or doc.get("kind") != "Role":
            continue
        for rule in doc.get("rules", []):
            if "pods/exec" in (rule.get("resources") or []):
                verbs.update(rule.get("verbs") or [])
print(" ".join(sorted(verbs)))
PYEOF
  else
    awk '
      /^- apiGroups:/  { resources = ""; verbs = "" }
      /  resources:/   { resources = $0 }
      /  verbs:/ {
        verbs = $0
        if (resources ~ /pods\/exec/) { print verbs }
      }
    ' "$file" | grep -oE '"[a-zA-Z]+"' | tr -d '"' | sort -u | tr '\n' ' '
  fi
}

check_pods_exec_both_verbs() {
  local verbs
  verbs="$(pods_exec_verbs "$1")"
  [[ "$verbs" == *create* && "$verbs" == *get* ]]
}

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template jenkins jenkins/jenkins --namespace ci \
  --version "$JENKINS_CHART_VERSION" \
  --set controller.installPlugins=false \
  --set controller.numExecutors=0 \
  --set persistence.enabled=false \
  --set rbac.create=true \
  --set rbac.readSecrets=false > "$rendered"

check "no ClusterRole is created"          "! grep -q '^kind: ClusterRole$' '$rendered'"
check "no ClusterRoleBinding is created"   "! grep -q '^kind: ClusterRoleBinding$' '$rendered'"
check "a namespaced Role is created"       "grep -q '^kind: Role$' '$rendered'"
check "no PersistentVolumeClaim"           "! grep -q '^kind: PersistentVolumeClaim$' '$rendered'"
check "pods/exec grants both create+get"   "check_pods_exec_both_verbs '$rendered'"

# The support chart renders offline with no cluster.
helm template jenkins-support "$REPO_ROOT/charts/jenkins-support" --namespace ci > "$rendered"
check "ExternalSecret rendered"  "grep -q 'kind: ExternalSecret' '$rendered'"
check "NetworkPolicy rendered"   "grep -q 'kind: NetworkPolicy' '$rendered'"
check "VPC range is excluded"    "grep -q '10.0.0.0/16' '$rendered'"

exit "$fail"
