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
which a single statement-level `IS NULL` guard cannot do. `logo_url` still uses `AND ... IS NULL`.

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
party row from a DB seeded with the OLD file, then diff against both (a) a fresh DB seeded with the
new file and (b) the old-seeded DB with the new file applied on top. Both diffs empty, or it isn't a
refactor.

Researching party positions: `idi.org.il` returns **504** and `israelhayom.co.il` returns **403** to
WebFetch — party official sites and `he.wikipedia.org` work. When only a blocked source supports the
stronger claim, score the weaker one and say so (see רע"ם in `docs/party-classifications.md`).


## Working on the backend


**Adding a new backend or worker source file: update that service's `Dockerfile` `COPY` line.** On EKS
the build context *is* the source directory (`scripts/build-push-ecr.sh` / the CI workflow run
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

