#!/usr/bin/env bash
# Usage: ./scripts/cleanup-orphaned-lb-resources.sh [--apply] [--quiet]
#
# Deletes the security groups and target groups the AWS Load Balancer Controller created for this
# cluster and never got to delete. DRY RUN BY DEFAULT; scripts/destroy.sh passes --apply, once
# before `terraform destroy` and again from its background reaper while the destroy runs.
#
# WHY THIS EXISTS. The controller deletes its own security groups and target groups when the last
# Ingress goes -- unless AWS is still reporting the ALB as in use. On 2026-09-16 the ALB vanished from
# the ELB API while its two network interfaces stayed attached for hours, every DeleteTargetGroup
# answered ResourceInUse, and the controller was uninstalled before it ever succeeded. It left two
# security groups (k8s-<cluster>-*, k8s-traffic-<cluster>-*) and one target group behind. Terraform
# does not know they exist, so `aws_vpc` sat on "Still destroying..." until they were deleted by hand
# -- and then went in seconds.
#
# SAFETY -- what makes a resource eligible, all of it required:
#   * it is inside THIS stack's VPC (found by the same Name-tag lookup destroy.sh's reaper uses);
#   * it carries the controller's ownership tag, elbv2.k8s.aws/cluster = <cluster name>. The
#     controller's IAM policy only lets it create security groups and target groups that carry this
#     tag, so the tag is proof of who made it. Terraform's own security groups (cluster, nodes, RDS,
#     EFS) never carry it, and are never touched;
#   * no load balancer in the VPC still exists, and no ELB-owned network interface is still attached.
#     While either is true the resources are still in use and a delete can only fail, so the script
#     says so and changes nothing.
# A k8s-* security group WITHOUT the tag is reported and left alone: if the tag assumption ever stops
# holding, this prints the miss instead of reporting a clean VPC.
#
# Never exits non-zero on an AWS failure: it runs in front of, and alongside, a billed teardown.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh"

APPLY=0
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || echo "$@"; }
TAG_KEY="elbv2.k8s.aws/cluster"

vpc="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${CLUSTER}*" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)" || vpc=""
if [ -z "$vpc" ] || [ "$vpc" = "None" ]; then
  say "No ${CLUSTER} VPC found -- nothing to clean up."
  exit 0
fi

lbs="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?VpcId=='${vpc}'].LoadBalancerName" --output text 2>/dev/null)" || lbs="?"
elb_enis="$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=vpc-id,Values=${vpc}" Name=requester-id,Values=amazon-elb \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)" || elb_enis="?"
if [ "$lbs" = "?" ] || [ "$elb_enis" = "?" ]; then
  say "Could not check whether a load balancer is still in ${vpc}; changing nothing."
  exit 0
fi
if [ -n "$lbs" ] && [ "$lbs" != "None" ]; then
  say "A load balancer still exists in ${vpc} (${lbs}); its security groups are still in use. Changing nothing."
  exit 0
fi
if [ -n "$elb_enis" ] && [ "$elb_enis" != "None" ]; then
  say "AWS still has load-balancer network interfaces attached in ${vpc} (${elb_enis})."
  say "Nobody can delete those -- AWS removes them itself, which took ~6 hours on 2026-09-16. Changing nothing."
  exit 0
fi

# ---- security groups -------------------------------------------------------------------------------
mapfile -t sgs < <(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=${vpc}" "Name=tag:${TAG_KEY},Values=${CLUSTER}" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null | grep -v '^None' || true)
mapfile -t untagged < <(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=${vpc}" "Name=group-name,Values=k8s-*" \
  --query "SecurityGroups[?!(Tags[?Key=='${TAG_KEY}'])].[GroupId,GroupName]" --output text 2>/dev/null \
  | grep -v '^None' || true)
for row in "${untagged[@]}"; do
  [ -n "$row" ] && say "  NOT touching ${row}: named like a controller group but missing the ${TAG_KEY} tag -- check by hand."
done

# Two passes: one controller group can reference another in its rules, and a referenced group
# refuses deletion until the one pointing at it is gone.
pending=("${sgs[@]}")
for pass in 1 2; do
  remaining=()
  for row in "${pending[@]}"; do
    [ -z "$row" ] && continue
    id="${row%%[[:space:]]*}"
    if [ "$APPLY" = 0 ]; then
      say "  would delete security group ${row}"
      continue
    fi
    if aws ec2 delete-security-group --region "$REGION" --group-id "$id" >/dev/null 2>&1; then
      echo "  deleted orphaned load-balancer security group ${row}"
    else
      remaining+=("$row")
    fi
  done
  pending=("${remaining[@]}")
  [ "$APPLY" = 0 ] && break
  [ "${#pending[@]}" -eq 0 ] && break
done
for row in "${pending[@]}"; do
  [ "$APPLY" = 1 ] && [ -n "$row" ] && echo "  WARNING: could not delete security group ${row} -- see: aws ec2 delete-security-group --group-id ${row%%[[:space:]]*}"
done

# ---- target groups ---------------------------------------------------------------------------------
# Unattached only (a target group still attached to a listener cannot be deleted anyway), and
# ownership checked per group through its tags -- describe-target-groups has no tag filter.
mapfile -t tgs < <(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?VpcId=='${vpc}' && length(LoadBalancerArns)==\`0\`].TargetGroupArn" \
  --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep . || true)
for arn in "${tgs[@]}"; do
  tg="${arn##*:targetgroup/}"; tg="${tg%%/*}"   # the name, for humans
  owner="$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
    --query "TagDescriptions[0].Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text 2>/dev/null)" || owner=""
  if [ "$owner" != "$CLUSTER" ]; then
    say "  NOT touching target group ${tg}: not tagged ${TAG_KEY}=${CLUSTER}"
    continue
  fi
  if [ "$APPLY" = 0 ]; then
    say "  would delete target group ${tg}"
  elif aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" >/dev/null 2>&1; then
    echo "  deleted orphaned target group ${tg}"
  else
    echo "  WARNING: could not delete target group ${arn}"
  fi
done

if [ "${#sgs[@]}" -eq 0 ] && [ "${#tgs[@]}" -eq 0 ]; then
  say "No orphaned load-balancer security groups or target groups in ${vpc}."
fi
exit 0
