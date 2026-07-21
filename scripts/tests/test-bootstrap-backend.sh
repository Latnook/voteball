#!/usr/bin/env bash
# Tests the Terraform state-backend bootstrap with NO AWS access. Every `aws` call is stubbed via
# the BOOTSTRAP_STUB_AWS_CMD env var the script honours -- same pattern as test-ci-guards.sh and
# test-sync-values.sh.
#
# What this is really guarding: the script's two outputs must agree. It creates the bucket AND
# writes the backend.hcl that points Terraform at it, and if those ever disagree the operator gets
# a confusing `terraform init` failure instead of a working backend. Every assertion below is some
# version of "the name it created is the name it wrote down".
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stub `aws` that logs every invocation and answers the two calls that must return data.
# head-bucket exits non-zero, which is how the real CLI reports "bucket does not exist".
cat > "$WORK/aws-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AWS_CALL_LOG"
case "$1 $2" in
  "sts get-caller-identity") echo "123456789012" ;;
  "s3api head-bucket")      exit "${STUB_HEAD_BUCKET_RC:-1}" ;;
esac
exit 0
STUB
chmod +x "$WORK/aws-stub.sh"
export BOOTSTRAP_STUB_AWS_CMD="$WORK/aws-stub.sh"

# Isolated tfvars so the test never depends on the developer's real terraform/voteball.tfvars.
mkdir -p "$WORK/tf/jenkins"
cat > "$WORK/tf/voteball.tfvars" <<'VARS'
aws_region  = "eu-west-1"
cluster_name = "testball"
VARS
export TF_DIR="$WORK/tf" TFVARS="$WORK/tf/voteball.tfvars"

run_bootstrap() {
  export AWS_CALL_LOG="$WORK/calls.log"
  : > "$AWS_CALL_LOG"
  scripts/bootstrap-tf-backend.sh >"$WORK/out.txt" 2>&1 || {
    echo "--- script output ---" >&2; cat "$WORK/out.txt" >&2; return 1
  }
}

# ---- Fresh account: creates the bucket, in the configured region ---------------------------------
run_bootstrap || fail "bootstrap failed on a fresh account"

grep -q "s3api create-bucket" "$WORK/calls.log" || fail "should create the bucket when head-bucket fails"
pass=$((pass+1))

grep -q "testball-tfstate-123456789012" "$WORK/calls.log" \
  || fail "bucket name must be <cluster_name>-tfstate-<account_id>"
pass=$((pass+1))

grep -q "eu-west-1" "$WORK/calls.log" || fail "region must come from tfvars, not be hardcoded"
pass=$((pass+1))

# Durability settings are the entire point -- versioning is what makes a corrupted state recoverable.
for want in put-bucket-versioning put-bucket-encryption put-public-access-block \
            put-bucket-policy put-bucket-lifecycle-configuration; do
  grep -q "$want" "$WORK/calls.log" || fail "must apply $want"
  pass=$((pass+1))
done

# ---- backend.hcl generation ----------------------------------------------------------------------
[ -f "$WORK/tf/backend.hcl" ]         || fail "main stack backend.hcl not written"
[ -f "$WORK/tf/jenkins/backend.hcl" ] || fail "jenkins stack backend.hcl not written"
pass=$((pass+2))

grep -q 'bucket *= *"testball-tfstate-123456789012"' "$WORK/tf/backend.hcl" \
  || fail "main backend.hcl must name the bucket the script just created"
pass=$((pass+1))

grep -q 'key *= *"voteball/main.tfstate"' "$WORK/tf/backend.hcl" \
  || fail "main backend.hcl must use the main state key"
pass=$((pass+1))

grep -q 'key *= *"voteball/jenkins.tfstate"' "$WORK/tf/jenkins/backend.hcl" \
  || fail "jenkins backend.hcl must use the jenkins state key"
pass=$((pass+1))

# The two stacks sharing a key would have them overwrite each other's state -- catastrophic and
# silent until a plan shows the wrong resources.
main_key="$(sed -nE 's/^ *key *= *"(.*)"/\1/p' "$WORK/tf/backend.hcl")"
jenk_key="$(sed -nE 's/^ *key *= *"(.*)"/\1/p' "$WORK/tf/jenkins/backend.hcl")"
[ "$main_key" != "$jenk_key" ] || fail "the two stacks must not share a state key"
pass=$((pass+1))

grep -q 'region *= *"eu-west-1"' "$WORK/tf/backend.hcl" || fail "backend.hcl region must match tfvars"
pass=$((pass+1))

# ---- Idempotency: re-run against an existing bucket ----------------------------------------------
export STUB_HEAD_BUCKET_RC=0     # bucket already exists
run_bootstrap || fail "bootstrap must be safe to re-run"

grep -q "s3api create-bucket" "$WORK/calls.log" \
  && fail "must NOT re-create a bucket that already exists"
pass=$((pass+1))

# Settings are re-asserted on every run so drift (someone toggling versioning off) self-heals.
grep -q "put-bucket-versioning" "$WORK/calls.log" \
  || fail "must re-assert bucket settings even when the bucket exists"
pass=$((pass+1))

[ -f "$WORK/tf/backend.hcl" ] || fail "backend.hcl must still exist after a re-run"
pass=$((pass+1))

# ---- Forkability: no identity may be baked into the script itself --------------------------------
if grep -nE '\b(il-central-1|[0-9]{12})\b' scripts/bootstrap-tf-backend.sh \
     | grep -vE '^\s*[0-9]+:\s*#' | grep -q .; then
  fail "bootstrap script must not hardcode a region or account id outside comments"
fi
pass=$((pass+1))

echo "OK: $pass assertions passed"
