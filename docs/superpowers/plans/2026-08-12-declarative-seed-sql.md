# Declarative `seed.sql` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `services/backend/seed.sql` so every property is set by exactly one statement, eliminating the ~20 patch statements that exist only to correct earlier statements in the same file.

**Architecture:** Two new columns carry what the file currently infers from display names — `seed_key` (immutable identity) and `admin_edited` (column-level provenance). Each entity's data becomes one `TEMP TABLE` populated by one `VALUES` block; four fixed statements (adopt, guard, insert-missing, update-columns) read it. Because `admin_edited` marks the exception explicitly, the base statement becomes authoritative and no patch is ever needed to move an already-seeded value.

**Tech Stack:** PostgreSQL 17, psycopg2, Flask 3.1, pytest against a real Postgres container.

**Design doc:** `docs/design/2026-08-12-seed-sql-declarative-design.md` — read it first.

## Global Constraints

- **Production is always already seeded.** A statement guarded on `IS NULL` reaches a fresh database only. Every change must be verified against a production-shaped database, never only a fresh one.
- **`init_db` runs `schema.sql` then `seed.sql` on every backend pod boot** (`services/backend/db.py:26-29`), as a single `cur.execute()` per file inside one transaction, committed once. A `RAISE EXCEPTION` in `seed.sql` is a `CrashLoopBackOff`, not a failed request.
- **`vote_clubs.club_id` references `clubs(id)` with no `ON DELETE CASCADE`.** Any `DELETE FROM clubs` must carry `AND NOT EXISTS (SELECT 1 FROM vote_clubs vc WHERE vc.club_id = c.id)`. Production holds 22 votes.
- **The six ideology `UPDATE`s stay unguarded**; names and `logo_url` stay protected — now by `admin_edited` rather than `COALESCE`/`IS NULL`. Do not "make them consistent."
- **Russian names must be Cyrillic.** `test_migration.py::test_seeded_russian_names_are_cyrillic` asserts it; a Latin homoglyph (`РААМ` vs `PAAM`) passes visual review and fails the test.
- **Do not add a `Claude-Session:` trailer to any commit** (root `CLAUDE.md`; the repo is public).
- **Commit and push as you go.** Never force-push.
- **Pin the baseline ref once, in Task 1, and use it for every harness run:** `git tag seed-baseline HEAD` before any change. Every later `verify-neutrality.sh "$DUMP" seed-baseline` then compares against the same pre-refactor files. Counting `HEAD~n` by hand drifts as commits accumulate and silently compares the wrong thing.
- **Baseline established 2026-08-12:** production and a fresh seed differ in **107 fields, all of them the vestigial legacy `name` column** (104 `clubs.name`, 3 `leagues.name`). Zero divergence in `name_en`/`name_he`/`name_ru`/`logo_url`/`group_label`/`sort_order`/`has_divisions` or any ideology column; both party tables are identical. Therefore `admin_edited` starts empty for every row and adoption on `name_en`/`name_he` matches 100% of rows. **If Task 1's harness reproduces anything other than 107 name-only diffs, stop — production has changed and the adoption matcher needs an exceptions list.**

## File Structure

| File | Responsibility |
|---|---|
| `scripts/seed/snapshot.py` | **Create.** Dump the five seeded tables from any database to normalized JSON (timestamps excluded, sorted by natural key). The diff primitive. |
| `scripts/seed/verify-neutrality.sh` | **Create.** Build databases A/B/C, apply files, diff. The data-neutrality proof. |
| `scripts/seed/generate-tables.py` | **Create.** Emit `seed.sql`'s `VALUES` blocks from a seeded database, so the data is transcribed by machine rather than by hand. |
| `services/backend/schema.sql` | **Modify.** Add `seed_key` + `admin_edited` columns and indexes; absorb the `name_en`/`name_he` backfill from `seed.sql`. |
| `services/backend/queries.py` | **Modify.** Four `rename_*` functions record genuinely-changed columns in `admin_edited`. |
| `services/backend/seed.sql` | **Rewrite.** Four straight tables + fixed mechanism statements. |
| `services/backend/tests/test_migration.py` | **Modify.** Add the provenance and adoption tests. |
| `services/backend/tests/test_queries.py` | **Modify.** Add the `admin_edited` diffing tests. |
| `services/backend/CLAUDE.md` | **Modify.** Replace the guard-mechanics rules with the new ones. |

`scripts/seed/` sits at the repo root, **outside** the `services/backend` Docker build context, so no `Dockerfile` `COPY` line changes and no dev-only file ships in the image. It is not added to `scripts/tests/run-ci-suite.sh` — that suite is offline-only and this harness needs a live Postgres.

---

### Task 1: Verification harness and baseline

Nothing else starts until the proof exists. This task produces the tool that every later task is checked with, and freezes today's behaviour as the baseline.

**Files:**
- Create: `scripts/seed/snapshot.py`
- Create: `scripts/seed/verify-neutrality.sh`

**Interfaces:**
- Produces: `snapshot.py --dsn <dsn>` writes normalized JSON to stdout. `verify-neutrality.sh <prod-dump.sql>` exits non-zero on any non-empty diff.

- [ ] **Step 1: Write the snapshot tool**

Create `scripts/seed/snapshot.py`:

```python
#!/usr/bin/env python3
"""Dump the five seeded tables to normalized JSON for data-neutrality diffing.

Two normalizations exist because both previously produced a confident "31 unexplained
changes" against a refactor that was in fact exact (services/backend/CLAUDE.md):

  * timestamps are excluded -- the databases being compared are seeded seconds apart,
    so every `updated_at` differs;
  * rows are keyed by their natural key, never sorted by whole-row text -- if a value
    changes, row text changes, sort order changes with it, and diff reports dozens of
    unrelated rows as modified.

Surrogate `id` columns are excluded for the same reason: they are assignment order, not data.
"""
import argparse
import json
import sys

import psycopg2

# table -> (natural key, columns compared)
TABLES = {
    'leagues': ('name_en',
                ['name', 'name_en', 'name_he', 'name_ru', 'logo_url',
                 'sort_order', 'has_divisions']),
    'clubs': ('name_en',
              ['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'group_label']),
    'previous_parties': ('name_he',
                         ['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'bloc',
                          'economic', 'security', 'religiosity', 'sector', 'tags']),
    'upcoming_parties': ('name_he',
                         ['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'bloc',
                          'economic', 'security', 'religiosity', 'sector', 'tags',
                          'families', 'family_evidence']),
}


def snapshot(dsn, include=()):
    """Return {table: {natural_key: {column: value}}}.

    `include` names extra columns to compare where they exist -- used to inspect
    seed_key/admin_edited, which are excluded by default because they do not exist
    in the old schema and would make every baseline diff non-empty.
    """
    out = {}
    with psycopg2.connect(dsn) as conn:
        for table, (key, columns) in TABLES.items():
            cols = list(columns)
            for extra in include:
                if extra not in cols and _has_column(conn, table, extra):
                    cols.append(extra)
            with conn.cursor() as cur:
                cur.execute(
                    'SELECT {} FROM {}'.format(', '.join(cols), table))
                rows = cur.fetchall()
            out[table] = {
                row[cols.index(key)]: {
                    c: (list(v) if isinstance(v, list) else v)
                    for c, v in zip(cols, row)
                }
                for row in rows
            }
        # party_lineage carries no natural key of its own; resolve it to party names
        # so it survives id reassignment between databases.
        with conn.cursor() as cur:
            cur.execute(
                'SELECT p.name_he, u.name_he FROM party_lineage l '
                'JOIN previous_parties p ON p.id = l.previous_party_id '
                'JOIN upcoming_parties u ON u.id = l.upcoming_party_id')
            out['party_lineage'] = {
                '{} -> {}'.format(a, b): {'linked': True} for a, b in cur.fetchall()
            }
    return out


def _has_column(conn, table, column):
    with conn.cursor() as cur:
        cur.execute(
            'SELECT 1 FROM information_schema.columns '
            'WHERE table_name = %s AND column_name = %s', (table, column))
        return cur.fetchone() is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dsn', required=True)
    ap.add_argument('--include', default='',
                    help='comma-separated extra columns to compare, e.g. seed_key')
    args = ap.parse_args()
    extra = [c for c in args.include.split(',') if c]
    json.dump(snapshot(args.dsn, extra), sys.stdout,
              ensure_ascii=False, indent=1, sort_keys=True, default=str)
    print()


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Verify the snapshot tool reproduces the known baseline**

The production dump already exists from the design phase; if it does not, re-take it (Step 4 below).

Run against the fresh database seeded with the **current** files:

```bash
cd /home/latnook/Documents/Voteball
python3 scripts/seed/snapshot.py --dsn "postgres://postgres:test@localhost:5432/seedbase" | head -20
```

Expected: JSON with `clubs`, `leagues`, `party_lineage`, `previous_parties`, `upcoming_parties` keys.

- [ ] **Step 3: Write the neutrality harness**

Create `scripts/seed/verify-neutrality.sh`:

```bash
#!/usr/bin/env bash
# Proves a seed.sql restructure is data-neutral, per services/backend/CLAUDE.md.
#
# Three databases, because a fresh one proves nothing on its own -- a guarded block would
# set the value there anyway. Only the production-shaped database can show that an
# ALREADY-SEEDED database ends up where it is today, which is the only kind that exists
# in production.
#
#   C = production dump + OLD files   (the baseline: current behaviour)
#   A = production dump + NEW files   (the migration)
#   B = empty          + NEW files    (a fresh install)
#
# A == C is the diff that matters. A == B confirms fresh and migrated converge.
#
# Usage: verify-neutrality.sh <production-dump.sql> <old-git-ref>
set -euo pipefail

DUMP="${1:?usage: verify-neutrality.sh <production-dump.sql> <old-git-ref>}"
OLD_REF="${2:?usage: verify-neutrality.sh <production-dump.sql> <old-git-ref>}"
CONTAINER="${SEED_TEST_CONTAINER:-voteball-test-db}"
DSN_BASE="postgres://postgres:test@localhost:5432"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Old files come from git, not from a hand-kept copy: a restated copy of the previous
# behaviour would pass throughout any period the real file diverged from it.
git -C "$ROOT" show "$OLD_REF:services/backend/schema.sql" > "$WORK/old-schema.sql"
git -C "$ROOT" show "$OLD_REF:services/backend/seed.sql"   > "$WORK/old-seed.sql"

psql_db() { docker exec -i "$CONTAINER" psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }

build() {   # build <dbname> <dump-or-empty> <schema> <seed>
    local db="$1" dump="$2" schema="$3" seed="$4"
    docker exec "$CONTAINER" psql -U postgres -q \
        -c "DROP DATABASE IF EXISTS $db;" -c "CREATE DATABASE $db;" >/dev/null
    [ -n "$dump" ] && psql_db -d "$db" < "$dump"
    psql_db -d "$db" < "$schema"
    psql_db -d "$db" < "$seed"
}

echo "==> C: production dump + OLD files"
build seed_c "$DUMP" "$WORK/old-schema.sql" "$WORK/old-seed.sql"
echo "==> A: production dump + NEW files"
build seed_a "$DUMP" "$ROOT/services/backend/schema.sql" "$ROOT/services/backend/seed.sql"
echo "==> B: empty + NEW files"
build seed_b ""      "$ROOT/services/backend/schema.sql" "$ROOT/services/backend/seed.sql"

for db in a b c; do
    python3 "$ROOT/scripts/seed/snapshot.py" --dsn "$DSN_BASE/seed_$db" > "$WORK/$db.json"
done

status=0
echo
echo "==> DIFF A vs C  (already-seeded database is unchanged -- THE diff that matters)"
if diff -u "$WORK/c.json" "$WORK/a.json"; then echo "    OK: empty"; else status=1; fi
echo
echo "==> DIFF A vs B  (fresh install and migrated database converge)"
if diff -u "$WORK/b.json" "$WORK/a.json"; then echo "    OK: empty"; else status=1; fi
echo
echo "==> IDEMPOTENCE: re-apply new seed.sql to A"
psql_db -d seed_a < "$ROOT/services/backend/seed.sql"
python3 "$ROOT/scripts/seed/snapshot.py" --dsn "$DSN_BASE/seed_a" > "$WORK/a2.json"
if diff -u "$WORK/a.json" "$WORK/a2.json"; then echo "    OK: empty"; else status=1; fi

[ $status -eq 0 ] && echo && echo "PASS: restructure is data-neutral" || echo >&2 "FAIL: see diffs above"
exit $status
```

- [ ] **Step 4: Take the production dump**

The cluster is live. The backend pod has no `pg_dump`, so dump through a port-forward:

```bash
cd /home/latnook/Documents/Voteball
POD=$(kubectl get pods -n devops-app -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n devops-app "$POD" 15432:5432 &
sleep 3
PGPASSWORD="$(kubectl get secret -n devops-app app-secret -o jsonpath='{.data.DB_PASS}' | base64 -d)" \
  pg_dump -h localhost -p 15432 -U voteball -d voteball --no-owner --no-acl \
  > /tmp/claude-1000/-home-latnook-Documents-Voteball/*/scratchpad/prod.sql
kill %1
wc -l /tmp/claude-1000/-home-latnook-Documents-Voteball/*/scratchpad/prod.sql
```

If the port-forward is blocked, fall back to the psycopg2 extraction used during design (`scripts/seed/snapshot.py --dsn` against the pod) and reconstruct — but prefer the real dump, it carries the FK graph and the 22 votes that the removal guard depends on.

- [ ] **Step 5: Run the harness against HEAD to prove it detects nothing**

With no changes made yet, A/B/C are all built from the same files, so all three diffs must be empty:

```bash
chmod +x scripts/seed/verify-neutrality.sh
git tag seed-baseline HEAD            # every later run compares against this exact ref
scripts/seed/verify-neutrality.sh "$DUMP" seed-baseline
```

Expected: `PASS: restructure is data-neutral`. **If this fails now, the harness is wrong, not the code** — fix it before touching `seed.sql`.

- [ ] **Step 6: Commit**

```bash
git add scripts/seed/snapshot.py scripts/seed/verify-neutrality.sh
git commit -m "test(seed): data-neutrality harness for seed.sql restructuring

Three databases, because a fresh one proves nothing: a guarded block would set
the value there anyway. Only production-dump + new files shows that an
already-seeded database -- the only kind that exists in production -- ends up
unchanged. Old files come from git rather than a kept copy, so the baseline
cannot silently drift from what the file actually did."
git push -u origin feat/declarative-seed-sql
```

---

### Task 2: Schema — `seed_key` and `admin_edited`

**Files:**
- Modify: `services/backend/schema.sql` (append after the existing `ALTER TABLE` migrations, ~line 141)
- Modify: `services/backend/tests/test_migration.py`

**Interfaces:**
- Produces: `seed_key TEXT` (unique where not null) and `admin_edited TEXT[] NOT NULL DEFAULT '{}'` on `leagues`, `clubs`, `previous_parties`, `upcoming_parties`.

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_migration.py`:

```python
SEEDED_TABLES = ('leagues', 'clubs', 'previous_parties', 'upcoming_parties')


def test_seed_provenance_columns_exist(conn):
    """seed_key is immutable identity; admin_edited is column-level provenance.

    Both replace inference from display names, which the admin UI and seed.sql
    both rewrite -- 104 of 212 production clubs carry a drifted legacy `name`.
    """
    cur = conn.cursor()
    for table in SEEDED_TABLES:
        cur.execute(
            'SELECT column_name, data_type, is_nullable, column_default '
            'FROM information_schema.columns '
            'WHERE table_name = %s AND column_name IN (%s, %s)',
            (table, 'seed_key', 'admin_edited'))
        found = {r[0]: r for r in cur.fetchall()}
        assert 'seed_key' in found, f'{table} is missing seed_key'
        assert 'admin_edited' in found, f'{table} is missing admin_edited'
        assert found['admin_edited'][2] == 'NO', f'{table}.admin_edited must be NOT NULL'
        assert found['admin_edited'][3] is not None, \
            f'{table}.admin_edited needs a default, or every insert must name it'
    cur.close()


def test_seed_key_is_unique_but_allows_admin_created_rows(conn):
    """NULL seed_key means "created through the admin UI", and seed.sql ignores those.

    So the index must be partial: many NULLs allowed, duplicates of a real key not.
    """
    cur = conn.cursor()
    # Assign the key explicitly rather than reading one from the table: this task adds the
    # column but nothing populates it until Task 4, so a SELECT ... WHERE seed_key IS NOT NULL
    # returns no rows here and the test would fail on a TypeError instead of its assertion.
    cur.execute("INSERT INTO leagues (name, name_en) VALUES ('Placeholder A', 'Placeholder A')")
    cur.execute("INSERT INTO leagues (name, name_en) VALUES ('Placeholder B', 'Placeholder B')")
    conn.commit()  # two NULL seed_keys coexist -- the partial index must allow this

    cur.execute("UPDATE leagues SET seed_key = 'placeholder-a' WHERE name_en = 'Placeholder A'")
    conn.commit()

    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute("UPDATE leagues SET seed_key = 'placeholder-a' WHERE name_en = 'Placeholder B'")
    conn.rollback()
    cur.close()
```

Ensure `import pytest` and `import psycopg2` are present at the top of the file.

- [ ] **Step 2: Run it to verify it fails**

```bash
cd services/backend && source .venv/bin/activate
python -m pytest tests/test_migration.py::test_seed_provenance_columns_exist -v
```

Expected: FAIL — `leagues is missing seed_key`.

- [ ] **Step 3: Add the columns**

Append to `services/backend/schema.sql`, after the `religiosity` migrations:

```sql
-- Stable seed identity (2026-08-12). Every statement in seed.sql matches on seed_key and
-- nothing else. Display names cannot serve as identity: the admin endpoints overwrite the
-- legacy `name` column with name_he on ANY save (including a no-op one), and seed.sql used
-- to rewrite its own name_en literals -- 104 of 212 production clubs and 3 of 10 leagues
-- carry a drifted `name` because of it. seed_key is never displayed, never writable through
-- the API and never changes once assigned.
--
-- NULL means "created through the admin UI", which is what makes seed.sql's declarative
-- removal safe: it only ever deletes rows it owns. Hence a PARTIAL unique index.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS seed_key TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS seed_key TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS seed_key TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS seed_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS leagues_seed_key_uidx          ON leagues (seed_key)          WHERE seed_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_seed_key_uidx            ON clubs (seed_key)            WHERE seed_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS previous_parties_seed_key_uidx ON previous_parties (seed_key) WHERE seed_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS upcoming_parties_seed_key_uidx ON upcoming_parties (seed_key) WHERE seed_key IS NOT NULL;

-- Column-level provenance (2026-08-12). Lists the columns a human has actually CHANGED
-- through the admin UI; seed.sql overwrites every column not listed here.
--
-- This inverts the old rule. Names and logo_url used to be guarded with COALESCE/IS NULL so
-- they could only fill an empty cell -- which meant editing a literal reached a fresh
-- database only, and moving an already-seeded value needed a separate patch statement
-- appended to the file. There were about twenty such patches. With the exception recorded
-- explicitly, the base statement can be authoritative and no patch is needed.
--
-- Empty for every existing row on purpose: verified 2026-08-12 that production and a fresh
-- seed differ in 107 fields, ALL of them the vestigial legacy `name` column, so no live
-- admin edit exists to preserve.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';

-- Moved here from seed.sql (design decision 6): this is a migration, and schema.sql is the
-- migration file. It must run BEFORE seed.sql's adoption statements, which key on name_en
-- and name_he -- a database restored from a snapshot old enough to predate those columns
-- would otherwise have every row fail to adopt and raise the duplicate guard.
UPDATE leagues           SET name_en = name WHERE name_en IS NULL;
UPDATE clubs             SET name_en = name WHERE name_en IS NULL;
UPDATE previous_parties  SET name_he = name WHERE name_he IS NULL;
UPDATE upcoming_parties  SET name_he = name WHERE name_he IS NULL;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
python -m pytest tests/test_migration.py -v -k "seed_provenance or seed_key_is_unique"
```

Expected: 2 passed. Then the full suite: `python -m pytest tests/ -q` — expected: all pass, nothing regressed.

- [ ] **Step 5: Confirm neutrality still holds**

```bash
cd ../.. && scripts/seed/verify-neutrality.sh "$DUMP" HEAD
```

Expected: PASS. The new columns are excluded from `snapshot.py` by default, so adding them must not move any compared value.

- [ ] **Step 6: Commit**

```bash
git add services/backend/schema.sql services/backend/tests/test_migration.py
git commit -m "feat(schema): add seed_key identity and admin_edited provenance columns

seed_key replaces display names as seed.sql's match key -- the admin endpoints
overwrite the legacy name column with name_he on any save, so 104 of 212
production clubs already carry a drifted one. Partial unique index: NULL means
admin-created, which is what will make declarative removal safe.

admin_edited lists columns a human actually changed, letting the base statement
be authoritative instead of guarded, which is what removes the need for patches."
git push -u origin feat/declarative-seed-sql
```

---

### Task 3: Record provenance in the admin write paths

**Files:**
- Modify: `services/backend/queries.py` — `rename_upcoming_party:360`, `rename_previous_party:416`, `rename_league:608`, `rename_club:778`
- Modify: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: `admin_edited` from Task 2.
- Produces: `_admin_edited_after(cur, table, row_id, incoming) -> list[str] | None` in `queries.py`. All four `rename_*` signatures are unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `services/backend/tests/test_queries.py`:

```python
def test_no_op_admin_save_records_no_provenance(conn):
    """A save that changes nothing must not claim the row for the admin.

    All four admin endpoints replace every field they receive, so "saved" cannot mean
    "owned": admin.js's "Add to UEFA Champions League" button resends
    name_en/name_he/name_ru/logo_url unchanged while setting a league link. If that
    marked every resent column, one click would freeze that club's Russian name forever.
    """
    cur = conn.cursor()
    # league_id and domestic_league_id must be re-sent as they are: clubs.league_id is
    # NOT NULL, and passing domestic_league_id=None would itself count as a change and
    # land in admin_edited -- breaking the very assertion this test makes.
    cur.execute("SELECT id, league_id, domestic_league_id, name_en, name_he, name_ru, logo_url "
                "FROM clubs WHERE name_en = 'Bayern Munich'")
    club_id, league_id, domestic_id, name_en, name_he, name_ru, logo_url = cur.fetchone()

    queries.rename_club(conn, club_id, league_id=league_id, domestic_league_id=domestic_id,
                        name_en=name_en, name_he=name_he, name_ru=name_ru,
                        logo_url=logo_url)

    cur.execute('SELECT admin_edited FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == []
    cur.close()


def test_changed_field_records_exactly_that_field(conn):
    cur = conn.cursor()
    cur.execute("SELECT id, league_id, domestic_league_id, name_en, name_he, name_ru, logo_url "
                "FROM clubs WHERE name_en = 'Bayern Munich'")
    club_id, league_id, domestic_id, name_en, name_he, name_ru, logo_url = cur.fetchone()

    queries.rename_club(conn, club_id, league_id=league_id, domestic_league_id=domestic_id,
                        name_en=name_en, name_he=name_he, name_ru=name_ru,
                        logo_url='https://example.invalid/my-own-crest.svg')

    cur.execute('SELECT admin_edited FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == ['logo_url']
    cur.close()


def test_provenance_accumulates_across_saves(conn):
    cur = conn.cursor()
    cur.execute("SELECT id, league_id, domestic_league_id, name_en, name_he, name_ru, logo_url "
                "FROM clubs WHERE name_en = 'Arsenal'")
    club_id, league_id, domestic_id, name_en, name_he, name_ru, logo_url = cur.fetchone()

    queries.rename_club(conn, club_id, league_id, domestic_id, name_en, name_he, name_ru,
                        'https://example.invalid/one.svg')
    queries.rename_club(conn, club_id, league_id, domestic_id, name_en, name_he,
                        'Арсенал ФК', 'https://example.invalid/one.svg')

    cur.execute('SELECT admin_edited FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == ['logo_url', 'name_ru']
    cur.close()


def test_provenance_is_recorded_for_every_renamable_table(conn):
    """All four rename paths, not just clubs -- a missed one silently loses an edit."""
    cur = conn.cursor()
    cur.execute("SELECT id, name_en, name_he, name_ru FROM leagues WHERE name_en = 'La Liga'")
    lid, en, he, ru = cur.fetchone()
    queries.rename_league(conn, lid, en, he, ru, 'https://example.invalid/ll.svg')
    cur.execute('SELECT admin_edited FROM leagues WHERE id = %s', (lid,))
    assert cur.fetchone()[0] == ['logo_url']

    cur.execute("SELECT id, name_en, name_he, name_ru, logo_url FROM previous_parties "
                "WHERE name_he = 'הליכוד'")
    pid, en, he, ru, logo = cur.fetchone()
    queries.rename_previous_party(conn, pid, 'Likud Party', he, ru, logo)
    cur.execute('SELECT admin_edited FROM previous_parties WHERE id = %s', (pid,))
    assert cur.fetchone()[0] == ['name_en']

    cur.execute("SELECT id, name_en, name_he, name_ru, logo_url FROM upcoming_parties "
                "WHERE name_he = 'הליכוד'")
    uid, en, he, ru, logo = cur.fetchone()
    queries.rename_upcoming_party(conn, uid, en, he, 'Ликуд-2026', logo)
    cur.execute('SELECT admin_edited FROM upcoming_parties WHERE id = %s', (uid,))
    assert cur.fetchone()[0] == ['name_ru']
    cur.close()
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd services/backend && source .venv/bin/activate
python -m pytest tests/test_queries.py -v -k provenance
```

Expected: FAIL — `assert None == []` or a missing-column error.

- [ ] **Step 3: Add the helper**

Insert into `services/backend/queries.py`, above `rename_upcoming_party`:

```python
# Columns whose ownership can pass from seed.sql to the admin. Adding a column here is
# what makes it protectable; forgetting to means seed.sql will overwrite admin edits to it.
_PROVENANCE_COLUMNS = ('name_en', 'name_he', 'name_ru', 'logo_url')


def _admin_edited_after(cur, table, row_id, incoming, extra=()):
    """Return row_id's admin_edited array after applying `incoming`, or None if it is gone.

    Only columns whose value actually CHANGES are added. Every admin endpoint replaces all
    the fields it receives, so marking each submitted column would let a single no-op save
    freeze the rest of the row: admin.js's continental-competition buttons resend
    name_en/name_he/name_ru/logo_url untouched, and historically did so for 104 of 212 clubs.

    `extra` names additional columns to compare that are not in _PROVENANCE_COLUMNS --
    rename_club passes 'domestic_league_id', an integer FK rather than one of the four text
    columns, but equally admin-writable: both PATCH /api/admin/clubs/<id> and the admin UI's
    continental-competition buttons set it, so seed.sql must yield to a human's link too.

    `table` is interpolated because psycopg2 cannot parameterise an identifier; every call
    site passes a literal from this module, never request data.
    """
    columns = tuple(_PROVENANCE_COLUMNS) + tuple(extra)
    cur.execute(
        'SELECT admin_edited, {} FROM {} WHERE id = %s'.format(
            ', '.join(columns), table),
        (row_id,))
    row = cur.fetchone()
    if row is None:
        return None
    edited = set(row[0] or [])
    for column, current in zip(columns, row[1:]):
        if incoming.get(column) != current:
            edited.add(column)
    return sorted(edited)
```

- [ ] **Step 4: Wire it into all four rename functions**

`rename_club` becomes (the other three follow the identical shape — write each out, do not abbreviate):

```python
def rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he, name_ru=None, logo_url=None):
    cur = conn.cursor()
    try:
        edited = _admin_edited_after(cur, 'clubs', club_id, {
            'name_en': name_en, 'name_he': name_he,
            'name_ru': name_ru, 'logo_url': logo_url,
            'domestic_league_id': domestic_league_id,
        }, extra=('domestic_league_id',))
        if edited is None:
            return False
        cur.execute(
            'UPDATE clubs SET league_id = %s, domestic_league_id = %s, name = %s, name_en = %s, '
            'name_he = %s, name_ru = %s, logo_url = %s, admin_edited = %s WHERE id = %s',
            (league_id, domestic_league_id, name_he, name_en, name_he, name_ru, logo_url,
             edited, club_id)
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
```

Apply the same to `rename_league` (table `'leagues'`), `rename_previous_party` (`'previous_parties'`, keep `updated_at = NOW()`) and `rename_upcoming_party` (`'upcoming_parties'`, keep `updated_at = NOW()`).

- [ ] **Step 5: Run the tests to verify they pass**

```bash
python -m pytest tests/test_queries.py -v -k provenance
python -m pytest tests/ -q
```

Expected: 4 new tests pass; full suite green (175+ tests).

- [ ] **Step 6: Commit**

```bash
git add services/backend/queries.py services/backend/tests/test_queries.py
git commit -m "feat(admin): record genuinely-changed columns in admin_edited

The four rename endpoints replace every field they receive, so \"saved\" cannot
mean \"owned\" -- admin.js's continental-competition buttons resend all four name
and logo fields unchanged. Marking every submitted column would freeze the rest
of the row on the first no-op save. Each function now diffs against the stored
row and records only what actually moved."
git push -u origin feat/declarative-seed-sql
```

---

### Task 4: Generator, and the leagues table converted

Leagues is the smallest table (10 rows, 7 properties) and carries five of the patch classes, so it proves the whole mechanism before 212 clubs ride on it.

**Files:**
- Create: `scripts/seed/generate-tables.py`
- Modify: `services/backend/seed.sql` (leagues section: replace lines ~16-30, ~338-437)
- Modify: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: `seed_key`/`admin_edited` (Task 2), `verify-neutrality.sh` (Task 1).
- Produces: `seed_leagues` temp table with columns `(seed_key, name_en, name_he, name_ru, logo_url, sort_order, has_divisions)`.

- [ ] **Step 1: Write the generator**

Create `scripts/seed/generate-tables.py`:

```python
#!/usr/bin/env python3
"""Emit seed.sql's straight tables from a seeded database.

The data is transcribed by machine, not by hand. 212 clubs across four merged statements
is exactly the kind of retyping that produces a silently wrong row, and the guard that
used to catch a duplicate key ("first in file order wins") no longer exists -- a VALUES
block joins, so a repeated key matches arbitrarily.

Usage: generate-tables.py --dsn <dsn> --table leagues|clubs|previous_parties|upcoming_parties
"""
import argparse
import re
import unicodedata

import psycopg2

SPECS = {
    'leagues': dict(
        slug_from='name_en',
        columns=['name_en', 'name_he', 'name_ru', 'logo_url', 'sort_order', 'has_divisions'],
        types='seed_key TEXT PRIMARY KEY, name_en TEXT, name_he TEXT, name_ru TEXT, '
              'logo_url TEXT, sort_order INTEGER, has_divisions BOOLEAN',
        order='sort_order'),
    'clubs': dict(
        slug_from='name_en',
        columns=['name_en', 'name_he', 'name_ru', 'logo_url', 'group_label'],
        types='seed_key TEXT PRIMARY KEY, league TEXT, also_in TEXT, name_en TEXT, '
              'name_he TEXT, name_ru TEXT, logo_url TEXT, group_label TEXT',
        order='id'),
    'previous_parties': dict(
        slug_from='name_en',
        columns=['name_he', 'name_en', 'name_ru', 'logo_url', 'bloc', 'economic',
                 'security', 'religiosity', 'sector', 'tags'],
        types='seed_key TEXT PRIMARY KEY, name_he TEXT, name_en TEXT, name_ru TEXT, '
              'logo_url TEXT, bloc TEXT, economic INTEGER, security INTEGER, '
              'religiosity INTEGER, sector TEXT, tags TEXT[]',
        order='id'),
    'upcoming_parties': dict(
        slug_from='name_en',
        columns=['name_he', 'name_en', 'name_ru', 'logo_url', 'bloc', 'economic',
                 'security', 'religiosity', 'sector', 'tags', 'families', 'family_evidence'],
        types='seed_key TEXT PRIMARY KEY, name_he TEXT, name_en TEXT, name_ru TEXT, '
              'logo_url TEXT, bloc TEXT, economic INTEGER, security INTEGER, '
              'religiosity INTEGER, sector TEXT, tags TEXT[], families TEXT[], '
              'family_evidence TEXT',
        order='id'),
}


def slug(value):
    """ASCII kebab-case identity. Latin-transliterable names only; parties use name_en."""
    text = unicodedata.normalize('NFKD', value or '')
    text = text.encode('ascii', 'ignore').decode('ascii').lower()
    text = re.sub(r'[^a-z0-9]+', '-', text).strip('-')
    return text


def lit(value):
    if value is None:
        return 'NULL'
    if isinstance(value, bool):
        return 'TRUE' if value else 'FALSE'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        if not value:
            return "'{}'"
        inner = ', '.join("'{}'".format(v.replace("'", "''")) for v in value)
        return 'ARRAY[{}]::text[]'.format(inner)
    return "'{}'".format(str(value).replace("'", "''"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dsn', required=True)
    ap.add_argument('--table', required=True, choices=sorted(SPECS))
    args = ap.parse_args()
    spec = SPECS[args.table]

    with psycopg2.connect(args.dsn) as conn, conn.cursor() as cur:
        if args.table == 'clubs':
            cur.execute(
                'SELECT c.name_en, l.name_en, d.name_en, {} FROM clubs c '
                'JOIN leagues l ON l.id = c.league_id '
                'LEFT JOIN leagues d ON d.id = c.domestic_league_id '
                'ORDER BY l.sort_order, c.name_en'.format(
                    ', '.join('c.' + c for c in spec['columns'])))
            rows = [(slug(r[0]), slug(r[1]), slug(r[2]) if r[2] else None) + tuple(r[3:])
                    for r in cur.fetchall()]
        else:
            cols = spec['columns']
            cur.execute('SELECT {} FROM {} ORDER BY {}'.format(
                ', '.join(cols), args.table, spec['order']))
            slug_at = cols.index(spec['slug_from'])
            rows = [(slug(r[slug_at]),) + tuple(r) for r in cur.fetchall()]

    keys = [r[0] for r in rows]
    dupes = sorted({k for k in keys if keys.count(k) > 1})
    # A duplicate key is silent under the new scheme and must fail here. With one statement
    # per row the IS NULL guard made it "first in file order wins"; a VALUES block JOINS, so
    # a repeated key lets Postgres match arbitrarily -- same SQL, non-deterministic row.
    assert not dupes, 'duplicate seed_key: {}'.format(dupes)
    assert all(keys), 'empty seed_key generated -- a source name was NULL or non-Latin'

    print('CREATE TEMP TABLE seed_{} ({}) ON COMMIT DROP;'.format(args.table, spec['types']))
    print('INSERT INTO seed_{} VALUES'.format(args.table))
    for i, row in enumerate(rows):
        end = ';' if i == len(rows) - 1 else ','
        print('    ({}){}'.format(', '.join(lit(v) for v in row), end))


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Generate the leagues block and eyeball it**

```bash
cd /home/latnook/Documents/Voteball
python3 scripts/seed/generate-tables.py \
  --dsn postgres://postgres:test@localhost:5432/seedbase --table leagues
```

Expected: 10 rows, `sort_order` 0–9, `nations-league` the only `TRUE` for `has_divisions`, `la-liga` carrying the `assets.laliga.com` URL (its post-patch value) and `uefa-champions-league` carrying `/logos/uefa-champions-league.svg`. If any row still shows a pre-patch value, the source database was not fully seeded — re-seed it and regenerate.

- [ ] **Step 3: Write the failing tests**

Append to `services/backend/tests/test_migration.py`:

```python
def test_seed_overwrites_a_column_the_admin_never_touched(conn):
    """The guarantee the whole redesign exists for, and which nothing used to test.

    Under the old COALESCE/IS NULL guards this was FALSE: editing a literal reached a
    fresh database only, so every corrected value needed its own patch statement.
    """
    cur = conn.cursor()
    cur.execute("UPDATE leagues SET name_ru = 'stale value' WHERE seed_key = 'la-liga'")
    conn.commit()

    db.init_db(conn)  # what happens on every backend pod boot

    cur.execute("SELECT name_ru FROM leagues WHERE seed_key = 'la-liga'")
    assert cur.fetchone()[0] == 'Ла Лига'
    cur.close()


def test_seed_leaves_an_admin_edited_column_alone(conn):
    cur = conn.cursor()
    cur.execute("UPDATE leagues SET name_ru = 'Моя Лига', admin_edited = ARRAY['name_ru'] "
                "WHERE seed_key = 'la-liga'")
    conn.commit()

    db.init_db(conn)

    cur.execute("SELECT name_ru, name_he FROM leagues WHERE seed_key = 'la-liga'")
    name_ru, name_he = cur.fetchone()
    assert name_ru == 'Моя Лига', 'an admin edit was overwritten'
    assert name_he == 'לה ליגה', 'provenance must be per-column, not per-row'
    cur.close()


def test_every_league_is_adopted_by_seed_key(conn):
    cur = conn.cursor()
    cur.execute('SELECT count(*) FROM leagues WHERE seed_key IS NULL')
    assert cur.fetchone()[0] == 0
    cur.execute('SELECT count(DISTINCT seed_key), count(*) FROM leagues')
    distinct, total = cur.fetchone()
    assert distinct == total
    cur.close()
```

- [ ] **Step 4: Run them to verify they fail**

```bash
cd services/backend && python -m pytest tests/test_migration.py -v \
  -k "overwrites_a_column or leaves_an_admin_edited or adopted_by_seed_key"
```

Expected: FAIL — no `seed_key` values exist yet.

- [ ] **Step 5: Replace the leagues section of `seed.sql`**

Delete the leagues `INSERT` (lines ~16-30), the names `UPDATE` block, the two `name_en` rewrites, the two `name_ru` renames, the ten `sort_order` statements, the two `has_divisions` statements, the logo `VALUES` block and its three follow-up corrections. Replace with the generated table plus this fixed mechanism:

```sql
-- ---------------------------------------------------------------------------
-- LEAGUES
-- ---------------------------------------------------------------------------
<paste the generated CREATE TEMP TABLE / INSERT from Step 2 here>

-- Adopt rows that predate seed_key, keyed on name_en. Not on the legacy `name` column:
-- the admin endpoints overwrite it with name_he on any save, and 3 of 10 production
-- leagues already carry a drifted one.
UPDATE leagues t SET seed_key = s.seed_key
FROM seed_leagues s
WHERE t.seed_key IS NULL AND t.name_en = s.name_en;

-- Refuse to insert a duplicate of a row that exists but could not be adopted. This is the
-- 2026-07-17 incident: a phantom 'UCL' row produced duplicate clubs and crashed init_db on
-- every pod boot. Failing loudly here is the better failure -- and the neutrality harness
-- is what stops it reaching production at all.
DO $$
DECLARE unadopted TEXT;
BEGIN
    SELECT string_agg(s.seed_key, ', ') INTO unadopted
    FROM seed_leagues s
    WHERE NOT EXISTS (SELECT 1 FROM leagues t WHERE t.seed_key = s.seed_key)
      AND EXISTS (SELECT 1 FROM leagues t
                  WHERE t.name_en = s.name_en OR t.name_he = s.name_he);
    IF unadopted IS NOT NULL THEN
        RAISE EXCEPTION 'seed.sql: leagues % exist but were not adopted; a name matches '
                        'while seed_key does not. Fix the adoption matcher -- inserting '
                        'would duplicate the row (2026-07-17 incident).', unadopted;
    END IF;
END $$;

INSERT INTO leagues (seed_key, name, name_en, name_he, name_ru, logo_url, sort_order, has_divisions)
SELECT s.seed_key, s.name_en, s.name_en, s.name_he, s.name_ru, s.logo_url,
       s.sort_order, s.has_divisions
FROM seed_leagues s
WHERE NOT EXISTS (SELECT 1 FROM leagues t WHERE t.seed_key = s.seed_key);

-- Admin-ownable columns yield to admin_edited; seed-owned ones are written unconditionally.
UPDATE leagues t SET
    name_en       = CASE WHEN 'name_en'  = ANY(t.admin_edited) THEN t.name_en  ELSE s.name_en  END,
    name_he       = CASE WHEN 'name_he'  = ANY(t.admin_edited) THEN t.name_he  ELSE s.name_he  END,
    name_ru       = CASE WHEN 'name_ru'  = ANY(t.admin_edited) THEN t.name_ru  ELSE s.name_ru  END,
    logo_url      = CASE WHEN 'logo_url' = ANY(t.admin_edited) THEN t.logo_url ELSE s.logo_url END,
    sort_order    = s.sort_order,
    has_divisions = s.has_divisions
FROM seed_leagues s
WHERE t.seed_key = s.seed_key;
```

- [ ] **Step 6: Run the tests and the neutrality harness**

```bash
python -m pytest tests/ -q
cd ../.. && scripts/seed/verify-neutrality.sh "$DUMP" seed-baseline
```

Expected: pytest green; harness `PASS`. **The A-vs-C diff must be empty** — if a league's `name` now differs, the `INSERT` is writing `name_en` where production holds Hebrew; that is expected only for rows the insert creates, never for adopted ones. Adopted rows must not have `name` rewritten, so confirm the `UPDATE` does not set it.

- [ ] **Step 7: Commit**

```bash
git add scripts/seed/generate-tables.py services/backend/seed.sql services/backend/tests/test_migration.py
git commit -m "refactor(seed): leagues become one straight table, five patch classes removed

Replaces the roster INSERT, the names block, two name_en rewrites, two name_ru
renames, ten sort_order statements, two has_divisions statements, the logo block
and its three corrections with one 10-row table and four fixed statements.

la-liga and uefa-champions-league now carry their CURRENT logo directly rather
than a superseded URL plus an unguarded correction 90 lines below. Data-neutrality
verified against a dump of the live production database."
git push -u origin feat/declarative-seed-sql
```

---

### Task 5: Clubs

212 rows, and the table that carries the roster, four `domestic_league_id` link blocks, the names block, three logo blocks, the `group_label` block and the relegation `DELETE`.

**Files:**
- Modify: `services/backend/seed.sql` (clubs sections)
- Modify: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: `seed_leagues` (Task 4) — clubs resolve `league`/`also_in` against `leagues.seed_key`.
- Produces: `seed_clubs` temp table `(seed_key, league, also_in, name_en, name_he, name_ru, logo_url, group_label)`.

- [ ] **Step 1: Generate the block**

```bash
python3 scripts/seed/generate-tables.py \
  --dsn postgres://postgres:test@localhost:5432/seedbase --table clubs > /tmp/clubs-block.sql
grep -c '^    (' /tmp/clubs-block.sql   # expect 212
grep -c "'a'\|'b'\|'c'\|'d'" /tmp/clubs-block.sql  # Nations League divisions present
```

Expected: 212 rows. Confirm `bayern-munich` carries `also_in` = `bundesliga`, and that the 16 World Cup / Nations League dual-league nations carry `also_in` = `nations-league`.

- [ ] **Step 2: Write the failing tests**

Append to `services/backend/tests/test_migration.py`:

```python
def test_dual_league_clubs_keep_both_leagues(conn):
    """A club playing two competitions must keep league_id AND domestic_league_id.

    _VOTE_LEAGUES_TOUCHED_CTE in services/worker/rollups.py derives league scope from both
    columns, so losing one silently under-counts a multi-league ballot.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT l.seed_key, d.seed_key FROM clubs c
        JOIN leagues l ON l.id = c.league_id
        LEFT JOIN leagues d ON d.id = c.domestic_league_id
        WHERE c.seed_key = 'bayern-munich'""")
    league, domestic = cur.fetchone()
    assert league == 'uefa-champions-league'
    assert domestic == 'bundesliga'
    cur.close()


def test_nations_league_divisions_survive(conn):
    cur = conn.cursor()
    cur.execute("SELECT group_label FROM clubs WHERE seed_key = 'france'")
    assert cur.fetchone()[0] == 'A'
    cur.execute("SELECT count(*) FROM clubs WHERE group_label IS NOT NULL")
    assert cur.fetchone()[0] > 0
    cur.close()


def test_admin_created_club_survives_reseeding(conn):
    """seed_key IS NULL means the admin created it, so declarative removal must skip it."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE seed_key = 'la-liga'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name, name_en) "
                "VALUES (%s, 'Ruritania FC', 'Ruritania FC') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    conn.commit()

    db.init_db(conn)

    cur.execute('SELECT count(*) FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == 1, 'seed.sql deleted a club it does not own'
    cur.close()
```

- [ ] **Step 3: Run them to verify they fail**

```bash
cd services/backend && python -m pytest tests/test_migration.py -v \
  -k "dual_league or nations_league_divisions or admin_created_club"
```

Expected: FAIL — no club `seed_key` values yet.

- [ ] **Step 4: Replace the clubs sections**

Remove the roster `INSERT`, the `Curacao` spelling patch, all four `domestic_league_id` blocks, the dual-league Nations League and Europa League link statements, the names block, all three logo blocks, the France crest patch, the Kiryat Yam patch, and the `group_label` block. Insert the generated table, then:

```sql
UPDATE clubs t SET seed_key = s.seed_key
FROM seed_clubs s
WHERE t.seed_key IS NULL AND t.name_en = s.name_en;

DO $$
DECLARE unadopted TEXT;
BEGIN
    SELECT string_agg(s.seed_key, ', ') INTO unadopted
    FROM seed_clubs s
    WHERE NOT EXISTS (SELECT 1 FROM clubs t WHERE t.seed_key = s.seed_key)
      AND EXISTS (SELECT 1 FROM clubs t
                  WHERE t.name_en = s.name_en OR t.name_he = s.name_he);
    IF unadopted IS NOT NULL THEN
        RAISE EXCEPTION 'seed.sql: clubs % exist but were not adopted; a name matches '
                        'while seed_key does not. Fix the adoption matcher -- inserting '
                        'would duplicate the row and violate clubs_name_en_uidx.', unadopted;
    END IF;
END $$;

INSERT INTO clubs (seed_key, league_id, domestic_league_id, name, name_en, name_he,
                   name_ru, logo_url, group_label)
SELECT s.seed_key, l.id, d.id, s.name_en, s.name_en, s.name_he, s.name_ru,
       s.logo_url, s.group_label
FROM seed_clubs s
JOIN leagues l ON l.seed_key = s.league
LEFT JOIN leagues d ON d.seed_key = s.also_in
WHERE NOT EXISTS (SELECT 1 FROM clubs t WHERE t.seed_key = s.seed_key);

-- domestic_league_id IS admin-writable (PATCH /api/admin/clubs/<id> and the admin UI's
-- continental-competition buttons both set it), so it yields to admin_edited like the
-- names do. group_label does not: both admin club endpoints omit it by design, precisely
-- so a PATCH cannot null it out.
UPDATE clubs t SET
    league_id          = l.id,
    domestic_league_id = CASE WHEN 'domestic_league_id' = ANY(t.admin_edited)
                              THEN t.domestic_league_id ELSE d.id END,
    name_en     = CASE WHEN 'name_en'  = ANY(t.admin_edited) THEN t.name_en  ELSE s.name_en  END,
    name_he     = CASE WHEN 'name_he'  = ANY(t.admin_edited) THEN t.name_he  ELSE s.name_he  END,
    name_ru     = CASE WHEN 'name_ru'  = ANY(t.admin_edited) THEN t.name_ru  ELSE s.name_ru  END,
    logo_url    = CASE WHEN 'logo_url' = ANY(t.admin_edited) THEN t.logo_url ELSE s.logo_url END,
    group_label = s.group_label
FROM seed_clubs s
JOIN leagues l ON l.seed_key = s.league
LEFT JOIN leagues d ON d.seed_key = s.also_in
WHERE t.seed_key = s.seed_key;
```

`domestic_league_id` provenance is already handled — Task 3's `rename_club` passes it via the helper's `extra` parameter, which is why the `UPDATE` above can check `'domestic_league_id' = ANY(t.admin_edited)`. It is deliberately not a member of `_PROVENANCE_COLUMNS`: that tuple is shared by all four rename paths, and only clubs have the column.

- [ ] **Step 5: Run the tests and the harness**

```bash
python -m pytest tests/ -q
cd ../.. && scripts/seed/verify-neutrality.sh "$DUMP" seed-baseline
```

Expected: green, and `PASS`. If the A-vs-C diff shows `group_label` differences, the generator ordered clubs differently from the old block — the values are keyed by `seed_key`, so investigate the generator, not the SQL.

- [ ] **Step 6: Commit**

```bash
git add services/backend/seed.sql services/backend/queries.py services/backend/tests/test_migration.py
git commit -m "refactor(seed): clubs become one straight table

Replaces the roster INSERT, the Curacao spelling patch, four domestic_league_id
link blocks, the Nations League and Europa League dual-league statements, the
names block, three logo blocks, the France crest and Kiryat Yam corrections and
the group_label block with one 212-row table and four fixed statements.

domestic_league_id yields to admin_edited because both admin club endpoints
write it; group_label does not, because both omit it by design."
git push -u origin feat/declarative-seed-sql
```

---

### Task 6: Parties and lineage

**Files:**
- Modify: `services/backend/seed.sql` (both party sections, `party_lineage`)
- Modify: `services/backend/tests/test_migration.py`

**Interfaces:**
- Produces: `seed_previous_parties`, `seed_upcoming_parties`, `seed_party_lineage (previous_key, upcoming_key)`.

- [ ] **Step 1: Generate both blocks**

```bash
for t in previous_parties upcoming_parties; do
  python3 scripts/seed/generate-tables.py \
    --dsn postgres://postgres:test@localhost:5432/seedbase --table $t > /tmp/$t-block.sql
  grep -c '^    (' /tmp/$t-block.sql
done
```

Expected: 13 and 18 rows.

- [ ] **Step 2: Write the failing tests**

```python
def test_other_has_no_ideology(conn):
    """'אחר' is a catch-all ballot option, not a party -- every axis stays NULL."""
    cur = conn.cursor()
    cur.execute("SELECT bloc, economic, security, religiosity, sector "
                "FROM previous_parties WHERE name_he = 'אחר'")
    assert all(v is None for v in cur.fetchone())
    cur.close()


def test_ideology_edits_reach_an_already_seeded_database(conn):
    """The six ideology columns stay UNGUARDED -- a guard makes every later edit
    unreachable in production, which is always already seeded."""
    cur = conn.cursor()
    cur.execute("UPDATE previous_parties SET economic = -3, bloc = 'wrong' "
                "WHERE name_he = 'הליכוד'")
    conn.commit()

    db.init_db(conn)

    cur.execute("SELECT economic, bloc FROM previous_parties WHERE name_he = 'הליכוד'")
    assert cur.fetchone() == (1, 'bibi')
    cur.close()


def test_party_lineage_is_rebuilt_by_key(conn):
    cur = conn.cursor()
    cur.execute('SELECT count(*) FROM party_lineage')
    assert cur.fetchone()[0] == 14
    cur.close()
```

- [ ] **Step 3: Run them to verify they fail**

```bash
cd services/backend && python -m pytest tests/test_migration.py -v \
  -k "other_has_no_ideology or ideology_edits_reach or party_lineage_is_rebuilt"
```

Expected: `test_ideology_edits_reach_an_already_seeded_database` FAILs (the others may already pass — that is fine, they are regression pins).

- [ ] **Step 4: Replace both party sections**

Remove the two roster `INSERT`s, the `המילואימניקים` → `בית ציוני` rename, the `name_he` backfills, both names blocks, both logo blocks, the two unguarded logo corrections and the 14 `party_lineage` `INSERT`s. Insert the generated tables, the same adopt/guard/insert/update quartet keyed on `name_he` for adoption, and:

```sql
CREATE TEMP TABLE seed_party_lineage (previous_key TEXT, upcoming_key TEXT) ON COMMIT DROP;
-- Generated from production 2026-08-12; 14 links. Religious Zionism splits three ways and
-- Labor/Meretz merge into one successor, so neither column is unique -- do not add a
-- primary key to this temp table.
INSERT INTO seed_party_lineage VALUES
    ('likud', 'likud'),
    ('yesh-atid', 'together'),
    ('religious-zionist-party', 'religious-zionist-party'),
    ('religious-zionist-party', 'otzma-yehudit'),
    ('religious-zionist-party', 'noam'),
    ('national-unity', 'blue-and-white'),
    ('yisrael-beiteinu', 'yisrael-beiteinu'),
    ('shas', 'shas'),
    ('united-torah-judaism', 'united-torah-judaism'),
    ('ra-am', 'ra-am'),
    ('hadash-ta-al', 'hadash-ta-al'),
    ('labor', 'the-democrats'),
    ('meretz', 'the-democrats'),
    ('balad', 'balad');

INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM seed_party_lineage s
JOIN previous_parties p ON p.seed_key = s.previous_key
JOIN upcoming_parties u ON u.seed_key = s.upcoming_key
ON CONFLICT DO NOTHING;
```

Generate the lineage rows with:

```bash
docker exec voteball-test-db psql -U postgres -d seedbase -tAc "
SELECT format('    (%L, %L),', p.name_en, u.name_en) FROM party_lineage l
JOIN previous_parties p ON p.id = l.previous_party_id
JOIN upcoming_parties u ON u.id = l.upcoming_party_id ORDER BY p.id, u.id"
```

then slugify both columns to match `seed_key`.

The ideology `UPDATE` stays unguarded — write `bloc`, `economic`, `security`, `religiosity`, `sector`, `tags`, `families`, `family_evidence` directly from the temp table with no `admin_edited` check, since no admin endpoint writes them.

- [ ] **Step 5: Run the tests and the harness**

```bash
python -m pytest tests/ -q
cd ../.. && scripts/seed/verify-neutrality.sh "$DUMP" seed-baseline
```

Expected: green, `PASS`, and `party_lineage` identical in the A-vs-C diff.

- [ ] **Step 6: Commit**

```bash
git add services/backend/seed.sql services/backend/tests/test_migration.py
git commit -m "refactor(seed): party tables and lineage become straight tables

Removes both roster INSERTs, the Beit Tzioni rename, the name_he backfills, both
names blocks, both logo blocks, two unguarded logo corrections and 14 lineage
INSERTs. The six ideology columns stay unguarded, since no admin endpoint writes
them and a guard would make every later edit unreachable in production."
git push -u origin feat/declarative-seed-sql
```

---

### Task 7: Declarative removal, and the last patches deleted

**Files:**
- Modify: `services/backend/seed.sql`
- Modify: `services/backend/tests/test_migration.py:test_removing_a_seeded_club_from_the_europa_league_is_re_applied` (inverts)

- [ ] **Step 1: Write the failing tests**

```python
def test_seeded_club_absent_from_the_table_is_removed(conn):
    """Removal now sticks. Previously a guarded link statement re-applied it on the next
    boot, which test_removing_a_seeded_club_from_the_europa_league_is_re_applied pinned."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE seed_key = 'la-liga'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, seed_key, name, name_en) "
                "VALUES (%s, 'ruritania-united', 'Ruritania United', 'Ruritania United')",
                (league_id,))
    conn.commit()

    db.init_db(conn)

    cur.execute("SELECT count(*) FROM clubs WHERE seed_key = 'ruritania-united'")
    assert cur.fetchone()[0] == 0
    cur.close()


def test_a_voted_for_club_is_never_deleted(conn):
    """vote_clubs.club_id has no ON DELETE CASCADE, so deleting a voted-for club raises
    inside init_db -- a CrashLoopBackOff on every pod boot, not one failed request."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE seed_key = 'la-liga'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, seed_key, name, name_en) "
                "VALUES (%s, 'ruritania-city', 'Ruritania City', 'Ruritania City') "
                "RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    cur.execute('INSERT INTO votes DEFAULT VALUES RETURNING id')
    vote_id = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)',
                (vote_id, club_id, league_id))
    conn.commit()

    db.init_db(conn)  # must not raise

    cur.execute('SELECT count(*) FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == 1
    cur.close()
```

Delete `test_removing_a_seeded_club_from_the_europa_league_is_re_applied` and note the inversion in its place with a comment pointing at the design doc.

- [ ] **Step 2: Run them to verify they fail**

```bash
python -m pytest tests/test_migration.py -v -k "absent_from_the_table or voted_for_club"
```

Expected: the first FAILs (the row survives).

- [ ] **Step 3: Add the declarative removal**

After the clubs `UPDATE` in `seed.sql`:

```sql
-- Removal is declarative: a club this file no longer names is deleted. Two guards, both
-- load-bearing.
--
-- seed_key IS NOT NULL protects clubs the admin created -- this file does not own them and
-- must not delete them for the crime of being absent from it.
--
-- The vote guard keeps the app bootable. vote_clubs.club_id references clubs(id) with NO
-- ON DELETE CASCADE (schema.sql), so deleting a club somebody voted for raises inside
-- init_db, which runs on every backend pod boot -- a CrashLoopBackOff on startup rather
-- than one failed request. It also encodes the policy the admin API already enforces:
-- DELETE /api/admin/clubs/<id> returns 409 while any vote references the club. A roster
-- tidy-up must never destroy a ballot; if a dropped club has votes it stays, and the admin
-- UI's vote-reassignment flow is the way out.
DELETE FROM clubs c
WHERE c.seed_key IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM seed_clubs s WHERE s.seed_key = c.seed_key)
  AND NOT EXISTS (SELECT 1 FROM vote_clubs vc WHERE vc.club_id = c.id);
```

- [ ] **Step 4: Delete the four `utm_source` strips and confirm no patch remains**

Production already carries zero `?utm_source=` values (verified 2026-08-12) and the generated literals come from that database, so the strips are dead code. Remove them, then:

```bash
grep -nE "^UPDATE (leagues|clubs|previous_parties|upcoming_parties) SET (name_|logo_url)" \
  services/backend/seed.sql
```

Expected: **no output** outside the four mechanism `UPDATE`s. Any hit is a surviving patch.

- [ ] **Step 5: Run everything**

```bash
cd services/backend && source .venv/bin/activate && python -m pytest tests/ -q
cd ../worker && source .venv/bin/activate && python -m pytest tests/ -q
cd ../..
scripts/seed/verify-neutrality.sh "$DUMP" seed-baseline
ruff check services/backend services/worker   # CI lints BEFORE it tests -- a green suite
                                              # locally still cannot deploy if ruff fails
wc -l services/backend/seed.sql
```

Expected: both suites green, harness `PASS`, ruff clean, and `seed.sql` around 700 lines (from 1,276).

- [ ] **Step 6: Commit**

```bash
git add services/backend/seed.sql services/backend/tests/test_migration.py
git commit -m "refactor(seed): declarative club removal, last patches deleted

A seeded club absent from the table is now deleted, guarded on seed_key IS NOT
NULL (never touch an admin-created club) and on no vote referencing it
(vote_clubs has no ON DELETE CASCADE, so this would crash init_db on every pod
boot). This inverts test_removing_a_seeded_club_from_the_europa_league_is_re_applied,
which pinned the old surprise that removal did not stick.

Also drops the four utm_source strips: production carries zero such URLs and the
literals are generated from it, so they were dead code."
git push -u origin feat/declarative-seed-sql
```

---

### Task 8: Documentation, and deploy

**Files:**
- Modify: `services/backend/CLAUDE.md`
- Modify: `docs/design/2026-08-12-seed-sql-declarative-design.md` (add "Verification outcome")
- Modify: root `CLAUDE.md` (the `seed.sql` rules it repeats)
- Delete: `docs/superpowers/plans/2026-08-12-declarative-seed-sql.md`

- [ ] **Step 1: Rewrite the `seed.sql` guidance in `services/backend/CLAUDE.md`**

Replace the guard-mechanics rules — the `COALESCE` explanation, the `IS NULL` logo-block rules, the three single-row logo exceptions, the "no guard makes a removal stick" note and the `name OR name_he` matching note — with the new model:

- Identity is `seed_key`, never a display name. Never change one; it is not a rename mechanism.
- Adding an entity is **one row**. Regenerate with `scripts/seed/generate-tables.py` rather than hand-editing.
- `admin_edited` is what protects live edits. The six ideology columns and `group_label` are seed-owned; names, `logo_url` and `domestic_league_id` are admin-ownable.
- **Removal now sticks**, guarded on votes.
- Restructuring still requires `scripts/seed/verify-neutrality.sh`, and the A-vs-C diff is the one that matters.

Keep the Russian-Cyrillic homoglyph warning, the `RELIGIOSITY_NULL_BY_DESIGN` note, the research-source notes (403s, `pdftotext`, image-only PDFs) and the fixture-naming rule — none are affected.

- [ ] **Step 2: Update the root `CLAUDE.md`**

The Architecture and "Party ideology axes" sections restate the guarded/unguarded rules and the "one `VALUES` block per table, not one statement per row" note. Update them to the `seed_key`/`admin_edited` model and correct the statement count (61 statements on pod boot is now wrong).

- [ ] **Step 3: Add the Verification outcome to the design doc**

Record what actually happened: the real A/B/C diff results, anything that broke, and the final line count. This section is the durable record — the plan is not.

- [ ] **Step 4: Deploy**

`init_db` runs on pod boot, so the migration ships with the image. **This is the only step that deploys** — the whole plan runs on `feat/declarative-seed-sql` precisely so the six intermediate states never reach production. Merging to `master` fires the webhook once: `application-ci` builds and `application-cd` promotes and syncs.

**Stop for the human's sign-off before running this step.** It is the first time the migration touches the live database, which holds real votes.

```bash
git checkout master && git pull --rebase origin master
git merge --no-ff feat/declarative-seed-sql -m "feat(seed): declarative seed.sql — one statement per property"
git push origin master
```

Watch the rollout, then verify against production:

```bash
kubectl get pods -n devops-app -w   # backend must not CrashLoopBackOff
POD=$(kubectl get pods -n devops-app -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n devops-app "$POD" -- python -c "
import db
c=db.get_db(); cur=c.cursor()
cur.execute('SELECT count(*) FROM clubs WHERE seed_key IS NULL'); print('unadopted clubs:', cur.fetchone()[0])
cur.execute('SELECT count(*) FROM votes'); print('votes:', cur.fetchone()[0])
"
```

Expected: `unadopted clubs: 0`, `votes: 22` (or higher — never lower).

- [ ] **Step 5: Delete this plan and commit**

Per the root `CLAUDE.md` rule, an executed plan is deleted in the same commit as the last task. This runs on `master`, after the merge in Step 4 — the doc edits from Steps 1-3 are committed on the branch and arrive with it; only the plan deletion and the verification outcome land here.

```bash
git rm docs/superpowers/plans/2026-08-12-declarative-seed-sql.md
git add services/backend/CLAUDE.md CLAUDE.md docs/design/2026-08-12-seed-sql-declarative-design.md
git commit -m "docs(seed): document the seed_key/admin_edited model, record verification

Replaces the guard-mechanics rules in services/backend/CLAUDE.md -- COALESCE
name guards, IS NULL logo guards, the three single-row exceptions, the
name OR name_he matching and the 'no guard makes a removal stick' note all
describe a file that no longer exists.

Deletes the executed implementation plan; git history is the archive."
git push origin master
```
