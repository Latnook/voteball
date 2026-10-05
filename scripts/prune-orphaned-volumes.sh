#!/usr/bin/env bash
# Usage: ./scripts/prune-orphaned-volumes.sh [--apply] [--min-age-days N]
#
# Deletes EBS volumes that a PREVIOUS cluster's PersistentVolumeClaims left behind: unattached,
# tagged as this cluster's dynamically provisioned PVC volumes, and at least N days old (default 7).
# DRY RUN BY DEFAULT -- it prints what it would delete and exits 0. Pass --apply to actually delete.
# scripts/destroy.sh calls it with --apply as its last step, after the cluster is gone.
#
# WHY THIS EXISTS. An orphaned EBS volume blocks nothing, so `terraform destroy` reports complete
# success while leaking it, and it then bills forever. destroy.sh step 5 deletes the observability
# PVCs so that new teardowns leak none -- but on 2026-10-05 the account still held TWELVE such
# volumes, 220 GB, created between 2026-08-23 and 2026-09-08 by teardowns that predated that step:
# ten 20 GB Elasticsearch volumes and two 10 GB Prometheus volumes, all `available`, all billed while
# the stack was down. Nothing looked for them, because nothing fails when they exist. This is the
# backstop for the next way a volume gets leaked, whatever it turns out to be.
#
# THREE RULES, each about not deleting a volume that is still somebody's data:
#
#  1. REFUSE TO RUN WHILE THE CLUSTER EXISTS. With a live cluster an `available` volume is not
#     necessarily an orphan: a StatefulSet pod being rescheduled leaves its volume detached for as
#     long as the move takes, and on a 100% Spot node group that happens daily. Once the cluster is
#     gone, nothing can ever mount one of these again, so every match is an orphan by definition.
#     "Cannot tell whether the cluster exists" counts as "it exists".
#
#  2. MATCH ON TWO INDEPENDENT MARKERS, not one. The EBS CSI driver names a dynamic volume
#     `<cluster>-dynamic-pvc-<uid>` AND tags it `kubernetes.io/created-for/pvc/name`. Requiring both,
#     plus `available`, means a hand-made volume that merely shares the name prefix is never a match.
#     The prefix comes from config.sh's cluster name, never a literal.
#
#  3. THE AGE IS A GRACE PERIOD, AND IT IS MEASURED FROM CREATION. EBS records no "detached at"
#     time, so "a week old" can only mean created a week ago. A volume leaked by a cluster that
#     itself lived more than N days is therefore deleted at that cluster's teardown with no grace at
#     all. That is acceptable here -- clusters in this project live for hours -- and it is the reason
#     the default is not shorter.
#
# AWS itself refuses to delete an attached volume (VolumeInUse), so a volume that is attached between
# the listing and the delete call fails safe: it is reported and left in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh"

MIN_AGE_DAYS="${ORPHAN_VOLUME_MIN_AGE_DAYS:-7}"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        APPLY=1; shift ;;
    --min-age-days) MIN_AGE_DAYS="${2:?--min-age-days needs a number}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$MIN_AGE_DAYS" in
  ''|*[!0-9]*) echo "ERROR: --min-age-days must be a non-negative integer, got '$MIN_AGE_DAYS'" >&2; exit 2 ;;
esac

PREFIX="${CLUSTER:-voteball}"

# Rule 1. Only a clean "no such cluster" lets this proceed; any other failure (expired token, no
# network, throttling) is indistinguishable from "the cluster is up" and is treated as exactly that.
if cluster_out="$(aws eks describe-cluster --name "$PREFIX" --region "$REGION" \
      --query 'cluster.status' --output text 2>&1)"; then
  echo "EKS cluster '${PREFIX}' exists (${cluster_out}) -- refusing to prune volumes."
  echo "A detached volume on a live cluster may be a pod mid-reschedule, not an orphan."
  exit 0
fi
case "$cluster_out" in
  *ResourceNotFoundException*) ;;
  *) echo "ERROR: could not determine whether EKS cluster '${PREFIX}' exists:" >&2
     echo "       ${cluster_out}" >&2
     echo "Refusing to delete anything without knowing the cluster is gone." >&2
     exit 1 ;;
esac

# Rule 2. Oldest first. The namespace and claim are printed so a human can see WHOSE data each
# volume was before it goes.
if ! LIST="$(aws ec2 describe-volumes \
      --region "$REGION" \
      --filters "Name=status,Values=available" \
                "Name=tag:Name,Values=${PREFIX}-dynamic-pvc-*" \
                "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
      --query 'sort_by(Volumes, &CreateTime)[].[VolumeId,CreateTime,Size,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
      --output text)"; then
  echo "ERROR: aws ec2 describe-volumes failed -- check AWS credentials/network." >&2
  echo "Refusing to delete anything on a failed listing." >&2
  exit 1
fi

mapfile -t ROWS < <(printf '%s\n' "$LIST" | grep -v '^[[:space:]]*$' || true)
TOTAL=${#ROWS[@]}

if [ "$TOTAL" -eq 0 ]; then
  echo "No unattached '${PREFIX}' PVC volumes found -- nothing to prune."
  exit 0
fi

# Rule 3.
CUTOFF=$(( $(date +%s) - MIN_AGE_DAYS * 86400 ))

echo "${TOTAL} unattached '${PREFIX}' PVC volume(s); pruning those created more than ${MIN_AGE_DAYS} day(s) ago."

rc=0
matched=0
gb=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r id when size ns claim <<<"$row"
  if ! created="$(date -d "$when" +%s 2>/dev/null)"; then
    # An unreadable timestamp is not evidence of age. Keep the volume and say so.
    echo "  kept     $id  (unreadable CreateTime '$when')" >&2
    rc=1
    continue
  fi
  if [ "$created" -gt "$CUTOFF" ]; then
    echo "  kept     $id  ${size}GiB  $when  ${ns}/${claim}  (younger than ${MIN_AGE_DAYS} day(s))"
    continue
  fi
  matched=$((matched + 1))
  if [ "$APPLY" = 1 ]; then
    if aws ec2 delete-volume --volume-id "$id" --region "$REGION" >/dev/null 2>&1; then
      echo "  deleted  $id  ${size}GiB  $when  ${ns}/${claim}"
      gb=$((gb + size))
    else
      # Not fatal, for the reason prune-db-snapshots.sh gives: this runs at the end of a teardown
      # that has already succeeded, and a volume that will not delete is a cost problem. Exit
      # non-zero so an unattended run still surfaces it.
      echo "  FAILED   $id  ${size}GiB  $when  ${ns}/${claim} -- left in place" >&2
      rc=1
    fi
  else
    echo "  would delete  $id  ${size}GiB  $when  ${ns}/${claim}"
    gb=$((gb + size))
  fi
done

if [ "$APPLY" = 1 ]; then
  echo "Deleted ${gb} GiB."
elif [ "$matched" -gt 0 ]; then
  echo
  echo "Dry run -- nothing was deleted. Re-run with --apply to delete these ${matched} volume(s), ${gb} GiB."
fi
exit "$rc"
