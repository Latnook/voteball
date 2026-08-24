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
#      record". That is a NEGATIVE answer cached against the zone's SOA minimum TTL, which for
#      latnook.com is 86400 -- twenty-four hours.
#   4. CoreDNS serves that cached NODATA long after the record appears. Measured: still empty 15
#      minutes later, while a direct query to the VPC resolver returned both ALB addresses.
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

# Resolve from OUTSIDE. This is what separates "the record does not exist yet" (wait for
# external-dns; not this script's problem) from "the record exists and only the cluster cannot see
# it" (a stale negative cache; exactly this script's problem).
resolve_publicly() {
  if [ -n "${PUBDNS_PUBLIC_RESOLVE_CMD:-}" ]; then ( eval "$PUBDNS_PUBLIC_RESOLVE_CMD" ); return; fi
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

echo "verify-public-dns: $HOST still does not resolve inside the cluster after restarting CoreDNS." >&2
echo "  The canary cannot reach the public site, so voteball:availability:ratio5m will report 1 from" >&2
echo "  its no-data fallback while measuring nothing. See docs/runbooks/VoteballJourneyTrafficStopped.md" >&2
exit 1
