#!/usr/bin/env bash
# Usage: ./scripts/prune-db-snapshots.sh [--apply] [--retain N]
#
# Deletes old manual RDS snapshots of this cluster's lineage, keeping the newest N (default 7).
# DRY RUN BY DEFAULT -- it prints what it would delete and exits 0. Pass --apply to actually delete.
# scripts/destroy.sh calls it with --apply, immediately after the final snapshot has been taken.
#
# WHY THIS EXISTS. Every teardown takes a final snapshot (delete_automated_backups = false and a
# final_snapshot_identifier, both deliberate -- see modules/database/main.tf), and nothing ever removed
# one. By 2026-09-09 that was 52 manual snapshots going back to 2026-07-19, and RDS backup storage had
# become the LARGEST RDS line item on the bill:
#
#     month        ChargedBackupUsage        instance hours
#     2026-07      $0.19   ( 1.8 GB-mo)      $14.52
#     2026-08      $4.21   (40.1 GB-mo)      $ 5.44
#     2026-09 (9d) $2.00   (19.0 GB-mo)      $ 1.06   <-- backups now cost more than the database
#
# AWS gives free backup storage up to 100% of allocated storage (20 GB here), which is why July was
# nearly free and August was not: the total crossed the allowance and every further GB is billed at
# ~$0.105/GB-month. Retaining 7 snapshots puts the total back under the allowance.
#
# TWO RULES THAT ARE NOT NEGOTIABLE, both about picking the wrong snapshot to keep:
#
#  1. Order by SnapshotCreateTime, NEVER by identifier. The identifier embeds `time_static.deploy`,
#     so a snapshot created TODAY is named after the day the stack was deployed -- CLAUDE.md records
#     a real instance of `voteball-eks-db-final-20260722065933` existing on 2026-07-27 and looking
#     five days stale. Sorting by name would delete the newest snapshot and keep an ancient one.
#
#  2. Use the SAME selection predicate as scripts/find-latest-snapshot.sh -- manual snapshots whose
#     DBInstanceIdentifier starts with the cluster prefix, spanning BOTH lineages (the retired k3s
#     `voteball-db` and the current `voteball-eks-db`). That script restores the newest match on the
#     next deploy. If this script's predicate were narrower, it could delete the very snapshot the
#     next apply is about to restore from.
#
# On top of the retention count there is a hard floor: the single newest snapshot is NEVER deleted,
# whatever --retain says. A retention count is a number someone can get wrong; the next deploy's
# restore target is not something to leave to arithmetic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh"

RETAIN="${SNAPSHOT_RETAIN:-7}"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  APPLY=1; shift ;;
    --retain) RETAIN="${2:?--retain needs a number}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$RETAIN" in
  ''|*[!0-9]*) echo "ERROR: --retain must be a non-negative integer, got '$RETAIN'" >&2; exit 2 ;;
esac

# The prefix comes from config.sh's cluster name, never a literal -- a hardcoded 'voteball' here would
# delete another fork's snapshots if two stacks ever shared an account.
PREFIX="${CLUSTER:-voteball}"

# Same predicate as find-latest-snapshot.sh, plus a status filter: a snapshot mid-creation cannot be
# deleted anyway, and counting one toward "newest" would let a still-forming snapshot mask the newest
# COMPLETE one. Oldest first, so the tail is what we keep.
if ! LIST="$(aws rds describe-db-snapshots \
      --snapshot-type manual \
      --region "$REGION" \
      --query "sort_by(DBSnapshots[?starts_with(DBInstanceIdentifier, \`${PREFIX}\`) && Status == \`available\`], &SnapshotCreateTime)[].[DBSnapshotIdentifier,SnapshotCreateTime]" \
      --output text)"; then
  echo "ERROR: aws rds describe-db-snapshots failed -- check AWS credentials/network." >&2
  echo "Refusing to delete anything on a failed listing." >&2
  exit 1
fi

mapfile -t ROWS < <(printf '%s\n' "$LIST" | grep -v '^[[:space:]]*$' || true)
TOTAL=${#ROWS[@]}

if [ "$TOTAL" -eq 0 ]; then
  echo "No manual '${PREFIX}' snapshots found -- nothing to prune."
  exit 0
fi

# Hard floor: never consider the newest for deletion, even at --retain 0.
EFFECTIVE="$RETAIN"
[ "$EFFECTIVE" -lt 1 ] && EFFECTIVE=1

if [ "$TOTAL" -le "$EFFECTIVE" ]; then
  echo "${TOTAL} manual '${PREFIX}' snapshot(s), retaining ${EFFECTIVE} -- nothing to prune."
  exit 0
fi

DELETE_COUNT=$(( TOTAL - EFFECTIVE ))
echo "${TOTAL} manual '${PREFIX}' snapshot(s); retaining the newest ${EFFECTIVE}, pruning ${DELETE_COUNT}."
echo "Newest (never deleted): $(printf '%s\n' "${ROWS[$((TOTAL-1))]}" | awk '{print $1, $2}')"

rc=0
for i in $(seq 0 $(( DELETE_COUNT - 1 ))); do
  id="$(printf '%s\n' "${ROWS[$i]}" | awk '{print $1}')"
  when="$(printf '%s\n' "${ROWS[$i]}" | awk '{print $2}')"
  if [ "$APPLY" = 1 ]; then
    if aws rds delete-db-snapshot --db-snapshot-identifier "$id" --region "$REGION" >/dev/null 2>&1; then
      echo "  deleted  $id  ($when)"
    else
      # Deliberately not fatal: this runs at the END of a teardown that has already succeeded, and a
      # snapshot that will not delete is a cost problem, not a correctness one. Report and continue,
      # but exit non-zero so an unattended run still surfaces it.
      echo "  FAILED   $id  ($when) -- left in place" >&2
      rc=1
    fi
  else
    echo "  would delete  $id  ($when)"
  fi
done

if [ "$APPLY" = 0 ]; then
  echo
  echo "Dry run -- nothing was deleted. Re-run with --apply to delete these ${DELETE_COUNT} snapshot(s)."
fi
exit "$rc"
