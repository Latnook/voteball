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

## Backend

In `ansible-project/roles/backend/files/backend/queries.py`, `create_previous_party`,
`rename_previous_party`, `create_upcoming_party`, and `rename_upcoming_party` each catch
`psycopg2.errors.UniqueViolation` specifically (before the existing broad `except Exception:
rollback; raise`), roll back, and raise a distinct exception (e.g. a small
`DuplicatePartyNameError`) that the four corresponding routes in `app.py` catch and turn into
`jsonify({'error': 'a party with this name already exists'}), 409`. All other exceptions keep
propagating as before — this only adds a specific case ahead of the general one, it doesn't change
the general rollback/re-raise behavior `CLAUDE.md` establishes for mutating query functions.

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

any admin fetch (rename/delete/create/votes-list) ─> attach X-Admin-Secret from sessionStorage
                 ├─ 401 → clear storage, show gate ("session expired")
                 ├─ 2xx → update UI (re-render row/list)
                 └─ other 4xx/5xx → inline error near the relevant control
```

## Error handling

- Wrong/expired secret: handled uniformly by the gate/re-prompt flow above — no separate cases per
  endpoint.
- Validation errors (empty name → 400, duplicate name → 409 per the backend fix above): the
  backend's `{'error': '...'}` JSON message is shown inline near the form that triggered it.
- Network/unexpected errors: generic inline "Something went wrong" message, matching the existing
  style in `vote.js`.
- No client-side retry/backoff logic — matches the rest of the frontend's simplicity level.

## Testing

Backend: new tests in `tests/test_app.py` for the duplicate-name fix — POSTing/PATCHing a
`previous-parties` or `upcoming-parties` name that already exists returns 409 with a JSON `error`
body (four cases: create/rename × previous/upcoming), mirroring the existing pattern for the
empty-name 400 case.

Frontend: no automated test suite exists for this project (per `CLAUDE.md` — matches the S3App
precedent). Verified manually by running the stack locally and driving `admin.html` in a browser:

- Incorrect secret shows inline error and does not reveal tabs.
- Correct secret reveals tabs; refreshing the tab within the same session skips the prompt.
- Previous/upcoming party create, rename, and delete each round-trip correctly and update the list.
- Duplicate-name rename/create surfaces the backend's 409 validation error inline.
- Votes tab lists existing votes and delete removes the correct row.
- Rotating `ADMIN_SECRET` (or corrupting the stored value) and retrying an action re-shows the gate
  with the "session expired" message instead of silently failing.

## Non-goals

- No change to admin auth model (still a single static shared secret, still `X-Admin-Secret`).
- No pagination, search, or filtering on the votes table.
- No admin UI for leagues/clubs — those are seed-only per `CLAUDE.md`, not admin-editable.
- No link from public pages to `admin.html`.
- No CSS/visual redesign — this reuses `style.css` as-is (visual redesign is a separate backlog item).
