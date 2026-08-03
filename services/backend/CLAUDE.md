# services/backend — CLAUDE.md

Guidance that applies when working under `services/backend/`. The root `CLAUDE.md` carries the
project-wide rules; this file carries what only matters here. `seed.sql`, `schema.sql`, `app.py`,
`queries.py` and `db.py` all live in this directory, and it is its own Docker build context — there
is no shared Python package with `services/worker/`.

## Party ideology axes, and how to revise them in `seed.sql`

Both party tables carry three numeric axes — `economic`, `security` and `religiosity` (each −3..+3,
**nullable**) — plus categorical `bloc`/`sector` and free-text `tags`. See
`docs/design/2026-07-16-party-categorization-analytics-design.md` and
`docs/design/2026-07-21-religiosity-axis-design.md`. Nullable is load-bearing: a `0` asserts a
confirmed centrist position, so a party with no stated position must be `NULL` — `religiosity` is
scoped to *Jewish* religion-and-state, so Ra'am and Hadash are NULL on it. **Balad is not**: its
program demands "complete separation of religion from the state" in as many words, so it scores −3
(the 2026-07-21 Arab-party pass amended the axis design doc's Decision 3 from a category exclusion
to a per-party evidence test — "Arab party" is not itself a reason to leave the axis NULL; the
reasoning is under Balad in `docs/party-classifications.md`). Where a party's rhetoric and
record diverge, the number records the **revealed** position and a tag carries the gap
(`claims-economically-liberal`, `instrumentally-clerical`) — do not add claimed/actual column pairs.

**`seed.sql` holds the values; `docs/party-classifications.md` holds the reasoning. Keep them
apart.** Each party has exactly one row in a plain `VALUES` block per table, and it is the current
state — edit that row in place. Do **not** reintroduce reasoning as SQL comments, and do not add a
second copy of the values to the doc; when the two disagree, `seed.sql` is right.

**The classification `UPDATE`s are deliberately UNGUARDED — do not add `AND bloc IS NULL`.**
Production is always already seeded, so a guard makes every later edit unreachable there; that is
precisely why the file used to grow by appending. Unguarded is safe for the six ideology columns
because nothing in the app writes them (the admin party endpoints only rename). **The name and
`logo_url` statements stay guarded for the opposite reason — admins edit those live, and an
unguarded write destroys their edits.** Don't "make them consistent."

For names that guard is now `COALESCE`, not `AND ... IS NULL`: since 2026-07-27 each table's names
live in **one `VALUES` block carrying all three languages**, one row per entity
(`COALESCE(c.name_he, v.name_he)` etc.). It is the same guarantee applied per column, and strictly
stronger — it can fill an empty `name_ru` on a row whose `name_en` an admin has already renamed,
which a single statement-level `IS NULL` guard cannot do.

**`logo_url` is one `VALUES` block per table too, and still guarded by `AND ... IS NULL`** — four
blocks carry 156 of the assignments (`clubs` keyed on `name_en`, `previous_parties` and
`upcoming_parties` on `name_he`, `leagues` on `name`), in the shape `UPDATE <t> t SET logo_url =
v.logo_url FROM (VALUES …) AS v(<key>, logo_url) WHERE t.<key> = v.<key> AND t.logo_url IS NULL`.
The guard is evaluated per row, so it is exactly what the 156 separate statements gave; the point of
the block is that `init_db` runs 61 statements on pod boot instead of 209. Row-specific comments live
**inside** the block, directly above the tuple they explain — keep them there when editing.

**Adding a logo means adding a tuple, and a duplicate key is now silent.** With one statement per
club the `IS NULL` guard made it "first in file order wins". A `VALUES` block *joins*, so a key
appearing twice lets Postgres match **arbitrarily** — same SQL, non-deterministic row. Check the key
is not already in the block rather than appending blind.

**Three logo statements stay single-row on purpose — do not fold them in.** The blocks carry only the
plain guard, and these three need a different one: `F.C. Kiryat Yam` widens it to
`IS NULL OR logo_url LIKE '%fbcdn.net%'` because it has to *correct* a known-bad value already in the
database, which `IS NULL` would skip forever; the `La Liga` and `המילואימניקים` corrections are
**unguarded** because each replaces a value that was actively wrong. Both unguarded ones run after
their blocks, so the final state is theirs.

**The `utm_*` strip at the end of the file is unguarded and separate for a reason.** 26 seeded URLs
carried `?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original`, which
`upload.wikimedia.org` ignores when serving the file — they only sent referral tracking on every page
load. Because every seeded literal is guarded by `logo_url IS NULL`, cleaning them at the source
reaches a *fresh* database only; an already-seeded one keeps them forever. The four `split_part()`
statements are that migration. Unguarded is safe here in a way it would not be for a whole URL — it
removes a meaningless suffix, so an admin-curated logo still points at the same image — and the
`LIKE` makes it a no-op once clean.

**The leagues block matches on `name OR name_he`, and neither column alone is enough.** No single
column identifies a league in all three states the table can be in: on a fresh install `name_he` is
still NULL; once seeded, `name_en` has been rewritten *unguarded* for EPL/UCL (`'EPL'` →
`'Premier League'`); and after any admin save `rename_league` has overwritten `name` with `name_he`
— even on a no-op rename, the 2026-07-17 drift. Both single-column forms have shipped and both
silently left leagues untranslated (`name_en`-keyed, then `name`-keyed, which is how UCL, EPL and
Bundesliga lost their Russian names). Each column is unique-indexed, so the `OR` still matches at
most one row. `test_league_names_survive_name_drift` and `test_admin_renamed_league_is_not_overwritten`
pin both halves.

Verify a revision the way every existing one was: seed a container with the *previous* file, apply
the new one, confirm the value actually moves on the already-seeded row — a fresh database proves
nothing, since a guarded block would set the value there anyway.

**Adding a new axis? Update `services/backend/tests/test_migration.py` too.** It is the reference
test that round-trips the ideology columns and asserts the `CHECK` bounds. The religiosity pass
missed it entirely and shipped an untested constraint; only the final review caught it.

**Scoring a party that `test_queries.py` lists in `RELIGIOSITY_NULL_BY_DESIGN` fails the suite** — it
asserts those parties *stay* NULL. Two different reasons put a party there: "the axis doesn't apply
to it" (permanent) vs "it hasn't published a platform yet" (a placeholder that must be revisited the
moment one appears). Check which before removing an entry.

**Restructuring `seed.sql` (as opposed to changing a value) must be proven data-neutral:** dump every
row of every table the change touches from a DB seeded with the OLD file, then diff against both
(a) a fresh DB seeded with the new file and (b) the old-seeded DB with the new file applied on top.
Both diffs empty, or it isn't a refactor. Diff (b) is the one that matters — it is the only one that
proves an *already-seeded* database ends up in the same state, which is the only kind that exists in
production. Widen the dump beyond the party tables when the change does: the logo blocks span
`leagues`, `clubs`, `previous_parties` and `upcoming_parties`.

**Two things make that proof fail when nothing is wrong, and both look like real regressions.**
Exclude `updated_at` (and any other `timestamp` column) from the dump — the three databases are
seeded seconds apart, so every party row differs. And sort by `id`, never by the whole row text: if
the change touches a value, the row's text changes, the sort order changes with it, and `diff`
reports dozens of unrelated rows as modified. Both of these produced a confident "31 unexplained
changes" against a refactor that was in fact exact.

If the change *intends* a value change alongside the restructure, the diffs will not be empty —
classify every differing row and show each one is the intended change, rather than eyeballing the
count.

Researching party positions: `kachollavan.org.il` returns **403** to WebFetch (the whole domain — the
`/8ps/` page and every PDF), `israelhayom.co.il` returns **403**, and `davar1.co.il` returns **403**.
`idi.org.il` intermittently returns **504** but was reachable on 2026-08-01. Party official sites and
`he.wikipedia.org` work. When only a blocked source supports the stronger claim, score the weaker one
and say so (see רע"ם in `docs/party-classifications.md`).

**A party PDF that WebFetch calls unreadable is usually readable — use `pdftotext`.** Party platforms
are frequently Adobe Illustrator exports; WebFetch hands its summarizer the raw binary, which then
reports "no extractable text" and offers to help if you find another format. That is a tooling limit,
not a property of the document. `curl` the PDF and run `pdftotext file.pdf file.txt` — all eight of
הדמוקרטים's platform papers extracted cleanly this way after WebFetch declared four of them
unreadable. Do not record "no platform published" on the strength of a WebFetch failure.

**Reachable is not the same as current, and IDI is the standing example.** Its רע"ם page loads and
carries a full platform — undated, and traceable to pre-2021 Joint List text rather than to anything
the party has published since. A secondary source with no date cannot settle an axis no matter how
authoritative the institution; that is what "from the party's own source" in the rule above is for.


## Working on the backend


**Adding a new backend or worker source file: update that service's `Dockerfile` `COPY` line.** On EKS
the build context *is* the source directory (`scripts/build-push-ecr.sh` and the `Jenkinsfile` both run
`docker build` against it), so the Dockerfile's explicit `COPY` list is the only place that can drop a
file — and a file missing there is simply absent from the image (no build error for the *app* files,
just an `ImportError`/404 at runtime). Same class of gap as the frontend note below.

Tests run TDD-style against a **real** Postgres, not mocks. Note the `.venv`s are **not relocatable** —
if a service directory is ever moved, delete and recreate them, or every command fails with a confusing
`ModuleNotFoundError` naming the *old* path (absolute paths are baked into the shebangs and
`pyvenv.cfg`):

```bash
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
# ...or `docker start voteball-test-db` if it already exists — it persists between sessions, and
# `docker run` then fails on the name conflict. For seed/schema verification create throwaway
# databases inside it (CREATE DATABASE revcheck; ...) rather than using the default one.
cd services/backend
python -m venv .venv && source .venv/bin/activate   # or use uv if pip is unavailable
pip install -r requirements-dev.txt                 # NOT requirements.txt — that has no pytest
python -m pytest tests/ -v                          # full suite
python -m pytest tests/test_app.py::test_health -v   # single test
```

**`requirements.txt` is the production dependency list and the Dockerfiles install *only* it;
`requirements-dev.txt` adds pytest on top.** Both services have this split. `tests/test_requirements.py`
(in each service) fails if a declared package is never imported, or if an imported package is missing
from the list — both mistakes were live until 2026-07-26, and neither is catchable by the normal
suite, because the venv has everything installed either way while the built image does not.

`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_USERNAME`,
`ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET`, etc.) via
`setdefault` and its `conn` fixture drops and recreates every table before each test (see the
`DROP TABLE ... CASCADE` list — keep it in sync with `schema.sql` when adding tables).

