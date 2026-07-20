#!/usr/bin/env bash
# Remove the Route53 records external-dns created for this cluster, if it did not remove them itself.
#
# Why this exists: external-dns only reconciles on a timer, so a teardown can delete the Ingress and
# then destroy external-dns before it ever notices -- leaving voteball.latnook.com pointing at a
# de-provisioned ALB (observed 2026-07-20). destroy.sh runs this as a deterministic backstop.
#
#   ./scripts/cleanup-stale-dns.sh           # delete owned records (waits for external-dns first)
#   ./scripts/cleanup-stale-dns.sh --dry-run # show what would be deleted, change nothing
#
# SAFETY: only deletes records that external-dns registered as owned by THIS cluster. Ownership is
# proven by a sibling TXT record containing "external-dns/owner=<cluster>". Records without that
# marker -- the zone apex, MX, NS, SOA, ProtonMail verification/DKIM, _dmarc -- are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

REGION="il-central-1"
ZONE_NAME="latnook.com."
OWNER="voteball"
HOST="voteball.latnook.com."
WAIT_SECONDS="${CLEANUP_DNS_WAIT:-90}"
DRY_RUN=0

[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ZONE_ID="$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_NAME}'].Id | [0]" --output text | sed 's|/hostedzone/||')"

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "ERROR: hosted zone ${ZONE_NAME} not found." >&2
  exit 1
fi

records_json() {
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --output json
}

# Records are only eligible when an ownership TXT names this cluster. external-dns stores that marker
# in a sibling TXT whose name embeds the record type, e.g. cname-voteball.latnook.com for the A
# record. We require at least one such TXT before deleting anything.
owned_marker_present() {
  records_json | python3 -c "
import json, sys
d = json.load(sys.stdin)
owner = '$OWNER'
for r in d['ResourceRecordSets']:
    if r['Type'] != 'TXT':
        continue
    for v in r.get('ResourceRecords', []):
        if 'heritage=external-dns' in v['Value'] and f'external-dns/owner={owner}' in v['Value']:
            sys.exit(0)
sys.exit(1)
"
}

# Give external-dns a chance to do its own job first -- if it already cleaned up, we do nothing.
if [ "$DRY_RUN" = "0" ] && [ "$WAIT_SECONDS" -gt 0 ]; then
  echo "Waiting up to ${WAIT_SECONDS}s for external-dns to remove its own records..."
  waited=0
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    if ! owned_marker_present; then
      echo "external-dns already cleaned up its records. Nothing to do."
      exit 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  echo "Still present after ${WAIT_SECONDS}s — cleaning up directly."
fi

# Build the change batch: every record for our host, plus the ownership TXTs that reference it.
CHANGES="$(records_json | python3 -c "
import json, sys
d = json.load(sys.stdin)
owner, host = '$OWNER', '$HOST'
marker = f'external-dns/owner={owner}'

owned_txt = []
for r in d['ResourceRecordSets']:
    if r['Type'] == 'TXT' and any(
        'heritage=external-dns' in v['Value'] and marker in v['Value']
        for v in r.get('ResourceRecords', [])
    ):
        owned_txt.append(r)

# Only remove address records for the exact host external-dns manages, and only when at least one
# ownership TXT for this cluster exists (proving external-dns created them).
addr = [r for r in d['ResourceRecordSets']
        if r['Name'] == host and r['Type'] in ('A', 'AAAA')] if owned_txt else []

batch = [{'Action': 'DELETE', 'ResourceRecordSet': r} for r in owned_txt + addr]
print(json.dumps({'Changes': batch}))
")"

COUNT="$(printf '%s' "$CHANGES" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['Changes']))")"

if [ "$COUNT" = "0" ]; then
  echo "No external-dns-owned records for ${OWNER} found. Nothing to delete."
  exit 0
fi

echo "Records to delete (${COUNT}):"
printf '%s' "$CHANGES" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['Changes']:
    r = c['ResourceRecordSet']
    print(f\"  {r['Type']:5} {r['Name']}\")
"

if [ "$DRY_RUN" = "1" ]; then
  echo "(--dry-run: nothing was changed)"
  exit 0
fi

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "$CHANGES" >/dev/null

echo "Deleted ${COUNT} stale external-dns record(s) for ${OWNER}."
