#!/usr/bin/env bash
# Usage: ./scripts/find-latest-snapshot.sh
# Run before `terraform apply` if you want the DB restored from the most
# recent final snapshot taken by a prior `terraform destroy` (see
# docs/deploy.md). Writes terraform/snapshot.auto.tfvars (Terraform loads
# *.auto.tfvars automatically, no -var-file needed) when a snapshot is
# found; leaves no file (or removes a stale one) when none exists, so a
# first-ever deploy just creates an empty DB as normal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
AUTO_TFVARS="$TF_DIR/snapshot.auto.tfvars"
REGION="il-central-1"

# Distinguish "the API call succeeded and found zero snapshots" (safe to
# treat as no-prior-snapshot) from "the API call itself failed" (expired
# SSO token, wrong profile, no network, throttling...) -- the latter must
# abort loudly rather than silently falling through to "fresh empty DB",
# which is exactly the accidental-data-loss outcome this script exists to
# prevent. A failed call also leaves any existing snapshot.auto.tfvars
# untouched, rather than deleting a possibly-still-correct one.
if ! SNAPSHOT_ID=$(aws rds describe-db-snapshots \
  --db-instance-identifier voteball-db \
  --snapshot-type manual \
  --region "$REGION" \
  --query 'sort_by(DBSnapshots, &SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text); then
  echo "ERROR: aws rds describe-db-snapshots failed -- check AWS credentials/network." >&2
  echo "Refusing to guess whether a snapshot exists; $AUTO_TFVARS left untouched." >&2
  exit 1
fi

if [ "$SNAPSHOT_ID" = "None" ] || [ -z "$SNAPSHOT_ID" ]; then
  rm -f "$AUTO_TFVARS"
  echo "No prior snapshot found — next apply creates a fresh, empty database."
else
  echo "db_snapshot_identifier = \"$SNAPSHOT_ID\"" > "$AUTO_TFVARS"
  echo "Found $SNAPSHOT_ID — next apply will restore from it."
  echo "(To force a fresh empty DB instead, delete $AUTO_TFVARS before applying.)"
fi
