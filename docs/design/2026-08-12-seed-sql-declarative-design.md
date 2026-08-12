# Declarative `seed.sql`: stable identity, admin provenance, no patches

**Date:** 2026-08-12
**Status:** designed, not yet implemented
**Touches:** `services/backend/schema.sql`, `services/backend/seed.sql`, `services/backend/queries.py`,
`services/backend/tests/`

Supersedes nothing. It changes the *mechanism* the party-categorization and Nations League / Europa
League docs' data rides on, not their decisions — every value those docs justify keeps its value.

## Problem

`seed.sql` is 1,276 lines and 78 statements, and roughly twenty of those statements exist only to
correct an earlier statement in the same file:

```
L71   INSERT … ('EPL')                  ->  L354  UPDATE leagues SET name_en = 'Premier League'
L338  names block sets name_ru          ->  L359  UPDATE leagues SET name_ru = 'Израильская …'
L385  logo block sets logo_url          ->  L422  UPDATE leagues SET logo_url = '/logos/…'
L700  club logo block                   ->  L766  UPDATE clubs (France crest)
                                        ->  L1270 UPDATE … split_part(logo_url, '?utm_source=', 1)
```

A property is written, then rewritten, sometimes twice. Reading the file does not tell you a row's
current value; you have to replay it.

Two root causes, and neither is sloppiness:

**1. Every base block is guarded, so it can only fill an empty cell.** Names use
`COALESCE(t.name_ru, v.name_ru)` and logos use `AND t.logo_url IS NULL`, both to protect edits made
live in the admin UI. Production is permanently already-seeded, so editing a literal in a guarded
block reaches a *fresh* database only — an already-seeded one keeps the old value forever. The patch
is the only thing that moves it. That is why the file grows by appending rather than by editing.

**2. There is no stable identity column.** Rows are keyed on display names — `name`, `name_en`,
`name_he` — and display names change, both from the admin UI and from this file itself. Hence the
`'EPL'` → `'Premier League'` self-patch, the three-way UCL/EPL identity check, and
`WHERE l.name = v.name OR l.name_he = v.name_he` with its explanatory table of three possible states.
The legacy `name` column is the worst offender: `queries.py` writes it in eight places and **never
reads it back**, yet `rename_league`/`rename_club` overwrite it with `name_he` on any save — including
a no-op one, which is the 2026-07-17 drift.

## Decisions

### 1. Add `seed_key` as immutable identity

`seed_key TEXT UNIQUE` on `leagues`, `clubs`, `previous_parties`, `upcoming_parties`. A kebab-case
slug (`premier-league`, `bayern-munich`, `likud`), never displayed, never writable through the API,
never changed once assigned. Every statement in `seed.sql` matches on it and nothing else.

`seed_key IS NULL` means "created through the admin UI" — `seed.sql` ignores those rows entirely,
which is what makes the declarative removal in decision 5 safe.

This retires the legacy `name` column as an identity key. It is **not dropped**: it stays
`NOT NULL UNIQUE`, still written by both the seed and the admin endpoints, simply not matched on.
Dropping it is a clean separate change; keeping it makes this one non-destructive.

### 2. Add `admin_edited` as column-level provenance

`admin_edited TEXT[] NOT NULL DEFAULT '{}'` on the same four tables, listing the columns a human has
changed through the admin UI. `seed.sql` overwrites any column *not* in that array.

That inverts today's rule — the base statement becomes authoritative, the exception becomes
explicit — and it is what eliminates the patches. A corrected Russian name or a replaced logo now
reaches an already-seeded database by editing the literal, because the statement is no longer
guarded on `IS NULL`.

**The four `rename_*` functions must append only columns whose value actually changed.** All four
admin endpoints replace every field they receive, so "the admin saved this row" cannot mean "the
admin owns this row" — one no-op save to attach a logo would otherwise freeze that club's Russian
name permanently. Each function reads the current row and diffs before writing, in the same
transaction as the existing `UPDATE`.

Provenance is maintained in the application, not by a database trigger. A trigger would be airtight
against a future write path forgetting, but it would also fire on `seed.sql`'s own writes and so
needs a session flag to suppress itself — machinery this repo does not otherwise use, to protect
four call sites that a test can pin directly.

### 3. One table per entity, all columns, materialized once

Each entity table gets exactly one `VALUES` block carrying every column, one row per entity, loaded
into a session-scoped `TEMP TABLE`:

```sql
CREATE TEMP TABLE seed_leagues (seed_key TEXT, name_en TEXT, …) ON COMMIT DROP;
INSERT INTO seed_leagues VALUES
    ('israeli-premier-league', …),
    …;
```

The fixed statements beneath it — adopt, insert-missing, update-columns, delete-absent — all read
that temp table, so the data is written **once** and referenced four times. Inlining the `VALUES`
block into each statement instead would repeat ~350 club rows four times over, which is the
duplication this design exists to remove. `init_db` executes the whole of `seed.sql` as a single
`cur.execute()` inside one transaction, committed once (`db.py:26-29`), so both the temp table and
`ON COMMIT DROP` behave for the file's whole lifetime — this would break under autocommit, where each
statement is its own transaction and the temp table would vanish immediately after creation.

Those four statements never change when the data changes.

```sql
-- seed_key                name_en                  name_he           name_ru                    ord div logo_url
('israeli-premier-league','Israeli Premier League','ליגת העל',       'Израильская Премьер-лига', 0, f, 'https://…/Winnerleague.png'),
('premier-league',        'Premier League',        'הפרמייר ליג',    'Премьер-лига',             2, f, 'https://…/EnglishPremierLeague.png'),
('la-liga',               'La Liga',               'לה ליגה',        'Ла Лига',                  3, f, 'https://assets.laliga.com/…color.png'),
('nations-league',        'Nations League',        'ליגת האומות',    'Лига наций УЕФА',          9, t, '/logos/uefa-nations-league.svg'),
```

La Liga carries its current logo directly rather than a Wikimedia URL with an unguarded correction
90 lines below it. Clubs take the same shape with `league`, `also_in` (the `domestic_league_id`
link), three names, `logo_url` and `group_label` — replacing the roster `INSERT`, four
`domestic_league_id` blocks, the names block, three logo blocks and the `group_label` block.

The update statement mixes both ownership rules per column, which is why one statement suffices:

```sql
UPDATE clubs t SET
    name_ru  = CASE WHEN 'name_ru'  = ANY(t.admin_edited) THEN t.name_ru  ELSE v.name_ru  END,
    logo_url = CASE WHEN 'logo_url' = ANY(t.admin_edited) THEN t.logo_url ELSE v.logo_url END,
    group_label = v.group_label          -- seed-owned: no admin write path exists
FROM seed_clubs v
WHERE t.seed_key = v.seed_key;
```

### 4. Adoption of existing rows, with a loud failure

Production rows have no `seed_key`. One adoption statement per table assigns it, matching current
rows on `name_en` (leagues, clubs) or `name_he` (parties), guarded by `seed_key IS NULL`. It is a
no-op once every row carries one.

Adoption cannot silently fail. If a row's `seed_key` is still `NULL` and its name collides with a
row the insert step is about to create, the insert must **raise**, not proceed — an unmatched row
followed by a blind insert is exactly the 2026-07-17 duplicate-league incident, which reached
production as a `CrashLoopBackOff` on every backend pod. Failing loudly at that point is the
better failure, and the verification in the next section is what stops it getting there at all.

Rows whose matching column was renamed after seeding (by an admin, or by this file's own patches
before they were removed) need their superseded value in the adoption matcher. Those are enumerated
from the real production database during verification, not guessed.

### 5. Removal becomes declarative

A seeded row absent from the table is deleted, provided nothing references it:

```sql
DELETE FROM clubs c
WHERE c.seed_key IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM seed_clubs s WHERE s.seed_key = c.seed_key)
  AND NOT EXISTS (SELECT 1 FROM vote_clubs vc WHERE vc.club_id = c.id);
```

The vote guard is not optional and is carried over unchanged: `vote_clubs.club_id` references
`clubs(id)` with no `ON DELETE CASCADE`, so deleting a club somebody voted for raises a foreign-key
violation *inside* `init_db`, which runs on every pod boot. `seed_key IS NOT NULL` is what protects
admin-created clubs from being deleted for the crime of not being in this file.

This replaces the hand-written relegation `DELETE` and **changes observable behaviour** — see below.

### 6. Migrations move to `schema.sql`, state stays in `seed.sql`

`schema.sql` is already the migration file (49 `ALTER TABLE` statements). The `name_en`/`name_he`
backfill from the legacy `name` column moves there, where it belongs. `seed.sql` is left describing
only the desired end state.

## Where each patch goes

| Today | Fate |
|---|---|
| `'EPL'`→`'Premier League'`, `'UCL'`→`'UEFA Champions League'` (L354–355) | Gone — `name` no longer identity |
| Two `name_ru` renames (L359–360) | Gone — literal is simply correct |
| `Curacao`→`Curaçao` (L41) | Gone |
| Six `logo_url` replacements (L422/424/432/766/1004/1250) | Gone |
| Two upcoming-party logo patches (L1252/1257) | Gone |
| `המילואימניקים` → `בית ציוני` rename (L233) | Gone — keyed on `seed_key` |
| Four `?utm_source=` strips (L1270–1273) | Gone — literals carry no `utm` |
| `name_en`/`name_he` backfill (L245–248) | Moves to `schema.sql` |
| Relegation `DELETE` (L316) | Declarative (decision 5) |
| 14 `party_lineage` `INSERT`s (L1085–1138) | One straight table |
| `name OR name_he` matching, three-way UCL check | Gone — `seed_key` |

Estimated 1,276 → ~700 lines. The 314 lines of comment prose largely go with the mechanics they
explain; the surviving warnings (the vote guard, `admin_edited` semantics) move to
`services/backend/CLAUDE.md`, which is where this repo keeps reasoning.

## Behaviour changes

Two, both deliberate:

1. **Removing a club from the table now removes it from the database** (if unvoted). Today removal
   does not stick — a guarded link statement re-applies on the next boot, which
   `test_removing_a_seeded_club_from_the_europa_league_is_re_applied` pins as expected behaviour.
   That test inverts.
2. **An admin edit now locks that column permanently**, where today it is protected only until
   someone writes a patch that overwrites it regardless. Strictly more protective, and the reason
   the diff in decision 2 matters: without it, one save locks a whole row.

## Verification

`services/backend/CLAUDE.md` requires a restructure to be proven data-neutral. The cluster is live
as of 2026-08-12, so the fixture is the real production database rather than a synthetic one:

1. `pg_dump` production through a backend pod. This is the only copy that contains real admin edits,
   which are the case the whole design turns on.
2. **DB A** — restore that dump; apply new `schema.sql` + `seed.sql`.
3. **DB B** — fresh database; apply new `schema.sql` + `seed.sql`.
4. **DB C** — restore the dump; apply *old* `schema.sql` + `seed.sql` (the current behaviour baseline).
5. Diff A against C over `leagues`, `clubs`, `previous_parties`, `upcoming_parties`, `party_lineage`.
   **Must be empty** except for the two new columns. This is the diff that matters — it is the only
   one that proves an already-seeded database ends up where it is today.
6. Diff B against A on the same tables to confirm fresh and migrated converge.
7. Re-apply the new `seed.sql` to A a second time and diff against itself — idempotence.

Two artefacts make these diffs fail when nothing is wrong, both previously mistaken for real
regressions: exclude `updated_at` and every other timestamp column, and sort by `seed_key`, never by
whole-row text.

New tests, covering the property the redesign exists for and which nothing currently tests:

- `seed.sql` overwrites a column absent from `admin_edited` (the patch-elimination guarantee).
- `seed.sql` leaves a column listed in `admin_edited` alone.
- A no-op admin save adds nothing to `admin_edited`.
- Changing one field through the admin API adds exactly that field.
- Adoption raises rather than inserting a duplicate when a seeded row cannot be matched.
- An admin-created row (`seed_key IS NULL`) survives the declarative delete.

## Not done

- **The legacy `name` column is not dropped.** It stays written and unread. Dropping it means
  touching `UNIQUE (league_id, name)`, four `INSERT`s and four `UPDATE`s in `queries.py`, and it is
  irreversible on production data; it earns its own change.
- **No admin UI for `seed_key` or `admin_edited`.** Both are invisible to the API. A misattributed
  `admin_edited` entry is fixed by SQL, deliberately.
- **No reverse-seeding.** Backfilling admin edits into `seed.sql` stays manual;
  `scripts/sync-seed-from-rds.sh` remains retired.
