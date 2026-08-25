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

# ---- 10. --ensure leaves a list that ALREADY COVERS this machine alone --------------------------
# This is the case plain --check gets wrong, and the reason --ensure exists: --check compares the
# rendered line as text, so any list that is not literally ["<my ip>/32"] reads as drift. An
# unattended deploy acting on that would replace a deliberately broad list with one host.
set_list() { printf 'aws_region   = "il-central-1"\ncluster_endpoint_public_access_cidrs = [%s]\ncluster_name = "voteball"\n' "$1" > "$work/tfvars"; }

for covering in '"0.0.0.0/0"' '"203.0.113.0/24"' '"203.0.113.4/32"' '"10.0.0.0/8", "203.0.113.0/24"'; do
  set_list "$covering"
  before="$(cat "$work/tfvars")"
  out="$(run 203.0.113.4 --ensure)" || fail "--ensure must exit 0 when already covered ($covering): $out"
  [ "$before" = "$(cat "$work/tfvars")" ] || fail "--ensure rewrote a list that already covers the address ($covering)"
  grep -q "already covers" <<<"$out" || fail "--ensure should say the list already covers it, got: $out"
done
ok "--ensure is a no-op when any entry already covers this machine (4 lists, incl. 0.0.0.0/0)"

# ---- 11. --ensure replaces a STALE /32 when the address is not covered --------------------------
set_list '"198.51.100.7/32"'
out="$(run 203.0.113.4 --ensure)" || fail "--ensure should succeed when it has to write: $out"
grep -qE '^cluster_endpoint_public_access_cidrs = \["203\.0\.113\.4/32"\]$' "$work/tfvars" \
  || fail "--ensure did not replace the stale /32; file is: $(cat "$work/tfvars")"
ok "--ensure replaces a stale single-host pin with this machine's /32"

# ---- 12. ...but KEEPS every entry broader than a /32 --------------------------------------------
# The asymmetry is the safety property: a /32 is one machine's ephemeral address, anything broader is
# a deliberate policy (a CI runner, an office range) that must survive a deploy nobody was watching.
set_list '"10.0.0.0/8", "198.51.100.7/32", "192.168.0.0/16"'
out="$(run 203.0.113.4 --ensure)" || fail "--ensure should succeed here: $out"
grep -qE '^cluster_endpoint_public_access_cidrs = \["10\.0\.0\.0/8", "192\.168\.0\.0/16", "203\.0\.113\.4/32"\]$' "$work/tfvars" \
  || fail "--ensure did not keep the broad ranges; file is: $(cat "$work/tfvars")"
ok "--ensure keeps every non-/32 entry, drops the stale /32, appends this machine"

# ---- 13. an entry it cannot parse is kept, not deleted ------------------------------------------
# Deleting what it cannot read would silently discard something a human put there on purpose; a
# terraform plan error naming the bad value is the better failure.
set_list '"not-a-cidr"'
out="$(run 203.0.113.4 --ensure)" || fail "--ensure should still write here: $out"
grep -qE '^cluster_endpoint_public_access_cidrs = \["not-a-cidr", "203\.0\.113\.4/32"\]$' "$work/tfvars" \
  || fail "--ensure dropped an unparseable entry; file is: $(cat "$work/tfvars")"
ok "--ensure keeps an entry it cannot parse rather than deleting it"

# ---- 14. --ensure refuses explicit CIDR arguments -----------------------------------------------
set_list '"198.51.100.7/32"'
before="$(cat "$work/tfvars")"
out="$(run 203.0.113.4 --ensure 10.0.0.0/8 2>&1)" && fail "--ensure with explicit CIDRs must be refused"
[ "$before" = "$(cat "$work/tfvars")" ] || fail "the refused --ensure invocation still wrote to the file"
ok "--ensure refuses explicit CIDR arguments instead of silently picking one intent"

# ---- 15. --ensure inherits the refusals: a garbled lookup never reaches the file ----------------
before="$(cat "$work/tfvars")"
for bad in "<html>error</html>" "203.0.113" ""; do
  out="$(run "$bad" --ensure 2>&1)" && fail "--ensure accepted a non-address lookup result '$bad'"
  [ "$before" = "$(cat "$work/tfvars")" ] || fail "--ensure wrote a refused lookup result '$bad'"
done
ok "--ensure refuses a non-address lookup result exactly like the plain form (3 shapes)"

# ---- 16. deploy.sh actually CALLS --ensure ------------------------------------------------------
# The other half of the contract, and the half no test of this script can see. deploy.sh used to
# print a warning and continue; on 2026-08-26 that warning scrolled past and the run died ~13 billed
# minutes later with every helm_release timing out against a control plane that was dropping its
# packets. If that call is ever reverted to --check, this file's --ensure coverage proves nothing.
grep -qE '^\s*elif ! \./scripts/refresh-api-cidr\.sh --ensure; then' scripts/deploy.sh \
  || fail "scripts/deploy.sh no longer runs refresh-api-cidr.sh --ensure in its preflight"
ok "scripts/deploy.sh runs the --ensure preflight (not just --check)"

# ---- 17. --help still prints the usage block ----------------------------------------------------
# The range it prints is derived from where `set -euo pipefail` sits, because the literal 2,16p it
# used to carry stopped covering the usage lines the moment one was added above them -- with no
# error, just a help text quietly missing its last flag.
out="$(bash "$SCRIPT_UNDER_TEST" --help)"
grep -q -- '--ensure' <<<"$out" || fail "--help does not mention --ensure; got: $out"
grep -q 'set -euo pipefail' <<<"$out" && fail "--help is printing past the header comment into the code"
ok "--help prints the whole header comment and stops before the code"

echo "PASS: $(basename "$0") -- $pass checks"
