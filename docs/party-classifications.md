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

Each table below lists **what the number means** and **every party that actually sits there**, across
both tables. `[p]` marks a `previous_parties` row, `[u]` an `upcoming_parties` row; a party with no
marker sits at that value in **both**. Bands with no party are shown as *(none)* — an empty band is
information, not an omission.

> **Verify this section rather than trusting it** — it is the part most likely to drift:
> ```bash
> grep -A40 'AS v(name_he, bloc, economic, security, religiosity, sector, tags)' \
>   services/backend/seed.sql
> ```
> When the tables here and `seed.sql` disagree, **`seed.sql` is right.**

### `economic` — how much the state should do

Negative is left (more state), positive is right (less state).

| | meaning | parties |
|---|---|---|
| **+3** | Libertarian: shrink the state as a matter of principle, not just policy | זהות `[u]` |
| **+2** | Privatizing: actually withdraws the state — sell Ashdod Port and Haifa Airport, end child allowances from the fifth child | ישראל ביתנו |
| **+1** | Liberalizing *fused with* real state expansion — trust-busting, subsidies, targeted spending | הליכוד, ישר `[u]`, ביחד `[u]`, המפלגה הכלכלית `[u]`, אל הדגל `[u]`, המילואימניקים `[u]`, המחנה הממלכתי `[p]` |
| **0** | No economic doctrine, or a genuinely balanced one | כחול לבן `[u]`, הציונות הדתית, עוצמה יהודית `[u]`, רע"ם, יש עתיד `[p]` |
| **−1** | *(none)* | — |
| **−2** | Social-democratic | הדמוקרטים `[u]`, בל"ד, ש"ס, יהדות התורה, העבודה `[p]`, מרצ `[p]` |
| **−3** | Self-defined communist | חד"ש-תע"ל |
| **NULL** | No stated position — see the NULL rule above | נעם `[u]` |

**The +1 band is crowded on purpose.** A programme that liberalizes trade while *coercively*
restructuring markets is not +2 — +2 requires actually withdrawing the state, and +3 requires doing
so as doctrine.

### `security` — the conflict and the territory

Negative is dovish, positive is hawkish.

| | meaning | parties |
|---|---|---|
| **+3** | Annexation / sovereignty over Judea and Samaria | הציונות הדתית, עוצמה יהודית `[u]`, זהות `[u]`, נעם `[u]` |
| **+2** | No Palestinian state **plus** a territorial claim — sovereignty over security-essential areas, settlement expansion, preemptive doctrine, taking territory in Gaza | הליכוד, ישראל ביתנו, כחול לבן `[u]`, אל הדגל `[u]`, המילואימניקים `[u]` |
| **+1** | No Palestinian state, but explicitly refusing territorial expansion | ש"ס, יהדות התורה, ישר `[u]` |
| **0** | No stated conflict doctrine either way — the party is about something else | יש עתיד `[p]`, המפלגה הכלכלית `[u]` |
| **−1** | Zionist two-staters | הדמוקרטים `[u]`, העבודה `[p]`, מרצ `[p]` |
| **−2** | Two-state with an end to the occupation | חד"ש-תע"ל, רע"ם `[u]` |
| **−3** | Full withdrawal, right of return, dismantling settlements | בל"ד |
| **NULL** | No stated position — see the NULL rule above | המחנה הממלכתי `[p]`, רע"ם `[p]`, ביחד `[u]` |

Note **0 and NULL are different claims** here, and this axis is where the distinction is easiest to
see. המפלגה הכלכלית is `0` because it is an economics party that genuinely takes no conflict
position; ביחד is `NULL` because its component parties have not published a joint one.

### `religiosity` — religion and the state

Scoped to **Jewish** religion-and-state, so it is NULL for parties the question does not apply to.
Negative reduces religious authority.

| | meaning | parties |
|---|---|---|
| **+3** | Halakhic state: derive state law from religious law | הציונות הדתית, עוצמה יהודית `[u]`, נעם `[u]` |
| **+2** | Expand religious authority and state religious funding — defend the marriage, kashrut and Shabbat monopolies, *without* a halakhic-state programme | הליכוד, ש"ס, יהדות התורה, זהות `[u]` |
| **+1** | Preserve and modestly strengthen the state's Jewish character | *(none)* |
| **0** | Status quo — no active religion-state agenda in either direction | אל הדגל `[u]`, המילואימניקים `[u]` |
| **−1** | Pluralist: soften the monopolies without disestablishing | המחנה הממלכתי `[p]` |
| **−2** | Strong separationist: **core curriculum as a funding condition**, break the monopolies, universal conscription; civil marriage is typical but *not* required — ישר and כחול לבן sit here without it | ישר `[u]`, ביחד `[u]`, כחול לבן `[u]`, המפלגה הכלכלית `[u]`, יש עתיד `[p]`, העבודה `[p]`, מרצ `[p]` |
| **−3** | Disestablishment: end the Rabbinate's monopolies outright, civil marriage, no state religious funding | ישראל ביתנו, בל"ד, הדמוקרטים `[u]` |
| **NULL** | The Jewish religion-and-state question does not apply, or no position published | רע"ם, חד"ש-תע"ל |

**This axis folds two different fights into one number, and כחול לבן is the case that exposes it.**
A party's posture on *religion in public life* (Shabbat, marriage, kashrut, the Rabbinate) and its
posture on *the haredi sectoral settlement* (conscription, and the funding of separate school
networks) can point opposite ways. B&W is mild on the first — Shabbat devolved to local authorities,
no civil marriage, no kashrut reform, and a stated aim that the public space express the state's
Jewish identity — and hard on the second, defunding any school that will not teach the core
curriculum and making state-haredi education the default. It sat at −1 for months because the
document with "religion and state" in its title contains only the first kind, and the second kind
lives in the education and service papers. **When scoring this axis, read the education and
conscription material too; the religion-and-state chapter alone will systematically under-score a
party.**

**בל"ד is scored, and that is deliberate.** "Arab party" is not itself a reason to leave this axis
NULL — Balad's own programme demands "complete separation of religion from the state" in as many
words, so it earns −3 on evidence. רע"ם and חד"ש-תע"ל stay NULL because they have published nothing,
not because of their sector. This is the per-party evidence test that replaced a blanket category
exclusion.

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

### הליכוד — Likud · `bibi` · 1 / 2 / 2 · traditional

**religiosity +2, moved from +1 on 2026-07-30.** The old reading was that Likud "does not want a
halakhic state, but reliably funds and defends religious authority to hold a coalition", scored +1
with `instrumentally-clerical` carrying the gap. The first half is still right and is what keeps this
row out of +3. The second half is the +2 band's definition, and the record meets it on both limbs:

- **Defends the monopolies.** The Knesset repealed the 2021 kashrut reform and restored the Chief
  Rabbinate's exclusive control over kosher certification — 49–34 in first reading, 46–41 final,
  included in the coalition agreements, with implementation stalled by the Religious Services
  Minister from December 2022. The Competition Authority warned the repeal removes competition that
  "could have led to … lower food prices".
- **Expands state religious funding.** Haredi allocations raised from NIS 4.1bn to **5.17bn** in the
  2026 budget plus a late-night **NIS 800m** amendment; **>NIS 600m** to private schools that teach no
  core curriculum; yeshiva funding restored after a unanimous nine-justice High Court ruling that
  the state may neither defer eligible students nor fund the institutions holding them — with
  legislation to reset the status of students who ignored call-up orders.

What moved is the reading of the rule, not the evidence. The religiosity design's Decision 5 holds
that **the axis records direction and tags record motive**; "for coalition reasons rather than from
conviction" is a motive claim, so it belongs in `instrumentally-clerical` and cannot also justify
suppressing the number. Scored on direction alone, defending the kashrut monopoly by statute and
funding religious institutions at this scale is the +2 band as written. `instrumentally-clerical` is
retained and now does only its own job.

**economic +1 is confirmed, not merely inherited.** The same pass tested whether the "liberalizing"
half of this band is real or is only what `claims-economically-liberal` flags as rhetoric. It is real:
the "מה שטוב לאירופה טוב לישראל" import reform has phased in since 2025-01-01 and covers 80% of the
value of consumer-goods imports, and the personal-import VAT exemption was raised from $75 to $150
against the declared opposition of the Manufacturers Association and the Federation of Israeli
Chambers of Commerce. Liberalizing against your own producer lobby is not a claim. It sits alongside
VAT 17%→18%, frozen tax brackets, no ministry closed and a deficit past 5% — which is precisely this
band's "liberalizing *fused with* real state expansion", so +1 stands.

`claims-economically-liberal` is likewise retained: it records that the party brands itself
free-market while presiding over record spending and tax rises on workers, which remains true even
though the liberalizing half exists.

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

**Re-checked 2026-08-01 and the NULL is confirmed, not merely unresolved.**
[he.wikipedia](https://he.wikipedia.org/wiki/ביחד_(רשימה)) still records the two parties as
"separate and independent, cooperating within the framework of the list", with **no joint platform
published** — three months after formation and under three months from the election. The security
NULL therefore rests on a re-verified absence rather than on a stale reading. The dissolution watch
above is also still live and was reported again in mid-June by Channel 13, so the split-into-two-rows
branch remains the likelier resolution of this row than a joint position.

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

**2026-08-01 — read against the party's own eight platform documents, which no previous pass had
seen.** Every axis is confirmed and none moved; the tags were badly incomplete, and one of them is
now in question.

- **religiosity −3 confirmed, and confirmed as the *pluralist* −3 the axis design intends.** The
  religion-and-state paper demands civil marriage and divorce by statute, breaking the Rabbinate's
  monopoly on conversion *and* kashrut, recognition of non-Orthodox conversion, public transport on
  Shabbat, freedom of choice in burial, and equal, transparent subsidy of religious services to all
  streams. The framing is *"הפרדת הדת ממוסדות המדינה לצד חיזוק אופיה של ישראל כמדינה יהודית
  ודמוקרטית"* — separation from state institutions **alongside** strengthening Jewish character,
  which is Decision 5 almost verbatim. `civil-marriage` added.
- **economic −2 confirmed.** Shorter work week, added vacation and sick days, paternity leave,
  expanded subsidized early childhood, breaking up food/pharma/energy cartels, restored price
  controls, public and long-term-rental housing, periphery investment. No privatization and no tax
  rate anywhere in the document — social-democratic, not communist, so not −3.
- **`universal-conscription` added, as a tag and as the fourth family.** The religion-and-state paper
  closes on שוויון בנטל: *"ננהיג שירות לאומי שוויוני לכלל אזרחי ישראל"* — equal national service for
  all citizens, *"מתוך כבוד לאורחות חיים שונים, אך ללא ויתור על העיקרון הבסיסי של שוויון"*. The
  education and economic papers carry the same theme from the funding side.
- **`core-curriculum`, `anti-annexation`, `anti-settler-violence`, `anti-indicted-pm`,
  `regional-normalization`, `lgbt-rights` added.** The education paper ends the special status of the
  haredi networks and defunds institutions that teach neither maths, English nor civics; the security
  paper devotes one of its five steps to *"עוצרים את הסיפוח"* — halting annexation, repealing the
  annexation laws, defunding illegal outposts and declaring violent settler organisations terror
  organisations; the democracy paper legislates *"איסור כהונה תחת כתב אישום"* for ministers and the
  PM plus an eight-year term limit; the security paper commits to Saudi normalization and IMEC.

**`two-state` is now questionable and is deliberately left in place for the repo owner to rule on.**
The security paper **never uses the words מדינה פלסטינית.** It commits to *"מהלך מדיני אחראי מול
הפלסטינים"*, to *"הסדרים מדיניים"*, and to promoting *"אלטרנטיבה שלטונית מתונה"* in the Palestinian
arena — and it opposes annexation on the demographic ground that it would be *"סופה של ישראל
היהודית והדמוקרטית"*. That is structurally the **same** position the page scores as `anti-annexation`
**without** `two-state` on ישר, where the entry says in terms that the omission is deliberate and the
score rests on the leader's statements rather than the platform. Yair Golan is personally and
publicly a two-stater, so the tag is not baseless — but it is currently carried by the party's
document, and the document does not carry it. Either drop `two-state`, or keep it and record that it
rests on Golan rather than on the platform, the way ישר's entry does. **security −1 is unaffected
either way** — a responsible political process plus PA security coordination plus halting annexation
lands at −1 regardless of whether the endpoint is named.

Sources, all read 2026-08-01 and all first-party (`democrats-media.s3.us-east-1.amazonaws.com`):
[מדיני־ביטחוני](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%93%D7%99%D7%A0%D7%99+%D7%91%D7%99%D7%98%D7%97%D7%95%D7%A0%D7%99+(1).pdf),
[כלכלי־חברתי](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9B%D7%9C%D7%9B%D7%9C%D7%99+%D7%97%D7%91%D7%A8%D7%AA%D7%99+(2).pdf),
[דת ומדינה](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%93%D7%AA+%D7%95%D7%9E%D7%93%D7%99%D7%A0%D7%94.pdf),
[דמוקרטיה ומשפט](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%93%D7%9E%D7%95%D7%A7%D7%A8%D7%98%D7%99%D7%94+%D7%95%D7%9E%D7%A9%D7%A4%D7%98.pdf),
[חינוך](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%99%D7%A0%D7%95%D7%9A.pdf),
[להט"ב](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9C%D7%94%D7%98%D7%91+(2).pdf),
[חיסול הפשע המאורגן](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%99%D7%A1%D7%95%D7%9C+%D7%94%D7%A4%D7%A9%D7%A2+%D7%94%D7%9E%D7%90%D7%95%D7%A8%D7%92%D7%9F.pdf),
[סביבה](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%A6%D7%A2+%D7%A1%D7%91%D7%99%D7%91%D7%94.pdf).
These are Illustrator exports with **no usable text layer for WebFetch** — its summarizer receives
binary and reports the document as unreadable. `pdftotext` extracts them cleanly. Reach for it
before concluding a party PDF is inaccessible.

### כחול לבן — Blue and White · `unaligned` · 0 / 2 / −2 · secular

security **+2**, verified against the document 2026-08-01. "Israel Mitazemet" is an explicit hawkish
doctrine — *"שליטה ביטחונית עליונה בכל השטח תוך חיזוק והרחבה של ההתיישבות החוקית"* (supreme security
control over all the territory, with settlement strengthened and expanded), the Trump plan's
voluntary-emigration track for Gaza, proactive targeted killings, and — from the principles booklet
— a declared shift from *solving* the conflict to *shrinking* it. Not +3: they keep the peace
treaties (*"חיזוק הסכמי השלום"*), guarantee Palestinian freedom of movement through dedicated
transport infrastructure, and the word **סיפוח does not appear in the document at all**, which is
what holds them below the annexationist pole.

**The statehood plank is conditional, and the entry previously flattened it.** The text is
*"לא תוקם מדינה פלסטינית **אשר תאיים על ישראל** ותאפשר חזרה על מתקפת הטרור... של ה-7 באוקטובר"* — no
Palestinian state *that would threaten Israel*, not a flat refusal. Read strictly it leaves a
non-threatening state open, and the same document calls for *"ממשל פלסטיני מתון שנלחם בטרור"*. In
practice it is a rejectionist plank and `no-palestinian-state` stays, but the qualifier is the kind
of distinction this page makes a point of recording elsewhere (see ישראל ביתנו below).

`unaligned` holds — both documents campaign for a broad consensus government "not dependent on the
extremes". economic 0: "free economy combined with social justice", imports and competition
alongside strengthening public health and education.

**religiosity −1 → −2 on 2026-08-01, when the education programme was finally read.** This was the
last unread document on the row and it was the one that mattered. The −1 rested entirely on the
principles booklet, whose religion-and-state section (*"יהדות ברוח בית הלל"*) is a single bullet
devolving Shabbat to local authorities — genuinely a −1 posture. The education paper is a different
animal:

- **Core curriculum as a funding condition, stated twice.** *"חוק חינוך לכל"* establishes a National
  Education Council to define shared core studies and *"ויקבע שרק מוסדות שילמדו לפי התוכנית
  יתוקצבו"* — only institutions teaching the programme get funded. Point 06 repeats it in budget
  terms: *"רק בתי ספר של החינוך הממלכתי יתוקצבו ב-100%. עצירת הכספים הפוליטיים לבתי ספר פרטיים שלא
  עומדים בלימודי הליבה"*.
- **State-haredi education as the default**, replacing the private haredi networks (point 08,
  *"חינוך ממלכתי חרדי במקום חינוך פרטי"*).
- Alongside the service programme's *"כלל הצעירים יחויבו בשירות"* with individual economic sanctions.

Those are **the same three planks ישר carries at −2** — core curriculum, state-run haredi education,
universal conscription. ישר demands no civil marriage either, so that criterion was never load-bearing
for this band; the band text has been corrected to say so rather than leaving the next reader to
rediscover it.

**Why −2 and not −3, and why it sits at the top of its band.** B&W disestablishes nothing: no civil
marriage, no kashrut reform, no move against the Rabbinate, and the public space is meant to express
the state's Jewish identity. It also keeps the *"תורתו אומנותו"* exemption with quotas fixed in law
and calls Torah learners *"נכס יהודי וכלל ישראלי"* — a warmth ישר explicitly refuses.
`scholar-exemption-retained` now carries that, and it explains position *within* the band rather
than membership of it.

**Conscription: added 2026-08-01 from `sherut4all.com`, the party's own campaign site, which the
earlier passes missed entirely.** The row previously carried no conscription tag and one family,
and the families design doc asserted that was because the party "genuinely holds no position on the
other dimensions". That was wrong: B&W runs a full universal-service programme — *"כל הצעירים
יחויבו בשירות"* (all young people obligated to serve), mandatory civilian-service tracks for Arab
citizens (*"כל צעיר/ה בחברה הערבית לשרת במסלולים אזרחיים"*), a "מנהלת שירות ישראלי" administration,
and *"קנוס אותו וצמצום זכויות"* — fines and reduced state-granted rights for non-servers,
specifically allowances, subsidized housing, government tenders and public-sector posts. Hence
`universal-conscription` (the family and the tag), `sanctions-on-non-servers` and
`arab-civil-service`; the last has no existing counterpart, since the vocabulary held only בל"ד's
`opposes-arab-conscription`.

**No axis moved, and `religiosity −1` is what the carve-out protects.** B&W preserves the
*"תורתו אומנותו"* exemption for genuine Torah scholars — the exact compromise Eisenkot refuses, and
the reason ישר sits at −2 while this row stays at −1. `scholar-exemption-retained` records it,
because otherwise a reader comparing the two rows sees identical conscription tags and an
unexplained one-point gap. Coercion plus sanctions also rules out `conscription-by-incentive`, which
is defined by rejecting both.

Sources, all first-party and all read 2026-08-01:
[sherut4all.com](https://www.sherut4all.com/) (the service programme — conscription, sanctions, the
scholar exemption);
[book-israel-mitazemet-one-page-1.pdf](https://kachollavan.org.il/im/wp-content/uploads/2025/10/book-israel-mitazemet-one-page-1.pdf)
(security doctrine, 28pp);
[Hoveret Ekronot](https://kachollavan.org.il/wp-content/uploads/2025/07/20527_3_A5_Hoveret_Ekronot_ONE_PAGE_A.pdf)
(the six principles — bloc, economics, religion-and-state, LGBT rights, an eight-year PM term limit);
[book-hinuh-kahollavan.pdf](https://kachollavan.org.il/wp-content/uploads/2025/12/book-hinuh-kahollavan.pdf)
(the 14-point education programme — **the document that moved religiosity**);
[book-kahol-lavan.pdf](https://kachollavan.org.il/wp-content/uploads/2025/07/book-kahol-lavan.pdf)
(צו 8 — public-service reform, the content behind the [`/8ps/`](https://kachollavan.org.il/8ps/)
page, and the sole basis for `public-service-reform`).

…plus [*מציאות אחרת*](https://kachollavan.org.il/wp-content/uploads/2025/12/book%20different%20reality%20.pdf),
which despite the title is **B&W's reservists programme** — *"תכנית המילואימניקים של כחול לבן"* —
and [*יחד מנצחים*](https://kachollavan.org.il/wp-content/uploads/2026/07/20678_9_Amud-Atar.pdf), a
national mental-health and trauma authority. **All six party documents have now been read.**

**מציאות אחרת is the third independent confirmation of the conscription platform**, after
`sherut4all` and the education paper: *"כולם משרתים — חילונים, דתיים, חרדים, יהודים, ערבים
ודרוזים"*, *"צה״ל בוחר ראשון את מי לגייס וכל השאר הולכים לשירות אזרחי"*,
*"סנקציות אישיות על כולם, עבודה מול הפרט ולא הישיבות"* and *"מכסות לפטור במקום יעדים לגיוס"*. It
also carries a full reservist-benefits package (free early-years education, land grants, academic
admission without psychometric, tax relief, housing-tender priority), which earns `reservist-focused`.

**It does *not* earn the `reservist-movement` family, and the distinction matters.** That family
records what a party *is*, not what it has a policy about: אל הדגל and המילואימניקים grew out of the
reservist protest movement. ישר is the governing precedent — it carries the `reservist-focused` tag
and not the family, for exactly this reason. Note the competitive context: B&W is running a
reservists programme while polling ~1%, having just lost חילי טרופר to
בית ציוני – המילואימניקים.

**`kachollavan.org.il` returns 403 to automated fetching**; these were downloaded by hand. One
caveat for the next pass: **the education programme is a scanned-image PDF** — `pdftotext` yields 7
bytes from 7 pages, so it has to be read visually. That is why it stayed unread while the others did
not, and why this row carried a wrong religiosity for as long as it did.

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

Sources: [beytenu.org.il/party-platform](https://beytenu.org.il/party-platform/). **Re-verified
2026-08-01 and every claim above holds** — the Ashdod/Haifa privatizations, child allowances from
the fifth, the ₪70B→₪95B defence budget, *"לא יתקיים כל מו״מ על ירושלים"*, all four
religion-and-state planks, and the "Judea and Samaria appears exactly once, as ייצוב ביטחוני
וכלכלי בשיתוף פעולה עם ירדן" observation. The platform also states the −3 anchor outright:
*"אנו מאמינים כי צריך להפריד דת ממדינה"*. This is currently the only party row on the page verified
against a live primary source.

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
opposition bloc its arithmetic.

**2026-08-01 — the Gantz merger did NOT happen, and a different one did. This row is now stale in
its name, and its `economic` gap has a date on it.** Sequence: the Hendel–Gantz talks collapsed over
Gantz's refusal to declare he would not sit with the haredi parties; MK חילי טרופר then left Gantz's
כחול לבן, registered "יסודות ישראל" in early July, and on 2026-07-07 announced a joint run with
Hendel under the name **"בית ציוני"**, to which the "המילואימניקים" brand was then appended. The
list now runs as **בית ציוני – המילואימניקים**, positioning itself as a
*"חלופה ציונית וממלכתית במרכז"* — a Zionist statist alternative in the centre, explicitly
differentiating from Gantz's כחול לבן. In late-July polls it crossed the threshold for the first
time at 4–5 seats.

Three consequences, in order of how much they matter:

1. **`economic +1` — the weakest number on this page — resolves on 2026-08-05**, when the joint list
   holds its launch conference in Jerusalem and presents its מצע. Do not guess before then; the
   whole reason this row's economics is flagged is that it rests on Hendel's personal record with no
   party document behind it. Read the platform on the 5th and rescore.
2. **`unaligned` holds and is now better evidenced, not worse.** The bloc question was open pending
   the Gantz talks; those talks died precisely over the haredi question, which is the same commitment
   the bloc rests on. Trooper arriving from כחול לבן reinforces the centre position rather than
   moving it.
3. **The rename is an admin-UI action, not a `seed.sql` edit, and it is deliberately not done here.**
   Renaming a party row orphans the votes already cast against it (see the warning above), so this is
   the repo owner's call through the admin screen, taken when the ballot name is final. Lists are not
   final until closer to 2026-10-27.

One note against over-reading the merger: Gantz said of Trooper's departure in a 103FM interview that
week, *"אני לא מצליח לשמוע משפט אחד שהוא אומר אחרת ממני"* — he cannot hear one sentence Trooper says
differently from his own. Take it as an interested party's framing, but it does mean this list and
כחול לבן are competing for one position rather than occupying two.

### זהות — Zehut · `bibi` · 3 / 3 / 2 · religious_zionist

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

`bloc` **bibi**. Zehut sits in the Netanyahu-led right-wing camp: on sovereignty, the judiciary and
the conflict there is no alternative bloc it could recommend, and Feiglin's own history runs through
Likud (Manhigut Yehudit) and the 2019 withdrawal deal with Netanyahu.

**This row was first committed as `unaligned` and corrected the same day — the mistaken reasoning is
worth recording, because it is easy to repeat.** The platform criticises Netanyahu by name more than
once (the 2017 magnetometer withdrawal from the Temple Mount, the policy of transferring
responsibility for Gaza), and that was read as ruling out the bibi bloc. It does not. **`bloc` tracks
which camp a party would sit with and recommend for PM, not whether it criticises the incumbent** —
several bibi-bloc parties attack Netanyahu's record freely. The Reservists' `unaligned` looks similar
but rests on something different in kind: Hendel's explicit commitment never to complete Netanyahu
to 61. Absent a refusal of that sort, right-wing criticism is just criticism. Being
extra-parliamentary is likewise not evidence of non-alignment.

Conscription is **not** scored here, per Decision 6. Zehut's model is its own: a short universal
enlistment and training for everyone **including haredim** (adapted to their way of life and
scheduled in *בין הזמנים*), feeding a well-paid professional volunteer army; women are not
obligated to serve but may volunteer; Arabs may volunteer for civilian service only. That closes the
haredi exemption by shrinking the obligation for everyone rather than extending it — which is why
`professional-army`, not `universal-conscription`, is the accurate tag.

### נעם — Noam · `bibi` · NULL / 3 / 3 · religious_zionist

Sources: the party's own site (`noam.org.il`) — its self-description, its sovereignty statement of
2 Tevet 5786 / 22 December 2025, and its education and religion-state material — plus he.wikipedia
for the electoral history. Avi Maoz's party, founded 5779 / 2019, spiritually led by Rabbi Tzvi Tau's
school; **hardal** (haredi-leumi) rather than mainstream religious-Zionist, which is why the tag
carries what `sector` cannot: the enum has no hardal value and `religious_zionist` is the closest
true one.

religiosity **+3**, and it earns the halakhic-state band on a structural demand rather than on
stringency. Their own text asks for the Chief Rabbinate to be established inside the government
compound as a **`רשות שלטונית רביעית`** — a *fourth branch of government* — holding "all the state's
Jewish-identity systems", per Rav Kook's vision. That is a claim about where state authority comes
from, not about defending existing monopolies, which is exactly the line between this band and ש"ס /
יהדות התורה at +2. The rest is consistent with it: the state must not become "a state of all its
citizens", opposition to the Western Wall pluralistic-prayer compromise, and the demand that only the
Chief Rabbinate rule on desecration of holy sites.

security **+3**. The party is famously about one subject, so it would be easy to score this 0 by
analogy with המפלגה הכלכלית — that would be wrong. Maoz opened a legislative process to apply
Israeli sovereignty in Judea and Samaria and his bill passed a preliminary reading 25–24; his stated
reasoning is that 7 October proved a Palestinian state is an existential danger. The party's own
banner reads *"להיות עם חופשי בארצנו — זה להיות עם ריבוני בארצנו בכל מרחבי ארצנו"*. Sovereignty over
Judea and Samaria **is** the +3 band, and a single-issue party that nonetheless authored the
sovereignty bill has stated a position as clearly as anyone.

economic **NULL — the first NULL on this axis, and it is a finding, not a gap.** Their site, their
self-description and their Wikipedia entry contain no economic content at all: no tax position, no
welfare position, no market position, and no governing record that would reveal one (Maoz's
ministerial brief was Jewish identity and education units, nothing fiscal). Compare the three
neighbouring cases, because the difference is the whole point of the axis:

- הציונות הדתית and עוצמה יהודית are **0**, not NULL — they actively claim economic liberalism
  (`claims-economically-liberal`) and Smotrich has a finance-ministry record to read.
- המילואימניקים is **+1** with no published platform, resting on Hendel's centre-right record.
- המפלגה הכלכלית is **0** on the *security* axis for the mirror-image reason: an economics party that
  genuinely takes no conflict position.

נעם has neither a claim nor a record, so `0` would assert a confirmed centrist economics that nobody
has ever asserted. `not-economy-focused` carries the observation; the NULL carries the honesty.
**Revisit the moment they publish anything fiscal** — this is the "no platform yet" kind of NULL,
which ages, not the "axis does not apply" kind, which does not.

Sources: [noam.org.il](https://noam.org.il/). **Re-checked against the party's own site 2026-08-01
and the NULL holds** — still no tax, welfare, budget, market, cost-of-living or allowance content of
any kind. Their "באנו לתקן" section lists ten priorities and every one is Jewish identity, education
or gender: curriculum transparency, gender ideology in schools, conversions and halakhic authority,
Western Wall prayer arrangements, unit composition in the army, migrants, foreign NGO funding in
education, segregation in public facilities, and "consciousness engineering". A NULL that survives a
direct re-check against the primary source is evidence, not neglect.

`bloc` **bibi**, with no ambiguity worth arguing: Noam entered Netanyahu's 37th government under the
December 2022 coalition agreement, Maoz served as deputy minister in the PM's office, and his stated
2026 pitch is that Noam "will be the party that takes the right-wing bloc past 61". Maoz's February
2023 resignation over broken promises does not touch this — the Zehut precedent above applies:
criticising Netanyahu is not leaving his bloc, and Maoz was reappointed in June 2023.

`anti-lgbt`, `anti-progressive` and `family-values` are descriptive, not editorial, and they are the
party's own framing: an explicit platform against "destruction of the family", campaign material
promoting heteronormativity, and opposition to gender content in education and the army.
`anti-judicial-review` records their attack on High Court intervention in religious matters, which is
a separate strand from the halakhic-state demand and would otherwise be invisible.

**Lineage: הציונות הדתית → נעם**, on the same footing as עוצמה יהודית. Noam held its 25th-Knesset seat
on the Religious Zionism joint slate (as it did in the 24th), and is running independently in 2026 —
structurally the same split Otzma made, so a 2022 הציונות הדתית voter switching to נעם is a real
transition the vote-switch rollups should be able to see.

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

**2026-08-01: `idi.org.il` was reachable this time, and reading it makes the −2 stronger, not
weaker.** The page does carry the full −3 language — *"תומכת בהקמת מדינה פלסטינית שבירתה ירושלים
מתוך סיום הכיבוש ופינוי ההתנחלויות"* and *"זכות השיבה לפליטים הפלסטינים"* — but it is **undated**,
and that text is the pre-2021 Joint List-era programme, not anything from Abbas's pragmatic turn. A
search for a 2026 רע"ם platform from the party's own source returned nothing. So the suspicion
recorded above ("may be inherited from old Joint List text") is now the likeliest reading rather
than a caveat, and **−2 stands**. Do not move this row on the IDI page.

One genuinely current item, recorded here but **not** scored: Abbas has publicly backed civilian
national service for Arab citizens — *"קידום מתווה שירות אזרחי יענה על הצרכים של הצעירים הערבים"* —
which is the opposite of בל"ד's `opposes-arab-conscription` and would be a real distinction between
the two rows. It is not tagged because the interview carries no publication date; date it and it
earns a tag. Note also that Abbas's "ריבונות" quote in the same interview is about **crime
organisations and the state's monopoly on force inside Israel**, not territory — it is not a
security-axis input, and reads like one at a glance.

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

- **הליכוד** `bibi` · 1 / 2 / 2 · traditional — as above, including `instrumentally-clerical`.
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

**נעם's logo is the same case as זהות's and likewise needs no code change — also verified, not
assumed.** The Wikimedia SVG is a `#003369` navy wordmark between two `#00b2ef` cyan bars, and
**45.3% of its opaque pixels are perceptually dark**, so the wordmark would be close to invisible on
the `#161B22` cards if shown untouched. Measured in a real Chromium against the live URL:
`recolorLogoForDark()` lifts the navy to `#a7d2ff` (luminance 0.17 → 0.80, hue preserved) and leaves
the cyan alone (0.567, already above the threshold), taking the dark fraction to **0%**. The
cross-origin load with `crossOrigin="anonymous"` did **not** taint the canvas — that is the half
worth re-checking on any new host, because a tainted canvas throws, `logoEl` swallows it, and the
logo renders dark with no error anywhere. Note this file lives under `/wikipedia/he/` rather than
`/wikipedia/commons/`, like most of the party logos here — same host, same
`access-control-allow-origin: *`. **Do not add it to `OUTLINE_CLUBS`**, for the reason given above.

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
- **ביחד's `security`** is the only NULL axis on a Jewish *upcoming* party (המחנה הממלכתי carries a
  NULL security among the frozen previous rows, for the same "no stated position" reason). It
  resolves only if the components merge or publish a joint position — or splits into two rows if the
  list dissolves. **Re-verified 2026-08-01: still no joint platform**, and the dissolution watch is
  still live, so the split branch is the likelier one.
- **רע"ם's `security`** should move to −3 if the stronger platform is verified from the party's own
  source. **2026-08-01: it still cannot be.** `idi.org.il` is now reachable and does carry the −3
  language, but undated and reading as pre-2021 Joint List text; no 2026 platform exists from the
  party's own source. Treat the IDI page as *not* sufficient evidence for this move.
- **בית ציוני – המילואימניקים launches its platform on 2026-08-05.** This is the dated resolution
  of the weakest number on the page — `economic +1` resting on Hendel's personal record with no party
  document. Read it on the day and rescore. The `bloc` question is closed: the Gantz merger collapsed,
  the Trooper merger completed, and `unaligned` holds.
- **The row is still seeded as `המילואימניקים`** while the list now runs as
  **בית ציוני – המילואימניקים**. Renaming orphans votes, so it is an admin-UI action taken when the
  ballot name is final — the same standing decision as נעם below.
- **הדמוקרטים's `two-state` tag is not supported by the party's own platform** and needs a ruling:
  drop it, or keep it and record that it rests on Golan's personal position rather than the document,
  as ישר's entry already does for the mirror case. No axis is affected. Details under that entry.
- **כחול לבן has six known party documents and two have been read.** The four unread ones are listed
  under its entry; `kachollavan.org.il` returns 403 to automated fetching, so they need to be fetched
  by hand. One of them postdates every classification pass on that row. It is also polling at ~1%,
  below the threshold, and losing people to בית ציוני – המילואימניקים.
- **נעם is campaigning as `נעם לישראל`** ("Noam for Israel") for the 26th Knesset. The row is seeded
  under the plain `נעם` and it is deliberately *not* renamed yet: lists are not final, a rename
  orphans votes (see the warning above), and an admin can do it in one edit if the longer name is
  what appears on the ballot.
- **נעם's `economic` is the only NULL on that axis** and is a "no platform yet" NULL, not a
  scoped-out one. It must be revisited if they publish any fiscal position.
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
| 2026-07-27 | Zehut `bloc` corrected `unaligned` → `bibi` (criticising Netanyahu ≠ leaving his bloc) |
| 2026-07-29 | נעם — Noam added to `upcoming_parties`; first NULL on the `economic` axis |
| 2026-07-30 | revision 10 — Likud audited against the voting record: religiosity +1 → **+2** (kashrut monopoly restored by statute, religious funding expanded); economic **+1 confirmed** (the import reform is real liberalizing, not rhetoric). Both tables |
| 2026-08-01 | revision 11 — כחול לבן's conscription programme found on `sherut4all.com`: 4 tags + the `universal-conscription` family added, **no axis moved**. Source URLs added to five entries. Freshness sweep: Beiteinu re-verified, נעם's economic NULL re-verified, ביחד's security NULL re-verified, רע"ם's IDI basis found undated and rejected, and המילואימניקים found to have merged into בית ציוני – המילואימניקים with its platform due 2026-08-05 |
| 2026-08-01 | revision 12 — הדמוקרטים read against its own eight platform documents for the first time: 8 tags + the `universal-conscription` family added, **all three axes confirmed and unmoved**, and `two-state` flagged as unsupported by the platform |
| 2026-08-01 | revision 13 — all six כחול לבן documents read (downloaded by hand past the 403). **religiosity −1 → −2** on the education programme's core-curriculum funding condition and state-haredi default; `core-curriculum`, `state-haredi-education`, `reservist-focused` added. security +2 and economic 0 verified against the documents and unmoved; the −2 band text corrected to stop implying civil marriage is required |
