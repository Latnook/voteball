# Party Display Names & Manual Party Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Knesset OData sync with manually seeded/admin-managed party lists using short, common Hebrew names, and give `previous_parties` the same admin create/rename/delete capability `upcoming_parties` already has.

**Architecture:** No new services or tables. Three surgical changes to the existing Flask backend: (1) delete the sync code path and its now-dead `knesset_faction_id` column, (2) add three admin routes + query functions for `previous_parties` mirroring the existing `upcoming_parties` ones — and bring both tables' CRUD up to CLAUDE.md's connection-safety standard in the same task, since they must stay identical in shape, (3) populate both party tables via `seed.sql` the same way `leagues`/`clubs` already are.

**Tech Stack:** Flask 3.1, psycopg2, pytest, real Postgres 17 (no mocks) — all per existing backend conventions.

## Global Constraints

- Backend tests run TDD-style against a real Postgres container, not mocks (`docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17`), per `CLAUDE.md`.
- `tests/conftest.py`'s `conn` fixture drops and recreates every table (via `schema.sql`) then re-loads `seed.sql` before each test — keep its `DROP TABLE ... CASCADE` list in sync with `schema.sql` if table names change (they don't in this plan — only a column changes).
- Every admin route must use the existing `require_admin` decorator in `app.py` — never hand-roll the `X-Admin-Secret` check.
- Every backend route must guarantee `conn.close()` on all exit paths via `try/finally`, matching the existing shape in `results()`/`vote()`.
- `queries.py` functions that mutate data must `conn.rollback()` in a broad `except` before re-raising (see `insert_vote`'s established pattern). Task 2 brings both the new `previous_parties` functions/routes and the existing `upcoming_parties` ones up to this standard together, in the same task — the two tables' admin CRUD must stay identical in shape, and this is the point where that shape gets fixed for both at once rather than only for the new code.
- Seed data language: Hebrew, short/common party names only — no separate full-legal-name column (per spec decision).

---

## Task 1: Remove the Knesset sync path

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/schema.sql`
- Delete: `ansible-project/roles/backend/files/backend/knesset_sync.py`
- Delete: `ansible-project/roles/backend/files/backend/tests/test_knesset_sync.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_app.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_queries.py`
- Modify: `ansible-project/roles/backend/files/backend/requirements.txt`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: `previous_parties` table with columns `id, name, updated_at` only (no `knesset_faction_id`). This is what Task 2's `create_previous_party`/`rename_previous_party`/`delete_previous_party` and Task 3's seed INSERTs target.

- [ ] **Step 1: Confirm the current test suite passes (baseline)**

Requires a running test Postgres container (start one if not already running):

```bash
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd ansible-project/roles/backend/files/backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest tests/ -v
```

Expected: all tests pass (this is the pre-change baseline; note the total count for comparison after Step 8).

- [ ] **Step 2: Drop the `knesset_faction_id` column from `previous_parties`**

In `ansible-project/roles/backend/files/backend/schema.sql`, change:

```sql
CREATE TABLE IF NOT EXISTS previous_parties (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    knesset_faction_id TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

to:

```sql
CREATE TABLE IF NOT EXISTS previous_parties (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

- [ ] **Step 3: Delete the sync module and its tests**

```bash
git rm ansible-project/roles/backend/files/backend/knesset_sync.py
git rm ansible-project/roles/backend/files/backend/tests/test_knesset_sync.py
```

- [ ] **Step 4: Remove the sync route and import from `app.py`**

In `ansible-project/roles/backend/files/backend/app.py`, remove the import (line 7):

```python
import knesset_sync
```

and remove the entire route (originally lines 98–105):

```python
@app.route('/api/admin/sync-previous-parties', methods=['POST'])
@require_admin
def sync_previous_parties():
    factions = knesset_sync.fetch_current_factions()
    conn = db.get_db()
    count = queries.upsert_previous_parties(conn, factions)
    conn.close()
    return jsonify({'synced': count})
```

- [ ] **Step 5: Remove `upsert_previous_parties` from `queries.py`**

In `ansible-project/roles/backend/files/backend/queries.py`, remove:

```python
def upsert_previous_parties(conn, factions):
    cur = conn.cursor()
    count = 0
    for faction in factions:
        cur.execute(
            '''INSERT INTO previous_parties (name, knesset_faction_id, updated_at)
               VALUES (%s, %s, NOW())
               ON CONFLICT (name) DO UPDATE SET
                   knesset_faction_id = EXCLUDED.knesset_faction_id,
                   updated_at = NOW()''',
            (faction['name'], faction['knesset_faction_id'])
        )
        count += 1
    conn.commit()
    cur.close()
    return count
```

- [ ] **Step 6: Remove sync-related tests from `test_app.py` and `test_queries.py`**

In `ansible-project/roles/backend/files/backend/tests/test_app.py`, remove:

```python
def test_sync_previous_parties_requires_admin_secret(client):
    resp = client.post('/api/admin/sync-previous-parties')
    assert resp.status_code == 401


def test_sync_previous_parties_with_valid_secret(client, monkeypatch):
    import knesset_sync

    def fake_fetch():
        return [{'knesset_faction_id': '1096', 'name': 'Likud'}]

    monkeypatch.setattr(knesset_sync, 'fetch_current_factions', fake_fetch)

    resp = client.post('/api/admin/sync-previous-parties', headers={'X-Admin-Secret': 'test-admin-secret'})
    assert resp.status_code == 200
    assert resp.get_json() == {'synced': 1}
```

In `ansible-project/roles/backend/files/backend/tests/test_queries.py`, remove:

```python
def test_upsert_previous_parties_inserts_and_updates(conn):
    import queries
    n = queries.upsert_previous_parties(conn, [
        {'knesset_faction_id': '1096', 'name': 'Likud'},
        {'knesset_faction_id': '1101', 'name': 'Torah Judaism'},
    ])
    assert n == 2

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 2
    cur.close()

    # Re-sync with an updated faction id for the same name — should update, not duplicate
    queries.upsert_previous_parties(conn, [
        {'knesset_faction_id': '9999', 'name': 'Likud'},
    ])
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 2
    cur.execute("SELECT knesset_faction_id FROM previous_parties WHERE name = 'Likud'")
    assert cur.fetchone()[0] == '9999'
    cur.close()
```

- [ ] **Step 7: Remove the `requests` dependency**

In `ansible-project/roles/backend/files/backend/requirements.txt`, remove the line:

```
requests==2.32.3
```

(Confirmed by grep during design that `requests` had no other consumer in the backend.)

- [ ] **Step 8: Run the test suite and confirm it passes with the expected reduced count**

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/ -v
```

Expected: PASS, with 5 fewer tests than the Step 1 baseline (2 removed from `test_app.py`, 1 from `test_queries.py`, 2 from the deleted `test_knesset_sync.py`).

- [ ] **Step 9: Update `CLAUDE.md`**

In the `## Architecture` section, change:

```markdown
- **backend** (`ansible-project/roles/backend/files/backend/`) — Flask 3.1 app. `app.py` holds all
  routes; `queries.py` holds all SQL; `db.py` holds only connection setup (`get_db`) and one-time
  schema bootstrap (`init_db`, which loads `schema.sql` then `seed.sql` — the backend is the only
  container that ever creates schema). `knesset_sync.py` is a pure-parsing + HTTP-fetch module for
  syncing `previous_parties` from the Knesset OData API.
```

to:

```markdown
- **backend** (`ansible-project/roles/backend/files/backend/`) — Flask 3.1 app. `app.py` holds all
  routes; `queries.py` holds all SQL; `db.py` holds only connection setup (`get_db`) and one-time
  schema bootstrap (`init_db`, which loads `schema.sql` then `seed.sql` — the backend is the only
  container that ever creates schema).
```

and further down in the same section, change:

```markdown
Postgres (RDS) stores: static seed data (`leagues`, `clubs`), synced party lists (`previous_parties`,
`upcoming_parties`), raw votes (`votes`, `vote_upcoming_parties`), and worker-computed rollup tables
(`rollup_previous`, `rollup_upcoming`) that the backend reads for fast `/api/results` responses.
```

to:

```markdown
Postgres (RDS) stores: static seed data (`leagues`, `clubs`, `previous_parties`, `upcoming_parties` —
the two party tables are also admin-editable after seeding), raw votes (`votes`,
`vote_upcoming_parties`), and worker-computed rollup tables (`rollup_previous`, `rollup_upcoming`) that
the backend reads for fast `/api/results` responses.
```

In the `### API surface` table, remove the row:

```markdown
| `/api/admin/sync-previous-parties` | POST | `X-Admin-Secret` | pulls current Knesset factions, upserts `previous_parties` |
```

(Leave the new `previous-parties` admin rows to be added by Task 2 — don't add them here.)

- [ ] **Step 10: Commit**

```bash
git add ansible-project/roles/backend/files/backend/schema.sql \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/requirements.txt \
        ansible-project/roles/backend/files/backend/tests/test_app.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py \
        CLAUDE.md
git commit -m "Remove Knesset sync; previous_parties will be manually managed"
git push
```

---

## Task 2: Add previous-parties admin CRUD, and bring both party tables' CRUD up to the connection-safety standard

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_queries.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_app.py`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `previous_parties(id, name, updated_at)` schema from Task 1.
- Produces: `queries.create_previous_party(conn, name) -> int`, `queries.rename_previous_party(conn, party_id, new_name) -> bool`, `queries.delete_previous_party(conn, party_id) -> bool` — same signatures/return types as the existing `create_upcoming_party`/`rename_upcoming_party`/`delete_upcoming_party`, but now all six functions (three new `previous_parties` ones, three existing `upcoming_parties` ones) share one internal shape: `try: ... conn.commit(); return X; except Exception: conn.rollback(); raise; finally: cur.close()`. Routes `POST /api/admin/previous-parties`, `PATCH /api/admin/previous-parties/<id>`, `DELETE /api/admin/previous-parties/<id>` plus the existing three `/api/admin/upcoming-parties...` routes all wrap their `queries.*` call in `try: ... finally: conn.close()`.

- [ ] **Step 1: Write failing tests — new previous-parties CRUD, plus rollback proofs for both tables**

Add to `ansible-project/roles/backend/files/backend/tests/test_queries.py`:

```python
def test_create_rename_delete_previous_party(conn):
    import queries

    party_id = queries.create_previous_party(conn, 'New Party')
    assert party_id > 0

    assert queries.rename_previous_party(conn, party_id, 'Renamed Party') is True
    cur = conn.cursor()
    cur.execute('SELECT name FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 'Renamed Party'
    cur.close()

    assert queries.delete_previous_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_previous_party(conn, 999999, 'Nope') is False
    assert queries.delete_previous_party(conn, 999999) is False


def test_create_previous_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Dup Previous Party')

    with pytest.raises(Exception):
        queries.create_previous_party(conn, 'Dup Previous Party')

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_previous_party(conn, 'Another Previous Party')
    assert party_id > 0


def test_create_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Dup Upcoming Party')

    with pytest.raises(Exception):
        queries.create_upcoming_party(conn, 'Dup Upcoming Party')

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_upcoming_party(conn, 'Another Upcoming Party')
    assert party_id > 0
```

(`pytest` is already imported at the top of `test_queries.py`.) The third test targets the *existing* `create_upcoming_party` — it fails against today's implementation (no rollback leaves the connection's transaction aborted), which is the point: it proves the Step 4 retrofit is necessary and correct.

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/test_queries.py::test_create_rename_delete_previous_party tests/test_queries.py::test_create_previous_party_duplicate_name_rolls_back_and_conn_still_usable tests/test_queries.py::test_create_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable -v
```

Expected: FAIL — the first two with `AttributeError: module 'queries' has no attribute 'create_previous_party'`; the third with a psycopg2 `InFailedSqlTransaction` (or similar) error from the second `create_upcoming_party` call, proving the current implementation doesn't roll back.

- [ ] **Step 3: Implement the three `previous_parties` query functions with rollback**

Add to `ansible-project/roles/backend/files/backend/queries.py` (immediately after `delete_upcoming_party`, before `get_votes`):

```python
def create_previous_party(conn, name):
    cur = conn.cursor()
    try:
        cur.execute('INSERT INTO previous_parties (name) VALUES (%s) RETURNING id', (name,))
        party_id = cur.fetchone()[0]
        conn.commit()
        return party_id
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_previous_party(conn, party_id, new_name):
    cur = conn.cursor()
    try:
        cur.execute('UPDATE previous_parties SET name = %s, updated_at = NOW() WHERE id = %s', (new_name, party_id))
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_previous_party(conn, party_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM previous_parties WHERE id = %s', (party_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

- [ ] **Step 4: Retrofit the three existing `upcoming_parties` query functions to the same shape**

In `ansible-project/roles/backend/files/backend/queries.py`, replace:

```python
def create_upcoming_party(conn, name):
    cur = conn.cursor()
    cur.execute('INSERT INTO upcoming_parties (name) VALUES (%s) RETURNING id', (name,))
    party_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    return party_id


def rename_upcoming_party(conn, party_id, new_name):
    cur = conn.cursor()
    cur.execute('UPDATE upcoming_parties SET name = %s, updated_at = NOW() WHERE id = %s', (new_name, party_id))
    updated = cur.rowcount > 0
    conn.commit()
    cur.close()
    return updated


def delete_upcoming_party(conn, party_id):
    cur = conn.cursor()
    cur.execute('DELETE FROM upcoming_parties WHERE id = %s', (party_id,))
    deleted = cur.rowcount > 0
    conn.commit()
    cur.close()
    return deleted
```

with:

```python
def create_upcoming_party(conn, name):
    cur = conn.cursor()
    try:
        cur.execute('INSERT INTO upcoming_parties (name) VALUES (%s) RETURNING id', (name,))
        party_id = cur.fetchone()[0]
        conn.commit()
        return party_id
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_upcoming_party(conn, party_id, new_name):
    cur = conn.cursor()
    try:
        cur.execute('UPDATE upcoming_parties SET name = %s, updated_at = NOW() WHERE id = %s', (new_name, party_id))
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_upcoming_party(conn, party_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM upcoming_parties WHERE id = %s', (party_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

- [ ] **Step 5: Run it to verify it passes**

```bash
python -m pytest tests/test_queries.py -v
```

Expected: all pass, including the three new tests from Step 1.

- [ ] **Step 6: Write failing tests for the three new admin routes**

Add to `ansible-project/roles/backend/files/backend/tests/test_app.py`:

```python
def test_previous_party_admin_crud(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}

    resp = client.post('/api/admin/previous-parties', json={'name': 'Test Party'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_id}', json={'name': 'Renamed'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 404


def test_previous_party_admin_routes_require_admin_secret(client):
    resp = client.post('/api/admin/previous-parties', json={'name': 'X'})
    assert resp.status_code == 401

    resp = client.patch('/api/admin/previous-parties/1', json={'name': 'X'})
    assert resp.status_code == 401

    resp = client.delete('/api/admin/previous-parties/1')
    assert resp.status_code == 401
```

- [ ] **Step 7: Run it to verify it fails**

```bash
python -m pytest tests/test_app.py::test_previous_party_admin_crud tests/test_app.py::test_previous_party_admin_routes_require_admin_secret -v
```

Expected: FAIL with 404 (no such route) on the `POST /api/admin/previous-parties` calls.

- [ ] **Step 8: Implement the three `previous-parties` admin routes with `try/finally`**

Add to `ansible-project/roles/backend/files/backend/app.py`, immediately after the existing `delete_upcoming_party_route` function and before the `/api/admin/votes` route:

```python
@app.route('/api/admin/previous-parties', methods=['POST'])
@require_admin
def create_previous_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_previous_party(conn, name)
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name': name}), 201


@app.route('/api/admin/previous-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_previous_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_previous_party(conn, party_id, name)
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name': name})


@app.route('/api/admin/previous-parties/<int:party_id>', methods=['DELETE'])
@require_admin
def delete_previous_party_route(party_id):
    conn = db.get_db()
    try:
        deleted = queries.delete_previous_party(conn, party_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204
```

- [ ] **Step 9: Retrofit the three existing `upcoming-parties` admin routes to the same `try/finally` shape**

In `ansible-project/roles/backend/files/backend/app.py`, replace:

```python
@app.route('/api/admin/upcoming-parties', methods=['POST'])
@require_admin
def create_upcoming_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    party_id = queries.create_upcoming_party(conn, name)
    conn.close()
    return jsonify({'id': party_id, 'name': name}), 201


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_upcoming_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    updated = queries.rename_upcoming_party(conn, party_id, name)
    conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name': name})


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['DELETE'])
@require_admin
def delete_upcoming_party_route(party_id):
    conn = db.get_db()
    deleted = queries.delete_upcoming_party(conn, party_id)
    conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204
```

with:

```python
@app.route('/api/admin/upcoming-parties', methods=['POST'])
@require_admin
def create_upcoming_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_upcoming_party(conn, name)
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name': name}), 201


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_upcoming_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_upcoming_party(conn, party_id, name)
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name': name})


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['DELETE'])
@require_admin
def delete_upcoming_party_route(party_id):
    conn = db.get_db()
    try:
        deleted = queries.delete_upcoming_party(conn, party_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204
```

- [ ] **Step 10: Run it to verify it passes, then run the full suite**

```bash
python -m pytest tests/test_app.py::test_previous_party_admin_crud tests/test_app.py::test_previous_party_admin_routes_require_admin_secret -v
python -m pytest tests/ -v
```

Expected: both targeted tests PASS; full suite passes.

- [ ] **Step 11: Update `CLAUDE.md`'s API surface table**

In `CLAUDE.md`, in the `### API surface` table, add these two rows immediately before the `/api/admin/upcoming-parties` row:

```markdown
| `/api/admin/previous-parties` | POST | `X-Admin-Secret` | create |
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | `X-Admin-Secret` | rename/remove |
```

- [ ] **Step 12: Commit**

```bash
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py \
        ansible-project/roles/backend/files/backend/tests/test_app.py \
        CLAUDE.md
git commit -m "Add previous-parties admin CRUD; bring both party tables' CRUD to the rollback/try-finally standard"
git push
```

---

## Task 3: Seed manual party data

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/seed.sql`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: `previous_parties`/`upcoming_parties` tables and admin CRUD from Tasks 1–2 (not required for this task's INSERTs, but this task exercises the final data shape those tasks built).
- Produces: 14 seeded `previous_parties` rows, 13 seeded `upcoming_parties` rows, present in every fresh `init_db()` call (including every test's `conn` fixture) from this point on.

- [ ] **Step 1: Update the failing assertion first**

In `ansible-project/roles/backend/files/backend/tests/test_queries.py`, change `test_get_options_returns_seeded_leagues`'s final two lines from:

```python
    assert options['previous_parties'] == []
    assert options['upcoming_parties'] == []
```

to:

```python
    previous_names = {p['name'] for p in options['previous_parties']}
    assert previous_names == {
        'הליכוד', 'יש עתיד', 'הציונות הדתית', 'המחנה הממלכתי', 'ישראל ביתנו',
        'ש"ס', 'יהדות התורה', 'רע"ם', 'חד"ש-תע"ל', 'העבודה', 'מרצ', 'בל"ד',
        'הבית היהודי', 'אחר',
    }

    upcoming_names = {p['name'] for p in options['upcoming_parties']}
    assert upcoming_names == {
        'הליכוד', 'ישר', 'ביחד', 'הדמוקרטים', 'כחול לבן', 'ישראל ביתנו',
        'הציונות הדתית', 'עוצמה יהודית', 'חד"ש-תע"ל', 'בל"ד',
        'המפלגה הכלכלית', 'אל הדגל', 'המילואימניקים',
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/test_queries.py::test_get_options_returns_seeded_leagues -v
```

Expected: FAIL — `previous_names`/`upcoming_names` are empty sets, not matching the expected sets.

- [ ] **Step 3: Add the seed data**

Append to the end of `ansible-project/roles/backend/files/backend/seed.sql`:

```sql
INSERT INTO previous_parties (name) VALUES
    ('הליכוד'), ('יש עתיד'), ('הציונות הדתית'), ('המחנה הממלכתי'),
    ('ישראל ביתנו'), ('ש"ס'), ('יהדות התורה'), ('רע"ם'),
    ('חד"ש-תע"ל'), ('העבודה'), ('מרצ'), ('בל"ד'), ('הבית היהודי'), ('אחר')
ON CONFLICT (name) DO NOTHING;

INSERT INTO upcoming_parties (name) VALUES
    ('הליכוד'), ('ישר'), ('ביחד'), ('הדמוקרטים'), ('כחול לבן'),
    ('ישראל ביתנו'), ('הציונות הדתית'), ('עוצמה יהודית'), ('חד"ש-תע"ל'),
    ('בל"ד'), ('המפלגה הכלכלית'), ('אל הדגל'), ('המילואימניקים')
ON CONFLICT (name) DO NOTHING;
```

- [ ] **Step 4: Run it to verify it passes**

```bash
python -m pytest tests/test_queries.py::test_get_options_returns_seeded_leagues -v
```

Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
python -m pytest tests/ -v
```

Expected: all pass. (Tests that insert ad-hoc parties like `'Test Party'`, `'Party A'`, `'New Party'` etc. are unaffected — none of those names collide with the Hebrew seed names, so the `UNIQUE (name)` constraint on each table isn't triggered.)

- [ ] **Step 6: Commit**

```bash
git add ansible-project/roles/backend/files/backend/seed.sql \
        ansible-project/roles/backend/files/backend/tests/test_queries.py
git commit -m "Seed previous_parties/upcoming_parties with manual short-name party lists"
git push
```

---

## Final verification

After all three tasks:

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/ -v
```

Expected: full suite passes. Spot-check with a live server if desired:

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable ADMIN_SECRET=test-admin-secret \
  SNS_TOPIC=arn:aws:sns:il-central-1:000000000000:test AWS_REGION=il-central-1 \
  python app.py &
curl -s localhost:5000/api/options | python -m json.tool
```

Expected: `previous_parties` (14 rows) and `upcoming_parties` (13 rows) with the Hebrew names from Task 3, no `knesset_faction_id` anywhere in the response.
