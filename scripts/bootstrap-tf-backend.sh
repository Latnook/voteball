#!/usr/bin/env bash
# Creates the S3 bucket that holds both Terraform stacks' state, and writes the backend.hcl files
# that point Terraform at it. Idempotent: safe to re-run, and re-asserts every bucket setting so
# drift self-heals.
#
# Why a script and not Terraform: Terraform cannot create the bucket that stores its own state --
# the bucket must exist before `init`. Managing it in a separate Terraform stack only moves the
# problem down one level, since that stack's state would then be the unprotected local file.
#
# Why it also writes backend.hcl: a `backend` block cannot interpolate variables, and the bucket
# name contains the AWS account id, which must never be committed (the repo's forkability rule).
# So the backend block is left partial in git and completed at init time:
#
#     terraform -chdir=terraform init -backend-config=backend.hcl
#
# This script is the only thing that knows the account id at the moment it resolves it, so it owns
# both halves -- creating the bucket and writing down where it is.
#
# See docs/design/2026-07-21-terraform-remote-state-design.md.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh
# NOTE: deliberately no `require_config` -- app_domain/route53_zone_name are irrelevant here, and
# this script must work on a fresh clone before the full tfvars is filled in.

# Tests override this to run offline; production uses the real CLI.
AWS_CMD="${BOOTSTRAP_STUB_AWS_CMD:-aws}"
aws_() { "$AWS_CMD" "$@"; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

ACCOUNT="$(aws_ sts get-caller-identity --query Account --output text)"
[ -n "$ACCOUNT" ] || { echo "ERROR: could not resolve the AWS account id. Is the CLI logged in?" >&2; exit 1; }

# S3 bucket names are globally unique across all AWS customers, so the account id is part of the
# name by necessity, not decoration.
BUCKET="${CLUSTER}-tfstate-${ACCOUNT}"

step "State bucket: s3://${BUCKET} (${REGION})"

# ---------------------------------------------------------------------------------------------
# 1. The bucket
# ---------------------------------------------------------------------------------------------
if aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "    already exists -- reasserting settings"
else
  echo "    creating"
  # us-east-1 is the one region that must NOT be given a LocationConstraint; the API rejects it.
  if [ "$REGION" = "us-east-1" ]; then
    aws_ s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws_ s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 2. Durability and protection. All idempotent PUTs -- re-applied on every run.
# ---------------------------------------------------------------------------------------------

# Versioning is the single most valuable setting here: it is what makes a truncated or corrupted
# state file recoverable by restoring the previous version.
aws_ s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration "Status=Enabled"

# State contains secrets -- the RDS master password among them.
aws_ s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws_ s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/policy.json" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
POLICY
aws_ s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${TMP}/policy.json"

# Versioning without expiry grows forever. 90 days is well past any window in which rolling back to
# an old state is a sane thing to do.
cat > "$TMP/lifecycle.json" <<'LIFECYCLE'
{
  "Rules": [
    {
      "ID": "expire-noncurrent-state-versions",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }
  ]
}
LIFECYCLE
aws_ s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "file://${TMP}/lifecycle.json"

# ---------------------------------------------------------------------------------------------
# 3. The backend.hcl files (gitignored -- they carry the account id)
# ---------------------------------------------------------------------------------------------
# Separate keys mean separate objects and separate locks, so the main stack can be destroyed and
# rebuilt repeatedly without the Jenkins stack noticing. Sharing a key would have the two stacks
# silently overwrite each other's state.
write_backend_hcl() {
  local dir="$1" key="$2"
  mkdir -p "$dir"
  cat > "${dir}/backend.hcl" <<HCL
# GENERATED by scripts/bootstrap-tf-backend.sh -- do not edit, do not commit.
# Terraform cannot interpolate variables inside a backend block, so this file supplies them:
#   terraform -chdir=${dir#./} init -backend-config=backend.hcl
bucket = "${BUCKET}"
key    = "${key}"
region = "${REGION}"
HCL
  echo "    wrote ${dir}/backend.hcl  (key: ${key})"
}

step "Backend configuration"
write_backend_hcl "$TF_DIR"           "voteball/main.tfstate"
write_backend_hcl "$TF_DIR/jenkins"   "voteball/jenkins.tfstate"

step "Done"
cat <<NEXT
The bucket is ready and belongs to NO Terraform stack -- scripts/destroy.sh must never touch it.

Next, in each stack (add -migrate-state the first time, to move existing local state):

  terraform -chdir=${TF_DIR}/jenkins init -backend-config=backend.hcl -migrate-state
  terraform -chdir=${TF_DIR}         init -backend-config=backend.hcl -migrate-state
NEXT
