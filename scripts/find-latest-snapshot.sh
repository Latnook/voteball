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

SNAPSHOT_ID=$(aws rds describe-db-snapshots \
  --db-instance-identifier voteball-db \
  --snapshot-type manual \
  --region "$REGION" \
  --query 'sort_by(DBSnapshots, &SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text 2>/dev/null || echo "None")

if [ "$SNAPSHOT_ID" = "None" ] || [ -z "$SNAPSHOT_ID" ]; then
  rm -f "$AUTO_TFVARS"
  echo "No prior snapshot found — next apply creates a fresh, empty database."
else
  echo "db_snapshot_identifier = \"$SNAPSHOT_ID\"" > "$AUTO_TFVARS"
  echo "Found $SNAPSHOT_ID — next apply will restore from it."
  echo "(To force a fresh empty DB instead, delete $AUTO_TFVARS before applying.)"
fi
