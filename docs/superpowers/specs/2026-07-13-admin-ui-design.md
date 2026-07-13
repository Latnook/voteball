# Admin UI

Status: approved
Date: 2026-07-13

## Context

The `/api/admin/...` endpoints (previous/upcoming party CRUD, votes list/delete) currently have no UI
— they're only reachable by hand-crafting requests with an `X-Admin-Secret` header. This adds a plain
HTML/CSS/vanilla-JS admin page, matching the existing frontend's no-build-step convention
(`index.html`/`vote.js`, `results.html`/`results.js`), that covers the full current admin API surface:
previous-party CRUD, upcoming-party CRUD, and votes list/delete.

Admin auth stays exactly as it is: a static shared secret compared against `ADMIN_SECRET`. This page
is a client for that model, not a replacement for it — no backend auth changes.

Parties are not static once seeded — real-world political parties merge and split, especially for
`upcoming_parties` in the run-up to an election (e.g. a joint list splitting into two independent
parties, or several small parties merging into one). `previous_parties`/`upcoming_parties` today are
flat, independent rows with no lineage concept, and plain delete is actively dangerous against votes
that reference them (see Decisions #10–11). This spec adds a **vote reassignment** action — an
admin-judgment-driven way to move existing votes from one party ID to another — that covers both
cases: a merge is reassignment applied once per losing party into the survivor; a split, where the
admin judges which successor actually carried the original voters' intent (e.g. votes for a joint list
led by a figure who took one faction independent), is reassignment applied once, redirecting history to
that successor. This is a manual, per-case admin decision, not an automatic algorithm — see Non-goals.

## Decisions

1. **New files, not an extension of an existing page**: `admin.html` + `admin.js`, reusing
   `style.css`. Keeps the public voting/results pages untouched.
2. **Unlinked**: no nav link from `index.html`/`results.html`. Reachable only by URL. The secret
   prompt is the real gate either way, but there's no reason to advertise the admin URL to every
   visitor.
3. **Single page, tabbed**: one page with three tabs — Previous Parties, Upcoming Parties, Votes —
   rather than stacked sections or separate pages per section. Tab switching is a plain `display`
   toggle on section `<div>`s, the same mechanism `results.html` already uses for its club/league vs.
   party mode toggle.
4. **Secret entered once per tab session**, not once per action. A password-style input, submitted
   against a probe request (`GET /api/admin/votes`); on success the secret is kept in
   `sessionStorage` (cleared when the tab closes) and attached to every subsequent admin request. On
   failure, an inline error, and the prompt stays.
5. **Reuse `/api/options` for listing parties.** It already returns `previous_parties` and
   `upcoming_parties` and needs no auth — the admin page uses it to populate both party tabs' lists,
   and only calls the authenticated `/api/admin/...` endpoints for the actual create/rename/delete
   mutations. `/api/admin/votes` (GET) is the only authenticated *read* the page performs.
6. **Lazy-load per tab.** Each tab's data (party lists, votes list) is fetched on that tab's first
   activation, not all up front. Mutations re-fetch just that tab's list rather than trying to
   patch local state.
7. **No pagination for votes.** `GET /api/admin/votes` returns everything; the votes tab renders it
   as one table. Acceptable for current and near-term vote volume; revisit if the table becomes
   unwieldy.
8. **Destructive actions use `confirm()`.** No custom modal — matches the simplicity bar of the rest
   of the frontend.
9. **Any 401 (from the probe or from any later admin request) clears the stored secret and re-shows
   the gate** with a "session expired — re-enter the secret" message. Covers secret rotation without
   needing a page reload.
10. **Backend fix, in scope**: duplicate party names currently cause an unhandled 500 (both
    `previous_parties.name` and `upcoming_parties.name` are `UNIQUE`, but nothing catches the
    resulting `UniqueViolation` — it propagates through queries.py's broad
    `except Exception: conn.rollback(); raise` to Flask's default, non-JSON error page). This is
    pre-existing, but the admin UI is what makes a human likely to actually hit it (via the "Add
    new" / rename forms), so it's fixed as part of this work rather than left as a dead end behind a
    generic error message.
11. **Backend fix, in scope**: deleting a party currently has two different, both-unsafe behaviors.
    `votes.previous_party_id → previous_parties(id)` has no `ON DELETE` rule (defaults to
    `RESTRICT`), so deleting a referenced previous party currently raises an unhandled foreign-key
    violation (another uncaught 500). `vote_upcoming_parties.upcoming_party_id → upcoming_parties(id)`
    is `ON DELETE CASCADE`, so deleting a referenced upcoming party currently succeeds but silently
    drops that party from every affected vote's `upcoming_party_ids` with no trace. Both delete
    routes are fixed to check for referencing votes first and return 409 with the count instead —
    "N votes still reference this party; reassign or reassign-and-delete first." This is what makes
    the reassign action (below) meaningful rather than optional: a party with real vote history is no
    longer either un-deletable-with-a-crash or silently-emptied-of-history.
12. **New action: "Reassign votes to another party"**, symmetric on both party tabs (Previous
    Parties, Upcoming Parties — same CRUD symmetry the tabs already share). Not "merge" or "split" as
    separate mechanics — a single primitive (move every vote's reference from a source party ID to a
    target party ID) that covers both: repeated once per losing party into a survivor, it's a merge;
    applied once to redirect a party's history toward whichever successor an admin judges actually
    represents the original voters' intent, it approximates a split. See Backend for the mechanics
    and Non-goals for what this deliberately does not attempt.

## Backend

### Duplicate-name fix

In `ansible-project/roles/backend/files/backend/queries.py`, `create_previous_party`,
`rename_previous_party`, `create_upcoming_party`, and `rename_upcoming_party` each catch
`psycopg2.errors.UniqueViolation` specifically (before the existing broad `except Exception:
rollback; raise`), roll back, and raise a distinct exception (e.g. a small
`DuplicatePartyNameError`) that the four corresponding routes in `app.py` catch and turn into
`jsonify({'error': 'a party with this name already exists'}), 409`. All other exceptions keep
propagating as before — this only adds a specific case ahead of the general one, it doesn't change
the general rollback/re-raise behavior `CLAUDE.md` establishes for mutating query functions.

### Delete guard

New query functions `count_votes_for_previous_party(conn, party_id) -> int` (`SELECT COUNT(*) FROM
votes WHERE previous_party_id = %s`) and `count_votes_for_upcoming_party(conn, party_id) -> int`
(`SELECT COUNT(DISTINCT vote_id) FROM vote_upcoming_parties WHERE upcoming_party_id = %s`). Both
delete routes call the matching count function before attempting the delete; if count > 0, return
`jsonify({'error': f'{count} votes still reference this party'}), 409` without touching the row.
Only when count is 0 does the route proceed to the existing `delete_previous_party`/
`delete_upcoming_party` call. These same two count functions back the reassign-preview endpoints
below — one implementation, two call sites.

### Reassign

New routes, mirroring the existing party CRUD shape:

- `GET /api/admin/previous-parties/<source_id>/reassign-count?target_id=<id>` → `{"count": N}`,
  read-only, using `count_votes_for_previous_party`.
- `POST /api/admin/previous-parties/<source_id>/reassign` body `{"target_id": <id>}` → validates
  `target_id != source_id` (400 if equal) and that `target_id` exists (404 if not), then in one
  transaction: `UPDATE votes SET previous_party_id = %(target)s WHERE previous_party_id =
  %(source)s`, returns `{"reassigned": <rowcount>}`.
- `GET /api/admin/upcoming-parties/<source_id>/reassign-count?target_id=<id>` → `{"count": N}`,
  using `count_votes_for_upcoming_party`.
- `POST /api/admin/upcoming-parties/<source_id>/reassign` body `{"target_id": <id>}` → same
  validation, then in one transaction:
  1. Count affected votes first (for the response): `SELECT COUNT(DISTINCT vote_id) FROM
     vote_upcoming_parties WHERE upcoming_party_id = %(source)s`.
  2. Drop collision rows: `DELETE FROM vote_upcoming_parties WHERE upcoming_party_id = %(source)s
     AND vote_id IN (SELECT vote_id FROM vote_upcoming_parties WHERE upcoming_party_id =
     %(target)s)` — handles a vote that already has both source and target among its picks, which
     would otherwise violate the `(vote_id, upcoming_party_id)` primary key on the next step.
  3. Reassign the rest: `UPDATE vote_upcoming_parties SET upcoming_party_id = %(target)s WHERE
     upcoming_party_id = %(source)s` — collision-free by construction after step 2.
  4. Return `{"reassigned": <count from step 1>}`.

All four new query functions follow the existing `try/except Exception: conn.rollback(); raise /
finally: cur.close()` shape; routes follow the existing `try/finally: conn.close()` shape. No schema
change — this operates entirely within the existing `votes`/`vote_upcoming_parties` tables and their
existing constraints: `votes.previous_party_id` carries no unique constraint (many votes already
share one party), so the plain `UPDATE` in the previous-parties case is safe on its own; the
composite primary key on `vote_upcoming_parties` is exactly what the delete-then-update ordering in
the upcoming-parties case exists to protect against. Neither table's rollup
(`rollup_previous`/`rollup_upcoming`/`rollup_previous_upcoming`) is touched directly — the worker's
normal recompute cycle picks up the change like any other vote-data mutation.

## Components

### Secret gate

- A form with a single `password`-type input and submit button.
- On submit: `GET /api/admin/votes` with the entered value as `X-Admin-Secret`.
  - 200: store the secret in `sessionStorage['voteballAdminSecret']`, hide the gate, show the tab
    bar + default-active tab ("Previous Parties"), trigger its lazy load.
  - 401: inline error "Incorrect secret", input cleared, gate stays.
  - other non-2xx / network failure: inline generic error, gate stays.
- On page load, if `sessionStorage['voteballAdminSecret']` is already set, skip straight to the
  probe request (so a refresh within the same tab doesn't force re-entry).

### Tab bar

- Three buttons: "Previous Parties", "Upcoming Parties", "Votes". Clicking sets the clicked tab's
  section to visible and hides the other two (same pattern as `results.js`'s mode toggle), and
  triggers that tab's lazy load if it hasn't fetched yet this session.

### Previous Parties / Upcoming Parties tabs (identical shape, different endpoints)

- On first activation: fetch `/api/options`, render `previous_parties` (or `upcoming_parties`) as a
  list, one row per party: name text, "Rename" button, "Delete" button.
- **Rename**: click swaps the name text for a text input + Save/Cancel; Save calls
  `PATCH /api/admin/{previous,upcoming}-parties/<id>` with the new name, then re-renders that row
  from the response (or refetches the list on error to stay consistent). Inline error under the row
  on failure (e.g. duplicate name).
- **Delete**: `confirm('Delete "<name>"? This cannot be undone.')`, then
  `DELETE /api/admin/{previous,upcoming}-parties/<id>`; on success remove the row; on failure, inline
  error.
- **Add new**: a text input + "Add" button below the list. On submit,
  `POST /api/admin/{previous,upcoming}-parties`; on success, append the new row and clear the input;
  on failure (e.g. duplicate name / empty), inline error near the form.
- **Reassign**: a third per-row button, "Reassign votes...", opens a small inline form: a dropdown
  of the *other* parties in the same list, plus a "+ new party" option that reveals a name input
  (submitting that creates the party via the existing POST endpoint first, then proceeds with its
  returned id as the target). On choosing a target, fetch the `reassign-count` endpoint and show the
  count in the confirm step: `confirm('Reassign N votes from "<source>" to "<target>"? This cannot
  be undone.')`. On confirm, `POST .../reassign`; on success, show the returned count and refresh
  the list (the row for a since-emptied source party still exists — reassign never deletes the
  source — so the admin can follow up with Delete if desired, now safe since Delete's guard will see
  zero referencing votes).

### Votes tab

- `GET /api/admin/votes` returns rows shaped
  `{id, league_id, club_id, previous_vote_status, previous_party_id, upcoming_vote_status,
  created_at, upcoming_party_ids: [...]}` — IDs only, ordered by `v.id` ascending. No names, and no
  `cookie_token` (already excluded server-side).
- On first activation: fetch `/api/options` (if not already cached from a party tab) to resolve
  `league_id`/`club_id`/`previous_party_id`/`upcoming_party_ids` to names client-side, then fetch
  `GET /api/admin/votes` and render as a table, reversed to newest-first (highest `id` first — `id`
  is monotonic with insertion order, so no `created_at` parsing/sorting needed). Columns: id,
  created_at, league, club (or "—"), previous vote (party name, or "did not vote" when
  `previous_vote_status` is `did_not_vote`), upcoming vote (party names comma-joined, or "undecided"
  when `upcoming_vote_status` is `undecided`), and a Delete button per row.
- **Delete**: `confirm('Delete vote #<id>? This cannot be undone.')`, then
  `DELETE /api/admin/votes/<id>`; on success remove the row; on failure, inline error.
- All names are resolved client-side from `/api/options` data and rendered via
  `createElement`/`textContent`, never `innerHTML`, matching the rest of the frontend's XSS posture.

## Data flow summary

```
page load
  └─ sessionStorage has secret? ─yes─> probe GET /api/admin/votes
  │                                      ├─ 200 → show tabs, lazy-load active tab
  │                                      └─ 401 → clear storage, show gate ("session expired")
  └─ no ─> show gate

gate submit ─> probe GET /api/admin/votes
                 ├─ 200 → store secret, show tabs, lazy-load active tab
                 └─ 401 → inline error, stay on gate

any admin fetch (rename/delete/create/reassign/votes-list) ─> attach X-Admin-Secret from sessionStorage
                 ├─ 401 → clear storage, show gate ("session expired")
                 ├─ 2xx → update UI (re-render row/list)
                 └─ other 4xx/5xx → inline error near the relevant control

reassign flow (per party row) ─> pick target ─> GET reassign-count ─> confirm(N) ─> POST reassign
                                                                          ├─ 2xx → refresh list, show count
                                                                          └─ 4xx/5xx → inline error

delete flow (per party row) ─> confirm() ─> DELETE
                                  ├─ 204 → remove row
                                  └─ 409 (still referenced) → inline error naming the count,
                                                               suggesting Reassign first
```

## Error handling

- Wrong/expired secret: handled uniformly by the gate/re-prompt flow above — no separate cases per
  endpoint.
- Validation errors (empty name → 400, duplicate name → 409, delete blocked by referencing votes →
  409, reassign with equal source/target → 400, reassign to a nonexistent target → 404): the
  backend's `{'error': '...'}` JSON message is shown inline near the form/control that triggered it.
- Network/unexpected errors: generic inline "Something went wrong" message, matching the existing
  style in `vote.js`.
- No client-side retry/backoff logic — matches the rest of the frontend's simplicity level.

## Testing

Backend: new tests in `tests/test_app.py`, mirroring the existing empty-name-400 pattern:

- Duplicate-name fix: create/rename × previous/upcoming (4 cases) returns 409 with a JSON `error`
  body when the name already exists.
- Delete guard: deleting a previous or upcoming party that a seeded vote references (2 cases)
  returns 409 instead of crashing or silently cascading; deleting an unreferenced party still
  succeeds (204), unchanged from today.
- Reassign, previous parties: a vote with `previous_party_id = source` ends up with
  `previous_party_id = target` after `POST .../reassign`; `reassign-count` reflects the right number
  before and after; equal source/target → 400; nonexistent target → 404.
- Reassign, upcoming parties: the same, plus the collision case specifically — a vote whose
  `upcoming_party_ids` already contains both source and target ends up with target only (not a
  duplicate row, not an error) after reassign, and a vote with only source ends up with only target.

Frontend: no automated test suite exists for this project (per `CLAUDE.md` — matches the S3App
precedent). Verified manually by running the stack locally and driving `admin.html` in a browser:

- Incorrect secret shows inline error and does not reveal tabs.
- Correct secret reveals tabs; refreshing the tab within the same session skips the prompt.
- Previous/upcoming party create, rename, and delete each round-trip correctly and update the list.
- Duplicate-name rename/create surfaces the backend's 409 validation error inline.
- Deleting a party with votes attached shows the 409 error instead of crashing; deleting an
  unreferenced party (including one just emptied by a reassign) succeeds.
- Reassign shows the correct vote count in the confirmation, and the target party's effective vote
  count increases accordingly on the next results view (after a worker recompute).
- Votes tab lists existing votes and delete removes the correct row.
- Rotating `ADMIN_SECRET` (or corrupting the stored value) and retrying an action re-shows the gate
  with the "session expired" message instead of silently failing.

## Non-goals

- No change to admin auth model (still a single static shared secret, still `X-Admin-Secret`).
- No pagination, search, or filtering on the votes table.
- No admin UI for leagues/clubs — those are seed-only per `CLAUDE.md`, not admin-editable.
- No link from public pages to `admin.html`.
- No CSS/visual redesign — this reuses `style.css` as-is (visual redesign is a separate backlog item).
- No automatic split/merge detection or proportional vote-splitting. Reassignment is entirely
  admin-invoked and all-or-nothing per action (every vote referencing the source moves to the same
  target) — there's no mechanism to send some fraction of a source party's votes to one target and
  the rest elsewhere. A split into more than one meaningful successor requires the admin to make the
  same judgment call the Otzma Yehudit example does: decide which single successor represents the
  original voters' intent, or leave the history where it is.
- No party lineage tracking (no "this party is the successor of that party" record kept after the
  fact) and no retroactive relabeling in `/api/results` beyond what the reassignment itself produces
  by moving the underlying vote rows. Once reassigned, a vote's history looks identical to a vote
  that was always cast for the target party — there's no audit trail of "this vote used to point at
  a different party ID." Add one later (e.g. a `party_reassignment_log` table) if that history turns
  out to matter.
