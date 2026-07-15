# Clubs & Leagues Admin CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the admin UI full CRUD (create/rename/delete/reassign) over `leagues` and `clubs`, let one club be votable under two leagues at once (its continental competition and its domestic league) via a new `domestic_league_id` column, deduplicate the real UCL/domestic-league duplicate rows this creates today, and add one-click UEFA Champions League roster toggle buttons.

**Architecture:** Backend follows the existing `previous_parties`/`upcoming_parties` admin-CRUD pattern in `app.py`/`queries.py` line-for-line — new routes under `/api/admin/leagues` and `/api/admin/clubs`, each backed by query functions using the same `try/except UniqueViolation / except Exception: rollback / finally: cur.close()` shape. Frontend adds a "Teams" tab to `admin.html`/`admin.js` mirroring the existing party tabs' render/add/rename/delete/reassign flow, plus a schema migration and one seed-data rewrite.

**Tech Stack:** Flask 3.1, psycopg2, plain HTML/CSS/vanilla JS (no build step), pytest against a real Postgres 17 (Docker), Postgres for all persistence.

## Global Constraints

- Every route acquires its own `psycopg2` connection via `db.get_db()` and guarantees `conn.close()` via `try/finally` on every exit path.
- Every mutating `queries.py` function rolls back in a broad `except Exception` before re-raising (not just the one expected constraint error), except where a specific exception (`UniqueViolation`) is caught first to convert to a typed error.
- Admin routes are protected by the existing `require_admin` decorator (`app.py`) — reuse it, never hand-roll.
- Frontend renders all names via `createElement`/`textContent`, never `innerHTML` string interpolation.
- Backend tests run TDD-style against a real Postgres (`docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17`), via `python -m pytest tests/ -v` from `ansible-project/roles/backend/files/backend/`.
- No automated frontend test suite exists (matches the S3App precedent) — frontend tasks are verified by driving the real page in a browser, not by writing JS tests.
- Commit and push after each task completes (this repo's standing instruction — don't batch).
- Full design rationale for every decision below lives in `docs/superpowers/specs/2026-07-15-clubs-leagues-admin-crud-design.md` — this plan implements it; consult it if a step's "why" isn't obvious from the code alone.

---

## Task 1: Schema migration + seed-data dedup (must land together)

**Why atomic:** `db.py`'s `init_db(conn)` runs `schema.sql` then `seed.sql` unconditionally, every time the backend starts and in every test's `conn` fixture (`tests/conftest.py`). If the new global club-name unique index is added without simultaneously removing seed.sql's duplicate rows (e.g. two `'Arsenal'` inserts, one under UCL and one under EPL), `seed.sql` itself violates the new constraint and **every test in the suite breaks**, not just new ones. This task must leave the suite green start to finish.

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/schema.sql`
- Modify: `ansible-project/roles/backend/files/backend/seed.sql`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_app.py:7-13` (existing `test_options_endpoint`)
- Test: `ansible-project/roles/backend/files/backend/tests/test_app.py` (new test appended)

**Interfaces:**
- Produces: `clubs.domestic_league_id` column (nullable `INTEGER REFERENCES leagues(id)`, `CHECK (domestic_league_id IS DISTINCT FROM league_id)`); global unique indexes `clubs_name_en_uidx`/`clubs_name_he_uidx` on `clubs(name_en)`/`clubs(name_he)` (replacing the old per-league `clubs_league_name_en_uidx`/`clubs_league_name_he_uidx`). Every later task's `create_club`/`rename_club` query functions depend on this exact column name and these exact index names (used to detect which language collided).

- [ ] **Step 1: Write the failing test for the schema migration**

Add to the end of `ansible-project/roles/backend/files/backend/tests/test_app.py`:

```python
def test_clubs_domestic_league_id_and_global_name_uniqueness(conn):
    import psycopg2
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'UCL'")
    ucl_id = cur.fetchone()[0]

    # A club can hold two distinct league slots.
    cur.execute(
        "INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he) "
        "VALUES (%s, %s, 'Test United', 'Test United', 'טסט יונייטד') RETURNING id",
        (ucl_id, epl_id)
    )
    conn.commit()

    # Global name uniqueness: the same name_en under a *different* league now collides
    # (this is the exact bug that let Arsenal exist twice before this migration).
    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute(
            "INSERT INTO clubs (league_id, name, name_en, name_he) "
            "VALUES (%s, 'Test United', 'Test United', 'אחר')",
            (epl_id,)
        )
    conn.rollback()

    # A club's two league slots can't be the same league.
    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute(
            "INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he) "
            "VALUES (%s, %s, 'Same Slot FC', 'Same Slot FC', 'קבוצה')",
            (epl_id, epl_id)
        )
    conn.rollback()
    cur.close()


def test_seed_data_dedupes_ucl_clubs_with_domestic_leagues(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'UCL'")
    ucl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]

    cur.execute("SELECT league_id, domestic_league_id FROM clubs WHERE name_en = 'Arsenal'")
    rows = cur.fetchall()
    assert len(rows) == 1, "Arsenal must be exactly one row after dedup"
    assert rows[0] == (ucl_id, epl_id)

    # PSG has no seeded domestic league and stays UCL-only.
    cur.execute("SELECT league_id, domestic_league_id FROM clubs WHERE name_en = 'Paris Saint-Germain'")
    rows = cur.fetchall()
    assert len(rows) == 1
    assert rows[0] == (ucl_id, None)
    cur.close()
```

Also update the existing `test_options_endpoint` (currently at `tests/test_app.py:7-13`), since `EPL`'s `name_en` is changing:

```python
def test_options_endpoint(client):
    resp = client.get('/api/options')
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'leagues' in body
    assert any(l['name_en'] == 'Premier League' for l in body['leagues'])
    assert any(l['name_he'] == 'הפרמייר ליג' for l in body['leagues'])
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ansible-project/roles/backend/files/backend && python -m pytest tests/test_app.py::test_clubs_domestic_league_id_and_global_name_uniqueness tests/test_app.py::test_seed_data_dedupes_ucl_clubs_with_domestic_leagues tests/test_app.py::test_options_endpoint -v`
Expected: `test_clubs_domestic_league_id_and_global_name_uniqueness` FAILs with `column "domestic_league_id" does not exist`; `test_seed_data_dedupes_ucl_clubs_with_domestic_leagues` FAILs with `len(rows) == 1` false (2 rows today); `test_options_endpoint` FAILs (`name_en` is still `'EPL'`).

- [ ] **Step 3: Add the schema migration**

In `schema.sql`, immediately after the existing block that ends with `CREATE UNIQUE INDEX IF NOT EXISTS clubs_league_name_he_uidx ON clubs (league_id, name_he) WHERE name_he IS NOT NULL;` (and before `CREATE TABLE IF NOT EXISTS votes`), insert:

```sql
-- One club can now be votable under two leagues (continental competition + domestic league) --
-- see docs/superpowers/specs/2026-07-15-clubs-leagues-admin-crud-design.md decision 10.
ALTER TABLE clubs ADD COLUMN IF NOT EXISTS domestic_league_id INTEGER REFERENCES leagues(id);

DO $$
BEGIN
    ALTER TABLE clubs ADD CONSTRAINT clubs_domestic_league_differs
        CHECK (domestic_league_id IS DISTINCT FROM league_id);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Club name uniqueness moves from per-league to global (decision 7) -- per-league uniqueness
-- is what let the same real club exist as two separate rows in two different leagues.
DROP INDEX IF EXISTS clubs_league_name_en_uidx;
DROP INDEX IF EXISTS clubs_league_name_he_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_en_uidx ON clubs (name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_he_uidx ON clubs (name_he) WHERE name_he IS NOT NULL;
```

- [ ] **Step 4: Run the schema test to verify it passes**

Run: `python -m pytest tests/test_app.py::test_clubs_domestic_league_id_and_global_name_uniqueness -v`
Expected: PASS

- [ ] **Step 5: Rewrite seed.sql's club list to remove the 14 now-duplicate domestic-league entries**

In `seed.sql`, in the `INSERT INTO clubs (league_id, name) SELECT ...` VALUES list, remove these 14 lines entirely (they stay listed once, under `'UCL'`, further up in the same VALUES list):

Remove from the `'EPL', ...` block: `('EPL', 'Arsenal'),`, `('EPL', 'Chelsea'),`, `('EPL', 'Liverpool'),`, `('EPL', 'Manchester City'),`, `('EPL', 'Manchester United'),`

Remove from the `'La Liga', ...` block: `('La Liga', 'Real Madrid'), ('La Liga', 'Barcelona'), ('La Liga', 'Atletico Madrid'),`

Remove from the `'Serie A', ...` block: `('Serie A', 'Inter Milan'), ('Serie A', 'AC Milan'), ('Serie A', 'Juventus'),` and `('Serie A', 'Napoli'),`

Remove from the `'Bundesliga', ...` block: `('Bundesliga', 'Bayern Munich'), ('Bundesliga', 'Borussia Dortmund'),`

(Leave every other line in that VALUES list untouched — this only removes the 14 rows that duplicated a UCL club under its domestic league. Paris Saint-Germain, Porto, Benfica, and Ajax stay as their single UCL-only line each; they have no domestic-league duplicate to remove.)

- [ ] **Step 6: Add the domestic_league_id backfill and the two league renames to seed.sql**

Immediately after the `INSERT INTO clubs ... ON CONFLICT (league_id, name) DO NOTHING;` statement (and before `INSERT INTO previous_parties`), add:

```sql
-- Link each UCL club that also plays in a domestic league this app seeds (decision 12).
-- Paris Saint-Germain/Porto/Benfica/Ajax are intentionally excluded -- their domestic
-- leagues (Ligue 1/Primeira Liga/Eredivisie) aren't seeded here, so they stay UCL-only.
UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'EPL')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name_en IN ('Arsenal', 'Chelsea', 'Liverpool', 'Manchester City', 'Manchester United');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'La Liga')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name_en IN ('Real Madrid', 'Barcelona', 'Atletico Madrid');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'Serie A')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name_en IN ('Inter Milan', 'AC Milan', 'Juventus', 'Napoli');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'Bundesliga')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name_en IN ('Bayern Munich', 'Borussia Dortmund');
```

Note: at this point in `seed.sql`, `name_en` has not been backfilled yet (that happens later, in the `UPDATE clubs SET name_en = name WHERE name_en IS NULL;` block) — so these four `UPDATE`s must match on `name` (the legacy column, already populated by the `INSERT` above), not `name_en`. Replace `name_en IN (...)` with `name IN (...)` in all four statements above before saving.

Then, in the existing "Leagues" backfill section (right after `UPDATE leagues SET name_he = 'מונדיאל 2026' ...` and its siblings), add two more lines:

```sql
UPDATE leagues SET name_en = 'Premier League' WHERE name = 'EPL';
UPDATE leagues SET name_en = 'UEFA Champions League' WHERE name = 'UCL';
```

- [ ] **Step 7: Run both remaining tests to verify they pass**

Run: `python -m pytest tests/test_app.py::test_seed_data_dedupes_ucl_clubs_with_domestic_leagues tests/test_app.py::test_options_endpoint -v`
Expected: PASS for both

- [ ] **Step 8: Run the full existing suite to confirm nothing else broke**

Run: `python -m pytest tests/ -v`
Expected: all tests PASS (this is the atomicity check — if `seed.sql` still had a duplicate name anywhere, this would fail with a `UniqueViolation` during fixture setup for *every* test, not just the new ones)

- [ ] **Step 9: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/schema.sql ansible-project/roles/backend/files/backend/seed.sql ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Add clubs.domestic_league_id, global club-name uniqueness, dedupe UCL seed data

Lets one club row be votable under two leagues (continental competition
+ domestic league) instead of existing as two separate duplicate rows.
Also renames UCL/EPL's name_en to their full names."
git push
```

---

## Task 2: League CRUD + reassign (backend)

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py` (append functions)
- Modify: `ansible-project/roles/backend/files/backend/app.py` (append routes)
- Test: `ansible-project/roles/backend/files/backend/tests/test_app.py` (append tests)

**Interfaces:**
- Consumes: nothing new from Task 1 beyond the schema being in place.
- Produces: `queries.create_league(conn, name_en, name_he) -> int`, `queries.rename_league(conn, league_id, name_en, name_he) -> bool`, `queries.delete_league(conn, league_id) -> bool`, `queries.league_exists(conn, league_id) -> bool`, `queries.count_votes_for_league(conn, league_id) -> int`, `queries.count_clubs_for_league(conn, league_id) -> int`, `queries.reassign_league_votes(conn, source_id, target_id) -> int`. Routes: `POST/PATCH/DELETE /api/admin/leagues[/<id>]`, `GET /api/admin/leagues/<id>/reassign-count`, `POST /api/admin/leagues/<id>/reassign`. Task 3 (clubs) reuses `league_exists` to validate a club's `league_id`/`domestic_league_id`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_app.py`:

```python
def test_league_admin_crud(client, admin_headers):
    headers = admin_headers

    resp = client.post('/api/admin/leagues', json={'name_en': 'Test League', 'name_he': 'ליגת בדיקה'}, headers=headers)
    assert resp.status_code == 201
    league_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/leagues/{league_id}', json={'name_en': 'Renamed League', 'name_he': 'שם חדש'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 404


def test_league_admin_routes_require_authentication(client):
    resp = client.post('/api/admin/leagues', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401
    resp = client.patch('/api/admin/leagues/1', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401
    resp = client.delete('/api/admin/leagues/1')
    assert resp.status_code == 401


def test_create_league_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'Dup League', 'name_he': 'Dup League'}, headers=headers)
    assert resp.status_code == 201
    resp = client.post('/api/admin/leagues', json={'name_en': 'Dup League', 'name_he': 'Dup League'}, headers=headers)
    assert resp.status_code == 409


def test_delete_league_blocked_when_clubs_reference_it(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'League With Club', 'name_he': 'ליגה עם קבוצה'}, headers=headers)
    league_id = resp.get_json()['id']
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en, name_he) VALUES (%s, 'Lone Club', 'Lone Club', 'קבוצה בודדה')",
        (league_id,)
    )
    conn.commit()
    cur.close()

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 club(s) still belong to this league'}


def test_delete_league_blocked_when_votes_reference_it(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'Voted League', 'name_he': 'ליגה עם הצבעה'}, headers=admin_headers)
    league_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 vote(s) still reference this league'}


def test_league_reassign_moves_votes_and_requires_zero_clubs(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'Source League', 'name_he': 'ליגת מקור'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/leagues', json={'name_en': 'Target League', 'name_he': 'ליגת יעד'}, headers=headers)
    target_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': source_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    vote_id = resp.get_json()['vote_id']

    resp = client.get(f'/api/admin/leagues/{source_id}/reassign-count?target_id={target_id}', headers=headers)
    assert resp.get_json() == {'count': 1}

    resp = client.post(f'/api/admin/leagues/{source_id}/reassign', json={'target_id': target_id}, headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {'reassigned': 1}

    resp = client.get('/api/admin/votes', headers=headers)
    vote = next(v for v in resp.get_json()['votes'] if v['id'] == vote_id)
    assert vote['league_id'] == target_id

    # Now block reassign on a league that still has a club.
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en, name_he) VALUES (%s, 'Blocker Club', 'Blocker Club', 'קבוצה חוסמת')",
        (target_id,)
    )
    conn.commit()
    cur.close()
    resp = client.post('/api/admin/leagues', json={'name_en': 'Third League', 'name_he': 'ליגה שלישית'}, headers=headers)
    third_id = resp.get_json()['id']
    resp = client.post(f'/api/admin/leagues/{target_id}/reassign', json={'target_id': third_id}, headers=headers)
    assert resp.status_code == 400
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_app.py -k league_admin -v`
Expected: FAIL — `/api/admin/leagues` routes don't exist yet (404s, not the expected status codes)

- [ ] **Step 3: Add query functions**

Append to `queries.py`:

```python
def create_league(conn, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO leagues (name, name_en, name_he) VALUES (%s, %s, %s) RETURNING id',
            (name_he, name_en, name_he)
        )
        league_id = cur.fetchone()[0]
        conn.commit()
        return league_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_league(conn, league_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE leagues SET name = %s, name_en = %s, name_he = %s WHERE id = %s',
            (name_he, name_en, name_he, league_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_league(conn, league_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM leagues WHERE id = %s', (league_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def league_exists(conn, league_id):
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM leagues WHERE id = %s', (league_id,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def count_votes_for_league(conn, league_id):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes WHERE league_id = %s', (league_id,))
    count = cur.fetchone()[0]
    cur.close()
    return count


def count_clubs_for_league(conn, league_id):
    cur = conn.cursor()
    cur.execute(
        'SELECT COUNT(*) FROM clubs WHERE league_id = %s OR domestic_league_id = %s',
        (league_id, league_id)
    )
    count = cur.fetchone()[0]
    cur.close()
    return count


def reassign_league_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE votes SET league_id = %s WHERE league_id = %s',
            (target_id, source_id)
        )
        reassigned = cur.rowcount
        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

Note `count_clubs_for_league` checks **both** `league_id` and `domestic_league_id` — a league can't be deleted or reassigned away from while any club still names it in either slot (this is the decision-4/5 guard generalized for two-slot clubs; not just `league_id` alone, since a club could be sitting in someone's `domestic_league_id` too).

- [ ] **Step 4: Add a generic duplicate-name error helper, and routes**

The existing `_duplicate_party_error_response` (`app.py:37-40`) hardcodes the word "party" in its message — reusing it verbatim for leagues would say "a party with this name already exists," which is wrong. Add a small generalized sibling instead of changing the existing one (the party routes keep using their own helper unchanged). Add this just below `_duplicate_party_error_response`:

```python
def _duplicate_named_error_response(err, entity):
    message = f'a {entity} with this English name already exists' if err.language == 'en' \
        else f'a {entity} with this Hebrew name already exists'
    return jsonify({'error': message}), 409
```

Append the routes to `app.py`, after `reassign_previous_party_route` and before `get_votes_route`:

```python
@app.route('/api/admin/leagues', methods=['POST'])
@require_admin
def create_league_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        league_id = queries.create_league(conn, name_en, name_he)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_named_error_response(err, 'league')
    finally:
        conn.close()
    return jsonify({'id': league_id, 'name_en': name_en, 'name_he': name_he}), 201


@app.route('/api/admin/leagues/<int:league_id>', methods=['PATCH'])
@require_admin
def rename_league_route(league_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_league(conn, league_id, name_en, name_he)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_named_error_response(err, 'league')
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': league_id, 'name_en': name_en, 'name_he': name_he})


@app.route('/api/admin/leagues/<int:league_id>', methods=['DELETE'])
@require_admin
def delete_league_route(league_id):
    conn = db.get_db()
    try:
        referencing_clubs = queries.count_clubs_for_league(conn, league_id)
        if referencing_clubs > 0:
            return jsonify({'error': f'{referencing_clubs} club(s) still belong to this league'}), 409
        referencing_votes = queries.count_votes_for_league(conn, league_id)
        if referencing_votes > 0:
            return jsonify({'error': f'{referencing_votes} vote(s) still reference this league'}), 409
        deleted = queries.delete_league(conn, league_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


@app.route('/api/admin/leagues/<int:source_id>/reassign-count', methods=['GET'])
@require_admin
def league_reassign_count_route(source_id):
    target_id = request.args.get('target_id', type=int)
    if target_id is None:
        return jsonify({'error': 'target_id is required'}), 400
    conn = db.get_db()
    try:
        count = queries.count_votes_for_league(conn, source_id)
    finally:
        conn.close()
    return jsonify({'count': count})


@app.route('/api/admin/leagues/<int:source_id>/reassign', methods=['POST'])
@require_admin
def reassign_league_route(source_id):
    body = request.get_json(force=True, silent=True) or {}
    target_id = body.get('target_id')
    if not isinstance(target_id, int):
        return jsonify({'error': 'target_id is required'}), 400
    if target_id == source_id:
        return jsonify({'error': 'target_id must differ from source league'}), 400
    conn = db.get_db()
    try:
        if not queries.league_exists(conn, target_id):
            return jsonify({'error': 'target league not found'}), 404
        if queries.count_clubs_for_league(conn, source_id) > 0:
            return jsonify({'error': 'source league still has clubs; move or delete them first'}), 400
        reassigned = queries.reassign_league_votes(conn, source_id, target_id)
    finally:
        conn.close()
    return jsonify({'reassigned': reassigned})
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_app.py -k league_admin -v`
Expected: PASS

- [ ] **Step 6: Run the full suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS

- [ ] **Step 7: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/queries.py ansible-project/roles/backend/files/backend/app.py ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Add admin CRUD + reassign for leagues

Mirrors the existing previous_parties/upcoming_parties pattern. Delete
and reassign are additionally guarded against a league that still has
clubs in either its league_id or domestic_league_id slot."
git push
```

---

## Task 3: Club CRUD + reassign (backend)

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py` (append)
- Modify: `ansible-project/roles/backend/files/backend/app.py` (append)
- Test: `ansible-project/roles/backend/files/backend/tests/test_app.py` (append)

**Interfaces:**
- Consumes: `queries.league_exists` (Task 2), `_duplicate_named_error_response` (Task 2).
- Produces: `queries.DuplicateClubNameError(language)`, `queries.create_club(conn, league_id, domestic_league_id, name_en, name_he) -> int`, `queries.rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he) -> bool`, `queries.delete_club(conn, club_id) -> bool`, `queries.club_exists(conn, club_id) -> bool`, `queries.get_club_leagues(conn, club_id) -> {'league_id': int, 'domestic_league_id': int|None} | None`, `queries.count_votes_for_club(conn, club_id) -> int`, `queries.reassign_club_votes(conn, source_id, target_id) -> int`. Routes: `POST/PATCH/DELETE /api/admin/clubs[/<id>]`, `GET /api/admin/clubs/<id>/reassign-count`, `POST /api/admin/clubs/<id>/reassign`. Task 6 (Teams tab JS) calls these exact routes with these exact body shapes.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_app.py`:

```python
def test_club_admin_crud(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/admin/clubs', json={
        'league_id': epl_id, 'name_en': 'Test FC', 'name_he': 'טסט אף.סי',
    }, headers=headers)
    assert resp.status_code == 201
    club_id = resp.get_json()['id']
    assert resp.get_json()['domestic_league_id'] is None

    resp = client.patch(f'/api/admin/clubs/{club_id}', json={
        'league_id': epl_id, 'domestic_league_id': la_liga_id,
        'name_en': 'Test FC Renamed', 'name_he': 'שם חדש',
    }, headers=headers)
    assert resp.status_code == 200
    assert resp.get_json()['domestic_league_id'] == la_liga_id

    resp = client.delete(f'/api/admin/clubs/{club_id}', headers=headers)
    assert resp.status_code == 204
    resp = client.delete(f'/api/admin/clubs/{club_id}', headers=headers)
    assert resp.status_code == 404


def test_club_admin_routes_require_authentication(client):
    resp = client.post('/api/admin/clubs', json={'league_id': 1, 'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401
    resp = client.patch('/api/admin/clubs/1', json={'league_id': 1, 'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401
    resp = client.delete('/api/admin/clubs/1')
    assert resp.status_code == 401


def test_create_club_duplicate_name_is_global_not_per_league(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/admin/clubs', json={
        'league_id': epl_id, 'name_en': 'Global Dup', 'name_he': 'Global Dup',
    }, headers=headers)
    assert resp.status_code == 201

    # Same name, a *different* league -- must still collide (decision 7's whole point).
    resp = client.post('/api/admin/clubs', json={
        'league_id': la_liga_id, 'name_en': 'Global Dup', 'name_he': 'Global Dup',
    }, headers=headers)
    assert resp.status_code == 409


def test_create_club_validates_league_ids(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/admin/clubs', json={'league_id': 999999, 'name_en': 'X', 'name_he': 'א'}, headers=headers)
    assert resp.status_code == 404

    resp = client.post('/api/admin/clubs', json={
        'league_id': epl_id, 'domestic_league_id': 999999, 'name_en': 'X', 'name_he': 'א',
    }, headers=headers)
    assert resp.status_code == 404

    resp = client.post('/api/admin/clubs', json={
        'league_id': epl_id, 'domestic_league_id': epl_id, 'name_en': 'X', 'name_he': 'א',
    }, headers=headers)
    assert resp.status_code == 400


def test_delete_club_blocked_when_referenced_by_votes(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/clubs', json={'league_id': epl_id, 'name_en': 'Voted Club', 'name_he': 'קבוצה מוצבעת'}, headers=headers)
    club_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': epl_id, 'club_id': club_id,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201

    resp = client.delete(f'/api/admin/clubs/{club_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 vote(s) still reference this club'}


def test_club_reassign_same_single_league_succeeds(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/clubs', json={'league_id': epl_id, 'name_en': 'Source Club', 'name_he': 'קבוצת מקור'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/clubs', json={'league_id': epl_id, 'name_en': 'Target Club', 'name_he': 'קבוצת יעד'}, headers=headers)
    target_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': epl_id, 'club_id': source_id,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    vote_id = resp.get_json()['vote_id']

    resp = client.get(f'/api/admin/clubs/{source_id}/reassign-count?target_id={target_id}', headers=headers)
    assert resp.get_json() == {'count': 1}

    resp = client.post(f'/api/admin/clubs/{source_id}/reassign', json={'target_id': target_id}, headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {'reassigned': 1}

    resp = client.get('/api/admin/votes', headers=headers)
    vote = next(v for v in resp.get_json()['votes'] if v['id'] == vote_id)
    assert vote['club_id'] == target_id


def test_club_reassign_rejects_target_not_covering_source_leagues(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'UCL'")
    ucl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    # Source is votable under two leagues (UCL + EPL).
    resp = client.post('/api/admin/clubs', json={
        'league_id': ucl_id, 'domestic_league_id': epl_id, 'name_en': 'Two League Club', 'name_he': 'קבוצת שתי ליגות',
    }, headers=headers)
    source_id = resp.get_json()['id']

    # Target only covers La Liga -- doesn't cover either of the source's leagues.
    resp = client.post('/api/admin/clubs', json={'league_id': la_liga_id, 'name_en': 'One League Club', 'name_he': 'קבוצת ליגה אחת'}, headers=headers)
    target_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/clubs/{source_id}/reassign', json={'target_id': target_id}, headers=headers)
    assert resp.status_code == 400

    # A target covering *both* UCL and EPL is accepted.
    resp = client.post('/api/admin/clubs', json={
        'league_id': ucl_id, 'domestic_league_id': epl_id, 'name_en': 'Covering Club', 'name_he': 'קבוצה מכסה',
    }, headers=headers)
    covering_target_id = resp.get_json()['id']
    resp = client.post(f'/api/admin/clubs/{source_id}/reassign', json={'target_id': covering_target_id}, headers=headers)
    assert resp.status_code == 200


def test_club_reassign_rejects_equal_source_and_target(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.close()
    resp = client.post('/api/admin/clubs', json={'league_id': epl_id, 'name_en': 'X', 'name_he': 'א'}, headers=headers)
    club_id = resp.get_json()['id']
    resp = client.post(f'/api/admin/clubs/{club_id}/reassign', json={'target_id': club_id}, headers=headers)
    assert resp.status_code == 400


def test_club_reassign_rejects_nonexistent_target(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.close()
    resp = client.post('/api/admin/clubs', json={'league_id': epl_id, 'name_en': 'Solo Club', 'name_he': 'קבוצה בודדה'}, headers=headers)
    club_id = resp.get_json()['id']
    resp = client.post(f'/api/admin/clubs/{club_id}/reassign', json={'target_id': 999999}, headers=headers)
    assert resp.status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_app.py -k club_admin -v` and `python -m pytest tests/test_app.py -k club_reassign -v` and `python -m pytest tests/test_app.py -k create_club -v` and `python -m pytest tests/test_app.py -k delete_club -v`
Expected: FAIL — `/api/admin/clubs` routes don't exist yet

- [ ] **Step 3: Add query functions**

Append to `queries.py`:

```python
class DuplicateClubNameError(Exception):
    def __init__(self, language):
        self.language = language
        super().__init__(f'a club with this {language} name already exists')


def create_club(conn, league_id, domestic_league_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he) '
            'VALUES (%s, %s, %s, %s, %s) RETURNING id',
            (league_id, domestic_league_id, name_he, name_en, name_he)
        )
        club_id = cur.fetchone()[0]
        conn.commit()
        return club_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicateClubNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE clubs SET league_id = %s, domestic_league_id = %s, name = %s, name_en = %s, name_he = %s '
            'WHERE id = %s',
            (league_id, domestic_league_id, name_he, name_en, name_he, club_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicateClubNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_club(conn, club_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM clubs WHERE id = %s', (club_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def club_exists(conn, club_id):
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM clubs WHERE id = %s', (club_id,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def get_club_leagues(conn, club_id):
    cur = conn.cursor()
    cur.execute('SELECT league_id, domestic_league_id FROM clubs WHERE id = %s', (club_id,))
    row = cur.fetchone()
    cur.close()
    if row is None:
        return None
    return {'league_id': row[0], 'domestic_league_id': row[1]}


def count_votes_for_club(conn, club_id):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes WHERE club_id = %s', (club_id,))
    count = cur.fetchone()[0]
    cur.close()
    return count


def reassign_club_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute('UPDATE votes SET club_id = %s WHERE club_id = %s', (target_id, source_id))
        reassigned = cur.rowcount
        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

`_duplicate_party_language` (`queries.py:10-14`) needs no change — it already matches on `endswith('_name_en_uidx')`, which is true for `clubs_name_en_uidx` from Task 1 too.

- [ ] **Step 4: Add routes**

Append to `app.py`, after the league routes from Task 2 and before `get_votes_route`:

```python
@app.route('/api/admin/clubs', methods=['POST'])
@require_admin
def create_club_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    league_id = body.get('league_id')
    if not isinstance(league_id, int):
        return jsonify({'error': 'league_id is required'}), 400
    domestic_league_id = body.get('domestic_league_id')
    if domestic_league_id is not None and not isinstance(domestic_league_id, int):
        return jsonify({'error': 'domestic_league_id must be an integer or null'}), 400
    if domestic_league_id is not None and domestic_league_id == league_id:
        return jsonify({'error': 'domestic_league_id must differ from league_id'}), 400
    conn = db.get_db()
    try:
        if not queries.league_exists(conn, league_id):
            return jsonify({'error': 'league not found'}), 404
        if domestic_league_id is not None and not queries.league_exists(conn, domestic_league_id):
            return jsonify({'error': 'domestic league not found'}), 404
        club_id = queries.create_club(conn, league_id, domestic_league_id, name_en, name_he)
    except queries.DuplicateClubNameError as err:
        return _duplicate_named_error_response(err, 'club')
    finally:
        conn.close()
    return jsonify({
        'id': club_id, 'league_id': league_id, 'domestic_league_id': domestic_league_id,
        'name_en': name_en, 'name_he': name_he,
    }), 201


@app.route('/api/admin/clubs/<int:club_id>', methods=['PATCH'])
@require_admin
def rename_club_route(club_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    league_id = body.get('league_id')
    if not isinstance(league_id, int):
        return jsonify({'error': 'league_id is required'}), 400
    domestic_league_id = body.get('domestic_league_id')
    if domestic_league_id is not None and not isinstance(domestic_league_id, int):
        return jsonify({'error': 'domestic_league_id must be an integer or null'}), 400
    if domestic_league_id is not None and domestic_league_id == league_id:
        return jsonify({'error': 'domestic_league_id must differ from league_id'}), 400
    conn = db.get_db()
    try:
        if not queries.league_exists(conn, league_id):
            return jsonify({'error': 'league not found'}), 404
        if domestic_league_id is not None and not queries.league_exists(conn, domestic_league_id):
            return jsonify({'error': 'domestic league not found'}), 404
        updated = queries.rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he)
    except queries.DuplicateClubNameError as err:
        return _duplicate_named_error_response(err, 'club')
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({
        'id': club_id, 'league_id': league_id, 'domestic_league_id': domestic_league_id,
        'name_en': name_en, 'name_he': name_he,
    })


@app.route('/api/admin/clubs/<int:club_id>', methods=['DELETE'])
@require_admin
def delete_club_route(club_id):
    conn = db.get_db()
    try:
        referencing = queries.count_votes_for_club(conn, club_id)
        if referencing > 0:
            return jsonify({'error': f'{referencing} vote(s) still reference this club'}), 409
        deleted = queries.delete_club(conn, club_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


@app.route('/api/admin/clubs/<int:source_id>/reassign-count', methods=['GET'])
@require_admin
def club_reassign_count_route(source_id):
    target_id = request.args.get('target_id', type=int)
    if target_id is None:
        return jsonify({'error': 'target_id is required'}), 400
    conn = db.get_db()
    try:
        count = queries.count_votes_for_club(conn, source_id)
    finally:
        conn.close()
    return jsonify({'count': count})


@app.route('/api/admin/clubs/<int:source_id>/reassign', methods=['POST'])
@require_admin
def reassign_club_route(source_id):
    body = request.get_json(force=True, silent=True) or {}
    target_id = body.get('target_id')
    if not isinstance(target_id, int):
        return jsonify({'error': 'target_id is required'}), 400
    if target_id == source_id:
        return jsonify({'error': 'target_id must differ from source club'}), 400
    conn = db.get_db()
    try:
        source_leagues = queries.get_club_leagues(conn, source_id)
        if source_leagues is None:
            return jsonify({'error': 'not found'}), 404
        target_leagues = queries.get_club_leagues(conn, target_id)
        if target_leagues is None:
            return jsonify({'error': 'target club not found'}), 404
        source_set = {v for v in (source_leagues['league_id'], source_leagues['domestic_league_id']) if v is not None}
        target_set = {v for v in (target_leagues['league_id'], target_leagues['domestic_league_id']) if v is not None}
        if not source_set.issubset(target_set):
            return jsonify({'error': 'target club does not cover every league the source club is votable under'}), 400
        reassigned = queries.reassign_club_votes(conn, source_id, target_id)
    finally:
        conn.close()
    return jsonify({'reassigned': reassigned})
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_app.py -k "club_admin or club_reassign or create_club or delete_club" -v`
Expected: PASS

- [ ] **Step 6: Run the full suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS

- [ ] **Step 7: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/queries.py ansible-project/roles/backend/files/backend/app.py ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Add admin CRUD + reassign for clubs

Club name uniqueness is enforced globally (not per-league) at the
route level too via the schema's global unique index. Reassign
requires the target club's league membership to be a superset of the
source's, since a club can now be votable under two leagues."
git push
```

---

## Task 4: Expose `domestic_league_id` on `GET /api/options`

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py:23-24` (the `get_options` clubs query)
- Test: `ansible-project/roles/backend/files/backend/tests/test_app.py` (append)

**Interfaces:**
- Produces: every club dict in `GET /api/options`'s `clubs` array now has a `domestic_league_id` key (`int | None`). Task 5's `vote.js` change and Task 6's admin Teams tab both read this field.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_app.py`:

```python
def test_options_endpoint_exposes_club_domestic_league_id(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.close()

    resp = client.get('/api/options')
    body = resp.get_json()
    arsenal = next(c for c in body['clubs'] if c['name_en'] == 'Arsenal')
    assert arsenal['domestic_league_id'] == epl_id

    psg = next(c for c in body['clubs'] if c['name_en'] == 'Paris Saint-Germain')
    assert psg['domestic_league_id'] is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_app.py::test_options_endpoint_exposes_club_domestic_league_id -v`
Expected: FAIL with `KeyError: 'domestic_league_id'`

- [ ] **Step 3: Update `get_options`**

In `queries.py`, replace lines 23-24:

```python
    cur.execute('SELECT id, league_id, name_en, name_he FROM clubs ORDER BY name_en')
    clubs = [{'id': r[0], 'league_id': r[1], 'name_en': r[2], 'name_he': r[3]} for r in cur.fetchall()]
```

with:

```python
    cur.execute('SELECT id, league_id, domestic_league_id, name_en, name_he FROM clubs ORDER BY name_en')
    clubs = [
        {'id': r[0], 'league_id': r[1], 'domestic_league_id': r[2], 'name_en': r[3], 'name_he': r[4]}
        for r in cur.fetchall()
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_app.py::test_options_endpoint_exposes_club_domestic_league_id -v`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS

- [ ] **Step 6: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/queries.py ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Expose clubs.domestic_league_id on GET /api/options

Needed by the public vote flow (a club votable under two leagues) and
the admin Teams tab, both landing next."
git push
```

---

## Task 5: Public vote-flow club filter (`vote.js`)

No automated frontend test suite exists for this project (per `CLAUDE.md`) — this task is verified by driving the real page in a browser, not by writing JS tests.

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/vote.js:22`

**Interfaces:**
- Consumes: `domestic_league_id` field on club objects from Task 4.

- [ ] **Step 1: Change the club filter**

In `vote.js`, `renderClubs()`, replace line 22:

```javascript
  optionsData.clubs.filter(c => c.league_id === leagueId).forEach(c => {
```

with:

```javascript
  optionsData.clubs.filter(c => c.league_id === leagueId || c.domestic_league_id === leagueId).forEach(c => {
```

- [ ] **Step 2: Verify manually**

This requires the backend from Tasks 1-4 running against a real Postgres (or the deployed stack). Start the backend (`cd ansible-project/roles/backend/files/backend && FLASK_APP=app.py DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable ADMIN_USERNAME=testadmin ADMIN_PASSWORD_HASH=... ADMIN_SESSION_SECRET=... python app.py`, using the `voteball-test-db` Docker container from the Global Constraints section) and serve `index.html` (any static server, or via the full Ansible/Helm deploy). In a browser:

1. Open `index.html`, pick "UEFA Champions League" as the league — confirm "Arsenal" appears in the club dropdown.
2. Change league to "Premier League" — confirm "Arsenal" *also* appears (this is the behavior Task 5 adds; before this change it would only show under whichever single league it belonged to).
3. Pick "Premier League" + "Arsenal" and submit a vote. Check `GET /api/admin/votes` (via `admin.html` or `curl` with a Bearer token) — confirm the stored vote has `league_id` equal to Premier League's id, not UCL's, proving the vote records whichever league was actually browsed under, not some fixed "home league" for the club.

- [ ] **Step 3: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/vote.js
git commit -m "Show a club under both its leagues in the public vote form

A club with domestic_league_id set (e.g. Arsenal: UCL + Premier
League) now appears in the club dropdown under either league, not
just the one currently in league_id."
git push
```

---

## Task 6: Admin "Teams" tab — i18n keys, markup, render/add/rename/delete

No automated frontend test suite exists — verified by driving `admin.html` in a browser (Global Constraints).

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/i18n.js` (append dictionary keys, both `en` and `he`)
- Modify: `ansible-project/roles/frontend/files/nginx/admin.html` (new tab button + section + CSS)
- Modify: `ansible-project/roles/frontend/files/nginx/admin.js` (append)

**Interfaces:**
- Consumes: routes from Tasks 2/3 (`/api/admin/leagues`, `/api/admin/clubs`), `domestic_league_id` field from Task 4, `adminFetch`/`getOptionsData`/`t`/`localizedName`/`loadedTabs`/`optionsData` from the existing `admin.js`.
- Produces: `buildLeagueSelect(leagues, excludeId, includeNone) -> HTMLSelectElement`, `loadTeamsTab()`, `renderLeagueGroups(data)`, `renderLeagueGroup(league, data) -> HTMLElement`, `renderClubRow(club, data, annotateLeagueId) -> HTMLElement` — Task 7 extends `renderClubRow` to add the UCL toggle button, and reuses `buildLeagueSelect`/`loadTeamsTab`/`optionsData`.

- [ ] **Step 1: Add i18n dictionary keys**

In `i18n.js`, inside the `en` object, immediately after `adminReassignGo: 'Reassign',` add:

```javascript
    adminTabTeams: 'Teams',
    adminHeadingTeams: 'Teams',
    adminAddLeague: '+ Add league',
    adminAddClub: '+ Add club',
    adminDomesticLeagueNone: '— none —',
    adminAlsoInLeague: 'also in {league}',
```

Inside the `he` object, immediately after `adminReassignGo: 'העברה',` add:

```javascript
    adminTabTeams: 'קבוצות',
    adminHeadingTeams: 'קבוצות',
    adminAddLeague: '+ הוספת ליגה',
    adminAddClub: '+ הוספת קבוצה',
    adminDomesticLeagueNone: '— ללא —',
    adminAlsoInLeague: 'גם ב{league}',
```

- [ ] **Step 2: Add the Teams tab markup and CSS to `admin.html`**

Add a fourth tab button, first in tab order (per the design spec, since every vote references a league/club), immediately before the existing Previous Parties button:

```html
      <button type="button" class="tab-button" data-tab="teams" data-i18n="adminTabTeams">Teams</button>
```

so the tab bar's four buttons read Teams, Previous Parties, Upcoming Parties, Votes, Log out. (Previous Parties keeps its `active` class and stays the tab shown right after login — unchanged from today; only button order changes.)

Add a new section, before `<section id="tab-previous" ...>`:

```html
    <section id="tab-teams" class="tab-section">
      <h2 data-i18n="adminHeadingTeams">Teams</h2>
      <div id="league-list"></div>
      <form id="league-add-form">
        <input type="text" id="league-add-input-en" data-i18n-placeholder="adminPlaceholderNameEn" placeholder="English name" required>
        <input type="text" id="league-add-input-he" data-i18n-placeholder="adminPlaceholderNameHe" placeholder="Hebrew name" dir="rtl" required>
        <button type="submit" data-i18n="adminAddLeague">+ Add league</button>
      </form>
      <p class="error" id="league-form-error"></p>
    </section>
```

Add CSS inside the existing `<style>` block, after the `.reassign-form` rule:

```css
    .league-group { border: 1px solid #ddd; border-radius: 6px; padding: 0.6rem; margin: 0.6rem 0; }
    .league-header { font-weight: bold; }
    .club-list { margin: 0.3rem 0 0.3rem 1rem; }
    .club-row { font-weight: normal; }
    .row-note { color: #666; font-size: 0.85rem; }
    .add-club-form { display: flex; gap: 0.4rem; align-items: center; margin: 0.4rem 0 0.4rem 1rem; flex-wrap: wrap; }
```

- [ ] **Step 3: Add the render/add/rename/delete logic to `admin.js`**

In `loadTab(tab)` (`admin.js:50-56`), add a branch:

```javascript
function loadTab(tab) {
  if (loadedTabs.has(tab)) return;
  loadedTabs.add(tab);
  if (tab === 'teams') loadTeamsTab();
  else if (tab === 'previous') loadPartyTab('previous');
  else if (tab === 'upcoming') loadPartyTab('upcoming');
  else if (tab === 'votes') loadVotesTab();
}
```

Append the following to `admin.js` (anywhere after the existing `leagueName`/`clubName` helper functions, so this can call them):

```javascript
function buildLeagueSelect(leagues, excludeId, includeNone) {
  const select = document.createElement('select');
  if (includeNone) {
    const noneOpt = document.createElement('option');
    noneOpt.value = '';
    noneOpt.textContent = t('adminDomesticLeagueNone');
    select.appendChild(noneOpt);
  }
  leagues.filter(l => l.id !== excludeId).forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    select.appendChild(opt);
  });
  return select;
}

async function loadTeamsTab() {
  const data = await getOptionsData();
  renderLeagueGroups(data);
}

function renderLeagueGroups(data) {
  const container = document.getElementById('league-list');
  container.innerHTML = '';
  data.leagues.forEach(league => container.appendChild(renderLeagueGroup(league, data)));
}

function renderLeagueGroup(league, data) {
  const group = document.createElement('div');
  group.className = 'league-group';
  group.dataset.leagueId = league.id;

  const header = document.createElement('div');
  header.className = 'party-row league-header';
  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = localizedName(league);
  header.appendChild(nameSpan);

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRenameLeague(league, header));
  header.appendChild(renameBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = t('adminDelete');
  deleteBtn.addEventListener('click', () => deleteLeague(league));
  header.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  header.appendChild(errorSpan);

  group.appendChild(header);

  const clubsContainer = document.createElement('div');
  clubsContainer.className = 'club-list';
  data.clubs.filter(c => c.league_id === league.id).forEach(club => {
    clubsContainer.appendChild(renderClubRow(club, data, null));
  });
  data.clubs.filter(c => c.domestic_league_id === league.id).forEach(club => {
    clubsContainer.appendChild(renderClubRow(club, data, club.league_id));
  });
  group.appendChild(clubsContainer);

  group.appendChild(renderAddClubForm(league));

  return group;
}

function renderClubRow(club, data, annotateLeagueId) {
  const row = document.createElement('div');
  row.className = 'party-row club-row';
  row.dataset.clubId = club.id;

  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = localizedName(club);
  row.appendChild(nameSpan);

  if (annotateLeagueId !== null) {
    const note = document.createElement('span');
    note.className = 'row-note';
    note.textContent = t('adminAlsoInLeague').replace('{league}', leagueName(data, annotateLeagueId));
    row.appendChild(note);
    return row; // read-only secondary listing under its domestic league group -- edit from its primary row
  }

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRenameClub(club, data, row));
  row.appendChild(renameBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = t('adminDelete');
  deleteBtn.addEventListener('click', () => deleteClub(club));
  row.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  row.appendChild(errorSpan);

  return row;
}

function renderAddClubForm(league) {
  const form = document.createElement('form');
  form.className = 'add-club-form';
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.placeholder = t('adminPlaceholderNameEn');
  inputEn.required = true;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.placeholder = t('adminPlaceholderNameHe');
  inputHe.dir = 'rtl';
  inputHe.required = true;
  const domesticSelect = buildLeagueSelect(optionsData.leagues, league.id, true);
  const addBtn = document.createElement('button');
  addBtn.type = 'submit';
  addBtn.textContent = t('adminAddClub');
  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';

  [inputEn, inputHe, domesticSelect, addBtn, errorSpan].forEach(el => form.appendChild(el));

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    errorSpan.textContent = '';
    const domesticLeagueId = domesticSelect.value ? parseInt(domesticSelect.value, 10) : null;
    let res;
    try {
      res = await adminFetch('/api/admin/clubs', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          league_id: league.id, domestic_league_id: domesticLeagueId,
          name_en: inputEn.value, name_he: inputHe.value,
        }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadTeamsTab();
  });

  return form;
}

function startRenameClub(club, data, row) {
  row.innerHTML = '';
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.value = club.name_en;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.value = club.name_he;
  inputHe.dir = 'rtl';
  const leagueSelect = buildLeagueSelect(data.leagues, null, false);
  leagueSelect.value = club.league_id;
  let domesticSelect = buildLeagueSelect(data.leagues, club.league_id, true);
  domesticSelect.value = club.domestic_league_id || '';

  leagueSelect.addEventListener('change', () => {
    const chosen = parseInt(leagueSelect.value, 10);
    const rebuilt = buildLeagueSelect(data.leagues, chosen, true);
    domesticSelect.replaceWith(rebuilt);
    domesticSelect = rebuilt;
  });

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = t('adminSave');
  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';

  [inputEn, inputHe, leagueSelect, domesticSelect, saveBtn, errorSpan].forEach(el => row.appendChild(el));
  inputEn.focus();

  saveBtn.addEventListener('click', async () => {
    errorSpan.textContent = '';
    const domesticLeagueId = domesticSelect.value ? parseInt(domesticSelect.value, 10) : null;
    let res;
    try {
      res = await adminFetch(`/api/admin/clubs/${club.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          league_id: parseInt(leagueSelect.value, 10), domestic_league_id: domesticLeagueId,
          name_en: inputEn.value, name_he: inputHe.value,
        }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadTeamsTab();
  });
}

async function deleteClub(club) {
  if (!confirm(t('adminConfirmDeleteParty').replace('{name}', localizedName(club)))) return;
  let res;
  try {
    res = await adminFetch(`/api/admin/clubs/${club.id}`, { method: 'DELETE' });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
}

function startRenameLeague(league, header) {
  const nameSpan = header.querySelector('.party-name');
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.value = league.name_en;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.value = league.name_he;
  inputHe.dir = 'rtl';
  nameSpan.replaceWith(inputEn);
  inputEn.after(inputHe);

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = t('adminSave');
  inputHe.after(saveBtn);
  inputEn.focus();

  saveBtn.addEventListener('click', async () => {
    const errorSpan = header.querySelector('.row-error');
    errorSpan.textContent = '';
    let res;
    try {
      res = await adminFetch(`/api/admin/leagues/${league.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadTeamsTab();
  });
}

async function deleteLeague(league) {
  if (!confirm(t('adminConfirmDeleteParty').replace('{name}', localizedName(league)))) return;
  let res;
  try {
    res = await adminFetch(`/api/admin/leagues/${league.id}`, { method: 'DELETE' });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
}

document.getElementById('league-add-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const inputEn = document.getElementById('league-add-input-en');
  const inputHe = document.getElementById('league-add-input-he');
  const errorEl = document.getElementById('league-form-error');
  errorEl.textContent = '';
  let res;
  try {
    res = await adminFetch('/api/admin/leagues', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
    });
  } catch (err) {
    errorEl.textContent = t('adminSomethingWrong');
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    errorEl.textContent = body.error || t('adminSomethingWrong');
    return;
  }
  inputEn.value = '';
  inputHe.value = '';
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
});
```

Note `adminConfirmDeleteParty`'s existing wording (`'Delete "{name}"? This cannot be undone.'`) has no party-specific text — it's reused as-is for league/club delete confirms rather than adding duplicate i18n keys.

- [ ] **Step 4: Verify manually**

Run the backend (Task 5's Step 2 command) and serve the frontend directory. In a browser, log into `admin.html`:

1. Click the "Teams" tab — confirm every league renders as a group, each with its clubs listed underneath.
2. Confirm a club with a domestic league (e.g. Arsenal) shows once, editable, under "UEFA Champions League", and a second time, read-only with a "also in Premier League" note, under "Premier League".
3. Add a new league via the bottom form — confirm it appears as a new empty group.
4. Within a league group, add a new club (leave Domestic League as "— none —") — confirm it appears in that group only.
5. Rename a club, changing its League dropdown to a different league and setting a Domestic League — confirm it now renders under both the new groups correctly on tab reload.
6. Delete an unreferenced club and an unreferenced league — confirm both disappear.
7. Toggle the language switcher — confirm the Teams tab's static labels (tab name, heading, add buttons, "also in" notes) switch to Hebrew and RTL layout, matching the rest of the admin page.

- [ ] **Step 5: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/i18n.js ansible-project/roles/frontend/files/nginx/admin.html ansible-project/roles/frontend/files/nginx/admin.js
git commit -m "Add admin Teams tab: render, add, rename, delete for leagues/clubs

Leagues render as expandable groups with their clubs nested inside; a
club with a domestic league appears (read-only) under both groups.
Mirrors the existing party tabs' interaction pattern."
git push
```

---

## Task 7: Teams tab — reassign flow + UEFA Champions League toggle buttons

No automated frontend test suite exists — verified by driving `admin.html` in a browser.

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/i18n.js` (append keys)
- Modify: `ansible-project/roles/frontend/files/nginx/admin.js` (add reassign buttons + toggle buttons + wire langchange)

**Interfaces:**
- Consumes: `renderLeagueGroup`, `renderClubRow`, `buildLeagueSelect`, `loadTeamsTab` from Task 6; `/api/admin/leagues/<id>/reassign*` (Task 2) and `/api/admin/clubs/<id>/reassign*` (Task 3).

- [ ] **Step 1: Add i18n keys for the UCL toggle**

In `i18n.js`, `en` object, after the keys added in Task 6:

```javascript
    adminAddToChampionsLeague: 'Add to UEFA Champions League',
    adminRemoveFromChampionsLeague: 'Remove from UEFA Champions League',
    adminUclAddDisabled: 'Already has a domestic league on file — edit via Rename instead.',
    adminUclRemoveDisabled: 'No domestic league on file — give it one via Rename first.',
```

`he` object, matching position:

```javascript
    adminAddToChampionsLeague: 'הוספה לליגת האלופות',
    adminRemoveFromChampionsLeague: 'הסרה מליגת האלופות',
    adminUclAddDisabled: 'כבר קיימת ליגה מקומית — לעריכה יש להשתמש בשינוי שם.',
    adminUclRemoveDisabled: 'אין ליגה מקומית רשומה — יש להוסיף אחת דרך שינוי שם קודם.',
```

- [ ] **Step 2: Add the League reassign button**

In `admin.js`'s `renderLeagueGroup` (from Task 6), insert a reassign button between the rename and delete buttons:

```javascript
  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRenameLeague(league, header));
  header.appendChild(renameBtn);

  const reassignBtn = document.createElement('button');
  reassignBtn.type = 'button';
  reassignBtn.textContent = t('adminReassign');
  reassignBtn.addEventListener('click', () => toggleReassignLeagueForm(league, data.leagues, header));
  header.appendChild(reassignBtn);

  const deleteBtn = document.createElement('button');
```

(This replaces the three-line block from `const renameBtn = ...` through `header.appendChild(renameBtn);` followed directly by `const deleteBtn = document.createElement('button');` in Task 6's version — the only change is the new `reassignBtn` block inserted between them.)

- [ ] **Step 3: Add the Club reassign button and the UCL toggle button**

In `admin.js`'s `renderClubRow` (from Task 6), insert a reassign button and the UCL toggle button between the rename and delete buttons:

```javascript
  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRenameClub(club, data, row));
  row.appendChild(renameBtn);

  const reassignBtn = document.createElement('button');
  reassignBtn.type = 'button';
  reassignBtn.textContent = t('adminReassign');
  reassignBtn.addEventListener('click', () => toggleReassignClubForm(club, data, row));
  row.appendChild(reassignBtn);

  row.appendChild(renderUclToggleButton(club, data));

  const deleteBtn = document.createElement('button');
```

(Same replacement shape as Step 2: this is Task 6's `renameBtn` block, immediately followed by the new `reassignBtn` and toggle-button lines, immediately followed by Task 6's existing `const deleteBtn = ...` line.)

- [ ] **Step 4: Add the reassign form builders**

Append to `admin.js`:

```javascript
function toggleReassignLeagueForm(sourceLeague, allLeagues, header) {
  const existing = header.parentElement.querySelector(':scope > .reassign-form');
  if (existing) { existing.remove(); return; }

  const form = document.createElement('div');
  form.className = 'reassign-form';

  const select = document.createElement('select');
  allLeagues.filter(l => l.id !== sourceLeague.id).forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    select.appendChild(opt);
  });
  form.appendChild(select);

  const goBtn = document.createElement('button');
  goBtn.type = 'button';
  goBtn.textContent = t('adminReassignGo');
  form.appendChild(goBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  form.appendChild(errorSpan);

  goBtn.addEventListener('click', async () => {
    if (!select.value) return;
    const targetId = parseInt(select.value, 10);
    errorSpan.textContent = '';

    let countRes;
    try {
      countRes = await adminFetch(`/api/admin/leagues/${sourceLeague.id}/reassign-count?target_id=${targetId}`);
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (countRes === null) return;
    if (!countRes.ok) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    const { count } = await countRes.json();
    const targetLeague = allLeagues.find(l => l.id === targetId);
    if (!confirm(t('adminConfirmReassign').replace('{count}', count).replace('{source}', localizedName(sourceLeague)).replace('{target}', localizedName(targetLeague)))) {
      return;
    }

    let res;
    try {
      res = await adminFetch(`/api/admin/leagues/${sourceLeague.id}/reassign`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_id: targetId }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadedTabs.delete('votes');
    loadTeamsTab();
  });

  header.after(form);
}

function clubLeagueSet(club) {
  return new Set([club.league_id, club.domestic_league_id].filter(v => v !== null && v !== undefined));
}

function toggleReassignClubForm(sourceClub, data, row) {
  const existing = row.parentElement.querySelector(':scope > .reassign-form');
  if (existing) { existing.remove(); return; }

  const sourceSet = clubLeagueSet(sourceClub);
  const eligibleTargets = data.clubs.filter(c => {
    if (c.id === sourceClub.id) return false;
    const targetSet = clubLeagueSet(c);
    return Array.from(sourceSet).every(leagueId => targetSet.has(leagueId));
  });

  const form = document.createElement('div');
  form.className = 'reassign-form';

  const select = document.createElement('select');
  eligibleTargets.forEach(c => {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = localizedName(c);
    select.appendChild(opt);
  });
  form.appendChild(select);

  const goBtn = document.createElement('button');
  goBtn.type = 'button';
  goBtn.textContent = t('adminReassignGo');
  form.appendChild(goBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  form.appendChild(errorSpan);

  goBtn.addEventListener('click', async () => {
    if (!select.value) return;
    const targetId = parseInt(select.value, 10);
    errorSpan.textContent = '';

    let countRes;
    try {
      countRes = await adminFetch(`/api/admin/clubs/${sourceClub.id}/reassign-count?target_id=${targetId}`);
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (countRes === null) return;
    if (!countRes.ok) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    const { count } = await countRes.json();
    const targetClub = data.clubs.find(c => c.id === targetId);
    if (!confirm(t('adminConfirmReassign').replace('{count}', count).replace('{source}', localizedName(sourceClub)).replace('{target}', localizedName(targetClub)))) {
      return;
    }

    let res;
    try {
      res = await adminFetch(`/api/admin/clubs/${sourceClub.id}/reassign`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_id: targetId }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadedTabs.delete('votes');
    loadTeamsTab();
  });

  row.after(form);
}
```

`clubLeagueSet` and the `eligibleTargets` filter are the client-side mirror of Task 3's server-side superset check (decision 3) — the picker only ever offers a valid target, and the server still enforces it independently.

- [ ] **Step 5: Add the UCL toggle button**

Append to `admin.js`:

```javascript
function findChampionsLeague(data) {
  return data.leagues.find(l => l.name_en === 'UEFA Champions League') || null;
}

function renderUclToggleButton(club, data) {
  const ucl = findChampionsLeague(data);
  const btn = document.createElement('button');
  btn.type = 'button';

  if (!ucl) {
    btn.style.display = 'none';
    return btn;
  }

  const inUcl = club.league_id === ucl.id || club.domestic_league_id === ucl.id;

  if (!inUcl) {
    btn.textContent = t('adminAddToChampionsLeague');
    if (club.domestic_league_id !== null && club.domestic_league_id !== undefined) {
      btn.disabled = true;
      btn.title = t('adminUclAddDisabled');
    } else {
      btn.addEventListener('click', () => patchClubLeagues(club, club.league_id, ucl.id));
    }
    return btn;
  }

  btn.textContent = t('adminRemoveFromChampionsLeague');
  if (club.league_id === ucl.id) {
    if (club.domestic_league_id === null || club.domestic_league_id === undefined) {
      btn.disabled = true;
      btn.title = t('adminUclRemoveDisabled');
    } else {
      btn.addEventListener('click', () => patchClubLeagues(club, club.domestic_league_id, null));
    }
  } else {
    btn.addEventListener('click', () => patchClubLeagues(club, club.league_id, null));
  }
  return btn;
}

async function patchClubLeagues(club, newLeagueId, newDomesticLeagueId) {
  let res;
  try {
    res = await adminFetch(`/api/admin/clubs/${club.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        league_id: newLeagueId, domestic_league_id: newDomesticLeagueId,
        name_en: club.name_en, name_he: club.name_he,
      }),
    });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
}
```

This implements decision 13 exactly: **Add** sets `domestic_league_id` to UCL's id (disabled if that slot is already taken by something else); **Remove** clears whichever slot holds UCL — swapping the domestic league into `league_id` and nulling `domestic_league_id` when UCL is the primary slot (disabled if there's no domestic league to fall back to), or simply nulling `domestic_league_id` when UCL was already the secondary slot.

- [ ] **Step 6: Re-render the Teams tab on language change**

In the existing `document.addEventListener('voteball:langchange', ...)` listener at the end of `admin.js`, add a Teams-tab branch (guarding against an open rename/reassign form the same way the party branch above it does, via a simple "any input inside `#league-list`" check since Teams doesn't track per-row open-edit keys the way the party tabs do):

```javascript
  if (optionsData && loadedTabs.has('teams') && !document.querySelector('#league-list input, #league-list .reassign-form')) {
    renderLeagueGroups(optionsData);
  }
```

Add this new `if` block directly after the existing `['previous', 'upcoming'].forEach(...)` block, inside the same listener.

- [ ] **Step 7: Verify manually**

1. On a club with no domestic league, click "Add to UEFA Champions League" — confirm it now appears under both its original league and UEFA Champions League groups.
2. On a UCL club with a domestic league (e.g. Arsenal), click "Remove from UEFA Champions League" — confirm it now appears only under Premier League, and the UCL group no longer lists it.
3. On one of Paris Saint-Germain/Porto/Benfica/Ajax (no domestic league seeded), confirm "Remove from UEFA Champions League" is disabled with a tooltip explaining why; give it a domestic league via Rename, then confirm Remove becomes enabled.
4. Click "Reassign votes…" on a club votable under two leagues — confirm the target dropdown only lists clubs covering both of the source's leagues, cast a vote for the source club first, reassign, and confirm `/api/admin/votes` shows the vote's `club_id` updated and `/api/results?by=club` for the source club drops to zero.
5. Click "Reassign votes…" on a league that still has clubs — confirm the inline error names the blocker; empty the league (delete or reassign its clubs) and confirm Reassign then succeeds.
6. Toggle the language switcher while a reassign form or rename input is open in the Teams tab — confirm the open form is left alone (not clobbered by a re-render), matching the existing party-tab behavior.

- [ ] **Step 8: Commit and push**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/i18n.js ansible-project/roles/frontend/files/nginx/admin.js
git commit -m "Add Teams tab reassign flow and UEFA Champions League toggle buttons

Reassign's target picker mirrors the backend's leagues-superset check
client-side. The UCL toggle is a one-click shortcut over the same
club PATCH route -- add sets domestic_league_id, remove clears
whichever slot holds UCL (swapping the domestic league into the
primary slot when needed), so a club's UCL status can change without
ever deleting the club."
git push
```

---

## Self-Review

**Spec coverage:**
- Decision 1 (scope: leagues + clubs) → Tasks 2, 3.
- Decision 2 (delete-blocked + reassign primitive) → Tasks 2, 3.
- Decision 3 (club reassign superset check) → Task 3 (server), Task 7 (client picker).
- Decisions 4–5 (league delete/reassign needs zero clubs) → Task 2 (`count_clubs_for_league` checks both `league_id` and `domestic_league_id`).
- Decision 6 (bilingual names) → Tasks 2, 3 (routes require `name_en`/`name_he`).
- Decision 7 (global club-name uniqueness) → Task 1 (schema), Task 3 (route/query wiring + test).
- Decision 8 (single Teams tab) → Task 6.
- Decision 9 (reassign UI shape) → Task 7.
- Decision 10 (`domestic_league_id`, dual votability, no rollup changes) → Task 1 (schema), Task 4 (`/api/options`), Task 5 (`vote.js`).
- Decision 11 (always-shown optional Domestic League dropdown) → Task 6 (`renderAddClubForm`, `startRenameClub`).
- Decision 12 (seed dedup + UCL/EPL renames) → Task 1.
- Decision 13 (UCL toggle buttons) → Task 7.

**Placeholder scan:** no TBD/TODO markers; every step has complete, runnable code or an explicit manual-verification checklist (frontend tasks have no automated suite per `CLAUDE.md`, so a checklist is the correct substitute, not a placeholder).

**Type consistency:** `create_club`/`rename_club` take `(conn, league_id, domestic_league_id, name_en, name_he)` consistently across Task 3's query functions, routes, and Task 6/7's JS callers (`league_id`/`domestic_league_id` body keys match exactly). `get_club_leagues` returns `{'league_id', 'domestic_league_id'}` matching what Task 3's reassign route and no other task consumes directly (Task 7's client-side `clubLeagueSet` reads the same two field names off the `/api/options` club objects instead, which Task 4 guarantees have those keys).
