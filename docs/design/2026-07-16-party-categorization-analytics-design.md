# Party Categorization, Lineage & Fan Politics Analytics

Status: approved
Date: 2026-07-16

## Context

The Phase 1 quick-wins spec (league logos, Israeli-league-first ordering, Jewish Home removal —
shipped same day) deferred a larger request: the user wants the results page to show *why* raw
previous→upcoming vote counts can be misleading, and to let visitors explore whether footballing
stereotypes ("Beitar fans lean right," "Hapoel Tel Aviv is politically mixed") actually hold in the
data.

Three distinct problems were tangled together in the original ask and had to be pulled apart during
design:

1. **Ideology** (where a party sits: bloc, economic/security position, sector, descriptive tags) is
   a property of *a party*, not of *a voter's history*.
2. **Lineage** (which upcoming party continues which previous party, through identity, splits, or
   merges) is a *continuity* fact, independent of ideology — a split party (Otzma Yehudit off
   Religious Zionist) can be ideologically distinct from its parent while still being the "same
   voters, no real switch" for loyalty-tracking purposes.
3. **Vote-switching** ("did this voter really change their mind") is a *per-voter* classification
   that depends on both previous_party_id and the up-to-3 upcoming picks a ballot allows, resolved
   through the lineage map — not just a raw previous↔upcoming crosstab, which over-counts anyone who
   kept their old party *and* added others.

This spec covers all three, plus the new "Fan Politics" results-page section that surfaces them:
diversity (how politically mixed is a club's fanbase), lean (where does it sit, does it match the
stereotype), and switching (is it more loyal or more volatile than average).

## Decisions

1. **Ideology lives on the party tables, not a shared "party family" table.** `previous_parties` and
   `upcoming_parties` each get their own `bloc`, `economic`, `security`, `sector`, `tags` columns.
   Confirmed necessary because lineage-linked parties can diverge ideologically (Otzma vs. Religious
   Zionist; National Unity vs. Blue and White, per the New Hope merge history) — inheriting ideology
   through `party_lineage` would silently misclassify these.
2. **`economic` and `security` are nullable INTEGER (−3..+3), not defaulted to 0.** Several parties
   (Together, National Unity, Ra'am) genuinely have no stated security position — Together/National
   Unity deliberately avoid the topic to not alienate voters, and Ra'am's focus is Arab-Israeli civil
   affairs rather than the Israeli-Palestinian conflict the axis is really measuring. Writing `0`
   would falsely assert "confirmed centrist"; `NULL` means "no stated position," and the frontend
   renders that distinctly (see Frontend, Lean tab).
3. **No separate "claimed vs. actual" field for economic position.** Likud, Religious Zionist Party,
   and Otzma Yehudit all rhetorically claim economic liberalism without governing or campaigning that
   way. Rather than doubling every economic value into claimed/actual pairs (real schema cost for one
   axis, a handful of parties), the numeric `economic` value reflects the actual/revealed position
   (closer to neutral for these three) and the rhetorical gap is captured as a `claims-economically-
   liberal` tag. Revisit if this pattern recurs on other axes.
4. **`party_lineage(previous_party_id, upcoming_party_id)` is a plain many-to-many link table**, no
   extra columns. A split is multiple rows sharing one `previous_party_id`; a merge is multiple rows
   sharing one `upcoming_party_id`; an unchanged party gets one identity row (Likud→Likud). A party
   with zero lineage rows on either side is a genuine dead end (previous party with no successor,
   e.g. after Jewish Home was folded into "Other") or a fresh entrant (Yashar, The Economic Party, El
   HaDegel, The Reservists, and Blue and White as an independent brand — none have a previous-election
   predecessor as a *seeded row*, even though Blue and White existed inside the National Unity merge
   historically).
5. **Vote-switch status is a 5-way per-vote classification**, computed by the worker:
   - `new_voter` — `previous_vote_status = 'did_not_vote'` (no previous party to compare against).
   - `undecided` — voted previously, but `upcoming_vote_status = 'undecided'`.
   - Otherwise, resolve the successor set for the vote's `previous_party_id` via `party_lineage`:
     - `stayed` — a successor is the voter's *only* upcoming pick.
     - `hedging` — a successor is *one of several* upcoming picks (up to 3 allowed per ballot).
     - `switched` — no successor appears among the picks at all (this is also the outcome for a
       previous party with an empty successor set, e.g. "Other," with no special-casing needed).
   This is strictly more correct than the existing `rollup_previous_upcoming` crosstab for "did they
   change their mind," which over-counts anyone who kept their old party and also added others.
6. **New rollup tables, same shape as existing ones**: `rollup_vote_switch(league_id, club_id,
   switch_status, vote_count)` and `rollup_national_vote_switch(switch_status, vote_count)`,
   recomputed by the worker every cycle alongside the existing rollups, using the same
   touched-leagues-CTE / `vote_clubs` scoping pattern as `rollup_previous`.
7. **Diversity score = effective number of parties** (Laakso-Taagepera index, `1 / Σ(share²)`),
   computed **client-side** from `previous`-election vote shares (see Decision 9 for why previous, not
   upcoming). Chosen over normalized Shannon entropy because it produces a directly-readable number
   ("this club's fans split like 5.8 parties") rather than an abstract 0–1 score requiring a legend —
   confirmed with the user as the more approachable option after walking through both with concrete
   examples.
8. **Political lean = vote-share-weighted average `economic`/`security` position, plus `bloc` and
   `sector` composition percentages**, computed client-side per club/league/national, also from
   `previous`-election data. Nullable axis values are excluded from the weighted average (not treated
   as 0) and the average is only computed over voters whose party *has* a stated position on that
   axis — if every vote in scope maps to a null-security party, the tab shows "no stated position"
   rather than a fabricated number.
9. **Diversity and Political Lean both use previous-election data, not upcoming.** Upcoming votes
   allow up to 3 picks per ballot, which would double-count voters in a naive share calculation
   (previous votes are exactly one party per voter — clean shares, no extra handling needed). This
   also keeps the two tabs internally consistent with each other. The Switching tab is the piece that
   already captures the forward-looking previous→upcoming transition, so no diversity/lean signal is
   lost by scoping the other two tabs to previous-election data alone.
10. **Small-sample clubs are excluded from ranked/leaderboard views**, mirroring the existing
    `get_results_segment` precedent (`total < 5` falls back to national). Diversity/Lean rankings use
    a minimum of 10 total previous-election votes for a club to appear in the Spotlight, Full Ranking,
    or spectrum strip — below that, a single voter can swing "effective parties" wildly and the number
    is more noise than signal. The threshold is a constant in `analytics.js`, easy to retune later.
    Clubs below the threshold are simply omitted from these views (not shown grayed-out — there's no
    reliable club list a first-time visitor would notice something's "missing" from).
11. **New `GET /api/results/clubs-breakdown` endpoint**, returning every club's previous-election
    party-vote breakdown in one response (`[{club_id, previous: [{party_id, count}, ...]}, ...]`,
    reading `rollup_previous WHERE club_id IS NOT NULL GROUP BY club_id, previous_party_id`).
    Discovered as a necessity while finalizing this spec: ranking *all* clubs (Diversity full list,
    Lean spectrum strip) needs every club's breakdown at once — calling the existing
    `GET /api/results?by=club&id=` once per club (30+ requests across 7 leagues) would be slow and
    wasteful. This is the one new read endpoint in this spec; everything else reuses `/api/options`
    (extended) and the new `/api/results/switch`.
12. **`GET /api/results/switch?league_id=&club_id=`** (national if neither given) returns the 5-way
    `{status, count}` breakdown for that scope, reading the new rollup tables — mirrors
    `get_results_segment`'s scope-selection shape (club_id takes precedence over league_id).
13. **World Cup national teams get an explicit include/exclude toggle in the Diversity tab, default
    excluded.** National-team support conflates "which country are you" with "which club do you root
    for" — different kind of fandom than domestic/continental club support — so it's opt-in rather
    than silently mixed into the club leaderboard. Confirmed with the user via the visual companion
    mockup.
14. **UI placement: a new "Fan Politics" section in `results.html`**, between National Standings and
    Explorer, with three internal tabs (Diversity / Political Lean / Switching) using the same
    pill-toggle component as Explorer's existing Club/League↔Party mode switch. Chosen over weaving
    these stats into Explorer (contextual, but hides diversity/lean's standalone national-level
    interest behind first picking a club) or a separate page (conflicts with the user's original
    "displayed nicely in the results section" ask). Confirmed via the visual companion.
15. **Diversity tab**: opens on a Spotlight view (top 5 / bottom 5 clubs by effective-parties score,
    side by side), with a pill-toggle to switch to a Full Ranking (every eligible club, standings-bar
    style, reusing `.standings`/`.standings-fill`), plus the World Cup include/exclude checkbox from
    Decision 13. Confirmed via the visual companion (interactive mockup).
16. **Political Lean tab**: a horizontal spectrum strip plotting every eligible club as a badge on the
    `economic` axis (−3 left … +3 right), click a badge to expand a detail card below showing that
    club's `security` position, `bloc` composition (%), and `sector` composition (%). A club whose
    average `economic` position can't be computed (all votes null on that axis, vanishingly rare given
    it's an average) is simply omitted from the strip. Confirmed via the visual companion.
17. **Switching tab**: a club/league picker (reusing the existing `<select>` pattern from Explorer,
    default National) showing a single stacked bar (Stayed/Hedging/Switched/New voter/Undecided) for
    the selected scope directly above the national-baseline bar for the same 5 categories, plus an
    auto-generated one-line takeaway ("Beitar fans are more loyal to their old party than average"),
    driven by comparing the selected scope's `stayed` share against the national `stayed` share
    (>5 points higher → "more loyal than average," >5 points lower → "more volatile than average,"
    within 5 points → "about as loyal as average" — thresholds are a constant in `analytics.js`).
    Confirmed via the visual companion.
18. **Categorization and lineage remain seed-only**, matching the earlier Phase 1 decision — no admin
    UI. Edits happen via `seed.sql` + the existing `sync-seed-from-rds.sh` reverse-seed workflow. This
    is explicitly acknowledged as provisional: party platforms aren't fully released yet and further
    splits/merges may happen before candidate lists lock, so this data will need revision over time —
    that's a normal seed edit, not a design gap.

## Backend

### Schema changes (`schema.sql`)

```sql
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS bloc TEXT
    CHECK (bloc IN ('bibi', 'opposition', 'unaligned'));
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS economic INTEGER
    CHECK (economic BETWEEN -3 AND 3);
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS security INTEGER
    CHECK (security BETWEEN -3 AND 3);
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS sector TEXT
    CHECK (sector IN ('secular', 'traditional', 'religious_zionist', 'haredi', 'arab'));
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS tags TEXT[];

ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS bloc TEXT
    CHECK (bloc IN ('bibi', 'opposition', 'unaligned'));
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS economic INTEGER
    CHECK (economic BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS security INTEGER
    CHECK (security BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS sector TEXT
    CHECK (sector IN ('secular', 'traditional', 'religious_zionist', 'haredi', 'arab'));
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS tags TEXT[];

CREATE TABLE IF NOT EXISTS party_lineage (
    previous_party_id INTEGER NOT NULL REFERENCES previous_parties(id),
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id),
    PRIMARY KEY (previous_party_id, upcoming_party_id)
);

CREATE TABLE IF NOT EXISTS rollup_vote_switch (
    league_id INTEGER,
    club_id INTEGER,
    switch_status TEXT NOT NULL CHECK (switch_status IN
        ('new_voter', 'undecided', 'stayed', 'hedging', 'switched')),
    vote_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rollup_national_vote_switch (
    switch_status TEXT NOT NULL CHECK (switch_status IN
        ('new_voter', 'undecided', 'stayed', 'hedging', 'switched')),
    vote_count INTEGER NOT NULL
);
```

### `queries.py` changes

- `get_options` extends its `previous_parties`/`upcoming_parties` SELECTs to include `bloc, economic,
  security, sector, tags`, and gains a new `get_party_lineage(conn) -> [{previous_party_id,
  upcoming_party_id}, ...]` (`SELECT previous_party_id, upcoming_party_id FROM party_lineage`),
  included in `get_options`'s return dict as `party_lineage`.
- `get_results_switch(conn, league_id=None, club_id=None) -> {status: count, ...}` — same
  scope-selection shape as `get_results_segment` (club_id precedence, league_id fallback, else
  national), reading `rollup_vote_switch`/`rollup_national_vote_switch`.
- `get_clubs_breakdown(conn) -> [{club_id, previous: [{party_id, count}, ...]}, ...]` — one query
  (`SELECT club_id, previous_party_id, SUM(vote_count) FROM rollup_previous WHERE club_id IS NOT NULL
  GROUP BY club_id, previous_party_id`), reshaped in Python into one entry per `club_id`.

### `app.py` changes

- `GET /api/options` — no route signature change, extended payload per above.
- `GET /api/results/switch` — query params `league_id`, `club_id` (both optional ints), delegates to
  `get_results_switch`.
- `GET /api/results/clubs-breakdown` — no params, delegates to `get_clubs_breakdown`.

### Worker (`rollups.py`) changes

New `_recompute_vote_switch(conn)`, called from `recompute()` alongside the existing four recomputes,
before the final `conn.commit()`. Classification CTE:

```sql
WITH vote_pick_stats AS (
    SELECT v.id AS vote_id, v.previous_vote_status, v.upcoming_vote_status,
           COUNT(vup.upcoming_party_id) AS total_picks,
           COUNT(vup.upcoming_party_id) FILTER (WHERE pl.upcoming_party_id IS NOT NULL) AS successor_picks
    FROM votes v
    LEFT JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
    LEFT JOIN party_lineage pl
        ON pl.previous_party_id = v.previous_party_id AND pl.upcoming_party_id = vup.upcoming_party_id
    GROUP BY v.id, v.previous_vote_status, v.upcoming_vote_status
),
vote_switch AS (
    SELECT vote_id,
        CASE
            WHEN previous_vote_status = 'did_not_vote' THEN 'new_voter'
            WHEN upcoming_vote_status = 'undecided' THEN 'undecided'
            WHEN successor_picks = 0 THEN 'switched'
            WHEN successor_picks >= 1 AND total_picks = 1 THEN 'stayed'
            ELSE 'hedging'
        END AS switch_status
    FROM vote_pick_stats
)
```

Then, matching `rollup_previous`'s existing scoping pattern:

- League-scope rows: join `vote_switch` to the shared touched-leagues CTE (`vote_clubs UNION
  vote_leagues`, deduped) → `GROUP BY league_id, switch_status`, `club_id = NULL`.
- Club-scope rows: join `vote_switch` to `vote_clubs` directly → `GROUP BY league_id, club_id,
  switch_status`.
- National: join `vote_switch` to `votes` alone → `GROUP BY switch_status`, into
  `rollup_national_vote_switch`.

All three are `TRUNCATE` + re-`INSERT`, same as every other rollup.

## Frontend

### New files / modified files

- `analytics.js` (new) — fetches `/api/options` (already cached if another script loaded it first),
  `/api/results/clubs-breakdown`, and (lazily, per scope selection) `/api/results/switch`. Computes
  effective-parties scores and lean aggregates client-side. **Must be added to the nginx `Dockerfile`
  COPY line** and given a `<script>` tag in `results.html`, per this repo's established gotcha
  (i18n.js shipped once without this, 404'd silently).
- `results.html` — new `<section id="fan-politics-section">` inserted between `#overall-section` and
  `#explorer-section`, containing a `.pill-group`-based tab switcher (Diversity / Political Lean /
  Switching) and three tab panels, structurally mirroring the existing `#mode-toggle` pattern.
- `i18n.js` — new keys for: tab labels, bloc names (`bibi`/`opposition`/`unaligned`), sector names,
  axis labels (economic/security), "no stated position," the Diversity spotlight headings, the World
  Cup toggle label, and the Switching takeaway sentence templates (`{who} are more loyal than
  average`, etc., using the existing `{placeholder}` replace-at-call-site convention).
- `style.css` — new classes for the spectrum strip (`.lean-strip`, `.lean-badge`), the switching
  stacked bar (`.switch-bar`, `.switch-segment`), and a small categorical color palette for the 5
  switch-statuses and 3 blocs (extending the existing `--accent`/`#FFD23F` pair, which isn't enough
  for 5 simultaneous categories).

### Diversity tab

- Fetches `/api/results/clubs-breakdown`, filters to clubs with ≥10 total previous-election votes
  (Decision 10), and, unless the World Cup checkbox is checked, filters out clubs whose `league_id`
  resolves to the "World Cup 2026" league (matched by `id`, not name-string, using `/api/options`'
  leagues list — the same "match by stable identifier" lesson already applied elsewhere in this repo
  after the UCL/EPL `name_en` rename history).
- For each remaining club: `effective_parties = 1 / Σ(share²)` over that club's previous-party vote
  shares.
- Spotlight view: top 5 and bottom 5 by score, rendered side by side (reusing `.card`/`.card-grid`).
- Full Ranking view: every eligible club, one `.standings-row` each, bar width scaled to the highest
  score in the current filter set (so the World Cup toggle re-scales the bars, not just the row list).
- Pill-toggle between the two views; World Cup checkbox re-filters and re-renders whichever view is
  active without a re-fetch (data for all clubs is already in memory).

### Political Lean tab

- Same ≥10-vote and World Cup filters as Diversity, reusing the same in-memory breakdown.
- For each eligible club: weighted `economic` average (excluding null-axis parties from both numerator
  and denominator), rendered as a badge positioned along a `−3..+3` strip (`left: ((economic+3)/6)*100%`).
- Clicking a badge expands a detail card below the strip: weighted `security` average (or "no stated
  position" if every party in scope has null `security`), `bloc` composition as a small 3-segment bar,
  `sector` composition as a small 5-segment bar.
- A "National" pseudo-badge/default view is shown before any club is clicked, using the same
  aggregation over all previous-election votes.

### Switching tab

- Club/league `<select>` picker, default "— National —" (no scope params → `/api/results/switch`
  called with neither `league_id` nor `club_id`).
- On scope change, fetches `/api/results/switch` for that scope and (if not already cached this page
  load) the national baseline, renders two `.switch-bar`s (selected scope, then national, dimmed) with
  the 5 segments in a fixed order/color (Stayed, Hedging, Switched, New voter, Undecided).
- Takeaway sentence compares the two `stayed` shares per the ±5-point thresholds in Decision 17.

## Data flow summary

```
results.html load ─> GET /api/options (leagues, clubs, parties+ideology, party_lineage)
                  ─> GET /api/results/clubs-breakdown (once, cached for Diversity + Lean tabs)

Diversity tab ─> filter (≥10 votes, World Cup toggle) ─> compute effective_parties per club
              ─> Spotlight (top/bottom 5) ⇄ Full Ranking (pill-toggle, no re-fetch)

Political Lean tab ─> filter (≥10 votes, World Cup toggle) ─> compute weighted economic average
                   ─> render spectrum strip ─> click badge ─> expand detail card
                        (security average, bloc %, sector %, from same in-memory breakdown)

Switching tab ─> pick scope (National default) ─> GET /api/results/switch[?league_id=|club_id=]
              ─> GET /api/results/switch (national, cached) ─> render scope bar + baseline bar
              ─> compute takeaway sentence from stayed-share delta

Worker (every cycle) ─> _recompute_vote_switch ─> TRUNCATE + rebuild
                          rollup_vote_switch / rollup_national_vote_switch
```

## Error handling

- Nullable `economic`/`security`: any weighted-average computation that ends up with zero eligible
  (non-null) votes in scope renders "no stated position" text instead of a number or a `NaN` — checked
  before division, not caught after.
- `/api/results/switch` and `/api/results/clubs-breakdown` follow the existing route shape
  (`try/finally: conn.close()`); no new error cases beyond standard 400 for a malformed `league_id`/
  `club_id` query param (`request.args.get(..., type=int)` already returns `None` on parse failure,
  matching every other scoped route in this codebase).
- Small-sample club exclusion (Decision 10) is a pure client-side filter, not a 4xx — there's nothing
  wrong with the request, the club is just omitted from ranked views (still fully visible through the
  existing Explorer).

## Testing

Backend (real-Postgres TDD, matching this repo's existing pattern):

- Worker: new tests in `tests/test_rollups.py` for `_recompute_vote_switch` — one case per
  `switch_status` outcome (stayed via identity lineage, stayed via a merge like Labor→Democrats,
  hedging with 2-3 picks including a successor, switched with no successor among picks, switched from
  a party with no lineage row at all, new_voter, undecided), plus league/club/national scoping
  parity with the existing `rollup_previous` scoping tests.
- `queries.py`: `test_get_options_exposes_party_ideology_and_lineage`, `test_get_results_switch_scopes`
  (club precedence over league, national fallback), `test_get_clubs_breakdown_shape`.
- `app.py`: route-level tests for `GET /api/results/switch` (all three scope modes) and
  `GET /api/results/clubs-breakdown` (200, correct shape), matching the existing route-test style.
- `test_migration.py`-style seed assertions: every previous/upcoming party row **except the catch-all
  "Other"** has non-null `bloc` and `sector` (`economic`/`security` allowed null more broadly, per
  Decision 2 — "Other" itself is null on all four, since it has no ideology by definition); every
  `party_lineage` row references existing ids on both sides; no orphaned lineage row after the Jewish
  Home removal.

Frontend (manual, no build step, per this repo's established precedent):

- Diversity tab: Spotlight/Full Ranking toggle both render; World Cup checkbox changes which clubs
  appear and re-scales the Full Ranking bars; a club with <10 previous votes is absent from both
  views.
- Political Lean tab: spectrum strip renders all eligible clubs at plausible left-right positions;
  clicking a badge expands the correct club's detail card; a club whose scope has null `security`
  shows "no stated position," not a fabricated value.
- Switching tab: scope picker changes both bars; takeaway sentence direction (more/less/about-as-loyal)
  matches the actual stayed-share delta at the ±5-point boundary.
- i18n: every new label has both `en`/`he` entries and switches correctly on language toggle
  (`voteball:langchange`), matching every existing i18n test-by-hand pattern in this repo.

## Non-goals

- No admin UI for editing ideology/lineage (Decision 18) — seed-only, matching the Phase 1 precedent.
- No "claimed vs. actual" structured economic field (Decision 3) — captured as a tag.
- No per-previous-party slicing of switch-status (e.g., "of Likud voters specifically, X% stayed") —
  only league/club/national scoping, matching every existing rollup's dimensionality. A future
  extension, not built here.
- No cross-axis correlation analysis (e.g., "do hawkish clubs skew more religious") beyond the four
  defined metrics (diversity, economic lean, security lean, bloc/sector composition).
- No previous-vs-upcoming toggle on the Diversity/Lean tabs (Decision 9) — previous-election data only,
  for the reasons given there.

## Appendix: party classification data

Bloc / Economic (−3 left … +3 right, nullable) / Security (−3 dovish … +3 hawkish, nullable) / Sector.
**Bold** = the user's explicit words; plain = inferred and confirmed during design review.

| Party | Table(s) | Bloc | Economic | Security | Sector | Tags |
|---|---|---|---|---|---|---|
| Likud | previous, upcoming | **bibi** | +1 | **+2** | traditional | claims-economically-liberal, populist, nationalist |
| Yesh Atid | previous only | **opposition** | 0 | 0 | secular | liberal-zionist, centrist |
| Together | upcoming only | **opposition** | **+1** | NULL | secular | liberal-zionist, **constitutionalist**, avoids-security-topic |
| Religious Zionist Party | previous, upcoming | **bibi** | 0 | **+3** | **religious_zionist** | claims-economically-liberal, not-economy-focused, **ultranationalist, far-right** |
| Otzma Yehudit | upcoming only | **bibi** | 0 | **+3** | religious_zionist | claims-economically-liberal, not-economy-focused, **kahanist, jewish-supremacist**, far-right |
| National Unity | previous only | **unaligned** | +1 | NULL | secular | centrist, avoids-security-topic, leans-traditional |
| Blue and White | upcoming only | **unaligned** | 0 | 0 | secular | **centrist**, hard-to-classify-bloc |
| Yisrael Beiteinu | previous, upcoming | **opposition** | **+2** | +2 | **secular** | **anti-clerical, revisionist-zionist** |
| Shas | previous, upcoming | **bibi** | **−2** | +1 | **haredi** | **ultra-orthodox**, religious-conservative |
| United Torah Judaism | previous, upcoming | **bibi** | **−2** | +1 | **haredi** | **ultra-orthodox**, religious-conservative |
| Ra'am | previous, upcoming | **opposition** | 0 | NULL | **arab** | **islamist, conservative**, focuses-on-arab-israeli-civil-issues |
| Hadash-Ta'al | previous, upcoming | **opposition** | **−3** | **−2** | **arab** | **communist, arab-nationalist, pro-two-state** |
| Labor | previous only | **opposition** | **−2** | −1 | secular | **social-democrat** |
| Meretz | previous only | **opposition** | −2 | −1 | secular | social-democrat |
| Balad | previous, upcoming | **opposition** | −2 | **−3** | **arab** | **palestinian-nationalist, non-zionist** |
| The Democrats | upcoming only | opposition | **−2** | −1 | secular | **progressive, social-democrat, liberal-zionist** |
| Yashar | upcoming only | **opposition** | 0 | 0 | secular | **new-party, undefined-ideology** |
| The Economic Party | upcoming only | **unaligned** | **+1** | 0 | **secular** | **populist, anti-corruption, anti-clerical** |
| El HaDegel | upcoming only | **unaligned** | +1 | 0 | secular | **reservist-focused, anti-conscription-exemption** |
| The Reservists | upcoming only | **unaligned** | +1 | 0 | secular | reservist-focused, anti-conscription-exemption |
| Other | previous only | NULL | NULL | NULL | NULL | catch-all, no ideology |

### Lineage (`party_lineage`, previous → upcoming)

Likud→Likud, Yesh Atid→Together, Religious Zionist→Religious Zionist, Religious Zionist→Otzma
Yehudit, National Unity→Blue and White, Yisrael Beiteinu→Yisrael Beiteinu, Shas→Shas, United Torah
Judaism→United Torah Judaism, Ra'am→Ra'am, Hadash-Ta'al→Hadash-Ta'al, Labor→The Democrats,
Meretz→The Democrats, Balad→Balad.

No lineage row for: Yashar, The Economic Party, El HaDegel, The Reservists (genuine first-time
entrants — no seeded predecessor). "Other" has no successor (previous-only, catch-all).
