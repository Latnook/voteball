# Max-3 Upcoming-Party Selection Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap `upcoming_party_ids` at 3 selections — prevented on the frontend (checkboxes disable at 3), enforced unconditionally on the backend as defense-in-depth.

**Architecture:** Two independent, small changes — a second validation check in the existing `/api/vote` route (no new endpoint, no `queries.py` change), and a change-listener in the existing vote form's checkbox rendering (no new DOM elements beyond a legend-text tweak).

**Tech Stack:** Flask 3.1, pytest, real Postgres 17 (backend); plain JS, no build step, no automated suite (frontend).

## Global Constraints

- Backend tests run TDD-style against a real Postgres container, not mocks, per `CLAUDE.md`.
- The previous-election choice (`previous_party_id`) is unaffected by this plan — it's already a single-select radio button; do not touch it.
- Frontend has no automated test suite (per `CLAUDE.md`) — verify by driving the real form in a browser, or by reasoning through the DOM logic directly if no browser is available in the execution environment.

---

## Task 1: Backend — reject more than 3 upcoming parties

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_app.py`

**Interfaces:**
- Consumes: nothing new — the existing `POST /api/vote` request body's `upcoming_party_ids` field.
- Produces: `POST /api/vote` now returns `400 {"error": "select at most 3 upcoming parties"}` whenever `len(upcoming_party_ids) > 3`, regardless of `upcoming_vote_status`. No other task depends on this.

- [ ] **Step 1: Write the failing test**

Add to `ansible-project/roles/backend/files/backend/tests/test_app.py`, near the existing
`test_vote_endpoint_considering_with_no_parties_returns_400` (reuses seeded `upcoming_parties` data
— no ad-hoc party creation needed, since `seed.sql` already has 13 rows):

```python
def test_vote_endpoint_considering_with_more_than_three_parties_returns_400(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties ORDER BY id LIMIT 4")
    party_ids = [r[0] for r in cur.fetchall()]
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': party_ids,
    })
    assert resp.status_code == 400
    assert resp.get_json() == {'error': 'select at most 3 upcoming parties'}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/test_app.py::test_vote_endpoint_considering_with_more_than_three_parties_returns_400 -v
```

Expected: FAIL — the vote currently succeeds (`201`), since no such limit exists yet
(`assert 201 == 400`).

- [ ] **Step 3: Implement the check**

In `ansible-project/roles/backend/files/backend/app.py`'s `vote()` route, change:

```python
    if body.get('upcoming_vote_status') == 'considering' and not body.get('upcoming_party_ids'):
        return jsonify({'error': 'select at least one upcoming party when status is considering'}), 400
```

to:

```python
    if body.get('upcoming_vote_status') == 'considering' and not body.get('upcoming_party_ids'):
        return jsonify({'error': 'select at least one upcoming party when status is considering'}), 400
    if len(body.get('upcoming_party_ids') or []) > 3:
        return jsonify({'error': 'select at most 3 upcoming parties'}), 400
```

- [ ] **Step 4: Run it to verify it passes**

```bash
python -m pytest tests/test_app.py::test_vote_endpoint_considering_with_more_than_three_parties_returns_400 -v
```

Expected: PASS.

- [ ] **Step 5: Run the full backend suite**

```bash
python -m pytest tests/ -v
```

Expected: all pass, including the pre-existing `test_vote_endpoint_considering_with_parties_succeeds`
(2 parties, well under the new limit — unaffected) and
`test_vote_endpoint_considering_with_no_parties_returns_400` (unaffected, different branch).

- [ ] **Step 6: Commit**

```bash
git add ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Reject more than 3 upcoming_party_ids in POST /api/vote"
git push
```

---

## Task 2: Frontend — disable further checkboxes at 3

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/vote.js`
- Modify: `ansible-project/roles/frontend/files/nginx/index.html`

**Interfaces:**
- Consumes: nothing new — the existing `.upcoming-checkbox` elements rendered by `loadOptions()`.
- Produces: no new interface — this is the final consumer (the form itself).

- [ ] **Step 1: Add the limit-enforcing listener**

In `ansible-project/roles/frontend/files/nginx/vote.js`, change the upcoming-parties rendering
block (currently):

```javascript
  const upcomingDiv = document.getElementById('upcoming-party-options');
  data.upcoming_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'upcoming-checkbox';
    input.value = p.id;
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + p.name));
    upcomingDiv.appendChild(label);
  });
}
```

to:

```javascript
  const upcomingDiv = document.getElementById('upcoming-party-options');
  data.upcoming_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'upcoming-checkbox';
    input.value = p.id;
    input.addEventListener('change', enforceUpcomingPartyLimit);
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + p.name));
    upcomingDiv.appendChild(label);
  });
}

function enforceUpcomingPartyLimit() {
  const checkboxes = document.querySelectorAll('.upcoming-checkbox');
  const checkedCount = document.querySelectorAll('.upcoming-checkbox:checked').length;
  checkboxes.forEach(cb => {
    cb.disabled = !cb.checked && checkedCount >= 3;
  });
}
```

(`enforceUpcomingPartyLimit` is a function declaration, so it's hoisted — safe to reference from
inside `loadOptions` above its own definition in the file. No call is needed at page load: with 0
checkboxes checked initially, nothing needs disabling.)

Note this does not conflict with the existing `undecided-checkbox` handler (which disables *all*
upcoming checkboxes when undecided is checked, and un-disables all when unchecked) — checking
undecided already clears every upcoming checkbox first, so `enforceUpcomingPartyLimit`'s own state
is naturally back at 0-checked by the time undecided is unchecked.

- [ ] **Step 2: Add the "(choose up to 3)" hint**

In `ansible-project/roles/frontend/files/nginx/index.html`, change:

```html
      <legend>3. Upcoming election — who are you considering?</legend>
```

to:

```html
      <legend>3. Upcoming election — who are you considering? (choose up to 3)</legend>
```

- [ ] **Step 3: Verify**

No automated frontend suite exists for this project (per `CLAUDE.md`) — verify by driving the real
form in a browser if one is available in the execution environment: load `index.html` (served
however the environment allows — e.g. a local static file server, keeping in mind `vote.js`'s
`fetch('/api/options')` needs a backend reachable at a relative `/api/*` path, so a raw
`file://` open won't work), check 3 upcoming-party checkboxes, and confirm the remaining ones
visually grey out / become unclickable; uncheck one and confirm the rest re-enable.

If no browser is available, verify by direct reasoning over the DOM logic instead: confirm
`enforceUpcomingPartyLimit` is wired to every checkbox's `change` event, and manually trace the
function's logic against 0/1/2/3/4-checked scenarios (a 4th checkbox can never reach `checked=true`
via a user click once its `disabled` is `true`, since disabled form elements don't fire `change` on
click and don't submit their value). Note in your report which verification method you used.

- [ ] **Step 4: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/vote.js \
        ansible-project/roles/frontend/files/nginx/index.html
git commit -m "Disable further upcoming-party checkboxes once 3 are selected"
git push
```

---

## Final verification

```bash
cd ansible-project/roles/backend/files/backend
python -m pytest tests/ -v
```

Expected: full backend suite green (Task 2 has no automated suite to run).
