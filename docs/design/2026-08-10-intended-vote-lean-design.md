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

**Exclusion requires no new code.** Undecided ballots are already stored as `upcoming_party_id IS NULL`
rows; `partyById(null, 'upcoming_parties')` returns undefined and the existing guard skips the row.
Only the displayed percentage is new.

**5. `schema.sql` changes by `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, never by editing the `CREATE`.**
`schema.sql` re-runs on every backend boot via `db.init_db`, and `CREATE TABLE IF NOT EXISTS` skips
an existing table entirely — so a plain edit to the `CREATE` would never reach a live database. The
file already documents this trap at `schema.sql:196` for `votes.ip_hash`; this follows it.

**6. The frontend falls back to `count` when `weight` is absent.**
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

Both `conftest.py` `DROP TABLE … CASCADE` lists are re-checked against `schema.sql`. No table is
added, so neither list should need editing — confirming that is the point.

## Non-goals

- **The Diversity tab keeps reading `entry.previous`.** It answers a different question — how
  politically varied a club's fans are — and after this pass it is the only previous-based view on
  the page. Deliberate, not an oversight.
- **The "Previous Knesset vote breakdown" section is unchanged.** It is explicitly labelled as
  history and is where last-election data belongs.
- **The Switching tab is unchanged.** It is inherently previous→upcoming.
- **No toggle between last-election and intended views.** Two numbers on screen invites "which one
  is real"; the card commits to one question.
- **No change to the ideology values themselves**, or to how parties are classified.
