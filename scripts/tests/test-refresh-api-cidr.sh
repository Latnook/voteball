#!/usr/bin/env bash
# Offline test for scripts/refresh-api-cidr.sh. Never touches the network: the public-IP lookup is
# stubbed through VOTEBALL_PUBLIC_IP_CMD, which is the only reason that override exists.
#
# What this actually protects: the script writes a firewall allow-list from a value that arrived over
# the network. A garbled response written verbatim either fails `terraform plan` minutes later or --
# worse -- lands as a plausible-looking CIDR that locks this machine out of its own cluster. The
# refusal cases below are the point of the file; the happy path is the easy half.
set -uo pipefail

cd "$(dirname "$0")/../.."
SCRIPT_UNDER_TEST="$PWD/scripts/refresh-api-cidr.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; pass=$((pass+1)); }

fresh_tfvars() {
  printf 'aws_region   = "il-central-1"\ncluster_name = "voteball"\n' > "$work/tfvars"
}

run() {  # run <stub-ip-output> [args...]
  local stub="$1"; shift
  TFVARS="$work/tfvars" VOTEBALL_PUBLIC_IP_CMD="printf %s $stub" \
    bash "$SCRIPT_UNDER_TEST" "$@" 2>&1
}

# ---- 1. appends the key when the tfvars does not carry it yet -----------------------------------
fresh_tfvars
out="$(run 203.0.113.4)" || fail "expected success on a fresh tfvars, got: $out"
grep -qE '^cluster_endpoint_public_access_cidrs = \["203\.0\.113\.4/32"\]$' "$work/tfvars" \
  || fail "the key was not appended as a /32 list; file is: $(cat "$work/tfvars")"
ok "a detected address is appended as a /32 CIDR list"

# ---- 2. rewrites in place rather than appending a second copy -----------------------------------
out="$(run 198.51.100.7)" || fail "expected success on rewrite, got: $out"
count="$(grep -cE '^cluster_endpoint_public_access_cidrs' "$work/tfvars")"
[ "$count" = "1" ] || fail "expected exactly one key line after a rewrite, found $count"
grep -qE '^cluster_endpoint_public_access_cidrs = \["198\.51\.100\.7/32"\]$' "$work/tfvars" \
  || fail "the rewrite did not take; file is: $(cat "$work/tfvars")"
ok "a changed address rewrites the existing line, leaving exactly one"

# ---- 3. the surrounding tfvars is left alone ----------------------------------------------------
grep -q '^aws_region   = "il-central-1"$' "$work/tfvars" || fail "the rewrite disturbed other keys"
grep -q '^cluster_name = "voteball"$'     "$work/tfvars" || fail "the rewrite disturbed other keys"
ok "other tfvars keys survive the rewrite untouched"

# ---- 4. idempotent -- a second identical run changes nothing and exits 0 ------------------------
before="$(cat "$work/tfvars")"
out="$(run 198.51.100.7)" || fail "a no-op run must exit 0, got: $out"
[ "$before" = "$(cat "$work/tfvars")" ] || fail "a no-op run rewrote the file"
grep -q "already sets" <<<"$out" || fail "a no-op run should say so, got: $out"
ok "an unchanged address is a no-op that still exits 0"

# ---- 5. --check reports drift WITHOUT writing, and exits non-zero -------------------------------
before="$(cat "$work/tfvars")"
out="$(run 192.0.2.9 --check)" && fail "--check must exit non-zero when it would change something"
[ "$before" = "$(cat "$work/tfvars")" ] || fail "--check wrote to the file"
grep -q "would change" <<<"$out" || fail "--check should describe the change, got: $out"
ok "--check reports drift, writes nothing, and exits non-zero"

out="$(run 198.51.100.7 --check)" || fail "--check must exit 0 when already correct, got: $out"
ok "--check exits 0 when the file already matches"

# ---- 6. explicit CIDR arguments override detection ----------------------------------------------
out="$(run 203.0.113.4 10.0.0.0/8 192.168.0.0/16)" || fail "explicit CIDRs should be accepted: $out"
grep -qE '^cluster_endpoint_public_access_cidrs = \["10\.0\.0\.0/8", "192\.168\.0\.0/16"\]$' "$work/tfvars" \
  || fail "explicit CIDRs were not written as given; file is: $(cat "$work/tfvars")"
ok "explicit CIDR arguments override detection and are written verbatim, in order"

# ---- 7. REFUSALS -- a garbled lookup must never reach the file ----------------------------------
# This is the half that matters. checkip.amazonaws.com behind a captive portal returns an HTML login
# page; a proxy can return an error body; a truncated read returns a partial address. Each of those
# is a plausible string that must not become a firewall rule.
fresh_tfvars
before="$(cat "$work/tfvars")"

for bad in "not-an-ip" "<html>error</html>" "203.0.113" "203.0.113.4.5" "" "1.2.3.4.5.6"; do
  out="$(run "$bad" 2>&1)" && fail "expected refusal for lookup result '$bad', but it succeeded"
  [ "$before" = "$(cat "$work/tfvars")" ] || fail "refused input '$bad' still modified the tfvars"
done
ok "a non-address lookup result is refused and never written (6 shapes)"

# ---- 8. a missing tfvars is an error, not a silently created file -------------------------------
# Creating one here would produce a tfvars holding ONLY this key, which then fails terraform on every
# other required variable -- a confusing failure several steps removed from its cause.
rm -f "$work/tfvars"
out="$(run 203.0.113.4 2>&1)" && fail "expected an error when the tfvars does not exist"
[ -f "$work/tfvars" ] && fail "a missing tfvars must not be created"
grep -q "does not exist" <<<"$out" || fail "the error should name the missing file, got: $out"
ok "a missing tfvars errors out rather than being created half-populated"

# ---- 9. the variable really has no default, which is what makes this script necessary -----------
grep -qE 'variable "cluster_endpoint_public_access_cidrs"' terraform/variables.tf \
  || fail "terraform/variables.tf no longer declares cluster_endpoint_public_access_cidrs"
block="$(awk '/^variable "cluster_endpoint_public_access_cidrs"/,/^}/' terraform/variables.tf)"
grep -qE '^\s*default\s*=' <<<"$block" \
  && fail "cluster_endpoint_public_access_cidrs has a default again -- the 0.0.0.0/0 default was removed on 2026-08-23 (Task 3 review T3-2) precisely so a fork cannot inherit an open control plane without deciding to. Remove the default, or delete this test and say why."
ok "the tfvars variable still has NO default (an open endpoint stays an explicit choice)"

echo "PASS: $(basename "$0") -- $pass checks"
