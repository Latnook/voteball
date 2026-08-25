#!/usr/bin/env bash
# Offline test for scripts/verify-public-dns.sh. No cluster, no kubectl, no network: every external
# command the script runs is injected through PUBDNS_*_CMD.
#
# The branch that matters most is #2. Restarting CoreDNS when the record simply does not exist yet
# would "fix" nothing, would happen on most fresh deploys, and would train everyone to ignore the
# step. The script must restart ONLY when the outside world can resolve a name the cluster cannot --
# which is the signature of a cached negative answer and nothing else.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT_UNDER_TEST=scripts/verify-public-dns.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { echo "  ok   $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*" >&2; fail=$((fail+1)); }

run() { # runs the script with the given stubs, capturing output and rc
  set +e
  OUT="$(env PUBDNS_SLEEP=0 PUBDNS_ATTEMPTS=2 "$@" bash "$SCRIPT_UNDER_TEST" example.test 2>&1)"
  RC=$?
  set -e
}

echo "1. resolves immediately -> success, and CoreDNS is NOT restarted"
run PUBDNS_RESOLVE_CMD='echo 1.2.3.4' \
    PUBDNS_PUBLIC_RESOLVE_CMD='true' \
    PUBDNS_RESTART_CMD="touch $TMP/restarted-1"
[ "$RC" = 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $OUT"
[ -e "$TMP/restarted-1" ] && bad "restarted CoreDNS despite DNS being healthy" || ok "no restart"

echo "2. cluster cannot resolve AND neither can the public -> fail WITHOUT restarting"
run PUBDNS_RESOLVE_CMD='exit 1' \
    PUBDNS_PUBLIC_RESOLVE_CMD='exit 1' \
    PUBDNS_RESTART_CMD="touch $TMP/restarted-2"
[ "$RC" = 1 ] && ok "exit 1" || bad "expected exit 1, got $RC: $OUT"
[ -e "$TMP/restarted-2" ] && bad "restarted CoreDNS for a record that does not exist yet" || ok "no restart"
grep -q "record does not exist yet" <<<"$OUT" && ok "says the record is missing, not that DNS is broken" \
  || bad "did not distinguish a missing record from a cache fault: $OUT"

echo "3. only the cluster cannot resolve -> restart, then success"
printf 'x' > "$TMP/first"
run PUBDNS_RESOLVE_CMD="if [ -e $TMP/first ]; then rm -f $TMP/first; exit 1; else echo 5.6.7.8; fi" \
    PUBDNS_PUBLIC_RESOLVE_CMD='true' \
    PUBDNS_RESTART_CMD="touch $TMP/restarted-3"
[ "$RC" = 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $OUT"
[ -e "$TMP/restarted-3" ] && ok "restarted CoreDNS" || bad "did not restart CoreDNS on a stale negative cache"
grep -q "5.6.7.8" <<<"$OUT" && ok "reports the address it finally resolved" || bad "no address in output: $OUT"

echo "4. restart does not help -> fail loudly, bounded by PUBDNS_ATTEMPTS"
run PUBDNS_RESOLVE_CMD='exit 1' \
    PUBDNS_PUBLIC_RESOLVE_CMD='true' \
    PUBDNS_RESTART_CMD="echo restarting >> $TMP/restart-count-4"
[ "$RC" = 1 ] && ok "exit 1" || bad "expected exit 1, got $RC: $OUT"
[ "$(wc -l < "$TMP/restart-count-4")" = 1 ] && ok "restarted exactly once, never in a loop" \
  || bad "restarted $(wc -l < "$TMP/restart-count-4") times -- must not loop"
grep -q "no-data fallback" <<<"$OUT" && ok "explains the consequence (availability reads 1 while blind)" \
  || bad "failure message does not say why it matters: $OUT"

echo "5. no hostname anywhere -> a distinct non-zero exit, not a silent pass"
# config.sh reads app_domain from the tfvars and treats it as required, so point TFVARS at a file
# that does not name one. The script must refuse rather than check the empty string and "succeed".
: > "$TMP/empty.tfvars"
set +e
OUT="$(TFVARS="$TMP/empty.tfvars" bash "$SCRIPT_UNDER_TEST" 2>&1)"; RC=$?
set -e
[ "$RC" != 0 ] && ok "refuses with exit $RC" || bad "passed with no hostname configured: $OUT"

echo "6. the DEFAULT public probe asks an authoritative nameserver, never this machine's stub resolver"
# The bug this pins, hit on 2026-08-26: the operator's own resolver had cached the identical NODATA
# answer the cluster was stuck on, so `getent` said "no address" for the same wrong reason and the
# script concluded "the record does not exist yet" about a record that plainly did -- and refused to
# act. A resolver that can be wrong in exactly the way you are trying to detect is not a witness.
# Behavioural, not a grep: `dig` and `getent` are shimmed on PATH and record how they were called.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/dig" <<'DIG'
#!/usr/bin/env bash
echo "dig $*" >> "$DIGLOG"
for a in "$@"; do case "$a" in
  NS) echo "ns-1.example.net."; exit 0 ;;
  @ns-1.example.net.) echo "203.0.113.9"; exit 0 ;;
esac; done
exit 1
DIG
cat > "$BIN/getent" <<'GETENT'
#!/usr/bin/env bash
echo "getent $*" >> "$GETENTLOG"
exit 1
GETENT
chmod +x "$BIN/dig" "$BIN/getent"
: > "$TMP/dig.log"; : > "$TMP/getent.log"
run PATH="$BIN:$PATH" DIGLOG="$TMP/dig.log" GETENTLOG="$TMP/getent.log" \
    PUBDNS_RESOLVE_CMD='exit 1' \
    PUBDNS_RESTART_CMD="touch $TMP/restarted-6"
grep -q '@ns-1.example.net.' "$TMP/dig.log" \
  && ok "queried the zone's authoritative nameserver directly" \
  || bad "never asked an authoritative nameserver; dig calls were: $(cat "$TMP/dig.log")"
[ -s "$TMP/getent.log" ] && bad "fell back to the local stub resolver anyway: $(cat "$TMP/getent.log")" \
  || ok "never consulted the local stub resolver"
[ -e "$TMP/restarted-6" ] && ok "treated the authoritative answer as proof the record exists" \
  || bad "did not act on a record the authority can resolve: $OUT"

echo "7. when the restart does not help, it says the negative answer is UPSTREAM and self-heals"
# CoreDNS comes back with an empty cache; if it is still told NODATA, the answer is held by the VPC
# resolver, which nothing in this cluster can clear. The old message described that as a flat failure,
# which sends an operator debugging a cluster that is fine for the ~15 minutes it needs.
run PUBDNS_RESOLVE_CMD='exit 1' \
    PUBDNS_PUBLIC_RESOLVE_CMD='true' \
    PUBDNS_RESTART_CMD='true'
grep -q "UPSTREAM" <<<"$OUT" && ok "names the cache that actually holds it" \
  || bad "does not say the negative answer is upstream: $OUT"
grep -q "heals by itself" <<<"$OUT" && ok "says it resolves on its own rather than reading as broken" \
  || bad "does not say it self-heals: $OUT"
grep -q "PUBLIC path is" <<<"$OUT" && ok "says visitors are unaffected" \
  || bad "does not distinguish the canary's view from a real outage: $OUT"

echo
if [ "$fail" -gt 0 ]; then echo "FAIL — $fail of $((pass+fail)) checks failed" >&2; exit 1; fi
echo "PASS — all $pass checks green"
