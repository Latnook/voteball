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

**Why the classification `UPDATE`s are unconditional.** The name and `logo_url` columns in `seed.sql`
are admin-ownable: each row carries an `admin_edited TEXT[]` column listing which of those columns a
human has actually changed through the admin UI, and the per-table `UPDATE` skips writing a column
already listed there. The six classification columns carry no such check — they are written every
time, unconditionally. Production is always already seeded, so a guard would make every edit to these
columns unreachable there — the whole reason the file previously grew by appending patch statements.
Unconditional is safe for these six columns specifically because **nothing in the app ever writes
them**: the admin party endpoints only rename. Names and logos are the opposite case for exactly the
opposite reason — admins *do* edit those live, and `admin_edited` is what stops a re-seed from
destroying that edit. See `services/backend/CLAUDE.md` and
`docs/design/2026-08-12-seed-sql-declarative-design.md` for the full mechanism.

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
> grep -A20 'INSERT INTO seed_previous_parties VALUES' services/backend/seed.sql
> grep -A20 'INSERT INTO seed_upcoming_parties VALUES' services/backend/seed.sql
> ```
> When the tables here and `seed.sql` disagree, **`seed.sql` is right.**

### `economic` — how much the state should do

Negative is left (more state), positive is right (less state).

| | meaning | parties |
|---|---|---|
| **+3** | Libertarian: shrink the state as a matter of principle, not just policy | זהות `[u]` |
| **+2** | Privatizing: actually withdraws the state — sell Ashdod Port and Haifa Airport, end child allowances from the fifth child | ישראל ביתנו |
| **+1** | Liberalizing *fused with* real state expansion — trust-busting, subsidies, targeted spending | הליכוד, ישר `[u]`, ביחד `[u]`, המפלגה הכלכלית `[u]`, אל הדגל `[u]`, בית ציוני - המילואימניקים `[u]`, המחנה הממלכתי `[p]` |
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
| **+2** | No Palestinian state **plus** a territorial claim — sovereignty over security-essential areas, settlement expansion, preemptive doctrine, taking territory in Gaza | הליכוד, ישראל ביתנו, כחול לבן `[u]`, אל הדגל `[u]`, בית ציוני - המילואימניקים `[u]` |
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
| **0** | Status quo — no active religion-state agenda in either direction | *(none)* |
| **−1** | Pluralist: soften the monopolies without disestablishing | המחנה הממלכתי `[p]` |
| **−2** | Strong separationist: **core curriculum as a funding condition**, break the monopolies, universal conscription; civil marriage is typical but *not* required — ישר and כחול לבן sit here without it | ישר `[u]`, ביחד `[u]`, כחול לבן `[u]`, המפלגה הכלכלית `[u]`, אל הדגל `[u]`, בית ציוני - המילואימניקים `[u]`, יש עתיד `[p]`, העבודה `[p]`, מרצ `[p]` |
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
the value was simply missing, and the Political Lean tab computes from intended-vote (`upcoming_parties`)
ballots, so without it on `upcoming_parties` the feature renders nothing (`previous_parties` was scored
too, for the same reason every axis is scored on both tables: each row still needs to answer to its own
election). Same reasoning applied to בל"ד's religiosity, whose programme is dated 2018 and unchanged,
so it was equally their position at the previous election.

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

**2026-08-11 — the October 7 commission framework. Read, deliberately not tagged, and the reason is
about the tag rather than the party.**
[מתווה ישר לוועדת חקירה ממלכתית](https://yasharwitheisenkot.com/wp-content/uploads/2026/08/%D7%9E%D7%AA%D7%95%D7%95%D7%94-%D7%99%D7%A9%D7%A8-%D7%9C%D7%95%D7%A2%D7%93%D7%AA-%D7%97%D7%A7%D7%99%D7%A8%D7%94-%D7%9E%D7%9E%D7%9C%D7%9B%D7%AA%D7%99%D7%AA-%D7%9C%D7%98%D7%91%D7%97-%D7%94-7-%D7%91%D7%90%D7%95%D7%A7%D7%98%D7%95%D7%91%D7%A8-%D7%98%D7%99%D7%95%D7%98%D7%94-%D7%9C%D7%A9%D7%99%D7%AA%D7%95%D7%A3-%D7%94%D7%A6%D7%99%D7%91%D7%95%D7%A8.pdf)
is not a manifesto plank but a drafted government decision: a commission under **§1 of the
Commissions of Inquiry Law 1968** — the clause that makes it *ממלכתית* — with the **President of
the Supreme Court** appointing the chair and all five members, scope running back a decade to the
end of צוק איתן, sub-committees on intelligence and security doctrine, an interim report within a
year, and ₪25m plus 25 temporary posts. It covers the political echelon, hostage-deal
decision-making including the ground maneuver, the government's own הסברה apparatus, Knesset
oversight, and the implementation record of every prior commission back to אגרנט.

**`state-commission-of-inquiry` was considered and rejected, because the tag does not discriminate.**
It sits on 1 of 18 rows (אל הדגל), earned there from a *slogan* — *"מי שכשל צריך ללכת הביתה"*.
Wanting a state commission is close to a universal opposition position, so a tag held by one or two
parties is recording which documents happened to be read, not which parties hold the position.
Adding a second such row would have made the tag look like a finding while measuring audit coverage.
The distinction actually worth keeping is the one a tag cannot carry: אל הדגל wants a commission,
ישר has drafted the statute. That belongs here, in prose.

Two caveats for the next pass: the document is a **draft open for public comment until 2026-10-07**,
and it is authored by two outside figures — גדי מוזס, a captivity survivor from ניר עוז, and
עו"ד גיל אבריאל, formerly the National Security Council's legal adviser — published by the party as
its own מתווה. First-party enough to read as the party's position; check whether a final version
replaced it.

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

**`two-state` was challenged on 2026-08-01 and survives. Keep it.** The platform papers never
use the words מדינה פלסטינית — they commit to *"מהלך מדיני אחראי מול הפלסטינים"*, to
*"הסדרים מדיניים"*, and to *"אלטרנטיבה שלטונית מתונה"*. Read alone, that looked like the same
statehood-silence the page records for ישר, whose entry says the omission is deliberate and scores
from the leader's statements instead. It is not the same, and three independent lines of evidence
say so:

- **The party's own platform text names the state.** A far-left critique
  ([zoha.org.il](https://zoha.org.il/145596/), 2026-05-22) attacking the Democrats for *not* being
  genuine two-staters quotes them directly: *"בהגדרת גבולות קבע ברורים תוך שמירה על רוב יהודי מוצק,
  פירוז מלא של **המדינה הפלסטינית העתידית** – ללא צבא או איום טרור ובשליטה ביטחונית ישראלית מלאה"*.
  A hostile source quoting a position against interest is strong attribution.
- **The chairman states it as the party's vision**, not as a personal view: *"החזון זה שתי מדינות
  לשני עמים"*, and he has said he entered politics to promote separation leading to two states within
  a regional framework.
- **The realized top six was audited candidate by candidate on 2026-08-01**, and four of the six
  campaign on it explicitly:

  | # | candidate | position on two states |
  |---|---|---|
  | 1 | יאיר גולן (chair) | **explicit** — *"החזון זה שתי מדינות לשני עמים"* |
  | 2 | נעמה לזימי | **explicit** — a leading advocate; also anti-settler-violence, anti-outpost, authored a national peace-day bill |
  | 3 | גלעד קריב | **explicit** — two states alongside religious pluralism and Jewish-Arab partnership |
  | 4 | אפרת רייטן | **none stated** — her own site carries no conflict position at all; democracy, rule of law, judicial reform, labour and welfare |
  | 5 | יאיא פינק | **none stated** — שוויון בנטל protest leadership, social justice at the Histadrut, religious pluralism |
  | 6 | גבי לסקי | **explicit, and to the party's left** — two states *and* ending the occupation, from Meretz |

  The two silences are **division of labour, not dissent**: both hold domestic portfolios and neither
  has campaigned against the position. And לסקי at #6 is the tell in the other direction — she
  carries the "end the occupation" language the party itself declines to use, which is precisely the
  −1/−2 boundary below.

**This is also why `security` is −1 and not −2, and the band table was right.** The −1 band reads
"Zionist two-staters", which is exactly a two-state position conditioned on a solid Jewish majority,
full demilitarization and permanent Israeli security control. The −2 band requires "two-state **with
an end to the occupation**" — and the critique's sharpest point is that the word כיבוש never appears
in the Democrats' material at all. The party is where the rubric says it is; the papers simply
lead with security and anti-annexation framing rather than with the endpoint.

Golan's own political plan (N12, 2026-06-29) fits the same shape: recognition of a Palestinian
technocratic government replacing Hamas, PA reform into *"גורם שלטוני מתון ואפקטיבי"*, and
*"עצירת הסיפוח"* — mechanism first, endpoint assumed rather than proclaimed.

**2026-08-11 — two further papers (מילואימניקים, שיווין מגדרי) bring the corpus to ten. No axis
moved; two tags added.**

- **religiosity −3 reached from a third motive.** The axis design's Decision 5 has this row at −3
  from *pluralism* (Kariv, Fink, Dabush) rather than anti-clericalism. The gender paper arrives at
  the same −3 from neither: women's structural disadvantage in religious divorce —
  *"חשופות לסחטנות, לתלות ולסרבנות גט"* — cancelling every expansion of rabbinical-court
  jurisdiction and opening a full civil marriage and divorce track. Same direction, third road.
  This is the axis-records-direction/tags-record-motive rule doing real work on one row.
- **`gender-equality` added — a new tag; the vocabulary had nothing for it.** Not a values
  statement: a self-binding zipper list, a **statutory 40% quota** for women in the Knesset enforced
  by docking party funding, 40% in director-general and senior public-service posts, the right to
  equality entrenched in a Basic Law, and an independent national authority against violence against
  women with the definition widened to economic, psychological and digital violence.
- **`reservist-focused` added, and this row is the tag's first cross-bloc holder.** The other four
  (ישר, כחול לבן, אל הדגל, בית ציוני) are all security-hawk centre-or-right rows at security +1/+2;
  this one is `opposition` at −2 / −1. That is what makes the tag worth carrying here — a tag four
  hawks share says little, one that a social-democratic dove also earns records that the
  reservist-burden question crossed the bloc line. It clears the standard כחול לבן set in revision
  13 (a costed benefits package, not rhetoric): ₪1,000/day for combat reservists, unified
  entitlements replacing the current maze, a resilience-and-rehab basket, state-guaranteed loans for
  self-employed reservists, ~₪10bn/yr, against a target of 21–30 reserve days a year.
- **It does *not* earn the `reservist-movement` family**, on the ישר precedent — that family records
  what a party *is*, not what it has a policy about.
- **`sanctions-on-non-servers` was considered and rejected**, and the distinction is the same one
  that separates כחול לבן from this row. The paper does say *"נאכוף את חובת הגיוס ונוודא שכסף ציבורי
  לא מממן השתמטות"* — but that targets the **institutions**. כחול לבן earned the tag for the
  opposite: fines and reduced individual entitlements, explicitly *"עבודה מול הפרט ולא הישיבות"*.
  Tagging both identically would erase a real difference.
- **Open: who "additional populations" means.** The conscription clause reads
  *"גיוס אלפי חרדים והרחבת גיוס של אוכלוסיות נוספות"*. The phrase is unspecified on a row carrying
  `jewish-arab-partnership` as a family with בשיר at #10. Either it includes Arab citizens — which
  sits against the partnership platform — or it is deliberately vague to avoid saying so. Recorded
  rather than tagged; revisit if the party clarifies.
- **security −1 re-verified mechanically at ten papers.** מדינה פלסטינית, פלסטינית, כיבוש and
  שתי מדינות each occur **0 times** in both new papers, so the −1/−2 boundary argument above still
  holds on the full corpus. But the reservists paper presses on it harder than anything the party
  has published — an international stabilizing force in Gaza and Lebanon *"במקום החזקת השטח בידי
  צה"ל"*, plus evacuation of West Bank outposts and farms, which is stronger than the security
  paper's defunding language. Two documents now lean on this boundary. **If a third does, re-open
  the −1.**

Sources: the ten papers below, the first eight read 2026-08-01 and the last two 2026-08-11, all
first-party (`democrats-media.s3.us-east-1.amazonaws.com`):
[מדיני־ביטחוני](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%93%D7%99%D7%A0%D7%99+%D7%91%D7%99%D7%98%D7%97%D7%95%D7%A0%D7%99+(1).pdf),
[כלכלי־חברתי](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9B%D7%9C%D7%9B%D7%9C%D7%99+%D7%97%D7%91%D7%A8%D7%AA%D7%99+(2).pdf),
[דת ומדינה](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%93%D7%AA+%D7%95%D7%9E%D7%93%D7%99%D7%A0%D7%94.pdf),
[דמוקרטיה ומשפט](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%93%D7%9E%D7%95%D7%A7%D7%A8%D7%98%D7%99%D7%94+%D7%95%D7%9E%D7%A9%D7%A4%D7%98.pdf),
[חינוך](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%99%D7%A0%D7%95%D7%9A.pdf),
[להט"ב](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9C%D7%94%D7%98%D7%91+(2).pdf),
[חיסול הפשע המאורגן](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%99%D7%A1%D7%95%D7%9C+%D7%94%D7%A4%D7%A9%D7%A2+%D7%94%D7%9E%D7%90%D7%95%D7%A8%D7%92%D7%9F.pdf),
[סביבה](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%A6%D7%A2+%D7%A1%D7%91%D7%99%D7%91%D7%94.pdf),
[מילואימניקים](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%99%D7%9C%D7%95%D7%90%D7%99%D7%9E%D7%A0%D7%99%D7%A7%D7%99%D7%9D.pdf),
[שיווין מגדרי](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%A9%D7%99%D7%95%D7%95%D7%99%D7%95%D7%9F+%D7%9E%D7%92%D7%93%D7%A8%D7%99.pdf).
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
national mental-health and trauma authority, and
[*עולים צפונה*](https://kachollavan.org.il/wp-content/uploads/2026/08/20678_14_Amud-Atar.pdf), the
Galilee and Kiryat Shmona programme (2026-08, read 2026-08-11). **All seven party documents have
now been read.**

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
בית ציוני - המילואימניקים.

**2026-08-11 — *עולים צפונה*, the seventh document. No axis moved and no tag was added.** It is
drafted as a bill: a national target of **half a million more Israelis in the Negev and Galilee
within five years, and half of all Israeli citizens living there by 2048**, under it a costed
Kiryat Shmona package — a state-funded ER within a year, מכללת תל חי elevated to
*"אוניברסיטת קריית שמונה"* with its own Education Ministry budget line, transport and Highway 6
discounts with rail-station priority, a five-year full ארנונה exemption for businesses, tourism and
restaurant work reclassified as *עבודה מועדפת*, a 50% ארנונה discount for under-30s, and remote-work
accommodations for state employees in the north.

- **economic 0 holds.** The temptation is to read a large spending commitment as a move left. It
  isn't one: the economic axis measures the state's role in the economy *broadly*, and this is
  geographically targeted regional development — endorsed in some form across the whole spectrum —
  with mechanisms split between public investment (ER, university) and tax relief (the ארנונה
  exemption and discounts). Nothing here decides the row away from 0, in either direction.
- **security +2 holds.** The document opens by tying border communities to security doctrine
  (*"לשנות את תפיסת הביטחון... יישובי הגבול ואזורי הספר"*), which is the same trap the
  `homeland-security` note above records for ישר: a civil document whose framing invites a
  security-axis reading it does not support. Nothing on statehood, the territories, Gaza or borders.
- **`periphery-development` was considered and rejected — the tag was broken, not the fit.** It sat
  on 3 of 18 rows, yet this page *already documents* periphery programmes for two rows that didn't
  carry it (הדמוקרטים's economic paper, "periphery investment"; אל הדגל, "massive periphery
  infrastructure"). So the tag was recording which documents were read closely, not which parties
  hold the position, and a fourth arbitrary member would have made the analysis silently imply the
  other two lack it. **The 2026-08-11 sweep retired it outright**: none of its three holders had any
  justification recorded on this page, while *עולים צפונה* — half a million people to the Negev and
  Galilee in five years — is the most explicit periphery programme any party has published. It is
  recorded above in prose, which is now where such programmes live. See "The vocabulary sweep".
- **התיישבות here means the Negev and Galilee, not the West Bank.** This row carries
  `pro-settlement`, earned from the security doctrine and meaning territorial settlement. This
  document uses התיישבות repeatedly — *"השקעה בצמיחה, בהתיישבות, בביטחון"* — about communities
  inside the Green Line, i.e. internal demographic dispersal. Anyone auditing this row by grepping
  the corpus for התיישבות will hit these and read them as corroboration of a tag they have nothing
  to do with.

**`kachollavan.org.il` returns 403 to a bare `curl`, but not to a browser-shaped request** — sending
a normal desktop `User-Agent` **and** a `Referer: https://kachollavan.org.il/` header fetched both
2026-08 PDFs at 200 on 2026-08-11. The earlier "downloaded by hand" note was a workaround for a
block that only stops default tooling, so this domain does not need manual retrieval. One caveat for
the next pass: **the education programme is a scanned-image PDF** — `pdftotext` yields 7
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
territorial claim at all:** the words ריבונות, סיפוח and התנחל do not appear in the platform at
all — zero occurrences of each — and Gaza is handed to an international body rather than held.

Judea and Samaria appear **four** times, and none of the four is a claim: the section-5 plank
("ייצוב ביטחוני וכלכלי בשיתוף פעולה עם ירדן"), a pre-1967 historical aside ("כשירדן ומצרים עוד
שלטו ביהודה ושומרון"), and two Border Police deployment items ("הקצאת 4,000 לוחמי מג״ב ליו״ש בלבד",
"כל פעילות הבט״ש ביו״ש תעבור לסמכות המשטרה"). Security posture in a territory, not a position on
who holds it.

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
2026-08-02 against the live page, string by string.** Fifteen sourced claims hold verbatim — the
Ashdod/Haifa privatizations, child allowances from the fifth, the ₪70B→₪95B defence budget,
*"לא יתקיים כל מו״מ על ירושלים"*, אפס הכלה, the preemptive-strike doctrine, cutting Gaza's
water/electricity/fuel, Gaza to an international body, all four religion-and-state planks, the
statutory ban on an indicted person forming a government, and the −3 anchor stated outright:
*"אנו מאמינים כי צריך להפריד דת ממדינה"*.

**One did not: "Judea and Samaria appears exactly once" was wrong** — it appears four times (see
above). The count was the evidence for "no territorial claim", so it needed replacing rather than
just correcting; the claim now rests on ריבונות / סיפוח / התנחל scoring zero occurrences each,
which is what "makes no territorial claim" actually asserts and is not sensitive to how often the
region is named in passing. **No axis moves** — every mention is security deployment or history.
This is currently the only party row on the page verified against a live primary source.

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
- **סוכות #5 and רחמים #7** (Yesha Council CEO) keep `settler-movement` and `annexationist`
  (the latter folded into `sovereignty-annexation` on 2026-08-11; the reasoning is unaffected).
- **טל #6 and וולדיגר #8** are deliberately **not** tagged. One advocacy figure at sixth is not a
  foreign-policy orientation, and one welfare MK at eighth does not move `not-economy-focused` —
  there is still no economic figure anywhere on this list. Tagging thin evidence is how a tag set
  stops meaning anything. *(That tag was later removed from this row entirely — not on the strength
  of a candidate, but on the party's own 6-page economy paper; see the 2026-08-11 entry below. The
  judgement recorded here was right about the candidate and wrong about the party.)*

economic 0 with `claims-economically-liberal` already captures the gap between Smotrich's rhetoric
and his finance-ministry record.

**The thirteen `zionutdatit.org.il/hityashvut/` pages, read 2026-07-27: no axis moves either.** Same
reason as the primary — security +3 and religiosity +3 are already at their poles. The pages confirm
them at maximum: sovereignty defined as "החלת החוק הישראלי על יהודה, שומרון ובקעת הירדן" with the
Oslo A/B/C division dismantled, E1 approved to "תקבור את רעיון המדינה הפלסטינית", 50 new recognised
settlements in 2.5 years, ~50,000 housing units, 30,000 dunams declared state land.

`anti-two-state` **was missing and is now added.** The row carried `annexationist` (folded into
`sovereignty-annexation` by the 2026-08-11 sweep) but never the plain veto, which is odd for the party that states it most explicitly — and Yashar carries
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

**2026-08-11 — read against the party's own 13 platform PDFs (`zionutdatit.org.il`, 2021-12 and
2022-10). No axis moved. `not-economy-focused` REMOVED from both rows; one tag added.**

These are the **2022-election** platform. The party has published nothing for 2026, so they are
directly authoritative for the `previous_parties` row and only indicative for `upcoming_parties`;
`basis` stays **`record`** on the upcoming row rather than becoming `platform`.

- **`not-economy-focused` is removed, and the repo already contradicted itself about it.**
  `docs/design/2026-07-30-party-families-club-traits-design.md` records that the *family* of that
  name was replaced by `sectoral-budgeting` here because it "was simply false: Smotrich has held the
  finance ministry since December 2022" — but nobody removed the **tag**, so `seed.sql` kept
  asserting what the design doc called false. The entry above already flagged it as "the strained
  tag on this row". A dedicated 6-page **כלכלה** paper settles it: public-sector reform (compulsory
  arbitration in essential services, a ban on political and solidarity strikes, abolition of tenure —
  *"ביטול מוסד הקביעות בשירות המדינה"*), deficit reduction explicitly **not** via tax rises, simple
  uniform taxes cutting exemptions in exchange for *"הפחתת מיסים אוניברסלית רחבה"*, competition
  between hospitals with government hospitals spun out as independent מלכ"רים, education devolution
  and parental school choice, and deregulation including cutting the power of professional guilds
  that create *"חסמי כניסה למקצוע"*. A second 7-page **רווחה** paper adds a workfare frame
  (*"במקום קצבאות שונות יוכלו אנשים להשתכר בכבוד"*, and *"לא ניתן להמשיך במודל הקיים של מתן
  קצבאות"*) plus a mental-health programme. That is a developed economic doctrine, whatever one
  makes of it.
- **`economic` stays 0 all the same, and this is the rule working rather than an oversight.** The
  revision procedure is explicit that where rhetoric and record diverge the *number* records the
  revealed position and a *tag* carries the gap. This row's `basis` is `record`, and the record is a
  finance ministry directing money to one sector. So the 13 papers do not move the number — they
  give `claims-economically-liberal` far better evidence than it has ever had, which previously
  rested on a settlement-budget document. **Not economy-focused and economically-liberal-in-rhetoric
  are different claims; only the second was ever true here.**
- **`death-penalty-for-terrorists` added — and this retires the "single-holder" note on
  עוצמה יהודית below.** The טרור paper: *"הפרקליטות תונחה להגיש כתבי אישום כנגד מחבלים בבקשה
  לעונש מוות"*. The tag now has two holders, both far-right bloc partners, which is a coherent
  grouping rather than a party-specific label.
- **`judicial-overhaul` and `annexationist` are confirmed against first-party text** for the first
  time. The משפט paper's override clause would let the court strike a Knesset law only by a
  **unanimous** decision of all justices, with no power at any majority to strike a Basic Law; the
  טרור paper separately abolishes the reasonableness ground so the HCJ cannot review house
  demolitions. Both were previously scored from the record alone.

**`reservist-focused` was initially withheld and then added the same day by the vocabulary sweep.**
The מילואים paper is a costed reservist land-benefit package (discount ceiling doubled ₪75k → ₪150k,
further 5–10% for young couples), the same *shape* of evidence that earned the tag for כחול לבן. It
was first held back on two grounds — the paper is from 2021, and a sixth holder would put the tag on
a third of the table — and the repo owner had predicted exactly that breadth
(*"most of the parties claim to be reservist focused"*).

**The sweep reversed it, and the reason the reversal is right matters more than the tag.** Withholding
was *inconsistent*: the same 2021 corpus was used the same day to confirm `judicial-overhaul`, confirm
`sovereignty-annexation` and remove `not-economy-focused` from this row. Evidence cannot be sound
enough for three findings and too stale for a fourth. The staleness caveat attaches to the whole row —
which is why `basis` stays `record` — not to one tag. And breadth turned out not to be dilution: with
this row added, the tag's six holders span all three blocs, putting הדמוקרטים (−2/−1/−3) and this
party (0/+3/+3) under the same label, which records something the axes cannot. See
"The vocabulary sweep".

Sources: 13 PDFs at `zionutdatit.org.il`, read 2026-08-11 —
כלכלה, רווחה, משפט, זהות יהודית, דיני משפחה, מסתננים, התיישבות ריבונית, חינוך, טרור, טבע וסביבה,
פשיעה חקלאית, מילואים, and יהדות התפוצות וקליטת עליה (2022-10).
**Twelve of the thirteen are image-only** — `pdftotext` returns 34 bytes from each (the party name,
set as text; everything else is a picture), which is the exit-0 failure mode
`services/backend/CLAUDE.md` warns about. They are tall single-page infographics, 595pt wide by up
to 4,500pt, so they must be rendered and sliced (`pdftoppm -r 150` then crop to ~1,500px bands) and
read visually, or OCR'd with `tesseract -l heb`. Only יהדות התפוצות has a real text layer.

### עוצמה יהודית — Otzma Yehudit · `bibi` · 0 / 3 / 3 · religious_zionist

`kahanist`, `jewish-supremacist`. religiosity +3 for the same explicit halakhic-state vision as
Religious Zionism.

**2026-08-11 — read against 30 of the party's own news posts (`ozma-yeudit.co.il`, 2026-05-26 to
2026-08-04). No axis moved; six tags added, 5 → 11.**

**This row had been the thinnest in the table, and the reason matters.** It carried five tags and a
two-line entry because it was scored from general knowledge of the party, never from party output —
it publishes **no platform**, so earlier passes had nothing to read. It does publish a continuous
stream of ministerial-action posts, which is a *record* source, not a platform one. `basis` therefore
stays **`record`** — correctly, and now far better evidenced than when it was a placeholder.

- **`gun-rights` added — the single best-documented position here**, in 8 of the 30 posts, with
  first-party numbers: 6 localities approved in 2021, none in 2019/2020/2022, 23 in 2023, 21 in
  2024, 80 in 2025, and **126 in 2026 alone**; **280,000+ personal licences** and 200+ localities
  since the reform widened. Also a regulatory expansion to ex-police, prison officers, serving
  combat soldiers and firefighters. זהות was the only holder; the motive differs (libertarian there,
  armed-citizenry-for-security here) and that is exactly what the axis/tag split is for.
- **`judicial-overhaul` added**, closing a conspicuous gap against its own bloc partner
  הציונות הדתית, which already held it. Ben Gvir: *"אמשיך בכל הכוח עד שנעביר את הרפורמה המשפטית"*.
- **`pro-settlement` and `sovereignty-annexation` added.** A cornerstone ceremony for a new
  neighbourhood at חיננית in northern Samaria and a visit to חוות גלעד, with the sovereignty claim
  stated as doctrine: *"ריבונות לא נקבעת רק בהחלטות ממשלה, אלא במציאות שקובעים כאן יום־יום… זו
  המשמעות של ריבונות: לבנות, להתיישב ולהגן"*. Note this is the **opposite** of the כחול לבן
  התיישבות trap recorded above — here the word does mean West Bank settlement.
- **`temple-mount-centred` added.** The chairman ascended on Tisha B'Av, with a second minister
  (וסרלאוף) the same morning, framed as an achievement of his tenure: *"אנחנו רואים התקדמות ענקית
  גם בהר הבית… יהודים שמתפללים, מרגישים כאן בעלי הבית"*.
- **`death-penalty-for-terrorists` added — a new tag, and the only new one.** Cited across three
  posts as the party's own legislative achievement (*"במסגרת חוק עונש מוות למחבלים העברנו"*). No
  existing tag covered capital punishment; `hardline-on-gaza` is about military conduct. It was
  introduced as a deliberate single-holder tag on the `opposes-hostage-deals` precedent: the position
  is genuinely distinctive, not a widely-held one that is merely under-recorded. That is the
  distinction that decided against `periphery-development` on the same day.

  > **Superseded later the same day.** הציונות הדתית's טרור paper carries the same position —
  > *"הפרקליטות תונחה להגיש כתבי אישום כנגד מחבלים בבקשה לעונש מוות"* — so the tag has **two**
  > holders, both far-right bloc partners. It is no longer single-holder and the "contested within
  > the bloc" half of the rationale was wrong; the two partners agree on it. The tag is better for
  > it: two of eighteen is a grouping, and it now distinguishes this pair from הליכוד, which sits in
  > the same bloc without the position.

**economic 0 and `not-economy-focused` are now confirmed by evidence rather than inferred.** Across
30 posts there is **no** economic content whatsoever — no tax, market, welfare, cost-of-living or
privatization position. Every budget figure is a security appropriation (₪497m diverting the 550
five-year plan into Shin Bet and police anti-crime units, tens of millions to relocate the northern
police HQ). Thirty posts of party output with zero economic content is about as strong as negative
evidence gets for that tag.

**Two things that look like axis evidence and are not:**

- **The muezzin-noise bill is not religiosity evidence.** Default prohibition on mosque loudspeakers
  without a permit, ₪50,000 fines, police power to confiscate the system. The religiosity axis is
  scoped to **Jewish** religion-and-state, and the bill's own sponsors frame it as public health
  explicitly — *"המואזין בעוצמות חריגות הוא לא עניין דתי, זו פגיעה בבריאות הציבור"*. It belongs to
  `jewish-supremacist`, which the row already carries, not to the axis.
- **Negev enforcement is recorded here and deliberately left untagged.** ~5,700 illegal structures
  demolished in a year, and planting on ~6,000 dunam under Bedouin ownership claims in court,
  described as land control outright (*"אנחנו בעלי הבית"*). It is heavily evidenced and distinctive,
  but no existing tag covers it and minting one with no comparator row is what the
  `periphery-development` finding argues against. `jewish-supremacist` plus `far-right` already
  position the row; revisit if a second party gives the tag something to discriminate between.

**`bibi` confirmed, with a bargaining condition worth recording.** Ben Gvir wrote to Netanyahu
setting a **precondition for joining the next government**: immediate dismissal of Attorney General
Baharav-Miara, plus a commission with criminal-investigative powers over her conduct — *"ללא קיומו
של תנאי זה, לא נוכל להיכנס לממשלה"*. The letter presupposes a Netanyahu government, so the bloc is
unchanged; what is new is that the row now has a stated coalition condition, which no tag carries and
which could matter if it is ever acted on.

Sources: 30 posts at `ozma-yeudit.co.il`, published 2026-05-26 to 2026-08-04, read 2026-08-11.
Ordinary WordPress pages — no retrieval trap, `.elementor-widget-theme-post-content` carries the
body text.

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

### אל הדגל — El HaDegel · `unaligned` · 1 / 2 / −2 · secular

**Three sources, and they are not interchangeable.** The **platform PDF** (`מצע אל הדגל`,
28.05.2026) carries four policy programmes — security, education, government/law, economy. The
**vision chapters at `elhadegel.co.il/about-us`** are a *separate body of text*, not a rendering of
that PDF: only the הקדמה overlaps, and קיר ברזל, דור הניצחון, אחדות העם, שבירת הגושים,
האתגר הדמוגרפי and ישראל 2050 appear nowhere in the PDF. The **education policy document** is a
third, and it is where the religiosity number actually lives.

**Two retrieval traps here, and the row has been wrong from each in turn.** Both PDFs are
**image-only** — `pdftotext` returns 25 bytes from 25 pages and 7 bytes from 7 pages, an exit code
of 0 and one newline per page — so both have to be read visually, and a pipeline checking only
whether the command failed will read that as a clean extraction. And the two bodies of text overlap
just enough at the הקדמה to look like the same document, which is how the education paper stayed
unread while the platform was treated as fully mined. `elhadegel.co.il` itself is **not** a
retrieval problem: it returns 200 to automated fetching and serves all six chapter headings in the
HTML, unlike `kachollavan.org.il`.

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

**economic was re-examined on 2026-08-10 and stays +1.** The website's economy card reads as +2 or
+3 doctrine — *"יוסרו כל הרגולציות והחסמים על השוק מלבד החיוניים"*, remove every regulation but the
essential ones, alongside the 30% cut. The programme behind it is not: negative income tax
expansion, targeted vocational training, differential support for weak regions, state infrastructure
investment and a strategic-industry push. Slogan at +2, substance at +1 — which is exactly the
fusion the crowded +1 band exists to keep visible. Recorded here because the *next* pass will find
that sentence and reach for +2 again.

religiosity **−2 (was 0, moved 2026-08-10).** The education policy document conditions state money
on the core curriculum — *"יישום תכנית 'חבילת הבסיס' תהווה תנאי לקבלת תקצוב חינוך מהמדינה (בכל
הרבדים, כולל בינוי)"* — and for institutions that will not comply, *"הפסקת תקציב הדרגתית אבל מוחלטת
לכל המוסדות שאינם עומדים בקריטריונים לחינוך ציבורי"*, after a five-year adaptation plan. That is the
−2 band's defining criterion, and the same evidence that moved כחול לבן −1 → −2 on 2026-08-01 and
בית ציוני - המילואימניקים 0 → −2 on 2026-08-08. It is entrenched rather than aspirational: the
package is legislated for ten years and repeal needs a special majority, and the base layer is 50%
of the curriculum nationally with 30% to local authorities, leaving the stream itself 20%.

**Decision 6 is not overridden — it is why this took a third pass to see.** Conscription stays off
this axis, and the exemption fight stays in `anti-conscription-exemption`/`universal-conscription`.
The 0 was scored on the platform and the website, where the education plank appears only as
*שכבת בסיס חובה בכל מוסד מתוקצב*; with conscription set aside, "mandatory core curriculum, offset by
a Values Pillar grounded in Jewish heritage plus community autonomy above the core" was a fair
reading of *that* evidence. The funding position — the second of the two fights this axis folds
together — is in the education document, which was never read. Exactly as the כחול לבן note below
warns, and now for the third row in a row.

The offset does not survive the precedent it is now measured against. כחול לבן held *a stated aim
that the public space express the state's Jewish identity* and still moved to −2 on the funding
condition; the autonomy here is explicitly the 20% *above* the base layer, the same bounded
devolution as B&W's local-authority Shabbat clause. A Jewish-heritage values component has now twice
failed to offset a funding condition in this document.

Held at −2, not −3: nothing about the Rabbinate, marriage, kashrut or Shabbat, and ישר and כחול לבן
both sit at −2 without civil marriage.

**Planks recorded 2026-08-10, all previously absent.** From the website chapters: a demand for a
**state commission of inquiry** into 7 October (*"מי שכשל צריך ללכת הביתה"*, `state-commission-of-inquiry`);
Basic Law **protections for a sitting PM** (`pm-immunity-protections`); a standing pre-committed
**territorial price** for attacks on the state (`territorial-price-doctrine`); and the demographic
chapter's haredi and Arab labour-market integration track, *"היעד איננו 'לגייר' אף קהילה"*
(`workforce-integration`). From the platform PDF: a **voluntary-emigration** benefits basket for
Palestinians choosing to leave, held distinct from זהות's `population-transfer` because it is
opt-in (`voluntary-emigration-incentives`).

**Those first two planks point opposite ways, and that is the finding, not a defect.** Demanding a
state commission of inquiry is the anti-Netanyahu marker; entrenching protections for a sitting PM
is the pro-Netanyahu one. For a party whose organising pitch is שבירת הגושים — refusing the
"רק ביבי"/"רק לא ביבי" binary in as many words — holding both is coherent, and it is the strongest
single piece of evidence for `unaligned` in any of the three sources. Note the platform PDF is
narrower than the website card here: an 8-year term cap with immunity confined to חטא ועוון,
misdemeanours. The tag records the website's broader claim; this sentence records the gap.

### בית ציוני - המילואימניקים — Zionist Home – The Reservists · `unaligned` · 1 / 2 / −2 · secular

**Read the name-collision warning above before touching this row.**

Source: the party's own full platform, *מצע מפלגת בית ציוני – נוסח מאוחד ומעודכן* (26pp,
`baitzioni-hamiluimnikim.org.il/wp-content/uploads/2026/08/Zionist-Home-Party-Platform-PDF.pdf`,
authored `בית ציוני`, created 2026-08-06 — the unified text incorporating every update to the
**תוכנית מגן דוד** launched at the joint list's Jerusalem conference on 2026-08-05). Read in full
on 2026-08-13; all four values below are cited to it.

**Revision 14 scored this row from press reporting, and said so.** It recorded that the platform had
no home on the open web, that four outlets' quotation of the מצע was standing in for the document
itself, and that "a later pass must not assume a party document was read." The document has since
been published, and it is roughly three times what the press covered — an entire religion-and-state
chapter, *מדינה יהודית לכולם*, went unreported in every outlet. **No axis moved when it was read**,
which is the part worth keeping: the press-derived numbers were right. What changed is eleven tags
and the standard of evidence behind all four values.

security **+2 — confirmed against the full platform, unmoved.** The מצע sets out a front-by-front
posture in its own words. Lebanon: hold *"קו הרכסים ששולט על יישובי הצפון"*, withdrawing only
against a Lebanese assumption of responsibility. Gaza: stay to the yellow line, enter and leave on
operational need, and *"אין שיקום בלי פירוז"* — no reconstruction without demilitarisation. The
Egyptian and Jordanian borders: *"יש להרחיב משמעותית את ההתיישבות בגבול המזרחי"*. Judea and Samaria:
encourage *"תפיסת רכסים גבוהים באמצעות מוצבים ונקודות אזרחיות בתיאום ואישור המדינה"*, with the
Jordan Valley named *"יעד לאומי ראשון במעלה להתיישבות ופיתוח"* and the contest over Area C an
explicit objective. That is the +2 band as written — a territorial claim without a sovereignty
claim, and it now rests on the document rather than on Hendel's remarks.

`anti-two-state` still rests on the statements (permanent control of Gaza on the West Bank model,
the Rafah crossing opening as *"establishing a Palestinian state on top of our heads"*). The
platform neither states the position nor contradicts it, so the tag stands on the older evidence.

Held below +3 on the same grounds as before, now checkable rather than inferred: **there is no call
for sovereignty or annexation anywhere in 26 pages**, and no population transfer. Note the platform
does carry a nationalist *domestic* programme — *"ייהוד הנגב והגליל כמשימה לאומית"* — but this axis
scores the conflict and the territory, not internal demography, and the parties that would plausibly
share that plank were never checked for it.

economic **+1 — confirmed against the full platform, unmoved.** It rested for months on Hendel's
centre-right record with no party document behind it; revision 14 confirmed it from press
paraphrase; the מצע's own wording now carries it. The liberalizing half is the *יוקר המחייה*
chapter: *"נפעל לפרק את מוקדי הכוח והמונופולים ונסיר חסמי ייבוא מיותרים"*, a move from
*"רגולציה חונקת"* to a trust-based model for small business, recognition of leading international
standards to kill duplicate certification, and breaking the concentration in land marketing by
devolving planning powers to municipalities.

**The state-expanding half is much larger than the press reported, and it is what puts
`welfare-state` in the families.** Public housing is under 2% of stock against ~12% in Europe, and
the platform commits to the Alaluf Committee's **110,000** units against fewer than 50,000 today —
more than doubling it. The 1958 חוק סעד is replaced outright by a new *חוק שירותי רווחה וביטחון
חברתי* creating an appealable right to welfare services. Disability allowances rise. Matching-funds
financing, which it argues sends unspent budget back to strong municipalities, drops to 10% for
socio-economic clusters 1–3 with a dedicated fund for the rest. Roughly ₪1bn outside the defence
budget goes to a post-trauma authority.

That combination is the +1 band as written — *liberalizing fused with real state expansion* — and it
is now the clearest case for that band on the page rather than the shakiest. **Not +2**: nothing
here withdraws the state the way selling Ashdod Port does. **Not 0 either**, despite the volume of
spending: the market-side commitments are specific and structural, not decorative. The one
right-leaning conditionality worth recording is that early-childhood support becomes
*"מותנה במיצוי כושר עבודה"* — conditioned on work-capacity utilisation — hence `workforce-integration`.

Their service-conditioned sanctions are severe but sectoral, not a general economic doctrine. Hendel's
formulation is that whoever does not serve "will not be able to vote or be elected, and will not
receive a shekel". **Conditioning the franchise on service** is a defining and unusual position,
hence `service-conditioned-citizenship`.

**The platform does not carry the franchise clause, and that gap is recorded rather than resolved.**
Its *סנקציות על עריקים* list is six items: tax and arnona discounts cancelled, housing benefits
(מחיר למשתכן, subsidised daycare) withheld, **driving licence revoked**, **exit from the country
barred**, public-sector and government posts refused, and funding withdrawn from educational
institutions that do not support service. Severe, and two of those are harsher than anything else on
this page — but none of them is disenfranchisement. The tag stays, because the statement was really
made and this axis records the revealed position; but the party's own document, which is both newer
and more authoritative, declines to write it down. A later pass should check whether the omission is
deliberate before treating the tag as platform-backed.

religiosity **−2 (was 0, moved 2026-08-08; re-examined against the full platform 2026-08-13 and
held).** The education chapter conditions state money on the core curriculum in as many words —
*"מימון ציבורי מלא יינתן אך ורק למוסדות חינוך שנושאים באחריות ציבורית מלאה, מפוקחים על ידי המדינה
ומלמדים ליבה באופן מלא"*, full public funding **only** for institutions under full public
responsibility, state supervision and teaching the core in full. That is the −2 band's defining
criterion verbatim, and it is the same evidence that moved כחול לבן −1 → −2 on 2026-08-01. It does
not stand alone: the party makes passing a conscription law a precondition for joining any coalition,
and Hendel campaigns on *"פירוק האוטונומיות במגזר הערבי והחרדי"* — dismantling the Arab and haredi
autonomies.

The platform pairs the funding condition with a build-out of the alternative, which is why
`state-haredi-education` joins כחול לבן here: **ממ"ח as the default** wherever a new haredi
institution is needed (*"הממ"ח כברירת מחדל"*), a five-year plan of classroom construction, teacher
training and scholarships, enforcement on private institutions, and compulsory registration zones to
end ethnic selection. Against that, `scholar-exemption-retained` records the honest complication:
the conscription chapter keeps a narrow exemption for demonstrated excellence in
*"ספורט, מדעים, מוזיקה ותורה"*, and proposes pioneering haredi yeshivas on the borders on the נח"ל
model. This is not a programme to end Torah study at state expense; it is one to condition it.

**The 0 was not a mistake at the time, and the reason it was wrong is the reason this axis is hard.**
This row had no platform at all until 2026-08-05, and the haredi-exemption fight is excluded from
this axis by the religiosity design doc's Decision 6 — so with conscription set aside there was
genuinely nothing left to score, and 0 was the honest reading. What arrived on the 5th was not a
conscription position but a *funding* position, which is the second of the two fights this axis
folds together. Exactly as the כחול לבן note below warns: the religion-and-state material alone
systematically under-scores a party, and the education chapter is where the real number lives.

**Held at −2, not −3 — but the reason it is held there changed completely on 2026-08-13, and the old
reason is now false.** Revision 14 wrote: *"they say nothing about the Rabbinate, marriage, kashrut
or Shabbat, and −3 requires ending the monopolies outright."* The unreported *מדינה יהודית לכולם*
chapter says a great deal about all four. It adopts Rabbi Shai Piron's **50:30:20 model**, splitting
religion-and-state across three layers:

- **50, the state layer** — minimum supervision of conversion and *"גיור מאיר פנים בנוסח בית הלל"*;
  and *"הסדרת הנישואין והגירושין... ומתן האפשרות לכל זוג לבחור כיצד להינשא, לצד הכרה בברית
  הזוגיות"*. That is **civil marriage**, and the LGBT chapter states it a second time —
  *"כל בני זוג יוכלו להירשם כנשואים במדינת ישראל ויוגדרו כנשואים לכל דבר"*.
- **30, the municipal layer** — *"כשרות ושירותי דת יינתנו על ידי הרשות המקומית ומוסדותיה"*, the local
  rabbinate chosen by the municipality, and the extent of Shabbat public transport set by it.
- **20, the community layer** — neighbourhood forums set Jewish content in schools above the core
  minimum, and decide local observance.

So four of the −3 band's concerns are answered in the separationist direction, and `civil-marriage`,
`kashrut-liberalization`, `religious-pluralism`, `municipal-devolution` and `communitarian-devolution`
all now apply. **The number still does not move, and the deciding criterion is funding.** −3 requires
*no state religious funding*; this platform expands it — *"הרחבת הסמכות והתקצוב של מוסדות דת ותרבות
מקומיים"* — and frames the whole model as *"לא איום על הצביון היהודי של ישראל, הוא הזדמנות לחזק
אותו"*: not a threat to Israel's Jewish character but a chance to strengthen it. **Devolving an
establishment is not disestablishing it.** A municipally-run rabbinate is still a state rabbinate; it
is simply a smaller and more locally accountable one. ישראל ביתנו at −3 wants the institution gone,
which is a different claim.

That leaves this row at the top of the −2 band rather than the bottom of −3, and it is worth naming
the tension for whoever revisits the axis: the band's third criterion, *"no state religious
funding"*, silently conflates **disestablishment** with **anti-clericalism**. A pluralist party that
funds every community's institutions equally is not defending a monopoly, yet the criterion as
written scores it as though it were. That did not change the outcome here — the devolution reading
decides it on its own — so the band is left as it stands. If a second party ever arrives with civil
marriage, broken monopolies *and* equal pluralist funding, the criterion should be rewritten rather
than stretched. Compare `communitarian-devolution`'s only other holder, זהות at **+2**: the same
mechanism, run in the opposite direction, which is the clearest evidence that devolution is
axis-neutral on its own and that the direction of travel has to be read off the content.

The governance chapter carries `constitutionalist` and `governance-reform`, and adds `term-limits`
from *"נגביל את מספר השרים בממשלה ואת משך כהונת ראש הממשלה"* — alongside a cap of ~20 core
ministries entrenched in Basic Law, which is the same shape of commitment that earned אל הדגל the
tag. The centrepiece is **חוק יסוד: החקיקה**, made a precondition for joining any coalition: a
special majority and public involvement for Basic Laws, agreed limits on judicial review, and a
balanced judicial-selection mechanism. Note this is the *symmetrical* constitutional position, not
judicial-overhaul in either direction — it explicitly refuses to *"לנצח צד אחר"*, to defeat the
other camp.

**`state-commission-of-inquiry` was deliberately NOT added, on revision 15's own precedent.** The
platform's founding principle #5 does demand a ממלכתית inquiry into
*"כל הכשלים שהובילו אותנו לאסון הגדול ביותר שהעם שלנו ידע מאז השואה"* — but revision 15 read ישר's
full commission מתווה and declined to tag it, on the grounds that the tag "measures audit coverage
rather than position". Tagging this row for one sentence, when a row with a drafted מתווה is
untagged, would make the tag record which documents happened to get read. The demand is real and is
recorded here in prose; the tag stays at its single holder until someone audits all 18 rows for it.

`unaligned` is supported from both directions and the platform closes it. Founding principle #1 is
*"ממשלה ציונית: למדנו שממשלה שמסתמכת על מפלגות לא ציוניות נאלצת לקבל החלטות לא ציוניות... שיתוף
פעולה של הגורמים הציוניים בלבד"* — cooperation among Zionist actors only, which excludes the haredi
and Arab parties and so denies the opposition bloc its arithmetic. From the other side, Hendel has
committed that he will "never complete Netanyahu to 61, even if it means more elections", which
rules out the bibi bloc. Two of the platform's three coalition preconditions (a real conscription
law, a balanced judicial package) are stated as *"נשב רק בממשלה ש..."* / *"נצטרף רק לממשלה ש..."*,
which is what makes `unaligned` a position here rather than an absence of one.

**2026-08-01 — the Gantz merger did NOT happen, and a different one did. This row is now stale in
its name, and its `economic` gap has a date on it.** Sequence: the Hendel–Gantz talks collapsed over
Gantz's refusal to declare he would not sit with the haredi parties; MK חילי טרופר then left Gantz's
כחול לבן, registered "יסודות ישראל" in early July, and on 2026-07-07 announced a joint run with
Hendel under the name **"בית ציוני"**, to which the "המילואימניקים" brand was then appended. The
list now runs as **בית ציוני - המילואימניקים**, positioning itself as a
*"חלופה ציונית וממלכתית במרכז"* — a Zionist statist alternative in the centre, explicitly
differentiating from Gantz's כחול לבן. In late-July polls it crossed the threshold for the first
time at 4–5 seats.

Three consequences, all resolved on 2026-08-08:

1. **`economic +1` was confirmed, not moved** — see the axis note above. The platform arrived on
   schedule and the number it was flagged against turned out to be right.
2. **`unaligned` holds and is now decisively evidenced.** Hendel's condition is
   *"ממשלה ציונית רחבה, ללא המפלגות החרדיות והערביות"* — a broad Zionist government without the
   haredi or Arab parties — and he will not hand Netanyahu a majority *"כל עוד הוא נשען עליהן"*, as
   long as he leans on them, adding that Netanyahu should take responsibility for October 7 and go
   home. That closes the bloc question from both directions at once, which is what `unaligned`
   requires.
3. **The rename is done, and it was a `seed.sql` edit after all — a rename, not a re-seed.** The
   earlier note here assumed renaming must be an admin-UI action because it orphans votes. That is
   true of the *naive* edit — changing the literal in the `INSERT` block, whose `ON CONFLICT (name)`
   matches the old name and therefore adds a second party rather than renaming the first. The
   working form is an `UPDATE` placed **before** that `INSERT`, keyed on `name`, setting `name` and
   `name_he` together the way `rename_upcoming_party()` does. The row keeps its `id`, so every vote
   already cast stays attached. Verified against a database seeded with the previous file: one row,
   `id` unchanged, one vote still attached, and idempotent across two applies.

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
- בית ציוני - המילואימניקים is **+1** on its own platform since 2026-08-05 (it rested on Hendel's
  centre-right record with no party document until then, and the platform confirmed the number).
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
**Their attack on High Court intervention in *religious* matters is a separate strand from the
halakhic-state demand**, and it is recorded here rather than in a tag. It used to carry
`anti-judicial-review`, which the 2026-08-11 vocabulary sweep folded into `judicial-overhaul`: the
tag was held by נעם alone while both its bloc partners used the other name for the same programme,
the `judicial-restraint` family already grouped all three, and נעם had by then acquired
`judicial-overhaul` itself. The religious-intervention nuance is one row wide, so prose is its right
home — it can be explained here, where a tag could only assert it.

**2026-08-11 — the relaunched site (`noamlisrael.org.il`, campaign launched 2026-07-29 under
*"חופשי להיות יהודי"*) is the first real platform this row has ever had. No axis moved; two tags
added.**

- **economic stays NULL — and this is the standing revisit firing, not being skipped.** The entry
  above says "revisit the moment they publish anything fiscal", and they have: a **₪12,000 minimum
  salary for a starting teacher**. That is the first fiscal number the party has ever published, and
  it still does not move the axis, for the same reason the הציונות הדתית entry gives for ₪9B of
  settlement budgets — it is *education policy denominated in shekels*, not a position on how the
  economy should be organised. A single sectoral wage floor asserts nothing about tax, welfare,
  markets or the state's economic role. **The revisit is now discharged rather than pending**; the
  next one needs a fiscal *position*, not a fiscal *figure*.
- **`not-economy-focused` is kept here, on the same day it was removed from הציונות הדתית.** That is
  not inconsistency: RZP published a 6-page economic doctrine, נעם published a teacher's salary. The
  two rows are different because the evidence is different.
- **`opposes-hostage-deals` added, on the exact precedent that earned it for הציונות הדתית.** That
  row got the tag because Tikva Forum founder צביקה מור entered at #3. Here **אליהו ליבמן** — second
  of the three candidates the party has named — **founded the same forum**, and independent reporting
  confirms he established it specifically in opposition to hostage-for-prisoner exchange deals,
  pressing to continue until Hamas was defeated. He is also a bereaved father: his son אליקים was a
  security guard at the Nova festival, held as presumed-kidnapped for over half a year before it
  emerged he had been murdered and his body mistakenly buried with one of the victims. Same forum,
  same position, higher list slot than the case that set the precedent.
- **`judicial-overhaul` added, and it exposes a vocabulary split.** The new platform is the overhaul
  programme in detail: legislate פסקת ההתגברות to restrain the High Court from annulling Knesset
  decisions, **split the Attorney-General's role** so the post advises rather than serially vetoes,
  and make political trust appointments so ministers can execute policy. נעם was the *only* holder of
  `anti-judicial-review` while its two bloc partners held `judicial-overhaul` — three parties, one
  programme, two tags. The tag is added rather than swapped: `anti-judicial-review` may still carry
  something narrower (court intervention in *religious* matters specifically), and deciding that
  belongs to the vocabulary sweep, not to an opportunistic edit. Logged under Open questions as the
  third instance of this pattern.
- **Confirmed first-party for the first time, having previously rested on the old site and
  Wikipedia:** religiosity +3 and `rabbinate-as-fourth-branch` (*"חיזוק הרבנות הראשית, הסדרת מעמד
  הכותל המערבי"*), `opposes-western-wall-compromise`, `halakhic-state` (legislation "במבט יהודי" on
  kashrut, conversion, **משפט עברי** and family values; Shabbat as the public day of rest),
  `education-system-focused` (a full education plank — curriculum transparency, expelling foreign
  NGOs, abolishing registration zones, a **parental veto over content**), and `rabbinic-authority-led`
  (Rabbi Tzvi Tau publicly blessing the campaign).

**The candidates, checked independently rather than from the party's own biographies:**

| # | candidate | what independent sources confirm |
|---|---|---|
| 1 | **אבי מעוז** | party chairman since 2019; former DG of the Interior and Housing ministries; ran the Authority for National Jewish Identity and the Education Ministry's External Programs Unit — the brief that made him nationally controversial, and the reason `education-system-focused` was never speculative |
| 2 | **סא״ל במיל׳ אליהו ליבמן** | founded פורום תקווה in opposition to hostage-exchange deals; head of the Kiryat Arba-Hebron council, and **reported as not standing for re-election there**, i.e. leaving local office for this run; Hebron-born, Golani Sayeret officer; brother murdered 1998, son murdered at Nova |
| 3 | **הרב שמעון טובול** | deputy mayor of Beer Sheva and councillor for 13 years, holding the environment portfolio; Givati reservist who served hundreds of days in חרבות ברזל; long record with at-risk haredi youth and a weekly food-basket operation for ~450 families |

**טובול is the interesting one for what it does *not* change.** A municipal welfare-and-community
record at #3 is the closest thing to a social profile this party has ever fielded, and it is still
not an economic position — it is one candidate's local record, not a party doctrine, so it leaves the
NULL untouched. Worth recording because it is exactly the sort of biography that invites reading an
economic stance into a party that has not stated one.

Sources: [noamlisrael.org.il](https://www.noamlisrael.org.il/) (the relaunched site),
[he.wikipedia — מפלגת נעם](https://he.wikipedia.org/wiki/מפלגת_נעם),
[Arutz 7 on Libman joining](https://www.inn.co.il/news/702060),
[Kipa on Libman joining](https://www.kipa.co.il/חדשות/1228206-0/),
[Makor Rishon — Libman not standing again in Kiryat Arba](https://www.makorrishon.co.il/news/671099/),
[IDI 2026 party and candidate list](https://www.idi.org.il/policy/parties-and-elections/elections/2026-1/).

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

`logo_url` is admin-ownable: `seed.sql` writes it on every boot unless the row's `admin_edited` array
already lists `logo_url`, which is how an admin's live edit (through the admin UI) survives a re-seed
— those edits exist only in RDS until someone backfills them into `seed.sql`. (Before 2026-08-12 this
was a per-statement `AND logo_url IS NULL` guard instead; same intent, different mechanism — see
`docs/design/2026-08-12-seed-sql-declarative-design.md`.)

**Three corrections shipped as literal replacements in the seeded value itself**, which is what let
them reach an admin-edited row too (this only matters for a row whose `admin_edited` does *not* list
`logo_url` — the common case, since these are the exception). Each replaced a value that was actively
wrong:

- **La Liga** — swapped the Wikimedia wordmark SVG for LaLiga's own "LL" monogram PNG, which suits
  the small square logo slot better; a wide wordmark renders tiny there.
- **בית ציוני - המילואימניקים** — originally a **misattribution fix**, not a cosmetic swap: the
  replaced URL was `Logo_המילואימניקים_-_דור_הניצחון.png`, the logo of **Gilad Ach's movement** (see
  the name-collision warning). We were showing one organisation's mark on another organisation's row.
  Repointed again on 2026-08-08 to `/logos/beit-tzioni-miluimnikim.png` for the joint list's rebrand.
- **הציונות הדתית**, `upcoming_parties` **only** — the 2026 rebrand. `previous_parties` deliberately
  keeps the 2022 logo, because that row is the current Knesset faction, and the two tables carry
  independent `logo_url` columns. Scoping the statement to one table is what enforces that.

### Two logos are self-hosted under `/logos/`, and neither is a matter of taste

`services/frontend/logos/` is copied into the frontend image as a whole directory, so adding a file
there is a data change. Both party logos that live there had to leave Wikimedia/CDN hosting:

- **בית ציוני - המילואימניקים** (`beit-tzioni-miluimnikim.png`) — the list's only artwork is on
  `*.fbcdn.net`, whose URLs are signed and expire, and which tracker blockers drop in the browser.
  That is the F.C. Kiryat Yam failure exactly: `curl` fetches it happily while a large share of real
  visitors see nothing, and **no server-side check can detect it.** The file is cropped and its
  background removed, but otherwise the party's own blue lockup, shown **unchanged in both themes** —
  see the knockout note below, which is why it is the one party logo the dark-mode recolour skips.
- **הציונות הדתית** (`religious-zionism-2026.png`) — **neither Wikimedia revision works in both
  themes, so there is no URL to point at.** The published PNG has the white background baked in
  (100% opaque, no alpha), which trips the `> 0.9` solid-tile guard in `recolorLogoForDark()` and
  renders as a white plate on the dark cards. The revision it replaced — still reachable under
  `/wikipedia/he/archive/…/20260805145808!…` — is a **white-ink knockout on transparency**, invisible
  in light mode; the uploader replaced it 33 minutes later with the comment
  *"עם רקע לבן וכיתוב בצבע טורקיז"*. **Do not "restore" either one.** The seeded file is the
  canonical revision with its *outer* white flood-filled to transparent — a flood fill from the
  edges, not a global white-to-transparent replace, which would punch holes through the white text
  inside the teal בראשות bar. That leaves the `#31698C` wordmark (luminance 0.375) below the recolour
  threshold and the teal bar (0.518) just above it, so the bar keeps white-on-teal in both themes.
  **That split is luck, not design** — re-exporting the file with a slightly darker teal would send
  the bar below 0.5, lift it, and put white text on a light background.

Both were verified by rendering the real `logos.js` and `style.css` in headless Chromium over HTTP
in both themes, not by inspecting the files. Both use `oxipng` lossless and **not** `pngquant` —
the blue in each is faceted and bands.

### A knockout cannot be recoloured, and it defeats every check based on brightness

בית ציוני's Star of David is not drawn. It is a **hole** in the swoosh that lets the background show
through, so in the file the star's interior and the empty space outside the whole logo are the same
transparent pixels. This is the defect `fillLogoInteriorForDark()` already documents for ש"ס, and it
has the same consequence: `recolorLogoForDark()` lifts the swoosh but **cannot lift a hole**, so the
dark card shows through the star as black triangles.

**This shipped once and was signed off as verified.** The first attempt swapped the artwork's white
lettering to navy so the recolour would lift it, and the swoosh and wordmark did lift, exactly as
measured. The check was of the wrong property: every test was "does this pixel brighten", and a hole
has no pixel to brighten. The rendered screenshot contained the black triangles and was read as a
star. **When a logo contains a knockout, the question is not how its colours transform — it is what
shows through the holes on each background.**

Two fixes were tried, and the second is the one in the repo:

1. *Two assets*, one knocked out to white and one to the dark card. Correct, and the reason it was
   dropped is not technical — the white-on-dark version was judged to look worse than the blue one.
2. **One asset, recolour skipped** — `'Zionist Home – The Reservists'` in `SKIP_RECOLOR_PARTIES` in
   `logos.js`. **That set is keyed by `name_en`, so renaming the party breaks it silently** — the
   entry stops matching, the recolour runs again, and the knockout star returns as black triangles
   with no error anywhere. Renamed together on 2026-08-13; keep them in step. The
   artwork is left exactly as the party drew it and its colours are chosen to clear WCAG's 3:1
   graphical-object minimum on **both** grounds: the secondary elements use the brighter of the
   logo's own two blues, `#418AB8` (**4.57:1** on the dark card, **3.78:1** on white). The darker
   `#326B9F` reads better on white but drops to **3.08:1** on the dark card — passing, with nothing
   spare, and the small בראשות טרופר והנדל line is what pays for it first.

Skipping the recolour is the load-bearing half: without it the blues get lifted and the two themes
drift apart again, which is the whole point of using one lockup. **Do not "tidy" this party back
into the recolour path.**

**An `/archive/` path or a `!<timestamp>!` prefix in a `upload.wikimedia.org` URL means a superseded
revision.** It is easy to copy one from a file-history page and reasonable to assume it is current.
The canonical URL has neither.

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
- ~~**בית ציוני - המילואימניקים launches its platform on 2026-08-05**~~ — **resolved 2026-08-08.**
  The מצע (תוכנית מגן דוד) landed on schedule and was read. `economic +1` **confirmed** on the
  party's own document rather than Hendel's record, so it is no longer the weakest number on the
  page; `religiosity` moved **0 → −2** on the core-curriculum funding condition; `security +2` and
  `bloc unaligned` both confirmed. Details under that entry. One caveat carried forward: the party
  has **no website**, so the platform reaches this page through press quoting it, not a primary
  source.
- ~~**The row is still seeded as `המילואימניקים`**~~ — **renamed 2026-08-08** to
  **בית ציוני - המילואימניקים**, in `seed.sql`, without orphaning any vote. The reasoning that made
  this look like an admin-only action — and the `UPDATE`-before-`INSERT` shape that makes it safe —
  is under that entry. **נעם below is NOT the same case**: that one is still open, because its
  rename is speculative (lists are not final) while this one followed a completed merger with a
  launched campaign.
- ~~**הדמוקרטים's `two-state` tag is not supported by the party's own platform**~~ — **resolved
  2026-08-01: the tag stays.** The platform text does name *"המדינה הפלסטינית העתידית"* (surfaced via
  a hostile source quoting it), the chair states two states as the party vision, and four of the
  realized top six campaign on it. `security −1` and the "Zionist two-staters" band label were both
  correct as written. Details under that entry.
- ~~**כחול לבן has six known party documents and two have been read**~~ — **stale as written, and it
  contradicted revision 13 four rows above it, which recorded all six as read on 2026-08-01.**
  Resolved 2026-08-11: there are **seven**, all read, the seventh being *עולים צפונה* (2026-08). The
  403 no longer needs a manual workaround either — a browser `User-Agent` plus a `Referer` header
  fetches the PDFs directly; see that entry. The row is still polling ~1%, below the threshold, and
  losing people to בית ציוני - המילואימניקים.
- ~~**`periphery-development`, `annexationist`/`sovereignty-annexation`, and
  `anti-judicial-review`/`judicial-overhaul` are three instances of vocabulary drift**~~ —
  **all three RESOLVED by the vocabulary sweep, 2026-08-11 (revision 19). See "The vocabulary
  sweep" below for the reasoning; the summary is: two tags retired, one folded, one confirmed and
  extended.**
- **נעם is campaigning as `נעם לישראל`** ("Noam for Israel") for the 26th Knesset. The row is seeded
  under the plain `נעם` and it is deliberately *not* renamed yet: lists are not final, a rename
  orphans votes (see the warning above), and an admin can do it in one edit if the longer name is
  what appears on the ballot.
  **Stronger as of 2026-08-11, and still held.** The rebrand is no longer just campaign language: the
  party relaunched on a new domain (`noamlisrael.org.il`), opened its campaign on 2026-07-29 under
  *"חופשי להיות יהודי"*, and has named three candidates. That is close to the bar בית ציוני -
  המילואימניקים cleared before *its* rename — but not the same bar. That one followed a **completed
  merger**, a structural fact; this is a rebrand, and the doc's stated blocker was never the branding,
  it was that **the ballot name is not certified**. The asymmetry decides it: waiting costs one admin
  edit, renaming early costs a second rename plus a data migration on a row that holds votes if they
  file as plain `נעם`. **Trigger: ballot certification, not campaign launch.**
- **נעם's `economic` is the only NULL on that axis** and is a "no platform yet" NULL, not a
  scoped-out one. **Revisit discharged 2026-08-11** against the relaunched platform: they published
  their first fiscal *figure* (a ₪12,000 starting-teacher salary floor) and it does not move the
  axis, because a sectoral wage floor is not a position on how the economy should be organised. The
  next revisit needs a fiscal **position**, not another figure.
- Election date is **2026-10-27**; lists are not final, so more revisions should be expected.

---

## The vocabulary sweep (2026-08-11)

Three tags were found asserting things the evidence did not support. They were deliberately **not**
fixed as they were found — each was logged and left alone, because fixing vocabulary opportunistically
in the middle of reading a party document is exactly how all three got that way. This section records
the one pass that resolved them, and the test it used.

**The test.** A tag earns its place if it either (a) *groups* rows in a way a reader could not
reconstruct from the axes, or (b) records a position precisely, with membership matching the evidence
this page documents. Rarity is **not** a defect: 72 tags sit on a single row and most are exact
(`kahanist`, `islamist`, `flat-tax`). The defects were duplication and unjustified membership.

| tag | before | after | outcome |
|---|---|---|---|
| `periphery-development` | 3 | **0** | **retired** |
| `annexationist` | 1 | **0** | **folded** into `sovereignty-annexation` |
| `anti-judicial-review` | 1 | **0** | **folded** into `judicial-overhaul` |
| `sovereignty-annexation` | 4 | **5** | confirmed, gains הציונות הדתית |
| `reservist-focused` | 5 | **6** | **confirmed and extended** |

### `periphery-development` — retired

**None of its three holders (ישר, ביחד, בית ציוני) has a single line of justification in this
document.** Checked section by section. Meanwhile this page documents periphery programmes for two
rows that did *not* carry it — הדמוקרטים ("periphery investment") and אל הדגל ("massive periphery
infrastructure") — and כחול לבן's *עולים צפונה* is the most explicit periphery programme any party
has published (half a million people to the Negev and Galilee in five years, half of all citizens
by 2048) and was also untagged.

So membership was inverted with respect to the evidence: no support for those who held it, documented
support for several who did not. The alternative to retiring was to invent a standard and audit 18
rows, and that was rejected because **developing the periphery is near-universal Israeli political
rhetoric** — the honest end state is a tag on most of the table, discriminating nothing. Distinctive
periphery programmes are recorded in prose, where they can be described precisely, and כחול לבן's and
אל הדגל's already are.

### `annexationist` → `sovereignty-annexation`

One position, two spellings, and the worst possible split: `annexationist` held by הציונות הדתית
alone while `sovereignty-annexation` held its four closest neighbours (עוצמה יהודית, אל הדגל, זהות,
נעם). A reader filtering on either name got an incomplete right. Folded; the tag now reads 5 of 18
and covers the sovereignty-supporting right exactly.

### `anti-judicial-review` → `judicial-overhaul`

Held by נעם alone, while its two bloc partners held `judicial-overhaul` for the same programme. Two
things decided the fold rather than a sweep. First, the anti-court grouping **already exists one
layer up**: the `judicial-restraint` *family* covers הליכוד, הציונות הדתית, עוצמה יהודית, זהות and
נעם, so the tag was grouping nothing the family did not. Second, נעם itself now carries
`judicial-overhaul`, so the tag was a footnote on a row that already had the general position.

The nuance it carried — that נעם's objection is specifically to High Court intervention in *religious*
matters — is real, and it survives **in prose** under that party's entry, where it can be explained
rather than merely asserted. That is the right home for a distinction one row wide.

### `reservist-focused` — confirmed, and extended to הציונות הדתית

This is the one the sweep *kept*, and the reasoning runs opposite to the others. The repo owner
predicted it would prove over-broad, and the prediction was half right: a sixth row does qualify.
But unlike `periphery-development`, this tag has a **recorded earning standard** — a costed benefits
package, not rhetoric (revision 13) — so membership is testable rather than impressionistic, and
every holder meets it.

**Its six holders span all three blocs**: הדמוקרטים (`opposition`, −2/−1/−3) and הציונות הדתית
(`bibi`, 0/+3/+3) now carry the same tag. That is not dilution; it is the finding. A tag that unites
the social-democratic left and the far right is recording something the axes cannot — that reservist
burden became post-ideological in 2026 — which is precisely criterion (a).

**הציונות הדתית was added here, reversing the same-day decision to hold it back.** It had been
declined on the ground that its מילואים paper is pre-October-7 and therefore weak for a 2026 row.
That objection was inconsistent: the *same* 2021 corpus was used the same day to confirm
`judicial-overhaul`, confirm `sovereignty-annexation` and remove `not-economy-focused` from that row.
Evidence cannot be good enough for three findings and too stale for a fourth. The date caveat belongs
to the whole row — which is why its `basis` stays `record` — not to one tag.

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
| 2026-08-01 | revision 11 — כחול לבן's conscription programme found on `sherut4all.com`: 4 tags + the `universal-conscription` family added, **no axis moved**. Source URLs added to five entries. Freshness sweep: Beiteinu re-verified, נעם's economic NULL re-verified, ביחד's security NULL re-verified, רע"ם's IDI basis found undated and rejected, and המילואימניקים found to have merged into בית ציוני - המילואימניקים with its platform due 2026-08-05 |
| 2026-08-01 | revision 12 — הדמוקרטים read against its own eight platform documents for the first time: 8 tags + the `universal-conscription` family added, **all three axes confirmed and unmoved**, and `two-state` flagged as unsupported by the platform |
| 2026-08-01 | revision 13 — all six כחול לבן documents read (downloaded by hand past the 403). **religiosity −1 → −2** on the education programme's core-curriculum funding condition and state-haredi default; `core-curriculum`, `state-haredi-education`, `reservist-focused` added. security +2 and economic 0 verified against the documents and unmoved; the −2 band text corrected to stop implying civil marriage is required |
| 2026-08-02 | ישראל ביתנו re-verified string-by-string against the live platform: 15 sourced claims hold, **1 was wrong** — "Judea and Samaria appears exactly once" (it appears four times). Evidence for "no territorial claim" moved to ריבונות / סיפוח / התנחל = 0 occurrences each. **No axis moves** |
| 2026-08-08 | revision 14 — בית ציוני - המילואימניקים read against its own תוכנית מגן דוד platform (launched 2026-08-05). **religiosity 0 → −2** on *"מתן תקצוב ציבורי רק למוסדות המלמדים לימודי ליבה"*, the same criterion that moved כחול לבן in revision 13; economic +1, security +2 and `unaligned` all **confirmed and unmoved**, with economic now resting on a party document instead of Hendel's personal record. 5 tags + the `cost-of-living` family added. **Row renamed** `המילואימניקים` → `בית ציוני - המילואימניקים` in `seed.sql` via an `UPDATE` before the `INSERT`, verified against an already-seeded database to keep its `id` and its votes. Logos: the same row repointed to a self-hosted file, and **הציונות הדתית's 2026 rebrand applied to `upcoming_parties` only** — `previous_parties` keeps the 2022 logo as the current Knesset faction |
| 2026-08-08 | בית ציוני's logo corrected after shipping: its Star of David is a **knockout**, so the dark-mode recolour left the card showing through it as black triangles. Now one blue lockup used unchanged in both themes, with the recolour skipped (`SKIP_RECOLOR_PARTIES`) and the secondary elements on `#418AB8` to clear 3:1 on both grounds. **No classification change.** See the knockout section under Logos |
| 2026-08-11 | revision 15 — five newly-read first-party documents across three rows, and **no axis moved on any of them**. הדמוקרטים's corpus 8 → 10 (מילואימניקים, שיווין מגדרי): `reservist-focused` and `gender-equality` added — the first makes this the tag's only cross-bloc holder, the second is new to the vocabulary; `sanctions-on-non-servers` rejected (this party targets institutional funding, not individuals, the opposite side of כחול לבן's line); religiosity −3 confirmed from a *third* motive (get-refusal, not pluralism or anti-clericalism); security −1 re-verified mechanically at ten papers, with a note that two documents now press on the −1/−2 boundary. ישר's October 7 commission מתווה read and **deliberately not tagged** — `state-commission-of-inquiry` sits on 1 of 18 rows and measures audit coverage rather than position; the drafted-statute-vs-slogan distinction recorded in prose instead. כחול לבן's corpus 6 → 7 (עולים צפונה): economic 0 and security +2 both held, `periphery-development` **rejected as a broken tag** and raised as an open question, and the התיישבות homograph (Negev/Galilee, not the West Bank) flagged against the row's `pro-settlement` tag. Two stale claims fixed: "כחול לבן... two have been read" contradicted revision 13, and the `kachollavan.org.il` 403 does **not** require manual download — a browser `User-Agent` plus `Referer` fetches it |
| 2026-08-11 | revision 16 — **עוצמה יהודית read against party output for the first time**, via 30 of its own news posts (2026-05-26 → 2026-08-04); it publishes no platform, which is why the row had stood at five tags and a two-line entry. **No axis moved** (security and religiosity are already at the +3 ceiling; economic 0 is now confirmed by 30 posts containing zero economic content, rather than inferred). Six tags added, 5 → 11: `gun-rights` (8 posts, 280,000+ licences, 126 localities in 2026 alone), `judicial-overhaul` (closing a gap against its own bloc partner), `pro-settlement` + `sovereignty-annexation` (חיננית cornerstone, sovereignty stated as doctrine), `temple-mount-centred` (chairman ascending on Tisha B'Av), and one new tag `death-penalty-for-terrorists`. `basis` stays `record` — ministerial-action posts are a record source, not a platform. Two near-misses recorded rather than tagged: the muezzin-noise bill is **not** religiosity evidence (that axis is scoped to Jewish religion-and-state, and its sponsors frame it as public health), and Negev demolition enforcement is left untagged for want of a comparator row. Also logged: `annexationist` and `sovereignty-annexation` are duplicate tags for one position, splitting the two closest parties across two spellings |
| 2026-08-11 | revision 17 — **הציונות הדתית read against its own 13 platform PDFs** (2021-12 / 2022-10; the party has published nothing for 2026, so these are authoritative for `previous_parties` and only indicative for `upcoming_parties`, whose `basis` stays `record`). **No axis moved.** `not-economy-focused` **REMOVED from both rows** — `docs/design/2026-07-30-party-families-club-traits-design.md` had already replaced the *family* of that name here as "simply false" given Smotrich's finance ministry, but nobody removed the *tag*, so `seed.sql` kept asserting what another repo doc called false; a dedicated 6-page כלכלה paper (abolish civil-service tenure, ban political strikes, no deficit-closing via tax rises, broad tax cuts against narrowed exemptions, hospital independence, deregulation) plus a 7-page workfare-framed רווחה paper settle it. **economic stays 0 regardless** — the number records the *revealed* position and `claims-economically-liberal` carries the gap; those two tags were never the same claim, and only the second was ever true here. `death-penalty-for-terrorists` added from the טרור paper, giving that tag a **second** holder and retiring the "single-holder" rationale written for עוצמה יהודית earlier the same day. `judicial-overhaul` and `annexationist` confirmed against first-party text for the first time (the משפט paper's override clause requires a *unanimous* court to strike a Knesset law). `reservist-focused` **deliberately not added** despite a qualifying מילואים paper: pre-October-7, and it would put the tag on a third of the table — confirming the owner's prediction and sharpening the open vocabulary question. Retrieval note: **12 of the 13 are image-only**, `pdftotext` yielding 34 bytes each |
| 2026-08-11 | revision 18 — **נעם read against its relaunched site** (`noamlisrael.org.il`, campaign opened 2026-07-29), the first real platform this row has ever had. **No axis moved.** `opposes-hostage-deals` added on the exact precedent that earned it for הציונות הדתית — that row got it because Tikva Forum founder צביקה מור stood at #3; here **אליהו ליבמן**, who *founded* the same forum in opposition to hostage-for-prisoner deals, stands at #2, and is himself a bereaved father (son murdered at Nova, held as presumed-kidnapped for over half a year). `judicial-overhaul` added: the platform is the overhaul programme in detail (פסקת ההתגברות, splitting the Attorney-General's role, political trust appointments), which exposed נעם as the sole holder of `anti-judicial-review` while both bloc partners held `judicial-overhaul` — **third instance** of the vocabulary-split pattern, logged rather than opportunistically fixed. **economic stays NULL and the standing revisit is now DISCHARGED rather than pending**: the ₪12,000 starting-teacher salary floor is the first fiscal figure the party has published, but it is education policy denominated in shekels, not a position on how the economy should be organised — the next revisit needs a fiscal *position*, not a fiscal *figure*. `not-economy-focused` **kept** here on the same day it was removed from הציונות הדתית, because the evidence differs: RZP published a 6-page economic doctrine, נעם published a teacher's salary. religiosity +3, `rabbinate-as-fourth-branch`, `halakhic-state`, `opposes-western-wall-compromise`, `education-system-focused` and `rabbinic-authority-led` all confirmed against first-party text for the first time. Candidates verified independently (Maoz, Libman, Tovol), and the נעם→נעם לישראל rename remains **held**, with the trigger restated as ballot certification rather than campaign launch |
| 2026-08-11 | **revision 19 — the vocabulary sweep.** One pass over all 18 rows resolving the three drift instances logged earlier the same day, deliberately *not* fixed as they were found. **`periphery-development` RETIRED** (3 → 0): none of its holders had a single line of justification on this page, while two untagged rows had documented programmes and כחול לבן's *עולים צפונה* — half a million people to the Negev and Galilee — is the most explicit any party has published; inventing a standard and auditing 18 rows was rejected because periphery development is near-universal Israeli rhetoric, so the honest end state is a tag on most of the table. **`annexationist` FOLDED into `sovereignty-annexation`** (1 → 0, target 4 → 5): one position under two spellings, splitting הציונות הדתית from its four closest neighbours. **`anti-judicial-review` FOLDED into `judicial-overhaul`** (1 → 0): the `judicial-restraint` *family* already grouped all five anti-court parties, and נעם had itself acquired `judicial-overhaul`; the religious-intervention nuance survives in prose under that entry. **`reservist-focused` CONFIRMED and extended to הציונות הדתית** (5 → 6), reversing the same-day decision to withhold it — withholding was inconsistent, since the same 2021 corpus was used that day to confirm `judicial-overhaul`, confirm `sovereignty-annexation` and remove `not-economy-focused` from that row; the staleness caveat attaches to the whole row (hence `basis` stays `record`), not to one tag. The tag's six holders now span all three blocs, putting הדמוקרטים (−2/−1/−3) and הציונות הדתית (0/+3/+3) under one label, which is the finding rather than dilution. **No axis moved and no `previous_parties` row was touched** (none carried any of the four tags). Test used, and recorded in the new "The vocabulary sweep" section: a tag earns its place if it *groups* rows in a way the axes cannot, or records a position precisely with membership matching documented evidence — **rarity is not a defect**, and 72 single-holder tags were deliberately left alone |
| 2026-08-13 | revision 20 — **בית ציוני - המילואימניקים read against its own platform PDF for the first time** (*מצע מפלגת בית ציוני – נוסח מאוחד ומעודכן*, 26pp, created 2026-08-06). Revision 14 had scored this row from press quotation of the same מצע and recorded that it had done so; the document is roughly three times what the press covered, and **no axis moved when it was read** — economic +1, security +2, religiosity −2 and `unaligned` all confirmed, now cited to the party's own text rather than to Hendel's record. The unreported chapter is *מדינה יהודית לכולם*, which adopts Piron's **50:30:20 model** and answers all four questions revision 14 had recorded as unanswered: civil marriage (*"מתן האפשרות לכל זוג לבחור כיצד להינשא"*, restated in the LGBT chapter), kashrut and religious services devolved to municipalities, the local rabbinate chosen by them, and Shabbat transport set by them. **religiosity held at −2 anyway, and the old justification was deleted rather than patched** — "they say nothing about the Rabbinate, marriage, kashrut or Shabbat" is now false. The deciding criterion is funding: −3 requires *no state religious funding* and this platform expands it (*"הרחבת... התקצוב של מוסדות דת ותרבות מקומיים"*), framing the model as strengthening Israel's Jewish character. **Devolving an establishment is not disestablishing it.** Logged as an open question: that −3 criterion conflates disestablishment with anti-clericalism, and should be rewritten rather than stretched if a second pluralist-funding party ever arrives. **10 tags added** (17 → 27), every one drawn from the existing vocabulary with no new label invented: `civil-marriage`, `kashrut-liberalization`, `religious-pluralism`, `municipal-devolution`, `communitarian-devolution`, `lgbt-rights`, `state-haredi-education`, `scholar-exemption-retained`, `term-limits`, `workforce-integration`; plus the `welfare-state` family, earned by public housing <50,000 → **110,000** units and the 1958 חוק סעד replaced outright. **`state-commission-of-inquiry` deliberately NOT added**, on revision 15's precedent — it declined the tag for ישר's full commission מתווה as measuring audit coverage rather than position, so tagging this row for one sentence would record which documents got read. Two near-misses left untagged for want of a comparator: *"ייהוד הנגב והגליל כמשימה לאומית"* (this axis scores the conflict, not internal demography) and the ~40% of the platform devoted to post-trauma and mental health. **One discrepancy recorded rather than resolved:** the platform's six-item סנקציות list (arnona, housing benefits, driving licence, exit ban, public posts, school funding) does **not** include Hendel's franchise clause, which `service-conditioned-citizenship` rests on — the tag stays, but the party's own newer document declines to write it down. **Renamed in the same pass**: `name_en` `The Reservists` → `Zionist Home – The Reservists` and `name_ru` `Резервисты` → `Сионистский дом – Резервисты`, so all three names now carry the joint list's full brand rather than only the מילואימניקים half. **Two files key on the old `name_en` string and both were changed with it**: `SKIP_RECOLOR_PARTIES` in `services/frontend/logos.js` (a stale entry there silently re-enables the dark-mode recolour on a **knockout** logo, returning the black-triangle Star of David bug of 2026-08-08 with no error raised) and the expected-name set in `services/backend/tests/test_queries.py`, which is the only automated check that would have caught either |
