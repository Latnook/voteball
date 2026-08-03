#!/usr/bin/env bash
# Tests scripts/register-github-ci.sh against REAL GitHub and a REAL cluster.
#
# WHY ONLINE RATHER THAN STUBBED, unlike test-ci-guards.sh and test-sync-values.sh: what this script
# has to get right is not its own control flow, it is what GitHub and Jenkins actually DO. A stub can
# only confirm the assumptions you already hold. Written online, this test immediately falsified one:
# the claim that a wrong webhook secret is rejected with 401. It is not -- Jenkins answers 200 and
# silently drops the event (see the 2026-08-03 findings in docs/deploy.md).
#
# WHAT IT MUTATES, and how it cleans up:
#   - creates and deletes a temporary webhook pointing at a NON-RESOLVING host (safe: nothing receives it)
#   - re-registers the real deploy key and webhook at the end, so the live pair is left valid
#   - with --test-fault-branch ONLY: scales the Jenkins StatefulSet to 0 and back (CI is down ~2 min)
#
# Requires a deployed cluster, gh authenticated, and AWS credentials.
#   scripts/tests/test-register-github-ci.sh                     # safe subset
#   scripts/tests/test-register-github-ci.sh --test-fault-branch # also takes Jenkins down briefly
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/config.sh
require_config

REPO="$(tfvar github_repo)"
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }

command -v gh >/dev/null || fail "gh is required"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
kubectl cluster-info >/dev/null 2>&1 || fail "no cluster reachable — this test needs a live deploy"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== 1. idempotent path: a second run must change nothing =="
out="$(./scripts/register-github-ci.sh 2>&1)" || fail "idempotent run exited non-zero"
grep -q "Already registered" <<<"$out" || fail "expected 'Already registered', got: $out"
grep -q "removed stale" <<<"$out" && fail "idempotent run must not delete anything"
ok "no-op when the vault key already matches GitHub"

echo "== 2. reachable path: probe returns 200 with a REAL round-trip duration =="
out="$(FORCE_REGISTER=1 ./scripts/register-github-ci.sh 2>&1)" || fail "forced run exited non-zero"
grep -q "registered key" <<<"$out" || fail "expected a key registration"
grep -q "Webhook reachable" <<<"$out" || fail "expected the reachable message, got: $out"
grep -q "does NOT verify the shared secret" <<<"$out" \
  || fail "the success message must NOT claim the secret was verified (2026-08-03 finding)"
ok "registers, probes, and does not overclaim about the secret"

echo "== 3. DNS-cache path: a non-resolving host must be reported CALMLY, not as a fault =="
# Drives the script at a domain that does not exist, via TFVARS -- no production DNS is touched.
cat > "$TMP/nx.tfvars" <<EOF
app_domain        = "nx-test.${APP_DOMAIN}"
route53_zone_name = "${ZONE_NAME}"
cluster_name      = "${CLUSTER}"
aws_region        = "${REGION}"
github_repo       = "${REPO}"
EOF
out="$(TFVARS="$TMP/nx.tfvars" FORCE_REGISTER=1 ./scripts/register-github-ci.sh 2>&1)" || true
bogus_hook="$(gh api "repos/${REPO}/hooks" --jq ".[] | select(.config.url|contains(\"nx-test\")) | .id" | head -1)"
[ -n "$bogus_hook" ] && gh api -X DELETE "repos/${REPO}/hooks/${bogus_hook}" --silent
grep -q "GitHub never opened a connection" <<<"$out" \
  || fail "non-resolving host should hit the DNS-cache branch, got: $out"
grep -q "WARNING" <<<"$out" && fail "a DNS-cache failure must NOT warn — it self-heals"
ok "classifies a sub-100ms failure as DNS cache and stays quiet"

if [ "${1:-}" = "--test-fault-branch" ]; then
  echo "== 4. fault path: no healthy target must WARN (takes Jenkins down ~2 min) =="
  kubectl scale statefulset jenkins -n ci --replicas=0 >/dev/null
  kubectl wait --for=delete pod/jenkins-0 -n ci --timeout=180s >/dev/null 2>&1 || true
  sleep 20
  out="$(FORCE_REGISTER=1 ./scripts/register-github-ci.sh 2>&1)" || true
  kubectl scale statefulset jenkins -n ci --replicas=1 >/dev/null
  kubectl rollout status statefulset/jenkins -n ci --timeout=300s >/dev/null
  grep -q "WARNING" <<<"$out" || fail "an unreachable backend must warn, got: $out"
  grep -q "not DNS" <<<"$out" || fail "the warning should distinguish itself from the DNS case"
  ok "classifies a realistic-duration failure as a real fault and warns"
else
  echo "== 4. fault path: SKIPPED (pass --test-fault-branch to run; it stops Jenkins briefly) =="
fi

echo "== restoring a valid live registration =="
FORCE_REGISTER=1 ./scripts/register-github-ci.sh >/dev/null 2>&1 || fail "could not restore registration"
keys="$(gh api "repos/${REPO}/keys" --jq 'length')"
hooks="$(gh api "repos/${REPO}/hooks" --jq "[.[] | select(.config.url|contains(\"nx-test\")|not)] | length")"
[ "$keys" = "1" ]  || fail "expected exactly 1 deploy key afterwards, found $keys"
[ "$hooks" = "1" ] || fail "expected exactly 1 real webhook afterwards, found $hooks"
ok "left exactly one valid deploy key and one webhook"

echo
echo "PASS: ${pass} assertions"
