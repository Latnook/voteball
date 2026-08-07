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

## Decision 2 — shared teams are linked, never re-inserted

`clubs_name_en_uidx` is a **global** unique index (schema.sql:160, moved there from per-league by
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
`_VOTE_LEAGUES_TOUCHED_CTE` (`services/worker/rollups.py:14`), shared by `rollup_previous`,
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
| `services/frontend/analytics.js` | `worldCupLeagueId()` widens to all national-team leagues |
| `services/frontend/i18n.js` | one header key in all three languages |
| `services/frontend/logos/` | cropped `uefa-nations-league.svg` |
| `services/frontend/logos.js` | `OUTLINE_CLUBS` review for dark crests among the 38 |

`analytics.js:51` currently hardcodes `name_en === 'World Cup 2026'` to keep national teams out of
the club-diversity ranking. Thirty-eight more countries would swamp that ranking if the filter is
not widened; it is a silent quality regression, not an error.

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
