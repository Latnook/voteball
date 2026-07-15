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

## Decisions

1. **Scope: leagues and clubs, not just clubs.** Both get full CRUD (create, rename, delete,
   reassign). A league is a small, occasionally-wrong-at-seed-time list (e.g. a competition added by
   mistake, or renamed) — worth the same admin control as clubs.
2. **Delete-blocked-by-votes + reassign, same primitive as parties.** `DELETE` on a league or club
   returns 409 if any votes still reference it; a paired `reassign` action (mirroring
   `previous-parties`' shape) moves votes from a source id to a target id in one transaction. No new
   mechanic — this is the existing party pattern applied one level further.
3. **Club reassign is same-league only, enforced server-side.** `votes.league_id` and `votes.club_id`
   are both set per vote and read together everywhere (`rollup_previous`/`rollup_upcoming` are grouped
   by `league_id, club_id`) — reassigning a club's votes to a club in a different league without also
   touching `league_id` would silently corrupt those groupings. `POST
   /api/admin/clubs/<source_id>/reassign` 400s if the target club's `league_id` differs from the
   source's. This is a correctness rule, not just a UI restriction — enforced in the route, not only
   by restricting the picker's options client-side.
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
7. **Club name uniqueness is per-league, league name uniqueness is global** — this falls directly out
   of the existing schema (`clubs_league_name_{en,he}_uidx` on `(league_id, name_en/he)` vs.
   `leagues_name_{en,he}_uidx` on `(name_en/he)` alone; no schema change needed). A duplicate-name
   error on club create/rename is scoped to "within this league," not global.
8. **UI: one "Teams" admin tab**, not two separate League/Club tabs. Leagues render as expandable
   groups; each group lists its clubs with an inline "+ Add club" row scoped to that league. Chosen
   over mirroring the flat previous/upcoming-party tabs because clubs genuinely nest under leagues —
   a flat club list would need a raw `league_id` dropdown per row with no visual grouping, which is
   worse UX for what's fundamentally a two-level structure.
9. **Reassign UI matches the existing party reassign flow**: a "Reassign votes..." control per
   row (club or league), a target picker (clubs: other clubs in the same league only; leagues: any
   other league), a `reassign-count` fetch feeding a `confirm()` with the vote count, then the mutating
   call. Same shape as `2026-07-13-admin-ui-design.md`'s reassign flow, just parameterized over
   leagues/clubs instead of previous/upcoming parties.

## Backend

### New query functions (`queries.py`), mirroring the `*_party` functions

- `create_league(conn, name_en, name_he) -> id`, `rename_league(conn, league_id, name_en, name_he) ->
  bool`, `delete_league(conn, league_id) -> bool`, `league_exists(conn, league_id) -> bool` —
  identical shape to `create_previous_party`/`rename_previous_party`/`delete_previous_party`/
  `previous_party_exists`, raising a `DuplicateLeagueNameError(language)` on `UniqueViolation`
  (same `_duplicate_party_language`-style constraint-name sniff, generalized to check both
  `_name_en_uidx`/`_name_he_uidx` suffixes regardless of table).
- `create_club(conn, league_id, name_en, name_he) -> id`, `rename_club(conn, club_id, name_en,
  name_he) -> bool`, `delete_club(conn, club_id) -> bool`, `club_exists(conn, club_id) -> bool`,
  `get_club_league_id(conn, club_id) -> int | None` (used by the reassign route's same-league check).
  `create_club`/`rename_club` raise `DuplicateClubNameError(language)` on `UniqueViolation`, and let a
  `ForeignKeyViolation` on a bad `league_id` propagate as today's generic 500 is avoided by validating
  `league_exists` in the route *before* calling the query function (400, not a raw DB error).
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
  `POST`/`PATCH` additionally take `league_id` in the body (400 if missing/not an int, 404 if it
  doesn't reference an existing league — checked via `league_exists` before insert/update).
  `POST .../reassign` additionally 400s if `get_club_league_id(target_id) !=
  get_club_league_id(source_id)`.

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
  the group, and a "+ Add league" control below all groups.
- **Club Reassign target picker** is pre-filtered client-side to clubs sharing the source club's
  `league_id` (defense in depth alongside the server-side 400 — the UI simply never offers an invalid
  choice).
- **League Delete/Reassign** on a league with clubs still under it: the 409/400 response's message
  (from decision 4/5) is shown inline, same as any other validation error — no special client-side
  precheck, since the count is already visible from the expanded club list.
- All rendering via `createElement`/`textContent`, matching the rest of the frontend's XSS posture —
  league/club names come from an external API and admin input, same trust level as party names.
- Bilingual add/rename forms (two inputs, `name_en`/`name_he`) matching the existing party forms per
  the i18n design.

## Data flow summary

```
Teams tab activation ─> GET /api/options ─> render league groups, each with nested clubs

Add league ─> POST /api/admin/leagues {name_en, name_he} ─> append group
Add club (within a league group) ─> POST /api/admin/clubs {league_id, name_en, name_he} ─> append row

Rename (league or club) ─> PATCH .../<id> {name_en, name_he} ─> re-render row/group header

Delete (club) ─> confirm() ─> DELETE /api/admin/clubs/<id>
                   ├─ 204 → remove row
                   └─ 409 (votes reference it) → inline error, suggest Reassign

Delete (league) ─> confirm() ─> DELETE /api/admin/leagues/<id>
                   ├─ 204 → remove group
                   ├─ 409 (clubs still belong to it) → inline error, suggest deleting/reassigning clubs first
                   └─ 409 (votes reference it) → inline error, suggest Reassign

Reassign (club) ─> pick target club (same league only) ─> GET reassign-count ─> confirm(N)
                     ─> POST reassign
                          ├─ 200 → refresh Teams tab, show count
                          └─ 400 (cross-league target) → inline error

Reassign (league) ─> pick target league ─> GET reassign-count ─> confirm(N) ─> POST reassign
                          ├─ 200 → refresh Teams tab, show count
                          └─ 400 (clubs still remain) → inline error, suggest emptying the league first
```

## Error handling

Same shape as the existing party routes throughout: `{'error': '...'}` JSON bodies shown inline near
the triggering control, no client-side retry, 401 handling via the existing session-secret-clear
flow. New cases specific to this feature: missing/invalid `league_id` on club create/rename (400/404),
league delete/reassign blocked by remaining clubs (409/400, decisions 4–5), club reassign blocked by
cross-league target (400, decision 3).

## Testing

Backend: new tests in `tests/test_app.py`, mirroring the existing previous/upcoming-party test
patterns:

- Create/rename league and club: success case, missing `name_en`/`name_he` → 400, duplicate name →
  409 (global for leagues, per-league for clubs — including the *same* club name allowed in two
  different leagues).
- Create/rename club with a nonexistent `league_id` → 404.
- Delete guards: a league with clubs → 409 (clubs count) even with zero votes; a league with zero
  clubs but referencing votes → 409 (votes count); a club with referencing votes → 409; an
  unreferenced, childless league/club → 204.
- Reassign, club: same-league target moves matching votes' `club_id`; cross-league target → 400;
  equal source/target → 400; nonexistent target → 404.
- Reassign, league: target with the source having zero clubs succeeds and moves matching votes'
  `league_id`; source with any remaining club → 400; equal source/target → 400; nonexistent target →
  404.

Frontend: no automated suite (per `CLAUDE.md`) — verified manually by driving `admin.html` in a
browser: Teams tab renders leagues with nested clubs; add/rename/delete round-trip for both levels;
deleting a league with clubs shows the club-count error before ever reaching the votes check; club
reassign only offers same-league targets and updates `/api/results` (club-scoped view) after the next
worker recompute; league reassign is refused with clubs still present and succeeds once emptied.

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
