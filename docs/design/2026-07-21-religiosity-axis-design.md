# Religion-and-State Axis

Adds a third numeric ideology axis, `religiosity`, alongside `economic` and `security`.

Extends `2026-07-16-party-categorization-analytics-design.md`; read that first. Its Decisions 2
and 3 (nullable axes, no claimed/actual pairs) are load-bearing here and are followed rather than
revisited.

## Context

Religion-and-state is the third major cleavage in Israeli politics, and the schema currently has no
way to express it. Two existing fields gesture at it and neither works:

- **`sector`** (`secular`/`traditional`/`religious_zionist`/`haredi`/`arab`) describes *who a party's
  base is*, not *what the party wants the state to do*. It is also categorical, so it cannot be
  averaged and cannot feed the Political Lean tab.
- **the `anti-clerical` tag** is a single binary flag carrying wildly different intensities. As of
  2026-07-21 it is worn by Yisrael Beiteinu (abolish the religious councils, mandatory civil-marriage
  option, end yeshiva stipends, rabbinical courts to the Justice Ministry) and by Together (60% core
  curriculum as a funding condition). Those are not the same position, and a boolean cannot say so.

A numeric axis fixes exactly this, and does it cheaply: `weightedAxisAverage(breakdown, axis)` in
`analytics.js` is already generic over the axis name and already excludes null-axis parties from both
numerator and denominator.

## Decisions

1. **One nullable INTEGER column (−3..+3), not a categorical field.** Rejected a categorical
   `religion_state` enum: the entire purpose is to feed the vote-share-weighted average on the
   Political Lean tab, and categories cannot be averaged. Symmetric with `economic`/`security`.

2. **The axis measures religion-and-state POLICY, not the observance of the party's base.** The
   question is *how religiously Jewish should the state be* — marriage, Shabbat, kashrut, the
   Rabbinate's powers, state funding of religious institutions, core curriculum as a funding
   condition. It is deliberately near-orthogonal to `sector`, and the interesting rows are the ones
   where they diverge (see Decision 5).

3. **Scoped to *Jewish* religion-and-state; a party is NULL when it takes no position on it.**
   Ra'am is Islamist and socially conservative but wants nothing about how religiously *Jewish*
   Israel is. Scoring parties on "religion in public life generally" would make a Ra'am +2 and a
   Shas +2 mean unrelated things, which is worse than no value. NULL is the same convention
   Decision 2 of the parent doc established, and the null-handling code already exists.

   > **Amended 2026-07-21 by `seed.sql` classification revision 4.** As originally written this
   > decision said "the Arab parties are NULL" and named all three. That conflated a *finding*
   > (these parties published nothing on the question) with a *rule* (Arab parties are out of
   > scope), and the rule turned out to be false for Balad: their program demands "complete
   > separation of religion from the state", freedom of worship for all religions, and state
   > symbols grounded in "constitutional egalitarian and democratic principles" rather than
   > sectarian ones. That is a stated −3 position, so **Balad is now −3 on both tables** and the
   > decision is restated as a per-party evidence test rather than a category exclusion.
   >
   > Ra'am and Hadash remain NULL, for their own reasons: Ra'am's conservatism is about *Muslim*
   > religious life, which this axis does not measure, and Hadash published no program at all this
   > cycle. Balad landing level with Yisrael Beiteinu is not a defect — Decision 5 already accepts
   > that the axis records direction while tags record motive, which is why Yisrael Beiteinu and
   > the Democrats already share −3 from opposite impulses. Balad's motive (civic equality, not
   > anti-clerical animus and not religious pluralism) is carried by `secular-democratic-state`
   > and `state-of-all-its-citizens`.
   >
   > `RELIGIOSITY_NULL_BY_DESIGN` in `test_queries.py` is the executable form of this decision;
   > it was updated in the same commit and is what will catch the next drift.

4. **No claimed/actual pair for Likud.** Likud does not want a halakhic state but reliably funds and
   defends religious authority to hold its coalition. Rather than doubling the column, the numeric
   value records the revealed position (+1) and the gap is carried by a new tag,
   `instrumentally-clerical`. This is exactly the precedent set by Decision 3 of the parent doc for
   `claims-economically-liberal`.

5. **The axis records DIRECTION; tags record MOTIVE.** Yisrael Beiteinu and the Democrats both land
   at −3 from opposite impulses — punitive secularism versus religious pluralism. This is the one
   place a single axis genuinely loses information, and it is accepted rather than solved: splitting
   into separate "secularist" and "pluralist" axes would add a column to distinguish two parties.
   `anti-clerical` and `religious-pluralism` in `tags` carry the distinction.

6. **Conscription is NOT scored on this axis.** The haredi draft exemption is the sharpest
   religion-state fight in practice, but it is a distinct question from how religiously Jewish the
   state should be — a party can demand universal conscription while wanting the Rabbinate left
   exactly as it is. El HaDegel and the Reservists are therefore 0, not negative, despite both
   building their platforms on the exemption. Their stance lives in
   `anti-conscription-exemption`/`universal-conscription`.

7. **`previous_parties` is populated too, and this does not contradict the seed's revision-block
   rule.** The revision blocks added on 2026-07-21 deliberately touch only `upcoming_parties`,
   because back-dating a 2026 platform onto a previous-election row would defeat the independence of
   the two tables. A *new axis* is different: each row is scored as that party stood at the time. It
   is also mandatory, not optional — the Political Lean tab computes from `entry.previous`, so
   without `previous_parties` values the feature renders nothing at all.

## Scale

−3 separationist … +3 theocratic. Nullable.

| Value | Meaning |
|---|---|
| **−3** | Disestablishment: break the Rabbinate's monopolies, civil marriage, no state religious funding |
| **−2** | Strong separationist: civil marriage, break religious monopolies, core curriculum as a funding condition |
| **−1** | Pluralist: soften monopolies, recognise non-Orthodox streams, local Shabbat autonomy — without disestablishing |
| **0** | Status quo; no active religion-state agenda |
| **+1** | Preserve and modestly strengthen the state's Jewish character |
| **+2** | Expand religious authority and state religious funding |
| **+3** | Halakha as a basis for state law; maximal rabbinic authority |

## Schema (`schema.sql`)

```sql
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS religiosity INTEGER
    CHECK (religiosity BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS religiosity INTEGER
    CHECK (religiosity BETWEEN -3 AND 3);
```

Placed with the other ideology columns, under the comment block citing this doc.

## Backend (`queries.py`)

`get_options` selects `religiosity` in both the `previous_parties` and `upcoming_parties` queries and
adds it to both dict builders. Four line edits, no new function. `app.py` is untouched — `/api/options`
serialises whatever `get_options` returns.

## Frontend

**`analytics.js`** — one additional `lean-detail-row` in the detail card, after the security row,
calling the existing generic helper:

```js
const religiosity = weightedAxisAverage(previousBreakdown, 'religiosity');
```

Rendered as `value (label)` where the label is separationist below 0 and clerical above, matching how
the security row already renders dovish/hawkish. Null renders the existing "no stated position"
string. No new machinery, no change to `weightedAxisAverage`.

**`i18n.js`** — `analyticsReligiosityLabel`, `analyticsReligiositySeparationist`,
`analyticsReligiosityClerical`, in both `en` and `he`.

**No Dockerfile change** — both files already exist and are already listed in the frontend
`COPY` line.

The main club-ranking strip continues to rank on `economic` only. A religiosity ranking view was
considered and deferred (see Non-goals).

## Seed data (`seed.sql`)

One new unguarded revision block, following the pattern and the warning comment established by the
three revision blocks of 2026-07-21. It differs from those in writing **both** tables (Decision 7).

`upcoming_parties`:

| Party | `religiosity` | Basis |
|---|---|---|
| ישראל ביתנו | **−3** | Abolish the religious councils, mandatory civil-marriage option, end yeshiva stipends, one chief rabbi per municipality, rabbinical courts to the Justice Ministry |
| הדמוקרטים | **−3** | Kariv (#3) campaigns for civil marriage and divorce, religious councils to municipal departments, full recognition of the non-Orthodox movements, ending the Rabbinate's conversion monopoly; Fink (#5) is an observant supporter of separation of religion and state; Dabush (#13) runs the cross-denominational Rabbis for Human Rights |
| ביחד | **−2** | "Not state-funded — not on our dime", 60% core curriculum as a funding condition, full state supervision of haredi education, automatic recognition of international kashrut certification |
| המפלגה הכלכלית | **−2** | "Kashrut is too important for us to allow a monopoly in it… take the government, with its political interests, out of granting kashrut", plus ending the subsidy-for-study model via workforce integration |
| כחול לבן | **−1** | "Judaism in the spirit of Beit Hillel", local authorities shape Shabbat in their own area — but the public space should express the state's Jewish identity |
| אל הדגל | **0** | Mandatory core curriculum in every publicly funded school, offset by a Values Pillar grounded in Jewish heritage and community autonomy above the core. Conscription excluded per Decision 6 |
| המילואימניקים | **0** | Says nothing about marriage, Shabbat, kashrut or the Rabbinate; the haredi-exemption fight is excluded per Decision 6 |
| הליכוד | **+1** | Revealed position; rhetoric-vs-record gap carried by `instrumentally-clerical` (Decision 4) |
| ש"ס | **+2** | Communal autonomy and state funding, defence of the marriage/kashrut/Shabbat monopolies — but not a halakhic-state program |
| יהדות התורה | **+2** | As Shas |
| הציונות הדתית | **+3** | Explicit halakhic-state vision |
| עוצמה יהודית | **+3** | As Religious Zionism |
| בל"ד | **−3** | *Revision 4, 2026-07-21.* "Complete separation of religion from the state", freedom of worship for all religions, state symbols and anthem on "constitutional egalitarian and democratic principles" rather than sectarian ones. Motive carried by `secular-democratic-state` per Decision 5 |
| ישר | **NULL** | New party, `undefined-ideology` |
| רע"ם, חד"ש-תע"ל | **NULL** | Decision 3 as amended — no published position, per party, not per category |

`previous_parties`, scored as each party stood at the previous election:

| Party | `religiosity` |
|---|---|
| ישראל ביתנו | **−3** |
| יש עתיד, העבודה, מרצ | **−2** |
| המחנה הממלכתי | **−1** |
| הליכוד | **+1** |
| ש"ס, יהדות התורה | **+2** |
| הציונות הדתית | **+3** |
| בל"ד | **−3** (*revision 4*) |
| רע"ם, חד"ש-תע"ל, אחר | **NULL** |

Balad is the one party whose `previous_parties` row was touched by a later revision block, which
looks like a violation of revision 1's "upcoming only" rule and is not. That rule stops a *2026*
platform being back-dated onto a previous-election row. Balad's program is dated 2018-09-11 and is
unchanged since, so it was equally their position at the previous election — the value was missing,
not superseded. Only `religiosity` was set; economic/security/tags on that row are untouched.

### Correction carried by the same block

Revision 2 of 2026-07-21 replaced the Economic Party's `anti-clerical` tag with
`kashrut-liberalization`, on the reading that their kashrut position was competition policy rather
than a religion-state stance. That was wrong: their own text is about removing the government from
the granting of kashrut, and their haredi section is about ending payment for non-participation.
This block **restores `anti-clerical`** alongside `kashrut-liberalization`.

New tags introduced: `instrumentally-clerical` (Likud), `religious-pluralism` (already present on the
Democrats from revision 1, now load-bearing for Decision 5).

## Data flow

```
seed.sql ──> previous_parties.religiosity ──> get_options ──> /api/options
                                                                   │
                              partyById(party_id, 'previous_parties') lookup
                                                                   │
                     Political Lean tab ──> weightedAxisAverage(previous, 'religiosity')
                                                                   │
                                                    detail card, 4th row
```

Unchanged from the security axis in every respect except the column name.

## Error handling

Inherited, not new. A party with `religiosity IS NULL` is skipped in both the numerator and the
denominator of the weighted average; if every party in scope is null the helper returns `null` and
the row renders the existing "no stated position" string rather than a misleading `0.0`. This is the
path the Arab parties take by design (Decision 3), so it is a routine case here rather than an edge
case — a club whose fans vote overwhelmingly Arab-party will legitimately show no religiosity value.

## Testing

- `test_queries.py` — `get_options` returns `religiosity` for both party tables, including `None`
  for a NULL-axis party.
- `test_queries.py` — every seeded party except the Decision 3 NULL set has a non-null
  `religiosity`. Note this is a NEW kind of assertion: the parent design doc lists non-null
  `bloc`/`sector` coverage as a goal, but no test enforces it today (`test_queries.py` only
  round-trips fields on a party it sets up itself). Worth adding coverage for all three axes at once
  while writing this one.
- `test_app.py` — `/api/options` serialises the field.
- Schema CHECK constraint rejects −4 and +4.
- Seed idempotency: apply `schema.sql` + `seed.sql` twice against a container already seeded with
  the pre-change file; values must be identical on both runs and the axis must reach an
  already-seeded database (the guarded classification block cannot, which is why this is an
  unguarded revision block).

Frontend has no automated suite per repo convention; verify the fourth detail row in a browser in
both languages, including a club with a NULL-axis result.

## Non-goals

- **No religiosity ranking strip.** The main club ranking stays on `economic`. Adding a second
  ranked axis needs a toggle, bar re-scaling and more i18n; deferred until there is enough real vote
  data to know whether the distribution is interesting.
- **No separate "secularist" vs "pluralist" axes** (Decision 5).
- **No admin editing.** Like `bloc`/`economic`/`security`/`sector`/`tags`, this column is seed-owned;
  the admin party endpoints continue to rename only. This is what makes the unguarded revision block
  safe.
- **No backfill of `rollup_*` tables.** Nothing is rolled up per-axis; the weighted average is
  computed client-side from the existing breakdown.
