# Previous↔upcoming party crosstab

Status: approved
Date: 2026-07-12

## Context

Voteball lets someone record which party they voted for in the last Knesset election
(`previous_party_id`) and which party/parties they're now considering for the next one
(`upcoming_party_ids`), on the same vote row. Several previous-election parties have since
merged or split (e.g. יש עתיד merging with Bennett's party into ביחד; העבודה and מרצ merging into
הדמוקרטים; the joint הציונות הדתית list splitting into separate הציונות הדתית and עוצמה יהודית
lines for the next election — see `docs/superpowers/specs/2026-07-12-party-display-names-design.md`
for the full seeded lists). Viewing the previous-election results and the upcoming-election results
as two independent breakdowns hides this continuity — a reader has to already know Israeli politics
to connect "יש עתיד voters disappeared from the previous breakdown" with "a new ביחד bloc appeared
in the upcoming breakdown."

This spec adds a crosstab: for a given previous party, what upcoming parties are those same voters
now considering (and vice versa). Because every vote row already carries both fields, this is
answerable directly from real voting behavior — no static merge/split mapping table is needed. The
connection between יש עתיד and ביחד will simply show up as a large real number in the data, the same
way it would for any two parties, without Voteball ever having to declare "these are the same
movement."

This is the second of several planned improvements to Voteball (see
`docs/superpowers/specs/2026-07-12-party-display-names-design.md`'s "Non-goals" for the full list —
i18n, the max-3 selection limit, an admin UI, and a visual redesign are separate, later efforts).

## Decisions

1. **A real crosstab, not just a label.** Reject the simpler "annotate the party name" idea in favor
   of actually computing "of people who voted party X previously, what are they considering now" —
   this is directly answerable from existing vote data.
2. **Global, not sliced by league/club.** The site owner wants football fandom to stay the main
   focus of Voteball; the crosstab is political-alignment information and shouldn't grow into a
   competing three-dimensional (previous × upcoming × club) data surface. One count per
   previous↔upcoming party pair, full stop.
3. **Reuse the existing per-party results view — no new page.** `results.html`'s "start from a
   party" mode already has two panels (previous-results, upcoming-results); today, whichever panel
   *isn't* the one you searched by shows a static "switch party type to see this breakdown" message.
   That's the crosstab's home — no new endpoint, no new page, no matrix/grid UI.
4. **Fan-out for multi-select "considering," same as `rollup_upcoming` already does.** A voter
   considering up to three upcoming parties (three is a separate future constraint, not yet
   enforced) contributes to the crosstab count for *each* of those parties — the crosstab's column
   for one previous party won't sum to exactly that party's total voter count. This mirrors how
   `rollup_upcoming` already fans out multi-select votes across league/club breakdowns, so it's not
   a new kind of double-counting, just the same behavior in a new dimension.

## Data model

New table in `ansible-project/roles/backend/files/backend/schema.sql`, following the existing
`rollup_previous`/`rollup_upcoming` pattern:

```sql
CREATE TABLE IF NOT EXISTS rollup_previous_upcoming (
    previous_party_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_previous ON rollup_previous_upcoming (previous_party_id);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_upcoming ON rollup_previous_upcoming (upcoming_party_id);
```

Both columns are nullable: `previous_party_id IS NULL` represents `did_not_vote`;
`upcoming_party_id IS NULL` represents `upcoming_vote_status = 'undecided'`. A voter who both
did-not-vote previously and is undecided now produces its own `(NULL, NULL, count)` row — it falls
out naturally as its own `GROUP BY previous_party_id` group in the worker's second INSERT (see
below), the same way today's `rollup_upcoming` already produces `upcoming_party_id = NULL` rows for
undecided voters regardless of their previous-party value.

## Worker computation

`ansible-project/roles/worker/files/worker/rollups.py`'s `recompute()` gains a third
truncate/insert block, following the exact shape of the existing `rollup_upcoming` block:

```python
cur.execute('TRUNCATE rollup_previous_upcoming')
cur.execute('''
    INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count)
    SELECT v.previous_party_id, vup.upcoming_party_id, COUNT(*)
    FROM votes v
    JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
    GROUP BY v.previous_party_id, vup.upcoming_party_id
''')
cur.execute('''
    INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count)
    SELECT previous_party_id, NULL, COUNT(*)
    FROM votes
    WHERE upcoming_vote_status = 'undecided'
    GROUP BY previous_party_id
''')
```

Runs on the worker's existing ~30s loop alongside the other two rollups — no new scheduling.

## Backend API

No new endpoint. `queries.get_results_by_party(conn, party_type, party_id)` in
`ansible-project/roles/backend/files/backend/queries.py` gains a second query and a new
`crosstab` key in its return value:

- `type=previous`: `crosstab` is `[{upcoming_party_id, count}, ...]` — what upcoming parties this
  previous party's voters are now considering.
- `type=upcoming`: `crosstab` is `[{previous_party_id, count}, ...]` — what previous parties this
  upcoming party's considerers came from.

Both cases key off `rollup_previous_upcoming`, filtering on whichever column matches `party_type`
and grouping by the other. `GET /api/results?by=party&type=previous|upcoming&id=N` is otherwise
unchanged — `app.py`'s `results()` route already returns whatever `queries.get_results_by_party`
gives it, so the route itself needs no code change, just the CLAUDE.md API-table note updated to
mention `crosstab`.

## Frontend

`ansible-project/roles/frontend/files/nginx/results.js`'s `loadResultsByParty()`: the line that
currently sets the "other" panel to a static message —

```javascript
document.getElementById(otherId).innerHTML = '<p>Switch party type to see this breakdown.</p>';
```

is replaced with a `renderBars` call against `data.crosstab`, using whichever name-lookup function
(`previousPartyName`/`upcomingPartyName`) corresponds to the *other* party type from the one
searched by. Same panel, same `renderBars` helper already used elsewhere on the page — no new CSS,
no new DOM elements.

## Testing

Real-Postgres TDD per `CLAUDE.md`, in both the worker and backend suites:

- **Worker** (`ansible-project/roles/worker/files/worker/tests/`, reusing the shared
  `voteball-test-db` container): extend rollup-recompute tests to cover
  `rollup_previous_upcoming` — a voter considering multiple upcoming parties fans out to multiple
  crosstab rows; an undecided voter produces an `upcoming_party_id = NULL` row; a did-not-vote voter
  produces `previous_party_id = NULL` rows.
- **Backend** (`ansible-project/roles/backend/files/backend/tests/`): extend
  `get_results_by_party` tests to assert the new `crosstab` key in both directions
  (`type=previous` and `type=upcoming`), including the case where a previous party has zero
  crosstab rows (no one who voted for it has stated an upcoming preference yet).

## Non-goals (deferred to future specs)

- Any static previous→upcoming lineage/mapping table — deliberately rejected; the crosstab reads
  live behavior instead.
- League/club-sliced crosstab — deliberately out of scope per the "keep football the focus" decision
  above; revisit only if explicitly requested later.
- A dedicated full-matrix (all-previous × all-upcoming) view — the per-party crosstab covers the
  stated need; a grid/heatmap view is a separate, bigger UI project if ever wanted.
- i18n, the max-3 selection limit, the admin UI, and the visual redesign — tracked separately per
  `docs/superpowers/specs/2026-07-12-party-display-names-design.md`.
