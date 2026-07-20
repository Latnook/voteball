# Party display names & manual party management

Status: approved
Date: 2026-07-12

## Context

Voteball currently sources `previous_parties` from a live sync against the Knesset OData API
(`knesset_sync.py`, wired to `POST /api/admin/sync-previous-parties`), which pulls the full,
often very long, official legal name of each faction (e.g. `התאחדות הספרדים שומרי תורה
תנועתו של מרן הרב עובדיה יוסף זצ"ל` for Shas). `upcoming_parties` is already a plain
admin-managed table (`POST/PATCH/DELETE /api/admin/upcoming-parties...`) with no sync involved.

This is the first of several planned improvements to Voteball (party lineage/merge-split
tracking, English/Hebrew i18n, a max-3-party selection limit, a real admin UI, and a visual
redesign with club/party logos are separate, later efforts — see "Non-goals" below). This spec
covers only how party names get into the system and what they look like.

## Decisions

1. **Drop the Knesset sync entirely.** The site owner will maintain the party lists manually.
   This removes a moving external dependency and the class of bug where a sync overwrites
   admin edits.
2. **No separate full/short name columns.** Originally scoped as a `short_name` override
   alongside the full legal name, but simplified once the owner chose to seed only the
   short, commonly-known form directly into the existing `name` column. There is no need to
   retain the long legal name anywhere in the system.
3. **`previous_parties` becomes admin-managed**, mirroring the existing `upcoming_parties`
   create/rename/delete pattern, so future elections don't require a code change.
4. **Seed data supplies the initial party lists** (like `leagues`/`clubs` already do in
   `seed.sql`), rather than requiring the admin to type in ~27 parties by hand after every
   fresh deploy.
5. **A catch-all "Other" (`אחר`) row is added to `previous_parties`** so a voter whose 2022
   party isn't one of the 13 named ones still has a truthful option, instead of being forced
   into `did_not_vote` or a wrong pick. `upcoming_parties` gets no such catch-all — the
   existing `undecided` status already covers "no specific party in mind" for the forward-looking
   question.

## Data model changes

`ansible-project/roles/backend/files/backend/schema.sql`:

- Drop the `knesset_faction_id` column from `previous_parties` — it was only ever populated
  by the sync being removed, and has no other purpose.
- Keep `updated_at` on `previous_parties` — it's now meaningful again as "last admin edit,"
  the same role it already plays on `upcoming_parties`.
- No other schema changes. `name TEXT NOT NULL UNIQUE` is unchanged on both tables.

## Seed data

`ansible-project/roles/backend/files/backend/seed.sql` gains INSERT blocks for both party
tables (mirroring the existing `leagues`/`clubs` ON CONFLICT DO NOTHING pattern):

**`previous_parties`** (14 rows — 2022 Knesset election):
הליכוד, יש עתיד, הציונות הדתית, המחנה הממלכתי, ישראל ביתנו, ש"ס, יהדות התורה, רע"ם,
חד"ש-תע"ל, העבודה, מרצ, בל"ד, הבית היהודי, אחר

**`upcoming_parties`** (13 rows — next election):
הליכוד, ישר, ביחד, הדמוקרטים, כחול לבן, ישראל ביתנו, הציונות הדתית, עוצמה יהודית,
חד"ש-תע"ל, בל"ד, המפלגה הכלכלית, אל הדגל, המילואימניקים

Note some names appear in both lists (e.g. הליכוד, ישראל ביתנו, הציונות הדתית,
חד"ש-תע"ל, בל"ד) — these are two independent tables keyed by their own surrogate `id`, so
the `UNIQUE (name)` constraint on each table is unaffected by the same string appearing in
the other table.

## Code removal

- Delete `ansible-project/roles/backend/files/backend/knesset_sync.py`.
- Delete `ansible-project/roles/backend/files/backend/tests/test_knesset_sync.py`.
- Remove `POST /api/admin/sync-previous-parties` from `app.py` (route + `knesset_sync` import).
- Remove `queries.upsert_previous_parties`.
- Remove the `requests==2.32.3` line from `requirements.txt` (only consumer was
  `knesset_sync.py`; confirmed no other usage in the backend).
- Remove references to the sync endpoint and `knesset_sync.py` from `tests/test_app.py`.

## Code addition

Add three routes to `app.py`, mirroring the existing `upcoming-parties` routes exactly
(same validation shape, same `require_admin` decorator, same 400/404 semantics):

- `POST /api/admin/previous-parties` — body `{"name": "..."}`, 201 with `{id, name}`.
- `PATCH /api/admin/previous-parties/<id>` — body `{"name": "..."}`, 200 with `{id, name}`,
  404 if not found.
- `DELETE /api/admin/previous-parties/<id>` — 204, 404 if not found.

Add matching `queries.py` functions: `create_previous_party`, `rename_previous_party`,
`delete_previous_party` — direct copies of `create_upcoming_party`/`rename_upcoming_party`/
`delete_upcoming_party` targeting `previous_parties`.

`GET /api/options` is unchanged in shape (still returns `{id, name}` for both party lists) —
only the underlying data changes.

## Deleting a previous_party that has votes

`votes.previous_party_id` is a nullable FK with no explicit `ON DELETE` action (defaults to
`NO ACTION`), same as `upcoming_parties` already behaves via `vote_upcoming_parties`'s
`ON DELETE CASCADE` — but note the asymmetry: `previous_party_id` on `votes` has no cascade,
so deleting a `previous_parties` row that is still referenced by a vote will fail with a
FK-violation error, surfaced to the admin as a normal 500/db error. This matches the current
production behavior (the sync path never deleted rows, so this case was previously unreachable);
it's an acceptable edge case for this spec — the admin UI project (deferred) is the right place
to decide whether to surface a friendlier "N votes reference this party" error.

## Testing

Real-Postgres TDD per `CLAUDE.md`:

- Extend `tests/conftest.py`'s table-drop list only if needed (this is a column drop, not a
  table add/remove — `schema.sql` already governs table shape, so likely no change needed;
  confirm during implementation).
- Add tests for `POST/PATCH/DELETE /api/admin/previous-parties...`, copied from the existing
  `upcoming-parties` test coverage.
- Remove `test_knesset_sync.py` and any `test_app.py` cases covering the sync endpoint.
- Add a seed-data smoke test (or extend an existing one) asserting `previous_parties` has 14
  rows and `upcoming_parties` has 13 after `init_db`.

## Documentation

Update `CLAUDE.md`:
- Architecture section: remove the `knesset_sync.py` description from the backend bullet.
- API surface table: remove `/api/admin/sync-previous-parties`; add the three new
  `/api/admin/previous-parties...` rows.

## Non-goals (deferred to future specs)

- Party lineage/merge-split tracking (e.g. correlating a previous הציונות הדתית vote with
  upcoming עוצמה יהודית consideration) — the two party lists here are intentionally
  independent tables with no cross-reference.
- English/Hebrew i18n — this spec seeds Hebrew-only names.
- Max-3-party selection limit on `upcoming_party_ids`.
- Admin UI (a real page, vs. curl-able admin endpoints).
- Visual redesign / club & party logos.
