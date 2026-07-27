# Party classifications — reasoning

`services/backend/seed.sql` holds the **values**. This file holds the **reasoning**. That split is
deliberate: the seed file had grown into an append-only changelog where roughly half the lines were
prose, and the current value for a party could only be worked out by reading every block in order.

**Rules of the split**

- A number or tag changes in `seed.sql`. The justification for it changes *here*.
- Do not put reasoning back into `seed.sql`. If a value needs defending, defend it here.
- Do not put values here that aren't in `seed.sql`. This file must never become a second source of
  truth — when the two disagree, `seed.sql` is right and this file is stale.

Formal design decisions live in
[`design/2026-07-16-party-categorization-analytics-design.md`](design/2026-07-16-party-categorization-analytics-design.md)
and [`design/2026-07-21-religiosity-axis-design.md`](design/2026-07-21-religiosity-axis-design.md).
This file records how those decisions were applied to each party.

---

## How to revise a classification

1. Edit the party's row in the `VALUES` block in `seed.sql`. There is exactly one row per party per
   table, and it is the current state — no appending, no revision blocks.
2. Update that party's entry below, saying what moved and on what evidence.
3. Verify the way every revision here was verified: seed a container with the *previous* `seed.sql`,
   apply the new one on top, and confirm the value actually moves on the already-seeded row.

   ```bash
   docker exec voteball-test-db psql -U postgres -c "CREATE DATABASE revcheck;"
   docker exec voteball-test-db psql -q -U postgres -d revcheck -f /tmp/schema.sql
   docker exec voteball-test-db psql -q -U postgres -d revcheck -f /tmp/seed-prev.sql   # previous
   docker exec voteball-test-db psql -q -U postgres -d revcheck -f /tmp/seed-new.sql    # new
   ```

4. Run the backend suite. `test_queries.py` and `test_migration.py` both assert on classification
   state and will catch a party that loses its `bloc`/`sector`, or one that gains a religiosity
   score while still whitelisted as NULL-by-design.

**Why the classification `UPDATE`s are unguarded.** The name and `logo_url` statements in `seed.sql`
end in `AND ... IS NULL`, so they only fire on a fresh database. The classification statements
deliberately do not. Production is always already seeded, so a guard would make every edit to these
columns unreachable there — the whole reason the file previously grew by appending. Unguarded is
safe for these six columns specifically because **nothing in the app ever writes them**: the admin
party endpoints only rename. Names and logos keep their guards for exactly the opposite reason —
admins *do* edit those live, and an unguarded write would destroy their edits.

---

## The axes

All three axes are `INTEGER`, range **−3..+3**, and **nullable**. A `CHECK` constraint enforces the
bounds; `test_migration.py` asserts it.

**NULL is load-bearing and is not "unknown yet."** A `0` asserts a *confirmed centrist position*. A
party that has stated no position must be NULL. This is why proving that a party still hasn't
published a platform is a real finding rather than a failed lookup.

### `economic`

Negative is left, positive is right. Anchors as actually used:

| | party | why it sits there |
|---|---|---|
| **+2** | ישראל ביתנו | shrinks the state — privatize Ashdod Port and Haifa Airport, end child allowances from the fifth child |
| **+1** | ישר, ביחד, המפלגה הכלכלית, אל הדגל, המילואימניקים, הליכוד | liberalizing *fused with* real state expansion (trust-busting, subsidies, targeted spending) |
| **0** | כחול לבן, הציונות הדתית, עוצמה יהודית, רע"ם | no economic doctrine, or a genuinely balanced one |
| **−2** | הדמוקרטים, בל"ד, ש"ס, יהדות התורה | social-democratic |
| **−3** | חד"ש-תע"ל | self-defined communist |

The +1 band is crowded on purpose. A programme that liberalizes trade while *coercively*
restructuring markets is not +2; +2 requires actually withdrawing the state.

### `security`

Negative is dovish, positive is hawkish.

| | position |
|---|---|
| **+3** | annexation / sovereignty over Judea and Samaria |
| **+2** | no Palestinian state **plus** a territorial claim (sovereignty over security-essential areas, settlement expansion, preemptive doctrine, taking territory in Gaza) |
| **+1** | no Palestinian state, but explicitly refusing territorial expansion |
| **−1** | Zionist two-staters |
| **−2** | two-state with an end to the occupation |
| **−3** | full withdrawal, right of return, dismantling settlements |

### `religiosity`

Scoped to **Jewish** religion-and-state. Negative reduces religious authority.

−3 disestablishment / −2 strong separationist / −1 pluralist / 0 status quo / +1 preserve Jewish
character / +2 expand religious authority / +3 halakhic state.

---

## Conventions

**Revealed position, not claimed position.** Where rhetoric and record diverge, the number records
what a party actually does and a tag carries the gap (`claims-economically-liberal`,
`instrumentally-clerical`). Do **not** add claimed/actual column pairs — explicitly rejected by
Decision 3 of the parent design doc.

**The axis records direction; the tag records motive.** Two parties can share a score from opposite
impulses. ישראל ביתנו and הדמוקרטים are both religiosity −3 — one from anti-clerical animus
(`anti-clerical`), one from religious pluralism (`religious-pluralism`). בל"ד is −3 from a third
motive again, civic equality (`secular-democratic-state`). This is Decision 5, and it is why a
shared number is never evidence that a distinction has been lost.

**`previous_parties` and `upcoming_parties` are independent**, even where `party_lineage` links
them. Previous rows describe each party *as it stood at the previous election* and are frozen —
back-dating a 2026 platform onto them defeats the point (Decision 1).

The one deliberate exception is a **new axis**: when `religiosity` was added it was scored for both
tables, because each row was scored as that party stood at its own time. Nothing was back-dated —
the value was simply missing, and the Political Lean tab computes from previous-election votes, so
without it the feature renders nothing. Same reasoning applied to בל"ד's religiosity, whose
programme is dated 2018 and unchanged, so it was equally their position at the previous election.

**Classify from the party's own sources.** A position that appears in a journalist's summary but not
in the party's own document does not move a number. See ביחד's tax cuts and רע"ם's security score
below for the two live cases.

**`אחר` (Other) is not a party.** It is a catch-all ballot option and every ideology column stays
NULL. It is absent from the `VALUES` blocks; `test_migration.py` asserts the NULLs.

---

## ⚠ Two things that must not be lost

### The Reservists name collision

Two different organisations use almost the same name. **Conflating them is a serious error.**

- **`המילואימניקים`** — Yoaz Hendel's **party**, registered 2025-09, primary 2026-06-08 (Hendel,
  Adomi, Frank, Peretz, Damri). *This is the row in the database.*
- **`המילואימניקים - דור הניצחון`** — a **movement** chaired by Gilad Ach (ex-chairman of Ad Kan),
  founded 2023/24, site `miluimnikim.org.il`. **Not this party**, and no established link.

Ach's movement publishes a far harder platform — conquering and holding territory in Gaza, a
permanent buffer zone to the Litani, and implementing the Trump emigration plan to remove the
*majority* of Gaza's population — which would score security +3. Classifying this row from
`miluimnikim.org.il` would attribute support for mass population transfer to a party that has never
stated it. **Classify this row from the party's own sources only.** This has already caused one real
bug: the row carried Ach's movement's logo until it was corrected.

### Renaming a party orphans its votes

Several rows have outdated names. **Do not rename them mid-cycle** — votes already cast reference
these rows.

- `ישר` is registered as "ישר! עם איזנקוט".
- `חד"ש-תע"ל` is the 2022 joint list with Ta'al; the list classified below is Hadash's own, and its
  chair is campaigning to re-form the broader Joint List. If the partnership lapses or the Joint
  List re-forms, this row needs **renaming, not reclassifying** — which is a different and larger
  change.

---

## Upcoming parties

### הליכוד — Likud · `bibi` · 1 / 2 / 1 · traditional

`claims-economically-liberal` records the gap between free-market rhetoric and the record.
religiosity **+1 is the revealed position** (Decision 4): Likud does not want a halakhic state, but
reliably funds and defends religious authority to hold a coalition. That gap is carried by
`instrumentally-clerical` rather than by a second column.

### ישר — Yashar · `opposition` · +1 / +1 / −2 · secular

Gadi Eisenkot's party, founded 2025-09-16. Co-founders include Matan Kahana (former Religious
Affairs Minister), Manuel Trachtenberg, Yoram Cohen (former Shin Bet chief), Nir Zohar (Wix).
Source: the party's own site `yasharwitheisenkot.com` (10-point agenda, principles page).

This row previously read `new-party` + `undefined-ideology` at a default `0/0/NULL`. That was honest
when written — the party had no platform. It has one now, and polls ahead of Likud, so the
placeholder had become the worst kind of stale: it looked like a classification.

**security +1.** The published agenda contains **no** position on a Palestinian state, the
territories, or sovereignty — the omission is deliberate and reported as such. The score therefore
rests on Eisenkot's own statements, the same evidence route the Reservists needed: *"you will not
find one statement of mine in favour of a Palestinian state"*, **plus** opposition to sovereignty
over Judea and Samaria on the grounds that it produces a bi-national state and forfeits the Jewish
majority, **plus** a single military force between the river and the sea.

Not +2, which is the interesting call. Every +2 party *that vetoes statehood* pairs that veto with a
territorial claim. Eisenkot has the first half and explicitly refuses the second — his objection to
annexation is demographic rather than dovish, but it is a real refusal. `anti-annexation` had to be
a new tag; the vocabulary only had its opposite, `sovereignty-annexation`, so the position would
otherwise have been invisible and this row indistinguishable from a soft +1.

**religiosity −2.** "שירות לכולם" conscripting haredim and Arabs with no compromise (he has said he
would prefer another election to a compromise on the haredi draft), a mandatory core curriculum for
all, state-run haredi education. Not −3: this platform demands no civil marriage and no abolition of
the Rabbinate, promises citizens can keep their faith and lifestyle, promotes "inclusive Judaism",
and Kahana — whose kashrut and conversion reforms were fought from *inside* religious Zionism — is a
co-founder. Reducing clerical privilege is not separating religion from state.

**economic +1, moved from 0 on 2026-07-27** when the party published eight costed principles
documents. The old reasoning was that the rightward and leftward halves "cancel", and that was fair
when the evidence was a 10-point agenda plus co-founder biography. Both halves are now large and
specific, which is not the same thing as balanced — it is this band's literal definition.

- Liberalizing: cut income tax (offset by levies on sugary drinks and single-use goods), open and
  parallel imports, break food-and-retail concentration, close redundant ministries, end patronage
  appointments, deregulate housing permits.
- Expanding: ₪20B over three years for reservists, a 15% rise for every conscript, 100% degree
  funding for combatants, dedicated land allocation, national post-trauma rehabilitation authorities
  under a dedicated minister, direct farm subsidies, absorbing a million olim in a decade.

The line that decides it against **0** is the welfare conditionality — "העבודה תשתלם תמיד יותר
מקצבה", with aid redirected from stipends to "משרתי מילואים ולמשפחות עובדות ויצרניות". That is a
directional doctrine about how welfare should work, and the 0 band requires *no* doctrine or a
genuinely balanced one. `service-conditioned-citizenship` carries it.

What decides it against **+2** is agriculture: "ייצור מזון מקומי הוא חלק בלתי נפרד מהחוסן הלאומי",
direct support to farmers, legislated `ענף אסטרטגי חיוני` status, state management of water and
reservoirs, production targets for essential goods. +2 requires withdrawing the state; this moves it
in. `agricultural-protectionism` is a new tag — the vocabulary had `free-trade` and
`anti-privatization` but nothing for sector-specific protection, so the position would have been
invisible.

**The `homeland-security` document is not evidence for the security axis.** It is *internal*
security — organised crime, police budgets, digital crime, violence against women, municipal
defence — and contains nothing on statehood, the territories, Gaza or borders. The URL invites
exactly the wrong inference. The security score still rests on Eisenkot's own statements, as above.

Nor does `inlocation-and-aliya` create a territorial claim, though it comes close enough to check:
"תמריצים להתיישבות באיזורי עדיפות לאומית" names no region. In Israeli usage "national priority
areas" often includes Judea and Samaria — but the document does not say so, and unstated is not
stated.

### ביחד — Together · `opposition` · 1 / NULL / −2 · secular

A **list of two legally separate parties** (Bennett 2026 + Yesh Atid), formed 2026-04-26 with
Bennett as chair and Lapid at #2. The components remain separate and autonomous.

**security is NULL and must stay NULL.** This is not the party dodging the topic — it is a genuine
internal contradiction. Lapid's position is that a Palestinian state is *postponed, not dropped*,
with the PA heading Gaza; Bennett rules one out. A single number cannot represent both, and
`internally-split-on-conflict` says so. **Do not "fix" this NULL by averaging the two.**

**economic +1**, from Bennett's cost-of-living programme presented 2026-06-30
([be-yahad.org.il/plans/yoker](https://be-yahad.org.il/plans/yoker/), plus launch coverage for the
measures not on that page). The programme pulls both ways and nets out where it already was:

- *Rightward*: eliminate produce tariffs outright (212% on milk powder, 85% on some fruit and veg),
  open agricultural imports, the European-standards principle ("what is permitted in Europe is
  permitted in Israel"), one Food Authority replacing three approval agencies.
- *Statist*: the headline instruments are **coercive** — mandatory dissolution of named monopolies
  (תנובה, שטראוס, דיפלומט, שופרסל), forcing שופרסל to sell stores where it holds a regional
  monopoly, mandated per-category financial reporting, a ban on exclusive importers carrying
  additional major brands, US-style deposit insurance. Replacing farm tariffs with direct grants is
  fiscally a wash.

This is the same fusion that holds המפלגה הכלכלית at +1 rather than +2. Not +2: no privatization and
no budget cut anywhere in the document. Not 0: a detailed published programme built on trade
liberalization is not "no doctrine."

**On the tax cuts.** One launch write-up lists "broad-based tax cuts"; another explicitly records
none, and the party's own document contains not one rate. Given **no weight**. Had it been counted,
the case for +2 would look much stronger — so this single decision is doing real work.

**`kashrut-liberalization` is not evidence for `anti-clerical` here.** Together's reform recognizes
foreign certifiers that the rabbinical authorities *approve*, explicitly without changing Chief
Rabbinate procedure — liberalization inside the Rabbinate's framework. `anti-clerical` is carried by
the education and civil-service plans instead (defunding religious school networks, the 60%
core-curriculum funding condition, full state supervision of haredi education, universal
conscription).

**Watch:** Bennett was reported in mid-June 2026 to be weighing dissolving the list over polling. If
it dissolves, this row does not get reclassified — it gets **split back into two rows**.

### הדמוקרטים — The Democrats · `opposition` · −2 / −1 / −3 · secular

Primary 2026-07-20; list weighted by rank, so the top drives the read. The realized list confirms
the dovish and social-democratic wings over the security wing — and all three military figures point
dovish (Golan #1; Ronen #7, who led the ceasefire protest movement; Sheffer #11, who signed the
pilots' letter). Axes unchanged by the list; what the old tags missed was religious pluralism
(Kariv #3, Fink #5, Dabush #13), Jewish-Arab partnership (Bashir #10) and the protest-movement
intake (Ronen #7, Radman #9, Avital #15).

religiosity −3 from **pluralism, not punitive secularism** (Decision 5). Kariv is a Reform rabbi
campaigning for civil marriage and divorce, for turning religious councils into municipal
departments, for recognition of the non-Orthodox movements, and against the Rabbinate's conversion
monopoly; Fink is an observant Shabbat-keeper who supports separation of religion and state; Dabush
runs the cross-denominational Rabbis for Human Rights. **The religious figures on this list push the
score down, not up.**

### כחול לבן — Blue and White · `unaligned` · 0 / 2 / −1 · secular

security **+2**. "Israel Mitazemet" is an explicit hawkish doctrine — no Palestinian state,
permanent Israeli security control over all territory, expansion of settlement, the Trump plan's
voluntary-emigration track for Gaza, proactive targeted killings, and a declared shift from
*solving* the conflict to *shrinking* it. Not +3: they keep the peace treaties, Palestinian freedom
of movement, a regional moderate alliance and an international civil administration in Gaza, so they
sit below the annexationist pole.

`unaligned` holds — both documents campaign for a broad consensus government "not dependent on the
extremes". economic 0: "free economy combined with social justice", imports and competition
alongside strengthening public health and education. religiosity −1: pluralist without
disestablishing — "Judaism in the spirit of Beit Hillel", local authorities shape Shabbat in their
own area, but the public space should still express the state's Jewish identity.

### ישראל ביתנו — Yisrael Beiteinu · `opposition` · 2 / 2 / −3 · secular

The platform confirms every axis rather than moving any: privatizing Ashdod Port and Haifa Airport
and ending child allowances from the fifth child (+2 economic); preemptive strikes, cutting Gaza's
water/electricity/fuel, a defence budget raised ₪70B→₪95B, and no negotiation over Jerusalem
(+2 security); abolishing the religious councils, a
mandatory civil-marriage option, ending yeshiva stipends, one chief rabbi per municipality,
rabbinical courts moved to the Justice Ministry (−3, the anchor of that axis).

**It does not say "no Palestinian state" in those words** — unlike every other +2 party here. What
it says is that there is no point reaching a settlement with the Palestinians alone, and that any
arrangement must be a comprehensive regional package with the Arab states. **And it makes no
territorial claim at all:** no sovereignty plank, no settlement plank, Gaza handed to an
international body rather than held, and Judea and Samaria appearing exactly once, as "ייצוב
ביטחוני וכלכלי בשיתוף פעולה עם ירדן".

So the +2 rests on doctrine, not territory — "אפס הכלה", preemptive strikes, carrying the war to
enemy ground, cutting Gaza's water/electricity/fuel, ₪70B→₪95B, no negotiation over Jerusalem,
loyalty demands on the Arab minority. The rubric's +2 parenthetical names preemptive doctrine as
qualifying, so the row fits — but this is the party that shows "statehood veto **and** territorial
claim" is over-specified as a definition. Checked against the party's own platform, 2026-07-27.

**Lieberman is himself a settler, and that fact does not do what it looks like it does.** He has
lived in נוקדים, over the Green Line, since 1988. Read quickly, that is the territorial claim the
platform is missing. Followed through, it is closer to the opposite: his signature proposal is the
land-and-population exchange — "סיפוח גושי התנחלויות לישראל, ובמקביל העברת שטחים ישראליים
המאוכלסים בערבים" — which annexes the blocs, his own home among them, *by trading* Arab-populated
Israeli land to a Palestinian state, and so presupposes a Palestinian state to trade with; he has
said he would recognise one under conditions. The residence and the swap plan are one transactional
position, not two contradictory ones, and they explain the platform's silence on sovereignty rather
than filling it in. **This is sourced from he.wikipedia and from the leader's biography, not from a
party document, so it moves no number** — see the "classify from the party's own sources" rule
above. It is recorded here because without it this row reads as a party with no territorial
position, which is not the same thing as a party that has one and declines to print it.

The bloc is pinned down rather than inferred: they want a statutory ban on an indicted person
forming a government.

### הציונות הדתית — Religious Zionist Party · `bibi` · 0 / 3 / 3 · religious_zionist

Primary held 2026-07-26. Realized list: 1 בצלאל סמוטריץ', 2 אורית סטרוק, 3 צביקה מור,
4 שמחה רוטמן, 5 צבי סוכות, 6 אוהד טל, 7 עומר רחמים, 8 מיכל וולדיגר.

**No axis moves, and that is the finding.** The two axes the list speaks to are already at their
poles — security +3 and religiosity +3, and a scale has nowhere further to go. The list does not
confirm them weakly; it confirms them at the maximum.

What the **order** changes:

- **צביקה מור enters at #3, above רוטמן.** Mor founded the Tikva Forum, the hostage families' body
  organised in explicit opposition to exchange deals ("victory, not deals"), and is himself the
  father of a hostage. A first-time candidate placed third by the membership, over sitting MKs, is
  the clearest statement this list makes about what the base prioritised in 2026 — hence
  `opposes-hostage-deals`, which no existing tag covered (`hardline-on-gaza` is about what is done
  to Gaza; `security-hawk` is a general disposition).
- **רוטמן slips to #4.** `judicial-overhaul` stays — still high on the list, still party policy —
  but the architect of the overhaul placed below a hostage-deal opponent is a real de-emphasis.
  Ranked lists are evidence about *priority*, not only about presence.
- **סטרוק at #2** is the first person-level evidence for a religiosity +3 that had been assigned
  from the programme alone. `halakhic-state` is the motive tag this party previously lacked.
- **סוכות #5 and רחמים #7** (Yesha Council CEO) keep `settler-movement` and `annexationist`.
- **טל #6 and וולדיגר #8** are deliberately **not** tagged. One advocacy figure at sixth is not a
  foreign-policy orientation, and one welfare MK at eighth does not move `not-economy-focused` —
  there is still no economic figure anywhere on this list. Tagging thin evidence is how a tag set
  stops meaning anything.

economic 0 with `claims-economically-liberal` already captures the gap between Smotrich's rhetoric
and his finance-ministry record.

**The thirteen `zionutdatit.org.il/hityashvut/` pages, read 2026-07-27: no axis moves either.** Same
reason as the primary — security +3 and religiosity +3 are already at their poles. The pages confirm
them at maximum: sovereignty defined as "החלת החוק הישראלי על יהודה, שומרון ובקעת הירדן" with the
Oslo A/B/C division dismantled, E1 approved to "תקבור את רעיון המדינה הפלסטינית", 50 new recognised
settlements in 2.5 years, ~50,000 housing units, 30,000 dunams declared state land.

`anti-two-state` **was missing and is now added.** The row carried `annexationist` but never the
plain veto, which is odd for the party that states it most explicitly — and Yashar carries
`no-palestinian-state` on thinner evidence. Upcoming table only; the previous-election row keeps its
four original tags, per the no-back-dating convention above.

**Roughly ₪9B is itemised across these pages and none of it moves `economic`.** Roads ₪7B over five
years, farms ₪100M+, antennas ₪50M, land-patrol units ₪40M/yr, Gaza-envelope alternative housing
₪800M, northern rehabilitation ₪650M, the settlement division from ₪40M to ₪100M a year, plus
₪250M/₪190M/₪170M/₪110M/₪95M for planning, traffic lights, safety, lighting and access roads. This
is territorial policy denominated in shekels, not a position on how the economy should be organised,
and reading it as state-expansionist economics would be a category error. What it *does* do is give
`claims-economically-liberal` its best evidence so far: this is the finance minister's own party
itemising what he directed to one sector.

`not-economy-focused` survives, but it is now the strained tag on this row — the subject of every
page is settlement and the budgets are instruments of it.

**"מקסימום שטח תחת ריבונות ישראלית עם מינימום אוכלוסייה ערבית"** is the sovereignty page's own
formulation, and it needs stating precisely: it is a plan to draw the sovereignty line *around*
Palestinian population centres, not a transfer proposal. The party does not advocate moving anyone.
The Reservists entry below is the standing warning about attributing population transfer to a party
that has not stated it, and it applies here in the direction of restraint. No existing tag covers
demography-driven border design; it is deliberately left untagged rather than approximated with
`jewish-supremacist`, which means something else. If it is ever worth a tag it should be added
across rows — Beiteinu's swap plan and Eisenkot's anti-annexation are *also* demographic arguments,
pointing in three different directions — not to this row alone.

**Two of the thirteen URLs mean something other than what they say**, and both would mislead a
future reader working from the link list:

- **`/tours/` is not tourism.** It is סיירי הקרקעות — land-patrol units, ₪40M a year, drones and
  cameras, claiming "עלייה של כ-70% באכיפת הבנייה הערבית הבלתי חוקית". An enforcement document.
- **`/settlement/` is inside the Green Line**, unlike the other twelve: five new communities between
  Arad and Beersheba, five more between Dimona and Beersheba, four in the north.

### עוצמה יהודית — Otzma Yehudit · `bibi` · 0 / 3 / 3 · religious_zionist

`kahanist`, `jewish-supremacist`. religiosity +3 for the same explicit halakhic-state vision as
Religious Zionism.

### המפלגה הכלכלית — The Economic Party · `unaligned` · 1 / 0 / −2 · secular

An unusual fusion: a large tax cut (VAT 18→12, marginal income 50→40, corporate 50→40) and
abolition of all tariffs and import quotas, fused with aggressive trust-busting — declare the
exclusive importers monopolies, dissolve the production councils, stop approving mergers, a
state-co-funded bank. **economic stays +1 rather than +2 precisely because that second half is real
state expansion**, not standard right-economics, and +1 keeps the fusion visible.

**Correction worth remembering:** `anti-clerical` was once removed from this party on the reading
that its kashrut position was competition policy. That was wrong and it was restored. Their own text
asks to "take the government, with its political interests, out of granting kashrut" — that is
disestablishment, not price policy — and their haredi section is about ending the
subsidy-for-study model, the same fight from the fiscal side. Both `anti-clerical` and
`kashrut-liberalization` are true.

### אל הדגל — El HaDegel · `unaligned` · 1 / 2 / 0 · secular

security **+2**, from a full policy programme rather than the single-issue reservist party the old
tags implied: sovereignty over "areas essential to its security", a reserved "right to take
territorial action", preemptive strikes, and rejection of *both* Oslo and conflict management —
Palestinians get self-governance, never a state. Not +3: secular-nationalist rather than messianic,
and neighbours who abandon terror are offered development and self-rule.

economic +1 for the same reason as Together — eliminating ministries and a 30% budget cut, offset by
massive periphery infrastructure and a strategic-industry programme. The constitutional material
(Basic Law supermajorities, a 16-minister cap, tiered judicial review, an 8-year PM term limit) and
the "El HaDegel Service" Basic Law drafting every citizen — with refusal forfeiting economic and
employment rights — were entirely unrecorded before.

religiosity **0**, and this is a deliberate call (Decision 6): the party is built on ending the
haredi conscription exemption, and **conscription is not scored on this axis**. A party can demand
universal service while wanting the Rabbinate left exactly as it is. Their mandatory core curriculum
pulls negative but is offset by a Values Pillar grounded in Jewish heritage plus community autonomy
above the core. The conscription stance lives in `anti-conscription-exemption` and
`universal-conscription`.

### המילואימניקים — The Reservists · `unaligned` · 1 / 2 / 0 · secular

**Read the name-collision warning above before touching this row.**

Sources: the party registry goals via IDI, the primary list composition, and — the decisive
evidence — the candidates' own public statements, which are far more explicit than the registry text.

security **+2**. The registry goals alone would justify only +1; the statements do not leave it
there. The platform promises to *take territory* from Gaza; Hendel's stated plan for the remainder
is to make it "Judea and Samaria" — permanent control through raids, on the West Bank model — and he
attacked the Rafah crossing opening as "establishing a Palestinian state on top of our heads". Held
below +3: unlike Ach's movement they do not call for mass population transfer, and unlike Religious
Zionism they do not call for sovereignty over Judea and Samaria.

economic +1 rests on Hendel's centre-right record — no published economic platform. Their
service-conditioned sanctions are severe but sectoral, not a general economic doctrine: Hendel's
formulation is that whoever does not serve "will not be able to vote or be elected, and will not
receive a shekel". **Conditioning the franchise on service** is a defining and unusual position,
hence its own tag.

`unaligned` is supported from both directions: Hendel has committed that he will "never complete
Netanyahu to 61, even if it means more elections", which rules out the bibi bloc — but he also rules
out the Arab parties and wants a government of Jewish Zionist parties only, which denies the
opposition bloc its arithmetic. **If the reported merger talks with Gantz complete, this row needs
revisiting.**

### זהות — Zehut · `unaligned` · 3 / 3 / 2 · religious_zionist

Source: the party's own full platform, *מחזירים את המדינה לעם — מצע מפלגת זהות תשפ"ו – 2026*
(188pp, `zehut.org.il/docs/zehut-platform-full-he.pdf`, first edition May 2026, written under Moshe
Feiglin). Scored entirely from the primary text — no secondary sources were needed or used.

economic **+3**, the only +3 on the axis and the clearest case in the table. This is not
right-of-centre economics, it is a doctrinal libertarian programme: a **flat tax** at a single low
rate on all income types, "no brackets, no credit points, no reliefs for cronies", with a one-page
return; government ministries cut **31 → 11** and entrenched in a Basic Law so the count can no
longer be set by coalition bargaining; the presidency abolished outright; a standing commitment to
vote *against* any bill without demonstrated necessity and to repeal existing ones; broad
deregulation; corporate-tax cuts; privatisation of state transport companies; budgetary pensions
curtailed. Switzerland and Hong Kong are named as the models, alongside Argentina's eight-ministry
reduction, with Reagan and PragerU quoted approvingly. Yisrael Beiteinu's +2 `free-market` is a
different order of claim from this.

security **+3**. Cancellation of the Oslo accords and sovereignty over Judea, Samaria **and Gaza**,
which the platform states in its own words is to be reached "by conquest, expulsion and settlement"
(`מביטול הסכמי אוסלו – להחלת ריבונות על חלקי ארצנו על ידי כיבוש, גירוש והתיישבות`). It budgets a
funded emigration programme for the Arab population of Judea and Samaria — real-estate purchase plus
a financial package, assistance locating receiving states and jobs — and devotes a section to
precedents it considers analogous (the post-1945 German expulsions, Partition, Cyprus 1974, Kuwait
1991, Kosovo 1999). Those who accept Israeli sovereignty receive **permanent residency, not
citizenship**; full civil rights come only individually, to those who "truly bind their fate to the
state and the Jewish people". A Palestinian state is rejected in principle ("the peace trap"), and
the Defence Ministry is renamed the **Ministry of War**. `population-transfer` is recorded because
the platform argues for it explicitly and at length; recording it is not endorsing it, and the
convention here is that the number and tags track the party's stated position.

religiosity **+2**, and this is the interesting row in the table — it is where the axis and `sector`
diverge in an unusual direction, and where the naive reading from Zehut's 2019 libertarian
reputation is simply wrong. The platform is explicitly **not** separationist. Its chapter *מוסדות
מדינת העם היהודי* opens with "מחויבות ממלכתית להלכה" — a **state commitment to halakha**: every
state institution and government body is to keep Shabbat, the festivals and kashrut, described as
"a basic and simple national principle, not a compromise" made to accommodate religious employees.
The Knesset cafeteria must be kosher; Israel Railways and the Electric Company must observe Shabbat
for as long as they are state arms; in the IDF food is kosher-only, non-operational Shabbat activity
is barred, and an order to desecrate Shabbat without operational need is "manifestly illegal",
justifying refusal. The **Chief Rabbinate keeps** the who-is-a-Jew determination for the Law of
Return, endorsed as rightly placed there. And Jewish civil law (*משפט עברי*) is to be recognised as
a **parallel state jurisdiction** autonomous from Knesset legislation, whose rulings the authorities
must enforce exactly as they enforce civil-court judgments.

Held **below +3** by a genuinely different mechanism, not by moderation. Coercion of the individual
is removed: the citizen's "Shabbat, marriage, food, culture, education and religion" are declared
private and communal matters; public transport is to be privatised precisely so Shabbat operation
becomes a community question rather than national law; the Ministry of Religious Services is
abolished into the Interior Ministry; the Hebrew courts are **voluntary**, civil-only, and require
both parties' consent; and direct state funding of yeshivas is to **end** — even-handedly with
humanities funding, on the argument that the funding weapon buys ideological conformity. So the
state *qua* state is thoroughly halakhic while the citizen is left alone. Religious Zionism and
Otzma hold +3 for wanting halakha to reach the citizen; Zehut explicitly does not.

This is exactly the direction-versus-motive split of Decision 5 in the religiosity design doc.
`state-institutions-bound-to-halakha`, `ends-state-religious-funding`,
`jewish-law-parallel-jurisdiction` and `communitarian-devolution` carry the shape of the position
that the single number +2 cannot. **`instrumentally-clerical` deliberately does not apply** — unlike
Likud there is no gap between claim and record to flag; Zehut is sincerely clerical about the state
and sincerely libertarian about the person.

`sector` **religious_zionist** describes the movement's identity and leadership — Feiglin, the
Manhigut Yehudit lineage, Temple Mount centrality, and a text that reasons from Rambam and Rav Kook
throughout — not its actual 2019 electorate, which skewed young and secular. That divergence is real
and is what `libertarian` and `cannabis-legalization` are doing in the tag list. Worth noting for
anyone revisiting: Feiglin states in the platform's own preface that he has **no operative plans
regarding the Temple** and that the platform contains no chapter on building it, so
`temple-mount-centred` records sovereignty and national symbolism, not a construction programme.

`bloc` **unaligned**: extra-parliamentary (it has run before and holds no seats), committed to
neither camp, and critical of Netanyahu on the security record — the magnetometer withdrawal from
the Temple Mount in 2017 and the policy of transferring responsibility for Gaza are both attacked by
name. Same reading as El HaDegel and the Reservists.

Conscription is **not** scored here, per Decision 6. Zehut's model is its own: a short universal
enlistment and training for everyone **including haredim** (adapted to their way of life and
scheduled in *בין הזמנים*), feeding a well-paid professional volunteer army; women are not
obligated to serve but may volunteer; Arabs may volunteer for civilian service only. That closes the
haredi exemption by shrinking the obligation for everyone rather than extending it — which is why
`professional-army`, not `universal-conscription`, is the accurate tag.

### רע"ם — Ra'am · `opposition` · 0 / −2 / NULL · arab

security **−2** on Abbas's own statements: an immediate end to the war, and a peaceful settlement
requiring an independent Palestinian state alongside Israel. That two-state position lands between
the Democrats (−1, Zionist two-staters) and בל"ד (−3).

**Scored conservatively on purpose.** A secondary summary also attributes to רע"ם the ending of the
occupation, evacuation of the settlements and the right of return — which would be −3, level with
בל"ד. That could **not** be verified: `idi.org.il` returned 504 on two attempts and
`israelhayom.co.il` returned 403, so the claim could not be traced to רע"ם's own material and may be
inherited from old Joint List text. −2 is what the confirmed evidence carries. If the stronger
platform is ever verified from the party's own source this row moves to −3 — but it should move on
evidence, not on a summary nobody could open.

religiosity **NULL** by Decision 3: this axis measures *Jewish* religion-and-state, and Ra'am's
conservatism is about Muslim religious life, which it does not measure.

### חד"ש-תע"ל — Hadash-Ta'al · `opposition` · −3 / −2 / NULL · arab

**No axis changes, and that is the finding, not an omission.** The party published an electoral list
and **no programme** this cycle, so there is no new policy evidence — inventing movement from a list
of names would be exactly the fabrication the NULL convention exists to prevent. Re-checked
2026-07-26: still no programme.

The list is evidence about **emphasis**, and that is what the tags record. יוסף ג'בארין replaced
איימן עודה as chair with ~82% of the conference vote and has said his aim is to rebuild the Joint
List (`pro-joint-list`); he is a law professor and former MK known for education and civil-rights
work, and #2 ג'עפר פרח directs the Mossawa Center (`civil-rights-focused`). #3 עופר כסיף is the
sitting Jewish MK — Hadash's founding Jewish-Arab principle made literal. #4 יוסף עטאונה is a former
MK and a Negev Bedouin; #5 is ניהאיה וישאחי.

See the renaming warning above: this row is named for the 2022 joint list with Ta'al.

### בל"ד — Balad · `opposition` · −2 / −3 / −3 · arab

Sources: the party's own programme at `altajamoa.org` (Hebrew edition, dated 2018-09-11 and
**unchanged since** — hence `program-unchanged-since-2018`, a note about the age of the evidence,
not a policy position), plus the 2026 primary list: סאמי אבו שחאדה (chair), בכר עואודה,
ד"ר מהא כרכבי סבאח, חסן נסאסרה, אורלי נוי.

**economic stays −2.** The programme is unambiguously left — raise the minimum wage, oppose
privatization of social services, tax capital over labour, strong labour protections, corrective
discrimination, autonomous Arab economic planning bodies — but that is social-democratic, not
communist. −3 is held for חד"ש, whose self-definition is communist. Moving Balad to −3 would erase a
real distinction between the two Arab lists that voters choosing between them can see.

**security stays −3**, confirmed rather than adjusted: complete withdrawal from the post-1967
territories, a Palestinian state with East Jerusalem as its capital, right of return under UNGA 194,
dismantling the settlements, opposition to Druze conscription and to national service for Arab
citizens. It is already the pole of the axis.

**sector stays `arab`** despite אורלי נוי at #5 being the first Jewish woman elected in a Balad
primary. `sector` describes the constituency a party organises, not the biography of every candidate
— the same reason עופר כסיף does not make חד"ש `secular`.

**religiosity −3 — this amends Decision 3** of the religiosity design doc, which put all three Arab
parties at NULL on the premise that they say nothing about how religiously Jewish the state should
be. Balad's own text refutes the premise *for Balad*: it demands "complete separation of religion
from the state", freedom of worship for all religions, and state symbols and an anthem grounded in
constitutional egalitarian principles rather than sectarian ones. That is stated, not inferred.
The amendment is **per-party evidence, not a blanket "Arab parties now get scored"** — רע"ם and
חד"ש stay NULL because Balad moved for publishing a religion-and-state demand, not for being an Arab
party. Motive tag `secular-democratic-state`: neither anti-clerical animus nor religious pluralism
but civic equality.

Balad's `previous_parties` row also carries religiosity −3, which is the deliberate exception
described under Conventions — the programme is dated 2018 and unchanged, so nothing is back-dated.

### ש"ס / יהדות התורה — Shas, UTJ · `bibi` · −2 / 1 / 2 · haredi

religiosity **+2**: communal autonomy and state funding, plus defence of the marriage, kashrut and
Shabbat monopolies — but **not** a programme to derive state law from halakha, which is what
separates them from +3.

---

## Previous parties

These describe each party **as it stood at the previous election** and are frozen. Most carry the
same reasoning as their upcoming counterpart at an earlier stage; only the differences are noted.

- **הליכוד** `bibi` · 1 / 2 / 1 · traditional — as above, including `instrumentally-clerical`.
- **יש עתיד** `opposition` · 0 / 0 / −2 · secular — strong separationist.
- **הציונות הדתית** `bibi` · 0 / 3 / 3 · religious_zionist — the four original tags only; the 2026
  primary findings are **not** back-dated here.
- **המחנה הממלכתי** `unaligned` · 1 / NULL / −1 · secular — security NULL with
  `avoids-security-topic`. This pairing is the reference example of "NULL means no stated position,
  and a tag says why", and `test_migration.py` asserts it directly.
- **ישראל ביתנו** `opposition` · 2 / 2 / −3 · secular.
- **ש"ס**, **יהדות התורה** `bibi` · −2 / 1 / 2 · haredi.
- **רע"ם** `opposition` · 0 / NULL / NULL · arab — the security −2 above is a 2026 statement and is
  deliberately not back-dated.
- **חד"ש-תע"ל** `opposition` · −3 / −2 / NULL · arab.
- **העבודה**, **מרצ** `opposition` · −2 / −1 / −2 · secular — both link to הדמוקרטים via
  `party_lineage`.
- **בל"ד** `opposition` · −2 / −3 / −3 · arab — religiosity populated, see above.

---

## Logos

Logo URLs are guarded on `IS NULL` because admins edit them live through the admin UI, and those
edits exist only in RDS until someone backfills them into `seed.sql`.

**Two corrections are unguarded** and therefore *do* overwrite an admin-edited logo for those rows.
That is a deliberate trade — each replaced a value that was actively wrong:

- **La Liga** — swapped the Wikimedia wordmark SVG for LaLiga's own "LL" monogram PNG, which suits
  the small square logo slot better; a wide wordmark renders tiny there.
- **המילואימניקים** — a **misattribution fix**, not a cosmetic swap. The replaced URL was
  `Logo_המילואימניקים_-_דור_הניצחון.png`, the logo of **Gilad Ach's movement** (see the name-collision
  warning). We were showing one organisation's mark on another organisation's row.

**זהות's logo is dark artwork and needs no special handling — verified, not assumed.** The Wikimedia
SVG is a `#163651` navy wordmark plus a `#6ac6de` cyan flag; 62% of its opaque pixels are
perceptually dark, and the wordmark is close to invisible on the `#161B22` cards if shown untouched.
`recolorLogoForDark()` in `logos.js` handles it with no code change: the navy lifts to `#b2d0ea`
(luminance 0.80) with hue preserved and the cyan is left alone, because it is already above the
threshold. Both halves of that were confirmed in a real browser — including a **cross-origin** load
from `upload.wikimedia.org` with `crossOrigin="anonymous"`, which is the part that could have failed
silently: a tainted canvas throws, `logoEl` swallows it, and the logo would render as the original
dark navy with no error anywhere. `upload.wikimedia.org` sends `access-control-allow-origin: *`, so
it does not taint. **Do not add it to `OUTLINE_CLUBS`** — that set is for clubs and leagues, and the
recolour already covers parties.

**Do not hotlink social-media CDNs.** Those URLs are signed and expire, the CDN may refuse hotlinks,
and — the one that actually bit, on F.C. Kiryat Yam — tracker blockers drop `*.fbcdn.net` in the
browser, so the crest is invisible to many visitors while `curl` fetches it happily. That class of
bug is undetectable server-side. Check a candidate URL by loading it **in a real browser from the
app's own origin**, not just with `curl`: the fbcdn crest passed curl and failed in-browser.

---

## Open questions

- **The Arab bloc may restructure.** Talks about a Joint List are live and unresolved; nothing is
  confirmed. If one forms, the affected rows need **renaming, not reclassifying**, and `seed.sql`
  keeps a commented-out `הרשימה המשותפת` insert for that case.
- **ביחד's `security`** is the only NULL axis on a Jewish party. It resolves only if the components
  merge or publish a joint position — or splits into two rows if the list dissolves.
- **רע"ם's `security`** should move to −3 if the stronger platform is verified from the party's own
  source.
- **המילואימניקים's `bloc`** needs revisiting if the reported merger talks with Gantz complete.
- Election date is **2026-10-27**; lists are not final, so more revisions should be expected.

---

## Change history

The per-pass reasoning is folded into the party entries above; this is only a pointer to when each
pass happened, for anyone reading git history.

| date | pass |
|---|---|
| 2026-07-16 | original classification (`bloc`, `economic`, `security`, `sector`, `tags`) |
| 2026-07-21 | revision 1 — Democrats' primary, Together's plans, Blue & White, Yisrael Beiteinu |
| 2026-07-21 | revision 2 — Religious Zionism (tags only), Economic Party, El HaDegel |
| 2026-07-21 | revision 3 — The Reservists, incl. the name-collision finding |
| 2026-07-21 | religion-and-state axis added (`religiosity`), both tables |
| 2026-07-21 | revision 4 — Arab parties from primary sources; Decision 3 amended for Balad |
| 2026-07-26 | revision 5 — Religious Zionism rank-weighted from its primary |
| 2026-07-26 | revision 6 — Together's economic programme |
| 2026-07-26 | revision 7 — NULL-axis sweep (Yashar reclassified, Ra'am scored) |
| 2026-07-26 | `seed.sql` flattened to a plain table; this document created |
| 2026-07-27 | Yisrael Beiteinu's security basis corrected against the party platform |
| 2026-07-27 | revision 8 — Yashar's eight principles documents; economic 0 → +1 |
| 2026-07-27 | revision 9 — Religious Zionism's settlement pages; no axis moves, `anti-two-state` added |
| 2026-07-27 | זהות — Zehut added to `upcoming_parties`, scored from its own 2026 platform |
