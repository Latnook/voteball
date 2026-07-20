# Max-3 upcoming-party selection limit

Status: approved
Date: 2026-07-12

## Context

`/api/vote` accepts `upcoming_party_ids`, an unbounded array, when `upcoming_vote_status=considering`.
The site owner wants to cap this at 3 — a voter can say they're considering at most three upcoming
parties. This does not affect the previous-election choice, which is already a single radio button
(`previous_party_id`), enforced by the form's HTML structure — no change needed there.

## Decisions

1. **Prevent, don't just validate, on the frontend.** Once 3 checkboxes are checked, the remaining
   unchecked ones become `disabled` — a 4th selection is physically impossible rather than something
   the user finds out about after clicking submit. Unchecking one re-enables the rest.
2. **Backend enforces unconditionally**, not only when `upcoming_vote_status=considering` — a
   malformed or non-standard client request with `upcoming_party_ids.length > 3` gets rejected
   regardless of status, the same defense-in-depth posture as the existing empty-array check.

## Backend

In `ansible-project/roles/backend/files/backend/app.py`'s `vote()` route, add a second check
alongside the existing one:

```python
    if body.get('upcoming_vote_status') == 'considering' and not body.get('upcoming_party_ids'):
        return jsonify({'error': 'select at least one upcoming party when status is considering'}), 400
    if len(body.get('upcoming_party_ids') or []) > 3:
        return jsonify({'error': 'select at most 3 upcoming parties'}), 400
```

No `queries.py` change — this is request-shape validation, same layer as the existing empty-array
check, before `queries.insert_vote` is ever called.

## Frontend

`ansible-project/roles/frontend/files/nginx/vote.js`: add a change listener on
`.upcoming-checkbox` elements that counts how many are checked; if the count is 3, every unchecked
box gets `disabled = true`; otherwise all are `disabled = false`. Runs after `loadOptions()` renders
the checkboxes (so it can attach to elements that exist by then) and again after `loadOptions()`
finishes, to cover the initial (0-checked) state.

`ansible-project/roles/frontend/files/nginx/index.html`: append a short hint to fieldset 3's legend
— `who are you considering? (choose up to 3)` — so the disabled-checkbox behavior reads as intentional
rather than a bug.

## Testing

Backend: a new test in `tests/test_app.py`, mirroring the existing
`test_vote_endpoint_considering_with_no_parties_returns_400`, asserting that 4 `upcoming_party_ids`
returns 400.

Frontend: no automated suite for this project (per `CLAUDE.md`) — verified by driving the real form.

## Non-goals

- No change to the previous-election single-choice radio button.
- No server-side change to how `upcoming_party_ids` are stored (`vote_upcoming_parties` join table
  is unchanged) — this is purely an input-count cap.
