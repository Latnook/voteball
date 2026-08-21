#!/usr/bin/env bash
# Narrates what AWS is actually DOING while `terraform apply` / `terraform destroy` sit on
# "Still creating... [6m20s elapsed]". Terraform reports its own wait; it never reports the
# machine coming up underneath. Run in the background by scripts/deploy.sh step 6 and
# scripts/destroy.sh step 7, and killed by their EXIT trap.
#
# READ-ONLY BY CONSTRUCTION. Every AWS call here is a describe*/list*. It creates, deletes and
# modifies nothing -- the one mutating background job in this repo is destroy.sh's orphaned-ENI
# reaper, and it stays over there. The single exception is `eks update-kubeconfig`, which is
# pointed at a throwaway file in this script's own temp dir (see KUBECONFIG below) so the
# operator's ~/.kube/config is never touched; deploy.sh step 7 remains what sets their context.
# scripts/tests/test-aws-progress-watch.sh asserts both properties by recording every argv the
# stub receives and failing on any mutating verb -- this process runs CONCURRENTLY with a destroy,
# so "read-only" has to be enforced, not intended.
#
# What AWS can and cannot tell us, since the ceiling is not obvious:
#   * machine provisioned  -> YES. ASG scaling activities, then instance pending -> running.
#   * OS booted            -> YES, indirectly. EC2 status checks initializing -> ok is the box
#                             answering; the node going NotReady -> Ready is the kubelet up.
#   * database engine      -> YES. rds describe-events emits real sentences ("Restored from
#                             snapshot", "Finished DB Instance backup").
#   * inside the EKS control plane -> NO. It is managed; AWS exposes one field, CREATING/ACTIVE.
#                             There are no sub-steps to show at any price.
#   * percent complete     -> NO on create. YES on the destroy-time final snapshot, which is the
#                             only real PercentProgress in the whole system.
#
# NOT `set -e`: this runs alongside a billed 13-minute apply, and a watcher that dies (or worse,
# takes the parent with it) because one describe call hiccuped is strictly worse than no watcher.
# Every call is guarded and the script never exits non-zero from the loop.
set -uo pipefail
cd "$(dirname "$0")/.."

. scripts/lib/config.sh   # REGION, CLUSTER -- no hardcoded region/name (forkability rule)

MODE=""
ONCE=0
for arg in "$@"; do
  case "$arg" in
    apply|destroy) MODE="$arg" ;;
    --once)        ONCE=1 ;;
    *) echo "usage: $0 <apply|destroy> [--once]" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: $0 <apply|destroy> [--once]" >&2; exit 2; }

# Whole-binary swap seam, same shape as BOOTSTRAP_STUB_AWS_CMD in scripts/bootstrap-tf-backend.sh.
AWS_CMD="${AWSWATCH_STUB_AWS_CMD:-aws}"
KUBECTL_CMD="${AWSWATCH_STUB_KUBECTL_CMD:-kubectl}"
HELM_CMD="${AWSWATCH_STUB_HELM_CMD:-helm}"

POLL="${VOTEBALL_WATCH_POLL_SECS:-15}"
# Sleep-first, like destroy.sh's reaper -- and here it is load-bearing for a second reason:
# `terraform apply` is INTERACTIVE unless VOTEBALL_AUTO_APPROVE=1, so the operator is typing `yes`
# during the first few seconds and watcher output would land on top of that prompt. Nothing
# observable happens in the first 30s anyway.
DELAY="${VOTEBALL_WATCH_START_DELAY:-30}"
IDLE="${VOTEBALL_WATCH_IDLE_SECS:-120}"

DB_ID="${CLUSTER}-eks-db"
VPC=""
NG=""
ASG=""
KUBE=0
INSTANCE_IDS=""

WORK="$(mktemp -d)"
SLEEP_PID=""
# `kill` on a shell that is blocked in `sleep` leaves the sleep running as an orphan until it
# finishes -- up to 30s of litter every time deploy.sh/destroy.sh tears the watcher down, and after
# a Ctrl-C. Backgrounding the sleep and `wait`ing on it makes the wait interruptible, so the trap
# can take the child with it.
cleanup() { [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM
# Set unconditionally so a kubectl call can NEVER reach the operator's real cluster context, even
# before the file exists (kubectl just fails, which is guarded).
export KUBECONFIG="$WORK/kubeconfig"

T0=$SECONDS
LAST_OUTPUT=$SECONDS
declare -A PREV=()   # key -> last value seen, so only CHANGES print
declare -A FIRST=()  # key -> when first seen, for the per-resource timer
declare -A SEEN=()   # append-only event streams (ASG activities, RDS events)

hms() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
dur() { if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); else printf '%ds' "$1"; fi; }

say() { printf '  aws | %s  %s\n' "$(hms $(( SECONDS - T0 )))" "$*"; LAST_OUTPUT=$SECONDS; }

# emit <key> <label> <value...> -- prints ONLY when the value changed. The dedup is the whole
# point: without it this is just noise every 15 seconds.
emit() {
  local key="$1" label="$2"; shift 2
  local val="$*" age=""
  [ -z "$val" ] && return 0
  [ "${PREV[$key]:-}" = "$val" ] && return 0
  if [ -n "${FIRST[$key]:-}" ]; then age="  ($(dur $(( SECONDS - FIRST[$key] ))))"; else FIRST[$key]=$SECONDS; fi
  PREV[$key]="$val"
  say "$(printf '%-30s %s%s' "$label" "$val" "$age")"
}

# emit_new <stream> <line...> -- for append-only streams, where each distinct line prints once.
emit_new() {
  local stream="$1"; shift
  local val="$*"
  [ -z "$val" ] && return 0
  local h="$stream:$val"
  [ -n "${SEEN[$h]:-}" ] && return 0
  SEEN[$h]=1
  say "$val"
}

aws_text() { "$AWS_CMD" "$@" --region "$REGION" --output text 2>/dev/null || true; }
none() { [ -z "$1" ] || [ "$1" = "None" ]; }

# ---------------------------------------------------------------------------------------------
# shared probes
# ---------------------------------------------------------------------------------------------
probe_vpc() {
  [ -n "$VPC" ] && return 0
  local v; v="$(aws_text ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER}-eks-vpc" --query 'Vpcs[0].VpcId')"
  none "$v" && return 0
  VPC="$v"
  emit vpc "VPC" "$VPC"
}

probe_nat() {
  [ -z "$VPC" ] && return 0
  local s; s="$(aws_text ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" --query 'NatGateways[].State')"
  none "$s" && return 0
  emit nat "NAT gateway" "$s"
}

probe_eks() {
  local s; s="$(aws_text eks describe-cluster --name "$CLUSTER" --query 'cluster.status')"
  if none "$s"; then
    [ "$MODE" = destroy ] && emit eks "EKS control plane" "gone"
    return 0
  fi
  emit eks "EKS control plane" "$s"
  [ "$s" = "ACTIVE" ] && kube_bootstrap
}

probe_nodegroup() {
  if [ -z "$NG" ]; then
    NG="$(aws_text eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[0]')"
    none "$NG" && { NG=""; return 0; }
  fi
  local s; s="$(aws_text eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --query 'nodegroup.status')"
  if none "$s"; then
    [ "$MODE" = destroy ] && emit ng "node group $NG" "gone"
    return 0
  fi
  emit ng "node group $NG" "$s"
  # The ASG name is EKS-generated (eks-default-<uuid>), never guessable -- resolve it, don't assume.
  if [ -z "$ASG" ]; then
    ASG="$(aws_text eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
      --query 'nodegroup.resources.autoScalingGroups[0].name')"
    none "$ASG" && ASG=""
  fi
}

probe_asg_activities() {
  [ -z "$ASG" ] && return 0
  local desc prog code
  while IFS=$'\t' read -r desc prog code; do
    [ -z "$desc" ] && continue
    emit_new asg "$(printf 'ASG   %s  [%s %s%%]' "$desc" "$code" "$prog")"
  done < <(aws_text autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
    --max-items 10 --query 'Activities[].[Description,Progress,StatusCode]')
}

# The worker instances are launched by the EKS-managed ASG, NOT by Terraform, so the provider's
# default_tags (Project/Environment) never reach them. tag:eks:cluster-name is AWS-injected and is
# the filter that actually matches.
probe_instances() {
  local id st ids=""
  while IFS=$'\t' read -r id st; do
    [ -z "$id" ] && continue
    emit "i-$id" "instance $id" "$st"
    ids="$ids $id"
  done < <(aws_text ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]')
  INSTANCE_IDS="$ids"
}

# describe-instance-status does NOT support tag filters, so it has to be fed the ids collected
# above. --include-all-instances is required or instances that are not yet `running` are omitted --
# which is exactly the window we want to watch.
probe_instance_checks() {
  [ -z "${INSTANCE_IDS// /}" ] && return 0
  local id sys inst
  while IFS=$'\t' read -r id sys inst; do
    [ -z "$id" ] && continue
    local note=""
    [ "$sys" = "ok" ] && [ "$inst" = "ok" ] && note="   <- OS up"
    emit "s-$id" "instance $id checks" "system=$sys instance=$inst$note"
  done < <(aws_text ec2 describe-instance-status --include-all-instances \
    --instance-ids $INSTANCE_IDS \
    --query 'InstanceStatuses[].[InstanceId,SystemStatus.Status,InstanceStatus.Status]')
}

probe_rds() {
  local s; s="$(aws_text rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus')"
  if none "$s"; then
    emit rds "RDS $DB_ID" "$([ "$MODE" = destroy ] && echo gone || echo 'not created yet')"
    return 0
  fi
  emit rds "RDS $DB_ID" "$s"
}

# The closest thing to a narrative AWS publishes anywhere in this stack.
probe_rds_events() {
  local d msg
  while IFS=$'\t' read -r d msg; do
    [ -z "$msg" ] && continue
    emit_new rdsev "RDS   event: $msg"
  done < <(aws_text rds describe-events --source-identifier "$DB_ID" --source-type db-instance \
    --duration 60 --query 'Events[].[Date,Message]')
}

probe_acm() {
  local dom st
  while IFS=$'\t' read -r dom st; do
    [ -z "$dom" ] && continue
    emit "acm-$dom" "certificate $dom" "$st"
  done < <(aws_text acm list-certificates --query 'CertificateSummaryList[].[DomainName,Status]')
}

probe_addons() {
  local a st
  for a in $(aws_text eks list-addons --cluster-name "$CLUSTER" --query 'addons[]'); do
    [ "$a" = "None" ] && continue
    st="$(aws_text eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --query 'addon.status')"
    none "$st" && continue
    emit "addon-$a" "add-on $a" "$st"
  done
}

# ---------------------------------------------------------------------------------------------
# cluster-side probes (the last third of step 6 -- the ten Helm add-ons -- is otherwise silent)
# ---------------------------------------------------------------------------------------------
kube_bootstrap() {
  [ "$KUBE" = 1 ] && return 0
  "$AWS_CMD" eks update-kubeconfig --name "$CLUSTER" --region "$REGION" \
    --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 && KUBE=1
}

probe_nodes() {
  [ "$KUBE" = 1 ] || return 0
  local n st
  while read -r n st; do
    [ -z "$n" ] && continue
    local note=""
    [ "$st" = "Ready" ] && note="   <- kubelet joined"
    emit "node-$n" "node $n" "$st$note"
  done < <("$KUBECTL_CMD" get nodes --no-headers 2>/dev/null | awk '{print $1, $2}')
}

probe_helm() {
  [ "$KUBE" = 1 ] || return 0
  local names
  names="$("$HELM_CMD" list -A -q 2>/dev/null | sort | tr '\n' ' ')"
  [ -z "${names// /}" ] && return 0
  emit helm "helm releases ($(printf '%s' "$names" | wc -w))" "$names"
}

probe_pods() {
  [ "$KUBE" = 1 ] || return 0
  local s
  s="$("$KUBECTL_CMD" get pods -A --no-headers 2>/dev/null \
    | awk '{t[$1]++; if ($4=="Running" || $4=="Completed") r[$1]++} END {for (n in t) printf "%s %d/%d  ", n, r[n], t[n]}')"
  [ -z "${s// /}" ] && return 0
  emit pods "pods by namespace" "$s"
}

# ---------------------------------------------------------------------------------------------
# destroy-only probes
# ---------------------------------------------------------------------------------------------
# The only genuine percentage in the whole teardown. Newest snapshot only -- during a destroy that
# is the final snapshot being taken, which is what the RDS delete is actually waiting on.
probe_final_snapshot() {
  local id st pct
  IFS=$'\t' read -r id st pct < <(aws_text rds describe-db-snapshots \
    --db-instance-identifier "$DB_ID" --snapshot-type manual \
    --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].[DBSnapshotIdentifier,Status,PercentProgress]')
  none "${id:-}" && return 0
  emit "snap" "final snapshot $id" "$st ${pct}%"
}

probe_alb() {
  [ -z "$VPC" ] && return 0
  local n; n="$(aws_text elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='$VPC'])")"
  none "$n" && return 0
  emit alb "load balancers in VPC" "$n"
}

# This is the payoff for the "Still destroying... subnet" stall: a detached CNI interface is what
# blocks DeleteSubnet, and destroy.sh's reaper clears them. Showing the count makes a 10-20 minute
# silence legible instead of alarming.
probe_enis() {
  [ -z "$VPC" ] && return 0
  local total detached
  total="$(aws_text ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --query 'length(NetworkInterfaces)')"
  detached="$(aws_text ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" Name=status,Values=available --query 'length(NetworkInterfaces)')"
  none "$total" && return 0
  emit eni "network interfaces left" "$total ($detached detached)"
}

probe_vpc_gone() {
  [ -z "$VPC" ] && return 0
  local v; v="$(aws_text ec2 describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].VpcId')"
  none "$v" && emit vpc "VPC" "gone"
}

# ---------------------------------------------------------------------------------------------
poll_apply() {
  probe_vpc
  probe_nat
  probe_eks
  probe_nodegroup
  probe_asg_activities
  probe_instances
  probe_instance_checks
  probe_rds
  probe_rds_events
  probe_acm
  probe_addons
  probe_nodes
  probe_helm
  probe_pods
}

poll_destroy() {
  probe_vpc
  probe_final_snapshot
  probe_rds
  probe_rds_events
  probe_instances
  probe_nodegroup
  probe_eks
  probe_nat
  probe_alb
  probe_enis
  probe_vpc_gone
}

# A quiet stretch must never read as a dead watcher.
heartbeat() {
  [ $(( SECONDS - LAST_OUTPUT )) -lt "$IDLE" ] && return 0
  # Values alone are ambiguous -- "ACTIVE | available | ACTIVE" tells you nothing about which is
  # which. Name each one.
  local k parts=()
  declare -A short=([eks]="EKS" [rds]="RDS" [ng]="nodes" [snap]="snapshot" [eni]="ENIs left")
  for k in eks rds ng snap eni; do
    [ -n "${PREV[$k]:-}" ] && parts+=("${short[$k]} ${PREV[$k]}")
  done
  [ ${#parts[@]} -eq 0 ] && return 0
  local joined=""
  for k in "${parts[@]}"; do joined="${joined:+$joined | }$k"; done
  say "still waiting: $joined   ($(dur $(( SECONDS - T0 ))) elapsed)"
}

if [ "$ONCE" = 1 ]; then
  "poll_$MODE"
  exit 0
fi

nap() { sleep "$1" & SLEEP_PID=$!; wait "$SLEEP_PID" 2>/dev/null; SLEEP_PID=""; }

nap "$DELAY"
while :; do
  "poll_$MODE"
  heartbeat
  nap "$POLL"
done
