#!/usr/bin/env bash
# Prove the CLUSTER can resolve the site's own public hostname, and repair it if it cannot.
#
# THE FAILURE THIS EXISTS FOR, observed on the 2026-08-24 rebuild:
#
#   1. The app is installed. Its pods -- the synthetic canary above all -- start immediately and
#      begin resolving <app_domain>.
#   2. external-dns has not created the A record yet. It only reconciles once the Ingress exists and
#      then on a timer, so there is a window of a minute or more.
#   3. <app_domain> ALREADY EXISTS in Route53 for another reason (this zone carries a
#      google-site-verification TXT record on that exact name). So the query does not return
#      NXDOMAIN -- it returns NOERROR with an empty answer, i.e. "this name exists and has no A
#      record". That is a NEGATIVE answer, and RFC 2308 bounds how long it may be cached at
#      min(SOA record TTL, SOA MINIMUM field) -- for latnook.com min(900, 86400) = 900s, FIFTEEN
#      MINUTES. (This file used to say 86400/twenty-four hours, taking the MINIMUM field alone.
#      docs/eks/live-cluster-snapshot.md had the rule right all along; measured 2026-08-26 with
#      691s remaining on the VPC resolver's copy, of 900.)
#   4. Both caches serve that NODATA until it expires. Which one holds it decides whether anything
#      here can help: CoreDNS caps a denial at 30s (`cache 30`), so restarting it clears its copy
#      almost for free -- but the VPC resolver upstream keeps its own for the full 15 minutes, and
#      no restart in this cluster can touch that one. Measured 2026-08-26: 19s left on CoreDNS,
#      691s left on 10.0.0.2, so the restart below could not have worked and did not.
#   5. The canary therefore makes ZERO requests, so voteball:journey_requests:rate5m sits at 0 --
#      and voteball:availability:ratio5m falls back to `or vector(1)` and reports a confident,
#      wrong 100%. Per the root CLAUDE.md, the canary IS the denominator for every ratio SLI on
#      this site; losing it does not lose one metric, it makes the headline SLI untrustworthy.
#
# VoteballJourneyTrafficStopped does catch this (it went pending 6 minutes into the 2026-08-24
# occurrence and would have fired at 10). This script exists so a rebuild does not START in that
# state and wait ten minutes to say so -- an alert firing on every deploy is an alert people learn
# to ignore.
#
# The repair is a rolling restart of CoreDNS, which drops the cache. It is deliberately conditional:
# restarting CoreDNS on every deploy would be a cargo-cult step whose removal nobody could risk.
#
# Offline-testable: every external command is a variable, so scripts/tests/test-verify-public-dns.sh
# can drive the whole decision tree with fakes and no cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh
. scripts/lib/config.sh

HOST="${1:-${APP_DOMAIN:-}}"
[ -n "$HOST" ] || { echo "verify-public-dns: no hostname given and app_domain is not set in the tfvars" >&2; exit 2; }

NS="${PUBDNS_NAMESPACE:-devops-app}"
ATTEMPTS="${PUBDNS_ATTEMPTS:-3}"
SLEEP="${PUBDNS_SLEEP:-10}"

# Resolve FROM INSIDE the cluster. `kubectl exec` into a pod that already exists rather than
# `kubectl run`: a throwaway pod has to be scheduled, pull an image and satisfy this namespace's
# default-deny NetworkPolicy, any of which can fail for reasons that have nothing to do with DNS and
# would be reported as a DNS fault.
resolve_in_cluster() {
  if [ -n "${PUBDNS_RESOLVE_CMD:-}" ]; then eval "$PUBDNS_RESOLVE_CMD"; return; fi
  local pod
  pod="$(kubectl get pods -n "$NS" -l app=backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || { echo "verify-public-dns: no backend pod in $NS to resolve from" >&2; return 2; }
  kubectl exec -n "$NS" "$pod" -- python -c "
import socket,sys
try: print(socket.gethostbyname('$HOST'))
except Exception as e: print('FAIL: %s' % e, file=sys.stderr); sys.exit(1)
" 2>/dev/null
}

# Resolve from OUTSIDE, and specifically NOT through this machine's own stub resolver. That is the
# whole point: the operator's laptop is subject to the identical NODATA cache the cluster is stuck
# on, so `getent` answers "no such address" for exactly the same wrong reason -- and the script then
# reports "the record does not exist yet" about a record that plainly does, and refuses to act.
# Observed 2026-08-26: systemd-resolved held the negative while dig against 1.1.1.1 returned both
# ALB addresses from the same shell, seconds apart.
#
# So: ask the zone's AUTHORITATIVE nameserver, which has no cache to be wrong. The NS lookup that
# finds it is a positive query, so a poisoned local cache cannot break it. Falling back to a public
# recursive resolver and finally to getent keeps this working without dig, in descending order of
# how much it can be trusted.
resolve_publicly() {
  if [ -n "${PUBDNS_PUBLIC_RESOLVE_CMD:-}" ]; then ( eval "$PUBDNS_PUBLIC_RESOLVE_CMD" ); return; fi
  if command -v dig >/dev/null 2>&1; then
    local ns
    ns="$(dig +short NS "${HOST#*.}" 2>/dev/null | grep -m1 '\.$' || true)"
    [ -n "$ns" ] && dig +short A "$HOST" "@${ns}" 2>/dev/null | grep -qE '^[0-9]+\.' && return 0
    dig +short A "$HOST" @1.1.1.1 2>/dev/null | grep -qE '^[0-9]+\.' && return 0
    return 1
  fi
  getent ahostsv4 "$HOST" | awk 'NR==1{print $1}' | grep -q .
}

restart_coredns() {
  if [ -n "${PUBDNS_RESTART_CMD:-}" ]; then ( eval "$PUBDNS_RESTART_CMD" ); return; fi
  kubectl rollout restart deployment coredns -n kube-system
  kubectl rollout status  deployment coredns -n kube-system --timeout=120s
}

echo "==> Checking that the cluster can resolve $HOST"
if addr="$(resolve_in_cluster)" && [ -n "$addr" ]; then
  echo "    resolves to $addr from inside the cluster -- ok."
  exit 0
fi

echo "    the cluster CANNOT resolve $HOST."
if ! resolve_publicly; then
  echo "    ...and neither can a public resolver, so the record does not exist yet." >&2
  echo "    This is external-dns not having reconciled, not a cache fault. Not restarting CoreDNS." >&2
  exit 1
fi

echo "    but a public resolver CAN -- CoreDNS is serving a stale negative answer. Restarting it."
restart_coredns

for i in $(seq 1 "$ATTEMPTS"); do
  if addr="$(resolve_in_cluster)" && [ -n "$addr" ]; then
    echo "    resolves to $addr after the restart -- ok."
    exit 0
  fi
  echo "    attempt $i/$ATTEMPTS: still unresolved, waiting ${SLEEP}s"
  [ "$i" -lt "$ATTEMPTS" ] && sleep "$SLEEP"
done

# Reaching here is informative, not mysterious: CoreDNS came back with an EMPTY cache and is still
# being told NODATA, so the negative answer is held UPSTREAM of it -- the VPC resolver -- where
# nothing in this cluster can clear it. It expires on its own within the RFC 2308 bound (15 minutes
# for this zone, see the header), so the honest instruction is to wait and re-run, not to go
# debugging. Saying so matters: the previous wording described a permanent-sounding failure, and the
# natural next move was to start pulling the cluster apart during the ten minutes it needed.
echo "verify-public-dns: $HOST still does not resolve inside the cluster after restarting CoreDNS." >&2
echo "  CoreDNS restarted with an empty cache and is STILL getting NOERROR-with-no-A, so the negative" >&2
echo "  answer is cached UPSTREAM (the VPC resolver at the VPC base +2), which no restart here can" >&2
echo "  clear. RFC 2308 caps it at min(SOA record TTL, SOA MINIMUM) -- 900s for this zone -- so it" >&2
echo "  heals by itself. Wait a few minutes and re-run this script; check the remaining TTL with:" >&2
echo "    dig +noall +authority A $HOST @<vpc-resolver>   # from inside the VPC" >&2
echo "  Until it does, the canary makes no requests, so voteball:availability:ratio5m reports 1 from" >&2
echo "  its no-data fallback while measuring nothing. Visitors are unaffected -- the PUBLIC path is" >&2
echo "  fine, which is exactly why this is easy to misread. docs/runbooks/VoteballJourneyTrafficStopped.md" >&2
exit 1
