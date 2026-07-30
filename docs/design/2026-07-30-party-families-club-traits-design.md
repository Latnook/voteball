# Party Families and Club Traits

Adds a second, deliberately-shared classification layer to `upcoming_parties` — **families** — and a
results-page view that reports what a club's fans have in common: *"63% of this club's fans backed
universal-conscription parties (national average 41%)."*

This extends `2026-07-16-party-categorization-analytics-design.md` and
`2026-07-21-religiosity-axis-design.md` rather than replacing them. The three numeric axes and
`bloc`/`sector` are unchanged; `tags` is unchanged.

## Context

`tags` cannot answer "what do these parties have in common", and the reason is structural rather than
a gap in the curation.

Measured on `seed.sql` at the time of writing:

| | parties | tags/party | distinct tags | singletons | tags on ≥3 parties |
|---|---|---|---|---|---|
| `previous_parties` | 12 | 2.4 | 24 | 19 (79%) | **0** |
| `upcoming_parties` | 18 | 9.0 | 110 | 78 (71%) | 13 |

Three properties make the existing tags unusable as a grouping key:

1. **They are evidence, not classification.** A tag exists to justify an axis score, so being unique
   to one party is a feature. `rabbinate-as-fourth-branch` is true of exactly נעם; that is the tag
   working correctly. 61% of the vocabulary is singletons, and a singleton "shared trait" is just a
   party's name in disguise.
2. **Tag counts are unbounded and uneven** — 2 on ש"ס, 19 on זהות. Counting votes per tag would make
   Zehut's positions look ~10× more popular than Shas's purely because more was written about Zehut.
   `bloc` and `sector` avoid this by carrying exactly one value per party.
3. **Some tags carry a negation a grouping cannot see.** `claims-economically-liberal` and
   `instrumentally-clerical` exist to record that a stated position is *not* the real one. A
   keyword clustering pass filed הליכוד as a `religious-law` party and עוצמה יהודית as `free-market`
   from exactly these two tags — inverting their meaning.

Filtering by a support floor instead of curating fails on a different axis: at ≥3 parties, ש"ס and
יהדות התורה carry **no** eligible tag, because `ultra-orthodox` sits on exactly the two Haredi
parties there are. A threshold silently encodes "a trait only counts if many parties hold it", which
is a claim about party fragmentation, not about fans.

## Decisions

1. **Add a `families` column; do not touch `tags`.** `tags` remains the per-party evidence trail that
   `docs/party-classifications.md` reasons about. `families` is a short, closed, deliberately-shared
   vocabulary whose only job is to name what parties have in common. Rewriting `tags` into broad
   buckets was rejected: it would destroy distinctions the classification doc spends paragraphs
   justifying (the axis records direction, tags record motive — Decision 5 of the religiosity design),
   and it is not data-neutral, so the `services/backend/CLAUDE.md` restructuring proof does not apply.

2. **Families exist only where no axis already answers the question.** Territory is the `security`
   axis (a 7-band gradient with per-party evidence); religion-and-state is `religiosity`;
   state-vs-market is `economic`. A `greater-israel`/`two-state` family pair was drafted and dropped —
   it is a two-bucket version of a seven-band axis, and it merged `security +1` ("no Palestinian
   state, but explicitly refusing territorial expansion" — ש"ס, יהדות התורה, ישר) with `security +3`
   (annexation) into one value.

3. **Economics is the exception, and it earns a dimension.** The `economic` axis has a traffic jam:
   **6 of the 18** upcoming parties sit at `+1` (הליכוד, ישר, ביחד, המפלגה הכלכלית, אל הדגל,
   המילואימניקים), including both poll front-runners. The axis measures *how much state*; the family
   measures *what kind of economic politics*, which cuts across it — the trust-busting agenda spans
   `economic +1` to `+3` and three different blocs.

4. **Families are hand-authored, never derived.** Not from `tags` (Decision 1's failure modes), and
   not from Knesset vote tallies. The reasonableness bill of 2023-07-24 passed **64–0**: all 64
   coalition MKs for, all 56 opposition MKs walked out rather than vote. Read literally, the record
   says *no party opposed the judicial overhaul*. Abstention, walkout, absence and coalition
   discipline are indistinguishable in the data and mean different things.

5. **Every family assignment carries how it was established.** `[R]` — from the voting record;
   `[P]` — from the platform only, because no usable record exists. Nine parties have a record; nine
   do not (ישר founded 2025-09-16, זהות extra-parliamentary, נעם has only run inside another slate,
   and so on). This is not bookkeeping: הליכוד's platform says free market and its record says VAT to
   18%, brackets frozen, no ministry closed and NIS 5.4bn in coalition funds. Classifying from a
   platform alone gets Likud wrong, and that same error is currently uncatchable for ישר — the
   party polling first. The grade also gives new parties an automatic revisit trigger: their first
   Knesset vote makes a `[P]` assignment checkable.

6. **A party split against itself gets an explicit split value, not a guess.** יהדות התורה is one row
   carrying two factions that voted opposite ways on the draft bill (Degel HaTorah for, Agudat Yisrael
   against, over whether *any* sanction on yeshiva students is acceptable). הציונות הדתית is split the
   other way — Solomon, Woldiger and Sofer rebelled against the bill as too weak. Following the
   precedent ביחד already sets with `internally-split-on-conflict` and `security = NULL`, both carry
   `conscription-split`. Asserting a majority position would state something a third of the faction
   rejects.

7. **Every family value must sit on ≥2 parties, or it does not exist.** Two drafted values were cut
   by this rule: `anti-indicted-pm` (only ישראל ביתנו, and it duplicates `bloc` anyway) and
   `excludes-arab-parties` (only המילואימניקים). A singleton family is the exact defect this layer
   exists to fix.

8. **Percentages skip parties with no position on that dimension, from the numerator *and* the
   denominator.** This is Decision 8 of the categorization design, already implemented by
   `weightedAxisAverage` (`services/frontend/analytics.js:206`) for NULL axes. המפלגה הכלכלית has no
   conscription position — counting its voters in the denominator of "% backing universal
   conscription" would answer a question they were never asked.

9. **Families are seed-owned, like `bloc`/`economic`/`security`/`religiosity`/`sector`/`tags`.** No
   admin endpoint reads or writes them. The admin party endpoints only rename.

10. **Computed from upcoming-election votes.** The poll's actual subject, and the table with the
    richer classification. `previous_parties` gets no `families` column in this pass (see Non-goals).

## The vocabulary

Five dimensions, thirteen values. Counts are parties carrying the value, of 18.

### 1. Conscription

The defining fight of the 25th Knesset, and it cuts across every axis — ישר and ישראל ביתנו agree
here and disagree on nearly everything else.

| value | n | parties |
|---|---|---|
| `universal-conscription` | 5 | ישר, ביחד, ישראל ביתנו, אל הדגל, המילואימניקים |
| `conscription-exemption` | 3 | הליכוד, ש"ס, נעם |
| `conscription-split` | 2 | הציונות הדתית, יהדות התורה |

### 2. The judiciary

`bloc` records who a party sits with, not what it thinks of the courts.

| value | n | parties |
|---|---|---|
| `constitutional-reform` | 7 | ישר, ביחד, הדמוקרטים, כחול לבן, ישראל ביתנו, אל הדגל, המילואימניקים |
| `judicial-restraint` | 5 | הליכוד, הציונות הדתית, עוצמה יהודית, זהות, נעם |

### 3. Economics

| value | n | parties |
|---|---|---|
| `welfare-state` | 5 | הדמוקרטים, חד"ש-תע"ל, בל"ד, ש"ס, יהדות התורה |
| `cost-of-living` | 4 | ישר, ביחד, המפלגה הכלכלית, זהות |
| `sectoral-budgeting` | 4 | הליכוד, הציונות הדתית, ש"ס, יהדות התורה |
| `market-liberal` | 2 | ישראל ביתנו, זהות |
| `not-economy-focused` | 2 | עוצמה יהודית, נעם |

`welfare-state` is the value that justifies the layer: it unites Haredi, Arab and left parties that
agree on essentially nothing else, and no existing view of this data can produce that grouping.

`sectoral-budgeting` — fiscal power used as a delivery mechanism for a defined constituency rather
than as a macroeconomic programme — is descriptive, not pejorative; Shas has stated this model
openly for decades. It replaced `not-economy-focused` on הציונות הדתית, which was simply false:
Smotrich has held the finance ministry since December 2022. The record behind it is in
`docs/party-classifications.md`.

### 4. Arab political representation

`sector` labels a party as Arab; nothing records a *Jewish* party's stance toward Arab political
participation.

| value | n | parties |
|---|---|---|
| `arab-representation` | 3 | חד"ש-תע"ל, בל"ד, רע"ם |
| `jewish-arab-partnership` | 2 | הדמוקרטים, חד"ש-תע"ל |

### 5. Service identity

| value | n | parties |
|---|---|---|
| `reservist-movement` | 2 | אל הדגל, המילואימניקים |

## Seed data (`seed.sql`)

18 rows, 1–3 families each. `[R]` from voting record, `[P]` from platform only.

| party | families | grade |
|---|---|---|
| הליכוד | `conscription-exemption`, `judicial-restraint`, `sectoral-budgeting` | **[R]** |
| ישר | `universal-conscription`, `constitutional-reform`, `cost-of-living` | **[P]** |
| ביחד | `universal-conscription`, `constitutional-reform`, `cost-of-living` | **[P]** |
| הדמוקרטים | `constitutional-reform`, `welfare-state`, `jewish-arab-partnership` | **[P]** |
| כחול לבן | `constitutional-reform` | **[P]** |
| ישראל ביתנו | `universal-conscription`, `constitutional-reform`, `market-liberal` | **[R]** |
| הציונות הדתית | `judicial-restraint`, `conscription-split`, `sectoral-budgeting` | **[R]** |
| עוצמה יהודית | `judicial-restraint`, `not-economy-focused` | **[R]** |
| חד"ש-תע"ל | `arab-representation`, `jewish-arab-partnership`, `welfare-state` | **[R]** |
| בל"ד | `arab-representation`, `welfare-state` | **[R]** |
| רע"ם | `arab-representation` | **[R]** |
| ש"ס | `conscription-exemption`, `welfare-state`, `sectoral-budgeting` | **[R]** |
| יהדות התורה | `conscription-split`, `welfare-state`, `sectoral-budgeting` | **[R]** |
| המפלגה הכלכלית | `cost-of-living` | **[P]** |
| אל הדגל | `universal-conscription`, `reservist-movement`, `constitutional-reform` | **[P]** |
| המילואימניקים | `universal-conscription`, `reservist-movement`, `constitutional-reform` | **[P]** |
| זהות | `judicial-restraint`, `market-liberal`, `cost-of-living` | **[P]** |
| נעם | `judicial-restraint`, `conscription-exemption`, `not-economy-focused` | **[P]** |

Coverage is deliberately uneven (1–3, not a fixed 3–5). רע"ם, כחול לבן and המפלגה הכלכלית carry one
family each because they genuinely hold no position on the other dimensions; forcing a value would
assert something false. Decision 8's denominator rule is what makes uneven coverage safe.

The `families` and `family_evidence` writes join the existing **unguarded** ideology `UPDATE` blocks —
same reasoning as `bloc`/`economic`/`security`: nothing in the app writes these columns, production is
always already seeded, and a guard would make every later revision unreachable there. The name and
`logo_url` blocks keep their `COALESCE`/`IS NULL` guards; do not make them consistent.

`אחר` is absent, as it is from the existing ideology blocks — a catch-all ballot option, not a party.
It exists only in `previous_parties`, so it does not reach this feature.

## Schema (`schema.sql`)

```sql
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS families TEXT[];
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS family_evidence TEXT
    CHECK (family_evidence IS NULL OR family_evidence IN ('record', 'platform'));
```

Additive and idempotent, matching how `tags` (`schema.sql:94,104`) and `religiosity` were added. No
rollup table changes: `rollup_upcoming` already carries `club_id`, which is everything the compute
path needs. `tests/conftest.py`'s `DROP TABLE ... CASCADE` list is unaffected — no new tables.

## Backend (`queries.py`)

Two changes.

**`get_options()`** selects `families` and `family_evidence` alongside the existing party columns, in
both the `previous_parties` and `upcoming_parties` blocks (previous returns `NULL`/`NULL` for now).
Serialised as `'families': r[N] or []` following the existing `'tags': r[10] or []` shape.

**`get_clubs_breakdown()`** currently reads only `rollup_previous` and returns
`[{'club_id', 'previous'}]`. It gains an `upcoming` key from `rollup_upcoming`, filtered the same way:

```sql
SELECT club_id, upcoming_party_id, SUM(vote_count) FROM rollup_upcoming
WHERE club_id IS NOT NULL GROUP BY club_id, upcoming_party_id
```

This is the one change without which the feature cannot work — the analytics tab's only per-club feed
is previous-election data. No new endpoint; `/api/results/clubs-breakdown` gains a key.

Both follow the established connection discipline: `db.get_db()` per route, `conn.close()` in a
`finally`.

## Frontend (`analytics.js`)

A new **Traits** tab beside Lean and Diversity, reusing the existing machinery:

- `clubsBreakdown` (fetched at `analytics.js:665`) now carries `upcoming` per club.
- `LEAN_MIN_VOTES = 10` (`analytics.js:5-6`) is reused unchanged as the eligibility floor — clubs
  below it are excluded, exactly as they are from Lean and Diversity.
- `familyShare(upcomingBreakdown, family)` mirrors `compositionPercentages`
  (`analytics.js:218`) but is **multi-valued**: one vote contributes to every family its party
  carries, so shares do **not** sum to 100. The UI must not render them as a composition.
- The national baseline comes from `/api/results?by=all` → `data.upcoming`, which reads the deduped
  `rollup_national_upcoming`. It must **not** be summed from `clubsBreakdown`: per the comment at
  `analytics.js:354-359`, that double-counts multi-club ballots and silently drops league-only voters.

Display is the club's **top three families by over-representation** (club share minus national
share), each with its share, the national average, and the gap. Only positive gaps are shown; a club
whose fans are merely average on everything shows nothing rather than a filler trait.

Each row states its own denominator, because Decision 8 means each family is computed over a
different subset of votes. Rendering is `createElement`/`textContent` only — family values are
seed-owned and safe, but the surrounding party names are not, and the page rule is absolute.

## i18n (`i18n.js`)

13 family values × 3 languages = 39 new `DICTIONARY` keys, plus tab and column labels. All three
language objects must carry identical key sets and identical `{placeholder}` tokens; `t()` returns the
key itself on a miss, so a gap renders `familyWelfareState` on the page rather than throwing.

Family values are written as display copy from the start, which is the main practical reason this
layer beats reusing `tags` — `claims-economically-liberal` has no natural Hebrew rendering, whereas
"welfare state" does. Russian names must be Cyrillic; a Latin-keyboard homoglyph passes review.

## Testing

`services/backend/tests/`:

- `test_migration.py` — round-trips `families`/`family_evidence` and asserts the `CHECK` bounds,
  matching how the ideology columns are covered. Adding a column without touching this file is the
  exact gap the religiosity pass shipped.
- **Every family value sits on ≥2 parties** (Decision 7). This is the property that makes the layer
  worth having, and it degrades silently as parties are added.
- **Every party with `tags` has ≥1 family and a non-NULL `family_evidence`.** The discipline cost of
  a second vocabulary is that a new party can be given tags and no families; this makes that fail CI
  rather than produce a party invisible to every percentage.
- **Every value in `families` is drawn from the closed 13-value vocabulary** — the column is `TEXT[]`,
  so nothing else enforces it.
- `test_queries.py` — `get_options()` returns `families` as a list, `[]` when NULL; `get_clubs_breakdown()`
  returns both `previous` and `upcoming` keys.

Frontend has no automated suite (per `services/frontend/CLAUDE.md`); verify by driving the page.

## Non-goals

- **No `families` on `previous_parties`.** Its 12 rows average 2.4 tags with zero tags on 3+ parties;
  classifying it is a separate editorial pass, and this feature reads upcoming votes.
- **No admin editing of families.** Seed-owned, like every other ideology column.
- **No `excludes-arab-parties` or `anti-indicted-pm`** — one party each (Decision 7).
- **No automated derivation from Knesset voting data.** Decision 4. The record is how an assignment is
  *checked*, not how it is produced.
- **No change to `tags`, the three axes, `bloc`, or `sector`.**

## Open questions

- **עוצמה יהודית** carries only `judicial-restraint` and `not-economy-focused`. Its vote *against* the
  2025 budget is suggestive but no clean conscription position was sourced.
- **נעם**'s `conscription-exemption` is inferred from its religious-law programme, not from a vote —
  it has never run alone. Flagged `[P]` accordingly.
- **Whether some `sectoral-budgeting` recipients are organisations opposed to the IDF and the state**
  is asserted in public debate but was not sourced to budget lines in this pass. Following the
  convention used for רע"ם, the weaker well-evidenced claim is recorded and the stronger one is not.

## Verification outcome

*To be filled in after implementation, per the convention in this directory.*
