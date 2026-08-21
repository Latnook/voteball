#!/usr/bin/env bash
# Tests scripts/watch-aws-progress.sh -- the background narrator that deploy.sh step 6 and
# destroy.sh step 7 run alongside terraform. Fully offline: `aws`, `kubectl` and `helm` are replaced
# by fake executables via AWSWATCH_STUB_*_CMD, and the poll/delay knobs are compressed to seconds,
# so this needs no cluster, no AWS account and no deploy.
#
# What it is guarding, in order of how badly it would hurt:
#
#   1. READ-ONLY. This process runs CONCURRENTLY with `terraform destroy`, against a live account,
#      while the state lock is held. A mutating call that slipped in here would race a teardown.
#      "Read-only by intention" is not a property -- the test records every operation the stub is
#      asked to run and fails on any verb that is not describe*/list*/get*.
#   2. It must NEVER take the parent down. It is backgrounded inside a script running under
#      `set -euo pipefail`, in front of a billed ~13-minute apply. A watcher that aborts because a
#      describe call hiccuped is strictly worse than no watcher at all.
#   3. It must print only CHANGES. Without dedup it emits the same six lines every 15 seconds and
#      becomes noise that hides the transitions it exists to show.
#
# None of the three is visible from reading the output of a successful deploy, which is why they
# need a test.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SCRIPT=./scripts/watch-aws-progress.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

OPS="$work/ops.log"      # "<service> <operation>" per call
ARGV="$work/argv.log"    # full argv per call
: >"$OPS"; : >"$ARGV"

# ---- the fake aws ------------------------------------------------------------------------------
# Answers are driven by files in $work so a test can change them between polls.
make_aws() {
  cat >"$work/aws" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "$OPS"
echo "$*" >> "$ARGV"
q=""
for a in "$@"; do [ "$prev" = "--query" ] 2>/dev/null && q="$a"; prev="$a"; done
case "$1 $2" in
  "ec2 describe-vpcs")            echo "vpc-test123" ;;
  "ec2 describe-nat-gateways")    echo "available" ;;
  "eks describe-cluster")         cat "$STATE_DIR/eks" 2>/dev/null || echo "" ;;
  "eks list-nodegroups")          echo "default-abc" ;;
  "eks describe-nodegroup")
      case "$q" in *autoScalingGroups*) echo "eks-default-xyz" ;; *) echo "CREATING" ;; esac ;;
  "eks list-addons")              echo "vpc-cni" ;;
  "eks describe-addon")           echo "ACTIVE" ;;
  "eks update-kubeconfig")        echo "updated" ;;
  "autoscaling describe-scaling-activities")
      printf 'Launching a new EC2 instance: i-0abc\t100\tSuccessful\n' ;;
  "ec2 describe-instances")       printf 'i-0abc\trunning\n' ;;
  "ec2 describe-instance-status") cat "$STATE_DIR/checks" 2>/dev/null || echo "" ;;
  "rds describe-db-instances")    cat "$STATE_DIR/rds" 2>/dev/null || echo "" ;;
  "rds describe-events")          printf '2026-08-21\tRestored from snapshot\n' ;;
  "rds describe-db-snapshots")    cat "$STATE_DIR/snap" 2>/dev/null || echo "" ;;
  "acm list-certificates")        printf 'voteball.example.com\tISSUED\n' ;;
  "elbv2 describe-load-balancers") echo "1" ;;
  "ec2 describe-network-interfaces") echo "14" ;;
  *) echo "" ;;
esac
exit 0
STUB
  chmod +x "$work/aws"
}
make_aws

cat >"$work/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get nodes"*) echo "ip-10-0-1-1   Ready   <none>   5m   v1.36.0" ;;
  *"get pods"*)  echo "devops-app   backend-1   1/1   Running   0   5m" ;;
esac
exit 0
STUB
cat >"$work/helm" <<'STUB'
#!/usr/bin/env bash
printf 'argocd\njenkins\n'
exit 0
STUB
chmod +x "$work/kubectl" "$work/helm"

STATE="$work/state"; mkdir -p "$STATE"
export OPS ARGV
export STATE_DIR="$STATE"
export AWSWATCH_STUB_AWS_CMD="$work/aws"
export AWSWATCH_STUB_KUBECTL_CMD="$work/kubectl"
export AWSWATCH_STUB_HELM_CMD="$work/helm"

# ---- 1. a single pass reports what AWS currently says -------------------------------------------
echo "ACTIVE" >"$STATE/eks"
echo "available" >"$STATE/rds"
printf 'i-0abc\tok\tok\n' >"$STATE/checks"

out="$("$SCRIPT" apply --once 2>&1)" || fail "apply --once must exit 0, got: $out"
grep -q "EKS control plane" <<<"$out" || fail "expected the EKS control plane state: $out"
grep -q "RDS " <<<"$out"              || fail "expected the RDS state: $out"
ok "a single apply pass reports the live resource states"

grep -q "OS up" <<<"$out" || fail "status checks system=ok/instance=ok must be called out as the OS being up: $out"
ok "EC2 status checks ok/ok are labelled as the OS coming up"

grep -q "kubelet joined" <<<"$out" || fail "a Ready node must be labelled as the kubelet joining: $out"
ok "a Ready node is labelled as the kubelet joining"

grep -q "Restored from snapshot" <<<"$out" || fail "the RDS event stream must be surfaced verbatim: $out"
ok "RDS event sentences are surfaced verbatim"

grep -q "helm releases" <<<"$out" || fail "expected the Helm add-on progress: $out"
ok "Helm releases are counted as they land (the silent last third of step 6)"

# ---- 2. READ-ONLY: no mutating operation, ever --------------------------------------------------
# The operation is field 2 of every call, so this cannot be fooled by the word "Create" appearing
# inside a --query expression (sort_by(...,&SnapshotCreateTime) does exactly that).
if bad="$(awk '{print $2}' "$OPS" | grep -vE '^(describe|list|get)-' | grep -v '^update-kubeconfig$' | sort -u)"; [ -n "$bad" ]; then
  fail "watcher issued non-read-only AWS operations: $bad"
fi
ok "every AWS operation is describe*/list*/get* (no mutation, ever)"

# The one write it does make must land in a throwaway file, never the operator's real context.
if grep -q "update-kubeconfig" "$ARGV"; then
  grep "update-kubeconfig" "$ARGV" | grep -q -- "--kubeconfig" \
    || fail "update-kubeconfig must be pinned to a throwaway --kubeconfig file"
  grep "update-kubeconfig" "$ARGV" | grep -q "\.kube/config" \
    && fail "update-kubeconfig must NEVER target the operator's ~/.kube/config"
  ok "update-kubeconfig writes only a throwaway kubeconfig, never ~/.kube/config"
fi

# ---- 3. only CHANGES print ----------------------------------------------------------------------
# Four passes over an unchanging account must report each resource exactly once.
out="$(VOTEBALL_WATCH_START_DELAY=0 VOTEBALL_WATCH_POLL_SECS=1 VOTEBALL_WATCH_IDLE_SECS=9999 \
  timeout 4 "$SCRIPT" apply 2>&1)"
n="$(grep -c "EKS control plane" <<<"$out")"
[ "$n" = 1 ] || fail "an unchanged state must print once, not $n times (that is noise, not progress)"
ok "an unchanged state prints exactly once across repeated polls"

# ---- 4. a transition prints, and names the new state --------------------------------------------
cat >"$STATE/eks" <<'EOF'
CREATING
EOF
( sleep 2; echo "ACTIVE" >"$STATE/eks" ) &
flip=$!
out="$(VOTEBALL_WATCH_START_DELAY=0 VOTEBALL_WATCH_POLL_SECS=1 VOTEBALL_WATCH_IDLE_SECS=9999 \
  timeout 5 "$SCRIPT" apply 2>&1)"
wait "$flip" 2>/dev/null
grep -q "EKS control plane .*CREATING" <<<"$out" || fail "expected the CREATING state: $out"
grep -q "EKS control plane .*ACTIVE"   <<<"$out" || fail "expected the ACTIVE transition: $out"
ok "a state transition prints both states"
grep -qE "EKS control plane .*ACTIVE.*\([0-9]+m?[0-9]*s\)" <<<"$out" \
  || fail "a transition must carry how long that resource took: $out"
ok "a transition reports how long the resource took"
echo "ACTIVE" >"$STATE/eks"

# ---- 5. a broken AWS never kills the watcher (or, in real life, the billed apply) ----------------
cat >"$work/aws" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "$OPS"
echo "boom" >&2
exit 1
STUB
chmod +x "$work/aws"
out="$("$SCRIPT" apply --once 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "a failing AWS CLI must not make the watcher exit non-zero (got $rc): $out"
ok "a failing AWS CLI still exits 0 -- it can never abort the parent deploy"

grep -q "boom" <<<"$out" && fail "AWS stderr must not be dumped into the deploy output: $out"
ok "AWS errors stay quiet rather than spamming the terminal"
make_aws

# ---- 6. destroy mode: the final snapshot percentage ---------------------------------------------
printf 'voteball-eks-db-final-20260821\tcreating\t34\n' >"$STATE/snap"
echo "deleting" >"$STATE/rds"
out="$("$SCRIPT" destroy --once 2>&1)" || fail "destroy --once must exit 0: $out"
grep -q "final snapshot .*creating 34%" <<<"$out" \
  || fail "destroy must surface the final snapshot PercentProgress (the only real % there is): $out"
ok "destroy mode reports the final snapshot percentage"
grep -q "network interfaces left" <<<"$out" \
  || fail "destroy must report the ENI count -- that is what blocks DeleteSubnet: $out"
ok "destroy mode reports the ENI count that stalls subnet deletion"
grep -q "RDS .*deleting" <<<"$out" || fail "expected the RDS deleting state: $out"
ok "destroy mode reports the RDS teardown state"

# ---- 7. the launcher block in deploy.sh actually launches (and honours the off switch) -----------
# Extracted from the LIVE script between its sentinel comments, per test-build-push-ecr.sh -- a
# hand-copied duplicate would pass forever while the real deploy did something else.
awk '/^# --- BEGIN aws progress watcher ---$/,/^# --- END aws progress watcher ---$/' \
  scripts/deploy.sh >"$work/launch.sh"
[ -s "$work/launch.sh" ] || fail "could not extract the watcher launcher from scripts/deploy.sh"
grep -q "VOTEBALL_NO_WATCH" "$work/launch.sh" || fail "the launcher lost its off switch"
grep -q "trap" "$work/launch.sh" || fail "the launcher must trap EXIT, or a Ctrl-C leaks the watcher"
ok "deploy.sh still carries the sentinel-delimited launcher, with its off switch and trap"

mkdir -p "$work/probe/scripts"
cat >"$work/probe/scripts/watch-aws-progress.sh" <<'FAKE'
#!/usr/bin/env bash
sleep 30
FAKE
chmod +x "$work/probe/scripts/watch-aws-progress.sh"
cp "$work/launch.sh" "$work/probe/launch.sh"

out="$(cd "$work/probe" && VOTEBALL_NO_WATCH=1 bash -c '. ./launch.sh; echo "PID=[$WATCH_PID]"')"
grep -q 'PID=\[\]' <<<"$out" || fail "VOTEBALL_NO_WATCH=1 must launch nothing, got: $out"
ok "VOTEBALL_NO_WATCH=1 launches nothing"

out="$(cd "$work/probe" && bash -c '. ./launch.sh; sleep 0.3; kill -0 "$WATCH_PID" && echo ALIVE; kill "$WATCH_PID" 2>/dev/null')"
grep -q ALIVE <<<"$out" || fail "the launcher must actually start the watcher, got: $out"
ok "the launcher actually starts the watcher in the background"

# ---- 8. killing the watcher takes its sleep child with it ---------------------------------------
# `kill` on a shell blocked in `sleep` orphans that sleep, which then lingers for up to the poll
# interval (30s at the start delay). deploy.sh and destroy.sh kill this thing on every EXIT and on
# Ctrl-C, so the litter is guaranteed, not hypothetical.
VOTEBALL_WATCH_START_DELAY=30 VOTEBALL_WATCH_POLL_SECS=30 "$SCRIPT" apply >/dev/null 2>&1 &
wpid=$!
sleep 1
# Read the child list from /proc rather than pgrep/ps: python:3.12-slim (one of the two containers
# Jenkins runs this suite in) ships no procps at all, so pgrep here fails the build.
kids="$(cat "/proc/$wpid/task/$wpid/children" 2>/dev/null)"
[ -n "${kids// /}" ] || fail "expected the watcher to be waiting on a backgrounded sleep child"
kill "$wpid" 2>/dev/null
sleep 1
for k in $kids; do
  kill -0 "$k" 2>/dev/null && fail "killing the watcher orphaned its sleep child (pid $k)"
done
ok "killing the watcher takes its sleep child with it (no orphans on Ctrl-C)"

echo "PASS: scripts/tests/test-aws-progress-watch.sh"
