# Declarative `seed.sql`: stable identity, admin provenance, no patches

**Date:** 2026-08-12
**Status:** implemented on `feat/declarative-seed-sql` (Tasks 1–7 complete); merging to `master`
(which is what deploys it, since `init_db` runs on every pod boot) is gated on the repo owner's
sign-off and has not happened. See "Verification outcome" below.
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
| `name_en`/`name_he` backfill (L245–248) | Moves to `schema.sql` — but a duplicate of it lingered in `seed.sql` after the move (dead code, no longer reachable once every row adopts a `seed_key`); Task 7 deleted it |
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
   `test_removing_a_seeded_club_from_the_europa_league_is_re_applied` pinned as expected behaviour.
   That test is deleted and replaced by `test_seeded_club_absent_from_the_table_is_removed`, which
   pins the inversion; the narrower case it also used to cover — a raw `domestic_league_id` clear
   that skips `admin_edited` — still gets re-applied exactly as before and is now pinned directly by
   `test_europa_league_link_is_re_applied_after_a_raw_clear`.
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

## Verification outcome

Implemented across Tasks 1–7 (`d4335de..f92f228` on `feat/declarative-seed-sql`, each task reviewed
before the next started). This section records what actually happened; the step-by-step task briefs
that drove it are process artefacts and are deleted at merge time, per the root `CLAUDE.md`'s rule —
this is the durable account.

**Real before/after numbers.** `seed.sql` went **1,276 lines / 78 statements → 578 lines / 46
statements** (`grep -c ';\s*$' services/backend/seed.sql`), and its roughly twenty patch statements
are **gone — zero remain**, confirmed by grepping the finished file for a bare
`UPDATE (leagues|clubs|previous_parties|upcoming_parties) SET (name_|logo_url)` outside the four
tables' single per-table `UPDATE`: the one hit is the legacy-`name` backfill, which turned out to be
dead code once `schema.sql` runs the same backfill earlier in the same boot (see below), and was
deleted rather than kept as a second layer. The production dump this was verified against (pulled
2026-08-12) carries 10 leagues, 212 clubs, 13 `previous_parties`, 18 `upcoming_parties`, 14
`party_lineage` links, 22 votes, 41 `vote_clubs` and 28 `vote_upcoming_parties` rows.

**A/B/C diff, re-run against that same production dump for this section**:
`scripts/seed/verify-neutrality.sh` reports `PASS` — the A-vs-C diff (already-seeded database
unchanged), the A-vs-B diff (fresh install and migrated database converge) and the idempotence
re-apply are all empty. The design's central claim holds against real data, not just synthetic
fixtures.

**The harness itself was extended twice during implementation, both times because it was found
capable of reporting PASS on a real regression:**

1. **Task 1.** The first cut of `snapshot.py` excluded the legacy `name` column from *every*
   comparison, not just the A-vs-B one that is supposed to exclude it (a fresh install never touches
   `name`, so excluding it there is correct; excluding it everywhere hides a genuine regression).
   Review demonstrated a false PASS on a `seed.sql` deliberately regressed to rewrite `name` on an
   already-adopted row. Fixed to exclude `name` from A-vs-B only, then re-proven to FAIL on the same
   regression.
2. **Task 5.** `snapshot.py`'s `clubs` comparison never included `league_id`/`domestic_league_id` (or
   anything derived from them) — so every PASS up to that point said nothing about whether the 212
   clubs' league/domestic-league links, the single most consequential thing that task rewrote and what
   `_VOTE_LEAGUES_TOUCHED_CTE` depends on for correct multi-league vote counting, had survived.
   Extended to resolve both FKs through **`leagues.name_en`**, never the raw ids (A, B and C each
   assign ids independently, so a raw-id diff would report a false regression on every run) — chosen
   over `seed_key` because the harness's C branch runs the *old* schema, which predates that column.
   Re-proven to FAIL in a disposable detached worktree (a link nulled on `bayern-munich`) before being
   trusted to PASS again on the clean tree.

**What the harness still cannot see: a legacy-identity regression — the pytest suite is the safety
net there.** `seed_key` and `admin_edited` are excluded from the harness's default comparison,
deliberately: they don't exist in the pre-2026-08-12 schema its C branch runs, so comparing them by
default would make every baseline diff non-empty regardless of correctness. That means a bug in the
*adoption* matcher — assigning `seed_key` to the wrong row, or failing to assign it at all — can leave
every column the harness does compare identical while identity is wrong underneath, since the
adoption statement (`UPDATE … SET seed_key = … WHERE seed_key IS NULL AND name_en = …`) never touches
`name`/`name_en` itself. The `DO $$ … RAISE EXCEPTION` duplicate-guard block in each table's section of
`seed.sql`, and the dedicated adoption tests in `test_migration.py`, are what actually assert
`seed_key` lands on the right row — not this harness.

**Two claims made during design were proven wrong during implementation; the decisions they
supported survived on different grounds, and neither wrong claim should be restated as fact:**

- Task 2's schema-comment draft justified the `seed_key` indexes' `WHERE seed_key IS NOT NULL`
  predicate as rejecting a second `NULL` value. **False** — Postgres treats `NULL` as distinct for
  uniqueness, so a plain (non-partial) unique index already permits unlimited `NULL`s; verified by
  hand (a plain unique index took three `NULL`s without complaint). The predicate is partial for the
  reason `schema.sql:144-154`'s corrected comment now gives: it scopes the uniqueness guarantee to
  rows that actually carry a key, stating "NULL is not an identity" explicitly — not to enforce it.
- Task 4's plan amendment justified keeping `legacy_name` (the `'EPL'`/`'UCL'` tokens `leagues.name`
  seeds under) on the grounds that writing `name_en` into `name` for a newly-inserted club would
  insert **zero** clubs on a fresh database, because the old clubs-roster join matched `name`
  literally. **False** — that join carried an `OR l.name_en = CASE …` fallback nobody had re-read;
  the reviewer applied the "wrong" version and it seeded all 212 clubs correctly, links intact.
  `legacy_name` still has to stay, for the reason `seed.sql`'s own header comment gives instead:
  **~36 tests** in `test_app.py`/`test_queries.py` look leagues up with `WHERE name = 'EPL'`/`'UCL'`
  and have no `name_en` fallback of their own.

**Nothing broke on `master`.** Every mistake above was caught by review or by the harness's own
re-proof-it-can-fail requirement before the task that introduced it was marked complete, and none of
the six intermediate states between the old `seed.sql` and the new one ever reached production — that
is the reason this whole redesign ran on a branch instead of task-by-task on `master`.

**Final state, re-confirmed for this section:** `python -m pytest tests/` — **203 passed** (backend),
**42 passed** (worker, untouched by this change and run for completeness); `ruff check .` clean on
both services; `scripts/seed/verify-neutrality.sh` PASS against the real production dump. The dump's
22 votes, 41 `vote_clubs` and 17 distinct voted clubs all survive the new `seed.sql`'s declarative
`DELETE` with no foreign-key raise — the scenario the vote guard in decision 5 exists for.
