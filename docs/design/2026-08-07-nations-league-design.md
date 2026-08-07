# UEFA Nations League — design (2026-08-07)

Adds the UEFA Nations League as a ninth league, displayed after the World Cup, with its four
divisions (A–D) rendered as headers inside a single tab. Extends
`docs/design/2026-07-15-clubs-leagues-admin-crud-design.md` (decisions 10 and 12, which introduced
`clubs.domestic_league_id` and the dual-league club) rather than replacing it.

Fifty-four national teams. Sixteen of them are already in this database as World Cup 2026 rows and
are **linked**, not re-inserted. Thirty-eight are new.

## Decision 1 — one league row, with a `group_label` column, not four league rows

The A–D divisions are `clubs.group_label TEXT` (nullable, values `'A'`/`'B'`/`'C'`/`'D'`). The
Nations League itself is one row in `leagues` with `sort_order = 8`.

Four league rows would have produced four tabs, and the requirement is one tab with headings inside
it. Suppressing three of four tabs would mean inventing a "sub-league" concept — a parent/child
relationship in `leagues`, a rule for which children are tabbable, and a matching rule everywhere a
league is listed (voting tabs, results dropdown, analytics, admin). A nullable text column on
`clubs` is the whole feature instead.

The cost is that `group_label` is a general-purpose column used by exactly one league. If a second
league ever wants divisions, it works; if a club is ever in two leagues that *both* want divisions,
one column cannot express both labels. No such club exists and none is foreseeable — every
divisioned competition here is a national-team tournament, and a nation plays in one division.

**`group_label` alone turned out not to be enough — a second column, `leagues.has_divisions
BOOLEAN`, was added to say *whether this league renders division headers at all*, separately from
`group_label` saying *which* division a club is in.** The gap: 16 of the 54 Nations League nations
are also World Cup 2026 teams and carry `domestic_league_id` linking them to the Nations League (see
decision 2), so they carry a `group_label` there too. Sixteen labelled clubs is enough for `vote.js`
to conclude "this league has divisions" if that conclusion is inferred from the clubs present — so
the World Cup tab, which has no divisions of its own, rendered "League A"/"League B" headers over
those 16 shared nations while its other 32 teams sat above them with no header at all. Inferring
"divided" from "some club here has a label" cannot tell "this league is divided" apart from "this
league happens to contain a club that's divided somewhere else" — those are different facts once a
club can belong to two leagues, and only one of them is true for the World Cup. `has_divisions` makes
the first fact explicit on the league itself instead of trying to derive it from club data that a
dual-league club can carry into a league it doesn't describe. `vote.js`'s `groupedClubsForLeague()`
and `results.js`'s club dropdown both gate the header/`<optgroup>` rendering on `league.has_divisions`
now, never on the presence of `group_label` values among that league's clubs.

## Decision 2 — shared teams are linked, never re-inserted

`clubs_name_en_uidx` is a **global** unique index (in `schema.sql`, moved there from per-league by
decision 7 of the CRUD design). There cannot be a second row named `France`. The sixteen teams in
both competitions therefore keep their existing World Cup row, their existing crest and their
existing Hebrew/Russian names, and gain `domestic_league_id = <Nations League>`:

> France, Belgium, Turkey, Germany, Netherlands, Spain, Croatia, England, Czech Republic, Portugal,
> Norway (League A); Scotland, Switzerland, Austria, Bosnia and Herzegovina, Sweden (League B).

`clubsForLeague()` in `vote.js` and the club dropdown in `results.js` already match on
`league_id === leagueId || domestic_league_id === leagueId`, so both tabs show the team with no
frontend change. `toggleClub()`/`linkedLeagueId()` already mirror a selection into both tabs, which
is the "picked in one, picked in the other" behaviour, also with no change.

**Do not add these sixteen to the `clubs` logo `VALUES` block.** That block is keyed on `name_en`
and a duplicate key makes Postgres match arbitrarily rather than resolving by file order — see the
rule in `services/backend/CLAUDE.md`. They already have crests.

## Decision 3 — league membership for rollups derives from the clubs table, not from the tab

This is the substantive change, and it fixes a pre-existing inconsistency rather than only serving
the Nations League.

`vote_clubs.league_id` records which tab a club was picked under, and `dedupedTeamPicks()` in
`vote.js` collapses a dual-league club to a single pick filed under one league. Which league that is
follows `domestic_league_id`, and that column's direction is not consistent across the seeded data:

| Pick | Filed under | Counted in | Missing from |
|---|---|---|---|
| Real Madrid (`league_id` UCL, `domestic` La Liga) | La Liga | La Liga | Champions League |
| Real Betis (`league_id` La Liga, `domestic` UCL) | Champions League | Champions League | La Liga |

Both are La Liga clubs that also play in the Champions League; they land on opposite sides purely
because of which column each was seeded into. The visible consequence is that the Champions League
view is built almost entirely from the clubs with no domestic league in this app (PSG, Porto,
Galatasaray, Club Brugge, Feyenoord, PSV, Lens, Lille, Shakhtar, Slavia, Sporting), while Real
Madrid, Barcelona, Bayern, Liverpool and Arsenal fans contribute nothing to it.

Every league-scope number in the app flows through **one** SQL fragment,
`_VOTE_LEAGUES_TOUCHED_CTE` (in `services/worker/rollups.py`), shared by `rollup_previous`,
`rollup_upcoming`, `rollup_previous_upcoming` and `rollup_vote_switch`. Answering "which leagues did
this vote touch?" from the club's real memberships instead of from the filing tab is one edit:

```sql
SELECT vc.vote_id, c.league_id          FROM vote_clubs vc JOIN clubs c ON c.id = vc.club_id
UNION
SELECT vc.vote_id, c.domestic_league_id FROM vote_clubs vc JOIN clubs c ON c.id = vc.club_id
  WHERE c.domestic_league_id IS NOT NULL
UNION
SELECT vote_id, league_id FROM vote_leagues
```

`UNION` deduplicates, so a voter who picks three La Liga clubs still produces one La Liga row.

Properties worth stating explicitly, because each was a live risk in a rejected alternative:

- **No double counting.** Club-scope rows (`club_id` set) are untouched — still one per
  `vote_clubs` row, so `?by=club` still reports one voter as one. This is what ruled out the obvious
  approach of submitting the pick twice: `get_results_by_club` filters on `club_id` with **no league
  predicate** (`queries.py:_results_for_filter`), so two club-scope rows would `SUM()` to double.
- **National totals do not move.** They read `rollup_national_*`, which have no league dimension.
- **Retroactive.** `recompute()` `TRUNCATE`s and rebuilds from the raw ballots, so votes already
  cast are re-counted under both leagues. The Champions League figure will jump on the first
  recompute after deploy. This is a correction, not a regression, but it is visible.
- **No rollup-schema, API or ballot-format change.** The rollup tables, `/api/vote` and `vote_clubs`
  are all unchanged, so no migration and no client/server validation drift. (Decision 1's
  `clubs.group_label` is the only schema addition in this pass, and nothing in the rollup path
  reads it.)

One asymmetry is knowingly left in place: `count_votes_for_league()` in `queries.py` (the admin
delete guard) still counts from `vote_clubs`/`vote_leagues` directly, so it can report fewer votes
than the league's rollup now reflects. It is not a data-safety hole — `count_clubs_for_league()`
already matches on both columns, so a league cannot be deleted while any club still links to it.

## Decision 4 — WITHDRAWN: a pick does not record the tab it was clicked from

*Originally: track the originating league of each pick so the review screen labels a dual-league
club by the tab it was chosen under. **Withdrawn at the repo owner's request on 2026-08-07, before
implementation** — "it doesn't matter which tab a pick came from."*

`dedupedTeamPicks()` therefore keeps its existing behaviour: a dual-league pick is filed under
`domestic_league_id` regardless of where the user clicked, so picking France on the World Cup tab
reads "Nations League — France" on the review screen.

Decision 3 is what makes this harmless. Both of a club's leagues are counted at league scope no
matter which tab filed the pick, so tab origin decides no total — it only ever decided a label. The
one residual effect is the league dimension of `get_results_by_party`'s club-scope breakdown, which
attributes a dual-league club to `domestic_league_id` alone; nothing in the results UI reads that
dimension for clubs today.

## Decision 5 — `group_label` is seed-only, not admin-editable

The admin club endpoints replace every field they receive, so any PATCH that forwards a subset
writes `NULL` into the rest — the trap `patchClubLeagues()` in `admin.js` already has to work around
by resending all four name/logo fields. Adding `group_label` to `create_club`/`rename_club` adds a
fifth field to that list and a fifth way to silently blank data.

Leaving it out of both statements means no admin path can ever null it, at the cost of not being
able to assign a division from the UI. Roster changes in this repo are seed edits already (see the
Liga Leumit relegation block in `seed.sql`), so this matches existing practice. A club created
through the admin UI inside the Nations League renders ungrouped, above the first header — visible,
not silent.

## Decision 6 — headers rendered client-side, alphabetical within each division

`renderTeamGrid()` groups the league's clubs by `group_label`, emits a header per division in
`A → B → C → D` order, and sorts within each division with the existing `sortByLocalizedName()`, so
ordering follows the display language. A league with no labelled clubs renders exactly as today;
clubs with a `NULL` label in a labelled league render first, headerless.

Header text is one i18n key taking the label as a placeholder — `"League {label}"` / `"ליגה {label}"`
/ `"Лига {label}"` — not four keys per language. `results.js`'s club dropdown gets matching
`<optgroup>` labels so a 54-entry list stays navigable.

## Decision 7 — the league emblem is a cropped, self-hosted copy

The source SVG (`UEFA_Nations_League.svg`, 260×381) contains **no `<text>` elements** — the
"UEFA NATIONS LEAGUE" wordmark is outlined paths. Removing the text is therefore a `viewBox` crop to
the emblem, not a node deletion, and no path data is edited.

Self-hosted at `services/frontend/logos/uefa-nations-league.svg` because the crop has to live
somewhere and hotlinking a file this repo has modified is not possible. `logos/` is copied into the
image as a whole directory, so this needs no `Dockerfile` change (unlike every other frontend file).

## Roster

Fifty-four teams: 16 in each of A, B and C, and 6 in D. Teams marked **†** already exist as World
Cup 2026 rows and are linked, not inserted — 16 of them, leaving 38 new rows.

- **A** — Belgium†, Croatia†, Czech Republic†, Denmark, England†, France†, Germany†, Greece, Italy,
  Netherlands†, Norway†, Portugal†, Serbia, Spain†, Turkey†, Wales
- **B** — Austria†, Bosnia and Herzegovina†, Georgia, Hungary, Israel, Kosovo, North Macedonia,
  Northern Ireland, Poland, Republic of Ireland, Romania, Scotland†, Slovenia, Sweden†,
  Switzerland†, Ukraine
- **C** — Albania, Armenia, Belarus, Bulgaria, Cyprus, Estonia, Faroe Islands, Finland, Iceland,
  Kazakhstan, Latvia, Luxembourg, Moldova, Montenegro, San Marino, Slovakia
- **D** — Andorra, Azerbaijan, Gibraltar, Liechtenstein, Lithuania, Malta

Spelled **Liechtenstein** (the source list read "Lichtenstein").

Each of the 38 new rows needs `name_en`, `name_he`, `name_ru` and `logo_url`. `name_ru` must be
genuine Cyrillic — `test_seeded_russian_names_are_cyrillic` in `test_migration.py` asserts it, and a
Latin-keyboard homoglyph (`PAAM` for `РААМ`) passes visual review while breaking Russian search and
collation.

## Files this touches

| File | Change |
|---|---|
| `services/backend/schema.sql` | `clubs.group_label TEXT` via `ADD COLUMN IF NOT EXISTS` |
| `services/backend/seed.sql` | league row, 38 clubs, names ×3, logos, group labels, 16 `domestic_league_id` links, `sort_order = 8`, league emblem |
| `services/backend/queries.py` | `get_options()` selects and returns `group_label` |
| `services/worker/rollups.py` | `_VOTE_LEAGUES_TOUCHED_CTE` (decision 3) |
| `services/frontend/vote.js` | division headers (decision 6). Origin-league tracking was withdrawn — see decision 4 |
| `services/frontend/results.js` | `<optgroup>` division labels in the club dropdown |
| `services/frontend/analytics.js` | `nationalTeamLeagueIds()` widens from a single hardcoded `'World Cup 2026'` match to the `NATIONAL_TEAM_LEAGUES` set (`{'World Cup 2026', 'Nations League'}`) |
| `services/frontend/i18n.js` | one header key in all three languages |
| `services/frontend/logos/` | cropped `uefa-nations-league.svg` |
| `services/frontend/logos.js` | `OUTLINE_CLUBS` review for dark crests among the 38 |
| `services/frontend/style.css` | `.team-group-header`, and a 4-column grid rule for divisioned leagues |

Before this change, `analytics.js` matched only `name_en === 'World Cup 2026'` to keep national
teams out of the club-diversity ranking (the ranking compares clubs to each other, and a national
side is not a club). Thirty-eight more countries would have swamped that ranking unfiltered — a
silent quality regression, not an error — which is why the match widened to a set rather than
staying a single string comparison.

## Verification

- **Backend/worker suites against real Postgres**, per `services/*/CLAUDE.md`. New coverage:
  a dual-league club produces a league-scope row for *both* leagues and exactly *one* club-scope
  row; national totals are unchanged by the CTE edit; `group_label` survives an admin club rename.
- **Seed re-run on an already-seeded database.** Every guarded statement in `seed.sql` reaches a
  fresh database only, so the link `UPDATE`s and the new `INSERT` must be verified against a
  database seeded with the *previous* file — a fresh one proves nothing.
- **Rollup delta measured, not assumed.** Record each league's totals before and after the first
  recompute. The Champions League and the five domestic leagues should each rise; national totals
  and every per-club figure must be byte-identical.
- **Browser check** of the four headers, alphabetical order in all three languages (Hebrew RTL
  included), the cropped emblem, and dark-mode legibility of the new crests.

## Out of scope

Division headers on the results page beyond the dropdown `<optgroup>`s; admin editing of
`group_label` (decision 5); any change to the 3-picks-per-league cap, which continues to charge a
dual-league club against both leagues' caps.

## Verification outcome

This feature deployed continuously as it was built — each task's commit went straight to `master`
and Jenkins' `application-cd` promoted and synced it within minutes, per the standing repo practice
of committing and pushing as work is made. That means the live site ran a visibly half-finished
feature for a stretch: Task 3 (`38f7b98`, the Nations League league row plus the cropped emblem, no
teams under it yet) deployed at `2026-08-06 22:01:33 UTC` (`ci: image tag 38f7b98`), and Task 4
(`093a283`, the 38 new national teams) did not deploy until `2026-08-07 05:21:52 UTC` — a **7h20m
gap** during which the voting form showed a "Nations League" tab with the cropped UEFA emblem and
zero clubs under it. Not a data-safety issue (an empty-club league renders as an empty tab, same as
any league with no clubs yet), but a real, visible symptom of shipping each task independently
instead of behind a flag.

Two real defects surfaced along the way, both caught before or immediately after they shipped:

**Defect 1 — the Task 5 linking statement's planned placement matched zero rows on a fresh database
while silently working on an already-seeded one.** The implementation plan said to place the
16-nation `domestic_league_id` link (`UPDATE clubs SET domestic_league_id = ... WHERE ... AND
name_en IN (...)`) directly after the last of the existing UCL `domestic_league_id` blocks — i.e.,
*before* `seed.sql`'s `UPDATE clubs SET name_en = name WHERE name_en IS NULL` backfill. Verified
directly (not just recalled from the task report) by reconstructing that exact placement and running
it both ways:

| Scenario | Shared-nation links matched |
|---|---|
| Fresh DB (`schema.sql` + wrong-placement `seed.sql`, first boot) | **0** |
| Already-seeded DB (pre-Task-5 `seed.sql` applied first, wrong-placement `seed.sql` applied on top) | **16** |

The asymmetry is exactly what makes this class of bug dangerous: a production database is always
already-seeded (RDS restores from a snapshot, and `init_db` only ever adds to what's there), so this
placement would have shipped, passed every manual smoke check against the live site, and quietly
broken only the *next* fresh-database boot — a `terraform destroy`/rebuild, or a fork's first deploy
— shipping a 38-team-only Nations League with the 16 shared nations silently missing from it, with
no error anywhere. `name_en` is why: a freshly-inserted club carries only the legacy `name` column
until the backfill runs, so a `name_en`-keyed match placed before that backfill finds nothing on a
database seeded in one pass, but finds everything on a database where `name_en` was already
populated by a previous boot's backfill (a `WHERE name_en IS NULL` guard makes the backfill a no-op
on every later run, but the values it already wrote stay). TDD caught it immediately instead: the
three tests written for Task 5 (`test_shared_nations_are_linked_not_duplicated`,
`test_nations_league_has_54_votable_teams`, `test_nations_league_divisions_are_fully_populated`) run
against a fresh per-test database (`conftest.py`'s `conn` fixture calls `init_db` fresh every time),
so they failed at RED with the exact fresh-DB numbers:

| | A | B | C | D |
|---|---|---|---|---|
| Before the fix (link statement in the planned position) | 5 | 11 | 16 | 6 |
| After moving the statement past the `name_en` backfill | 16 | 16 | 16 | 6 |

The statement now sits at `seed.sql:234`, after the backfill, with an in-file comment recording why.
Re-verified against a genuinely already-seeded database too (old `seed.sql` applied first, new
`seed.sql` applied on top without dropping the database), confirming the corrected placement reaches
both database shapes, then a third application confirmed it is idempotent (54/54/16/16/16/6 held
steady). (The full `psql` transcript of that run lived in the implementation plan for this feature,
which — per this repo's standing rule — was deleted the moment the plan finished executing; the
table above is the durable record of the numbers that mattered.)

**Defect 2 — a fixture named after something the feature itself later seeded.** `services/backend`'s
test fixtures run against a *fully seeded* database (`conftest.py`'s `conn` fixture calls
`db.init_db`, which loads `schema.sql` **and** `seed.sql`), and `clubs.name_en`/`leagues.name_en`
both carry a global unique index. Two throwaway fixtures collided with real rows this feature added:
a fixture league literally called `'Nations League'` (written before Task 3 seeded the real one) and
a fixture club called `'Italy'` (written before Task 4 seeded the real one) — each test passed for as
long as the name stayed unseeded and started failing the moment a later commit in the *same feature*
seeded the real row out from under it. Both were renamed to obviously-fake names (`'Placeholder
League'`, `'Ruritania'`); see `services/backend/CLAUDE.md`, which now carries a paragraph warning
future fixture authors about this.

**Decision 3's dual-league counting fix (the `_VOTE_LEAGUES_TOUCHED_CTE` change) worked as designed**,
confirmed at the unit level by `services/worker/tests/test_rollups.py`'s `_seed_dual_league_vote`
fixture (a club shaped like Real Madrid: `league_id`=UCL, `domestic_league_id`=La Liga, picked under
La Liga only) — before the fix, the league-scope query returned one row; after, it returns one row
per league, as decision 3 predicted. The rollup tables are always rebuilt wholesale on the next
recompute (`TRUNCATE` then re-`INSERT`) and keep no history, so there is no literal "before" snapshot
of the live production numbers from the moment this shipped to compare against — the unit-level
before/after above is the durable record of the behavioral change instead.

**Dark-mode crest review (Task 9) added nothing to `OUTLINE_CLUBS`.** All 38 new crests were measured
mechanically (fraction of non-transparent pixels near-invisible against `#161B22`) and the ~10 that
scored meaningfully above the known-good negative controls were additionally confirmed by rendering
each one composited onto the actual card colour: every one of them (Albania, Armenia, Liechtenstein,
Malta, Finland, Luxembourg, Romania, Latvia, Faroe Islands, Azerbaijan) reads clearly on the dark
card — their raw pixel-luminance score was inflated by dark linework (a black eagle, a blue cross)
sitting on top of a bright or saturated field that anchors legibility, the same phenomenon
`recolorLogoForDark()`'s `warmVivid` exception in `logos.js` already accounts for on the party-logo
side of this codebase. (The full crest-by-crest measurement table lived in the implementation plan
for this feature, deleted per this repo's standing rule once the plan finished executing; the ten
names above are what it takes to reproduce the result.)

**Incidental change — the results-page club dropdown now sorts every league client-side.**
`renderClubPickerOptions()` in `results.js` needed `sortByLocalizedName()` for the 38 new Nations
League clubs so a divisioned league's `<optgroup>`s sort correctly in the active display language
(decision 6). Rather than branch "sort client-side only for the divisioned league, otherwise trust
the API's `ORDER BY name_en`", the simpler change applies `sortByLocalizedName()` to every league's
club list, divisioned or not — matching what the voting form's `clubsForLeague()` already did. That
changes Hebrew and Russian ordering for all eight pre-existing leagues, not just the new one: the API
order was always English-alphabetical regardless of display language, so a Hebrew or Russian visitor
now sees those dropdowns sorted the way they read rather than the way `name_en` sorts. Improvement,
not a regression, but it was an undocumented side effect of the Nations League change until now.

**Every suite passed** at the end of this plan: 161 backend tests, 40 worker tests (both real-Postgres
suites), `scripts/tests/test-i18n-parity.sh`, and `scripts/tests/test-frontend-seo.sh`.
