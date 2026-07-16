# Party Categorization, Lineage & Fan Politics Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-party ideology categorization, a previous↔upcoming party lineage map, a per-voter
vote-switch classification, and a new "Fan Politics" results-page section (Diversity / Political Lean
/ Switching tabs) to Voteball.

**Architecture:** Postgres schema additions (ideology columns on `previous_parties`/`upcoming_parties`,
new `party_lineage` and rollup tables) → worker computes the new switch-status rollup every cycle →
backend exposes ideology/lineage via `/api/options` plus two new read endpoints → frontend
`analytics.js` aggregates client-side into three new tabs on `results.html`.

**Tech Stack:** Flask 3.1 + psycopg2 (backend), plain Python + psycopg2 (worker), vanilla JS/HTML/CSS,
no build step (frontend), pytest against real Postgres (all tests).

## Global Constraints

- Region/AZ, resource naming, non-root containers, `sslmode=require` in production: unaffected by this
  plan (no infra changes).
- Every route acquires its own connection via `db.get_db()` and closes it in `try/finally`.
- Mutating query functions roll back broadly (`except Exception: conn.rollback(); raise`), not just on
  the one expected constraint error.
- Every backend-derived name renders via `createElement`/`textContent`, never `innerHTML` string
  interpolation.
- Any new frontend `.js` file must be added to `ansible-project/roles/frontend/files/nginx/Dockerfile`'s
  `COPY` line, or it 404s at runtime with no build error.
- Backend/worker tests run TDD-style against a real Postgres (`voteball-test-db` container), never
  mocks.
- `tests/conftest.py`'s `conn` fixture `DROP TABLE ... CASCADE` list (both backend and worker) must stay
  in sync with every new table added to schema.sql or the worker's own hand-rolled test schema.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible-project/roles/backend/files/backend/schema.sql` | Modify: ideology columns, `party_lineage`, `rollup_vote_switch`, `rollup_national_vote_switch` |
| `ansible-project/roles/backend/files/backend/seed.sql` | Modify: classification data + lineage rows |
| `ansible-project/roles/backend/files/backend/queries.py` | Modify: `get_options` extension, `get_party_lineage`, `get_results_switch`, `get_clubs_breakdown` |
| `ansible-project/roles/backend/files/backend/app.py` | Modify: two new routes |
| `ansible-project/roles/backend/files/backend/tests/conftest.py` | Modify: DROP TABLE list |
| `ansible-project/roles/backend/files/backend/tests/test_app.py`, `test_queries.py`, `test_migration.py` | Modify: new tests |
| `ansible-project/roles/worker/files/worker/rollups.py` | Modify: `_recompute_vote_switch` |
| `ansible-project/roles/worker/files/worker/tests/conftest.py` | Modify: hand-rolled SCHEMA + DROP list |
| `ansible-project/roles/worker/files/worker/tests/test_rollups.py` | Modify: new tests |
| `ansible-project/roles/frontend/files/nginx/results.html` | Modify: new Fan Politics section |
| `ansible-project/roles/frontend/files/nginx/analytics.js` | **Create**: all Fan Politics tab logic |
| `ansible-project/roles/frontend/files/nginx/i18n.js` | Modify: new dictionary keys |
| `ansible-project/roles/frontend/files/nginx/style.css` | Modify: new classes for the strip/bars |
| `ansible-project/roles/frontend/files/nginx/Dockerfile` | Modify: add `analytics.js` to COPY line |

---

### Task 1: Schema — ideology columns, `party_lineage`, switch rollup tables

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/schema.sql`
- Modify: `ansible-project/roles/backend/files/backend/tests/conftest.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_migration.py`

**Interfaces:**
- Produces: columns `bloc, economic, security, sector, tags` on `previous_parties`/`upcoming_parties`;
  tables `party_lineage(previous_party_id, upcoming_party_id)`, `rollup_vote_switch(league_id, club_id,
  switch_status, vote_count)`, `rollup_national_vote_switch(switch_status, vote_count)`.

- [ ] **Step 1: Write a failing test asserting the new columns/tables exist and enforce their CHECK constraints**

Append to `ansible-project/roles/backend/files/backend/tests/test_migration.py`:

```python
def test_party_ideology_columns_and_lineage_table_exist(conn):
    cur = conn.cursor()
    cur.execute('''
        UPDATE previous_parties SET bloc = 'bibi', economic = 2, security = 2,
            sector = 'traditional', tags = ARRAY['test-tag']
        WHERE name = 'הליכוד'
    ''')
    cur.execute("SELECT bloc, economic, security, sector, tags FROM previous_parties WHERE name = 'הליכוד'")
    row = cur.fetchone()
    assert row == ('bibi', 2, 2, 'traditional', ['test-tag'])

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE previous_parties SET bloc = 'not-a-real-bloc' WHERE name = 'הליכוד'")
    conn.rollback()

    cur.execute("SELECT id FROM previous_parties WHERE name = 'הליכוד'")
    prev_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties WHERE name = 'הליכוד'")
    up_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_id, up_id)
    )
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id FROM party_lineage WHERE previous_party_id = %s',
        (prev_id,)
    )
    assert cur.fetchone() == (prev_id, up_id)
    conn.commit()
    cur.close()


def test_vote_switch_rollup_tables_exist(conn):
    cur = conn.cursor()
    cur.execute('''
        INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count)
        VALUES (NULL, NULL, 'stayed', 5)
    ''')
    cur.execute('''
        INSERT INTO rollup_national_vote_switch (switch_status, vote_count)
        VALUES ('stayed', 5)
    ''')
    conn.commit()
    cur.execute('SELECT switch_status, vote_count FROM rollup_national_vote_switch')
    assert cur.fetchone() == ('stayed', 5)

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (NULL, NULL, 'not-a-real-status', 1)")
    conn.rollback()
    cur.close()
```

Check the top of `test_migration.py` already imports `pytest` and `psycopg2` — if not, add:

```python
import pytest
import psycopg2
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ansible-project/roles/backend/files/backend && source .venv/bin/activate && python -m pytest tests/test_migration.py::test_party_ideology_columns_and_lineage_table_exist tests/test_migration.py::test_vote_switch_rollup_tables_exist -v`
Expected: FAIL — `column "bloc" of relation "previous_parties" does not exist` (first test) and
`relation "rollup_vote_switch" does not exist` (second test).

- [ ] **Step 3: Add the schema changes**

In `ansible-project/roles/backend/files/backend/schema.sql`, find this block (added in the Phase 1
quick-wins plan):

```sql
-- Explicit display ordering for leagues (e.g. pinning the Israeli Premier League first). Nullable
-- so unranked leagues fall back to alphabetical (see get_options's ORDER BY sort_order NULLS LAST).
ALTER TABLE leagues ADD COLUMN IF NOT EXISTS sort_order INTEGER;
```

Append immediately after it:

```sql

-- Party ideology categorization (docs/superpowers/specs/2026-07-16-party-categorization-analytics-design.md).
-- Independent columns on both tables, not shared through party_lineage below -- a split/merged party
-- can be ideologically distinct from its lineage predecessor (e.g. Otzma Yehudit vs. Religious
-- Zionist). economic/security are nullable: several real parties genuinely have no stated position
-- (rather than a fabricated "0" implying a confirmed centrist stance).
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS bloc TEXT
    CHECK (bloc IN ('bibi', 'opposition', 'unaligned'));
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS economic INTEGER
    CHECK (economic BETWEEN -3 AND 3);
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS security INTEGER
    CHECK (security BETWEEN -3 AND 3);
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS sector TEXT
    CHECK (sector IN ('secular', 'traditional', 'religious_zionist', 'haredi', 'arab'));
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS tags TEXT[];

ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS bloc TEXT
    CHECK (bloc IN ('bibi', 'opposition', 'unaligned'));
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS economic INTEGER
    CHECK (economic BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS security INTEGER
    CHECK (security BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS sector TEXT
    CHECK (sector IN ('secular', 'traditional', 'religious_zionist', 'haredi', 'arab'));
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS tags TEXT[];

-- Continuity, independent of ideology: which upcoming party continues which previous party. A split
-- is multiple rows sharing one previous_party_id; a merge is multiple rows sharing one
-- upcoming_party_id; a party with no row on either side is a genuine dead end or a fresh entrant.
CREATE TABLE IF NOT EXISTS party_lineage (
    previous_party_id INTEGER NOT NULL REFERENCES previous_parties(id),
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id),
    PRIMARY KEY (previous_party_id, upcoming_party_id)
);

-- Per-voter vote-switch classification (worker-computed, same league/club/national scoping pattern
-- as the existing rollup_previous/rollup_national_previous tables).
CREATE TABLE IF NOT EXISTS rollup_vote_switch (
    league_id INTEGER,
    club_id INTEGER,
    switch_status TEXT NOT NULL CHECK (switch_status IN
        ('new_voter', 'undecided', 'stayed', 'hedging', 'switched')),
    vote_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rollup_national_vote_switch (
    switch_status TEXT NOT NULL CHECK (switch_status IN
        ('new_voter', 'undecided', 'stayed', 'hedging', 'switched')),
    vote_count INTEGER NOT NULL
);
```

- [ ] **Step 4: Update the backend test fixture's DROP TABLE list**

In `ansible-project/roles/backend/files/backend/tests/conftest.py`, the `conn` fixture currently runs:

```python
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, vote_clubs, vote_leagues, votes,
            rollup_previous, rollup_upcoming, rollup_previous_upcoming,
            rollup_national_previous, rollup_national_upcoming, rollup_national_previous_upcoming,
            clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE
    ''')
```

Replace it with (new tables added, `party_lineage` listed before the party tables it references so the
`CASCADE` ordering is irrelevant either way, but placed logically):

```python
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, vote_clubs, vote_leagues, votes,
            rollup_previous, rollup_upcoming, rollup_previous_upcoming,
            rollup_national_previous, rollup_national_upcoming, rollup_national_previous_upcoming,
            rollup_vote_switch, rollup_national_vote_switch, party_lineage,
            clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE
    ''')
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_migration.py::test_party_ideology_columns_and_lineage_table_exist tests/test_migration.py::test_vote_switch_rollup_tables_exist -v`
Expected: PASS

- [ ] **Step 6: Run the full backend suite to confirm nothing else broke**

Run: `python -m pytest tests/ -v`
Expected: all PASS (110 existing + 2 new = 112)

- [ ] **Step 7: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/schema.sql \
        ansible-project/roles/backend/files/backend/tests/conftest.py \
        ansible-project/roles/backend/files/backend/tests/test_migration.py
git commit -m "Add party ideology columns, party_lineage, and vote-switch rollup tables"
```

---

### Task 2: Seed data — party classification and lineage

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/seed.sql`
- Test: `ansible-project/roles/backend/files/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: columns/tables from Task 1.
- Produces: every previous/upcoming party (except "Other") has non-null `bloc`/`sector`; 13
  `party_lineage` rows exist.

- [ ] **Step 1: Write a failing test for the seeded classification data**

Append to `ansible-project/roles/backend/files/backend/tests/test_migration.py`:

```python
def test_seeded_parties_have_ideology_classification(conn):
    cur = conn.cursor()
    cur.execute("SELECT name_en, bloc, sector FROM previous_parties WHERE name_he != 'אחר'")
    for name_en, bloc, sector in cur.fetchall():
        assert bloc is not None, f'{name_en} (previous) missing bloc'
        assert sector is not None, f'{name_en} (previous) missing sector'

    cur.execute("SELECT bloc, economic, security, sector FROM previous_parties WHERE name_he = 'אחר'")
    assert cur.fetchone() == (None, None, None, None)

    cur.execute('SELECT name_en, bloc, sector FROM upcoming_parties')
    for name_en, bloc, sector in cur.fetchall():
        assert bloc is not None, f'{name_en} (upcoming) missing bloc'
        assert sector is not None, f'{name_en} (upcoming) missing sector'

    cur.execute("SELECT economic, security, tags FROM previous_parties WHERE name_he = 'המחנה הממלכתי'")
    economic, security, tags = cur.fetchone()
    assert economic == 1
    assert security is None
    assert 'avoids-security-topic' in tags
    cur.close()


def test_seeded_party_lineage(conn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM party_lineage')
    assert cur.fetchone()[0] == 13

    cur.execute('''
        SELECT u.name_en FROM party_lineage pl
        JOIN previous_parties p ON p.id = pl.previous_party_id
        JOIN upcoming_parties u ON u.id = pl.upcoming_party_id
        WHERE p.name_he = 'הציונות הדתית'
        ORDER BY u.name_en
    ''')
    successors = {r[0] for r in cur.fetchall()}
    assert successors == {'Otzma Yehudit', 'Religious Zionist Party'}

    cur.execute('''
        SELECT p.name_en FROM party_lineage pl
        JOIN previous_parties p ON p.id = pl.previous_party_id
        JOIN upcoming_parties u ON u.id = pl.upcoming_party_id
        WHERE u.name_he = 'הדמוקרטים'
        ORDER BY p.name_en
    ''')
    predecessors = {r[0] for r in cur.fetchall()}
    assert predecessors == {'Labor', 'Meretz'}
    cur.close()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_migration.py::test_seeded_parties_have_ideology_classification tests/test_migration.py::test_seeded_party_lineage -v`
Expected: FAIL — assertion errors (`bloc is None`, lineage count `0 != 13`).

- [ ] **Step 3: Add the classification data to seed.sql**

In `ansible-project/roles/backend/files/backend/seed.sql`, find the "Admin-curated party logos"
section end (the block of `UPDATE previous_parties SET logo_url = ...` statements, ending with the
Balad logo line) and insert this new block immediately after it, before the `-- Upcoming election
parties` comment:

```sql
-- Party ideology classification (docs/superpowers/specs/2026-07-16-party-categorization-analytics-design.md
-- Appendix). Provisional: platforms aren't fully released and more splits/merges may happen before
-- candidate lists lock -- revise via this file + scripts/sync-seed-from-rds.sh as needed.
UPDATE previous_parties SET bloc = 'bibi', economic = 1, security = 2, sector = 'traditional',
    tags = ARRAY['claims-economically-liberal', 'populist', 'nationalist']
    WHERE name_he = 'הליכוד' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = 0, security = 0, sector = 'secular',
    tags = ARRAY['liberal-zionist', 'centrist']
    WHERE name_he = 'יש עתיד' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right']
    WHERE name_he = 'הציונות הדתית' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'unaligned', economic = 1, security = NULL, sector = 'secular',
    tags = ARRAY['centrist', 'avoids-security-topic', 'leans-traditional']
    WHERE name_he = 'המחנה הממלכתי' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = 2, security = 2, sector = 'secular',
    tags = ARRAY['anti-clerical', 'revisionist-zionist']
    WHERE name_he = 'ישראל ביתנו' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'ש"ס' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'יהדות התורה' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = 0, security = NULL, sector = 'arab',
    tags = ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues']
    WHERE name_he = 'רע"ם' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -3, security = -2, sector = 'arab',
    tags = ARRAY['communist', 'arab-nationalist', 'pro-two-state']
    WHERE name_he = 'חד"ש-תע"ל' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['social-democrat']
    WHERE name_he = 'העבודה' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['social-democrat']
    WHERE name_he = 'מרצ' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -2, security = -3, sector = 'arab',
    tags = ARRAY['palestinian-nationalist', 'non-zionist']
    WHERE name_he = 'בל"ד' AND bloc IS NULL;
-- 'אחר' (Other) intentionally left fully NULL -- it is a catch-all, not a real party with ideology.
```

Immediately after the existing `-- Admin-curated party logos, synced from the live RDS instance (see
previous_parties above).` block for `upcoming_parties` (the block ending with the El HaDegel logo
line), insert:

```sql
-- Party ideology classification for upcoming_parties -- independent from previous_parties even where
-- a lineage link exists (see party_lineage below and design spec Decision 1).
UPDATE upcoming_parties SET bloc = 'bibi', economic = 1, security = 2, sector = 'traditional',
    tags = ARRAY['claims-economically-liberal', 'populist', 'nationalist']
    WHERE name_he = 'הליכוד' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 0, security = 0, sector = 'secular',
    tags = ARRAY['new-party', 'undefined-ideology']
    WHERE name_he = 'ישר' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 1, security = NULL, sector = 'secular',
    tags = ARRAY['liberal-zionist', 'constitutionalist', 'avoids-security-topic']
    WHERE name_he = 'ביחד' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['progressive', 'social-democrat', 'liberal-zionist']
    WHERE name_he = 'הדמוקרטים' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 0, security = 0, sector = 'secular',
    tags = ARRAY['centrist', 'hard-to-classify-bloc']
    WHERE name_he = 'כחול לבן' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 2, security = 2, sector = 'secular',
    tags = ARRAY['anti-clerical', 'revisionist-zionist']
    WHERE name_he = 'ישראל ביתנו' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right']
    WHERE name_he = 'הציונות הדתית' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'kahanist', 'jewish-supremacist', 'far-right']
    WHERE name_he = 'עוצמה יהודית' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = -3, security = -2, sector = 'arab',
    tags = ARRAY['communist', 'arab-nationalist', 'pro-two-state']
    WHERE name_he = 'חד"ש-תע"ל' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = -2, security = -3, sector = 'arab',
    tags = ARRAY['palestinian-nationalist', 'non-zionist']
    WHERE name_he = 'בל"ד' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 0, security = NULL, sector = 'arab',
    tags = ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues']
    WHERE name_he = 'רע"ם' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'ש"ס' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'יהדות התורה' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['populist', 'anti-corruption', 'anti-clerical']
    WHERE name_he = 'המפלגה הכלכלית' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['reservist-focused', 'anti-conscription-exemption']
    WHERE name_he = 'אל הדגל' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['reservist-focused', 'anti-conscription-exemption']
    WHERE name_he = 'המילואימניקים' AND bloc IS NULL;

-- Party lineage: continuity between previous and upcoming parties (identity, splits, merges).
-- See design spec Appendix -- Yashar, The Economic Party, El HaDegel, The Reservists, and Blue and
-- White (as an independent brand) have no seeded predecessor; 'אחר' has no successor.
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הליכוד' AND u.name_he = 'הליכוד'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'יש עתיד' AND u.name_he = 'ביחד'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הציונות הדתית' AND u.name_he = 'הציונות הדתית'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הציונות הדתית' AND u.name_he = 'עוצמה יהודית'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'המחנה הממלכתי' AND u.name_he = 'כחול לבן'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'ישראל ביתנו' AND u.name_he = 'ישראל ביתנו'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'ש"ס' AND u.name_he = 'ש"ס'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'יהדות התורה' AND u.name_he = 'יהדות התורה'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'רע"ם' AND u.name_he = 'רע"ם'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'חד"ש-תע"ל' AND u.name_he = 'חד"ש-תע"ל'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'העבודה' AND u.name_he = 'הדמוקרטים'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'מרצ' AND u.name_he = 'הדמוקרטים'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'בל"ד' AND u.name_he = 'בל"ד'
ON CONFLICT DO NOTHING;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_migration.py -v`
Expected: all PASS, including the two new tests.

- [ ] **Step 5: Run the full backend suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/seed.sql \
        ansible-project/roles/backend/files/backend/tests/test_migration.py
git commit -m "Seed party ideology classification and lineage data"
```

---

### Task 3: `queries.py` — expose ideology + lineage via `get_options`

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: `bloc, economic, security, sector, tags` columns and `party_lineage` table (Task 1/2).
- Produces: `get_options(conn)` return dict gains `party_lineage: [{previous_party_id, upcoming_party_id}]`;
  each `previous_parties`/`upcoming_parties` entry gains `bloc, economic, security, sector, tags`.
  New `get_party_lineage(conn) -> list[dict]`.

- [ ] **Step 1: Write the failing test**

In `ansible-project/roles/backend/files/backend/tests/test_queries.py`, find `test_get_options`
(the function containing `previous_names_en = {p['name_en'] for p in options['previous_parties']}`).
Add this new test right after it:

```python
def test_get_options_exposes_ideology_and_lineage(conn):
    cur = conn.cursor()
    cur.execute('''
        UPDATE previous_parties SET bloc = 'bibi', economic = 1, security = 2,
            sector = 'traditional', tags = ARRAY['a', 'b']
        WHERE name_he = 'הליכוד'
    ''')
    cur.execute("SELECT id FROM previous_parties WHERE name_he = 'הליכוד'")
    prev_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties WHERE name_he = 'הליכוד'")
    up_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_id, up_id)
    )
    conn.commit()
    cur.close()

    options = queries.get_options(conn)

    likud = next(p for p in options['previous_parties'] if p['id'] == prev_id)
    assert likud['bloc'] == 'bibi'
    assert likud['economic'] == 1
    assert likud['security'] == 2
    assert likud['sector'] == 'traditional'
    assert likud['tags'] == ['a', 'b']

    assert 'party_lineage' in options
    assert {'previous_party_id': prev_id, 'upcoming_party_id': up_id} in options['party_lineage']
```

Confirm the file already has `import queries` near the top (it does, per every existing test in this
file calling `queries.get_options`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `python -m pytest tests/test_queries.py::test_get_options_exposes_ideology_and_lineage -v`
Expected: FAIL — `KeyError: 'bloc'`.

- [ ] **Step 3: Implement**

In `ansible-project/roles/backend/files/backend/queries.py`, replace the `get_options` function body
(from `def get_options(conn):` through its `return` statement) with:

```python
def get_options(conn):
    cur = conn.cursor()

    cur.execute('SELECT id, name_en, name_he, logo_url FROM leagues ORDER BY sort_order NULLS LAST, name_en')
    leagues = [{'id': r[0], 'name_en': r[1], 'name_he': r[2], 'logo_url': r[3]} for r in cur.fetchall()]

    cur.execute(
        'SELECT id, league_id, domestic_league_id, name_en, name_he, logo_url FROM clubs ORDER BY name_en'
    )
    clubs = [
        {
            'id': r[0], 'league_id': r[1], 'domestic_league_id': r[2],
            'name_en': r[3], 'name_he': r[4], 'logo_url': r[5],
        }
        for r in cur.fetchall()
    ]

    cur.execute(
        'SELECT id, name_en, name_he, logo_url, bloc, economic, security, sector, tags '
        'FROM previous_parties ORDER BY name_en'
    )
    previous_parties = [
        {
            'id': r[0], 'name_en': r[1], 'name_he': r[2], 'logo_url': r[3],
            'bloc': r[4], 'economic': r[5], 'security': r[6], 'sector': r[7], 'tags': r[8] or [],
        }
        for r in cur.fetchall()
    ]

    cur.execute(
        'SELECT id, name_en, name_he, logo_url, bloc, economic, security, sector, tags '
        'FROM upcoming_parties ORDER BY name_en'
    )
    upcoming_parties = [
        {
            'id': r[0], 'name_en': r[1], 'name_he': r[2], 'logo_url': r[3],
            'bloc': r[4], 'economic': r[5], 'security': r[6], 'sector': r[7], 'tags': r[8] or [],
        }
        for r in cur.fetchall()
    ]

    cur.close()
    return {
        'leagues': leagues,
        'clubs': clubs,
        'previous_parties': previous_parties,
        'upcoming_parties': upcoming_parties,
        'party_lineage': get_party_lineage(conn),
    }


def get_party_lineage(conn):
    cur = conn.cursor()
    cur.execute('SELECT previous_party_id, upcoming_party_id FROM party_lineage')
    rows = [{'previous_party_id': r[0], 'upcoming_party_id': r[1]} for r in cur.fetchall()]
    cur.close()
    return rows
```

(This replaces the `ORDER BY name_en` on leagues with the `sort_order NULLS LAST, name_en` from the
Phase 1 plan — confirm that's already the case in the current file; if the current file still says
`ORDER BY name_en` for leagues, this step also fixes that. If it already says `sort_order NULLS LAST,
name_en`, leave it as shown above — no change needed there.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `python -m pytest tests/test_queries.py::test_get_options_exposes_ideology_and_lineage -v`
Expected: PASS

- [ ] **Step 5: Run the full backend suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS (the existing `test_get_options`/`test_get_options_returns_seeded_leagues` tests
must still pass unchanged — they don't assert on `bloc`/`tags` so adding fields doesn't break them).

- [ ] **Step 6: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py
git commit -m "Expose party ideology and lineage via GET /api/options"
```

---

### Task 4: `queries.py` — `get_results_switch` and `get_clubs_breakdown`

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: `rollup_vote_switch`/`rollup_national_vote_switch` (Task 1, populated by Task 6's worker
  logic — this task's tests insert rows directly, since the worker isn't wired yet); `rollup_previous`
  (existing table).
- Produces: `get_results_switch(conn, league_id=None, club_id=None) -> {'breakdown': [{'status': str, 'count': int}, ...]}`;
  `get_clubs_breakdown(conn) -> [{'club_id': int, 'previous': [{'party_id': int, 'count': int}, ...]}, ...]`.

- [ ] **Step 1: Write the failing tests**

Append to `ansible-project/roles/backend/files/backend/tests/test_queries.py`:

```python
def test_get_results_switch_scopes(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]

    cur.execute(
        'INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, 'stayed', 7)
    )
    cur.execute(
        'INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (%s, NULL, %s, %s)',
        (league_id, 'switched', 3)
    )
    cur.execute(
        'INSERT INTO rollup_national_vote_switch (switch_status, vote_count) VALUES (%s, %s)',
        ('stayed', 100)
    )
    conn.commit()
    cur.close()

    club_result = queries.get_results_switch(conn, club_id=club_id)
    assert {'status': 'stayed', 'count': 7} in club_result['breakdown']

    league_result = queries.get_results_switch(conn, league_id=league_id)
    assert {'status': 'switched', 'count': 3} in league_result['breakdown']

    national_result = queries.get_results_switch(conn)
    assert {'status': 'stayed', 'count': 100} in national_result['breakdown']


def test_get_clubs_breakdown_shape(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, party_id, 9)
    )
    # a league-scope row (club_id IS NULL) must NOT appear in the per-club breakdown
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, NULL, %s, %s)',
        (league_id, party_id, 40)
    )
    conn.commit()
    cur.close()

    breakdown = queries.get_clubs_breakdown(conn)
    entry = next(e for e in breakdown if e['club_id'] == club_id)
    assert entry['previous'] == [{'party_id': party_id, 'count': 9}]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_queries.py::test_get_results_switch_scopes tests/test_queries.py::test_get_clubs_breakdown_shape -v`
Expected: FAIL — `AttributeError: module 'queries' has no attribute 'get_results_switch'`.

- [ ] **Step 3: Implement**

In `ansible-project/roles/backend/files/backend/queries.py`, add these two functions immediately after
`get_results_segment` (the function ending `return {'upcoming': upcoming, 'total': total}`):

```python
def get_results_switch(conn, league_id=None, club_id=None):
    cur = conn.cursor()

    if club_id is not None:
        cur.execute(
            'SELECT switch_status, SUM(vote_count) FROM rollup_vote_switch '
            'WHERE club_id = %s GROUP BY switch_status',
            (club_id,)
        )
    elif league_id is not None:
        cur.execute(
            'SELECT switch_status, SUM(vote_count) FROM rollup_vote_switch '
            'WHERE league_id = %s AND club_id IS NULL GROUP BY switch_status',
            (league_id,)
        )
    else:
        cur.execute(
            'SELECT switch_status, SUM(vote_count) FROM rollup_national_vote_switch '
            'GROUP BY switch_status'
        )

    breakdown = [{'status': r[0], 'count': r[1]} for r in cur.fetchall()]
    cur.close()
    return {'breakdown': breakdown}


def get_clubs_breakdown(conn):
    cur = conn.cursor()
    cur.execute(
        'SELECT club_id, previous_party_id, SUM(vote_count) FROM rollup_previous '
        'WHERE club_id IS NOT NULL GROUP BY club_id, previous_party_id'
    )
    by_club = {}
    for club_id, party_id, count in cur.fetchall():
        by_club.setdefault(club_id, []).append({'party_id': party_id, 'count': count})
    cur.close()
    return [{'club_id': club_id, 'previous': rows} for club_id, rows in by_club.items()]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_queries.py::test_get_results_switch_scopes tests/test_queries.py::test_get_clubs_breakdown_shape -v`
Expected: PASS

- [ ] **Step 5: Run the full backend suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py
git commit -m "Add get_results_switch and get_clubs_breakdown query functions"
```

---

### Task 5: `app.py` — new routes

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Test: `ansible-project/roles/backend/files/backend/tests/test_app.py`

**Interfaces:**
- Consumes: `queries.get_results_switch`, `queries.get_clubs_breakdown` (Task 4).
- Produces: `GET /api/results/switch?league_id=&club_id=`, `GET /api/results/clubs-breakdown`.

- [ ] **Step 1: Write the failing tests**

Append to `ansible-project/roles/backend/files/backend/tests/test_app.py` (find
`test_results_segment_requires_previous_party_id` and add these tests right after it):

```python
def test_results_switch_national_when_no_scope_given(client):
    resp = client.get('/api/results/switch')
    assert resp.status_code == 200
    assert 'breakdown' in resp.get_json()


def test_results_switch_scoped_by_club(client, conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, 'hedging', 4)
    )
    conn.commit()
    cur.close()

    resp = client.get(f'/api/results/switch?club_id={club_id}')
    assert resp.status_code == 200
    assert {'status': 'hedging', 'count': 4} in resp.get_json()['breakdown']


def test_results_clubs_breakdown_returns_200(client):
    resp = client.get('/api/results/clubs-breakdown')
    assert resp.status_code == 200
    assert isinstance(resp.get_json(), list)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_app.py::test_results_switch_national_when_no_scope_given tests/test_app.py::test_results_switch_scoped_by_club tests/test_app.py::test_results_clubs_breakdown_returns_200 -v`
Expected: FAIL — 404 (routes don't exist yet).

- [ ] **Step 3: Implement**

In `ansible-project/roles/backend/files/backend/app.py`, find the end of the `results_segment`
function (it ends with `return jsonify(result)`, right after the `try/finally: conn.close()` block
that calls `queries.get_results_segment`). Add these two new routes immediately after it:

```python
@app.route('/api/results/switch', methods=['GET'])
def results_switch():
    league_id = request.args.get('league_id', type=int)
    club_id = request.args.get('club_id', type=int)

    conn = db.get_db()
    try:
        result = queries.get_results_switch(conn, league_id=league_id, club_id=club_id)
    finally:
        conn.close()

    return jsonify(result)


@app.route('/api/results/clubs-breakdown', methods=['GET'])
def results_clubs_breakdown():
    conn = db.get_db()
    try:
        result = queries.get_clubs_breakdown(conn)
    finally:
        conn.close()

    return jsonify(result)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_app.py::test_results_switch_national_when_no_scope_given tests/test_app.py::test_results_switch_scoped_by_club tests/test_app.py::test_results_clubs_breakdown_returns_200 -v`
Expected: PASS

- [ ] **Step 5: Run the full backend suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Add GET /api/results/switch and GET /api/results/clubs-breakdown routes"
```

---

### Task 6: Worker — `_recompute_vote_switch`

**Files:**
- Modify: `ansible-project/roles/worker/files/worker/rollups.py`
- Modify: `ansible-project/roles/worker/files/worker/tests/conftest.py`
- Test: `ansible-project/roles/worker/files/worker/tests/test_rollups.py`

**Interfaces:**
- Consumes: `votes`, `vote_upcoming_parties`, `vote_clubs`, `vote_leagues`, `party_lineage` (all
  existing or Task 1).
- Produces: `rollups._recompute_vote_switch(cur)`, wired into `rollups.recompute(conn)`; populates
  `rollup_vote_switch`/`rollup_national_vote_switch`.

- [ ] **Step 1: Update the worker's hand-rolled test schema and DROP list**

In `ansible-project/roles/worker/files/worker/tests/conftest.py`, the `SCHEMA` string currently ends
with:

```python
CREATE TABLE rollup_national_previous_upcoming (previous_party_id INTEGER, upcoming_party_id INTEGER, vote_count INTEGER NOT NULL);
'''
```

Insert these two new `CREATE TABLE` lines plus a `party_lineage` table right before that closing
`'''`:

```python
CREATE TABLE party_lineage (previous_party_id INTEGER NOT NULL REFERENCES previous_parties(id), upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id), PRIMARY KEY (previous_party_id, upcoming_party_id));
CREATE TABLE rollup_vote_switch (league_id INTEGER, club_id INTEGER, switch_status TEXT NOT NULL, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_national_vote_switch (switch_status TEXT NOT NULL, vote_count INTEGER NOT NULL);
'''
```

Then update the `DROP TABLE IF EXISTS` list in the same file (currently ending
`clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE`) to:

```python
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, vote_clubs, vote_leagues, votes,
            rollup_previous, rollup_upcoming, rollup_previous_upcoming,
            rollup_national_previous, rollup_national_upcoming, rollup_national_previous_upcoming,
            rollup_vote_switch, rollup_national_vote_switch, party_lineage,
            clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE
    ''')
```

- [ ] **Step 2: Write the failing tests**

Append to `ansible-project/roles/worker/files/worker/tests/test_rollups.py`:

```python
def _seed_switch_votes(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]

    cur.execute("INSERT INTO previous_parties (name) VALUES ('Prev A') RETURNING id")
    prev_a = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Prev B (no lineage)') RETURNING id")
    prev_b = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Up A') RETURNING id")
    up_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Up Other') RETURNING id")
    up_other = cur.fetchone()[0]

    # Prev A's only lineage successor is Up A
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_a, up_a)
    )

    def _vote(prev_status, prev_party, up_status, up_picks, token):
        cur.execute(
            '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
               VALUES (%s, %s, %s, %s) RETURNING id''',
            (prev_status, prev_party, up_status, token)
        )
        vote_id = cur.fetchone()[0]
        cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_id, club_id, league_id))
        for pick in up_picks:
            cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (vote_id, pick))
        return vote_id

    stayed_vote = _vote('voted', prev_a, 'considering', [up_a], 'switch-stayed')
    hedging_vote = _vote('voted', prev_a, 'considering', [up_a, up_other], 'switch-hedging')
    switched_vote = _vote('voted', prev_a, 'considering', [up_other], 'switch-switched')
    no_lineage_vote = _vote('voted', prev_b, 'considering', [up_other], 'switch-no-lineage')
    new_voter_vote = _vote('did_not_vote', None, 'considering', [up_other], 'switch-new-voter')
    undecided_vote = _vote('voted', prev_a, 'undecided', [], 'switch-undecided')

    conn.commit()
    cur.close()
    return {
        'league_id': league_id, 'club_id': club_id,
        'stayed': stayed_vote, 'hedging': hedging_vote, 'switched': switched_vote,
        'no_lineage': no_lineage_vote, 'new_voter': new_voter_vote, 'undecided': undecided_vote,
    }


def test_recompute_vote_switch_classifies_each_status(conn):
    import rollups
    ids = _seed_switch_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT switch_status, vote_count FROM rollup_vote_switch WHERE club_id = %s ORDER BY switch_status',
        (ids['club_id'],)
    )
    rows = dict(cur.fetchall())
    cur.close()

    assert rows['stayed'] == 1
    assert rows['hedging'] == 1
    # 'switched' includes both the vote whose successor wasn't picked and the vote with no lineage at all
    assert rows['switched'] == 2
    assert rows['new_voter'] == 1
    assert rows['undecided'] == 1


def test_recompute_national_vote_switch_matches_club_scope(conn):
    import rollups
    _seed_switch_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT switch_status, vote_count FROM rollup_national_vote_switch ORDER BY switch_status')
    rows = dict(cur.fetchall())
    cur.close()

    assert rows['stayed'] == 1
    assert rows['hedging'] == 1
    assert rows['switched'] == 2
    assert rows['new_voter'] == 1
    assert rows['undecided'] == 1
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ansible-project/roles/worker/files/worker && source .venv/bin/activate && python -m pytest tests/test_rollups.py::test_recompute_vote_switch_classifies_each_status tests/test_rollups.py::test_recompute_national_vote_switch_matches_club_scope -v`
Expected: FAIL — `relation "rollup_vote_switch" does not exist` (schema not updated in conftest is
step 1, already done, so more likely: `KeyError: 'stayed'` since the table is empty — `_recompute_vote_switch` doesn't exist yet, so `recompute()` never populates it).

If the worker has its own venv missing (`ansible-project/roles/worker/files/worker/.venv` doesn't
exist yet), set it up first:

```bash
cd ansible-project/roles/worker/files/worker
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

- [ ] **Step 4: Implement**

In `ansible-project/roles/worker/files/worker/rollups.py`, change the `recompute` function:

```python
def recompute(conn):
    cur = conn.cursor()

    _recompute_previous(cur)
    _recompute_upcoming(cur)
    _recompute_previous_upcoming(cur)
    _recompute_national(cur)
    _recompute_vote_switch(cur)

    conn.commit()
    cur.close()
```

Then append this new function at the end of the file:

```python
# Per-voter classification of "did they really change their mind," using party_lineage to resolve
# each vote's previous party's successor(s) rather than a raw previous<->upcoming crosstab (which
# over-counts anyone who kept their old party and also added others -- a ballot can name up to 3
# upcoming parties).
_VOTE_SWITCH_STATUS_CTE = '''
    WITH vote_pick_stats AS (
        SELECT v.id AS vote_id, v.previous_vote_status, v.upcoming_vote_status,
               COUNT(vup.upcoming_party_id) AS total_picks,
               COUNT(vup.upcoming_party_id) FILTER (WHERE pl.upcoming_party_id IS NOT NULL) AS successor_picks
        FROM votes v
        LEFT JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        LEFT JOIN party_lineage pl
            ON pl.previous_party_id = v.previous_party_id AND pl.upcoming_party_id = vup.upcoming_party_id
        GROUP BY v.id, v.previous_vote_status, v.upcoming_vote_status
    )
    SELECT vote_id,
        CASE
            WHEN previous_vote_status = 'did_not_vote' THEN 'new_voter'
            WHEN upcoming_vote_status = 'undecided' THEN 'undecided'
            WHEN successor_picks = 0 THEN 'switched'
            WHEN successor_picks >= 1 AND total_picks = 1 THEN 'stayed'
            ELSE 'hedging'
        END AS switch_status
    FROM vote_pick_stats
'''


def _recompute_vote_switch(cur):
    cur.execute('TRUNCATE rollup_vote_switch')
    cur.execute('TRUNCATE rollup_national_vote_switch')

    cur.execute(f'''
        INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count)
        SELECT vlt.league_id, NULL, vs.switch_status, COUNT(*)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN ({_VOTE_SWITCH_STATUS_CTE}) vs ON vs.vote_id = vlt.vote_id
        GROUP BY vlt.league_id, vs.switch_status
    ''')
    cur.execute(f'''
        INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count)
        SELECT vc.league_id, vc.club_id, vs.switch_status, COUNT(*)
        FROM vote_clubs vc
        JOIN ({_VOTE_SWITCH_STATUS_CTE}) vs ON vs.vote_id = vc.vote_id
        GROUP BY vc.league_id, vc.club_id, vs.switch_status
    ''')

    cur.execute(f'''
        INSERT INTO rollup_national_vote_switch (switch_status, vote_count)
        SELECT switch_status, COUNT(*) FROM ({_VOTE_SWITCH_STATUS_CTE}) vs
        GROUP BY switch_status
    ''')
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_rollups.py::test_recompute_vote_switch_classifies_each_status tests/test_rollups.py::test_recompute_national_vote_switch_matches_club_scope -v`
Expected: PASS

- [ ] **Step 6: Run the full worker suite**

Run: `python -m pytest tests/ -v`
Expected: all PASS (existing rollup tests unaffected — `_recompute_vote_switch` is additive).

- [ ] **Step 7: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/worker/files/worker/rollups.py \
        ansible-project/roles/worker/files/worker/tests/conftest.py \
        ansible-project/roles/worker/files/worker/tests/test_rollups.py
git commit -m "Worker: compute per-voter stayed/hedging/switched/new_voter/undecided rollup"
```

---

### Task 7: Frontend scaffold — Fan Politics section, `analytics.js` base, Dockerfile

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/results.html`
- Create: `ansible-project/roles/frontend/files/nginx/analytics.js`
- Modify: `ansible-project/roles/frontend/files/nginx/i18n.js`
- Modify: `ansible-project/roles/frontend/files/nginx/style.css`
- Modify: `ansible-project/roles/frontend/files/nginx/Dockerfile`

**Interfaces:**
- Consumes: `GET /api/options` (extended, Task 3), `GET /api/results/clubs-breakdown` (Task 4/5),
  global `fetchJSON`, `logoEl`, `t`, `localizedName` (already defined by `results.js`/`logos.js`/
  `i18n.js`, loaded as plain scripts sharing one global scope — no imports needed).
- Produces: `analyticsOptionsData` (module-level, populated by this task's `initAnalytics()`),
  `clubsBreakdown` (module-level), tab-switching wiring. Diversity/Lean/Switching tab bodies are
  built in Tasks 8-10 — this task only scaffolds the section, tab shell, and shared helpers they'll
  call.

- [ ] **Step 1: Add the Fan Politics section to `results.html`**

In `ansible-project/roles/frontend/files/nginx/results.html`, find:

```html
    </section>

    <hr class="chalk-rule">

    <section id="explorer-section">
```

Replace it with:

```html
    </section>

    <hr class="chalk-rule">

    <section id="fan-politics-section">
      <h2 class="section-heading" data-i18n="analyticsHeading">Fan Politics</h2>
      <div class="pill-group" id="analytics-tabs">
        <button type="button" data-tab="diversity" aria-pressed="true" data-i18n="analyticsTabDiversity">Diversity</button>
        <button type="button" data-tab="lean" aria-pressed="false" data-i18n="analyticsTabLean">Political Lean</button>
        <button type="button" data-tab="switching" aria-pressed="false" data-i18n="analyticsTabSwitching">Switching</button>
      </div>

      <div id="diversity-tab" class="analytics-tab"></div>
      <div id="lean-tab" class="analytics-tab" hidden></div>
      <div id="switching-tab" class="analytics-tab" hidden></div>
    </section>

    <hr class="chalk-rule">

    <section id="explorer-section">
```

At the very end of the `<body>`, find:

```html
  <script src="logos.js"></script>
  <script src="results.js"></script>
</body>
```

Replace it with:

```html
  <script src="logos.js"></script>
  <script src="results.js"></script>
  <script src="analytics.js"></script>
</body>
```

- [ ] **Step 2: Add the Dockerfile COPY line entry**

In `ansible-project/roles/frontend/files/nginx/Dockerfile`, find:

```
COPY index.html results.html admin.html vote.js results.js admin.js style.css i18n.js theme.js logos.js /usr/share/nginx/html/
```

Replace it with:

```
COPY index.html results.html admin.html vote.js results.js admin.js analytics.js style.css i18n.js theme.js logos.js /usr/share/nginx/html/
```

- [ ] **Step 3: Add the base i18n keys**

In `ansible-project/roles/frontend/files/nginx/i18n.js`, in the `en` object, find the line
`resultsMigrationNoteDidNotVote: "You told us you didn't vote last time, so there's no migration to show.",`
and add immediately after it (still inside the `en` object, before the blank line that precedes
`adminTitle`):

```js
    analyticsHeading: 'Fan Politics',
    analyticsTabDiversity: 'Diversity',
    analyticsTabLean: 'Political Lean',
    analyticsTabSwitching: 'Switching',
    analyticsErrorLoad: "Couldn't load this — try refreshing.",
```

In the `he` object, find the matching line
`resultsMigrationNoteDidNotVote: 'סימנתם שלא הצבעתם בפעם הקודמת, כך שאין נתוני מעבר להציג.',`
and add immediately after it:

```js
    analyticsHeading: 'פוליטיקת האוהדים',
    analyticsTabDiversity: 'גיוון',
    analyticsTabLean: 'נטייה פוליטית',
    analyticsTabSwitching: 'מעבר הצבעה',
    analyticsErrorLoad: 'לא הצלחנו לטעון — נסו לרענן.',
```

(Tasks 8-10 each add their own further keys to these same two objects, in the same place.)

- [ ] **Step 4: Add base CSS**

At the end of `ansible-project/roles/frontend/files/nginx/style.css`, after the
`@media (max-width: 480px) { ... }` block (the file's last rule), append:

```css

/* ---------- Fan Politics ---------- */

.analytics-tab {
  margin-top: 1rem;
}
```

(Tasks 8-10 each append their own further CSS rules after this block.)

- [ ] **Step 5: Create `analytics.js` with the tab-switching shell**

Create `ansible-project/roles/frontend/files/nginx/analytics.js`:

```js
let analyticsOptionsData = null;
let clubsBreakdown = null;

function analyticsShowError(containerId) {
  const el = document.getElementById(containerId);
  if (!el) return;
  el.innerHTML = '';
  const p = document.createElement('p');
  p.className = 'error';
  p.textContent = t('analyticsErrorLoad');
  el.appendChild(p);
}

function switchAnalyticsTab(tabName) {
  document.querySelectorAll('#analytics-tabs button[data-tab]').forEach(btn => {
    btn.setAttribute('aria-pressed', String(btn.dataset.tab === tabName));
  });
  document.getElementById('diversity-tab').hidden = tabName !== 'diversity';
  document.getElementById('lean-tab').hidden = tabName !== 'lean';
  document.getElementById('switching-tab').hidden = tabName !== 'switching';
}

document.getElementById('analytics-tabs').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-tab]');
  if (!btn) return;
  switchAnalyticsTab(btn.dataset.tab);
});

async function initAnalytics() {
  try {
    analyticsOptionsData = await fetchJSON('/api/options');
    clubsBreakdown = await fetchJSON('/api/results/clubs-breakdown');
  } catch (err) {
    analyticsShowError('diversity-tab');
    return;
  }
}

document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
});

initAnalytics();
```

(`switchAnalyticsTab`'s three `document.getElementById(...).hidden = ...` lines already reference the
tab containers Step 1 created; Tasks 8-10 populate each container's contents and extend
`initAnalytics()`/the `voteball:langchange` handler to render them.)

- [ ] **Step 6: Manual verification**

No automated frontend test suite exists in this repo (per `CLAUDE.md`) — verify by hand:

```bash
cd /home/latnook/Documents/Voteball/ansible-project/roles/backend/files/backend
source .venv/bin/activate
DB_HOST=localhost DB_NAME=postgres DB_USER=postgres DB_PASS=test DB_SSLMODE=disable \
  ADMIN_USERNAME=testadmin ADMIN_PASSWORD_HASH="$(python -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('test'))")" \
  ADMIN_SESSION_SECRET=test SNS_TOPIC=arn:aws:sns:il-central-1:000000000000:test AWS_REGION=il-central-1 \
  python -c "import app; app.app.run(port=5050)" &
cd /home/latnook/Documents/Voteball/ansible-project/roles/frontend/files/nginx
python -m http.server 8080 &
```

Open `http://localhost:8080/results.html` in a browser (Chromium/Firefox — not the Playwright MCP,
which needs Chrome and isn't available on this machine). Confirm: the page loads without console
errors about `analytics.js` (a 404 there means the Dockerfile/script-tag wiring from Steps 1-2 is
wrong), a "Fan Politics" heading with three tab buttons appears between National Standings and
Explorer, and clicking each tab button switches which (currently empty) panel is visible. Note: this
manual server won't proxy `/api/*` the way nginx does in the real deploy, so `fetchJSON` calls will
fail with a CORS/network error in the console — that's expected and fine for this task, since it's
only verifying the tab-switching shell renders and responds to clicks; Task 8's verification step
sets up the real nginx-proxied stack for actual data loading.

Kill the background servers when done: `kill %1 %2` (or find and `kill` the two Python processes).

- [ ] **Step 7: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/results.html \
        ansible-project/roles/frontend/files/nginx/analytics.js \
        ansible-project/roles/frontend/files/nginx/i18n.js \
        ansible-project/roles/frontend/files/nginx/style.css \
        ansible-project/roles/frontend/files/nginx/Dockerfile
git commit -m "Scaffold Fan Politics section with tab-switching shell"
```

---

### Task 8: Diversity tab

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/analytics.js`
- Modify: `ansible-project/roles/frontend/files/nginx/i18n.js`
- Modify: `ansible-project/roles/frontend/files/nginx/style.css`

**Interfaces:**
- Consumes: `analyticsOptionsData`, `clubsBreakdown` (Task 7).
- Produces: populated `#diversity-tab`; `computeEffectiveParties(previousBreakdown) -> number`.

- [ ] **Step 1: Add i18n keys**

In `i18n.js`, `en` object, immediately after the `analyticsErrorLoad` line added in Task 7:

```js
    analyticsSpotlight: 'Spotlight',
    analyticsFullRanking: 'Full Ranking',
    analyticsIncludeWorldCup: 'Include World Cup national teams',
    analyticsMostMixed: 'Most Mixed Fanbases',
    analyticsMostOneSided: 'Most One-Sided Fanbases',
    analyticsEffectiveParties: '{n} effective parties',
    analyticsTooFewVotes: 'Not enough votes yet for a meaningful diversity score.',
```

In the `he` object, immediately after its matching `analyticsErrorLoad` line:

```js
    analyticsSpotlight: 'בזרקור',
    analyticsFullRanking: 'דירוג מלא',
    analyticsIncludeWorldCup: 'כלול נבחרות מונדיאל',
    analyticsMostMixed: 'האוהדים המגוונים ביותר',
    analyticsMostOneSided: 'האוהדים החד-צדדיים ביותר',
    analyticsEffectiveParties: '{n} מפלגות אפקטיביות',
    analyticsTooFewVotes: 'אין עדיין מספיק הצבעות לציון גיוון משמעותי.',
```

- [ ] **Step 2: Add CSS**

Append to the end of `style.css`, after the `.analytics-tab { margin-top: 1rem; }` rule from Task 7:

```css

.diversity-controls {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 1rem;
}
.diversity-worldcup-label {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.8rem;
  color: var(--muted);
  cursor: pointer;
}
.diversity-spotlight-split {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
}
@media (max-width: 480px) {
  .diversity-spotlight-split { grid-template-columns: 1fr; }
}
.diversity-spotlight-heading {
  font-size: 0.75rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin-bottom: 0.5rem;
}
.diversity-spotlight-heading.most-mixed { color: var(--accent); }
.diversity-spotlight-heading.most-one-sided { color: #FFD23F; }
```

- [ ] **Step 3: Implement the Diversity tab in `analytics.js`**

Add these constants near the top of `analytics.js`, right after the `let clubsBreakdown = null;` line:

```js
const DIVERSITY_MIN_VOTES = 10;
let diversityIncludeWorldCup = false;
let diversityView = 'spotlight';
```

Add these functions before `async function initAnalytics() {`:

```js
// shares: [{party_id, count}, ...] for one club's previous-election votes.
// Returns 1 / sum(share^2) -- "effective number of parties" (Laakso-Taagepera index).
function computeEffectiveParties(previousBreakdown) {
  const total = previousBreakdown.reduce((sum, r) => sum + r.count, 0);
  if (total === 0) return 0;
  const sumSquaredShares = previousBreakdown.reduce((sum, r) => {
    const share = r.count / total;
    return sum + share * share;
  }, 0);
  return 1 / sumSquaredShares;
}

function worldCupLeagueId() {
  const wc = analyticsOptionsData.leagues.find(l => l.name_en === 'World Cup 2026');
  return wc ? wc.id : null;
}

function clubById(clubId) {
  return analyticsOptionsData.clubs.find(c => c.id === clubId);
}

// Every eligible club (>=DIVERSITY_MIN_VOTES previous-election votes, World-Cup-filtered per the
// current toggle state), with its effective-parties score, sorted descending.
function eligibleClubDiversityScores() {
  const wcLeagueId = worldCupLeagueId();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      const total = entry.previous.reduce((sum, r) => sum + r.count, 0);
      return { club, total, score: computeEffectiveParties(entry.previous) };
    })
    .filter(row => row !== null)
    .filter(row => row.total >= DIVERSITY_MIN_VOTES)
    .filter(row => diversityIncludeWorldCup || row.club.league_id !== wcLeagueId)
    .sort((a, b) => b.score - a.score);
}

function renderDiversityBar(container, row, maxScore) {
  const wrap = document.createElement('div');
  wrap.className = 'standings-row';

  const rank = document.createElement('div');
  rank.className = 'standings-rank';
  rank.textContent = '';
  wrap.appendChild(rank);

  const nameDiv = document.createElement('div');
  nameDiv.className = 'standings-name';
  nameDiv.appendChild(logoEl(row.club, localizedName(row.club)));
  const nameSpan = document.createElement('span');
  nameSpan.textContent = localizedName(row.club);
  nameDiv.appendChild(nameSpan);
  wrap.appendChild(nameDiv);

  const track = document.createElement('div');
  track.className = 'standings-track';
  const fill = document.createElement('div');
  fill.className = 'standings-fill';
  fill.style.width = `${Math.round((row.score / maxScore) * 100)}%`;
  track.appendChild(fill);
  wrap.appendChild(track);

  const stat = document.createElement('div');
  stat.className = 'standings-stat';
  stat.textContent = t('analyticsEffectiveParties').replace('{n}', row.score.toFixed(1));
  wrap.appendChild(stat);

  container.appendChild(wrap);
}

function renderDiversitySpotlight(rows) {
  const container = document.createElement('div');
  container.className = 'diversity-spotlight-split';

  const mostMixed = document.createElement('div');
  const mostMixedHeading = document.createElement('div');
  mostMixedHeading.className = 'diversity-spotlight-heading most-mixed';
  mostMixedHeading.textContent = t('analyticsMostMixed');
  mostMixed.appendChild(mostMixedHeading);
  const mostMixedList = document.createElement('div');
  mostMixedList.className = 'standings';
  mostMixed.appendChild(mostMixedList);

  const mostOneSided = document.createElement('div');
  const mostOneSidedHeading = document.createElement('div');
  mostOneSidedHeading.className = 'diversity-spotlight-heading most-one-sided';
  mostOneSidedHeading.textContent = t('analyticsMostOneSided');
  mostOneSided.appendChild(mostOneSidedHeading);
  const mostOneSidedList = document.createElement('div');
  mostOneSidedList.className = 'standings';
  mostOneSided.appendChild(mostOneSidedList);

  const maxScore = rows.length ? rows[0].score : 1;
  rows.slice(0, 5).forEach(row => renderDiversityBar(mostMixedList, row, maxScore));
  rows.slice(-5).reverse().forEach(row => renderDiversityBar(mostOneSidedList, row, maxScore));

  container.appendChild(mostMixed);
  container.appendChild(mostOneSided);
  return container;
}

function renderDiversityFullRanking(rows) {
  const container = document.createElement('div');
  container.className = 'standings';
  const maxScore = rows.length ? rows[0].score : 1;
  rows.forEach(row => renderDiversityBar(container, row, maxScore));
  return container;
}

function renderDiversityTab() {
  const tab = document.getElementById('diversity-tab');
  tab.innerHTML = '';

  const controls = document.createElement('div');
  controls.className = 'diversity-controls';

  const viewToggle = document.createElement('div');
  viewToggle.className = 'pill-group';
  ['spotlight', 'full'].forEach(view => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('aria-pressed', String(view === diversityView));
    btn.textContent = view === 'spotlight' ? t('analyticsSpotlight') : t('analyticsFullRanking');
    btn.addEventListener('click', () => { diversityView = view; renderDiversityTab(); });
    viewToggle.appendChild(btn);
  });
  controls.appendChild(viewToggle);

  const wcLabel = document.createElement('label');
  wcLabel.className = 'diversity-worldcup-label';
  const wcCheckbox = document.createElement('input');
  wcCheckbox.type = 'checkbox';
  wcCheckbox.checked = diversityIncludeWorldCup;
  wcCheckbox.addEventListener('change', () => {
    diversityIncludeWorldCup = wcCheckbox.checked;
    renderDiversityTab();
  });
  wcLabel.appendChild(wcCheckbox);
  const wcText = document.createElement('span');
  wcText.textContent = t('analyticsIncludeWorldCup');
  wcLabel.appendChild(wcText);
  controls.appendChild(wcLabel);

  tab.appendChild(controls);

  const rows = eligibleClubDiversityScores();
  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('analyticsTooFewVotes');
    tab.appendChild(empty);
    return;
  }

  tab.appendChild(diversityView === 'spotlight' ? renderDiversitySpotlight(rows) : renderDiversityFullRanking(rows));
}
```

Update `initAnalytics()` to call the renderer once data is loaded — change:

```js
async function initAnalytics() {
  try {
    analyticsOptionsData = await fetchJSON('/api/options');
    clubsBreakdown = await fetchJSON('/api/results/clubs-breakdown');
  } catch (err) {
    analyticsShowError('diversity-tab');
    return;
  }
}
```

to:

```js
async function initAnalytics() {
  try {
    analyticsOptionsData = await fetchJSON('/api/options');
    clubsBreakdown = await fetchJSON('/api/results/clubs-breakdown');
  } catch (err) {
    analyticsShowError('diversity-tab');
    return;
  }
  renderDiversityTab();
}
```

And update the `voteball:langchange` handler:

```js
document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
});
```

to:

```js
document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
});
```

- [ ] **Step 4: Manual verification**

Set up the real stack so `/api/*` is actually reachable (nginx proxies it; a plain `http.server` from
Task 7 cannot). Use the existing docker-based local stack pattern from `CLAUDE.md`'s backend section
(the `voteball-test-db` container) plus running the Flask app directly and nginx separately, or
simplest: temporarily point `vote.js`aside and instead run:

```bash
cd /home/latnook/Documents/Voteball/ansible-project/roles/backend/files/backend
source .venv/bin/activate
DB_HOST=localhost DB_NAME=postgres DB_USER=postgres DB_PASS=test DB_SSLMODE=disable \
  ADMIN_USERNAME=testadmin ADMIN_PASSWORD_HASH="$(python -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('test'))")" \
  ADMIN_SESSION_SECRET=test SNS_TOPIC=arn:aws:sns:il-central-1:000000000000:test AWS_REGION=il-central-1 \
  FLASK_APP=app.py python -m flask run --port 5050
```

In a second terminal, submit a handful of test votes for the same club via `curl -X POST
http://localhost:5050/api/vote` (varying `previous_party_id`) so `rollup_previous` has real data —
or, faster, insert rows directly into `rollup_previous` via `psql` for a couple of clubs, run the
worker's `rollups.recompute` once manually (`python -c "import db, rollups; conn = db.get_db();
rollups.recompute(conn)"` from the worker directory), then load `results.html` through nginx (or
`python -m http.server` plus a `sed`-adjusted `fetch('/api/...')` base for a quick local check) and
confirm: the Diversity tab shows a Spotlight split with real club names/logos, effective-parties
numbers look sane (a club with one dominant party scores near 1, an evenly-split club scores near its
party count), the World Cup checkbox visibly changes which clubs qualify, and Full Ranking shows every
eligible club as a standings bar.

- [ ] **Step 5: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/analytics.js \
        ansible-project/roles/frontend/files/nginx/i18n.js \
        ansible-project/roles/frontend/files/nginx/style.css
git commit -m "Implement Diversity tab: effective-parties leaderboard"
```

---

### Task 9: Political Lean tab

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/analytics.js`
- Modify: `ansible-project/roles/frontend/files/nginx/i18n.js`
- Modify: `ansible-project/roles/frontend/files/nginx/style.css`

**Interfaces:**
- Consumes: `analyticsOptionsData`, `clubsBreakdown`, `eligibleClubDiversityScores`-style filtering
  logic (Task 8, reused with a `LEAN_MIN_VOTES` constant).
- Produces: populated `#lean-tab`.

- [ ] **Step 1: Add i18n keys**

In `i18n.js`, `en` object, immediately after the `analyticsTooFewVotes` line from Task 8:

```js
    analyticsAxisLeft: 'Left',
    analyticsAxisRight: 'Right',
    analyticsNoStatedPosition: 'No stated position',
    analyticsSecurityLabel: 'Security:',
    analyticsBlocLabel: 'Bloc:',
    analyticsSectorLabel: 'Sector:',
    analyticsBlocBibi: 'Bibi bloc',
    analyticsBlocOpposition: 'Opposition',
    analyticsBlocUnaligned: 'Unaligned',
    analyticsSectorSecular: 'Secular',
    analyticsSectorTraditional: 'Traditional',
    analyticsSectorReligiousZionist: 'Religious Zionist',
    analyticsSectorHaredi: 'Haredi',
    analyticsSectorArab: 'Arab',
    analyticsSecurityDovish: 'Dovish',
    analyticsSecurityHawkish: 'Hawkish',
    analyticsNational: 'National',
```

In the `he` object, immediately after its matching `analyticsTooFewVotes` line:

```js
    analyticsAxisLeft: 'שמאל',
    analyticsAxisRight: 'ימין',
    analyticsNoStatedPosition: 'אין עמדה מוצהרת',
    analyticsSecurityLabel: 'ביטחון:',
    analyticsBlocLabel: 'מחנה:',
    analyticsSectorLabel: 'מגזר:',
    analyticsBlocBibi: 'מחנה ביבי',
    analyticsBlocOpposition: 'אופוזיציה',
    analyticsBlocUnaligned: 'לא משויך',
    analyticsSectorSecular: 'חילוני',
    analyticsSectorTraditional: 'מסורתי',
    analyticsSectorReligiousZionist: 'ציוני דתי',
    analyticsSectorHaredi: 'חרדי',
    analyticsSectorArab: 'ערבי',
    analyticsSecurityDovish: 'יוני',
    analyticsSecurityHawkish: 'ניצי',
    analyticsNational: 'כלל הארץ',
```

- [ ] **Step 2: Add CSS**

Append after Task 8's CSS additions, at the end of `style.css`:

```css

.lean-strip {
  position: relative;
  height: 3.4rem;
  border-radius: var(--radius-sm);
  background: linear-gradient(90deg, #4a9, var(--surface-raised), #c66);
  margin-bottom: 0.5rem;
}
.lean-axis-labels {
  display: flex;
  justify-content: space-between;
  font-size: 0.75rem;
  color: var(--muted);
  margin-bottom: 1rem;
}
.lean-badge {
  position: absolute;
  top: 0.5rem;
  transform: translateX(-50%);
  font-size: 0.7rem;
  font-weight: 600;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: 0.15rem 0.55rem;
  cursor: pointer;
  white-space: nowrap;
  color: var(--ink);
}
.lean-badge[aria-pressed="true"] {
  border-color: var(--accent);
  border-width: 2px;
  color: var(--accent);
}
.lean-detail-row {
  display: flex;
  justify-content: space-between;
  font-size: 0.85rem;
  padding: 0.3rem 0;
  border-top: 1px solid var(--line);
}
.lean-detail-row:first-child { border-top: none; }
```

- [ ] **Step 3: Implement the Lean tab in `analytics.js`**

Add this constant near the top, alongside `DIVERSITY_MIN_VOTES`:

```js
const LEAN_MIN_VOTES = 10;
```

Add these functions before `async function initAnalytics() {` (after Task 8's functions):

```js
function partyById(partyId, list) {
  return analyticsOptionsData[list].find(p => p.id === partyId);
}

// Weighted average of a numeric axis (economic/security) over a club's previous-election votes,
// skipping parties with a null value on that axis (both from the numerator and the denominator) --
// see design spec Decision 8.
function weightedAxisAverage(previousBreakdown, axis) {
  let weightedSum = 0;
  let weightTotal = 0;
  previousBreakdown.forEach(r => {
    const party = partyById(r.party_id, 'previous_parties');
    if (!party || party[axis] === null || party[axis] === undefined) return;
    weightedSum += party[axis] * r.count;
    weightTotal += r.count;
  });
  return weightTotal > 0 ? weightedSum / weightTotal : null;
}

function compositionPercentages(previousBreakdown, field, categories) {
  const totals = {};
  categories.forEach(c => { totals[c] = 0; });
  let total = 0;
  previousBreakdown.forEach(r => {
    const party = partyById(r.party_id, 'previous_parties');
    if (!party || !party[field] || !(party[field] in totals)) return;
    totals[party[field]] += r.count;
    total += r.count;
  });
  if (total === 0) return null;
  const pct = {};
  categories.forEach(c => { pct[c] = Math.round((totals[c] / total) * 100); });
  return pct;
}

function eligibleClubLeanRows() {
  const wcLeagueId = worldCupLeagueId();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      const total = entry.previous.reduce((sum, r) => sum + r.count, 0);
      const economic = weightedAxisAverage(entry.previous, 'economic');
      return { club, total, economic, previous: entry.previous };
    })
    .filter(row => row !== null && row.total >= LEAN_MIN_VOTES && row.economic !== null)
    .filter(row => diversityIncludeWorldCup || row.club.league_id !== wcLeagueId);
}

function renderLeanDetail(container, label, previousBreakdown) {
  container.innerHTML = '';
  const heading = document.createElement('div');
  heading.className = 'scoreboard-title';
  heading.textContent = label;
  container.appendChild(heading);

  const security = weightedAxisAverage(previousBreakdown, 'security');
  const securityRow = document.createElement('div');
  securityRow.className = 'lean-detail-row';
  const securityLabel = document.createElement('span');
  securityLabel.textContent = t('analyticsSecurityLabel');
  securityRow.appendChild(securityLabel);
  const securityValue = document.createElement('span');
  securityValue.textContent = security === null
    ? t('analyticsNoStatedPosition')
    : `${security.toFixed(1)} (${security < 0 ? t('analyticsSecurityDovish') : t('analyticsSecurityHawkish')})`;
  securityRow.appendChild(securityValue);
  container.appendChild(securityRow);

  const blocPct = compositionPercentages(previousBreakdown, 'bloc', ['bibi', 'opposition', 'unaligned']);
  const blocRow = document.createElement('div');
  blocRow.className = 'lean-detail-row';
  const blocLabel = document.createElement('span');
  blocLabel.textContent = t('analyticsBlocLabel');
  blocRow.appendChild(blocLabel);
  const blocValue = document.createElement('span');
  blocValue.textContent = blocPct
    ? `${blocPct.bibi}% ${t('analyticsBlocBibi')} · ${blocPct.opposition}% ${t('analyticsBlocOpposition')} · ${blocPct.unaligned}% ${t('analyticsBlocUnaligned')}`
    : t('analyticsNoStatedPosition');
  blocRow.appendChild(blocValue);
  container.appendChild(blocRow);

  const sectorCategories = ['secular', 'traditional', 'religious_zionist', 'haredi', 'arab'];
  const sectorPct = compositionPercentages(previousBreakdown, 'sector', sectorCategories);
  const sectorRow = document.createElement('div');
  sectorRow.className = 'lean-detail-row';
  const sectorLabel = document.createElement('span');
  sectorLabel.textContent = t('analyticsSectorLabel');
  sectorRow.appendChild(sectorLabel);
  const sectorValue = document.createElement('span');
  const sectorKeyMap = {
    secular: 'analyticsSectorSecular', traditional: 'analyticsSectorTraditional',
    religious_zionist: 'analyticsSectorReligiousZionist', haredi: 'analyticsSectorHaredi', arab: 'analyticsSectorArab',
  };
  sectorValue.textContent = sectorPct
    ? sectorCategories.filter(c => sectorPct[c] > 0).map(c => `${sectorPct[c]}% ${t(sectorKeyMap[c])}`).join(' · ')
    : t('analyticsNoStatedPosition');
  sectorRow.appendChild(sectorValue);
  container.appendChild(sectorRow);
}

function nationalPreviousBreakdown() {
  const totals = {};
  clubsBreakdown.forEach(entry => {
    entry.previous.forEach(r => {
      totals[r.party_id] = (totals[r.party_id] || 0) + r.count;
    });
  });
  return Object.entries(totals).map(([partyId, count]) => ({ party_id: Number(partyId), count }));
}

function renderLeanTab() {
  const tab = document.getElementById('lean-tab');
  tab.innerHTML = '';

  const rows = eligibleClubLeanRows();
  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('analyticsTooFewVotes');
    tab.appendChild(empty);
    return;
  }

  const strip = document.createElement('div');
  strip.className = 'lean-strip';
  const detail = document.createElement('div');
  detail.className = 'card';

  function selectClub(row, badge) {
    strip.querySelectorAll('.lean-badge').forEach(b => b.setAttribute('aria-pressed', 'false'));
    if (badge) badge.setAttribute('aria-pressed', 'true');
    renderLeanDetail(detail, row ? localizedName(row.club) : t('analyticsNational'), row ? row.previous : nationalPreviousBreakdown());
  }

  rows.forEach(row => {
    const badge = document.createElement('button');
    badge.type = 'button';
    badge.className = 'lean-badge';
    badge.setAttribute('aria-pressed', 'false');
    badge.style.left = `${((row.economic + 3) / 6) * 100}%`;
    badge.textContent = localizedName(row.club);
    badge.addEventListener('click', () => selectClub(row, badge));
    strip.appendChild(badge);
  });

  const axisLabels = document.createElement('div');
  axisLabels.className = 'lean-axis-labels';
  const leftLabel = document.createElement('span');
  leftLabel.textContent = `← ${t('analyticsAxisLeft')}`;
  const rightLabel = document.createElement('span');
  rightLabel.textContent = `${t('analyticsAxisRight')} →`;
  axisLabels.appendChild(leftLabel);
  axisLabels.appendChild(rightLabel);

  tab.appendChild(strip);
  tab.appendChild(axisLabels);
  tab.appendChild(detail);

  selectClub(null, null);
}
```

Update `initAnalytics()`'s success path from:

```js
  renderDiversityTab();
}
```

to:

```js
  renderDiversityTab();
  renderLeanTab();
}
```

And the `voteball:langchange` handler from:

```js
document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
});
```

to:

```js
document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
  renderLeanTab();
});
```

- [ ] **Step 4: Manual verification**

Using the same local stack as Task 8's Step 4 (Flask + real `/api/*` data with several clubs' worth
of `rollup_previous` rows spanning different parties), load `results.html`, open the Political Lean
tab, and confirm: badges are positioned left-to-right roughly matching each club's dominant party's
known economic lean, clicking a badge highlights it and updates the detail card below with security/
bloc/sector figures, a club whose votes are entirely for a null-`security` party (e.g., seed data
dominated by Together or Ra'am voters) shows "No stated position" rather than a number, and the
default view before any click shows the National aggregate.

- [ ] **Step 5: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/analytics.js \
        ansible-project/roles/frontend/files/nginx/i18n.js \
        ansible-project/roles/frontend/files/nginx/style.css
git commit -m "Implement Political Lean tab: spectrum strip + click-to-expand detail"
```

---

### Task 10: Switching tab

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/analytics.js`
- Modify: `ansible-project/roles/frontend/files/nginx/i18n.js`
- Modify: `ansible-project/roles/frontend/files/nginx/style.css`

**Interfaces:**
- Consumes: `GET /api/results/switch?league_id=&club_id=` (Task 4/5), `analyticsOptionsData`.
- Produces: populated `#switching-tab`.

- [ ] **Step 1: Add i18n keys**

In `i18n.js`, `en` object, immediately after the `analyticsNational` line from Task 9:

```js
    analyticsScopeLabel: 'Scope:',
    analyticsStatusStayed: 'Stayed',
    analyticsStatusHedging: 'Hedging',
    analyticsStatusSwitched: 'Switched',
    analyticsStatusNewVoter: 'New voter',
    analyticsStatusUndecided: 'Undecided',
    analyticsBaselineLabel: 'National average',
    analyticsTakeawayMoreLoyal: '{who} are more loyal to their old party than average.',
    analyticsTakeawayLessLoyal: '{who} are more volatile than average.',
    analyticsTakeawayAboutAverage: '{who} are about as loyal as average.',
```

In the `he` object, immediately after its matching `analyticsNational` line:

```js
    analyticsScopeLabel: 'טווח:',
    analyticsStatusStayed: 'נשארו',
    analyticsStatusHedging: 'מהססים',
    analyticsStatusSwitched: 'עברו',
    analyticsStatusNewVoter: 'מצביע/ה חדש/ה',
    analyticsStatusUndecided: 'לא החליטו',
    analyticsBaselineLabel: 'ממוצע ארצי',
    analyticsTakeawayMoreLoyal: '{who} נאמנים יותר למפלגה הקודמת שלהם מהממוצע.',
    analyticsTakeawayLessLoyal: '{who} משתנים יותר מהממוצע.',
    analyticsTakeawayAboutAverage: '{who} נאמנים בערך כמו הממוצע.',
```

- [ ] **Step 2: Add CSS**

Append after Task 9's CSS additions, at the end of `style.css`:

```css

.switch-bar-label {
  font-size: 0.75rem;
  color: var(--muted);
  margin-bottom: 0.2rem;
}
.switch-bar {
  display: flex;
  height: 1.7rem;
  border-radius: var(--radius-sm);
  overflow: hidden;
  margin-bottom: 0.9rem;
}
.switch-bar.is-baseline { opacity: 0.65; }
.switch-segment {
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 0.65rem;
  font-weight: 700;
  color: #fff;
  overflow: hidden;
  white-space: nowrap;
}
.switch-segment.status-stayed { background: var(--accent); }
.switch-segment.status-hedging { background: #7aa2c6; }
.switch-segment.status-switched { background: var(--danger); }
.switch-segment.status-new_voter { background: var(--muted); }
.switch-segment.status-undecided { background: #444d59; }
```

- [ ] **Step 3: Implement the Switching tab in `analytics.js`**

Add this constant near the top, alongside `LEAN_MIN_VOTES`:

```js
const SWITCH_TAKEAWAY_THRESHOLD_POINTS = 5;
const SWITCH_STATUSES = ['stayed', 'hedging', 'switched', 'new_voter', 'undecided'];
```

Add these functions before `async function initAnalytics() {` (after Task 9's functions):

```js
function switchStatusLabel(status) {
  const keyMap = {
    stayed: 'analyticsStatusStayed', hedging: 'analyticsStatusHedging', switched: 'analyticsStatusSwitched',
    new_voter: 'analyticsStatusNewVoter', undecided: 'analyticsStatusUndecided',
  };
  return t(keyMap[status]);
}

function switchBreakdownToShares(breakdown) {
  const total = breakdown.reduce((sum, r) => sum + r.count, 0);
  const counts = {};
  SWITCH_STATUSES.forEach(s => { counts[s] = 0; });
  breakdown.forEach(r => { if (r.status in counts) counts[r.status] = r.count; });
  const shares = {};
  SWITCH_STATUSES.forEach(s => { shares[s] = total > 0 ? (counts[s] / total) * 100 : 0; });
  return { shares, total };
}

function renderSwitchBar(container, label, breakdown, isBaseline) {
  const labelEl = document.createElement('div');
  labelEl.className = 'switch-bar-label';
  labelEl.textContent = label;
  container.appendChild(labelEl);

  const { shares } = switchBreakdownToShares(breakdown);
  const bar = document.createElement('div');
  bar.className = isBaseline ? 'switch-bar is-baseline' : 'switch-bar';
  SWITCH_STATUSES.forEach(status => {
    if (shares[status] <= 0) return;
    const segment = document.createElement('div');
    segment.className = `switch-segment status-${status}`;
    segment.style.width = `${shares[status]}%`;
    segment.textContent = shares[status] >= 12 ? `${switchStatusLabel(status)} ${Math.round(shares[status])}%` : '';
    bar.appendChild(segment);
  });
  container.appendChild(bar);
  return shares;
}

function renderSwitchTakeaway(container, scopeLabel, scopeShares, nationalShares) {
  const p = document.createElement('p');
  p.className = 'note';
  const delta = scopeShares.stayed - nationalShares.stayed;
  let key = 'analyticsTakeawayAboutAverage';
  if (delta > SWITCH_TAKEAWAY_THRESHOLD_POINTS) key = 'analyticsTakeawayMoreLoyal';
  else if (delta < -SWITCH_TAKEAWAY_THRESHOLD_POINTS) key = 'analyticsTakeawayLessLoyal';
  p.textContent = t(key).replace('{who}', scopeLabel);
  container.appendChild(p);
}

async function loadSwitchingScope(leagueId, clubId, scopeLabel) {
  const barsContainer = document.getElementById('switching-bars');
  const takeawayContainer = document.getElementById('switching-takeaway');
  barsContainer.innerHTML = '';
  takeawayContainer.innerHTML = '';

  try {
    const query = clubId ? `club_id=${clubId}` : (leagueId ? `league_id=${leagueId}` : '');
    const [scopeData, nationalData] = await Promise.all([
      fetchJSON(`/api/results/switch${query ? '?' + query : ''}`),
      fetchJSON('/api/results/switch'),
    ]);
    const scopeShares = renderSwitchBar(barsContainer, scopeLabel, scopeData.breakdown, false);
    const nationalShares = renderSwitchBar(barsContainer, t('analyticsBaselineLabel'), nationalData.breakdown, true);
    if (leagueId || clubId) {
      renderSwitchTakeaway(takeawayContainer, scopeLabel, scopeShares, nationalShares);
    }
  } catch (err) {
    analyticsShowError('switching-bars');
  }
}

function renderSwitchingScopePicker() {
  const picker = document.getElementById('switching-scope-picker');
  picker.innerHTML = '';

  const nationalOption = document.createElement('option');
  nationalOption.value = '';
  nationalOption.textContent = t('analyticsNational');
  picker.appendChild(nationalOption);

  analyticsOptionsData.leagues.forEach(league => {
    const opt = document.createElement('option');
    opt.value = `league:${league.id}`;
    opt.textContent = localizedName(league);
    picker.appendChild(opt);
  });
  analyticsOptionsData.clubs.forEach(club => {
    const opt = document.createElement('option');
    opt.value = `club:${club.id}`;
    opt.textContent = localizedName(club);
    picker.appendChild(opt);
  });
}

function renderSwitchingTab() {
  const tab = document.getElementById('switching-tab');
  tab.innerHTML = '';

  const field = document.createElement('label');
  field.className = 'field';
  const labelSpan = document.createElement('span');
  labelSpan.textContent = t('analyticsScopeLabel');
  field.appendChild(labelSpan);
  const picker = document.createElement('select');
  picker.id = 'switching-scope-picker';
  field.appendChild(picker);
  tab.appendChild(field);

  const barsContainer = document.createElement('div');
  barsContainer.id = 'switching-bars';
  tab.appendChild(barsContainer);

  const takeawayContainer = document.createElement('p');
  takeawayContainer.id = 'switching-takeaway';
  takeawayContainer.className = 'note';
  tab.appendChild(takeawayContainer);

  renderSwitchingScopePicker();
  picker.addEventListener('change', () => {
    const [kind, id] = (picker.value || '').split(':');
    if (!kind) {
      loadSwitchingScope(null, null, t('analyticsNational'));
    } else if (kind === 'league') {
      const league = analyticsOptionsData.leagues.find(l => l.id === Number(id));
      loadSwitchingScope(Number(id), null, localizedName(league));
    } else {
      const club = analyticsOptionsData.clubs.find(c => c.id === Number(id));
      loadSwitchingScope(null, Number(id), localizedName(club));
    }
  });
  loadSwitchingScope(null, null, t('analyticsNational'));
}
```

Update `initAnalytics()`'s success path from:

```js
  renderDiversityTab();
  renderLeanTab();
}
```

to:

```js
  renderDiversityTab();
  renderLeanTab();
  renderSwitchingTab();
}
```

And the `voteball:langchange` handler from:

```js
document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
  renderLeanTab();
});
```

to:

```js
document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
  renderLeanTab();
  renderSwitchingTab();
});
```

- [ ] **Step 4: Manual verification**

Using the same local stack as Tasks 8-9, insert a few rows into `rollup_vote_switch`/
`rollup_national_vote_switch` directly (or run real votes through `/api/vote` + the worker's
`recompute`), load `results.html`, open the Switching tab, and confirm: the scope picker defaults to
National (single bar, no takeaway sentence since national-vs-national is meaningless — confirmed by
the `if (leagueId || clubId)` guard in `loadSwitchingScope`), picking a club/league shows two bars
(scope + dimmed national baseline) and a takeaway sentence, and manually adjusting the seeded
`stayed` counts to swing the delta across the ±5-point boundary flips the takeaway sentence's wording
correctly.

- [ ] **Step 5: Run the full backend + worker suites one final time**

```bash
cd /home/latnook/Documents/Voteball/ansible-project/roles/backend/files/backend
source .venv/bin/activate && python -m pytest tests/ -v
cd /home/latnook/Documents/Voteball/ansible-project/roles/worker/files/worker
source .venv/bin/activate && python -m pytest tests/ -v
```

Expected: all PASS in both suites.

- [ ] **Step 6: Commit**

```bash
cd /home/latnook/Documents/Voteball
git add ansible-project/roles/frontend/files/nginx/analytics.js \
        ansible-project/roles/frontend/files/nginx/i18n.js \
        ansible-project/roles/frontend/files/nginx/style.css
git commit -m "Implement Switching tab: stayed/hedging/switched vs. national baseline"
```

---

## Self-Review

**Spec coverage:**
- Decisions 1-3 (ideology model, nullable axes, no claimed/actual field) → Task 1 (schema), Task 2
  (seed data).
- Decision 4 (`party_lineage`) → Task 1 (schema), Task 2 (seed rows).
- Decisions 5-6 (5-way switch classification, rollup tables) → Task 1 (schema), Task 6 (worker logic).
- Decisions 7-9 (diversity formula, lean aggregation, previous-election scoping) → Task 8, Task 9.
- Decision 10 (small-sample exclusion) → `DIVERSITY_MIN_VOTES`/`LEAN_MIN_VOTES` filters in Task 8/9.
- Decision 11 (`clubs-breakdown` endpoint) → Task 4/5.
- Decision 12 (`results/switch` endpoint) → Task 4/5.
- Decision 13 (World Cup toggle, default excluded) → Task 8 (`diversityIncludeWorldCup = false`
  initial value).
- Decision 14 (Fan Politics section placement) → Task 7.
- Decisions 15-17 (per-tab layouts) → Tasks 8, 9, 10 respectively.
- Decision 18 (seed-only, no admin UI) → no admin task exists in this plan, matching the decision.
- Appendix (full classification + lineage data) → Task 2.

**Placeholder scan:** No `TBD`/`TODO`/"add appropriate error handling" phrasing anywhere above; every
step shows complete code.

**Type consistency check:**
- `get_results_switch` returns `{'breakdown': [{'status': str, 'count': int}]}` in Task 4 — Task 5's
  routes and Task 10's `analytics.js` (`data.breakdown`, `r.status`, `r.count`) all match this exact
  shape.
- `get_clubs_breakdown` returns `[{'club_id': int, 'previous': [{'party_id': int, 'count': int}]}]` in
  Task 4 — Task 8's `eligibleClubDiversityScores`/`computeEffectiveParties` and Task 9's
  `eligibleClubLeanRows`/`weightedAxisAverage` all consume `entry.previous` as `{party_id, count}`
  objects, matching.
- `get_options`'s `party_lineage` field (`[{previous_party_id, upcoming_party_id}]`, Task 3) is not
  actually consumed anywhere in the frontend (Tasks 8-10 only use per-party `bloc`/`economic`/
  `security`/`sector` fields, not the lineage list itself — lineage only matters to the worker's
  server-side classification in Task 6). This is correct per the design: the frontend never needs to
  replicate the stayed/hedging/switched logic client-side, since `/api/results/switch` already returns
  the pre-classified breakdown. Exposing `party_lineage` via `/api/options` per Decision 4/spec item 11
  is still valuable for any future admin-facing lineage display, so it stays in `get_options`, just
  unused by this plan's frontend tasks — not a bug, a forward-compatible no-op.
- `analyticsOptionsData.previous_parties[i].tags` defaults to `[]` (never `null`) per Task 3's
  `r[8] or []` — Task 9's code never calls `.length`/iterates `tags` (tags aren't rendered in this
  plan's UI, only `bloc`/`economic`/`security`/`sector` are), so this is consistent but currently
  unread; also forward-compatible, not a bug.
- `diversityIncludeWorldCup` (Task 8) is read by both `eligibleClubDiversityScores` (Task 8) and
  `eligibleClubLeanRows` (Task 9) — a single shared toggle state, matching the spec's implicit
  design (one World Cup filter concept, reused). Confirmed both functions reference the same
  module-level variable, not two independent copies.

No gaps found.

---

Plan complete and saved to `docs/superpowers/plans/2026-07-16-party-categorization-analytics.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
