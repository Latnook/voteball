"""Export a snapshot of the NATIONAL poll results to S3 once per genuine change.

Runs at the end of the worker's 30-second recompute loop (see worker.py). Its job is to keep an
external, timestamped record of the poll's headline numbers in S3 -- both as a real use of S3 for
the DevOps submission and as a lightweight results-over-time history.

Two design constraints shape everything here:

1. CHANGED-ONLY. The loop fires ~2,880 times/day, but real traffic is near-zero, so almost every
   cycle produces identical results. Writing every cycle would litter the bucket with duplicates.
   So we only write when the national totals actually differ from the last write.

2. WRITE-ONLY IAM. The worker's IRSA role is scoped to s3:PutObject only (no s3:GetObject) -- the
   tightest least-privilege posture, and a graded requirement. That means we CANNOT read latest.json
   back to decide whether anything changed. The "did it change?" check is therefore kept in memory:
   the caller threads a fingerprint string from one call to the next (see worker.py's loop).

NATIONAL totals (not the league/club-scoped rollups) are used on purpose: a single ballot can name
several teams across several leagues, so summing the league-scoped rollups would over-count a
multi-team voter. The rollup_national_* tables hold exactly one row's worth of counting per vote.
"""
import json
from datetime import datetime, timezone


def _national_payload(conn):
    """Read the three national rollup tables into a plain, JSON-serialisable dict.

    These tables are refreshed by rollups.recompute() earlier in the same worker iteration, so we
    just read whatever it left behind. Each query is ORDER BY'd so the output is deterministic --
    that determinism is what makes the fingerprint comparison in export_if_changed() reliable
    (two identical result sets always serialise to the exact same string).
    """
    cur = conn.cursor()

    # Headline: votes per "previous" (last-election) party.
    cur.execute(
        'SELECT previous_party_id, vote_count FROM rollup_national_previous '
        'ORDER BY previous_party_id NULLS LAST'
    )
    previous = [{'previous_party_id': p, 'vote_count': c} for p, c in cur.fetchall()]

    # Headline: votes per "upcoming" (next-election) party. A NULL party id row = "undecided".
    cur.execute(
        'SELECT upcoming_party_id, vote_count FROM rollup_national_upcoming '
        'ORDER BY upcoming_party_id NULLS LAST'
    )
    upcoming = [{'upcoming_party_id': p, 'vote_count': c} for p, c in cur.fetchall()]

    # Crosstab: how previous-party voters split across upcoming parties (the "vote switch" grid).
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id, vote_count FROM rollup_national_previous_upcoming '
        'ORDER BY previous_party_id NULLS LAST, upcoming_party_id NULLS LAST'
    )
    crosstab = [
        {'previous_party_id': pp, 'upcoming_party_id': up, 'vote_count': c}
        for pp, up, c in cur.fetchall()
    ]

    cur.close()
    return {'previous': previous, 'upcoming': upcoming, 'crosstab': crosstab}


def export_if_changed(conn, s3_client, bucket, prefix, last_fingerprint, now=None):
    """Write a national-totals snapshot to S3, but only when it differs from the last write.

    Args:
        conn: open psycopg2 connection (national rollup tables already recomputed this cycle).
        s3_client: anything with put_object(Bucket, Key, Body, ContentType) -- boto3's S3 client
            in production, FakeS3Client in tests.
        bucket: target S3 bucket name.
        prefix: key prefix, e.g. "snapshots" (the worker's IAM role is scoped to this prefix).
        last_fingerprint: the fingerprint returned by the PREVIOUS call, or None on the first call.
        now: injectable timestamp for tests; defaults to the current UTC time.

    Returns:
        The fingerprint of the CURRENT results -- pass it back in as last_fingerprint next call.
        If nothing changed, returns last_fingerprint unchanged and performs no S3 writes.
    """
    payload = _national_payload(conn)

    # The fingerprint intentionally EXCLUDES the timestamp: two runs with identical vote counts must
    # produce the same fingerprint, or every cycle would look "changed" (because the clock moved)
    # and we'd be right back to writing ~2,880 near-duplicate objects a day.
    fingerprint = json.dumps(payload, sort_keys=True)
    if fingerprint == last_fingerprint:
        return last_fingerprint  # no new votes since last write -> nothing to do

    # Something changed: build the object body (the payload plus the moment we captured it).
    ts = (now or datetime.now(timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ')
    body = json.dumps({'ts': ts, **payload}, sort_keys=True)

    # Write two objects:
    #   - a timestamped, immutable history entry (never overwritten), and
    #   - latest.json, overwritten each time so "current results" always lives at one known key.
    for key in (f'{prefix}/rollup-{ts}.json', f'{prefix}/latest.json'):
        s3_client.put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/json')

    return fingerprint
