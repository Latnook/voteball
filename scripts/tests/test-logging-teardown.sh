#!/usr/bin/env bash
# Teardown-ordering and DNS-cleanup guards for the EFK stack.
#
# Separate from test-logging-chart.sh ON PURPOSE: everything here greps script text and needs no
# helm, so it runs in CI's git container while the chart test is skipped for want of helm.
#
# The ValidatingWebhookConfiguration the ECK chart installs intercepts writes to *.k8s.elastic.co
# objects. If the operator is uninstalled BEFORE the Elasticsearch/Kibana custom resources are
# deleted, every CR delete blocks on a webhook with no backend alive to answer -- the same class as
# kubernetes_namespace.ci sitting Terminating forever on 2026-08-04. That failure costs a real
# teardown to discover, which is why it is asserted here instead.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "==> destroy.sh ECK ordering"
d=scripts/destroy.sh
grep -q 'kubectl delete elasticsearch' "$d"    || fail "destroy.sh must delete the Elasticsearch CR"
grep -q 'kubectl delete kibana' "$d"           || fail "destroy.sh must delete the Kibana CR"
grep -q 'helm uninstall elastic-operator' "$d" || fail "destroy.sh must uninstall the ECK operator"

cr_line="$(grep -n 'kubectl delete elasticsearch' "$d" | head -1 | cut -d: -f1)"
op_line="$(grep -n 'helm uninstall elastic-operator' "$d" | head -1 | cut -d: -f1)"
[ "$cr_line" -lt "$op_line" ] \
  || fail "destroy.sh uninstalls the ECK operator (line $op_line) BEFORE deleting its CRs (line $cr_line) -- the webhook will hang the teardown"
pass "CRs deleted before the operator"

grep -q 'helm uninstall logging' "$d" || fail "destroy.sh must uninstall the logging release"
pass "logging release pre-uninstalled"

echo "==> ArgoCD Application removal"
grep -q 'logging' "$d" || fail "destroy.sh step 1 must delete the logging ArgoCD Application, or selfHeal recreates what step 4 removes"
pass "logging Application deleted in step 1"

echo "==> cleanup-stale-dns.sh"
grep -qE 'kibana\.\$\{APP_DOMAIN\}' scripts/cleanup-stale-dns.sh \
  || fail "cleanup-stale-dns.sh must list kibana.\${APP_DOMAIN}, or its record strands on a dead ALB"
pass "kibana host covered"

echo "==> deploy.sh enables the gate"
grep -q '11e' scripts/deploy.sh || fail "deploy.sh must carry step 11e"
grep -q 'verify-efk.sh' scripts/deploy.sh \
  || fail "deploy.sh step 11e must run verify-efk.sh -- charts/logging ships gated off and nothing else turns it on"
pass "deploy.sh step 11e present"

echo "PASS: logging teardown/deploy guards"
