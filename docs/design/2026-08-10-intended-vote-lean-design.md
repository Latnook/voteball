# Political Lean from intended vote, not last election — 2026-08-10

## Problem

The Political Lean tab answers "how did fans of this club vote in 2022". Every row on its detail
card — the three ideology axes plus the Bloc and Sector compositions — is computed from
`previous_parties`, via `weightedAxisAverage(entry.previous, …)` and
`compositionPercentages(previousBreakdown, …)` in `services/frontend/analytics.js`.

That makes the whole upcoming-election side of the data invisible on this card. Concretely: on
2026-08-10 `אל הדגל`'s `religiosity` moved 0 → −2 and the results page could not show it, because
`אל הדגל` is an `upcoming_parties` row and the card reads only the other table. The same is true of
every party contesting the coming election that did not contest the last one.

The site's purpose is correlating fandom with **voting**, and the more interesting question is the
forward-looking one. This pass repoints the card at intended vote.

## What changes on screen

Measured against live production data, 21 ballots, 2026-08-10:

| Row | Before (last election) | After (intended vote) |
|---|---|---|
| Economic | −0.6 (Left) | +0.1 (Right) |
| Security | −0.3 (Dovish) | +0.5 (Hawkish) |
| Religion & state | −1.7 (Separationist) | −2.2 (Separationist) |
| Bloc | 82% Opposition · 12% Unaligned · 6% Bibi | 81% · 15% · 4% |
| Sector | 94% Secular · 6% Traditional | 96% Secular · 4% Religious-Zionist |
| *(new)* Coverage | — | "based on 20 of 21 ballots · 5% undecided" |
| Diversity (ENP) | 4.20 | 5.23 (pick-counted, overstated — see Decision 7) |

**Two of the three axis labels flip.** This sample voted Labor/Yesh Atid in 2022 and now names
ישר, ביחד, אל הדגל and בית ציוני - המילואימניקים — the new centre-right reservist parties. The
label flip is the finding, not a defect, and it is the single most consequential effect of this
change. The after-figures above are pre-normalisation (see Decision 2); the direction holds and the
decimals will shift slightly.

## Decisions

**1. The card answers one question: intended vote. All five rows switch together.**
Switching only the three axes would leave Bloc and Sector on last-election data with nothing on
screen distinguishing them, and the single coverage figure would apply to some rows but not others.
Bloc arguably gains meaning in the process — "bibi / opposition / unaligned" is a statement about
the *coming* coalition.

**2. Each ballot counts once, not once per pick.**
A ballot may name up to three upcoming parties (`app.py:181`), and `rollup_upcoming.vote_count` is
`COUNT(*)` grouped by party — so it counts **picks, not people**. Live: 21 ballots produce 28 picks,
1.33×. Averaging over raw counts would give a three-party ballot triple the weight of a one-party
ballot.

This is the same error the national rollups already exist to avoid: summing league-scoped rollups
over-counts a multi-team ballot, which is why `rollup_national_*` are separate tables. Same mistake,
different column.

**3. Ballot weight is a new `weight NUMERIC` column on the existing upcoming rollups.**
`rollup_upcoming` and `rollup_national_upcoming` each gain `weight NUMERIC NOT NULL DEFAULT 0`,
filled with `SUM(1.0 / k)` where `k` is that ballot's pick count. Every ballot then contributes total
weight exactly 1, distributed across its picks.

`vote_count` stays `INTEGER` and continues to drive the displayed breakdown bars — those must remain
whole picks.

Rejected: a **ninth rollup table** (there are already eight, and *both* `services/backend/tests/conftest.py`
and `services/worker/tests/conftest.py` carry `DROP TABLE … CASCADE` lists that must stay in step
with them — a ninth doubles that burden for no gain); and making **`vote_count` itself fractional**
(breaks every displayed count and percentage).

**4. Undecided ballots are excluded from the mean and disclosed as a percentage.**
This follows the axis convention one level up: `weightedAxisAverage` already skips parties whose axis
is NULL from *both* numerator and denominator, rather than imputing a value
(2026-07-21 religiosity design, Decision 8). A voter with no stated intention is that same situation
one level up, so excluding and disclosing keeps the voter rule and the party rule consistent. It is
also standard polling practice: "don't know" is reported, not blended.

A partial weight for undecided voters was considered and rejected. Any specific weight is
undefendable — the objection that killed a fixed previous/upcoming blend applies unchanged — and at
the current 5% undecided the difference between excluding them and including them at half weight is
under 0.1 on a one-decimal display. The disclosure scales honestly: at 30% undecided the reader sees
30%, rather than the distortion being buried in a constant.

**Exclusion requires no new code** *for the axes*. Undecided ballots are already stored as
`upcoming_party_id IS NULL` rows; `partyById(null, 'upcoming_parties')` returns undefined and the
existing guard skips the row. Only the displayed percentage is new.

**It is not automatic for the diversity index or the eligibility gates, and both must exclude it
explicitly.** `computeEffectiveParties` has no party lookup to fail — it sums raw counts, so an
undecided row would be scored as though "undecided" were a party, making a split-but-decided fanbase
and a uniformly-undecided one look equally diverse. The gates must match the metric they admit:
eligibility counts *decided* ballots, so a club with 9 decided and 5 undecided ballots does not clear
a threshold of 10 on the strength of votes the number never uses. The coverage line reports undecided
as a share of **all** ballots, which is the one place the excluded voters are visible.

**5. The eligibility thresholds move to ballot weight, not pick count.**
`DIVERSITY_MIN_VOTES` and `LEAN_MIN_VOTES` are both 10 (`analytics.js:5-6`), tested against
`row.total`, which today is the sum of `entry.previous` counts — one per ballot, so "10 votes" means
ten people. Repointing the metric at upcoming without repointing the gate would test against
**picks**: a club with four voters naming three parties each reports 12 and walks onto a board meant
for ten people. Both gates must sum `weight`, giving ballots again.

This is the whole reason a naive table-swap is wrong, and it is invisible in testing unless a fixture
ballot names more than one party.

**6. `schema.sql` changes by `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, never by editing the `CREATE`.**
`schema.sql` re-runs on every backend boot via `db.init_db`, and `CREATE TABLE IF NOT EXISTS` skips
an existing table entirely — so a plain edit to the `CREATE` would never reach a live database. The
file already documents this trap at `schema.sql:196` for `votes.ip_hash`; this follows it.

**7. The Traits gate moves too, and this supersedes a standing "do not do this" comment.**
`traitsEligibleClubs` (`analytics.js:740`) reads `entry.upcoming` for its data but gates on
`entry.previous` ballots, under a comment that says explicitly: *"Do not 'fix' this by switching back
to entry.upcoming — an unknown ballot count is not a safe basis for publishing a fanbase profile, and
this keeps Traits, Lean and Diversity on one shared definition of sample size."*

Both of its reasons are addressed rather than overridden. The unknown ballot count was a real
constraint — `rollup_upcoming` held only picks — and the `weight` column is exactly what removes it;
the gate becomes a genuine ballot count, not a pick count wearing one. And the shared definition of
sample size is *preserved* only by moving all three together: leaving Traits on previous while Lean
and Diversity move to upcoming is what would split it.

The visible consequence is the one that comment anticipated and could not then allow: a club with
intended-vote ballots but no last-election ballots can now become eligible. That is now safe, because
its ballot count is known.

**The comment must be rewritten in the same commit**, not deleted. A future reader who finds the old
text will re-derive the old conclusion.

**8. The Diversity tab switches to intended vote as well, and says what it now measures.**
Diversity is the Laakso–Taagepera effective number of parties, `1 / Σ(share²)`. Leaving it on
last-election data would make it the only historical view on the page, so it switches too — but
unlike the lean axes it does not merely change value, it changes **meaning**, and the label has to
follow.

ENP assumes one choice per respondent. Over a multi-pick question it can no longer distinguish
*"fans disagree with each other"* from *"each fan is personally torn between three parties"*. Both
raise the number. The metric is therefore relabelled as fragmentation of **intended** vote, where a
voter hedging across three parties legitimately counts as fragmented — that is a real property of
the electorate, just not the one the old label claimed.

Measured effect is modest where it is visible: nationally ENP goes 4.20 → 5.23 (pick-counted, so an
overstatement). Only clubs above the threshold appear, which today is Maccabi Haifa alone.

**A 50/50 blend of the two distributions was considered and rejected as mathematically wrong here.**
Pooling inflates ENP above *both* inputs — nationally 4.20 and 5.23 pool to 9.31 — because it counts
change over time as if it were disagreement between people. The degenerate case proves it: a fanbase
unanimously behind one party that switches unanimously to another scores 1.00 on each side and 2.00
pooled. With 11 of 21 ballots switching, this dataset is exactly that shape. Averaging the two ENP
values instead is not broken, but mixes two instruments (one pick per voter vs up to three) and
needs an undefendable ratio, so it is rejected on the same grounds as the lean blend.

**9. The frontend falls back to `count` when `weight` is absent.**
Pods roll one at a time, so a new frontend can briefly meet an old API payload carrying no `weight`.
Reading `r.weight ?? r.count` degrades to today's pick-weighted behaviour for a few seconds instead
of rendering an empty card, and makes the deploy order-independent.

## Implementation

**Schema** (`services/backend/schema.sql`) — `ALTER TABLE rollup_upcoming ADD COLUMN IF NOT EXISTS
weight NUMERIC NOT NULL DEFAULT 0;` and the same for `rollup_national_upcoming`.

**Worker** (`services/worker/rollups.py`) — `_recompute_upcoming` (line 64) writes `weight` for the
club- and league-scoped rows; the national upcoming insert lives inside `_recompute_national`
(line 144), **not** in a function of its own, and needs the same treatment. Per-ballot pick count
comes from a `COUNT(*) OVER (PARTITION BY vote_id)` or an equivalent CTE over
`vote_upcoming_parties`. Undecided rows carry `weight = 1` per ballot. Recompute is already
`TRUNCATE`-and-reinsert, so the column fills on the first run after deploy with no backfill step.

**Backend** (`services/backend/queries.py`) — the upcoming selects at lines 187, 205 and 289 also
sum and return `weight`; `/api/results` and `/api/results/clubs-breakdown` include it per row.
`get_results_by_party` (line 302) is deliberately **not** changed: it backs the "Start from a party"
breakdown, which reports pick counts rather than averaging an axis, so ballot weight is meaningless
there.

**Frontend** (`services/frontend/analytics.js`) — `weightedAxisAverage` and `compositionPercentages`
take the party-list name as a parameter and read `r.weight ?? r.count`. Four call sites repoint from
`entry.previous`/`previous_parties` to `entry.upcoming`/`upcoming_parties`: line 312 (club ranking),
356 (axes), 370 (bloc), 384 (sector). A coverage line renders
`undecided_weight / total_weight` for the current scope.

`computeEffectiveParties` (line 40) takes the upcoming breakdown and sums `weight` rather than
`count` — with `count` it would measure picks and inflate every multi-pick club. Its two call sites
are the diversity rows at line 76 and the `row.total` gate at 79.

Both `row.total` computations (lines 75 and 310) sum `weight` over the **upcoming** breakdown, so
`DIVERSITY_MIN_VOTES` and `LEAN_MIN_VOTES` keep meaning "ten people" (Decision 5). Note the two are
computed independently in two places; changing one and not the other is the likely slip.

**i18n** (`services/frontend/i18n.js`) — new keys for the coverage line in `en`, `he` and `ru`. All
three objects must carry identical key sets and identical `{placeholder}` tokens; `t()` returns the
key itself on a miss, so a gap renders the raw key on the page rather than throwing.

## Testing

Worker tests carry the weight of this change, because they are what catches a silent regression to
pick-counting:

- a three-party ballot contributes total weight `1.0`, not `3`
- `SUM(weight)` over any scope equals the **ballot** count, never the pick count
- an undecided ballot puts weight `1` on the `upcoming_party_id IS NULL` row
- a one-party ballot is unchanged at weight `1` (guards against dividing when `k = 1`)

Backend tests assert `/api/results` and `/api/results/clubs-breakdown` expose `weight` per row, and
that `vote_count` is untouched and still integral.

The threshold regression is the one worth naming explicitly, because it fails silently and only
under multi-pick data: **a club with 4 ballots naming 3 parties each must NOT clear a threshold of
10.** Any fixture used for it must include ballots that name more than one party — a suite built
entirely from single-party ballots passes whether the gate counts ballots or picks, which is exactly
how this would ship broken.

Both `conftest.py` `DROP TABLE … CASCADE` lists are re-checked against `schema.sql`. No table is
added, so neither list should need editing — confirming that is the point.

## Non-goals

- **The "Previous Knesset vote breakdown" section is unchanged.** It is explicitly labelled as
  history and is where last-election data belongs.
- **The Switching tab is unchanged.** It is inherently previous→upcoming.
- **No toggle between last-election and intended views.** Two numbers on screen invites "which one
  is real"; the card commits to one question.
- **No change to the ideology values themselves**, or to how parties are classified.

## Verification outcome

Ten tasks executed on `feat/intended-vote-lean`, every one passing its own review with no fix
rounds. Final counts: worker suite 42 passed, backend suite 165 passed. Not merged to master by this
task — the repo owner has a pending wording call (see below) and the merge is left to a later step.

**This doc's own `Decimal`/`jsonify` claim was wrong, and worth correcting precisely.** The doc's
Implementation section (via the plan derived from it) asserted that returning an un-cast `Decimal`
from `queries.py` would make `jsonify` raise at request time. Task 4 checked this directly against
the version actually pinned in this repo (Flask 3.1.3) instead of taking it on faith: it does not
raise. `flask.json.provider.DefaultJSONProvider.default` catches `Decimal` and returns `str(o)`, so
an un-cast weight serializes silently as the JSON *string* `"0.5"` rather than the number `0.5` — no
exception, no log line. The `float()` cast in the row builder is still exactly the right fix, but the
real failure mode it prevents is worse than a crash: it's silent. JS `0 + "0.5"` is string
concatenation, not addition, so every weighted average on the card would have accumulated
concatenated strings instead of a sum — corrupting every axis, bloc and sector figure with no error
anywhere in the stack to catch it.

**`services/worker/tests/conftest.py` does not load `schema.sql`, contradicting what
`services/worker/CLAUDE.md` said.** Task 2 discovered that the worker's test fixtures define their
own inline `CREATE TABLE` schema (roughly lines 16-52) rather than calling anything that reads the
real `services/backend/schema.sql`. The backend's `tests/conftest.py` is the one that's fine — it
calls `db.init_db`, which genuinely loads `schema.sql` + `seed.sql`. Task 1's schema change (the new
`weight` column) reached the backend's tests for free and had to be hand-added to the worker's inline
copy, or Task 2's new test failed on `UndefinedColumn` instead of the intended assertion. Practical
consequence for future work: a column added to `schema.sql` does not reach the worker's tests until
someone patches this duplicate too, and `services/worker/CLAUDE.md` has been corrected in this same
commit to say so instead of the reverse.

**Task 6 left two small defects behind, both cleaned up in Task 8.** Repointing the Lean tab's
default (no-club-selected) view from `nationalPreviousBreakdown()` to `nationalUpcomingBreakdown()`
left the former with zero callers — dead code, confirmed by repo-wide grep before removal — and its
module-level cache variable (`nationalPreviousData`) went with it. Separately, the doc-comment above
`eligibleClubDiversityScores` still read "previous-election votes" after the function body had been
repointed to `entry.upcoming`; Task 8 reworded it to "decided intended-vote ballots," matching what
the code (`decidedBallots(entry.upcoming)`) actually gates on. Neither was a functional bug — the
stale comment couldn't mislead the running code, and the dead function couldn't execute wrongly — but
both are exactly the kind of drift this project's design docs exist to catch, and Task 8 caught them
in the same pass rather than leaving them as follow-up debt.

**The measured before/after numbers are not directly comparable across this doc and Task 9.** The
"What changes on screen" table above was computed pre-normalisation against 21 live production
ballots. Task 9's browser verification used its own 12-ballot local fixture (seeded specifically to
land the decided-ballot weight at exactly 10.0, the eligibility boundary), so its rendered figures —
Economic 0.3, Security 1.7, Religion & state 0.3, 57%/30%/13% bloc, 4.9 effective parties, and so on
— are answers to a different dataset, not a confirmation of the production table's specific decimals.
Don't read Task 9 as having verified those numbers; it verified the *mechanism* instead:

- the coverage line renders correctly with real counts and a real percentage ("Based on 10 of 12
  ballots · 17% undecided"), sourced from `weight` arriving as a genuine JSON number end-to-end (not
  a string — Task 4's `float()` cast confirmed working on the wire)
- both eligibility gates (`LEAN_MIN_VOTES`, `DIVERSITY_MIN_VOTES`) hold exactly at the intended
  boundary: a club with decided ballot-weight of precisely 10.0 clears the `>=` gate, matching
  Decision 5's intent
- a three-party ballot correctly contributes total weight 1.0 rather than 3, and an undecided ballot
  contributes weight 1 to the undecided bucket rather than being dropped or double-counted — both
  hand-verified against the raw `/api/results/clubs-breakdown` payload, not just eyeballed on screen
- all three languages (English, Hebrew, Russian) render genuine translated text for both new i18n
  keys (the coverage line and the Diversity basis caption) with correct script (verified by Unicode
  code-point classification, not eyeballing), no raw i18n keys, no `NaN`
- zero console or page errors across the full session (initial load, tab switches, axis switches,
  club selection, all three language switches)

One pre-existing, unrelated UI behavior was noted during Task 9 and deliberately left alone: switching
the display language resets the Lean tab's club picker back to "National," losing a prior club
selection. It predates this feature and nothing in this design touches that code path.

**Pending, not resolved by this task:** the English wording of the new Diversity basis caption
("Based on intended vote. A fan weighing several parties counts as mixed.") was flagged by the repo
owner as the one judgment call in this feature worth their own review — a number that stays in the
same place on the live site while what it measures changes underneath it. Task 8 shipped the brief's
draft wording verbatim and left the review open; this task does not resolve it and does not merge to
master for that reason.
