#!/usr/bin/env bash
# Tests the section-aware rewriter against a fixture, with NO AWS/Terraform access.
# Terraform lookups are stubbed via the SYNC_STUB_* env vars the script honours.
set -euo pipefail
cd "$(dirname "$0")/../.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/values.yaml"

cat > "$FIXTURE" <<'EOF'
image:
  registry: "old.dkr.ecr.example.com"
  tag: "OLDTAG" # git-SHA tag
  pullPolicy: IfNotPresent

config:
  DB_HOST: "old-db.example.com"
  DB_NAME: "postgres"
  S3_BUCKET: "old-bucket"
  SNS_TOPIC: "arn:aws:sns:old"

ingress:
  host: "voteball.latnook.com"
  certificateArn: "arn:aws:acm:il-central-1:590183895228:certificate/OLD"

backup:
  roleArn: "arn:aws:iam::590183895228:role/OLD-backup"
  schedule: "0 2 * * *"

worker:
  replicas: 1
  roleArn: "arn:aws:iam::590183895228:role/OLD-worker"
EOF

export SYNC_STUB_rds_endpoint="new-db.example.com"
export SYNC_STUB_acm_certificate_arn="arn:aws:acm:il-central-1:590183895228:certificate/NEW"
export SYNC_STUB_s3_bucket="new-bucket"
export SYNC_STUB_backup_role_arn="arn:aws:iam::590183895228:role/NEW-backup"
export SYNC_STUB_worker_role_arn="arn:aws:iam::590183895228:role/NEW-worker"
export SYNC_STUB_ecr_registry="new.dkr.ecr.example.com"
export SYNC_STUB_app_domain="new.example.com"
export SYNC_STUB_sns_topic_arn="arn:aws:sns:NEWTOPIC"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- 1. --check on a drifted file must exit non-zero and NOT write ---
BEFORE="$(cat "$FIXTURE")"
if ./scripts/sync-values-from-tf.sh --check --tag NEWTAG --values "$FIXTURE"; then
  fail "--check should exit non-zero when the file has drifted"
fi
[ "$BEFORE" = "$(cat "$FIXTURE")" ] || fail "--check must not modify the file"

# --- 2. a real run rewrites every managed value ---
./scripts/sync-values-from-tf.sh --tag NEWTAG --values "$FIXTURE"

grep -q 'tag: "NEWTAG"'                  "$FIXTURE" || fail "image.tag not updated"
grep -q 'DB_HOST: "new-db.example.com"'  "$FIXTURE" || fail "config.DB_HOST not updated"
grep -q 'S3_BUCKET: "new-bucket"'        "$FIXTURE" || fail "config.S3_BUCKET not updated"
grep -q 'certificateArn: ".*NEW"'        "$FIXTURE" || fail "ingress.certificateArn not updated"
grep -q 'registry: "new.dkr.ecr.example.com"' "$FIXTURE" || fail "image.registry not updated"
grep -q 'host: "new.example.com"'       "$FIXTURE" || fail "ingress.host not updated"
grep -q 'SNS_TOPIC: "arn:aws:sns:NEWTOPIC"' "$FIXTURE" || fail "config.SNS_TOPIC not updated"

# --- 3. the two same-named roleArn keys must NOT be cross-assigned ---
grep -q 'roleArn: "arn:aws:iam::590183895228:role/NEW-backup"' "$FIXTURE" || fail "backup.roleArn wrong"
grep -q 'roleArn: "arn:aws:iam::590183895228:role/NEW-worker"' "$FIXTURE" || fail "worker.roleArn wrong"
[ "$(grep -c 'NEW-backup' "$FIXTURE")" -eq 1 ] || fail "backup role leaked into another section"
[ "$(grep -c 'NEW-worker' "$FIXTURE")" -eq 1 ] || fail "worker role leaked into another section"

# --- 4. unmanaged keys and comments survive ---
grep -q 'DB_NAME: "postgres"'   "$FIXTURE" || fail "unmanaged key DB_NAME was clobbered"
grep -q 'schedule: "0 2 \* \* \*"' "$FIXTURE" || fail "unmanaged key schedule was clobbered"
grep -q '# git-SHA tag'         "$FIXTURE" || fail "trailing comment was lost"

# --- 5. --check on a synced file exits 0 ---
./scripts/sync-values-from-tf.sh --check --tag NEWTAG --values "$FIXTURE" \
  || fail "--check should exit 0 when the file is already in sync"

echo "PASS: all sync-values assertions"
