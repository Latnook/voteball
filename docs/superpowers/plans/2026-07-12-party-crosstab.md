# Previous↔Upcoming Party Crosstab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For a selected previous-election party, show what upcoming-election parties those same voters are now considering (and vice versa), computed live from vote data — no static merge/split mapping table.

**Architecture:** A third worker-computed rollup table, `rollup_previous_upcoming(previous_party_id, upcoming_party_id, vote_count)`, global (not sliced by league/club). The worker's existing `recompute()` loop populates it the same way it populates the other two rollups. The backend's existing `get_results_by_party` query function gains a second query against this table and a new `crosstab` key in its return value — no new endpoint. The frontend's existing "start from a party" results panel (which today shows a static placeholder in the panel you didn't search by) renders that `crosstab` data instead.

**Tech Stack:** Flask 3.1, psycopg2, pytest, real Postgres 17 (worker + backend, no mocks); plain JS (frontend, no build step, no automated suite).

## Global Constraints

- Both worker and backend tests run TDD-style against a real Postgres container, not mocks (`docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17`), per `CLAUDE.md`.
- **The worker's `tests/conftest.py` does NOT load the backend's real `schema.sql`** — it hardcodes its own inline `SCHEMA` string (see `ansible-project/roles/worker/files/worker/tests/conftest.py:15-37`). Any new table used by worker code must be added to *both* `ansible-project/roles/backend/files/backend/schema.sql` (the real source of truth, used by the backend and by real deploys) *and* the worker's inline test `SCHEMA` string (or the worker's tests will fail with "relation does not exist" even after the backend's schema.sql is updated). This is pre-existing duplication, not something to unify as part of this plan.
- The crosstab is global — no `league_id`/`club_id` columns on the new table, no league/club filtering anywhere in this feature (explicit spec decision: keep football fandom the primary lens; the crosstab is a lightweight secondary feature).
- No new API endpoint. `GET /api/results?by=party&type=previous|upcoming&id=N` gains a `crosstab` field in its JSON response; the route itself (`app.py`'s `results()`) needs no code change since it already returns whatever `queries.get_results_by_party` produces.
- No static previous→upcoming mapping/lineage table of any kind — the crosstab is computed entirely from the `votes`/`vote_upcoming_parties` tables' actual data, matching the spec's explicit rejection of that approach.
- Frontend has no automated test suite (matches CLAUDE.md's stated frontend testing approach) — verify this task's UI change by driving the real page, or by API-level verification when a full local frontend/backend/worker stack isn't practical in this environment.

---

## Task 1: Rollup table and worker computation

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/schema.sql`
- Modify: `ansible-project/roles/worker/files/worker/rollups.py`
- Modify: `ansible-project/roles/worker/files/worker/tests/conftest.py`
- Modify: `ansible-project/roles/worker/files/worker/tests/test_rollups.py`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `votes(previous_party_id, upcoming_vote_status)` and `vote_upcoming_parties(vote_id, upcoming_party_id)` — both already exist, unchanged.
- Produces: `rollup_previous_upcoming(previous_party_id, upcoming_party_id, vote_count)` table, fully repopulated (via `TRUNCATE` + `INSERT`) on every `rollups.recompute(conn)` call. This is what Task 2's `queries.get_results_by_party` reads from.

- [ ] **Step 1: Write the failing test**

Add to `ansible-project/roles/worker/files/worker/tests/test_rollups.py` (the existing `_seed_votes(conn)` helper at the top of this file already creates exactly the scenario needed — vote 1: voted `party_x` previously, now considering both `party_a` and `party_b`; vote 2: did not vote previously, now undecided — reuse it, don't duplicate it):

```python
def test_recompute_builds_previous_upcoming_crosstab(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id, vote_count FROM rollup_previous_upcoming '
        'ORDER BY previous_party_id NULLS LAST, upcoming_party_id NULLS LAST'
    )
    rows = cur.fetchall()
    cur.close()

    assert (party_x, party_a, 1) in rows
    assert (party_x, party_b, 1) in rows
    assert (None, None, 1) in rows  # did-not-vote AND undecided, from vote 2
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ansible-project/roles/worker/files/worker
python -m pytest tests/test_rollups.py::test_recompute_builds_previous_upcoming_crosstab -v
```

Expected: FAIL with a Postgres error that `rollup_previous_upcoming` does not exist (the table isn't in the worker's test `SCHEMA` string yet).

- [ ] **Step 3: Add the table to the worker's test schema**

In `ansible-project/roles/worker/files/worker/tests/conftest.py`, in the `SCHEMA` string (currently ending with the `rollup_upcoming` table definition on line 36), add a new table definition immediately after it:

```python
CREATE TABLE rollup_previous_upcoming (previous_party_id INTEGER, upcoming_party_id INTEGER, vote_count INTEGER NOT NULL);
```

Also add `rollup_previous_upcoming` to the `DROP TABLE IF EXISTS` list in the `conn` fixture (currently `vote_upcoming_parties, votes, rollup_previous, rollup_upcoming, clubs, leagues, previous_parties, upcoming_parties, alert_state`) so re-running tests doesn't collide with a leftover table from a prior run:

```python
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, votes, rollup_previous,
            rollup_upcoming, rollup_previous_upcoming, clubs, leagues, previous_parties,
            upcoming_parties, alert_state CASCADE
    ''')
```

- [ ] **Step 4: Add the table to the real schema**

In `ansible-project/roles/backend/files/backend/schema.sql`, immediately after the existing `rollup_upcoming` table's index definitions (the block ending `CREATE INDEX IF NOT EXISTS idx_rollup_upcoming_party ON rollup_upcoming (upcoming_party_id);`), add:

```sql

CREATE TABLE IF NOT EXISTS rollup_previous_upcoming (
    previous_party_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_previous ON rollup_previous_upcoming (previous_party_id);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_upcoming ON rollup_previous_upcoming (upcoming_party_id);
```

- [ ] **Step 5: Run the test again to confirm it still fails for the right reason**

```bash
python -m pytest tests/test_rollups.py::test_recompute_builds_previous_upcoming_crosstab -v
```

Expected: FAIL — table now exists but is empty (0 rows), since `rollups.recompute` doesn't populate it yet. The assertion `(party_x, party_a, 1) in rows` should fail because `rows == []`.

- [ ] **Step 6: Implement the recompute logic**

In `ansible-project/roles/worker/files/worker/rollups.py`, add a third block to `recompute(conn)`, after the existing `rollup_upcoming` block (after line 26, before `conn.commit()`):

```python
    cur.execute('TRUNCATE rollup_previous_upcoming')
    cur.execute('''
        INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count)
        SELECT v.previous_party_id, vup.upcoming_party_id, COUNT(*)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.previous_party_id, vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count)
        SELECT previous_party_id, NULL, COUNT(*)
        FROM votes
        WHERE upcoming_vote_status = 'undecided'
        GROUP BY previous_party_id
    ''')
```

The full function should now TRUNCATE+INSERT three tables (`rollup_previous`, `rollup_upcoming`, `rollup_previous_upcoming`) before the single `conn.commit()` at the end — don't add a second commit, follow the existing one-commit-at-the-end shape.

- [ ] **Step 7: Run it to verify it passes**

```bash
python -m pytest tests/test_rollups.py::test_recompute_builds_previous_upcoming_crosstab -v
```

Expected: PASS.

- [ ] **Step 8: Run the full worker suite**

```bash
python -m pytest tests/ -v
```

Expected: all pass, including the pre-existing `test_recompute_builds_previous_and_upcoming_rollups` and `test_recompute_is_idempotent` (idempotency now also covers the new table, since `TRUNCATE` + re-`INSERT` is idempotent by construction — no test change needed there, but confirm it still passes).

- [ ] **Step 9: Update `CLAUDE.md`**

In the `## Architecture` section, change:

```markdown
- **worker** (`ansible-project/roles/worker/files/worker/`) — Python batch/loop process that
  recomputes the `rollup_previous`/`rollup_upcoming` tables from `votes`/`vote_upcoming_parties`, and
  sends milestone SNS alerts.
```

to:

```markdown
- **worker** (`ansible-project/roles/worker/files/worker/`) — Python batch/loop process that
  recomputes the `rollup_previous`/`rollup_upcoming`/`rollup_previous_upcoming` tables from
  `votes`/`vote_upcoming_parties`, and sends milestone SNS alerts.
```

and change:

```markdown
Postgres (RDS) stores: static seed data (`leagues`, `clubs`, `previous_parties`, `upcoming_parties` —
the two party tables are also admin-editable after seeding), raw votes (`votes`,
`vote_upcoming_parties`), and worker-computed rollup tables (`rollup_previous`, `rollup_upcoming`) that
the backend reads for fast `/api/results` responses.
```

to:

```markdown
Postgres (RDS) stores: static seed data (`leagues`, `clubs`, `previous_parties`, `upcoming_parties` —
the two party tables are also admin-editable after seeding), raw votes (`votes`,
`vote_upcoming_parties`), and worker-computed rollup tables (`rollup_previous`, `rollup_upcoming`,
`rollup_previous_upcoming`) that the backend reads for fast `/api/results` responses.
```

- [ ] **Step 10: Commit**

```bash
git add ansible-project/roles/backend/files/backend/schema.sql \
        ansible-project/roles/worker/files/worker/rollups.py \
        ansible-project/roles/worker/files/worker/tests/conftest.py \
        ansible-project/roles/worker/files/worker/tests/test_rollups.py \
        CLAUDE.md
git commit -m "Add rollup_previous_upcoming crosstab table, computed by the worker"
git push
```

---

## Task 2: Backend crosstab in get_results_by_party

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_queries.py`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `rollup_previous_upcoming(previous_party_id, upcoming_party_id, vote_count)` from Task 1.
- Produces: `queries.get_results_by_party(conn, party_type, party_id)` now returns
  `{'breakdown': [...], 'crosstab': [...]}` (previously just `{'breakdown': [...]}`). For
  `party_type='previous'`, each `crosstab` row is `{'upcoming_party_id': int|None, 'count': int}`.
  For `party_type='upcoming'`, each `crosstab` row is `{'previous_party_id': int|None, 'count': int}`.
  This is what Task 3's frontend change reads.

- [ ] **Step 1: Write the failing tests**

Add to `ansible-project/roles/backend/files/backend/tests/test_queries.py` (reuse the existing
`_seed_rollup_rows(conn)` helper, which creates `party_x` in `previous_parties` with rollup rows
already present — don't duplicate its setup):

```python
def test_get_results_by_party_previous_includes_crosstab(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, party_a, 5)
    )
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, None, 2)
    )
    conn.commit()
    cur.close()

    result = queries.get_results_by_party(conn, 'previous', party_x)
    crosstab = {row['upcoming_party_id']: row['count'] for row in result['crosstab']}
    assert crosstab[party_a] == 5
    assert crosstab[None] == 2


def test_get_results_by_party_upcoming_includes_crosstab(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, party_a, 5)
    )
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (None, party_a, 4)
    )
    conn.commit()
    cur.close()

    result = queries.get_results_by_party(conn, 'upcoming', party_a)
    crosstab = {row['previous_party_id']: row['count'] for row in result['crosstab']}
    assert crosstab[party_x] == 5
    assert crosstab[None] == 4


def test_get_results_by_party_crosstab_empty_when_no_data(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    result = queries.get_results_by_party(conn, 'previous', party_x)
    assert result['crosstab'] == []
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/test_queries.py::test_get_results_by_party_previous_includes_crosstab tests/test_queries.py::test_get_results_by_party_upcoming_includes_crosstab tests/test_queries.py::test_get_results_by_party_crosstab_empty_when_no_data -v
```

Expected: FAIL — `test_get_results_by_party_crosstab_empty_when_no_data` fails with `KeyError: 'crosstab'`; the other two fail earlier still (`rollup_previous_upcoming` may not exist yet in this database if Task 1 hasn't been run against it — if so, expect a relation-does-not-exist error instead; either is an acceptable RED for this step).

- [ ] **Step 3: Implement the crosstab query**

In `ansible-project/roles/backend/files/backend/queries.py`, replace `get_results_by_party`:

```python
def get_results_by_party(conn, party_type, party_id):
    table = 'rollup_previous' if party_type == 'previous' else 'rollup_upcoming'
    column = 'previous_party_id' if party_type == 'previous' else 'upcoming_party_id'

    cur = conn.cursor()
    cur.execute(
        f'SELECT league_id, club_id, SUM(vote_count) FROM {table} '
        f'WHERE {column} = %s GROUP BY league_id, club_id',
        (party_id,)
    )
    breakdown = [{'league_id': r[0], 'club_id': r[1], 'count': r[2]} for r in cur.fetchall()]
    cur.close()
    return {'breakdown': breakdown}
```

with:

```python
def get_results_by_party(conn, party_type, party_id):
    table = 'rollup_previous' if party_type == 'previous' else 'rollup_upcoming'
    column = 'previous_party_id' if party_type == 'previous' else 'upcoming_party_id'
    other_column = 'upcoming_party_id' if party_type == 'previous' else 'previous_party_id'

    cur = conn.cursor()
    cur.execute(
        f'SELECT league_id, club_id, SUM(vote_count) FROM {table} '
        f'WHERE {column} = %s GROUP BY league_id, club_id',
        (party_id,)
    )
    breakdown = [{'league_id': r[0], 'club_id': r[1], 'count': r[2]} for r in cur.fetchall()]

    cur.execute(
        f'SELECT {other_column}, SUM(vote_count) FROM rollup_previous_upcoming '
        f'WHERE {column} = %s GROUP BY {other_column}',
        (party_id,)
    )
    crosstab = [{other_column: r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.close()
    return {'breakdown': breakdown, 'crosstab': crosstab}
```

(`party_type` is already constrained to the literals `'previous'`/`'upcoming'` by `app.py`'s
`results()` route before this function is ever called — see the existing `if party_type not in
('previous', 'upcoming'): return 400` check — so `column`/`table`/`other_column` are never
attacker-influenced strings, matching the safety of the pre-existing `table`/`column`
f-string usage two lines above.)

- [ ] **Step 4: Run it to verify it passes**

```bash
python -m pytest tests/test_queries.py::test_get_results_by_party_previous_includes_crosstab tests/test_queries.py::test_get_results_by_party_upcoming_includes_crosstab tests/test_queries.py::test_get_results_by_party_crosstab_empty_when_no_data -v
```

Expected: PASS.

- [ ] **Step 5: Run the full backend suite**

```bash
python -m pytest tests/ -v
```

Expected: all pass, including the pre-existing `test_get_results_by_party_previous` (still checks
only `result['breakdown']`, unaffected by the new `crosstab` key).

- [ ] **Step 6: Update `CLAUDE.md`'s API surface table**

In `CLAUDE.md`, in the `### API surface` table, change:

```markdown
| `/api/results` | GET | none | `?by=club\|league\|id=N` or `?by=party&type=previous\|upcoming&id=N`; reads the worker-computed rollup tables |
```

to:

```markdown
| `/api/results` | GET | none | `?by=club\|league\|id=N` or `?by=party&type=previous\|upcoming&id=N` (the latter also returns a global `crosstab` of the other party type); reads the worker-computed rollup tables |
```

- [ ] **Step 7: Commit**

```bash
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py \
        CLAUDE.md
git commit -m "Return previous<->upcoming crosstab from get_results_by_party"
git push
```

---

## Task 3: Frontend — render the crosstab in the existing party-results panel

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/results.js`

**Interfaces:**
- Consumes: `GET /api/results?by=party&type=previous|upcoming&id=N` now returning a `crosstab`
  array from Task 2, shaped `[{upcoming_party_id, count}, ...]` (when `type=previous`) or
  `[{previous_party_id, count}, ...]` (when `type=upcoming`).
- Produces: no new interface — this is the final consumer in the chain.

- [ ] **Step 1: Replace the static placeholder with a real render**

In `ansible-project/roles/frontend/files/nginx/results.js`, replace the `loadResultsByParty`
function (currently lines 83-103):

```javascript
async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';

  let data;
  try {
    const res = await fetch(`/api/results?by=party&type=${partyType}&id=${partyId}`);
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    data = await res.json();
  } catch (err) {
    showResultsError([targetId]);
    return;
  }

  document.getElementById(otherId).innerHTML = '<p>Switch party type to see this breakdown.</p>';
  renderBars(targetId, data.breakdown.map(r => ({ count: r.count, club_id: r.club_id, league_id: r.league_id })), clubOrLeagueName);
}
```

with:

```javascript
async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';
  const otherNameLookup = partyType === 'previous' ? upcomingPartyName : previousPartyName;
  const otherKey = partyType === 'previous' ? 'upcoming_party_id' : 'previous_party_id';

  let data;
  try {
    const res = await fetch(`/api/results?by=party&type=${partyType}&id=${partyId}`);
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    data = await res.json();
  } catch (err) {
    showResultsError([targetId, otherId]);
    return;
  }

  renderBars(targetId, data.breakdown.map(r => ({ count: r.count, club_id: r.club_id, league_id: r.league_id })), clubOrLeagueName);
  renderBars(otherId, data.crosstab.map(r => ({ count: r.count, key: r[otherKey] })), r => otherNameLookup(r.key));
}
```

Note `otherKey` matches Task 2's dict key naming exactly (`other_column` in `queries.py`), and
`otherNameLookup` reuses the existing `previousPartyName`/`upcomingPartyName` functions already
defined earlier in this file (lines 36-46) — no new name-lookup logic needed, and `null` party ids
already render as `'Did not vote'`/`'Undecided'` via those functions' existing `id === null` checks.

- [ ] **Step 2: Verify via the API directly (no automated frontend suite exists for this project)**

Start the backend against the test Postgres container, seed a vote with a known previous/upcoming
pairing, run the worker's `recompute` once by hand, then confirm the JSON shape:

```bash
cd ansible-project/roles/backend/files/backend
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable ADMIN_SECRET=test-admin-secret \
  SNS_TOPIC=arn:aws:sns:il-central-1:000000000000:test AWS_REGION=il-central-1 \
  python -c "import db; conn = db.get_db(); db.init_db(conn); conn.close()"

DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable ADMIN_SECRET=test-admin-secret \
  SNS_TOPIC=arn:aws:sns:il-central-1:000000000000:test AWS_REGION=il-central-1 \
  python app.py &

curl -s "http://localhost:5000/api/options" | python -m json.tool | head -20
```

Pick a real `previous_parties` id and `upcoming_parties` id from that output, cast a vote via
`POST /api/vote` with those ids (`previous_vote_status=voted`, `upcoming_vote_status=considering`),
then run the worker's recompute directly against the same database:

```bash
cd ../../../worker/files/worker
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -c "import db, rollups; conn = db.get_db(); rollups.recompute(conn); conn.close()"
```

Then re-fetch `curl -s "http://localhost:5000/api/results?by=party&type=previous&id=<the id you voted with>"`
and confirm the response now has a non-empty `crosstab` array containing the upcoming party id you
voted for. Kill the backend dev server (`kill %1` or equivalent) when done.

If a browser is available in this environment, also open `results.html` against a locally-proxied
backend, switch to "start from a party," pick the previous party you voted with, and visually
confirm the previously-static second panel now shows a bar for the upcoming party. If no browser is
available, the curl-level verification above plus the fact that `renderBars`/`previousPartyName`/
`upcomingPartyName` are pre-existing, already-exercised functions is sufficient — note in your report
whether you were able to do the visual check.

- [ ] **Step 3: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/results.js
git commit -m "Render the previous<->upcoming crosstab in the party-results panel"
git push
```

---

## Final verification

```bash
cd ansible-project/roles/worker/files/worker && python -m pytest tests/ -v
cd ../../../backend/files/backend && python -m pytest tests/ -v
```

Expected: both suites fully green. Spot-check `helm template voteball charts/voteball --namespace
voteball-app` still renders cleanly (no chart changes in this plan, but confirms nothing was
accidentally broken) if convenient — not required.
