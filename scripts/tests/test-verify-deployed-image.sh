#!/usr/bin/env bash
# Offline test for scripts/ci/verify-deployed-image.sh. kubectl is replaced by a fake; nothing here
# touches a cluster.
#
# THE CASE THAT MATTERS is the first failing one below: a digest-rendered image must VERIFY, not be
# rejected for "not carrying the tag". That is the live CD #1 regression of 2026-08-23 -- the deploy
# was correct, ArgoCD said Synced/Healthy, the site served 200, and Verify rolled it back anyway
# because the chart had started rendering repo@sha256:... and the check still looked for :tag.
set -uo pipefail

cd "$(dirname "$0")/../.."
SUT="$PWD/scripts/ci/verify-deployed-image.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; pass=$((pass+1)); }

REG="590183895228.dkr.ecr.il-central-1.amazonaws.com"
D_NGINX="sha256:1111111111111111111111111111111111111111111111111111111111111111"
D_BACK="sha256:2222222222222222222222222222222222222222222222222222222222222222"
D_WORK="sha256:3333333333333333333333333333333333333333333333333333333333333333"
ALL_DIGESTS="nginx=$D_NGINX backend=$D_BACK worker=$D_WORK"

# fake kubectl: prints whatever image the case under test assigned to that deployment
make_kubectl() {  # make_kubectl <frontend-image> <backend-image> <worker-image>
  cat > "$work/bin/kubectl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in frontend) echo -n '$1'; exit 0;; backend) echo -n '$2'; exit 0;; worker) echo -n '$3'; exit 0;; esac; done
exit 1
EOF
  chmod +x "$work/bin/kubectl"
}
run() { KUBECTL_CMD="$work/bin/kubectl" TAG="$1" IMAGE_DIGESTS="$2" NAMESPACE=devops-app bash "$SUT"; }

# ---- 1. THE CD #1 REGRESSION: digest-rendered images must PASS ----------------------------------
make_kubectl "$REG/voteball-nginx@$D_NGINX" "$REG/voteball-backend@$D_BACK" "$REG/voteball-worker@$D_WORK"
out="$(run abc1234 "$ALL_DIGESTS" 2>&1)" \
  || fail "THE CD #1 REGRESSION: digest-pinned deployments must verify, got:\n$out"
ok "digest-pinned deployments verify against the digests the tag resolves to"

# The frontend Deployment runs the *nginx* image. A naive name==name mapping breaks only on that one,
# which is the sort of thing that passes review and fails in production.
grep -q "frontend -> $REG/voteball-nginx@" <<<"$out" || fail "frontend/nginx mapping is wrong: $out"
ok "the frontend deployment is matched against the nginx image name"

# ---- 2. a WRONG digest must fail ----------------------------------------------------------------
# Otherwise case 1 proves only that the script exits 0, not that it compares anything.
WRONG="sha256:9999999999999999999999999999999999999999999999999999999999999999"
make_kubectl "$REG/voteball-nginx@$WRONG" "$REG/voteball-backend@$D_BACK" "$REG/voteball-worker@$D_WORK"
out="$(run abc1234 "$ALL_DIGESTS" 2>&1)" && fail "a mismatched digest must fail verification"
grep -q "is running $WRONG" <<<"$out" || fail "the error should name the running digest, got: $out"
ok "a deployment running a DIFFERENT digest fails verification"

# ---- 3. the tag fallback still works (empty digest map: fresh fork, or a failed ECR lookup) ------
make_kubectl "$REG/voteball-nginx:abc1234" "$REG/voteball-backend:abc1234" "$REG/voteball-worker:abc1234"
out="$(run abc1234 "" 2>&1)" || fail "tag-rendered deployments must still verify when no digests exist: $out"
ok "the tag fallback still verifies when the digest map is empty"

# ---- 4. a tag-rendered deployment carrying the WRONG tag fails ----------------------------------
make_kubectl "$REG/voteball-nginx:deadbee" "$REG/voteball-backend:abc1234" "$REG/voteball-worker:abc1234"
out="$(run abc1234 "" 2>&1)" && fail "a wrong tag must fail verification"
ok "a deployment carrying the wrong tag fails verification"

# ---- 5. digest-rendered but NO digest resolved -> fail, never silently pass ----------------------
# If the ECR lookup failed while the cluster is digest-pinned, we cannot say what is running. The
# safe answer is to fail, not to shrug.
make_kubectl "$REG/voteball-nginx@$D_NGINX" "$REG/voteball-backend@$D_BACK" "$REG/voteball-worker@$D_WORK"
out="$(run abc1234 "backend=$D_BACK worker=$D_WORK" 2>&1)" \
  && fail "a digest-pinned deployment with no resolved digest must fail, not pass"
grep -q "no digest for image 'nginx'" <<<"$out" || fail "the error should name the missing image: $out"
ok "digest-pinned with no resolved digest fails rather than silently passing"

# ---- 6. an unreadable deployment fails ----------------------------------------------------------
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$work/bin/kubectl"
out="$(run abc1234 "$ALL_DIGESTS" 2>&1)" && fail "an unreadable deployment must fail verification"
grep -q "Could not read the image" <<<"$out" || fail "expected a read error, got: $out"
ok "a deployment whose image cannot be read fails verification"

# ---- 7. Jenkinsfile-cd must actually delegate to this script ------------------------------------
# Extracted precisely so the decision is testable; an inline copy would drift from it silently, which
# is how the original bug survived (check-jenkinsfile-shell.sh proves a block PARSES, not that it
# decides correctly).
grep -q 'verify-deployed-image.sh' Jenkinsfile-cd \
  || fail "Jenkinsfile-cd does not call scripts/ci/verify-deployed-image.sh -- if the check was inlined again, this test no longer protects it"
pass=$((pass+1))
grep -q 'case "\$image" in' Jenkinsfile-cd \
  && fail "Jenkinsfile-cd still contains an inline image-matching case statement -- two copies of this decision will drift"
pass=$((pass+1))

echo "PASS: $(basename "$0") -- $pass checks"
