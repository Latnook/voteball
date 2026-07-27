# Russian language support

**Date:** 2026-07-27
**Status:** approved, implementation gated on the translation CSV

Voteball ships English and Hebrew. This adds Russian across both translation layers: the ~160
interface strings and all 214 distinct league, club and party names.

Russian-speaking Israelis are a substantial share of the electorate the poll is about, so partial
coverage — Russian buttons wrapped around Latin-script party names — would read as unfinished on
exactly the audience the feature targets. Scope is therefore full, not chrome-only.

## The two translation layers

The site localizes names through two unrelated mechanisms, and both need the new language:

1. **Interface strings** — `services/frontend/i18n.js`, a `DICTIONARY` keyed by language then by
   string id. Adding a language is one new object plus the language guards.
2. **Entity names** — `leagues`, `clubs`, `previous_parties`, `upcoming_parties` each carry
   `name_en` and `name_he` **columns**; `localizedName()` selects one. Adding a language is a schema
   change reaching the API, the admin CRUD endpoints and the seed file.

## Schema

Add `name_ru TEXT` (nullable) to the four tables using the `ADD COLUMN IF NOT EXISTS` form already
at `schema.sql:30`, plus four partial unique indexes mirroring `schema.sql:42-48`:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS <table>_name_ru_uidx ON <table> (name_ru) WHERE name_ru IS NOT NULL;
```

The partial predicate matters: without it, every row that has no Russian name yet would collide on
`NULL` under a plain unique index.

Nullable is deliberate and mirrors `name_he`. It is what makes the column safe to add to a live
database ahead of the translations, and what lets a missing translation degrade to a readable
English name rather than an empty label.

Delivered by the chart's existing schema-migration Job (`charts/voteball/templates/migrate-job.yaml`).

## `seed.sql` shape

Today each name is its own statement — 185 for clubs alone — in one of two mirrored forms:

```sql
UPDATE clubs SET name_he = 'ברזיל' WHERE name_en = 'Brazil' AND name_he IS NULL;            -- clubs, leagues
UPDATE previous_parties SET name_en = 'Likud' WHERE name_he = 'הליכוד' AND name_en IS NULL;  -- parties
```

Clubs and leagues seed with an English `name` and gain Hebrew; parties seed with a Hebrew `name` and
gain English. Each table keys on the column it was seeded with.

Appending Russian in the same style would take the name section from ~440 lines to ~660 of
near-identical SQL. Instead each table collapses to **one plain `VALUES` block carrying all three
languages, one row per entity**:

```sql
UPDATE clubs c SET
    name_he = COALESCE(c.name_he, v.name_he),
    name_ru = COALESCE(c.name_ru, v.name_ru)
FROM (VALUES
    ('Brazil',        'ברזיל',    'Бразилия'),
    ('Maccabi Haifa', 'מכבי חיפה', 'Маккаби Хайфа')
) AS v(name_en, name_he, name_ru)
WHERE c.name_en = v.name_en;
```

`COALESCE(c.name_he, v.name_he)` is exactly equivalent to the `AND name_he IS NULL` guard it
replaces — it writes only where the column is empty — but it guards each column independently, so
one statement covers both languages. **These guards are not optional and must not be removed.**
Admins rename parties and clubs through the live UI; those edits exist only in RDS, and an unguarded
seed would silently overwrite them on every deploy. (The *ideology* `UPDATE`s in the same file are
deliberately unguarded for the opposite reason — nothing in the app writes those columns. Do not
make the two consistent.)

Party blocks key on `name_he` instead, matching the existing direction.

### Restructure must be proven data-neutral

Collapsing the statements changes the file's shape, not its data. Per `CLAUDE.md` that requires
proof before it ships:

1. Seed a throwaway database with the **old** `seed.sql`; dump every row of the four tables.
2. Diff against a fresh database seeded with the **new** file.
3. Diff against the old-seeded database with the **new** file applied on top.

Both diffs empty, or it is not a refactor. Step 3 is the one that catches a broken guard.

## Translation sourcing

Names come from the renderings Russian-language Israeli media actually use, not mechanical
transliteration. The distinction is load-bearing for parties: ישראל ביתנו is conventionally
**Наш дом Израиль** — a translation — where transliteration would give Исраэль Бейтену. Club names
are stable transliterations (Маккаби Хайфа) and need no such judgement.

Working artifact: `docs/i18n/entity-names.csv`, three columns `name_en, name_he, name_ru`, 214 rows,
generated from `seed.sql` rather than retyped. The repo owner reviews and corrects the Russian
column; the `VALUES` blocks are generated from the corrected file.

**The CSV is deleted once merged into `seed.sql`.** `seed.sql` is the single source of truth for
these values; a doc holding a second copy drifts and then contradicts it. Git history retains the
file.

### Why 214 and not 222

Eight parties (הליכוד, ישראל ביתנו, ש"ס, יהדות התורה, חד"ש-תע"ל, בל"ד, רע"ם, הציונות הדתית) exist as
separate rows in both `previous_parties` and `upcoming_parties`. Deduplicating on the name pair means
each is translated once and the one Russian name feeds both tables, making the two provably
consistent. Verified: no `name_en` and no `name_he` repeats across the deduplicated set, so a name
alone identifies its table and no disambiguating column is needed.

## Backend

- `name_ru` added to the four `SELECT`s in `queries.py:20-53` and to the `/api/options` payload.
- The 8 admin create/patch endpoints **accept but do not require** `name_ru`.

Requiring it would mirror the existing `name_en`/`name_he` validation at `app.py:311`, but that
returns 400 when a field is absent — so every existing admin client, `admin.js` included, would start
failing on every create and rename until updated in lockstep, and no club could be saved without a
Russian name. Optional plus fallback trades that for a real cost: nothing forces later coverage, so
Russian names can silently rot behind newly added clubs.

## Frontend

- A `ru` object in `DICTIONARY` (~160 keys).
- `'ru'` accepted in `detectInitialLang()` and `setLang()`; `navigator.language` starting `ru` picks it.
- `dir` stays `ltr` — Russian is left-to-right, so no RTL machinery is involved.
- A third `РУ` pill in the `#lang-toggle` group in `index.html`, `results.html`, `admin.html`.
- `localizedName()` becomes a language→column lookup falling back `name_ru || name_en`.
- `admin.js` gains a third name input per create/rename form, with an `adminPlaceholderNameRu` key.

### Fonts

`services/frontend/fonts/` bundles Heebo, Anton and Secular One. **None has a Cyrillic subset**, so
Russian would fall back to a system sans and headings would not match the display type used for the
other two languages. Bundle a Cyrillic subset and add `:lang(ru)` display rules alongside the
existing `:lang(he)` ones at `style.css:130`.

Any new font file must be added to the `COPY` list in `services/frontend/Dockerfile` — except that
`fonts/` is copied as a whole directory, so this one is a data change. `i18n.js` is already listed.

## Testing

- `test_migration.py` — round-trip `name_ru` and assert the partial unique indexes, matching how it
  already covers the ideology columns.
- `test_app.py` — admin create and patch succeed both with and without `name_ru`.
- `tests/conftest.py` needs no change: no new tables, so the `DROP TABLE ... CASCADE` list is unaffected.
- Frontend has no automated suite; verify by driving all three pages in a browser in Russian.

## Out of scope

- Translating `docs/party-classifications.md` or any other documentation.
- A fourth language, or generalizing the two-language design into an arbitrary-locale system. The
  column-per-language shape does not scale, but three columns is not the point at which to rewrite it.
- Russian names for parties or clubs added after this pass — they fall back to English by design.
