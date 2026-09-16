#!/usr/bin/env bash
# scripts/cleanup-orphaned-lb-resources.sh -- the teardown sweep for security groups and target groups
# the AWS Load Balancer Controller left behind (2026-09-16: two of each kind blocked `aws_vpc`).
#
# It DELETES things in a live account, so most of these tests are about what it refuses to touch.
# Fully offline: `aws` is a bash fake on PATH that serves scenario files and logs every call, and it
# REFUSES a security-group listing that carries neither the ownership-tag filter nor the name filter,
# so dropping the tag filter from the script fails here instead of widening the sweep silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/scripts/lib" "$work/s"
cp "$ROOT/scripts/cleanup-orphaned-lb-resources.sh" "$work/repo/scripts/"
cat > "$work/repo/scripts/lib/config.sh" <<'EOF'
export AWS_PAGER=""
REGION="test-region-1"
CLUSTER="voteball"
EOF
cat > "$work/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform must not be invoked by this test" >&2
exit 127
EOF

S="$work/s"
cat > "$work/bin/aws" <<EOF
#!/usr/bin/env bash
S="$S"
echo "\$*" >> "$work/calls.log"
args="\$*"
out() { [ -f "\$S/\$1" ] && cat "\$S/\$1"; return 0; }
case "\$args" in
  *describe-vpcs*)
    case "\$args" in *"tag:Name,Values=voteball*"*) ;; *) exit 9 ;; esac
    if [ -s "\$S/vpc" ]; then cat "\$S/vpc"; else echo None; fi ;;
  *describe-load-balancers*)
    [ -f "\$S/lb_fail" ] && exit 1
    out lbs ;;
  *describe-network-interfaces*)
    case "\$args" in *"requester-id,Values=amazon-elb"*) ;; *) exit 9 ;; esac
    out enis ;;
  *describe-security-groups*)
    case "\$args" in
      *"tag:elbv2.k8s.aws/cluster,Values=voteball"*) out sg_tagged ;;
      *"group-name,Values=k8s-*"*) out sg_untagged ;;
      *) echo "fake aws: unscoped security-group listing" >&2; exit 9 ;;
    esac ;;
  *delete-security-group*)
    id="\${args##*--group-id }"; id="\${id%% *}"
    [ -f "\$S/sg_fail_always" ] && exit 1
    if [ -f "\$S/failonce_\$id" ]; then rm "\$S/failonce_\$id"; exit 1; fi
    exit 0 ;;
  *describe-target-groups*)
    case "\$args" in *'length(LoadBalancerArns)==\`0\`'*) ;; *) exit 9 ;; esac
    out tgs ;;
  *describe-tags*)
    name="\${args##*targetgroup/}"; name="\${name%%/*}"
    out "owner_\$name" ;;
  *delete-target-group*) exit 0 ;;
  *) echo "fake aws: unexpected call: \$args" >&2; exit 9 ;;
esac
EOF
chmod +x "$work/bin/aws" "$work/bin/terraform"

reset() { rm -f "$S"/*; : > "$work/calls.log"; }
run() { ( cd "$work/repo" && PATH="$work/bin:$PATH" ./scripts/cleanup-orphaned-lb-resources.sh "$@" ) 2>&1; }
deletes() { grep -c 'delete-' "$work/calls.log" || true; }
TG=arn:aws:elasticloadbalancing:test-region-1:111:targetgroup
standard() {
  reset
  echo vpc-1 > "$S/vpc"
  printf 'sg-front\tk8s-voteball-abc\nsg-back\tk8s-traffic-voteball-def\n' > "$S/sg_tagged"
  printf 'sg-stray\tk8s-someone-else\n' > "$S/sg_untagged"
  printf '%s/k8s-logging-voteball-f4d/1\t%s/k8s-foreign-tg/2\n' "$TG" "$TG" > "$S/tgs"
  echo voteball > "$S/owner_k8s-logging-voteball-f4d"
  echo other-cluster > "$S/owner_k8s-foreign-tg"
}

# ---- 1. no VPC: nothing to do, exit 0 ---------------------------------------------------------------
reset
out="$(run --apply)" || fail "no-VPC run exited non-zero:\n$out"
[ "$(deletes)" = 0 ] || fail "deleted something with no VPC"
grep -q 'nothing to clean up' <<<"$out" || fail "no-VPC run did not say so:\n$out"
ok "no VPC -> no calls beyond the lookup, exit 0"

# ---- 2. a live load balancer means its groups are in use -------------------------------------------
standard; echo k8s-voteball-abc > "$S/lbs"
out="$(run --apply)"
[ "$(deletes)" = 0 ] || fail "deleted while a load balancer still exists"
grep -q 'still exists' <<<"$out" || fail "did not report the live load balancer:\n$out"
ok "a load balancer in the VPC blocks every delete"

# ---- 3. the 2026-09-16 ghost: ELB interfaces still attached ------------------------------------------
standard; printf 'eni-1\teni-2\n' > "$S/enis"
out="$(run --apply)"
[ "$(deletes)" = 0 ] || fail "deleted while ELB network interfaces are still attached"
grep -q 'eni-1' <<<"$out" || fail "did not name the blocking interfaces:\n$out"
ok "attached amazon-elb interfaces block every delete"

# ---- 4. a failed load-balancer check is not 'no load balancer' --------------------------------------
standard; touch "$S/lb_fail"
out="$(run --apply)" || fail "failed check exited non-zero:\n$out"
[ "$(deletes)" = 0 ] || fail "a FAILED load-balancer listing was read as 'none' and deletes ran"
ok "a failed listing changes nothing"

# ---- 5. dry run is the default ----------------------------------------------------------------------
standard
out="$(run)"
[ "$(deletes)" = 0 ] || fail "dry run issued a delete"
grep -q 'would delete security group sg-front' <<<"$out" || fail "dry run printed no plan:\n$out"
grep -q 'would delete target group k8s-logging-voteball-f4d' <<<"$out" || fail "dry run omitted the target group:\n$out"
ok "dry run is the default and deletes nothing"

# ---- 6. --apply: exactly the tagged groups and the owned target group --------------------------------
standard
out="$(run --apply)"
grep -q 'delete-security-group .*--group-id sg-front' "$work/calls.log" || fail "tagged sg-front not deleted"
grep -q 'delete-security-group .*--group-id sg-back' "$work/calls.log" || fail "tagged sg-back not deleted"
grep -q 'sg-stray' <<<"$(grep delete- "$work/calls.log")" && fail "DELETED an untagged k8s-* group"
grep -q 'NOT touching sg-stray' <<<"$out" || fail "the untagged k8s-* group was not reported:\n$out"
grep -q 'delete-target-group .*k8s-logging-voteball-f4d' "$work/calls.log" || fail "owned target group not deleted"
grep -q 'delete-target-group .*k8s-foreign-tg' "$work/calls.log" && fail "DELETED a target group owned by another cluster"
[ "$(deletes)" = 3 ] || fail "expected exactly 3 deletes, got $(deletes):\n$(cat "$work/calls.log")"
ok "--apply deletes only resources tagged for this cluster"

# ---- 7. a group referenced by another is retried after it -------------------------------------------
standard; touch "$S/failonce_sg-front"
out="$(run --apply)"
n=$(grep -c 'delete-security-group .*--group-id sg-front' "$work/calls.log" || true)
[ "$n" = 2 ] || fail "expected sg-front to be retried once (2 attempts), got $n"
grep -q 'WARNING' <<<"$out" && fail "warned although the retry succeeded:\n$out"
ok "a delete that fails on the first pass is retried on the second"

# ---- 8. deletes that keep failing warn, and still exit 0 ---------------------------------------------
standard; touch "$S/sg_fail_always"
out="$(run --apply)" || fail "exited non-zero on failed deletes -- would break destroy.sh:\n$out"
grep -q 'WARNING: could not delete security group sg-front' <<<"$out" || fail "no warning for a failed delete:\n$out"
ok "persistent delete failures warn and exit 0"

# ---- 9. destroy.sh runs it, before terraform destroy and from the reaper ------------------------------
D="$ROOT/scripts/destroy.sh"
first_call="$(grep -n 'cleanup-orphaned-lb-resources.sh --apply' "$D" | grep -v 'quiet' | head -1 | cut -d: -f1)"
first_destroy="$(grep -n '^destroy_attempt && DESTROY_OK=1' "$D" | head -1 | cut -d: -f1)"
[ -n "$first_call" ] || fail "destroy.sh never runs the sweep with --apply"
[ "$first_call" -lt "$first_destroy" ] || fail "the sweep runs after the first terraform destroy"
awk '/^reap_orphaned_enis\(\) \{/,/^\}/' "$D" | grep -q 'cleanup-orphaned-lb-resources.sh --apply --quiet' \
  || fail "the background reaper does not run the sweep (needed when AWS clears the ENIs mid-destroy)"
ok "destroy.sh runs the sweep before terraform destroy and inside the reaper"

echo "PASS: cleanup-orphaned-lb-resources"
