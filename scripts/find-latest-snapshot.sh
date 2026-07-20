#!/usr/bin/env bash
# Usage: ./scripts/find-latest-snapshot.sh
# Picks the newest manual RDS snapshot from EITHER voteball lineage (the retired k3s `voteball-db`
# or the current `voteball-eks-db`) and writes it to terraform-eks/snapshot.auto.tfvars, which
# Terraform auto-loads. Run before `terraform apply`; scripts/deploy.sh does this for you.
#
# Writes `db_snapshot_identifier = null` when no snapshot exists, so a first-ever deploy creates an
# empty DB instead of hard-failing on a pinned identifier that is no longer there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform-eks"
AUTO_TFVARS="$TF_DIR/snapshot.auto.tfvars"
. "$SCRIPT_DIR/lib/config.sh"

# Distinguish "the API call succeeded and found zero snapshots" (safe: no prior snapshot) from "the
# API call itself failed" (expired SSO token, wrong profile, no network, throttling). The latter must
# abort loudly rather than silently falling through to "fresh empty DB" -- that is exactly the
# accidental-data-loss outcome this script exists to prevent. A failed call also leaves any existing
# snapshot.auto.tfvars untouched rather than deleting a possibly-still-correct one.
#
# Both lineages are searched: the k3s-era `voteball-db` holds the original vote history, and
# `voteball-eks-db` holds every final snapshot taken since. Newest SnapshotCreateTime wins.
if ! SNAPSHOT_ID=$(aws rds describe-db-snapshots \
  --snapshot-type manual \
  --region "$REGION" \
  --query 'sort_by(DBSnapshots[?starts_with(DBInstanceIdentifier, `voteball`)], &SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text); then
  echo "ERROR: aws rds describe-db-snapshots failed -- check AWS credentials/network." >&2
  echo "Refusing to guess whether a snapshot exists; $AUTO_TFVARS left untouched." >&2
  exit 1
fi

if [ "$SNAPSHOT_ID" = "None" ] || [ -z "$SNAPSHOT_ID" ]; then
  echo "db_snapshot_identifier = null" > "$AUTO_TFVARS"
  echo "No prior snapshot found — next apply creates a fresh, empty database."
else
  echo "db_snapshot_identifier = \"$SNAPSHOT_ID\"" > "$AUTO_TFVARS"
  echo "Found $SNAPSHOT_ID — next apply will restore from it."
  echo "(To force a fresh empty DB instead, put 'db_snapshot_identifier = null' in $AUTO_TFVARS.)"
fi
