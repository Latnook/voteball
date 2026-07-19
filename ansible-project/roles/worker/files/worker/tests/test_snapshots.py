import json

import rollups
import snapshots


class FakeS3Client:
    """Records put_object calls instead of hitting AWS -- mirrors the FakeSNSClient pattern in
    test_alerts.py, so the whole worker test suite fakes AWS the same way.

    It deliberately implements ONLY put_object. The worker's IRSA role is PutObject-only (no
    GetObject), so if the snapshot code ever reached for get_object, that would be an IAM-mismatch
    bug -- and this fake would surface it immediately with an AttributeError rather than silently
    'working' in tests and failing in production.
    """

    def __init__(self):
        self.puts = []

    def put_object(self, Bucket, Key, Body, ContentType):
        self.puts.append({'Bucket': Bucket, 'Key': Key, 'Body': Body, 'ContentType': ContentType})


def _seed_one_vote(conn):
    """Insert the minimum needed for the national rollup tables to be non-empty after recompute():
    one previous party, one upcoming party, and one vote that references both."""
    cur = conn.cursor()
    cur.execute("INSERT INTO previous_parties (id, name) VALUES (1, 'A') ON CONFLICT DO NOTHING")
    cur.execute("INSERT INTO upcoming_parties (id, name) VALUES (10, 'X') ON CONFLICT DO NOTHING")
    cur.execute(
        """INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', 1, 'considering', %s) RETURNING id""",
        ('snap-token-1',),
    )
    vote_id = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, 10)', (vote_id,))
    conn.commit()
    cur.close()


def test_first_export_writes_history_and_latest(conn):
    # First-ever export (last_fingerprint=None) must write both the timestamped history object
    # and the overwritten latest.json pointer.
    _seed_one_vote(conn)
    rollups.recompute(conn)

    s3 = FakeS3Client()
    fp = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', None)

    assert fp is not None
    keys = [p['Key'] for p in s3.puts]
    assert len(keys) == 2
    # One immutable timestamped history object + one overwritten latest.json pointer.
    assert any(k.startswith('snapshots/rollup-') and k.endswith('.json') for k in keys)
    assert 'snapshots/latest.json' in keys

    # latest.json body carries the national totals + a ts field.
    latest = next(p for p in s3.puts if p['Key'] == 'snapshots/latest.json')
    body = json.loads(latest['Body'])
    assert body['previous'] == [{'previous_party_id': 1, 'vote_count': 1}]
    assert body['upcoming'] == [{'upcoming_party_id': 10, 'vote_count': 1}]
    assert 'ts' in body
    assert latest['ContentType'] == 'application/json'


def test_unchanged_export_writes_nothing(conn):
    # Second call with identical results must be a no-op -- this is the whole point of the
    # changed-only design (the 30s loop would otherwise write ~2,880 duplicate objects/day).
    _seed_one_vote(conn)
    rollups.recompute(conn)

    s3 = FakeS3Client()
    fp1 = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', None)
    fp2 = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', fp1)

    assert fp2 == fp1
    assert len(s3.puts) == 2  # still only the first write's two objects


def test_new_votes_trigger_a_fresh_export(conn):
    # A genuine change (new vote -> different national totals) must produce a new pair of writes.
    _seed_one_vote(conn)
    rollups.recompute(conn)
    s3 = FakeS3Client()
    fp1 = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', None)

    cur = conn.cursor()
    cur.execute(
        """INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', 1, 'undecided', %s)""",
        ('snap-token-2',),
    )
    conn.commit()
    cur.close()
    rollups.recompute(conn)

    fp2 = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', fp1)
    assert fp2 != fp1
    assert len(s3.puts) == 4  # two more objects
