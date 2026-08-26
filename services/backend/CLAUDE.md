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

**The six ideology columns (and `group_label`) are deliberately UNCONDITIONAL — do not add `AND bloc
IS NULL` or an `admin_edited` check to them.** Production is always already seeded, so a guard makes
every later edit unreachable there; that is precisely why the file used to grow by appending patch
statements instead of edited literals. Unconditional is safe for these columns because nothing in the
app ever writes them — the admin party endpoints only rename, and both club endpoints omit
`group_label` by design, precisely so a PATCH can't null it out.

**Names, `logo_url` and (on `clubs`) `domestic_league_id` are admin-ownable, and `admin_edited
TEXT[]` is what protects an admin's edit — not a per-statement guard.** `seed_key`, `admin_edited` and
this whole model were added 2026-08-12 (`docs/design/2026-08-12-seed-sql-declarative-design.md`);
`schema.sql` carries the column comments. Every entity table's single `UPDATE` writes each
admin-ownable column unconditionally *unless* that column's name is already in the row's
`admin_edited` array, in which case the seeded value is skipped and the row keeps whatever the admin
set:

```sql
name_en = CASE WHEN 'name_en' = ANY(t.admin_edited) THEN t.name_en ELSE s.name_en END
```

The four `rename_*`/`patch_*` functions in `queries.py` are what *append* to `admin_edited` — each
diffs the incoming value against the current row before writing, in the same transaction as the
existing `UPDATE`, so a no-op save (attaching a logo, say) does not lock the row's name too. This
inverts the old rule: the base statement is now authoritative and the exception is explicit, which is
what let the file drop its roughly twenty patch statements — each of those existed only to re-apply a
value a guard had refused to move on an already-seeded row.

**Identity is `seed_key`, never a display name — and it is never a rename mechanism.** It is a
kebab-case slug (`premier-league`, `bayern-munich`, `likud`), assigned once per row, never displayed,
never writable through the API, and never changed once assigned; renaming a club or party is an
admin-UI edit to its `name_*` columns, not an edit to `seed_key`. `seed_key IS NULL` means "created
through the admin UI" — `seed.sql` ignores those rows entirely, which is what makes the declarative
removal below safe. The legacy `name` column still exists (still written by both the seed and the
admin endpoints, still unread by any query) but is no longer matched on anywhere in this file — see
the header comment above `seed_leagues` in `seed.sql` for why `legacy_name` still has to feed it.

**Adding an entity is one row, regenerated — not hand-typed.**
`scripts/seed/generate-tables.py --table <leagues|clubs|previous_parties|upcoming_parties>` reads a
live seeded database and prints its `VALUES` block; that is how all four blocks were produced, and
it's how a new club or party belongs too, rather than hand-typing into a 212-row block — exactly the
kind of retyping that produces a silent homoglyph or a dropped field.

**Removal now sticks, guarded on votes.** A seeded row this file no longer names is deleted outright
— no guarded link statement re-applying it on the next boot, the way `domestic_league_id` used to.
Two guards, both load-bearing: `seed_key IS NOT NULL` (this file must never delete a row it doesn't
own — an admin-created row carries no key) and `NOT EXISTS (SELECT 1 FROM vote_clubs ...)` (a club
somebody voted for stays, because `vote_clubs.club_id` has no `ON DELETE CASCADE` and a raise here
would crash `init_db` on every pod boot — the same 409 the admin API's own `DELETE
/api/admin/clubs/<id>` already enforces). Dropping a seeded club for good is now a plain edit to the
table; the admin UI's vote-reassignment flow is still the way out for a club that has votes.
`test_seeded_club_absent_from_the_table_is_removed` pins the new behaviour.

**`upcoming_parties` got the same removal rule on 2026-08-20** (the חד"ש-תע"ל + בל"ד merge into
הרשימה המשותפת), with one addition that has no clubs equivalent and is easy to miss: it must delete
the row's `party_lineage` links **first**. `party_lineage.upcoming_party_id` references
`upcoming_parties(id)` with **no `ON DELETE CASCADE`** (unlike `vote_upcoming_parties`, which has
one), so deleting a party that still carries a lineage link raises inside `init_db` — a
CrashLoopBackOff on every backend pod boot, not one failed request. Both statements carry the **same**
vote guard on purpose: a party kept because it has votes must keep its lineage too, or it survives as
a row with its history silently cut. **The two tables fail in opposite directions**, which is why the
parties guard cannot be reasoned about from the clubs one: `vote_clubs` has no cascade, so an
unguarded club delete *raises* — loud, and caught on the first pod boot. `vote_upcoming_parties`
*does* cascade, so dropping the vote guard from both party statements deletes the row and its ballot
**with no error at all**. Dropping it from only the `upcoming_parties` statement happens to raise on
the `party_lineage` FK first, but that is incidental and must not be relied on as the safety net.
All three failure modes were verified by mutating `seed.sql` against
`test_a_voted_for_upcoming_party_is_never_deleted` and
`test_removing_an_upcoming_party_clears_its_lineage_first`.

Verify a single-value revision the way every one has been: seed a container with the *previous* file,
apply the new one on top, and confirm the value actually moves on the already-seeded row — testing
against a fresh database only proves the literal is spelled right, not that an existing row's stale
value gets overwritten.

**Adding a new axis? Update `services/backend/tests/test_migration.py` too.** It is the reference
test that round-trips the ideology columns and asserts the `CHECK` bounds. The religiosity pass
missed it entirely and shipped an untested constraint; only the final review caught it.

**Scoring a party that `test_queries.py` lists in `RELIGIOSITY_NULL_BY_DESIGN` fails the suite** — it
asserts those parties *stay* NULL. Two different reasons put a party there: "the axis doesn't apply
to it" (permanent) vs "it hasn't published a platform yet" (a placeholder that must be revisited the
moment one appears). Check which before removing an entry.

**Restructuring `seed.sql` (as opposed to changing a value) must be proven data-neutral — run
`scripts/seed/verify-neutrality.sh <production-dump.sql> <old-git-ref>`.** It builds three databases
— **C** (old schema + a production dump + the OLD seed, the baseline), **A** (old schema + the same
dump + the NEW schema + the NEW seed, the migration) and **B** (new schema + new seed, a fresh
install, no dump) — and diffs them via `scripts/seed/snapshot.py`. **Diff A-vs-C is the one that
matters**: both sides descend from the same production dump, so it's the only comparison that proves
an *already-seeded* database — the only kind that exists in production — ends up where it started.
A-vs-B confirms fresh and migrated converge (it deliberately excludes the legacy `name` column for
that one comparison only: a fresh install was never admin-touched, so it still carries `seed.sql`'s
literal first-seed token instead of an admin-set value, and that divergence is expected on every run).
Re-applying the new file to A and diffing against itself checks idempotence. All three must be empty.

`snapshot.py` already handles the two things that used to make this proof fail when nothing was
wrong, both previously mistaken for real regressions and both worth knowing if you extend it further:
it excludes `updated_at` (and would need extending for any other `timestamp` column added later), and
it keys every row by its natural name column rather than sorting whole-row text, so a value change in
one row can't shuffle sort order and make `diff` report dozens of unrelated rows as modified. Widen
`TABLES` in `snapshot.py` beyond the four entity tables if a restructure touches more than
names/logos/ideology — see the harness's own header comment for the full contract, including why
`clubs`' `league_id`/`domestic_league_id` are resolved through `leagues.name_en` rather than compared
as raw ids (they're surrogate FKs, assigned independently by each of A/B/C).

If the change *intends* a value change alongside the restructure, A-vs-C will not be empty —
classify every differing row and show each one is the intended change, rather than eyeballing the
count.

Researching party positions: `kachollavan.org.il` returns **403** to WebFetch (the whole domain — the
`/8ps/` page and every PDF), `israelhayom.co.il` returns **403**, and `davar1.co.il` returns **403**.
`idi.org.il` intermittently returns **504** but was reachable on 2026-08-01. Party official sites and
`he.wikipedia.org` work. When only a blocked source supports the stronger claim, score the weaker one
and say so (see רע"ם in `docs/party-classifications.md`).

**A 403 usually blocks *default tooling*, not you — retry with a browser-shaped request before
concluding a source is unreachable.** `kachollavan.org.il` was recorded here and in
`docs/party-classifications.md` as needing manual download; on 2026-08-11 a plain `curl -A
'Mozilla/5.0 …' -H 'Referer: https://kachollavan.org.il/'` fetched its PDFs at **200** on the first
try. The cost of the wrong belief is not effort, it is coverage: that row sat with four unread
documents and a wrong `religiosity` partly because the domain was written off as hand-fetch-only.
Test the block before designing around it. **A User-Agent alone is not browser-shaped enough** —
`timesofisrael.com` still 403s to one, and returns **200** once `Accept`, `Accept-Language` and
`Referer` are added (2026-08-26).

**A summarizer's rendering of a source is not the source, and the gap shows up exactly where it
matters.** WebFetch answers a prompt *about* a page rather than handing you the page. Asked to
transcribe that Times of Israel entry verbatim, it returned the quotation the headline is built on
and silently dropped the sentence immediately after it — the one carrying the dehumanizing language
that is the whole reason the piece bears on a classification. Fetch and read the text before citing
a source for a tag or an axis; use WebFetch to decide whether a page is worth fetching, not as the
thing you cite.

**A party PDF that WebFetch calls unreadable is usually readable — use `pdftotext`.** Party platforms
are frequently Adobe Illustrator exports; WebFetch hands its summarizer the raw binary, which then
reports "no extractable text" and offers to help if you find another format. That is a tooling limit,
not a property of the document. `curl` the PDF and run `pdftotext file.pdf file.txt` — all ten of
הדמוקרטים's platform papers extracted cleanly this way after WebFetch declared four of them
unreadable. Do not record "no platform published" on the strength of a WebFetch failure.

**When `pdftotext` succeeds and returns ~1 byte per page, the PDF is image-only — read it visually
with the `Read` tool, which takes a `pages` range.** This is the failure the rule above does not
cover, and it does not look like a failure: exit code 0, a file created, one newline per page. Check
the byte count, not the exit code. `7 bytes from 7 pages` and `25 bytes from 25 pages` are what
כחול לבן's and אל הדגל's education and platform PDFs return, and **both rows carried a wrong
`religiosity` for as long as those files went unread** (2026-08-01 and 2026-08-10). Both were fixed
by the education paper, because that is where this axis's real number lives — see the warning under
`religiosity` in `docs/party-classifications.md`. **Reading the image-only file is necessary but not
sufficient: אל הדגל's platform PDF was read, and the funding clause on p. 11 was still missed** — a
page of rendered Hebrew scanned for the chapter you came for will not surrender the clause filed
under a different heading (revision 25, 2026-08-19).

**A second body of text that overlaps at the introduction is not the same document.** אל הדגל
publishes vision chapters at `elhadegel.co.il/about-us` *and* a platform page at `/our-platform`
*and* a platform PDF; the first two share no headings with each other and only the הקדמה with the
PDF, and the row was scored as though reading one had covered the others. Diff the section headings
before concluding a source is already mined.

**Enumerate a party's document links before reading any of them, and treat the link labels as
unreliable.** The same row went eight revisions with **two of its four PDFs never cited anywhere**,
because the four are linked from one page under labels that do not match their filenames
(*חוק הגיוס* → `חוק יסוד השירות`, *מסמך תכנית כלכלית* → `הכלכלה הציונית של אל הדגל`), so a reader
who has already found "the platform PDF" has no signal that three more exist. `curl` the platform
page and list every `.pdf` href first; it costs one request.

**Retrieval difficulty is a bad proxy for coverage, and it inverts more often than not.** On that
same row the two documents that went unread longest were the two that `pdftotext` extracts cleanly
in one command — the image-only pair got read precisely *because* they announced themselves as hard.
The corollary for this file's rules above: a document that gave you no trouble is not thereby a
document you read.

**A second document agreeing with the first is not evidence the first was read.** אל הדגל's
education paper was recorded as the source that moved `religiosity`, on the reading that the
platform contained only a slogan; the platform contained the same funding condition and the same
50/30/20 split all along. Corroboration feels like coverage and is not — when a new source confirms
an axis, check whether it *introduced* the evidence or merely repeated it.

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

**The `conn` fixture calls `db.init_db`, which loads `schema.sql` AND `seed.sql`** — every backend
test starts against a fully seeded database, not an empty one. Combined with the **global**
`clubs_name_en_uidx`/`leagues_name_en_uidx` unique indexes, a throwaway fixture named after
something real collides the moment that name gets seeded, and only then — a test written before the
name existed in `seed.sql` passes for as long as it stays unseeded and starts failing the day someone
adds it, with no code change in the test itself to blame. This happened twice during the Nations
League feature: a fixture league called `'Nations League'` and a fixture club called `'Italy'`, each
breaking only when a later commit seeded the real row. Give fixtures obviously-fake names instead —
this repo now uses `'Placeholder League'` and `'Ruritania'` for exactly this reason.

**Two ways a test run lies to you.** Both cost real debugging time during the observability
instrumentation plan:

- **A second suite running against the same `voteball-test-db` container deadlocks, and looks like a
  database problem, not a concurrency one.** Both this service's and the worker's fixtures drop and
  recreate every table before each test, so two suites at once fight over the same table locks — the
  symptom is a suite that hangs, or errors that read like stale database state. Run `pgrep -f "python
  -m pytest"` before trusting any diagnosis that blames the database. During this plan an implementer
  reported three errors as "pre-existing db state issues" and committed on that basis; a clean,
  exclusive run showed zero errors.
- **A stale `PROMETHEUS_MULTIPROC_DIR` masquerades as a database fault in `test_metrics.py`.** If
  that variable is exported and points at a directory that no longer exists, the metrics tests error
  in a way that looks unrelated to Prometheus at all. This happened for real when a by-hand
  multiprocess check exported it, deleted the directory afterwards, and left the variable set. Unset
  it (or run under `env -u PROMETHEUS_MULTIPROC_DIR`) before trusting any other explanation.

