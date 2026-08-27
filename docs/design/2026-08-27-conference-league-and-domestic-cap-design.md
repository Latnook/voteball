# UEFA Conference League, and a cap on domestic leagues instead of tabs (2026-08-27)

Two changes that arrived together and are independent of each other:

1. The per-league-tab cap of 3 clubs becomes a cap of 3 clubs from any one **domestic** league. The
   three UEFA club cups impose no cap of their own.
2. The UEFA Conference League is added as an eleventh league, with seven clubs, following the
   Europa League's shape exactly (`2026-08-12-europa-league-design.md`).

The dual-league mechanics themselves are designed in `2026-08-07-nations-league-design.md`
(decisions 1–5); nothing here changes them.

## Part 1 — the cap

### 1. What the old rule missed

The old rule was "at most 3 non-null `club_id` picks per distinct `league_id`". It was written when
every tab was a domestic league plus the Champions League, and it conflates two different claims:

- *"I follow Barcelona, Real Madrid and Atlético"* — three rivals from one league. This is the
  ballot the cap exists to prevent, because a poll correlating fandom with voting learns nothing
  from a respondent who claims the whole league.
- *"I follow Barcelona, Arsenal, Bayern and Inter"* — one club each from four leagues, all of whom
  happen to be in this year's Champions League. That is an ordinary answer, and the old rule
  rejected it purely because those four clubs shared a tab.

Worse, the old rule did not actually catch the first case. Barcelona, Atlético, Villarreal and Real
Betis are all La Liga clubs *and* all Champions League clubs, so a voter could name all four on the
Champions League tab and the per-tab count never exceeded 3 in La Liga's own bucket.

### 2. The cap counts league MEMBERSHIP, not the label on the pick

`_validate_team_picks` now ignores each pick's `league_id` when applying the cap, and reads the
club's own `{league_id, domestic_league_id}` instead, dropping any league with `is_club_cup`.

**This is not a stylistic preference — counting by the pick's label cannot work.** Which of the two
club columns holds the domestic league is not consistent in `seed.sql`:

| Club | `league_id` | `domestic_league_id` |
|---|---|---|
| Barcelona | UEFA Champions League | La Liga |
| Real Betis | La Liga | UEFA Champions League |

Both directions are legitimate and both are in production — the Champions League block was seeded
"cup-primary" and the Europa League block "domestic-primary" (that doc's decision 3). The client
files each pick under `domestic_league_id ?? the tab`, so the label on Barcelona's pick reads
"La Liga" and the label on Real Betis's reads "Champions League". A cap keyed on that label would
enforce the rule on roughly half the ballots and silently skip the rest.

Reading both columns and dropping the cups is exactly what `_VOTE_LEAGUES_TOUCHED_CTE` in
`services/worker/rollups.py` already does, for the same reason and with the same comment.

### 3. `leagues.is_club_cup`, a column rather than a name list

A new `BOOLEAN NOT NULL DEFAULT FALSE`, `TRUE` for the Champions League, Europa League and
Conference League. It means two things at once: *this league imposes no pick cap of its own*, and
*this league is never a club's domestic league*.

A **league-level flag, not something inferred from the clubs** — the same argument that produced
`has_divisions`. Every cup club also sits in a domestic league and most domestic clubs sit in no cup,
so "the field here is drawn from elsewhere" is not a question the club rows can answer.

It is **FALSE for the World Cup and the Nations League**, which are continental/global competitions
but not club cups. This is the load-bearing part of the definition: a national team has no domestic
league to be counted under, so marking either one would leave those tabs with **no cap at all**
rather than a domestic-league one. `test_only_the_uefa_club_cups_are_marked_is_club_cup` pins the
set in both directions and names those two explicitly.

Seed-owned and written unconditionally, like `sort_order` and `has_divisions`; absent from both
admin league endpoints, so nothing in the app can drift it.

### 4. What the rule does and does not reach

| Ballot | Before | After |
|---|---|---|
| 6 clubs on the Champions League tab, 6 different domestic leagues | rejected | **accepted** |
| Barcelona + Atlético + Villarreal + Real Betis, all via the Champions League tab | **accepted** (the hole) | rejected |
| 3 La Liga clubs via the cup + a 4th via the La Liga tab | accepted | rejected |
| 4 Premier League clubs on the Premier League tab | rejected | rejected |
| 4 national teams on the World Cup tab | rejected | rejected |
| Lugano + Thun (both Swiss; no Swiss tab) | rejected | **accepted** |

The last row is a deliberate gap, not an oversight. A club seeded only under a cup carries no
domestic league in this database, so it lands in no bucket. The rule binds exactly where a domestic
league is known — which is the six domestic leagues this app seeds. Closing the gap would mean a new
column recording a domestic league that has no tab, seeded for ~30 continental-only clubs, to
constrain a case nobody has hit. Rejected as not worth the schema.

### 5. Both sides enforce it, and the client must not be looser

`services/frontend/vote.js` reimplements the same predicate (`clubWouldExceedCap`), because the form
disables cards rather than letting a voter build a ballot the API will reject. A client **stricter**
than the server is a usability bug; a client **looser** than the server produces a rejection the form
cannot explain. The comment on `MAX_CLUBS_PER_DOMESTIC_LEAGUE` in both files says so.

The client change also **removed** a special case: `clubCardState` used to check whether a
dual-league club's *linked* league was at cap, because the old cap was per-tab and one such club
consumed a slot in two tabs at once. The cap is now a property of the ballot, counted once per club
across every tab, so that check has nothing left to do.

## Part 2 — the Conference League

### 6. Everything follows the Europa League, deliberately

`sort_order` 8, pushing the World Cup to 9 and the Nations League to 10 — unguarded values, so a
reordering is a value change and not a migration. The legacy `name` column gets the final English
name, so no rename statement and no third identity branch in the leagues INSERT (Europa League
decision 1: **UCL's shape is a historical cost, not a pattern**).

Seven clubs. Six are new and Conference-League-only — their domestic leagues (Swiss Super League,
Veikkausliiga, Scottish Premiership, Erovnuli Liga, Liga I) are not seeded here. The seventh,
SC Freiburg, is already seeded under the Bundesliga and gains the Conference League as its
`domestic_league_id`, the same "reverse direction" link the Europa League uses. It held
`domestic_league_id IS NULL` beforehand, so nothing is overwritten.

The roster is expected to grow, the way the Europa League's grew 16 → 26.

### 7. The competition logo: UEFA's own two files, minus the trademark

`logo_url` points at `/logos/uefa-conference-league.svg` (black trophy, `#00BE14` brackets);
`DARK_VARIANT_LOGOS` in `logos.js` maps the league to `-dark.svg` (white trophy, same brackets).
Same two-file mechanism as the Europa League trophy, so no new theme logic.

Unlike the Europa League's, these did **not** need re-tracing: UEFA's files are real vector geometry,
1.9 KB each, differing only in `white` vs `black` fills. Two edits:

- **The ™ is its own `<path>`** — an "M" zigzag plus a "T" bar at x≈25–27, y≈28–29. Removing it is an
  exact deletion, not a geometry edit.
- **The `viewBox` is cropped to the artwork's measured alpha bounding box**, `3.53 2 24.94 27` in the
  source's `0 0 32 32` space. Every logo renders `object-fit: contain` in a fixed 3.4rem box, so a
  file that pads itself renders a visibly smaller crest than its neighbours. Measured by rasterising
  at 2048px and reading the alpha bbox — the same discipline `PADDED_CRESTS` documents. **Do not
  estimate this if the files are ever regenerated.**

Fetching them needs `wget`, not `curl`: UEFA's Akamai edge resets curl's HTTP/2 stream with
`INTERNAL_ERROR` over IPv4 and stalls it over IPv6, on requests it serves to wget without complaint.
A TLS/HTTP fingerprint difference, not a network block — worth knowing before concluding the host is
unreachable.

### 8. Ararat-Armenia needs a dark file; Lugano only needs an outline

Two of the eight new crests do not survive the dark card (`#161B22`) untreated, and they need
*different* treatments — which is the whole distinction `OUTLINE_CLUBS` and `DARK_VARIANT_LOGOS`
exist to draw.

- **Lugano** is a black disc carrying a white LFC monogram. Measured contrast of the disc against
  the card: **1.2:1** — the disc vanishes and the monogram floats on nothing. This is the Sparta
  Prague case exactly, and `OUTLINE_CLUBS` is the answer: the shape needs *bounding*, not lifting.
- **Ararat-Armenia** is dark line art — a `#231f20` ring and mountains over a white field, above a
  solid "ARARAT ARMENIA" wordmark. The roundel survives on its own; the wordmark does not. An
  outline **cannot** fix it, for the reason the Europa League trophy needed a real second file:
  outlining a solid mass traces its edge and leaves the middle dark. So it gets a
  `DARK_VARIANT_LOGOS` entry, `/logos/fc-ararat-armenia-dark.svg` — the upstream artwork with its
  two flat colours swapped, which keeps it a file you can look at rather than a runtime canvas.
  It is the first **club** in that map; the mechanism was already club-capable (`entity.name_en`).

The other six were measured and left alone. Two worth recording, because both look like candidates:
**KuPS**'s black shield carries a yellow border that already separates it from the card — the same
reason Stade Rennais is excluded — and **Iberia 1999**'s crimson eagle measures **2.75:1**, dim but
unambiguously a shape. Neither is the 1.2:1 disappearing act that earns an outline.

### 9. Six columns from 12 clubs, not 18

`renderTeamGrid`'s shape rule drops its floor from 18 to 12:

```js
const hex = !quad && (clubCount >= 24 || (clubCount >= 12 && clubCount % 6 === 0));
```

The Conference League opens at 7 and is expected to grow. At 7 it stays on auto-fill (five columns,
5+2); at 12 it becomes the first count that fills two clean rows of six, so it reaches six columns as
soon as six columns are the right answer, with no further code change.

**Only the shape arm moved; the `>= 24` size arm is untouched.** That is what keeps every existing
league where it is — in particular the **Israeli Premier League, whose 14 clubs sit inside the
widened 12–17 band** but are `14 % 6 == 2` and so stay on auto-fill. Verified in a browser against
every league's real count; nothing else changed.

## Verification outcome

Everything below was run, not reasoned about.

- **Backend 266 tests, worker 48, script suite 27/27** — all green. Six new `/api/vote` cases cover
  the table in §4 row by row, including the two that used to be wrong.
- **The grid rule was exercised against input that should match it**, rather than trusted to fire:
  the Conference League tab was driven at 7, 11, 12, 13, 18 and 24 clubs and the computed
  `grid-template-columns` read back each time. Result: `5, 5, 6, 5, 6, 6`.
- **That run surfaced something the design did not predict: 13 clubs falls BACK to five columns**
  (`13 % 6 == 1`, and 13 < 24). The grid therefore oscillates 5 → 6 → 5 → 6 as a roster grows
  through 12, 13–17, 18, 19–23, 24. This is the pre-existing shape rule behaving as designed — 13
  cards at six columns is 6+6+1, an orphan, which is what the rule avoids — and it applies to every
  league, not just this one. Left as is; recorded here because reading the code does not reveal it.
- **The cap was driven in a real browser**, not asserted from unit tests: picking Barcelona, Atlético
  and Villarreal on the Champions League tab disabled exactly 2 of 36 cards there (Real Betis and
  Real Madrid — the two remaining La Liga clubs in that competition), 17 of 20 on the La Liga tab,
  and **0 of 20 on Serie A**. The last number is the one that matters: it is the negative case, and a
  cap that leaked across leagues would have shown up there and nowhere else.
- **Both logo treatments were rendered and inspected in both themes**, at the card size the site
  actually uses.
- One near-miss worth recording, because it is this repo's most-repeated defect shape in miniature:
  the rename guard written while fixing a shadowed test helper was `assert '_ballot(client,' not in
  s` — unsatisfiable, since the replacement `_post_ballot(client,` *contains* that substring. A
  check that can never pass is the mirror of the `grep '^gate:'` pattern that could never match.
