# Clubs & Leagues Admin CRUD

Status: approved
Date: 2026-07-15

## Context

`leagues` and `clubs` are currently seed-only: read via `GET /api/options`, never admin-editable
(the 2026-07-13 admin-UI spec explicitly called this a non-goal). `previous_parties`/`upcoming_parties`
already have full admin CRUD plus a "reassign votes" action for safe merges/splits (see
`2026-07-13-admin-ui-design.md`). This spec extends the same CRUD + reassign pattern to `leagues` and
`clubs`, reversing that earlier non-goal.

Unlike parties, clubs nest under a league (`clubs.league_id → leagues.id`, `NOT NULL`, no cascade),
and `votes.league_id` is itself `NOT NULL` (unlike `votes.previous_party_id`, which is nullable).
Both facts shape the decisions below: club operations must stay league-scoped, and league deletion needs
an extra guard beyond the vote-reference check parties already have.

**Second problem folded into this spec (added 2026-07-15, after initial review): real duplicate club
rows.** A club competing in a continental competition (UCL) also plays in its domestic league (e.g.
Arsenal in both UCL and EPL). Today, `clubs` has one `league_id` per row and is unique on `(league_id,
name)`, so today's seed data creates the *same real club as two separate rows with two separate ids* —
one under UCL, one under its domestic league (`seed.sql`'s "clubs not already covered by UCL" comments
are a pre-existing workaround for exactly this, in the `name_he` backfill only — the duplicate rows
themselves were never actually fixed). This spec adds a second, optional league reference to `clubs` so
one canonical row can be votable under both its continental competition and its domestic league, and
deduplicates the ~18 affected seed rows. Confirmed with the user: no votes exist yet in the current
(freshly-destroyed) database, so this is a pure schema + seed-data fix, no vote-history migration
needed.

## Decisions

1. **Scope: leagues and clubs, not just clubs.** Both get full CRUD (create, rename, delete,
   reassign). A league is a small, occasionally-wrong-at-seed-time list (e.g. a competition added by
   mistake, or renamed) — worth the same admin control as clubs.
2. **Delete-blocked-by-votes + reassign, same primitive as parties.** `DELETE` on a league or club
   returns 409 if any votes still reference it; a paired `reassign` action (mirroring
   `previous-parties`' shape) moves votes from a source id to a target id in one transaction. No new
   mechanic — this is the existing party pattern applied one level further.
3. **Club reassign requires the target to cover every league the source is votable under, enforced
   server-side.** A club is now votable under up to two leagues (`league_id` and, per decision 10
   below, `domestic_league_id`), and `reassign` only moves `votes.club_id` — it never touches the
   reassigned votes' existing `league_id`. If a source club's votes could have been cast under either
   of its two leagues, the target must be votable under both too, or a reassigned vote could end up
   with a `(league_id, club_id)` pairing that doesn't correspond to any real membership (e.g. an EPL
   vote landing on a club that's never listed as an EPL option). Concretely: `POST
   /api/admin/clubs/<source_id>/reassign` 400s unless target's `{league_id, domestic_league_id}` is a
   superset of source's `{league_id, domestic_league_id}` (both nullable fields; `NULL` is simply not
   a membership). This subsumes the simpler single-league case from before decision 10 was added.
   Enforced in the route, not only by restricting the picker's options client-side.
4. **League delete requires zero remaining clubs, not just zero votes.** `clubs.league_id` is `NOT
   NULL` with no `ON DELETE` rule, so deleting a league that still has clubs would hit a raw FK
   violation today. `DELETE /api/admin/leagues/<id>` explicitly checks `count_clubs_for_league` first
   and returns 409 ("N club(s) still belong to this league") if nonzero — checked *before* the
   existing votes check, since it's the more fundamental blocker (a league with clubs may have zero
   direct votes-with-null-club yet still be non-deletable).
5. **League reassign also requires zero remaining clubs**, for the same reason, applied to `reassign`
   instead of `delete`: reassigning `votes.league_id` away from a source league only touches votes
   where `club_id IS NULL` in practice (any vote that ever pointed at a club in this league is blocked
   from existing by decision 4's precondition — a club can't be deleted while votes reference it, so by
   the time a league has zero clubs, no vote's `club_id` can point into it). Requiring zero clubs
   up front means the plain `UPDATE votes SET league_id = target WHERE league_id = source` in the
   reassign action can never produce a vote whose `club_id` points at a club outside its new
   `league_id` — no extra runtime check needed, the precondition makes it structurally impossible.
6. **Bilingual names, same as parties.** `create`/`rename` for both leagues and clubs require
   non-empty `name_en` and `name_he` (400 if either is missing), matching the existing
   `2026-07-14-hebrew-english-i18n-design.md` convention. The legacy `name` column (still `NOT NULL`
   on both tables) is written as `name_he`, matching `create_previous_party`'s existing convention —
   not read anywhere in the API, kept only so the `NOT NULL`/`UNIQUE` constraints on that column don't
   need a migration.
7. **Club name uniqueness becomes global, matching leagues/parties — this is a schema change, and it
   reverses what the pre-decision-10 version of this spec said.** Per-league uniqueness
   (`(league_id, name)`) is exactly what allowed today's Arsenal-under-UCL /
   Arsenal-under-EPL duplication: two different `league_id`s meant no conflict. Now that one row can
   represent both leagues via `domestic_league_id` (decision 10), only a *global* name check actually
   stops someone from recreating that duplicate (e.g. adding a new "Arsenal" row under EPL with
   `domestic_league_id = UCL` when a UCL-primary "Arsenal" with `domestic_league_id = EPL` already
   exists — a same-league check would miss this since the two rows' primary `league_id`s legitimately
   differ). `clubs_league_name_{en,he}_uidx` on `(league_id, name_en/he)` is replaced with
   `clubs_name_{en,he}_uidx` on `(name_en/he)` alone, mirroring `leagues_name_{en,he}_uidx` exactly.
   Trade-off accepted: two unrelated real clubs that happen to share a display name (not present in
   current seed data) would now collide; acceptable given the alternative silently reintroduces the
   exact bug this spec exists to fix.
8. **UI: one "Teams" admin tab**, not two separate League/Club tabs. Leagues render as expandable
   groups; each group lists its clubs with an inline "+ Add club" row scoped to that league. Chosen
   over mirroring the flat previous/upcoming-party tabs because clubs genuinely nest under leagues —
   a flat club list would need a raw `league_id` dropdown per row with no visual grouping, which is
   worse UX for what's fundamentally a two-level structure.
9. **Reassign UI matches the existing party reassign flow**: a "Reassign votes..." control per
   row (club or league), a target picker (clubs: other clubs whose league membership covers the
   source's, per decision 3; leagues: any other league), a `reassign-count` fetch feeding a
   `confirm()` with the vote count, then the mutating call. Same shape as
   `2026-07-13-admin-ui-design.md`'s reassign flow, just parameterized over leagues/clubs instead of
   previous/upcoming parties.
10. **`clubs.domestic_league_id` — a second, optional league membership, votable exactly like the
    primary one.** New nullable column, `INTEGER REFERENCES leagues(id)`, `CHECK (domestic_league_id
    IS DISTINCT FROM league_id)` (a club can't have the same league in both slots). Confirmed with the
    user: a club with `domestic_league_id` set must be selectable by voters under *both* leagues, with
    one canonical row backing both — this is what actually removes the duplicate rather than just
    hiding it from one side. No rollup/results changes needed: `get_results_by_club` already sums by
    `club_id` alone (ignores league), and `get_results_by_league` already filters by whichever
    `league_id` is on the vote row (unaffected by what `clubs.domestic_league_id` says) — confirmed by
    reading `queries.py`'s `_results_for_filter`. The only vote-flow-facing change is `vote.js`'s club
    filter, from `c.league_id === leagueId` to `c.league_id === leagueId || c.domestic_league_id ===
    leagueId`, and `/api/options` exposing the new field. `votes` itself needs no schema change — a
    vote already just records whichever `league_id` the voter was browsing under plus the club's
    (single, canonical) id; nothing there assumes a club has exactly one league.
11. **Club add/rename form always shows a "Domestic League" dropdown, optional, not conditional on
    the primary League choice.** Simpler and uniform (one extra optional field, blank for the large
    majority of clubs with no continental competition) versus tagging which leagues count as
    "continental" to conditionally reveal it — confirmed with the user, who preferred the simpler,
    always-present form.
12. **Seed data fix, in scope**: of `seed.sql`'s 18 UCL clubs, exactly 14 are actually duplicated under
    a domestic league this app also seeds — Arsenal, Chelsea, Liverpool, Manchester City, Manchester
    United (EPL); Real Madrid, Barcelona, Atletico Madrid (La Liga); Inter Milan, AC Milan, Juventus,
    Napoli (Serie A); Bayern Munich, Borussia Dortmund (Bundesliga). These 14 are consolidated into
    single rows: `league_id = UCL` (unchanged from today), `domestic_league_id` set to their actual
    domestic league, and the now-redundant domestic-league insert for that same club name is removed.
    The other 4 UCL clubs — Paris Saint-Germain, Porto, Benfica, Ajax — play in leagues this app
    doesn't seed at all (Ligue 1, Primeira Liga, Eredivisie); they aren't actually duplicated today and
    stay as plain UCL-only rows, `domestic_league_id` left `NULL`. Since no votes exist yet (confirmed
    with the user), this is a direct seed-file edit — no vote reassignment needed. `EPL`'s `name_en` is
    also corrected to `Premier League` (still `name_he = 'הפרמייר ליג'`, unchanged) as part of the same
    seed pass, per the user's request — a plain data correction, not a design decision.

## Backend

### Schema changes (`schema.sql`)

```sql
ALTER TABLE clubs ADD COLUMN IF NOT EXISTS domestic_league_id INTEGER REFERENCES leagues(id);
ALTER TABLE clubs ADD CONSTRAINT clubs_domestic_league_differs
    CHECK (domestic_league_id IS DISTINCT FROM league_id);

DROP INDEX IF EXISTS clubs_league_name_en_uidx;
DROP INDEX IF EXISTS clubs_league_name_he_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_en_uidx ON clubs (name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_he_uidx ON clubs (name_he) WHERE name_he IS NOT NULL;
```

The old per-league partial unique indexes are dropped and replaced with global ones (decision 7); the
legacy `UNIQUE (league_id, name)` table constraint from the original `CREATE TABLE clubs` is left as-is
(harmless now that it's stricter than the new global check, and dropping a table-level `UNIQUE`
constraint needs a `DO $$ ... $$` existence check to stay idempotent — not worth it for a column
nothing reads).

### New query functions (`queries.py`), mirroring the `*_party` functions

- `create_league(conn, name_en, name_he) -> id`, `rename_league(conn, league_id, name_en, name_he) ->
  bool`, `delete_league(conn, league_id) -> bool`, `league_exists(conn, league_id) -> bool` —
  identical shape to `create_previous_party`/`rename_previous_party`/`delete_previous_party`/
  `previous_party_exists`, raising a `DuplicateLeagueNameError(language)` on `UniqueViolation`
  (same `_duplicate_party_language`-style constraint-name sniff, generalized to check both
  `_name_en_uidx`/`_name_he_uidx` suffixes regardless of table).
- `create_club(conn, league_id, domestic_league_id, name_en, name_he) -> id`, `rename_club(conn,
  club_id, league_id, domestic_league_id, name_en, name_he) -> bool`, `delete_club(conn, club_id) ->
  bool`, `club_exists(conn, club_id) -> bool`, `get_club_leagues(conn, club_id) -> {league_id,
  domestic_league_id} | None` (used by the reassign route's superset check, decision 3).
  `create_club`/`rename_club` raise `DuplicateClubNameError(language)` on `UniqueViolation` (now
  matched against the global `clubs_name_en_uidx`/`clubs_name_he_uidx` constraint names, per decision
  7), and a `ForeignKeyViolation` on a bad `league_id`/`domestic_league_id` is avoided by validating
  `league_exists` for both (when `domestic_league_id` is provided) in the route *before* calling the
  query function (400/404, not a raw DB error) — same pattern as before, just checking two fields
  instead of one.
- `count_votes_for_league(conn, league_id) -> int` (`SELECT COUNT(*) FROM votes WHERE league_id =
  %s`), `count_votes_for_club(conn, club_id) -> int` (`SELECT COUNT(*) FROM votes WHERE club_id =
  %s`), `count_clubs_for_league(conn, league_id) -> int` (`SELECT COUNT(*) FROM clubs WHERE
  league_id = %s`).
- `reassign_league_votes(conn, source_id, target_id) -> int` (`UPDATE votes SET league_id = %s WHERE
  league_id = %s`, returns rowcount), `reassign_club_votes(conn, source_id, target_id) -> int`
  (`UPDATE votes SET club_id = %s WHERE club_id = %s`, returns rowcount) — both single-statement,
  no collision handling needed (neither `league_id` nor `club_id` carries a uniqueness constraint on
  `votes`, unlike `vote_upcoming_parties`' composite key).

All new mutating functions follow the established `try/except Exception: conn.rollback(); raise /
finally: cur.close()` shape; `UniqueViolation` is caught ahead of the broad `except`, exactly as
`create_previous_party` does.

### New routes (`app.py`), mirroring `previous-parties`

- `POST /api/admin/leagues`, `PATCH /api/admin/leagues/<id>`, `DELETE /api/admin/leagues/<id>`,
  `GET /api/admin/leagues/<id>/reassign-count`, `POST /api/admin/leagues/<id>/reassign` — identical
  shape to the `previous-parties` routes, with `DELETE` additionally checking
  `count_clubs_for_league` first (409 "N club(s) still belong to this league" if nonzero, checked
  before the votes count) and `POST .../reassign` additionally checking the same precondition (400,
  not 409, since this blocks the *action* rather than reporting existing referential state — matches
  the existing 400-for-equal-source/target convention on reassign).
- `POST /api/admin/clubs`, `PATCH /api/admin/clubs/<id>`, `DELETE /api/admin/clubs/<id>`,
  `GET /api/admin/clubs/<id>/reassign-count`, `POST /api/admin/clubs/<id>/reassign` — same shape.
  `POST`/`PATCH` additionally take `league_id` (required, 400/404 as before) and `domestic_league_id`
  (optional; if present, 400 if not an int, 404 if it doesn't reference an existing league via
  `league_exists`, 400 if equal to `league_id` — mirroring the `CHECK` constraint client-side so the
  error is a clean 400 instead of a raw constraint-violation 500).
  `POST .../reassign` additionally 400s unless target's `{league_id, domestic_league_id}` (via
  `get_club_leagues`) is a superset of source's, per decision 3.

All routes reuse `require_admin` and the `try/finally: conn.close()` shape, matching every existing
admin route.

## Components (`admin.html` / `admin.js`)

### New "Teams" tab

- Fourth tab button alongside Previous Parties / Upcoming Parties / Votes (order: Teams inserted
  first, since it's referenced by every vote — matches `/api/options`' own field order).
- On first activation: fetch `/api/options` (already cached if another tab loaded first), render one
  expandable group per league — group header shows the league name with Rename/Delete/Reassign
  controls (identical to a party row); expanding it lists that league's clubs, each with its own
  Rename/Delete/Reassign controls, plus an "+ Add club" row scoped to that league at the bottom of
  the group, and a "+ Add league" control below all groups. A club with `domestic_league_id` set
  additionally appears (read-only, not a second editable row) under its domestic league's group with a
  small "also in <primary league>" annotation, so it's visible from both groups without being a
  separately-editable duplicate — all edits happen from its one canonical row, wherever that's
  rendered first (its `league_id` group).
- **Club add/rename form**: `name_en`, `name_he`, a League dropdown (required — every other league),
  and a Domestic League dropdown (optional, "— none —" default, every league except whichever is
  currently selected as League, per decision 11's always-shown/optional choice).
- **Club Reassign target picker** is pre-filtered client-side to clubs whose `{league_id,
  domestic_league_id}` covers the source club's (defense in depth alongside the server-side 400 — the
  UI simply never offers an invalid choice).
- **League Delete/Reassign** on a league with clubs still under it: the 409/400 response's message
  (from decision 4/5) is shown inline, same as any other validation error — no special client-side
  precheck, since the count is already visible from the expanded club list.
- All rendering via `createElement`/`textContent`, matching the rest of the frontend's XSS posture —
  league/club names come from an external API and admin input, same trust level as party names.
- Bilingual add/rename forms (two inputs, `name_en`/`name_he`) matching the existing party forms per
  the i18n design.

### Public vote flow (`vote.js`), one-line change

`index.html`'s league→club dropdown filter (`optionsData.clubs.filter(c => c.league_id ===
leagueId)`) becomes `optionsData.clubs.filter(c => c.league_id === leagueId || c.domestic_league_id
=== leagueId)`, so a club like Arsenal (canonical row: `league_id = UCL`, `domestic_league_id = EPL`)
appears in the club list whether the voter picked "UCL" or "Premier League" as their league. The vote
submitted still records whichever `league_id` the voter actually browsed under (decision 10) — no
other change to `vote.js` or `/api/vote`.

## Data flow summary

```
Teams tab activation ─> GET /api/options ─> render league groups, each with nested clubs

Add league ─> POST /api/admin/leagues {name_en, name_he} ─> append group
Add club (within a league group) ─> POST /api/admin/clubs {league_id, domestic_league_id, name_en, name_he} ─> append row

Rename (league or club) ─> PATCH .../<id> {name_en, name_he} ─> re-render row/group header

Delete (club) ─> confirm() ─> DELETE /api/admin/clubs/<id>
                   ├─ 204 → remove row
                   └─ 409 (votes reference it) → inline error, suggest Reassign

Delete (league) ─> confirm() ─> DELETE /api/admin/leagues/<id>
                   ├─ 204 → remove group
                   ├─ 409 (clubs still belong to it) → inline error, suggest deleting/reassigning clubs first
                   └─ 409 (votes reference it) → inline error, suggest Reassign

Reassign (club) ─> pick target club (leagues must cover source's) ─> GET reassign-count ─> confirm(N)
                     ─> POST reassign
                          ├─ 200 → refresh Teams tab, show count
                          └─ 400 (target doesn't cover source's leagues) → inline error

Reassign (league) ─> pick target league ─> GET reassign-count ─> confirm(N) ─> POST reassign
                          ├─ 200 → refresh Teams tab, show count
                          └─ 400 (clubs still remain) → inline error, suggest emptying the league first
```

## Error handling

Same shape as the existing party routes throughout: `{'error': '...'}` JSON bodies shown inline near
the triggering control, no client-side retry, 401 handling via the existing session-secret-clear
flow. New cases specific to this feature: missing/invalid `league_id` or `domestic_league_id` on club
create/rename (400/404, decisions 10–11), league delete/reassign blocked by remaining clubs (409/400,
decisions 4–5), club reassign blocked by a target that doesn't cover the source's leagues (400,
decision 3), duplicate club name now global rather than per-league (409, decision 7).

## Testing

Backend: new tests in `tests/test_app.py`, mirroring the existing previous/upcoming-party test
patterns:

- Create/rename league and club: success case, missing `name_en`/`name_he` → 400, duplicate name →
  409, now **global for both** leagues and clubs (decision 7) — a club name reused across two
  different leagues is now rejected, not allowed, the reverse of what a pre-decision-10 version of
  this suite would have asserted.
- Create/rename club with a nonexistent `league_id` → 404; a nonexistent `domestic_league_id` → 404; a
  `domestic_league_id` equal to `league_id` → 400.
- Delete guards: a league with clubs → 409 (clubs count) even with zero votes; a league with zero
  clubs but referencing votes → 409 (votes count); a club with referencing votes → 409; an
  unreferenced, childless league/club → 204.
- Reassign, club: target covering the same single league as the source moves matching votes'
  `club_id`; a source with both `league_id` and `domestic_league_id` set requires the target to cover
  both, or 400; a target covering only one of the source's two leagues → 400; equal source/target →
  400; nonexistent target → 404.
- Reassign, league: target with the source having zero clubs succeeds and moves matching votes'
  `league_id`; source with any remaining club → 400; equal source/target → 400; nonexistent target →
  404.
- `GET /api/options` returns `domestic_league_id` (`null` when unset) on every club row.

Frontend: no automated suite (per `CLAUDE.md`) — verified manually by driving the real stack in a
browser:

- Admin `admin.html`: Teams tab renders leagues with nested clubs, a club with a domestic league
  showing under both group; add/rename/delete round-trip for both levels including the Domestic
  League dropdown; deleting a league with clubs shows the club-count error before ever reaching the
  votes check; club reassign only offers targets covering the source's league(s); league reassign is
  refused with clubs still present and succeeds once emptied.
- Public `index.html`/`vote.js`: a club with a domestic league (e.g. Arsenal) appears in the club list
  both when "UCL" and when "Premier League" is picked as the league; the submitted vote records
  whichever league was actually selected; `/api/results` for that club (`by=club`) reflects votes cast
  under either league combined, and `/api/results` for each league (`by=league`) reflects only the
  votes actually cast under that league — after the next worker recompute.

## Non-goals

- No change to admin auth model or to any existing party/vote route.
- No merge/split UI difference from the existing reassign primitive — same all-or-nothing semantics as
  parties (see `2026-07-13-admin-ui-design.md`'s Non-goals; applies identically here).
- No automatic handling of a league-to-league reassign attempted while clubs remain — it is refused
  outright (decision 5), not auto-cascaded (e.g. no "also reassign all clubs to matching clubs in the
  target league" convenience feature). An admin who wants to merge two leagues' clubs does so
  club-by-club first.
- No lineage/audit trail, matching the existing party reassign's Non-goals.
- This supersedes the 2026-07-13 admin-UI spec's "No admin UI for leagues/clubs" non-goal.
