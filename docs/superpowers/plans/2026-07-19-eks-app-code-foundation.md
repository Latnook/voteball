# EKS App-Code Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the k3s-compatible, TDD-able application-code changes the EKS migration needs — worker S3 rollup-snapshots, a worker heartbeat liveness signal, and a standalone `migrate.py` schema-bootstrap entrypoint — so the container images built in later phases are EKS-ready, while the live k3s site keeps working unchanged.

**Architecture:** All changes are *additive and inert on k3s*: the worker writes national-results snapshots to S3 only when an `S3_BUCKET` env var is set (unset on k3s ⇒ skipped); the heartbeat file is harmless; and `migrate.py` is a new entrypoint not yet wired to anything (the k3s image still bootstraps schema via gunicorn's `on_starting` hook). Each container's `files/` tree stays independently built — no shared module between backend and worker (deliberate; see CLAUDE.md).

**Tech Stack:** Python 3.12, Flask 3.1 + gunicorn (backend), plain Python loop (worker), `boto3` (SNS + new S3), `psycopg2`, `pytest` against a real Postgres 17 container.

## Global Constraints

*Every task's requirements implicitly include this section. Values copied verbatim from CLAUDE.md and the approved design.*

- **Region** `il-central-1`; **resource name prefix** `voteball`; single environment only.
- Backend/worker containers run **non-root, uid 1000**; frontend is out of scope for this plan.
- Postgres uses `sslmode=require` in prod (`DB_SSLMODE`); **tests override to `disable`** (already set in both `conftest.py` files via `setdefault`).
- **No `latest` image tags**, ever.
- **No shared Python package between backend and worker** — the worker keeps its own `db.py`; do not import across the two `files/` trees.
- **Base image tags stay floating** (`python:3.12-slim`, `nginx:alpine`) — a deliberate convenience-over-reproducibility choice (user decision 2026-07-19); do **not** digest-pin. This trade-off gets narrated in `docs/security.md` in a later plan.
- **Worker S3 write is env-gated**: if `S3_BUCKET` is unset, the worker performs **no** S3 calls (this is what keeps the change inert on live k3s).
- **Worker IRSA will be `s3:PutObject`-only** (no `GetObject`), so snapshot change-detection **must be kept in-memory** — never read an object back from S3 to dedup.
- **TDD against a real Postgres**, not mocks, for anything touching SQL (reuse the `voteball-test-db` container and the existing `conn` fixtures). Pure-logic/loop-plumbing may use fakes/`MagicMock`, matching `tests/test_alerts.py` / `tests/test_worker_loop.py`.
- **Commit and push to `master` as each task completes** (repo standing order, CLAUDE.md Workflow). Plain imperative commit messages, matching git log style (no `feat:`/`fix:` prefixes). Never force-push.
- **Do NOT redeploy the live k3s site** in this plan (user decision): land the code on `master`, stop, and hand to the user to verify before starting the next plan.

**Pre-flight (run once before Task 1):**
```bash
docker start voteball-test-db 2>/dev/null || \
  docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
```

---

### Task 1: Worker S3 snapshot module (`snapshots.py`)

Write national-results snapshots to S3, but only when the national rollup tables actually changed since the last write. Two keys per write: a timestamped history object and an overwritten `latest.json` pointer. Change-detection is an in-memory fingerprint (the worker's IRSA role cannot `GetObject`).

**Files:**
- Create: `ansible-project/roles/worker/files/worker/snapshots.py`
- Test: `ansible-project/roles/worker/files/worker/tests/test_snapshots.py`

**Interfaces:**
- Consumes: the `conn` fixture from `tests/conftest.py`; the national rollup tables (`rollup_national_previous`, `rollup_national_upcoming`, `rollup_national_previous_upcoming`) populated by `rollups.recompute(conn)`.
- Produces: `snapshots.export_if_changed(conn, s3_client, bucket, prefix, last_fingerprint, now=None) -> str` — writes 2 objects when changed (else nothing) and returns the current fingerprint (a stable string) to thread back into the next call. `s3_client` needs only a `put_object(Bucket, Key, Body, ContentType)` method (matches boto3's S3 client and the test's `FakeS3Client`).

- [ ] **Step 1: Write the failing test**

Create `ansible-project/roles/worker/files/worker/tests/test_snapshots.py`:

```python
import json

import rollups
import snapshots


class FakeS3Client:
    """Records put_object calls; mirrors the FakeSNSClient pattern in test_alerts.py.
    Deliberately implements only put_object -- the worker's IRSA role is PutObject-only,
    so a snapshot path that reached for get_object would be an IAM-mismatch bug."""

    def __init__(self):
        self.puts = []

    def put_object(self, Bucket, Key, Body, ContentType):
        self.puts.append({'Bucket': Bucket, 'Key': Key, 'Body': Body, 'ContentType': ContentType})


def _seed_one_vote(conn):
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
    _seed_one_vote(conn)
    rollups.recompute(conn)

    s3 = FakeS3Client()
    fp = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', None)

    assert fp is not None
    keys = sorted(p['Key'] for p in s3.puts)
    assert len(keys) == 2
    assert keys[0].startswith('snapshots/rollup-') and keys[0].endswith('.json')
    assert 'snapshots/latest.json' in keys

    # latest.json body carries the national totals + a ts
    latest = next(p for p in s3.puts if p['Key'] == 'snapshots/latest.json')
    body = json.loads(latest['Body'])
    assert body['previous'] == [{'previous_party_id': 1, 'vote_count': 1}]
    assert body['upcoming'] == [{'upcoming_party_id': 10, 'vote_count': 1}]
    assert 'ts' in body
    assert latest['ContentType'] == 'application/json'


def test_unchanged_export_writes_nothing(conn):
    _seed_one_vote(conn)
    rollups.recompute(conn)

    s3 = FakeS3Client()
    fp1 = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', None)
    fp2 = snapshots.export_if_changed(conn, s3, 'voteball-rollups', 'snapshots', fp1)

    assert fp2 == fp1
    assert len(s3.puts) == 2  # still only the first write's two objects


def test_new_votes_trigger_a_fresh_export(conn):
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ansible-project/roles/worker/files/worker && source .venv/bin/activate && python -m pytest tests/test_snapshots.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'snapshots'`.

- [ ] **Step 3: Write minimal implementation**

Create `ansible-project/roles/worker/files/worker/snapshots.py`:

```python
import json
from datetime import datetime, timezone


def _national_payload(conn):
    """Read the three national rollup tables into a JSON-serialisable dict.

    These are recomputed by rollups.recompute() earlier in the same worker iteration, so this
    reads them straight after. National (not league/club-scoped) totals are used because a
    multi-team ballot would be over-counted by the league-scoped rollups.
    """
    cur = conn.cursor()
    cur.execute(
        'SELECT previous_party_id, vote_count FROM rollup_national_previous '
        'ORDER BY previous_party_id NULLS LAST'
    )
    previous = [{'previous_party_id': p, 'vote_count': c} for p, c in cur.fetchall()]
    cur.execute(
        'SELECT upcoming_party_id, vote_count FROM rollup_national_upcoming '
        'ORDER BY upcoming_party_id NULLS LAST'
    )
    upcoming = [{'upcoming_party_id': p, 'vote_count': c} for p, c in cur.fetchall()]
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
    """Write a national-totals snapshot to S3 only when it differs from the last write.

    Returns the fingerprint of what is now current, to be threaded back in on the next call.
    The worker's IRSA role is PutObject-only (no GetObject), so 'changed since last write' is
    tracked purely in-memory via this fingerprint -- we cannot read latest.json back to compare.
    The timestamp is excluded from the fingerprint so an otherwise-identical result does not
    trigger a spurious write every cycle.
    """
    payload = _national_payload(conn)
    fingerprint = json.dumps(payload, sort_keys=True)
    if fingerprint == last_fingerprint:
        return last_fingerprint

    ts = (now or datetime.now(timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ')
    body = json.dumps({'ts': ts, **payload}, sort_keys=True)

    for key in (f'{prefix}/rollup-{ts}.json', f'{prefix}/latest.json'):
        s3_client.put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/json')
    return fingerprint
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ansible-project/roles/worker/files/worker && python -m pytest tests/test_snapshots.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/worker/files/worker/snapshots.py \
        ansible-project/roles/worker/files/worker/tests/test_snapshots.py
git commit -m "Add worker national-results S3 snapshot export (changed-only)"
git push
```

---

### Task 2: Worker heartbeat module (`heartbeat.py`)

A liveness signal for a batch loop that has no HTTP server. The worker touches a file every iteration; a chart-side `exec` probe (Plan 3) fails the pod when the file goes stale. Semantics: **alive if the loop spins** — the file is touched even after a caught DB error, so a database outage does not restart the worker (the existing catch-and-retry loop handles that); only a genuinely wedged process lets the file go stale.

**Files:**
- Create: `ansible-project/roles/worker/files/worker/heartbeat.py`
- Test: `ansible-project/roles/worker/files/worker/tests/test_heartbeat.py`

**Interfaces:**
- Produces: `heartbeat.DEFAULT_PATH` (str, `'/tmp/heartbeat'`) and `heartbeat.touch(path=DEFAULT_PATH) -> None` — creates the file if absent and updates its mtime. `/tmp` is the writable path the chart will back with an `emptyDir` under `readOnlyRootFilesystem: true`.

- [ ] **Step 1: Write the failing test**

Create `ansible-project/roles/worker/files/worker/tests/test_heartbeat.py`:

```python
import os

import heartbeat


def test_touch_creates_file(tmp_path):
    p = tmp_path / 'hb'
    assert not p.exists()
    heartbeat.touch(str(p))
    assert p.exists()


def test_touch_updates_mtime(tmp_path):
    p = tmp_path / 'hb'
    heartbeat.touch(str(p))
    os.utime(str(p), (0, 0))  # force mtime into the past
    heartbeat.touch(str(p))
    assert p.stat().st_mtime > 0


def test_default_path_is_tmp():
    assert heartbeat.DEFAULT_PATH == '/tmp/heartbeat'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ansible-project/roles/worker/files/worker && python -m pytest tests/test_heartbeat.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'heartbeat'`.

- [ ] **Step 3: Write minimal implementation**

Create `ansible-project/roles/worker/files/worker/heartbeat.py`:

```python
import os
import pathlib

# Written under /tmp so it stays writable when the container runs with readOnlyRootFilesystem: true
# (the chart mounts an emptyDir at /tmp). Overridable via env for tests / local runs.
DEFAULT_PATH = os.environ.get('HEARTBEAT_FILE', '/tmp/heartbeat')


def touch(path=DEFAULT_PATH):
    """Create the heartbeat file if missing and bump its mtime to 'now'."""
    pathlib.Path(path).touch()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ansible-project/roles/worker/files/worker && python -m pytest tests/test_heartbeat.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/worker/files/worker/heartbeat.py \
        ansible-project/roles/worker/files/worker/tests/test_heartbeat.py
git commit -m "Add worker heartbeat file module for liveness probe"
git push
```

---

### Task 3: Wire snapshots + heartbeat into `worker.py`; update loop tests + Dockerfile

Thread the S3 client and the snapshot fingerprint through `run_iteration`, gate the S3 client on `S3_BUCKET`, and touch the heartbeat every iteration in the main loop. Update the existing loop tests for the new `run_iteration` signature, and add the two new files to the worker Dockerfile's `COPY` line (a file on disk but missing from `COPY` 404s/`ImportError`s at runtime — see CLAUDE.md frontend note; the same rule applies to the worker).

**Files:**
- Modify: `ansible-project/roles/worker/files/worker/worker.py` (full rewrite below)
- Modify: `ansible-project/roles/worker/files/worker/tests/test_worker_loop.py`
- Modify: `ansible-project/roles/worker/files/worker/Dockerfile:8` (the `COPY` line)

**Interfaces:**
- Consumes: `snapshots.export_if_changed(...)` (Task 1), `heartbeat.touch()` (Task 2).
- Produces: `worker.run_iteration(sns, s3, snapshot_fingerprint) -> str` — new 3-arg signature (was 1-arg `run_iteration(sns)`); returns the updated fingerprint. `s3` may be `None` (S3 disabled), in which case the snapshot step is skipped.

- [ ] **Step 1: Update the failing tests**

Replace the body of `ansible-project/roles/worker/files/worker/tests/test_worker_loop.py` with (new signature; adds an S3-gating test):

```python
import os
import sys
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('SNS_TOPIC', 'arn:aws:sns:il-central-1:000000000000:test-topic')

import worker  # noqa: E402  (import after env setup, matches conftest.py pattern)


def test_run_iteration_success_closes_connection():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn) as mock_get_db, \
         patch('worker.rollups.recompute') as mock_recompute, \
         patch('worker.alerts.check_and_notify') as mock_notify:
        worker.run_iteration(MagicMock(), None, None)

    mock_get_db.assert_called_once()
    mock_recompute.assert_called_once_with(mock_conn)
    mock_notify.assert_called_once()
    mock_conn.close.assert_called_once()


def test_run_iteration_exports_snapshot_when_s3_present():
    mock_conn = MagicMock()
    fake_s3 = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute'), \
         patch('worker.alerts.check_and_notify'), \
         patch('worker.snapshots.export_if_changed', return_value='fp-new') as mock_export:
        result = worker.run_iteration(MagicMock(), fake_s3, 'fp-old')

    mock_export.assert_called_once()
    assert result == 'fp-new'


def test_run_iteration_skips_snapshot_when_s3_is_none():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute'), \
         patch('worker.alerts.check_and_notify'), \
         patch('worker.snapshots.export_if_changed') as mock_export:
        result = worker.run_iteration(MagicMock(), None, 'fp-old')

    mock_export.assert_not_called()
    assert result == 'fp-old'  # fingerprint passes through unchanged


def test_run_iteration_survives_recompute_failure_and_still_closes_connection():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute', side_effect=RuntimeError('connection reset')), \
         patch('worker.alerts.check_and_notify') as mock_notify:
        worker.run_iteration(MagicMock(), None, None)  # must not raise

    mock_conn.close.assert_called_once()
    mock_notify.assert_not_called()


def test_run_iteration_survives_alerts_failure_and_still_closes_connection():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute') as mock_recompute, \
         patch('worker.alerts.check_and_notify', side_effect=RuntimeError('sns unavailable')):
        worker.run_iteration(MagicMock(), None, None)

    mock_recompute.assert_called_once_with(mock_conn)
    mock_conn.close.assert_called_once()


def test_run_iteration_survives_connection_failure_with_no_connection_to_close():
    with patch('worker.db.get_db', side_effect=RuntimeError('could not connect to server')):
        worker.run_iteration(MagicMock(), None, None)  # must not raise
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ansible-project/roles/worker/files/worker && python -m pytest tests/test_worker_loop.py -v`
Expected: FAIL — `TypeError: run_iteration() takes 1 positional argument but 3 were given` (and the two new tests error on `worker.snapshots`).

- [ ] **Step 3: Rewrite `worker.py`**

Replace `ansible-project/roles/worker/files/worker/worker.py` entirely with:

```python
import os
import time

import boto3

import db
import rollups
import alerts
import snapshots
import heartbeat

SNS_TOPIC = os.environ['SNS_TOPIC']
AWS_REGION = os.environ.get('AWS_REGION', 'il-central-1')
# Optional: when unset, the worker performs no S3 calls at all (keeps this change inert on k3s).
S3_BUCKET = os.environ.get('S3_BUCKET')
S3_SNAPSHOT_PREFIX = os.environ.get('S3_SNAPSHOT_PREFIX', 'snapshots')


def run_iteration(sns, s3, snapshot_fingerprint):
    """Run one recompute/alert/snapshot cycle.

    Catches and logs any exception so a transient DB blip (failover, connection reset, etc.)
    doesn't crash the process -- Kubernetes would otherwise turn a brief hiccup into a
    crash-restart loop. Always closes the connection it opens, even on failure. Returns the
    (possibly updated) snapshot fingerprint to thread into the next call.
    """
    conn = None
    try:
        conn = db.get_db()
        rollups.recompute(conn)
        alerts.check_and_notify(conn, sns, SNS_TOPIC)
        if s3 is not None:
            snapshot_fingerprint = snapshots.export_if_changed(
                conn, s3, S3_BUCKET, S3_SNAPSHOT_PREFIX, snapshot_fingerprint
            )
        print('Rollups recomputed, milestones checked.')
    except Exception as e:
        print(f'Worker iteration failed, will retry next cycle: {e}')
    finally:
        if conn is not None:
            conn.close()
    return snapshot_fingerprint


if __name__ == '__main__':
    sns = boto3.client('sns', region_name=AWS_REGION)
    s3 = boto3.client('s3', region_name=AWS_REGION) if S3_BUCKET else None
    print('Voteball worker started...')
    snapshot_fingerprint = None
    while True:
        snapshot_fingerprint = run_iteration(sns, s3, snapshot_fingerprint)
        # Touch every iteration, even after a caught error: liveness == "loop is spinning", not
        # "DB is reachable". A DB outage must not restart the worker; a wedged process should.
        heartbeat.touch()
        time.sleep(30)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ansible-project/roles/worker/files/worker && python -m pytest tests/test_worker_loop.py -v`
Expected: PASS (6 passed).

- [ ] **Step 5: Add new files to the worker Dockerfile `COPY` line**

In `ansible-project/roles/worker/files/worker/Dockerfile`, change:

```dockerfile
COPY worker.py db.py rollups.py alerts.py .
```

to:

```dockerfile
COPY worker.py db.py rollups.py alerts.py snapshots.py heartbeat.py .
```

- [ ] **Step 6: Verify the worker image still builds**

Run: `cd ansible-project/roles/worker/files/worker && docker build -t voteball-worker:plancheck .`
Expected: build succeeds; final `COPY` includes `snapshots.py` and `heartbeat.py`.

- [ ] **Step 7: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/worker/files/worker/worker.py \
        ansible-project/roles/worker/files/worker/tests/test_worker_loop.py \
        ansible-project/roles/worker/files/worker/Dockerfile
git commit -m "Wire S3 snapshot export and heartbeat into the worker loop"
git push
```

---

### Task 4: Backend standalone `migrate.py` entrypoint

Give `init_db` a life outside app.py's `__main__` guard and gunicorn's `on_starting` hook, so a future EKS Helm `pre-install`/`pre-upgrade` **migration Job** (Plan 3) can run schema bootstrap **once per release** instead of every pod racing on startup. This is additive: k3s keeps bootstrapping via `on_starting` (which stays), so nothing changes on the live site. `init_db` is idempotent (`CREATE TABLE IF NOT EXISTS` + `ON CONFLICT DO NOTHING`), so `migrate.py` is safe to run against a fresh or an already-seeded DB.

**Files:**
- Create: `ansible-project/roles/backend/files/backend/migrate.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_migrate.py`
- Modify: `ansible-project/roles/backend/files/backend/Dockerfile:8` (the `COPY` line)

**Interfaces:**
- Consumes: `db.get_db()` and `db.init_db(conn)` (existing, `backend/db.py`).
- Produces: `migrate.main() -> None` — opens its own connection, runs `init_db`, closes it. Runnable as `python migrate.py` (this becomes the Job's command in Plan 3).

- [ ] **Step 1: Write the failing test**

Create `ansible-project/roles/backend/files/backend/tests/test_migrate.py`:

```python
import migrate


def test_migrate_main_bootstraps_seed_data(conn):
    # The `conn` fixture already dropped + re-created schema via init_db, proving the from-scratch
    # path. Running migrate.main() (which opens its own connection) must succeed idempotently and
    # leave the seeded reference data in place.
    migrate.main()

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM leagues')
    assert cur.fetchone()[0] > 0
    cur.close()


def test_migrate_main_is_idempotent(conn):
    # Two runs in a row must not raise (CREATE TABLE IF NOT EXISTS + ON CONFLICT DO NOTHING).
    migrate.main()
    migrate.main()

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] > 0
    cur.close()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ansible-project/roles/backend/files/backend && source .venv/bin/activate && python -m pytest tests/test_migrate.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'migrate'`.

- [ ] **Step 3: Write minimal implementation**

Create `ansible-project/roles/backend/files/backend/migrate.py`:

```python
"""Standalone schema-bootstrap entrypoint.

`init_db` also runs from app.py's __main__ guard (local dev) and gunicorn.conf.py's on_starting
hook (the k3s image). This module makes it runnable as its own process -- the command for the EKS
Helm pre-install/pre-upgrade migration Job (Plan 3), where running it once per release rather than
once per pod removes the multi-replica init_db race. It is idempotent, so re-running is safe.
"""
import db


def main():
    conn = db.get_db()
    try:
        db.init_db(conn)
        print('Schema and seed applied.')
    finally:
        conn.close()


if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ansible-project/roles/backend/files/backend && python -m pytest tests/test_migrate.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Add `migrate.py` to the backend Dockerfile `COPY` line**

In `ansible-project/roles/backend/files/backend/Dockerfile`, change:

```dockerfile
COPY app.py db.py queries.py gunicorn.conf.py schema.sql seed.sql .
```

to:

```dockerfile
COPY app.py db.py queries.py gunicorn.conf.py migrate.py schema.sql seed.sql .
```

- [ ] **Step 6: Verify the backend image still builds**

Run: `cd ansible-project/roles/backend/files/backend && docker build -t voteball-backend:plancheck .`
Expected: build succeeds; `migrate.py` present in the image.

- [ ] **Step 7: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/migrate.py \
        ansible-project/roles/backend/files/backend/tests/test_migrate.py \
        ansible-project/roles/backend/files/backend/Dockerfile
git commit -m "Add standalone migrate.py entrypoint for the EKS migration Job"
git push
```

---

### Task 5: readOnlyRootFilesystem audit doc + full-suite verification (STOP for user)

Capture, for Plan 3's chart securityContext work, exactly which writable paths each container needs under `readOnlyRootFilesystem: true` — discovered while writing this plan's code. Then run both full test suites as the completion gate and **stop for the user to verify before starting the next plan** (per the user's workflow decision).

**Files:**
- Create: `docs/eks/ro-fs-writable-paths.md`

- [ ] **Step 1: Write the audit note**

Create `docs/eks/ro-fs-writable-paths.md`:

```markdown
# readOnlyRootFilesystem: writable-path audit

Input for the EKS Helm chart (Plan 3). Under `securityContext.readOnlyRootFilesystem: true`,
each container needs an `emptyDir` mounted at every path it writes. Audited 2026-07-19.

| Container | Writable path needed | Why |
|---|---|---|
| backend  | `/tmp` | gunicorn's default `worker_tmp_dir` is `/tmp` (master↔worker heartbeat temp files). Mount an `emptyDir` at `/tmp`, or set `worker_tmp_dir = /dev/shm` in `gunicorn.conf.py`. |
| worker   | `/tmp` | heartbeat file `/tmp/heartbeat` (see `heartbeat.py`). Mount an `emptyDir` at `/tmp`. |
| frontend | (deferred) | Handled in the frontend base-image swap (`nginxinc/nginx-unprivileged`) in the infra/chart plan — not part of the app-code foundation plan. |

Note: base image tags stay floating (`python:3.12-slim`) by decision — the `.dockerignore` files
already exclude `tests/`, `__pycache__/`, `.venv/`, so no image-hygiene change was needed here.
```

- [ ] **Step 2: Run the FULL worker suite**

Run: `cd ansible-project/roles/worker/files/worker && python -m pytest tests/ -v`
Expected: PASS — all worker tests green (existing rollups/alerts/loop + new snapshots/heartbeat).

- [ ] **Step 3: Run the FULL backend suite**

Run: `cd ansible-project/roles/backend/files/backend && python -m pytest tests/ -v`
Expected: PASS — all backend tests green (existing + new migrate).

- [ ] **Step 4: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add docs/eks/ro-fs-writable-paths.md
git commit -m "Document readOnlyRootFilesystem writable paths for the EKS chart"
git push
```

- [ ] **Step 5: STOP — hand to the user for verification**

Do **not** proceed to the next plan or redeploy k3s. Report to the user:
- both full suites passing (paste the two summary lines),
- the four commits pushed to `master`,
- that the live k3s site was intentionally **not** redeployed (changes are inert without `S3_BUCKET`/the EKS Job),
- and ask them to verify before the next plan (EKS Terraform infra) begins.

---

## Self-Review

**1. Spec coverage** (against the approved design's Phase 0/1, app-code portions only):
- Worker S3 rollup snapshots → Task 1. ✅ (changed-only + national totals, per user decision)
- Worker heartbeat liveness → Task 2 + wired in Task 3. ✅ (alive-if-loop-spins, per user decision)
- `init_db` → standalone `migrate.py` for the Job → Task 4. ✅
- Dockerfile `COPY` updates for new files → Tasks 3 & 4. ✅
- `.dockerignore` review → covered (already adequate; noted in Task 5). ✅
- Base-image pinning → intentionally **out** (user chose floating tags); recorded in Global Constraints + Task 5 note. ✅
- RO-fs audit (feeds chart) → Task 5. ✅
- Frontend unprivileged nginx / TLS strip → **out of scope** (EKS-coupled, breaks k3s; belongs to the infra/chart plan). Documented in the plan Goal + Task 5 table. ✅
- ECR push / Trivy scan run → **out of scope** (needs the registry from the infra plan / CI from the observability plan); images are made build-clean here. ✅

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code and test block is complete. ✅

**3. Type consistency:** `export_if_changed(conn, s3_client, bucket, prefix, last_fingerprint, now=None)` is defined in Task 1 and called with the same shape in Task 3's `worker.py`. `run_iteration(sns, s3, snapshot_fingerprint)` is defined in Task 3 and matched by every call in the rewritten `tests/test_worker_loop.py`. `heartbeat.touch()` / `heartbeat.DEFAULT_PATH` defined Task 2, used Task 3. `migrate.main()` defined Task 4, called in its test. ✅
