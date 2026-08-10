# Intended-Vote Political Lean Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repoint the results page's Political Lean card and Diversity tab from last-election votes to intended vote, counted one ballot at a time, with the undecided share shown rather than hidden.

**Architecture:** A ballot may name up to 3 upcoming parties, so `rollup_upcoming.vote_count` counts *picks, not people*. The worker gains a `weight NUMERIC` column carrying `SUM(1.0/k)` per ballot (k = that ballot's pick count) so each ballot totals exactly 1. `vote_count` stays integral and keeps driving display bars. The backend exposes `weight`; the frontend averages on it.

**Tech Stack:** Postgres 17, Python 3 (Flask backend, plain-loop worker, psycopg2), vanilla JS frontend (no build step, no JS test framework), pytest against a real Postgres.

## Global Constraints

- **Full spec:** `docs/design/2026-08-10-intended-vote-lean-design.md`. Decisions 1–9 are binding.
- **`schema.sql` re-runs on every backend boot.** Add columns with `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, never by editing a `CREATE TABLE` — `CREATE TABLE IF NOT EXISTS` skips an existing table, so a `CREATE` edit never reaches a live database.
- **`vote_count` must stay `INTEGER` and unchanged.** It drives the displayed breakdown bars and percentages.
- **No new tables.** There are already eight rollup tables and *two* `conftest.py` `DROP TABLE … CASCADE` lists (`services/backend/tests/conftest.py`, `services/worker/tests/conftest.py`) that must stay in step with `schema.sql`. This plan adds columns only, so neither list changes.
- **The frontend has no automated test suite** (`services/frontend/CLAUDE.md`). Frontend tasks are verified by driving the real page with Playwright, and by `node --check` for parse errors. Playwright is installed **globally** and is CommonJS: `NODE_PATH` does not work for ESM, and `import { chromium } from 'playwright'` fails twice over (unresolvable, then "named export not found"). Resolve it dynamically and unwrap the default — `const pw = await import(process.env.PW); const { chromium } = pw.default ?? pw;` with `PW=$(npm root -g)/playwright/index.js`.
- **`ruff` runs before every test stage in CI.** Run `ruff check` on any Python change before committing, or the deploy fails after the tests pass.
- **No `Claude-Session:` trailer** in any commit message (public repo).
- **All three i18n language objects** (`en`, `he`, `ru`) must carry identical key sets and identical `{placeholder}` tokens. `t()` returns the key itself on a miss, so a gap renders the raw key on the page instead of throwing.
- **Undecided ballots** (`upcoming_party_id IS NULL`) are excluded from every axis average, from the diversity index, and from the eligibility gates; they appear only in the coverage line, as a share of all ballots.
- Test Postgres: `docker start voteball-test-db`. Run suites with `DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/ -q` from the service directory.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `services/backend/schema.sql` | schema, idempotent, re-run each boot | add `weight` to two rollup tables |
| `services/worker/rollups.py` | recompute all rollups | write `weight` in `_recompute_upcoming` + `_recompute_national` |
| `services/worker/tests/test_rollups.py` | worker tests | new weight tests |
| `services/backend/queries.py` | all SQL | return `weight` from 3 upcoming selects |
| `services/backend/tests/test_queries.py` | backend tests | assert `weight` exposed |
| `services/frontend/analytics.js` | results-page analytics | helpers, lean card, diversity, traits gate, coverage line |
| `services/frontend/i18n.js` | interface strings | 2 new keys × 3 languages |
| `services/frontend/style.css` | styles | one `.lean-detail-note` rule |
| `docs/design/2026-08-10-...-design.md` | the spec | add Verification outcome |

No new files, so **no `Dockerfile` `COPY` change** is needed in any service — the one gap that would otherwise 404 at runtime with no build error.

---

### Task 1: Add the `weight` column

**Files:**
- Modify: `services/backend/schema.sql` (after the `rollup_national_upcoming` block, ~line 288)

**Interfaces:**
- Produces: `rollup_upcoming.weight NUMERIC NOT NULL DEFAULT 0`, `rollup_national_upcoming.weight NUMERIC NOT NULL DEFAULT 0`

- [ ] **Step 1: Add the columns**

Append after the `rollup_national_upcoming` index line:

```sql
-- Ballot weight for the intended-vote lean (docs/design/2026-08-10-intended-vote-lean-design.md).
-- vote_count counts PICKS -- a ballot may name up to 3 parties -- so averaging on it gives a
-- 3-party ballot triple the say of a 1-party one. weight carries SUM(1.0/k) so each ballot totals
-- exactly 1. vote_count stays INTEGER and keeps driving the displayed breakdown bars.
-- ADD COLUMN IF NOT EXISTS, not a CREATE TABLE edit: schema.sql re-runs on every backend boot and
-- CREATE TABLE IF NOT EXISTS skips an existing table, so a CREATE edit never reaches a live DB.
ALTER TABLE rollup_upcoming ADD COLUMN IF NOT EXISTS weight NUMERIC NOT NULL DEFAULT 0;
ALTER TABLE rollup_national_upcoming ADD COLUMN IF NOT EXISTS weight NUMERIC NOT NULL DEFAULT 0;
```

- [ ] **Step 2: Verify it applies twice (idempotency)**

```bash
docker start voteball-test-db
docker exec -u postgres voteball-test-db dropdb --if-exists plancheck
docker exec -u postgres voteball-test-db createdb plancheck
docker exec -i -u postgres voteball-test-db psql -q -v ON_ERROR_STOP=1 -d plancheck < services/backend/schema.sql
docker exec -i -u postgres voteball-test-db psql -q -v ON_ERROR_STOP=1 -d plancheck < services/backend/schema.sql
docker exec -u postgres voteball-test-db psql -d plancheck -c "\d rollup_upcoming"
```

Expected: no error on the second run; `weight | numeric | not null default 0` present.

- [ ] **Step 3: Commit**

```bash
git add services/backend/schema.sql
git commit -m "feat(schema): add ballot weight to the upcoming rollups"
```

---

### Task 2: Worker writes ballot weight at club and league scope

**Files:**
- Modify: `services/worker/rollups.py:64-101` (`_recompute_upcoming`)
- Test: `services/worker/tests/test_rollups.py`

**Interfaces:**
- Consumes: `rollup_upcoming.weight` from Task 1
- Produces: `rollup_upcoming` rows where `SUM(weight)` per scope equals the **ballot** count

- [ ] **Step 1: Write the failing test**

Append to `services/worker/tests/test_rollups.py`. `_seed_votes` already creates vote 1 (picks Party A *and* Party B) and vote 2 (undecided) — exactly the multi-pick fixture this needs.

```python
def test_upcoming_weight_counts_ballots_not_picks(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT upcoming_party_id, vote_count, weight FROM rollup_upcoming WHERE club_id = %s',
        (club_id,)
    )
    rows = {r[0]: (r[1], float(r[2])) for r in cur.fetchall()}

    # Vote 1 named two parties, so it is HALF a ballot on each -- but still one pick each.
    assert rows[party_a] == (1, 0.5)
    assert rows[party_b] == (1, 0.5)
    # Vote 2 is undecided: a whole ballot on the NULL row.
    assert rows[None] == (1, 1.0)

    # The point of the column: 3 picks, 2 ballots.
    assert sum(c for c, _ in rows.values()) == 3
    assert sum(w for _, w in rows.values()) == 2.0
    cur.close()
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd services/worker
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/test_rollups.py::test_upcoming_weight_counts_ballots_not_picks -v
```

Expected: FAIL — `rows[party_a] == (1, 0.0)`, since `weight` defaults to 0 and nothing writes it.

- [ ] **Step 3: Write the weight into `_recompute_upcoming`**

Add this module-level constant next to `_VOTE_LEAGUES_TOUCHED_CTE`:

```python
# Each ballot contributes total weight 1, split evenly across the parties it named, so a 3-party
# ballot cannot outvote a 1-party one. See docs/design/2026-08-10-intended-vote-lean-design.md.
_PICK_COUNTS_CTE = '''
    pick_counts AS (
        SELECT vote_id, COUNT(*)::numeric AS k FROM vote_upcoming_parties GROUP BY vote_id
    )
'''
```

Replace the four statements in `_recompute_upcoming` after the `TRUNCATE`:

```python
    cur.execute(f'''
        WITH {_PICK_COUNTS_CTE}
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count, weight)
        SELECT vlt.league_id, NULL, vup.upcoming_party_id, COUNT(*), SUM(1.0 / pc.k)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        JOIN pick_counts pc ON pc.vote_id = v.id
        GROUP BY vlt.league_id, vup.upcoming_party_id
    ''')
    cur.execute(f'''
        WITH {_PICK_COUNTS_CTE}
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count, weight)
        SELECT vc.league_id, vc.club_id, vup.upcoming_party_id, COUNT(*), SUM(1.0 / pc.k)
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        JOIN pick_counts pc ON pc.vote_id = v.id
        GROUP BY vc.league_id, vc.club_id, vup.upcoming_party_id
    ''')

    cur.execute(f'''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count, weight)
        SELECT vlt.league_id, NULL, NULL, COUNT(*), COUNT(*)::numeric
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        WHERE v.upcoming_vote_status = 'undecided'
        GROUP BY vlt.league_id
    ''')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count, weight)
        SELECT vc.league_id, vc.club_id, NULL, COUNT(*), COUNT(*)::numeric
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        WHERE v.upcoming_vote_status = 'undecided'
        GROUP BY vc.league_id, vc.club_id
    ''')
```

An undecided ballot names no party, so it is one whole ballot on the NULL row — `COUNT(*)`, not `SUM(1/k)` (there is no k; the join would drop the row entirely).

- [ ] **Step 4: Run the whole worker suite**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/ -q
```

Expected: PASS, 41 tests (40 existing + 1 new). Existing tests assert `vote_count` only and must be untouched.

- [ ] **Step 5: Lint and commit**

```bash
cd services/worker && ruff check .
git add services/worker/rollups.py services/worker/tests/test_rollups.py
git commit -m "feat(worker): weight upcoming rollups by ballot, not by pick"
```

---

### Task 3: Worker writes ballot weight for national totals

**Files:**
- Modify: `services/worker/rollups.py:151-163` (inside `_recompute_national`)
- Test: `services/worker/tests/test_rollups.py`

**Interfaces:**
- Consumes: `_PICK_COUNTS_CTE` from Task 2, `rollup_national_upcoming.weight` from Task 1
- Produces: `rollup_national_upcoming.weight` summing to the ballot count

The national upcoming insert lives **inside `_recompute_national`**, not in a function of its own. It is easy to miss, and missing it leaves National showing pick-weighted numbers while every club scope is correct.

- [ ] **Step 1: Write the failing test**

```python
def test_national_upcoming_weight_counts_ballots_not_picks(conn):
    import rollups
    _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT upcoming_party_id, vote_count, weight FROM rollup_national_upcoming')
    rows = {r[0]: (r[1], float(r[2])) for r in cur.fetchall()}

    assert sum(c for c, _ in rows.values()) == 3      # picks
    assert sum(w for _, w in rows.values()) == 2.0    # ballots
    assert rows[None] == (1, 1.0)                     # the undecided ballot
    cur.close()
```

- [ ] **Step 2: Run it and watch it fail**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/test_rollups.py::test_national_upcoming_weight_counts_ballots_not_picks -v
```

Expected: FAIL — weights are 0.0, so the ballot sum is 0.0 not 2.0.

- [ ] **Step 3: Write the weight into `_recompute_national`**

Replace the two `rollup_national_upcoming` inserts:

```python
    cur.execute(f'''
        WITH {_PICK_COUNTS_CTE}
        INSERT INTO rollup_national_upcoming (upcoming_party_id, vote_count, weight)
        SELECT vup.upcoming_party_id, COUNT(*), SUM(1.0 / pc.k)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        JOIN pick_counts pc ON pc.vote_id = v.id
        GROUP BY vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_national_upcoming (upcoming_party_id, vote_count, weight)
        SELECT NULL, COUNT(*), COUNT(*)::numeric
        FROM votes WHERE upcoming_vote_status = 'undecided'
        HAVING COUNT(*) > 0
    ''')
```

- [ ] **Step 4: Run the whole worker suite**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/ -q
```

Expected: PASS, 42 tests.

- [ ] **Step 5: Lint and commit**

```bash
cd services/worker && ruff check .
git add services/worker/rollups.py services/worker/tests/test_rollups.py
git commit -m "feat(worker): weight national upcoming rollup by ballot"
```

---

### Task 4: Backend exposes `weight`

**Files:**
- Modify: `services/backend/queries.py:186-191` (`_results_for_filter`), `:205-206` (`get_results_all`), `:289` (clubs breakdown)
- Test: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: the `weight` column from Tasks 1–3
- Produces: every upcoming row gains `'weight': float` alongside `'party_id'` and `'count'`

`SUM(numeric)` returns a `Decimal` from psycopg2, and Flask's `jsonify` cannot serialize `Decimal` — it raises at request time, not at query time. Cast to `float` in the row builder.

- [ ] **Step 1: Write the failing test**

```python
def test_results_expose_ballot_weight_on_upcoming(conn):
    # One ballot naming two parties: 2 picks, 1 ballot.
    _seed_multi_pick_ballot(conn)   # helper added in Step 3

    all_results = queries.get_results_all(conn)

    assert sum(r['count'] for r in all_results['upcoming']) == 2
    assert sum(r['weight'] for r in all_results['upcoming']) == 1.0
    assert all(isinstance(r['weight'], float) for r in all_results['upcoming'])
    # previous rows are one-per-ballot already and carry no weight key
    assert 'weight' not in all_results['previous'][0]
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd services/backend
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/test_queries.py::test_results_expose_ballot_weight_on_upcoming -v
```

Expected: FAIL with `KeyError: 'weight'`.

- [ ] **Step 3: Add the helper and return the weight**

Add near the other fixtures in `tests/test_queries.py`:

```python
def _seed_multi_pick_ballot(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Plan Party A') RETURNING id")
    a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Plan Party B') RETURNING id")
    b = cur.fetchone()[0]
    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('did_not_vote', NULL, 'considering', 'plan-t1') RETURNING id'''
    )
    v = cur.fetchone()[0]
    for p in (a, b):
        cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v, p))
    cur.execute(
        '''INSERT INTO rollup_national_upcoming (upcoming_party_id, vote_count, weight)
           VALUES (%s, 1, 0.5), (%s, 1, 0.5)''', (a, b)
    )
    cur.execute(
        '''INSERT INTO rollup_national_previous (previous_party_id, vote_count) VALUES (NULL, 1)'''
    )
    conn.commit()
    cur.close()
    return a, b
```

In `queries.py`, change the three upcoming selects to also read `weight` and build the row with it:

```python
    cur.execute(
        f'SELECT upcoming_party_id, SUM(vote_count), SUM(weight) FROM rollup_upcoming '
        f'WHERE {where_clause} GROUP BY upcoming_party_id',
        params
    )
    upcoming = [{'party_id': r[0], 'count': r[1], 'weight': float(r[2] or 0)} for r in cur.fetchall()]
```

```python
    cur.execute('SELECT upcoming_party_id, SUM(vote_count), SUM(weight) FROM rollup_national_upcoming GROUP BY upcoming_party_id')
    upcoming = [{'party_id': r[0], 'count': r[1], 'weight': float(r[2] or 0)} for r in cur.fetchall()]
```

And in the clubs-breakdown builder (lines 288–294), which unpacks a 3-tuple in the loop header and so needs both lines changed together:

```python
    cur.execute(
        'SELECT club_id, upcoming_party_id, SUM(vote_count), SUM(weight) FROM rollup_upcoming '
        'WHERE club_id IS NOT NULL GROUP BY club_id, upcoming_party_id'
    )
    for club_id, party_id, count, weight in cur.fetchall():
        by_club.setdefault(club_id, {'previous': [], 'upcoming': []})
        by_club[club_id]['upcoming'].append(
            {'party_id': party_id, 'count': count, 'weight': float(weight or 0)}
        )
```

Leave the `previous` loop immediately above it alone — `rollup_previous` has no `weight` column, and adding one there would be meaningless: a ballot names exactly one previous party, so its count already is its ballot count.

- [ ] **Step 4: Run the whole backend suite**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable .venv/bin/python -m pytest tests/ -q
```

Expected: PASS, 165 tests (164 existing + 1 new).

- [ ] **Step 5: Lint and commit**

```bash
cd services/backend && ruff check .
git add services/backend/queries.py services/backend/tests/test_queries.py
git commit -m "feat(api): expose ballot weight on upcoming result rows"
```

---

### Task 5: Frontend helpers read weight and take a party list

**Files:**
- Modify: `services/frontend/analytics.js:38-48` (`computeEffectiveParties`), `:212-236` (`weightedAxisAverage`, `compositionPercentages`)

**Interfaces:**
- Produces: `rowWeight(r)`; `weightedAxisAverage(breakdown, axis, listName)`; `compositionPercentages(breakdown, field, categories, listName)`; `computeEffectiveParties(breakdown)` weight-based and NULL-excluding

No test framework exists here. This task changes only helper internals and is verified by Task 10's browser run; keep it a separate commit so a reviewer can read the helpers on their own.

- [ ] **Step 1: Add the shared accessor**

Above `computeEffectiveParties`:

```js
// Rows from the upcoming rollups carry `weight` -- one ballot's worth spread across the parties it
// named -- while `count` is raw picks. Averaging on count gives a 3-party ballot triple the say of
// a 1-party one. Falls back to count so a new frontend meeting an old API payload (pods roll one at
// a time) degrades to the previous behaviour instead of rendering an empty card.
function rowWeight(r) {
  return r.weight ?? r.count;
}
```

- [ ] **Step 2: Make the diversity index weight-based and exclude undecided**

```js
// shares: [{party_id, count, weight}, ...] for one club's intended-vote picks.
// Returns 1 / sum(share^2) -- "effective number of parties" (Laakso-Taagepera index).
// Rows with a null party_id are UNDECIDED ballots and are excluded: scoring them would treat
// "undecided" as a party, making a uniformly-undecided fanbase look as varied as a genuinely split
// one. Their share is reported separately by the coverage line.
function computeEffectiveParties(breakdown) {
  const decided = breakdown.filter(r => r.party_id !== null);
  const total = decided.reduce((sum, r) => sum + rowWeight(r), 0);
  if (total === 0) return 0;
  const sumSquaredShares = decided.reduce((sum, r) => {
    const share = rowWeight(r) / total;
    return sum + share * share;
  }, 0);
  return 1 / sumSquaredShares;
}
```

- [ ] **Step 3: Parameterise the two aggregate helpers**

```js
function weightedAxisAverage(breakdown, axis, listName = 'previous_parties') {
  let weightedSum = 0;
  let weightTotal = 0;
  breakdown.forEach(r => {
    const party = partyById(r.party_id, listName);
    if (!party || party[axis] === null || party[axis] === undefined) return;
    const w = rowWeight(r);
    weightedSum += party[axis] * w;
    weightTotal += w;
  });
  return weightTotal > 0 ? weightedSum / weightTotal : null;
}

function compositionPercentages(breakdown, field, categories, listName = 'previous_parties') {
  const totals = {};
  categories.forEach(c => { totals[c] = 0; });
  let total = 0;
  breakdown.forEach(r => {
    const party = partyById(r.party_id, listName);
    if (!party || !party[field] || !(party[field] in totals)) return;
    const w = rowWeight(r);
    totals[party[field]] += w;
    total += w;
  });
  if (total === 0) return null;
  const pct = {};
  categories.forEach(c => { pct[c] = Math.round((totals[c] / total) * 100); });
  return pct;
}
```

An undecided row needs no explicit filter in these two: `partyById(null, …)` returns undefined and the existing guard already skips it.

- [ ] **Step 4: Verify the file still parses**

```bash
node --check services/frontend/analytics.js
```

Expected: no output (exit 0).

- [ ] **Step 5: Commit**

```bash
git add services/frontend/analytics.js
git commit -m "refactor(analytics): weight-based aggregate helpers, party list as a parameter"
```

---

### Task 6: Repoint the lean card and both eligibility gates

**Files:**
- Modify: `services/frontend/analytics.js:304-317` (`allLeanClubRows`), `:355-395` (lean detail rows), `:69-82` (`eligibleClubDiversityScores`)

**Interfaces:**
- Consumes: helpers from Task 5
- Produces: `entry.upcoming`-driven lean card and diversity ranking; `decidedBallots(breakdown)`

- [ ] **Step 1: Add the gate helper**

Next to `rowWeight`:

```js
// Eligibility counts BALLOTS, and only ballots the metric actually uses. Counting `count` here
// would count picks -- four voters naming three parties each would report 12 and clear a gate meant
// for ten people. Undecided ballots are excluded because no displayed figure is computed from them.
function decidedBallots(breakdown) {
  return breakdown
    .filter(r => r.party_id !== null)
    .reduce((sum, r) => sum + rowWeight(r), 0);
}
```

- [ ] **Step 2: Repoint the diversity ranking**

In `eligibleClubDiversityScores`, replace the `.map` body and keep the filters as they are:

```js
      const total = decidedBallots(entry.upcoming);
      return { club, total, score: computeEffectiveParties(entry.upcoming) };
```

- [ ] **Step 3: Repoint the lean strip**

In `allLeanClubRows`, replace the `.map` body:

```js
      const total = decidedBallots(entry.upcoming);
      const values = {};
      LEAN_AXES.forEach(a => {
        values[a.key] = weightedAxisAverage(entry.upcoming, a.key, 'upcoming_parties');
      });
      return { club, total, values, upcoming: entry.upcoming };
```

- [ ] **Step 4: Repoint the five detail rows**

In the detail renderer, change the three axis calls and the two composition calls to pass the upcoming breakdown and list name. The parameter the function receives is renamed `upcomingBreakdown`; update its signature and every reference inside it.

```js
    const value = weightedAxisAverage(upcomingBreakdown, axis.key, 'upcoming_parties');
```
```js
  const blocPct = compositionPercentages(upcomingBreakdown, 'bloc', ['bibi', 'opposition', 'unaligned'], 'upcoming_parties');
```
```js
  const sectorPct = compositionPercentages(upcomingBreakdown, 'sector', sectorCategories, 'upcoming_parties');
```

Rename the parameter in the signature at line 346, from `previousBreakdown` to `upcomingBreakdown`:

```js
function renderLeanDetail(container, label, upcomingBreakdown) {
```

- [ ] **Step 5: Repoint the two `renderLeanDetail` callers**

At lines 477 and 481–482:

```js
      renderLeanDetail(detail, localizedName(row.club), row.upcoming);
```
```js
      const national = await nationalUpcomingBreakdown();
      renderLeanDetail(detail, t('analyticsNational'), national);
```

`nationalUpcomingBreakdown()` already exists at line 422 and is already used by the Traits tab — no new fetch, and it is cached the same way.

- [ ] **Step 6: Move the Traits gate and rewrite its comment**

Spec Decision 7. `traitsEligibleClubs` (line 740) gates on previous ballots under a comment forbidding exactly this change. The comment's reason — that `rollup_upcoming` carries no ballot count — is what `weight` removes, and leaving Traits behind is what would split the shared sample-size definition the comment protects. Replace the comment block above it and the `.map`/`.filter` body:

```js
// Gates on intended-vote BALLOTS, via the weight column (2026-08-10 intended-vote-lean design,
// Decision 7). This deliberately replaces an earlier rule that gated on previous-election ballots
// because rollup_upcoming could only offer a pick count, and an unknown ballot count is not a safe
// basis for publishing a fanbase profile. That count is now known, so the original objection is
// resolved rather than overruled -- and Traits, Lean and Diversity still share one definition of
// sample size, which is only true if all three move together.
// Consequence, now intended: a club with intended-vote ballots but no last-election ballots can
// become eligible here. Its sample size is real.
function traitsEligibleClubs() {
  const nationalLeagueIds = nationalTeamLeagueIds();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      return { club, ballots: decidedBallots(entry.upcoming), upcoming: entry.upcoming };
    })
    .filter(row => row !== null && row.ballots >= LEAN_MIN_VOTES)
    .filter(row => diversityIncludeWorldCup || !nationalLeagueIds.has(row.club.league_id))
    .sort((a, b) => localizedName(a.club).localeCompare(localizedName(b.club)));
}
```

The property is renamed `previousTotal` → `ballots`, because it no longer holds a previous-election total and a name that lies is worse than a rename. It is local to this function — `grep -n previousTotal services/frontend/analytics.js` returns only lines 746, 747 and 749, all inside it — so the rename is complete when those three are changed and that grep comes back empty.

- [ ] **Step 7: Verify it parses, then commit**

```bash
node --check services/frontend/analytics.js
grep -n "previousBreakdown" services/frontend/analytics.js || echo "no stale previousBreakdown references"
git add services/frontend/analytics.js
git commit -m "feat(analytics): lean, diversity and traits read intended vote"
```

---

### Task 7: Undecided coverage line

**Files:**
- Modify: `services/frontend/analytics.js` (detail renderer, after the sector row), `services/frontend/i18n.js`

**Interfaces:**
- Consumes: `decidedBallots` from Task 6
- Produces: one `lean-detail-row` showing the undecided share

- [ ] **Step 1: Add the i18n key to all three languages**

Next to `analyticsBlocLabel` in each of the three objects (lines ~98, ~283, ~468):

```js
    analyticsUndecidedShare: 'Based on {decided} of {total} ballots · {pct}% undecided',
```
```js
    analyticsUndecidedShare: 'מבוסס על {decided} מתוך {total} פתקים · {pct}% מתלבטים',
```
```js
    analyticsUndecidedShare: 'На основе {decided} из {total} бюллетеней · {pct}% не определились',
```

All three carry the same three tokens — `{decided}`, `{total}`, `{pct}`.

- [ ] **Step 2: Render the row**

After the sector row is appended:

```js
  // Undecided ballots are excluded from every figure above, so the share is disclosed rather than
  // hidden -- at 5% it is noise, but before an election it is routinely 20-30%.
  const decided = decidedBallots(upcomingBreakdown);
  const undecided = upcomingBreakdown
    .filter(r => r.party_id === null)
    .reduce((sum, r) => sum + rowWeight(r), 0);
  const totalBallots = decided + undecided;
  if (totalBallots > 0 && undecided > 0) {
    const note = document.createElement('div');
    note.className = 'lean-detail-note';
    note.textContent = t('analyticsUndecidedShare')
      .replace('{decided}', Math.round(decided))
      .replace('{total}', Math.round(totalBallots))
      .replace('{pct}', Math.round((undecided / totalBallots) * 100));
    container.appendChild(note);
  }
```

- [ ] **Step 3: Style it**

In `services/frontend/style.css`, next to the existing `.lean-detail-row` rule:

```css
.lean-detail-note {
  margin-top: 0.5rem;
  font-size: 0.85em;
  opacity: 0.7;
}
```

- [ ] **Step 4: Check key parity across the three languages**

```bash
node -e "
const s=require('fs').readFileSync('services/frontend/i18n.js','utf8');
const n=(s.match(/analyticsUndecidedShare/g)||[]).length;
if(n!==3){console.error('expected 3 occurrences, found '+n);process.exit(1)}
console.log('ok: key present in all three languages');
"
node --check services/frontend/analytics.js
```

Expected: `ok: key present in all three languages`, and no parse error.

- [ ] **Step 5: Commit**

```bash
git add services/frontend/analytics.js services/frontend/i18n.js services/frontend/style.css
git commit -m "feat(analytics): disclose the undecided share on the lean card"
```

---

### Task 8: Say what Diversity now measures

**Files:**
- Modify: `services/frontend/i18n.js` (3 language objects), `services/frontend/analytics.js` (diversity tab renderer, ~line 200)

**Interfaces:**
- Consumes: nothing
- Produces: `analyticsDiversityBasis` i18n key rendered above the diversity ranking

Spec Decision 8. Switching Diversity to intended vote changes what the number *means*, not just its value: ENP assumes one choice per respondent, and over a multi-pick question it can no longer separate "fans disagree with each other" from "each fan is torn between three parties". Both raise it. The tab name stays — it is a good name — but the page must say what is being counted.

- [ ] **Step 1: Add the key to all three languages**

Next to `analyticsMostOneSided` in each object (lines ~90, ~275, ~460):

```js
    analyticsDiversityBasis: 'Based on intended vote. A fan weighing several parties counts as mixed.',
```
```js
    analyticsDiversityBasis: 'מבוסס על כוונת ההצבעה. אוהד ששוקל כמה מפלגות נחשב מגוון.',
```
```js
    analyticsDiversityBasis: 'На основе намерения голосовать. Болельщик, выбирающий несколько партий, считается разнородным.',
```

No `{placeholder}` tokens in this one, so all three are plain strings.

- [ ] **Step 2: Render it**

In `renderDiversityTab`, immediately after the tab element is cleared and before the spotlight/ranking is appended:

```js
  const basis = document.createElement('p');
  basis.className = 'note';
  basis.textContent = t('analyticsDiversityBasis');
  tab.appendChild(basis);
```

`note` is an existing class already used for `#fan-lean-note` in `results.html`, so this needs no CSS.

- [ ] **Step 3: Verify parity and parse**

```bash
node -e "
const s=require('fs').readFileSync('services/frontend/i18n.js','utf8');
for (const k of ['analyticsUndecidedShare','analyticsDiversityBasis']) {
  const n=(s.match(new RegExp(k,'g'))||[]).length;
  if(n!==3){console.error(k+': expected 3, found '+n);process.exit(1)}
}
console.log('ok: both keys present in all three languages');
"
node --check services/frontend/analytics.js
```

Expected: `ok: both keys present in all three languages`, no parse error.

- [ ] **Step 4: Commit**

```bash
git add services/frontend/analytics.js services/frontend/i18n.js
git commit -m "feat(analytics): state that diversity is measured on intended vote"
```

**Wording note for the reviewer:** the English string is a first draft. The repo owner flagged this as the judgment call most worth their eye — a number keeping its position on the live site while changing what it means. Confirm the wording before shipping.

---

### Task 9: End-to-end browser verification against a local stack

**Files:**
- Create: `/tmp/claude-1000/.../scratchpad/verify-lean.mjs` (scratch, not committed)

**Interfaces:**
- Consumes: everything above

- [ ] **Step 1: Write the verification script**

```js
// playwright is installed globally and is CommonJS. A static `import ... from process.env.X` is not
// valid JS (the specifier must be a literal), so resolve it dynamically and unwrap the CJS default.
const pw = await import(process.env.PW);
const { chromium } = pw.default ?? pw;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 1400 } });
const errs = [];
p.on('pageerror', e => errs.push('PAGEERROR: ' + e.message));
p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });

await p.goto(process.env.BASE + '/results', { waitUntil: 'networkidle', timeout: 60000 });
await p.getByRole('button', { name: /Political Lean/i }).click();
await p.waitForTimeout(1500);
console.log('--- LEAN ---');
console.log(await p.locator('#lean-tab').innerText());
await p.getByRole('button', { name: /Diversity/i }).click();
await p.waitForTimeout(1200);
console.log('--- DIVERSITY ---');
console.log(await p.locator('#diversity-tab').innerText());
console.log('--- ERRORS ---', errs.length ? errs.join('\n') : '(none)');
await b.close();
```

- [ ] **Step 2: Run it**

```bash
PW=$(npm root -g)/playwright/index.js BASE=https://voteball.latnook.com node verify-lean.mjs
```

- [ ] **Step 3: Confirm each expectation**

- console errors: `(none)`
- the three axis rows render numbers, not `analyticsReligiosityLabel`-style raw keys
- a coverage line appears reading "…% undecided"
- no row reads `NaN` or `Infinity`
- the Diversity tab still renders a ranking

- [ ] **Step 4: Commit nothing**

This task produces no repo change. If any expectation fails, fix it in the owning task and re-run.

---

### Task 10: Record the outcome and delete this plan

**Files:**
- Modify: `docs/design/2026-08-10-intended-vote-lean-design.md`
- Delete: `docs/superpowers/plans/2026-08-10-intended-vote-lean.md` and the `docs/superpowers/` tree

The repo rule is explicit: an executed plan is deleted in the **same commit** as the last task, because a plan that outlives its execution reads like pending work. `docs/superpowers/` is the superpowers workflow's default output path and regenerates every run — deleting it once is not a permanent fix, so it must be deleted at the end of every plan.

- [ ] **Step 1: Append the Verification outcome to the design doc**

Add a `## Verification outcome` section recording: the measured before/after values on the live card, the final worker/backend test counts, and anything that behaved differently from the spec's prediction. Write what actually happened, including surprises — that section is the reason these docs are worth keeping.

- [ ] **Step 2: Delete the plan**

```bash
git rm -r docs/superpowers/
```

- [ ] **Step 3: Confirm the deploy path**

```bash
git status --short
grep -rn "docs/superpowers" --include=*.md . || echo "no dangling references"
```

- [ ] **Step 4: Commit both together**

```bash
git add docs/design/2026-08-10-intended-vote-lean-design.md
git commit -m "docs(design): record intended-vote lean verification outcome

Deletes the executed implementation plan in the same commit, per the
repo rule -- git history is the archive."
git push origin master
```

- [ ] **Step 5: Watch CI/CD**

Pushing app code to `master` fires `application-ci` → `application-cd`. Confirm a `ci: image tag <sha> [skip ci]` commit lands on master and the pods roll, then re-run Task 9's script against the live site. `seed.sql` is untouched by this plan, so no data migration is involved — but `schema.sql` is, and it applies on backend pod boot.
