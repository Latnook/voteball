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
| **+3** | Libertarian: shrink the state as a matter of principle, not just policy | *(none — זהות was the only holder and merged into הציונות הדתית on 2026-09-01, which did not take the number)* |
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
| **+3** | Annexation / sovereignty over Judea and Samaria | הציונות הדתית, עוצמה יהודית `[u]`, נעם `[u]`, הליכוד `[u]` |
| **+2** | No Palestinian state **plus** a territorial claim — sovereignty over security-essential areas, settlement expansion, preemptive doctrine, taking territory in Gaza | הליכוד `[p]`, ישראל ביתנו, כחול לבן `[u]`, אל הדגל `[u]`, בית ציוני - המילואימניקים `[u]`, המפלגה הכלכלית `[u]` |
| **+1** | No Palestinian state, but explicitly refusing territorial expansion | ש"ס, יהדות התורה, ישר `[u]` |
| **0** | No stated conflict doctrine either way — the party is about something else | יש עתיד `[p]` |
| **−1** | Zionist two-staters | הדמוקרטים `[u]`, העבודה `[p]`, מרצ `[p]` |
| **−2** | Two-state with an end to the occupation | חד"ש-תע"ל, רע"ם `[u]` |
| **−3** | Full withdrawal, right of return, dismantling settlements | בל"ד |
| **NULL** | No stated position — see the NULL rule above | המחנה הממלכתי `[p]`, רע"ם `[p]`, ביחד `[u]` |

Note **0 and NULL are different claims** here: `0` asserts a party has genuinely taken no side on the
conflict, `NULL` says none is on record. ביחד is the `NULL` case — its component parties have not
published a joint position.

**⚠ The `0` illustration used to be המפלגה הכלכלית, and it was wrong — the row moved to +2 on
2026-08-17 (revision 23).** This paragraph asserted that it "is an economics party that genuinely
takes no conflict position"; the party's platform has a dedicated `/ביטחון` page opposing any
withdrawal from any territory, opposing a Palestinian state, and backing Jewish settlement in Judea
and Samaria. **A `0` on this axis is a positive claim about a party and needs the same evidence as
any other score** — it is the cheapest score to leave in place by inertia, because it looks like
neutrality rather than an assertion. The band is now left with **one** holder, יש עתיד `[p]`, whose
`0` has not been re-verified against a source since it was assigned; treat it as unaudited until it
has been.

### `religiosity` — religion and the state

Scoped to **Jewish** religion-and-state, so it is NULL for parties the question does not apply to.
Negative reduces religious authority.

| | meaning | parties |
|---|---|---|
| **+3** | Halakhic state: derive state law from religious law | הציונות הדתית, עוצמה יהודית `[u]`, נעם `[u]` |
| **+2** | Expand religious authority and state religious funding — defend the marriage, kashrut and Shabbat monopolies, *without* a halakhic-state programme | הליכוד, ש"ס, יהדות התורה |
| **+1** | Preserve and modestly strengthen the state's Jewish character | *(none)* |
| **0** | Status quo — no active religion-state agenda in either direction | *(none)* |
| **−1** | Pluralist: soften the monopolies without disestablishing | המחנה הממלכתי `[p]` |
| **−2** | Strong separationist: **core curriculum as a funding condition**, break the monopolies, universal conscription. Civil marriage is neither required to sit here (כחול לבן, ביחד, המפלגה הכלכלית and אל הדגל have none) **nor disqualifying** — ישר and בית ציוני both demand it and are held at −2 by the funding criterion of the −3 band, not by its marriage criterion | ישר `[u]`, ביחד `[u]`, כחול לבן `[u]`, המפלגה הכלכלית `[u]`, אל הדגל `[u]`, בית ציוני - המילואימניקים `[u]`, עמך ישראל `[u]`, יש עתיד `[p]`, העבודה `[p]`, מרצ `[p]` |
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
- ~~`חד"ש-תע"ל` is the 2022 joint list with Ta'al…~~ **Resolved 2026-08-20.** The Joint List
  re-formed (חד"ש + תע"ל + בל"ד, without רע"ם) and the two upcoming rows merged into one,
  `הרשימה המשותפת`. Note this did **not** resolve as the "renaming, not reclassifying" this warning
  predicted: two rows cannot both be renamed into one, so the merge is a new `joint-list` row plus a
  guarded removal of the old two, with `party_lineage` carrying both predecessors into it. The
  warning's underlying point held anyway — the merge was done while both rows had **zero** votes, so
  nothing was orphaned, and `seed.sql`'s removal is guarded on votes precisely so that a roster
  change can never destroy a ballot. The frozen `previous_parties` rows keep their 2022 names.
- **The 2026-09-01 הציונות הדתית + זהות merge took a third shape again**, so neither earlier case is
  the template: one component was already the lead party and the registered list, so the surviving
  row is **kept, not created** — no rename, no new `seed_key`, and `זהות`'s row removed by the same
  guarded delete. Which shape a merge takes turns on whether either brand survives, and no merge on
  this page has yet resolved the way the preceding one did.
- **A withdrawal is the fourth shape, and it is the only one with no successor** (האחדות, 2026-09-04).
  Nothing is renamed, nothing is created, no `party_lineage` link changes and no brand survives — the
  row simply stops being named by `seed.sql` and the guarded delete takes it. The vote guard matters
  more here than in either merge, because a merge offers the voter a successor line to be reassigned
  to and a withdrawal does not: if the row has votes it stays on the ballot, which is the guard
  failing safe in the direction that is now *visible to voters*, not merely tidy. Check for votes and
  reassign deliberately rather than assuming the delete fired.

---

## Upcoming parties

### הליכוד — Likud · `bibi` · 1 / 3 / 2 · traditional

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

**2026-08-18 — revision 24: read against the 2026 primary list for the first time. `security`
moved +2 → +3. Ten tags added, 4 → 14. `previous_parties` untouched.**

This row had **four tags** against 11–27 on every comparable row, because it had never been read
against a party source at all — it publishes no platform, so `family_evidence` is `record`. The
primary (counted to 98%, 17 Aug 2026) is the closest thing this party emits to a stated position,
and revision 5 established the method: *ranked lists are evidence about priority, not only about
presence.*

Realized list: 1 בנימין נתניהו, 2 אלי כהן, 4 ישראל כץ, 5 גדעון סער, 6 אמיר אוחנה, 7 יריב לוין,
8 מירי רגב, 10 אופיר כץ, 11 אורן דוברונסקי (reserved, unconfirmed), 12 יואב קיש, 13 מיקי זוהר,
14 אלמוג כהן, 16 עמיחי שיקלי, 17 דודי אמסלם, 18 חיים כץ, 19 משה סעדה, 20 טלי גוטליב, 21 דוד ביטן,
22 שלמה קרעי, 23 בועז ביסמוט, 24 ניר ברקת, 25 גילה גמליאל, 27 ארז תדמור, 28 שלמה לרנר, 30 שוקי אוחנה,
31 משה בנימין פרץ, 32 זאב אלקין, 33 אמית הלוי, 34 קרן אטיאס בובליל. Turnout **53.5%**
(~75,000 of ~142,000 members), down 4.5 points from 2022.

**Two caveats on the list itself, both recorded rather than resolved.** Reporting puts **eight** slots
under Netanyahu's personal appointment — 3, 5, 9, 11, 15, 18, 26, 29 — plus separate guaranteed
placements for סער and ישראל כץ, but sources conflict on the exact set and the list was **not
certified** when this was written; the 21–23 ordering (קרעי/ביסמוט/ביטן in one count, reversed in
another) and the 16–17 ordering are both disputed. Reserved slots are evidence about **party
structure, not policy**, and score nothing here — but one of them is load-bearing for the economic
axis below: **slot 18 is an appointment**, upheld by a three-judge Likud internal-court panel on
12 Aug over גוטליב's public objection that it "mocks Likud voters."

#### `security` +2 → +3

**This is the one axis that moved, and it moved on the government's record rather than on the list.**
The list's own evidence is strong but not by itself decisive: אלי כהן at #2 states "only one Jewish
state between the Jordan and the Sea" and, as Energy Minister, connected new Samaria settlements to
electricity and water while calling it "exercising sovereignty in practice"; אמיר אוחנה at #6 was
among ~16 ministers urging sovereignty and calls it "clearer than ever"; the Knesset carried a
non-binding sovereignty motion on 23 July 2025.

What decides it is that **the government has acted, at cabinet level, in the +3 band's terms**:

- **8 February 2026 — the Security Cabinet approved a package of seven measures**: extending Israeli
  control into **Areas A and B**, legalizing settler land purchases, removing oversight of land
  transactions, publishing the West Bank land registry, reviving a state land-acquisition committee,
  seizing Rachel's Tomb, and transferring Hebron planning powers to the Civil Administration. Axios
  characterised it as "a step toward de facto annexation"; it breaches Oslo, and it came **after**
  Kushner and Witkoff asked Netanyahu in December 2025 to de-escalate.
- **The same day, the Ministerial Committee on Legislation** — the coalition's government-level
  gatekeeper, not a backbencher — backed a statutory **West Bank Heritage Authority**, described as
  the first application of domestic Israeli law to **territory** rather than persons in the West Bank.
- **2025 cabinet decisions established 54 new official settlements** (13 March, 22 May, 19 December)
  and granted 27 settlements municipal jurisdiction over 8,472 dunams. **E1** received final approval
  (3,401 units) with an acceleration agreement **signed by Netanyahu personally** and ₪3bn of
  infrastructure. The Higher Planning Council approved **27,941 units** in 2025.

**The counter-evidence is real and is why this took a second pass.** Netanyahu actively worked to
*block* the two annexation bills the Knesset advanced on 22–23 October 2025, because they risked
angering Washington; יואב קיש at #12 says he is "a great believer in applying sovereignty" but that it
"cannot be advanced through opposition bills"; and on 26 September 2025 a **senior Israeli official**
told Channel 12 that Netanyahu "never intended to annex," giving the Abraham Accords as the reason and
attributing the push to סמוטריץ' and בן גביר rather than to Likud.

That evidence is weaker than it looks. It is an **unnamed official** characterising intent, about
**formal declaration** rather than substance, and the same government extended control into Areas A
and B four months later against explicit American requests. The pattern across both files is
consistent: **the leadership blocks declaratory moves that create friction with Washington while
approving administrative ones that achieve the same end quietly** — which is Crisis Group's finding
in as many words, its October 2025 report being titled *Sovereignty in All but Name*, and its
judgment that much of the West Bank is already annexed in substance. A senior official also told the
Times of Israel that Jerusalem did **not** regard Trump's veto as final.

**The axis records the revealed position, and the revealed position is the cabinet's, not the
spokesman's.** +3. The one thing this does *not* license is reading Likud as עוצמה יהודית; a shared
number is never evidence a distinction has been lost (Decision 5), and the motive tags differ.

#### `economic` +1 and `religiosity` +2 both confirmed and unmoved

**economic +1 is the +1 band made flesh, and the list confirms it from both directions at once** —
which is why a crowded band is the right answer rather than a vague one. Liberalizing: אלי כהן #2
dismantled the Standards Institute monopoly and legislated an independent Capital Market Authority;
ישראל כץ #4 drove the private-ports reform against the Histadrut; אוחנה #6 is a self-described
free-marketer. Expanding: **מירי רגב #8** runs an explicitly redistributive fare structure and
deprioritised the Tel Aviv Metro for periphery lines, and **חיים כץ #18** was the Histadrut's
pension-funds policy chairman and entered the Knesset on Amir Peretz's Am Ehad before Likud.

**ניר ברקת's fall to #24 is deliberately not read as an economic verdict.** Every source attributes it
to his post-October-7 attempt to replace Netanyahu and to the reserved-slot arithmetic — no analysis
argues economic liberals lost as such, **ארז תדמור**, a declared economic liberal, *entered* the list at
#27, and the "Likud Liberals" faction recently swept the party's internal institutional elections.
Reading a leadership purge as an ideological shift would be the error here.

**religiosity +2 confirmed, not at +3.** Nothing on this list is a halakhic-state programme. The +2
evidence is stronger than ever — a Basic Law declaring Torah study a foundational value, the kashrut
monopoly restored by statute, the law banning arrest of haredi draft evaders (58–54) — and
`conscription-exemption` gains a fresh instance of the mechanism the families doc already cites:
**אופיר כץ at #10 stripped Dan Illouz of two committees and barred him from private bills for six
weeks** over the haredi draft. Individual dissent punished by the leadership is evidence *of* a party
line. Against that, גוטליב #20 refuses the exemption bill and הלוי #33 wants haredim *and* Arabs
conscripted — dissent, not the line.

#### Ten tags added, 4 → 14

- **`judicial-overhaul`** — closes a gap against all three bloc partners, and the largest one on this
  page: the party whose own Justice Minister wrote the overhaul did not carry it. **לוין at #7** is
  its architect and now threatens to paralyse the Court and let it "disappear"; אוחנה #6 floated an
  alternative constitutional court; סער #5 co-authored the enacted March 2025 selection law and
  refuses to reopen it; **אופיר כץ #10**, the coalition whip, has pledged "this time we won't stop";
  שיקלי #16 chaired the ministerial committee that recommended firing the Attorney-General; אמסלם #17,
  סעדה #19 (who revived the bill putting Mahash under the Justice Minister he once served under),
  גוטליב #20 and קרעי #22 fill it out. This clears revision 23's narrow membership test decisively
  — that test refused the tag to המפלגה הכלכלית for backing a *symmetrical* override while opposing
  Rothman's bill; here the party authored Rothman's bill. **The brakes are exactly the people who
  fell**: ביטן #21 counted heads to freeze the overhaul bills, ברקת #24 said he would respect a High
  Court ruling against Levin, and אלקין #32 negotiated the President's-Residence compromise and
  accused Netanyahu of corrupting the reform for personal ends.
- **`no-palestinian-state`**, **`anti-two-state`**, **`security-hawk`** — three gaps that contradicted
  the row's own score: the band Likud sat in is *defined* by the first of them, and ישר, כחול לבן and
  המפלגה הכלכלית all carried all three. Nobody in the top ten is open to a Palestinian state.
  סער #5: "a two-state solution means our end." אוחנה #6 on "the idea that was mistakenly called
  'the two-state solution'."
- **`sovereignty-annexation`** and **`pro-settlement`** — both follow the axis move. אלי כהן #2 on one
  million Jews in the West Bank and connecting settlements to infrastructure; ישראל כץ #4's career of
  converting settlements from security measures into permanent fact; the February 2026 cabinet package.
- **`hardline-on-gaza`** — ישראל כץ #4 "will never fully withdraw" plus outposts inside the Strip;
  רגב #8 rules out any permanent ceasefire; אלמוג כהן #14; סעדה #19; הלוי #33 — "there's no such
  thing as partial control." Second holder after ישראל ביתנו.
- **`preemptive-security-doctrine`** — ישראל כץ #4 as Defence Minister on Iran: Rising Lion was "only
  the preview of a new Israeli policy," and "after Oct. 7, immunity is over." Second holder after אל הדגל.
- **`scholar-exemption-retained`** — the arrest-ban law plus ביסמוט #23's exemption bill, condemned by
  the Attorney-General, the IDF and the Finance Ministry alike. Fourth holder, and this row is the
  first to reach it by *statute protecting non-enlistment* rather than by a quota design.
- **`voluntary-palestinian-emigration-incentives`** — גמליאל #25 authored the Gaza "voluntary
  migration" plan as Intelligence Minister, presented it to the government, and says a Defence
  Ministry directorate and the Mossad are involved. **Its evidence is her ministerial record, not her
  placement** — #25 alone would not carry a tag. Second holder after אל הדגל, and **the tag was
  renamed** from `voluntary-emigration-incentives` in this pass: the old name never said *whose*
  emigration. It is deliberately **not** narrowed to Gaza, because אל הדגל's plank is a benefits
  basket for "Palestinians choosing to leave" with no geographic limit, and גמליאל has extended the
  same logic to the West Bank. Naming a place the evidence does not support is the התיישבות homograph
  failure in reverse. `population-transfer` stays with הציונות הדתית (carried in from the זהות faction, 2026-09-01):
   opt-in is a different claim, and the
  standing warning under בית ציוני about attributing transfer to a party that has not stated it applies
  here in the direction of restraint.

#### Seven rejections, each with a reason meant to outlive the row

- **`opposes-western-wall-compromise` — considered, and dropped after the evidence was checked.** The
  claim was that לוין #7 backed a bill putting the whole Kotel including עזרת ישראל under Rabbinate
  control. What is true is narrower: the bill is **אבי מאוז's** private member's bill, at preliminary
  reading only; its text **does not name the Western Wall** and does not itself ban egalitarian
  prayer — it defines "desecration" as conduct contravening Chief Rabbinate directives, making the
  Rabbinate decision-making rather than advisory. Levin attacked the High Court over its עזרת ישראל
  ruling and announced support for amending the Protection of Holy Places Law — advocate, not
  sponsor — and **Netanyahu pulled the bill from the Ministerial Committee for Legislation at the
  last moment**, so the government never endorsed it. The tag's only other holder is נעם, whose own
  MK wrote it. Attributing it to Likud when the leader killed it inverts the same test that keeps
  `conscription-exemption` on this row: leadership *declining* is evidence against a party line, just
  as leadership *punishing* is evidence for one.
- **`far-right`** — Haaretz ("Likud… is the far right") and Ben-Dror Yemini ("Ben-Gvir did not move
  closer to Likud. Likud moved closer to Ben-Gvir") are journalists' characterisations, and a position
  that appears in a summary but not in a party source does not move this page. The strongest datum
  *for* it is recorded instead: **אלמוג כהן at #14 is a confirmed עוצמה יהודית defector for whom
  Netanyahu personally waived Likud's membership cooling-off rule**, and who placed 8th among elected
  candidates. Trigger for revisiting: a second such absorption, or the position entering a party
  document.
- **`opposes-hostage-deals`** — direct counter-evidence, not absence of evidence. **מיקי זוהר at #13**
  was the public Likud voice *for* the Trump hostage deal against בן גביר and סמוטריץ' — "there's what
  we'd like, and there's what's possible" — and the government approved it. נעם and הציונות הדתית
  earned this tag on candidates at #2 and #3; here the comparable placement argues the other way.
- **`pm-immunity-protections`** — אל הדגל holds it for a Basic Law plank. Likud has אוחנה's 2019
  backing of Netanyahu's immunity bid, which is a personal position on one case, not a constitutional
  programme.
- **`anti-lgbt` and `lgbt-rights`** — the row genuinely splits and **neither is true of the party**.
  **אוחנה #6 voted for an opposition civil-marriage bill as sitting Knesset Speaker in December
  2025**, drawing formal rebukes from ש"ס and דגל התורה, and has broken the party line on surrogacy,
  conversion therapy and adoption — while שיקלי #16 called Pride "disgraceful vulgarity." Recording
  the split in prose is the honest end state; a tag would assert a party position that does not exist.
  Note the limit of Ohana's liberalism too: it is confined to personal status, and he is inert on
  Shabbat and haredi conscription.
- **`deregulation`** — refused as audit coverage. The import reform is already documented above under
  `economic +1`; adding a tag for it now would record that this entry was re-read, not a new position.
- **`sovereignty-annexation` was very nearly refused on the earlier reading**, when this row was still
  +2 and every holder sat at +3. It is recorded here because the reasoning is reusable: a tag whose
  membership tracks a band should move *with* the band, in the same pass, or not at all.

#### Not resolved, and left unresolved deliberately

Four thin records that a Hebrew sweep did not close, listed so the next reader does not repeat the
search: **שיקלי #16** has no locatable statement of his own on West Bank sovereignty, which is odd for
a minister of his profile; **סעדה #19** calls for overhauling the haredi draft law without the
*direction* being determinable, and it points opposite ways on this page's axes; **תדמור #27** has no
on-record religion-and-state position despite being an explicit ideologue resident in Efrat; and
**לרנר #28, שוקי אוחנה #30, משה בנימין פרץ #31 and אטיאס בובליל 34** have no discoverable national
policy record at all — municipal and district figures, one of them plausibly the former mayor of
Safed, whose district (Galilee, not the Beit She'an Valley) is itself disputed in the sources.

**One structural fact that scores nothing but must not be lost.** An Agam Labs survey (11 Aug 2026)
found **54.9% of Likud *voters* want a more centrist government, against about a third of the
~140,000 *members*** who chose this slate. The reserved slots were reportedly used in both
directions — to remove ברקת and אלקין, and to keep firebrands out of top positions because internal
polling showed they repel swing voters. This row is scored on what the party does, not on that gap,
but the gap is the reason a future revision may find the parliamentary party diverging from this list.

### ישר — Yashar · `opposition` · +1 / +1 / −2 · secular

Gadi Eisenkot's party, founded 2025-09-16. Co-founders include Matan Kahana (former Religious
Affairs Minister), Manuel Trachtenberg, Yoram Cohen (former Shin Bet chief), Nir Zohar (Wix).
Source: the party's own site `yasharwitheisenkot.com` — the registered party goals, the 10-step
brochure and all **eleven** principles papers: nine listed under revision 21 below, the last two
under revision 39. `principles-sitemap.xml` enumerates the papers (and their `lastmod` dates) in one
request; the goals and the brochure are not in it, so *papers* and *documents* are separate counts.

This row previously read `new-party` + `undefined-ideology` at a default `0/0/NULL`. That was honest
when written — the party had no platform. It has one now, and polls ahead of Likud, so the
placeholder had become the worst kind of stale: it looked like a classification.

**security +1.** The published agenda contains **no** position on a Palestinian state, the
territories, or sovereignty — the omission is deliberate and reported as such. The score therefore
rests on Eisenkot's own statements, the same evidence route the Reservists needed: *"you will not
find one statement of mine in favour of a Palestinian state"*, **plus** opposition to sovereignty
over Judea and Samaria on the grounds that it produces a bi-national state and forfeits the Jewish
majority, **plus** a single military force between the river and the sea.

**2026-08-16: the demographic premise is now first-party, the conclusion still is not.** The party's
registered goals (`/topic/missions/`, *"כפי שאושרו ע"י רשם המפלגות ב-17.12.2025"*) commit it to
*"הבטחת רוב יהודי מוצק"* alongside *"נחתור לשלום"* and, in the brochure, *"הרחבת מעגל השלום"*. That
is the premise Eisenkot's anti-annexation argument runs on, stated in a document the Registrar of
Parties approved — so `anti-annexation` no longer rests *entirely* on his personal statements. The
inference from it does: **thirteen** documents contain no sentence on a Palestinian state, the
territories or sovereignty — eleven as of revision 21, and the two papers revision 39 added, one of
them about the northern border. **Do not upgrade the tag's basis past what the text says.**

Not +2, which is the interesting call. Every +2 party *that vetoes statehood* pairs that veto with a
territorial claim. Eisenkot has the first half and explicitly refuses the second — his objection to
annexation is demographic rather than dovish, but it is a real refusal. `anti-annexation` had to be
a new tag; the vocabulary only had its opposite, `sovereignty-annexation`, so the position would
otherwise have been invisible and this row indistinguishable from a soft +1.

**religiosity −2.** Core curriculum as a **funding condition** — *"נחיל את חוק חינוך ממלכתי
ולימודי ליבה כסטנדרט מחייב לקבלת מימון ציבורי מלא"*, with funding *"יצומצם באופן משמעותי"* for
institutions that fail the standard — plus a haredi joining track into the state system (ממ"ח) with
full core studies and pedagogical supervision, universal conscription with no compromise (Eisenkot
has said he would prefer another election to a compromise on the haredi draft), civil partnership,
kashrut reform, and Shabbat in the public space devolved to municipalities and communities.

**Not −3, on the funding criterion — the same test that held בית ציוני at −2 in revision 20.**
Disestablishment requires *no state religious funding*; this platform keeps funding religious
education and conditions it, mandates *זהות יהודית-ישראלית* in the national core for every pupil,
and commits the state to *"המחויבות למסורת היהודית"* in its registered goals. It abolishes no
monopoly outright and does not touch the Rabbinate's existence — contrast ישראל ביתנו at −3, which
wants the institution gone. **Devolving and reforming an establishment is not disestablishing it.**
Two wording distinctions carry weight and should not be smoothed over: the platform says
**זוגיות אזרחית** (civil *partnership*, the ברית־זוגיות model), not נישואין אזרחיים, and
**גיור מכבד** — reforming conversion, not removing the Rabbinate from it, which is precisely the
reform co-founder Matan Kahana ran from *inside* religious Zionism.

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

**2026-08-16 — revision 21. The full principles corpus read at last, and it corrected this entry.**
Revision 8 scored the row from "eight principles documents"; there are **nine** principles papers, a
10-step brochure and a registered statement of party goals. **No axis moved.** What moved is the
justification for one of them, plus nine tags.

Sources, all first-party, all read 2026-08-16 (all returned 200 to a plain browser-shaped `curl`;
the brochure PDF extracted cleanly with `pdftotext`, 10 KB from 8 pages):
[10 צעדים לשגשוגה של מדינת ישראל](https://yasharwitheisenkot.com/wp-content/uploads/2026/06/Yashar_10_Steps_Brochure.pdf)
(the brochure, created 2026-06-03) ·
[מטרות המפלגה](https://yasharwitheisenkot.com/topic/missions/) (the registered goals) ·
[חינוך](https://yasharwitheisenkot.com/principles/education/) ·
[שירות ממלכתי לכל](https://yasharwitheisenkot.com/principles/service-for-all/) ·
[מילואים](https://yasharwitheisenkot.com/principles/reservists-honour-and-compensation/) ·
[ביטחון פנים](https://yasharwitheisenkot.com/principles/homeland-security/) ·
[In-location ועלייה](https://yasharwitheisenkot.com/principles/inlocation-and-aliya/) ·
[פוסט-טראומה](https://yasharwitheisenkot.com/principles/post-traumatic-stress-recovery/) ·
[כלכלה](https://yasharwitheisenkot.com/principles/economics/) ·
[חקלאות](https://yasharwitheisenkot.com/principles/agriculture/) ·
[קליטת עלייה](https://yasharwitheisenkot.com/principles/aliyah-and-integration/).

**The religion-and-state planks were filed under immigration absorption, and that is the retrieval
lesson.** `aliyah-and-integration` carries a **מעמד אישי** section and a **המרחב הציבורי והשבת**
section — civil partnership, respectful conversion, IDF-standard burial for terror victims, and
Shabbat in the public space devolved to municipalities and communities. Nothing in the URL, the page
title or the party's own menu suggests a religion-and-state programme lives there. This is the
mirror image of the `homeland-security` trap recorded above: there, a URL invited the wrong axis;
here, a URL concealed the right one. **Read every document in a corpus before concluding an axis is
evidenced, and do not select by filename.**

**Nine tags added (18 → 27), every one from the existing vocabulary — no new label invented:**

- `civil-marriage` — *"נפעל למיסוד זוגיות אזרחית בישראל"*. Fourth holder. See the wording caveat
  under religiosity: זוגיות אזרחית is the weaker Israeli formulation, and this row is the tag's
  weakest case.
- `kashrut-liberalization` — *"נקדם רפורמות בכשרות ובייבוא מוצרים כשרים"*, in the cost-of-living
  chapter, framed as competition policy rather than as religion policy.
- `religious-pluralism` — *"יהדות מכילה ומכבדת"*, *"גיור מכבד"*, and inclusive treatment by state
  institutions *"בתחנות החיים, מלידה ועד פטירה"*.
- `municipal-devolution` and `communitarian-devolution` — *"הרחבת העצמאות של רשויות מקומיות
  וקהילות לעצב את השבת במרחב הציבורי בהתאם לאופיין וערכיהן"*, plus local authorities empowered as
  a central partner running education in their area. The wording names **both** levels, which is
  why both tags apply, exactly as on בית ציוני.
- `state-haredi-education` — *"מסלול הצטרפות למערכת החרדית הממלכתית (ממ"ח), הכוללת לימודי ליבה
  מלאים, פיקוח פדגוגי והסדרת מבני הלימוד"*. The entry had asserted this position in prose since
  revision 7 while the tag was missing — a gap only a corpus read would surface.
- `arab-civil-service` — *"מי שלא משרת בצה״ל, יחויב לשרת במסלול שירות אזרחי"*, with the internal
  security paper adding *"גיוס צעירים לשירות אזרחי חובה"* aimed at Arab-sector crime. **This
  retires the tag's single-holder status** (כחול לבן was alone on it), the same correction revision
  17 made for `death-penalty-for-terrorists`.
- `workforce-integration` — *"מהלך היסטורי לשילוב כלל חלקי החברה הישראלית בשוק העבודה"*, with
  haredim and Arabs named as the target populations.
- `term-limits` — *"כהונתו של ראש הממשלה תוגבל לשתי קדנציות"*, in both the brochure and the
  registered goals, the latter adding a cap on the number of ministers.

**Six candidates rejected, each for a reason that outlives this row:**

- `scholar-exemption-retained` — the 3% one-year deferral is not a retained exemption; see the
  correction under כחול לבן.
- `state-commission-of-inquiry` — declined for a third time, on revisions 15 and 20's precedent.
  Consistency here is the point: this row has the fullest commission document of any party and
  still does not get the tag.
- `periphery-development` — **retired in revision 19 and stays retired.** This corpus would have
  earned it comfortably; that is an argument for the retirement, not against it. Amended note in
  the retirement section.
- `anti-corruption` — the internal-security paper has a dedicated corruption section (a ministerial
  committee, legislative recommendations) and the brochure promises *"מלחמת חורמה נגד שחיתות"*.
  Declined on revision 19's test: opposing corruption is near-universal rhetoric, so a tag sitting
  on one or two rows would measure audit coverage, not position — the `periphery-development`
  failure mode exactly. The institutional half of the position is already carried by
  `governance-reform` and `public-service-reform`, both of which this row holds.
- `gender-equality` — the violence-against-women programme is crime policy in a crime paper.
  הדמוקרטים earned this tag from a dedicated equality paper; the standard should not slip.
- ~~`welfare-state` — this row runs the opposite doctrine, restated verbatim: *"נבטיח שהעבודה תשתלם
  תמיד יותר מקצבה"*.~~ **Reason struck 2026-09-02 (revision 39) — the conclusion survives, the
  argument does not.** Revision 29 granted the tag to ביחד while leaving that row's identical
  workfare finding standing, holding that an aging plan *"is a different class of document"* from an
  economics paper. That bars quoting one document to reject a tag earned in another, which is
  precisely what this line does. Re-rejected on the aging paper alone, and narrowly; see revision 39
  below for the margin and for the line that would earn it.

**economic +1 re-verified and unmoved**, now with the deciding line quoted from the party's own
economics paper rather than from press coverage. Both directions grew: *liberalizing* gains
scrapping Israel-only import standards and parallel imports, kashrut import reform, and cutting
income tax; *expanding* gains a real-time digital reporting regime against the black economy, a tax
on land not being brought to construction, direct financing of building protection and neighbourhood
rehabilitation *"היכן שכוחות השוק אינם מספיקים"*, and mass rail/metro investment. The +2 test
(withdrawing the state) still fails, and means-testing *"אחרי מיצוי השתכרות בלבד"* is workfare
doctrine, not neutrality.

**Two confirmations worth recording because they are re-checks of specific earlier warnings, and
both held.** The `homeland-security` paper still contains nothing on statehood, the territories,
Gaza or borders — it is organised crime, protection rackets, police independence, digital crime and
village defence. And `inlocation-and-aliya`'s *"תמריצים להתיישבות באיזורי עדיפות לאומית"* still
names no region. The agriculture paper adds a **third** instance of the התיישבות homograph flagged
for כחול לבן in revision 15: *"ההתיישבות החקלאית היא ערך ציוני… לצורך ביצור ושמירה על הגבולות"* is
rural/agricultural settlement in the Negev, Galilee and border areas, **not** the West Bank, and
must not be read as `pro-settlement`.

**Two housekeeping notes for the next pass.** The aliya target is larger than this entry recorded:
not "a million olim in a decade" but **a million in the first decade and two million by 2048**, the
state's centenary, which is the frame the whole corpus is built around. And the economics page is
**still carrying Hebrew lorem ipsum** in its body (*"לורם איפסום דולור סיט אמט…"*) — the corpus is
published but not finished, so treat absences on that page as unwritten rather than as positions.


**2026-09-02 — revision 39. The corpus grew 11 → 13 documents; two new principles papers read. No
axis moved, no tag was added, and `seed.sql` is unchanged** — the second pass on this page to end
that way (after revision 36), and again the outcome is the record rather than something to hide.
Both read 2026-09-02:
[ישר! לשיקום ושגשוג הצפון](https://yasharwitheisenkot.com/principles/north-reconstruction-and-prosperity/)
(published 2026-08-17) ·
[ישר! לגיל השלישי](https://yasharwitheisenkot.com/principles/senior-citizens/) (published 2026-09-01).

**The corpus is enumerable in one request, and the `lastmod` dates matter more than the count.**
`https://yasharwitheisenkot.com/principles-sitemap.xml` lists **11 principles papers plus the
`/principles/` index** — the technique revision 31 established for הציונות הדתית, and it answers
three questions the party's own menu cannot. First, **revision 21 was not incomplete**: it read nine
papers, and the two new ones are dated *after* it (2026-08-17, the day after; 2026-09-01). A pass
that reads a corpus and misses nothing still needs a way to prove that, and "nine" alone never
could. Second, it surfaces the **twelfth and thirteenth documents** — the brochure and the registered
goals are not in this sitemap, so the count of *papers* and the count of *documents* are different
numbers and must be stated separately. Third, and the reason to record dates at all:
**`aliyah-and-integration` was modified 2026-08-18, two days after revision 21 read it** — the single
page every religion-and-state finding on this row rests on. Re-checked against the live page: all four
cited phrases (מעמד אישי, זוגיות אזרחית, גיור מכבד, המרחב הציבורי והשבת) are still present, so
religiosity −2 stands on the same text it always did. **A `lastmod` after the read is a re-read
trigger of the same class as revision 22's moved URL**, and it is cheaper — it arrives with the
enumeration instead of waiting for a redirect to be noticed.

**A fourteenth document is cross-referenced and does not exist.** The north paper closes its
execution section with *"להרחבה על מנגנון חוזה פיתוח אזורי בתכנית ישר! לחיזוק הפריפריה הגאוגרפית
ופיתוח אזורי"*. That title is on **no** page in the sitemap, and the near-miss is genuinely
misleading: `inlocation-and-aliya` is titled *ישר! לעליית המיליונים, לשיבה הביתה וIn-location* —
immigration, not periphery. So it is announced but unpublished, and an absence there is unwritten
rather than a position, the same reading the economics page's lorem ipsum already forces. It changes
nothing about `periphery-development`, **retired in revision 19 and still retired**: this corpus now
contains a costed 15-billion-shekel regional programme *and* forward-references a dedicated periphery
plan, which is the third pass running to strengthen the retirement rather than challenge it. A tag
that the best-documented party on the subject would earn from three separate documents, while other
rows hold it on nothing, is measuring audit depth.

**`welfare-state` — rejected for a second time, and revision 21's stated reason has been struck,
because a later pass on a neighbouring row invalidated it.** Revision 21 declined the tag on the
ground that *"this row runs the opposite doctrine"*, quoting the economics paper's
*"נבטיח שהעבודה תשתלם תמיד יותר מקצבה"*. **Revision 29 then bars exactly that move**: it added the
tag to ביחד while leaving the servants law's identical workfare finding standing, on the explicit
holding that the aging plan *"is a different class of document"* and the old reasoning *"was not
wrong, it was about a different document."* ישר's economics paper and its aging paper are two
documents in the same way. So the rejection has to be re-earned on the aging paper alone — and it is,
but narrowly, and the margin is worth stating because this is the closest this row has come:

- **What it has.** *"נעלה את קצבאות הזקנה למי שהכנסתם נמוכה"*, naming Holocaust survivors, olim who
  worked from arrival but accrued a low pension, and lifelong welfare recipients — **and, separately,
  *"נייצר מנגנון קבע לשימור ערך הקצבאות"***, which is not restricted to that cohort. A permanent
  value-preservation mechanism is structurally the same act as re-indexation. No funding source and
  no offsetting cut appear anywhere on the page, which defeats the third clause of revision 21's
  reasoning too.
- **What decides it.** Revision 29's standard is *a change to the statutory formula of a universal
  entitlement, not a budget line* — and ביחד met it by **naming the formula**: the average wage
  instead of the CPI, identifying the 2003 de-indexation it reverses, with ~350,000 people and a
  doubling attached. ישר promises to *build* a mechanism and names neither formula, baseline nor
  scope. That is a commitment to the class of act without the act.
- **The countable discriminator, and it is stark.** **The senior-citizens paper carries no shekel
  figure anywhere** — its only numerals are the 13% population share and two uses of אחוז. It is the
  **one paper in this corpus with no costed measure in it**, against a north paper published two weeks
  earlier that carries ₪15B, ₪6B, ₪3B, ₪250M, ₪225M, ₪7,000 per pupil, ₪2,000/₪3,000 childcare and two
  new corporate-tax brackets. Revision 19's earning standard for `reservist-focused` — **a costed
  benefits package, not rhetoric** — is the one this page fails.
- **The line that would earn it**, recorded so the next pass tests rather than re-argues: name the
  formula or the baseline (indexation to the average wage, to the CPI, or to any stated series), or
  extend the rise past the low-income cohort. Either one and the tag is earned.

Note also the verb. *"נבחן הטלת חובת ביטוח סיעודי לכלל האוכלוסייה"* is the page's most universal
measure and its verb is **נבחן** — *we will examine* — against נפעל ×8, נקדם ×6 and נבטיח ×2
elsewhere on the same page. **Do not score an examination as a commitment**; a mandatory insurance
obligation is in any case a duty imposed on citizens rather than a state transfer, so it would be
weak evidence for this family even as a commitment.

**economic +1 confirmed, sixth reading, and both new papers pull the same way the corpus always
has.** North grows *both* halves again, which is this band's definition rather than evidence against
it: liberalizing gains two new corporate-tax brackets (2.5% on the confrontation line, 5% for the
northern district), accelerated depreciation on the Eilat model, an arnona cut for businesses
2026–2028, a "green track" clearing planning and licensing barriers, and private players admitted to
the electricity transmission network; expanding gains ₪15B over five years with ₪6B of it in
fortification, ₪3B of education funding over a decade, ₪250M of tourism budget, ₪225M of informal
education, state-guaranteed loans, matching grants, direct war compensation to farmers, and a
national-priority **law** for the northern confrontation line modelled on מנהלת תקומה. The
senior-citizens paper is the corpus's **first purely expansionary document — not one liberalizing
sentence in it** — which is worth recording precisely because it does *not* move the axis: the +1
band already covers "subsidies, targeted spending", and 0 would assert no doctrine or a balanced one.
The workfare doctrine that decided +1 against 0 is not contradicted by either paper and is arguably
restated in the aging one, *"נבחן אמצעים שיאפשרו לבני 67 ומעלה להמשיך לעבוד"*.

**`service-conditioned-citizenship` gains its sharpest instance in the corpus, and it is in a
childcare line.** North subsidises daycare for 0–3 in the 0–9 km border strip at **₪2,000 per child
where a parent has completed military service, and ₪3,000 where a parent is an active reservist** —
with no rate at all for a parent who has not served. Every prior instance of this tag on this row is
welfare doctrine ("aid to משרתי מילואים ולמשפחות עובדות ויצרניות"); this one differentiates a
universal child benefit by the parent's service status, in a region whose population is partly Arab.
The tourism chapter does the same in miniature with *"מסלולי 'פייטר' לצפון לחיילים ולמילואימניקים"*.
The tag already sits on this row and no change follows — but if the tag's meaning is ever audited,
this is its strongest single sentence anywhere in the table.

**security +1 unmoved, and the north paper is the second URL on this row that invites the wrong
axis.** A paper about the northern border, published while the confrontation line is still the
subject, contains **nothing** on Lebanon, Hezbollah, doctrine, statehood, the territories or
sovereignty: its "ביטחון" is מיגון — fortification of homes, kindergartens, schools and clinics,
2035 pulled forward to 2030 — plus a 300-officer district enforcement unit against organised crime.
That is the `homeland-security` trap in a new costume, and the count is now **thirteen documents with
no sentence on the conflict**, which continues to make the deliberate-omission reading the right one
and continues to leave the score resting on Eisenkot's own statements.

The paper also supplies a **fourth** instance of the התיישבות homograph flagged in revisions 15 and
21 — *"חבל ארץ של חלוציות, התיישבות, ערבות הדדית"* — Galilee pioneering, not the West Bank, and it
must not be read as `pro-settlement`. And it is the first document in which the party attaches
*"עדיפות לאומית"* to a **named** region (*"חוק עדיפות לאומית לקו העימות הצפוני"*, the northern
confrontation line). That is a data point, **not** a resolution of revision 21's open note:
`inlocation-and-aliya`'s unnamed *"אזורי עדיפות לאומית"* is still unnamed, and unstated is still not
stated.

**religiosity −2 untouched — and the search that established it very nearly lied.** Neither paper
contains any religion-and-state material. The word-level check for רבנות/כשרות/שבת/גיור/נישואין/
זוגיות/חרדי/ליבה/דתי returned hits on both pages, and **every one of them is a locality name in the
contact form's dropdown** — בר גיורא, כפר הנוער הדתי, כפר עזה, מחנה יהודית — as was the sole hit for
עזה on the territorial check. A page-wide grep on a WordPress form page searches a settlement list of
several hundred entries; on this site that list alone can produce apparent evidence for religion,
Gaza and the territories at once. **Read the hit, not the count** — this is the mirror of the
grep failures recorded in the root `CLAUDE.md`: there a pattern could never match, here it matched
something that means nothing, and both look like findings.

### ביחד — Together · `opposition` · 1 / NULL / −2 · secular

A **list of two legally separate parties** (Bennett 2026 + Yesh Atid), formed 2026-04-26 with
Bennett as chair and Lapid at #2. The components remain separate and autonomous.

**security is NULL and must stay NULL.** This is not the party dodging the topic — it is a genuine
internal contradiction. Lapid's position is that a Palestinian state is *postponed, not dropped*,
with the PA heading Gaza; Bennett rules one out. A single number cannot represent both, and
`internally-split-on-conflict` says so. **Do not "fix" this NULL by averaging the two.**

**economic +1**, from Bennett's cost-of-living programme presented 2026-06-30
([be-yahad.org.il/plans/yokermichya](https://be-yahad.org.il/plans/yokermichya/) — **the URL moved;
the `plans/yoker` this entry used to cite now 301s here** — plus launch coverage for the measures not
on that page). The programme pulls both ways and nets out where it already was:

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

**~~`kashrut-liberalization` is not evidence for `anti-clerical` here~~ — reversed 2026-08-17, and
the reversal was signalled by a moved URL.** This entry read that Together's reform "recognizes
foreign certifiers that the rabbinical authorities *approve*, explicitly without changing Chief
Rabbinate procedure — liberalization inside the Rabbinate's framework." The live plan says the
opposite, in a headline plank: **נשבור את מונופול הרבנות** — *break the Rabbinate's monopoly* — with
automatic recognition of international certifiers (*"מה שכשר באירופה, כשר בישראל"*), supervision
moved to the level of the certifying body rather than product-by-product Rabbinate review, and the
explicit finding that the obligation to show Rabbinate certification *"מרוקנת מתוכן חלקים
מהרפורמה"*. **Kashrut is now anti-clerical evidence on this row, and the strongest single piece of
it.** Whether the page was rewritten or the original reading was wrong cannot be settled from here —
but `plans/yoker/` **301-redirects to `plans/yokermichya/`**, which is the cheapest evidence
available that the page was reworked. **Treat a redirect on a cited source as a re-read trigger.**

`anti-clerical` is *also* carried by the education plan, and those claims all verified against the
live text: defunding religious school networks (*"נבטל תקצוב לרשתות פוליטיות, מוסדות פטור ובתי ספר
מגזריים בדלניים"*, under the slogan *"לא ממלכתי – לא על חשבוני"*), the **60%** core-curriculum
funding condition (*"נחייב 60 אחוזים מהתוכנית שתהיה תוכנית ליבה ארצית"*), full state supervision of
haredi education, and universal conscription. Those four claims were correct as written but had **no
source cited**, which is why nobody noticed the kashrut sentence next to them had gone stale.

**Watch:** Bennett was reported in mid-June 2026 to be weighing dissolving the list over polling. If
it dissolves, this row does not get reclassified — it gets **split back into two rows**.

**Re-checked 2026-08-01 and the NULL is confirmed, not merely unresolved.**
[he.wikipedia](https://he.wikipedia.org/wiki/ביחד_(רשימה)) still records the two parties as
"separate and independent, cooperating within the framework of the list", with **no joint platform
published** — three months after formation and under three months from the election. The security
NULL therefore rests on a re-verified absence rather than on a stale reading. The dissolution watch
above is also still live and was reported again in mid-June by Channel 13, so the split-into-two-rows
branch remains the likelier resolution of this row than a joint position.

**2026-08-17 — revision 22. The plans corpus read in full for the first time. No axis moved; one
justification reversed and seven tags added.** This entry had cited **one** page and referred to
"the education and civil-service plans" in prose without linking either. The party publishes
**four**, and the index is the only place that says so:
[יוקר המחיה](https://be-yahad.org.il/plans/yokermichya/) ·
[מערכת החינוך](https://be-yahad.org.il/plans/education/) ·
[חוק המשרתים](https://be-yahad.org.il/plans/servant-law-new/) ·
[״ביחד נתקן״ – חוק המשרתים](https://be-yahad.org.il/plans/meshartim/) (the campaign landing version
of the same law, carrying the costing the other page omits). All read 2026-08-17, all 200 to a plain
browser-shaped `curl`. **Enumerate `/plans/` before assuming a corpus is mined** — this row was
scored for four months off one page out of four.

**Seven tags added (9 → 16), all from the existing vocabulary.** Three come from the education plan
and four from the servants law:

- `core-curriculum` — *"נחייב 60 אחוזים מהתוכנית שתהיה תוכנית ליבה ארצית"* as a condition of public
  funding. **This row has sat at −2 since the axis was created, and the funding condition is the
  criterion that defines that band — yet the tag was missing.** The same gap `state-haredi-education`
  had on ישר until yesterday: the position was asserted in this entry's prose and never tagged.
- `state-haredi-education` — *"העברת 90% מהתלמידים בפיקוח חרדי למוסדות חינוך ממלכתיים-חרדיים תוך
  שמונה שנים"*, a dated numeric target, which is more specific than any other holder's version.
- `municipal-devolution` — the education plan's headline: dissolve the districts, reduce the
  ministry to a regulator, and move *"70% מהחלטות החינוך"* to local authorities and school heads.
- `reservist-focused` — the servants law is almost entirely reservist benefits: **₪1M off one home**
  for every active reservist with no lottery, free daycare (₪3,750/mo for combat), 50% off
  electricity, water, arnona and vehicle testing, free public transport, a free BA for all servers
  and a free MA for combat.
- `sanctions-on-non-servers` — *"מי שלא משרת – לא מקבל!"*, abolishing avrech stipends, National
  Insurance discounts, the avrech-equals-student status, arnona discounts and daycare subsidy for
  non-servers. **These are individual benefits, not institutional funding**, which is the side of
  the line revision 15 drew when it *denied* this tag to הדמוקרטים.
- `service-conditioned-citizenship` — benefits are explicitly tiered (combat → combat-support →
  regular service → national service, with active reservists on a further tier).
- `workforce-integration` — *"עשרות אלפי חרדים יצטרפו למעגל התעסוקה והשירות"*, presented as the
  law's central mechanism rather than a side effect.

**`universal-conscription` confirmed — but note the enforcement mechanism, because three rows now
hold this tag with three different ones.** ביחד's law is **sanctions-only**: it abolishes the
benefits that "fund evasion" and offers *"כולם מוזמנים לקחת חלק"*, with **no criminal penalty
anywhere in either page**. ישר attaches *דין פלילי* to non-service; כחול לבן pairs coercion with
fines. The tag is right on all three; the mechanism is not the same, and a reader comparing them
should not assume it is.

**Bennett says this in his own voice, which corroborates the documents from outside them:**
*"לא אשים בכלא, אבל מי שלא יתגייס - לא יקבל שקל"* — I will not jail them, but whoever does not
enlist will not get a shekel — alongside *"יש היום 50 צינורות של כסף שזורם, אני סוגר את הדבר הזה"*
([ynet, 2026-06-02](https://www.ynet.co.il/news/article/rj00itc9gzx)). The plan pages and the party
leader arrive at the same finding independently, which is as strong as evidence gets here.

**It is NOT a religiosity criterion, and the next reader should not re-derive it as one.** The
temptation is to read "refuses to jail evaders" as a milder religion-and-state posture and hold the
row at −2 on that basis. Two things defeat it. First, **consistency**: ישר carries *דין פלילי* and
כחול לבן carries fines, and both sit at −2 as well — so if enforcement severity moved this axis,
willingness to imprison draft evaders would have to count as *more* separation of religion from
state, which it plainly is not. Enforcement appetite and religion-state posture are different
dimensions. Second, **it is not even milder**: *"לא יקבל שקל מהמדינה"* and closing "50 channels of
money" is a **broader** financial sanction than ישר's itemized list. Softer on criminal law, harder
on money. −2 on this row rests on the funding criterion, exactly as on the other two. `conscription-by-incentive` remains **wrong** here despite the incentive
framing — that tag is defined by rejecting *both* coercion and sanctions, and this programme is
built on sanctions.

**economic +1 confirmed and unmoved, on a much larger evidence base.** Every rightward measure this
entry lists verified against the live page (212% milk-powder tariff, 85% on some produce, the
European-standards principle, one Food Authority replacing three approval bodies), as did every
coercive one (dissolving named monopolies, an importer barred from carrying more than one
monopolistic brand, mandated transparency). What is new is the **scale of the statist half**:
₪8.8B redirected from coalition funds, avrech stipends and closed ministries, plus the housing
benefit, which the party itself costs at **~₪16B per year** and argues is free because it is
*forgone land revenue* rather than expenditure — *"אין שינוי בהוצאות הממשלה, יש שינוי בסדר
העדיפויות"*. **Record that as the state expansion it is, not as the accounting the party gives it.**
It still does not reach a different band: the +1 definition already covers subsidies and targeted
spending, and nothing here withdraws the state.

**security NULL re-verified, and its basis is now much stronger than an absence on Wikipedia.** Four
substantial policy documents, none containing a sentence on a Palestinian state, the territories,
Gaza or borders. The NULL rests on four read documents rather than on no documents being found.

**religiosity −2 confirmed by the funding criterion — the third row in three days.** ביחד defunds
non-supervised religious education comprehensively but keeps funding the state-haredi stream it is
pushing pupils into. Same shape as ישר and בית ציוני. **This sharpens the open question filed
yesterday**: the −3 band reads "end the Rabbinate's monopolies outright, civil marriage, no state
religious funding" as a package, and this row now *does* end a Rabbinate monopoly outright (kashrut)
while failing the funding test and publishing nothing on marriage. Three rows, three different
subsets of that band's three criteria, all correctly at −2. The band needs rewriting, not stretching.

~~**`welfare-state` rejected** — the transfers are conditional, targeted at one population, and
explicitly deficit-neutral by cutting other transfers.~~ **Overturned 2026-08-26 (revision 29) — and
the old reasoning was not wrong, it was about a different document.** Every clause of it describes
the servants law, where it still holds. The aging plan defeats all three: the pension re-indexation
is universal and statutory, no offsetting cut is named anywhere in it, and the plan accepts the cost
in as many words. See revision 29 below.

**2026-08-26 — revision 29. Two new plans (`הזדקנות-בכבוד`, `women`), corpus 4 → 6. No axis moved;
one tag and one family added, and one standing rejection overturned.** Both read 2026-08-26 from the
party's own site:
[תוכנית לאומית להזדקנות בכבוד](https://be-yahad.org.il/plans/הזדקנות-בכבוד/) ·
[ביחד נתקן את מעמד הנשים בישראל](https://be-yahad.org.il/plans/women/).

**The `/plans/` index is paginated, and revision 22's "enumerate the index" rule is not enough on
its own.** That revision found four plans by listing the index and recorded the lesson as *enumerate
before assuming a corpus is mined*. The index now carries a `page/2` link. It happens to list the
same six posts, so nothing was missed this time — but a rule that says "read the index" and stops
there will miss a seventh plan the moment the first page fills up. **Enumerate every page of the
index, and record the page count, not just the plan count.**

**`gender-equality` added (16 → 17 tags), third holder, on revision 23's line exactly.** That
revision granted the tag to המפלגה הכלכלית for "a dedicated programme covering pay/promotion equality,
statutory representation, gender education, הדרת נשים והפרדה מגדרית and עגונות ומסורבות גט",
and revision 21 *declined* it for ישר as "crime policy in a crime paper". This plan is the granted
shape and not the declined one: **four of its seven sections are not about violence** — a multi-year
programme for **50% women** in the senior civil service and in government-company boards, a mandatory
gender opinion on every bill reaching the ministerial legislation committee, a party-funding
incentive for women on Knesset lists, daycare subsidy plus paternity leave against the *"קנס
האמהות"*, enforcement powers for the Equal Opportunities Commissioner and gender targets in
high-tech. The violence half is the *other* three sections and carries the only costed figure on the
page, **₪250M a year**, permanent.

**`welfare-state` added to the families (3 → 4), overturning two prior rejections.** The aging plan is
a different class of document from the servants law those rejections were about. Its headline
instrument is **re-indexing the old-age pension to the average wage instead of the CPI** — a reversal
of the 2003 de-indexation, which the plan names as the cause of the erosion it is fixing. That is a
change to the statutory formula of a universal entitlement, not a budget line: it is the same class
of act as בית ציוני's public housing 50,000 → 110,000 and its replacement of the 1958 חוק סעד,
which is what earned *that* row the family in revision 20. Alongside it: a differential rise for
**~350,000** citizens with income under ₪10,000 with the poorest's pension **doubled**, expanded
arnona and electricity eligibility, a higher nursing benefit with the Israeli-vs-foreign-worker
distinction abolished, and an **automatic indexation mechanism** for Holocaust survivors' monthly
payment. **No funding source and no offsetting cut appear anywhere in the plan** — it argues the
opposite way, that national spending in the field may double as a share of GDP if nothing is built
now. Note the family does not follow the axis: בית ציוני is `economic +1` and carries both
`cost-of-living` and `welfare-state`, so this row is the second such case, not a novel one.

**economic +1 confirmed, and the statist half is now much larger than the liberalizing half.** Both
new plans are pure state expansion — the only liberalizing sentence in either is increasing the
supply of foreign care workers. The row still sits at +1 because the +1 definition covers "subsidies,
targeted spending" and the trade programme (tariff abolition, European standards, one Food Authority)
is untouched; **0 would assert "no economic doctrine, or a genuinely balanced one"**, and a party
with a published tariff-abolition programme has a doctrine. **Say what would move it**, since three
revisions running have now added statist material to this row without moving the number: a withdrawal
of the liberalizing half, or a transfer programme presented as the party's economic doctrine rather
than as a sectoral plan, would.

**security NULL re-verified — six documents now, and the trigger the open question named has fired
once with no result.** That item says to re-check `/plans/` for a security page rather than wait for
a joint platform. There are two new plans and neither is one. **The sharpening is that the women's
plan does discuss the IDF** — expanding women's combat roles, and a dedicated body for reservists'
families — so this list now publishes on the military without publishing a sentence on the conflict,
the territories, Gaza, borders or statehood. Declining the subject while writing about the army next
door to it is stronger evidence of the internal contradiction than silence was.

**religiosity −2 confirmed, and the women's plan is the first religion-and-state material on this row
that is not about education or kashrut.** It commits to **repealing the laws that expanded the
rabbinical courts' authority**, mandatory legal training for דיינים, preventive measures against
get-refusal and עגינות, adequate representation for women in the religious councils and in the
assemblies that elect rabbis, and repeal of the gender-separation-in-academia law. Get-refusal is
established religiosity evidence, not only gender evidence — revision 15 confirmed הדמוקרטים's −3
from exactly that third motive. **It does not reach −3 and the reason is the funding criterion
again**, unchanged: state-haredi education stays funded. **What it does do is add a fourth subset to
the −3 band's open question from a single row** — this row now rolls back a religious court's
jurisdiction *and* ends a Rabbinate monopoly outright *and* publishes nothing on civil marriage *and*
fails the funding test. The band text remains the defect.

**`civil-marriage` still rejected, and this is the document where its absence counts.** A dedicated
women's-status plan that addresses עגינות and get-refusal by **training דיינים and adding
preventive measures inside the rabbinical system**, while repealing the courts' *expansion* rather
than their jurisdiction, is a deliberate choice not to propose civil marriage where the subject
demanded it. Record that as a position, not as a gap.

**Two further tags rejected.** `religious-pluralism` — the religious content here is women's
representation inside the existing establishment and a limit on its courts, not recognition of
non-Orthodox streams, which is what ישר, הדמוקרטים and בית ציוני hold it for.
`affirmative-action` — the 50% target, the hiring goals and the party-funding incentive are real
instances of it, but `gender-equality` is already carrying that exact evidence; tagging both records
one document twice, which is revision 21's reason for refusing `anti-corruption` next to
`governance-reform`.

**Two notes for the next reader.** The environment sweep filed in Open questions lists this row as a
likely holder: **six plans, and none of them is environmental** — that is a data point for the sweep,
not a verdict, since none of the six is the kind of document where it would appear. And the aging
plan's section 06 contains a drafting error — *"נבטל את נקבע יעדים ממשלתיים לתעסוקת אזרחים
ותיקים"* — where the summary section above it reads plainly *"נקבע יעדים"*. **Nothing is
abolished there**; a reader taking the sentence literally would record the opposite of the plan's
position.

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

**2026-08-31 — the eleventh paper (חברה ערבית) read, and the August platform booklet proven to be a
re-package. No axis moved and no tag was added; `seed.sql` is unchanged by this pass.**

The party published a dedicated Arab-society paper — five steps: a national task force to destroy the
criminal organisations; statutory master plans for the Arab, Druze and Bedouin localities with
*"נבטל את חוק קמיניץ"*; a new five-year plan for gap closure with full budget execution and oversight;
equal per-pupil education funding *"נשים סוף לאפליה התקציבית בין זרמי החינוך"* by uniform criteria,
plus Arab teachers into the Hebrew system and strengthened Hebrew and English in Arab education; and
*"נעגן את עקרון השוויון בחוק יסוד ונתקן את חוק הלאום"* with adequate representation of Arab citizens
in the ministries, the government companies and the decision-making centres.

- **All three axes hold.** economic **−2**: distributive spending — five-year plan, infrastructure,
  employment, transport, industrial zones, equal per-pupil funding — with no tax rate, no
  nationalization and no privatization anywhere in the document, which is the same social-democratic
  shape the economic paper set. security **−1**: מדינה פלסטינית, פלסטינ, כיבוש and שתי מדינות each
  occur **0 times**. Revision 15 left the standing instruction *"two documents now lean on this
  boundary — if a third does, re-open the −1"*; **this is not that third document**, it presses on
  the boundary in neither direction, so the −1 stands at eleven papers. religiosity **−3**
  untouched — the paper carries no religion-and-state content, and the axis is scoped to *Jewish*
  religion-and-state regardless.
- **`jewish-arab-partnership` is already held as both a tag and a family, and this paper is now its
  strongest first-party evidence.** Until today the row earned it from the realized list (בשיר at
  #10) and from scattered lines in other papers; it now rests on a dedicated programme.
- **`affirmative-action` considered and rejected, and the precedent forces it.** The paper asks for
  *"ייצוג הולם"* with no target, no mechanism and no enforcement. Revision 29 refused this same tag
  to ביחד on a **50% representation target plus a party-funding incentive** — strictly stronger
  evidence than a bare adequacy clause. Granting it here would silently lower a bar set five days
  ago.
- **`arab-representation` and `focuses-on-arab-israeli-civil-issues` rejected on the
  `reservist-movement` distinction this row already carries.** Both record what a party *is*
  (הרשימה המשותפת, רע"ם), not that a Jewish-Zionist party has a policy about Arab citizens. Note the
  adjacent trap: **`arab-civil-service` is not about civil-service employment.** It marks a
  *national-service track for Arab citizens* (כחול לבן's founding position, אל הדגל's bill §8), which
  is conscription policy, not representation policy. The name invites exactly the wrong match.
- **`sectoral-budgeting` rejected, but the tension is real and is recorded rather than tagged.** The
  party's own economic paper opens its first step with *"במקום תקציבים מגזריים, נשקיע בתעסוקה
  ובשירותים החברתיים"*, and this paper demands a תוכנית חומש, which is a sectoral instrument. The tag
  is held by הליכוד, הציונות הדתית, ש"ס and יהדות התורה for coalition funds; a gap-closing five-year
  plan of the 922/550 kind is not that, and stretching the tag to cover both would erase the
  distinction it exists to draw.
- **The finding is a silence.** גיוס, שירות לאומי and שירות אזרחי occur **0 times** in the paper.
  Revision 15 left open who *"הרחבת גיוס של אוכלוסיות נוספות"* means on a row carrying
  `jewish-arab-partnership`. A dedicated Arab-society paper — published after that clause, covering
  crime, planning, budget, education and legal status — is the most natural place a clarification
  would have appeared, and it is not there. That does not prove the vagueness is deliberate; it
  removes the reading that it was merely an unfinished sentence. The question stays open and narrows.
- **A tag is missing from the vocabulary and is deliberately not created here.** Nothing among the
  135 tags covers **repeal of the Kaminitz Law and statutory planning for Arab, Druze and Bedouin
  localities**, which is this paper's most specific and least universal plank — the opposite of the
  near-universal rhetoric that got `periphery-development` retired. הרשימה המשותפת and רע"ם very
  likely hold the same position, so revision 19's rule applies: **read the content first, then create
  the tag with membership decided in one pass.** Filed under Open questions rather than half-created
  on one row.

**`plan-8-26-he.pdf` — the 16-page booklet the homepage links as the platform — adds nothing, and
proving that was the larger half of this pass.** It is dated 2026-08-11 and looks like a major new
platform; it is a consolidation of eight papers this file has already read. Measured by sentence-level
containment: **מדיני-ביטחוני 48/48, דמוקרטיה ומשפט 44/44, חברתי-כלכלי 36/36, דת ומדינה 39/39,
חינוך 39/39 and סביבה 40/40 are verbatim.** The crime and להט"ב chapters showed apparent divergence
(17/26 and 9/36) and **that divergence was an artifact, not a finding** — every distinctive token
(*חברת ביטוח ממשלתית*, *ועדה קרואה*, *עוצרים את הדימום*, *קבינט פשיעה*, *טיפולי המרה*, *פונדקאות*,
the ₪100M departmental budget) is present in both, and the chapters match the papers in length to
within 4%; `pdftotext` reorders the bulleted columns, so whole-sentence equality fails on text that is
identical. **Checking the tokens before believing the sentence diff is the point** — the same
discipline as running a `grep` against input you know should match. The booklet **omits** מילואימניקים,
שיווין מגדרי and this Arab-society paper entirely (0 of its 34 sentences appear in it), so it is a
strict subset of the corpus and is listed below as a convenience copy, not an eleventh source.
Enumerating the site is what surfaced it: the S3 bucket refuses `ListObjectsV2`, and no page on
`democrats.org.il` links the topic PDFs at all — the booklet is reachable only from the homepage.

**2026-09-03 — the twelfth and thirteenth papers (פיתוח הצפון והדרום, המרחב הכפרי והחקלאות) read.
No axis moved; four tags added, all from the existing vocabulary.**

Both are on the same S3 bucket and neither is linked from anywhere on `democrats.org.il`. Re-checked
today via `sitemap_index.xml` → six sub-sitemaps: the only PDF any page on the site links is the party
constitution. Revision 36 recorded that the bucket refuses `ListObjectsV2` and that no page links the
topic PDFs; that still holds, so **this corpus can only grow by someone handing over a URL** —
enumeration cannot reach it. Recorded as a bound on the method rather than a failure of it.

- **All three axes hold.** economic **−2**: at least ₪15B added to the תנופה multi-year plan, a
  separate multi-year budget framework for the north and south, expanded government support for
  industry, local procurement, multi-year direct agricultural support and state-led energy planning —
  distributive and directive throughout, with no tax rate, no nationalization and no privatization in
  either document. religiosity **−3** untouched: neither paper carries religion-and-state content.
  security **−1** — below.
- **security −1 held, and this is a stronger hold than revision 36's.** מדינה פלסטינית, פלסטינ,
  כיבוש and שתי מדינות occur **0 times in both papers** — the same count חברה ערבית returned, but the
  two cases are not alike and the difference is the finding. חברה ערבית had *no security content at
  all*, so its silence proved little. The north–south paper's **first step is a full war-termination
  and regional-arrangement programme**: alternative governance to Hamas and international forces in
  Gaza, demilitarization of the Strip, Hezbollah beyond the Litani with international enforcement and
  a phased disarmament agreement with Beirut, alongside zero tolerance for security violations and
  significantly reinforced settlement defences. A party that writes that much about ending the war
  and still names neither the state nor the occupation is **declining the subject, not omitting it
  for want of space**. Revision 15's standing instruction — re-open the −1 if a *third* document leans
  on the boundary — is **not** triggered: this one presses in neither direction, and it presses hard.
- **`anti-annexation` becomes fiscal, and it is filed under a development heading.** The north–south
  paper's growth-engines step opens *"במקום תקציבי עתק למאחזים ולסיפוח והטבות מס למתנחלים, נפנה
  תקציבים לשינוי מציאות בצפון ובדרום"* — the party's most explicit statement that the settlement
  enterprise is a budget line to be redirected rather than only a diplomatic position to be reversed,
  and it is in a regional-development paper, not the security paper. Same shape as ישר's
  `aliyah-and-integration` concealing religion-and-state policy: **a heading is a poor index of which
  axis a document bears on.** No tag change — the row already holds `anti-annexation` — but the
  evidence is now budgetary as well as diplomatic.
- **`agricultural-protectionism` added, and the tag loses its single-holder status** (ישר was alone).
  The *rejection* standard is what decides it: revision 23 refused this tag to המפלגה הכלכלית on the
  ביחד precedent because both **abolish** tariffs and substitute direct subsidy — "direct support
  replacing protection is a liberalizing move with a safety net; that is not what the tag records."
  This paper does the opposite in as many words: *"ננהל את מדיניות הסחר כך שתגן על הייצור המקומי"* —
  trade policy managed **to protect** local production. It also clears two of ישר's three named
  elements outright, **national production targets** (*"בהתאם ליעדי הייצור הלאומיים"*) and **state
  management of the water economy** (*"נסדיר את משק המים"*), and substitutes a national-security
  framing (*"ייצור מקומי, מלאי חירום וניהול סיכונים, כחלק בלתי נפרד מתפיסת הביטחון הלאומי"*, under a
  2050 national plan) for ישר's legislated *ענף אסטרטגי חיוני* status; only that legislated-status
  element is absent. **The tag now spans +1 and −2**, which is the point of carrying it — agricultural
  protection is not an artefact of where a party sits on the economic axis.
- **`cost-of-living` added, and it closes a gap this page has carried since revision 12.** Step 4 of
  the rural paper is titled *"נוריד את יוקר המחיה"* and names its mechanisms: farmers' bargaining
  power, narrowed intermediation margins, marketing-chain transparency, trade policy. But the economic
  paper already supported the tag when it was read on 2026-08-01 — this entry has recorded "breaking
  up food/pharma/energy cartels, restored price controls" ever since, and the tag was simply never
  added. **The new paper found the gap; it did not create it.** Worth stating, because the inverse
  error — a second document mistaken for the evidence the first supplied — is already recorded on this
  page under אל הדגל.
- **`municipal-devolution` and `communitarian-devolution` added together, on the ישר precedent that
  wording naming both levels earns both.** North–south: *"נרחיב את סמכויות הרשויות המקומיות, ונעמיד
  לרשותן את המשאבים, כוח האדם והיכולות המקצועיות הנדרשים למימושן"* — a powers transfer that is also
  resourced, plus dedicated budgets for local-authority human capital. Rural: *"נבטיח כי החלטות
  מהותיות על תשתיות אנרגיה במרחב הכפרי יתקבלו בשיתוף ובהסכמה עם הרשויות המקומיות והיישובים הנוגעים
  בדבר"* — **agreement, not consultation**, from both levels, over siting in a national energy
  programme the same paper wants the state to lead. The domain is planning and infrastructure rather
  than Shabbat (ישר) or education (ביחד); the transfer is comparable in kind.
- **`statist` considered and rejected**, though *"המדינה תחזור להוביל את תכנון משק האנרגיה... ולא
  תפקיר את עיצוב המרחב ליוזמות פרטיות"* is as direct a statement of state direction as any holder's.
  All three (ישר, כחול לבן, בית ציוני) sit at economic **0 or +1**, where the axis alone would
  hide state expansion; on a **−2** social democrat the axis already records it and the tag would add
  nothing. Logged in the other direction: `statist` is one of the few tags this page never defines
  anywhere in prose, so its standard exists only in its membership.
- **`anti-monopoly` considered and rejected on these two papers.** *"נצמצם את פערי התיווך"* is an
  intermediation-margin claim, not a market-structure one. The economic paper's cartel-breaking may
  well earn it — six rows hold it — but that is old evidence and belongs to a pass that re-reads that
  document, not to this one.
- **`periphery-development` stays retired, and this is the fifth documented programme against it.** A
  dedicated north-and-south development paper from a fifth party is revision 19's argument for the
  retirement, not against it: the honest end state remains a tag on most of the table. The retirement
  section is amended rather than left asserting a count that has moved.
- **An environment tag stays uncreated.** The rural paper accelerates the renewable transition, funds
  agrivoltaics with continued cultivation required, and demands integrated national energy planning.
  Revision 23 considered and declined to create such a tag against המפלגה הכלכלית's serious
  environment programme; this is a second qualifying corpus and the same reasoning holds, for the same
  reason it holds for periphery development.
- **Two homographs, and the second is a live trap.** `התיישבות` occurs **4 times in the rural paper**
  and means kibbutzim, moshavim and border localities — the fourth instance this page records (the
  other three are on ישר), and the sharpest, because this row carries `anti-annexation` and its *other*
  new paper defunds מאחזים and סיפוח in the same breath. More dangerous: `גיוס` occurs **once** in the
  north–south paper, in *"נשקיע תקציבים בהכשרה, גיוס וחיזוק ההון האנושי ברשויות המקומיות"* —
  **recruitment of municipal staff, not conscription.** Revision 15's open question about who
  *"הרחבת גיוס של אוכלוסיות נוספות"* means is tracked by grepping that exact token, so the sweep that
  exists to answer it returns a hit from this paper bearing on it not at all. **The question is
  unchanged**: neither paper mentions conscription, national service or civil service.
- **One first-party document is still uncited** —
  [חוקת המפלגה](https://democrats.org.il/wp-content/uploads/2025/10/constitution_240725.pdf)
  (2025-07-24), linked site-wide in the footer. An organisational constitution rather than a policy
  platform, so it is unlikely to bear on any axis; recorded so the next pass knows it was seen and
  skipped deliberately rather than missed.

Sources: the thirteen papers below — the first eight read 2026-08-01, מילואימניקים and שיווין מגדרי
2026-08-11, חברה ערבית 2026-08-31, and פיתוח הצפון והדרום and המרחב הכפרי 2026-09-03 — all first-party
(`democrats-media.s3.us-east-1.amazonaws.com`):
[מדיני־ביטחוני](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%93%D7%99%D7%A0%D7%99+%D7%91%D7%99%D7%98%D7%97%D7%95%D7%A0%D7%99+(1).pdf),
[כלכלי־חברתי](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9B%D7%9C%D7%9B%D7%9C%D7%99+%D7%97%D7%91%D7%A8%D7%AA%D7%99+(2).pdf),
[דת ומדינה](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%93%D7%AA+%D7%95%D7%9E%D7%93%D7%99%D7%A0%D7%94.pdf),
[דמוקרטיה ומשפט](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%93%D7%9E%D7%95%D7%A7%D7%A8%D7%98%D7%99%D7%94+%D7%95%D7%9E%D7%A9%D7%A4%D7%98.pdf),
[חינוך](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%99%D7%A0%D7%95%D7%9A.pdf),
[להט"ב](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9C%D7%94%D7%98%D7%91+(2).pdf),
[חיסול הפשע המאורגן](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%99%D7%A1%D7%95%D7%9C+%D7%94%D7%A4%D7%A9%D7%A2+%D7%94%D7%9E%D7%90%D7%95%D7%A8%D7%92%D7%9F.pdf),
[סביבה](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%A6%D7%A2+%D7%A1%D7%91%D7%99%D7%91%D7%94.pdf),
[מילואימניקים](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%9E%D7%99%D7%9C%D7%95%D7%90%D7%99%D7%9E%D7%A0%D7%99%D7%A7%D7%99%D7%9D.pdf),
[שיווין מגדרי](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%A9%D7%99%D7%95%D7%95%D7%99%D7%95%D7%9F+%D7%9E%D7%92%D7%93%D7%A8%D7%99.pdf),
[חברה ערבית](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%97%D7%91%D7%A8%D7%94+%D7%A2%D7%A8%D7%91%D7%99%D7%AA.pdf),
[תוכנית פיתוח הצפון והדרום](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%AA%D7%95%D7%9B%D7%A0%D7%99%D7%AA+%D7%9C%D7%A4%D7%99%D7%AA%D7%95%D7%97+%D7%94%D7%A6%D7%A4%D7%95%D7%9F+%D7%95%D7%94%D7%93%D7%A8%D7%95%D7%9D.pdf),
[המרחב הכפרי ושמירה על החקלאות הישראלית](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%94%D7%9E%D7%A8%D7%97%D7%91+%D7%94%D7%9B%D7%A4%D7%A8%D7%99+%D7%95%D7%A9%D7%9E%D7%99%D7%A8%D7%94+%D7%A2%D7%9C+%D7%94%D7%97%D7%A7%D7%9C%D7%90%D7%95%D7%AA+%D7%94%D7%99%D7%A9%D7%A8%D7%90%D7%9C%D7%99%D7%AA.pdf).
Plus the consolidated booklet
[תוכנית הדמוקרטים, אוגוסט 2026](https://democrats.org.il/wp-content/uploads/2026/08/plan-8-26-he.pdf)
(16pp, on the party site rather than the S3 bucket), which is **a re-package of eight of the above
and carries no text of its own** — see the measurement in the 2026-08-31 block. It is listed so the
next pass recognises it instead of re-reading it.
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
universal conscription. Civil marriage is not load-bearing for this band, and the band text says so
— but note the supporting example has changed: **revision 21 found that ישר does demand civil
partnership** (*"נפעל למיסוד זוגיות אזרחית בישראל"*), so it is no longer a case of a −2 party
without one. This row still is, as are ביחד and אל הדגל.

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
*"תורתו אומנותו"* exemption for genuine Torah scholars — and the gap to ישר at −2 is real, but
**revision 21 narrowed it, and the earlier wording ("the exact compromise Eisenkot refuses") was too
strong.** ישר's own service page reserves *"עד 3%"* of each draft cohort for a **one-year deferral**
for Torah study — open competitive selection on external criteria, on the same footing as the
carve-out it grants athletes and scientists, with **induction and basic training required of every
recipient**, annual renewal on continued compliance, and criminal liability for false reporting.
That is a bounded *deferral*, not a retained *exemption*: B&W's carve-out is open-ended with quotas
fixed in law and no service attached. **`scholar-exemption-retained` was therefore considered for
ישר and rejected** — putting it on both rows would erase the exact distinction the tag exists to
draw. The −1/−2 gap survives on that distinction rather than on ישר refusing any carve-out at all.
`scholar-exemption-retained` records it,
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

**2026-09-04 — two documents read, and the pass turned into a gap audit. Four tags added (8 → 12),
one family added, `family_evidence` corrected `record` → `platform`. No axis moved.**

Read: [התכנית הכלכלית של אביגדור ליברמן](https://beytenu.org.il/התכנית-הכלכלית-של-אביגדור-ליברמן/)
(published 2026-03-04, last modified 2026-06-23 — **it predates the 2026-08-02 re-verification and had
never been read**) and [מצע ישראל ביתנו בנושא החינוך – יחד עם מועצת התלמידים](https://beytenu.org.il/מצע-ישראל-ביתנו-בנושא-החינוך-יחד-עם-מו/)
(2026-08-26). Reading them sent me back to `/party-platform`, and **that is where the actual findings
were.**

**The 2026-08-02 re-verification checked the fifteen claims this entry already made and found one
wrong. It could not find what the entry never said** — and four tags had been sitting in the platform
the whole time, three of them in the party's own seven קווי יסוד. A verification pass and an audit
pass are different instruments; this row had had the first twice and the second never.

- **`core-curriculum` (6 → 7 holders)** — *"חובת לימודי ליבה בכל מוסד חינוך **כתנאי לקבלת תמיכה
  ממשלתית**, בכפוף לפיקוח חיצוני שיכלול מבחני רמה לפחות אחת בשנה, וביטול מעמדם המיוחד של מוסדות
  הפטור"*, restated in the education chapter as *"מוסדות חינוך שלא ילמדו את תוכנית הליבה במלואה לא
  יהיו זכאים לתקצוב ממשלתי"*, and named as one of seven קווי יסוד (*"לימודי ליבה חובה"*). This is the
  **funding condition** — the criterion the −2 band is written around and the one that moved כחול לבן
  and בית ציוני — on the row that anchors −3. It should have been the least surprising tag on the page.
- **`sanctions-on-non-servers` (6 → 7)** — *"השתמטות משירות תוביל לשלילת זכויות, ובהן קצבאות, הנחות
  בדיור ובארנונה וזכאות לעבודה בשירות המדינה"*. Revision 41's standard for this tag is that all holders
  "name a concrete penalty — a fine, a withdrawn entitlement, a criminal charge". This names **four**
  withdrawn entitlements in one clause, which makes it among the strongest instances, not a marginal one.
- **`arab-civil-service` (4 → 5)** — *"חקיקת חוק גיוס חובה לכל אזרח ישראלי בגיל 18, ללא הבדל דת או
  מוצא, בשני מסלולי שירות: צבאי או אזרחי"*, with *"יהודים, מוסלמים, נוצרים, דרוזים וצ'רקסים"* named and
  a dedicated framework for haredim and minorities. That is the tag exactly as revision 36 defined it —
  a **national-service track for Arab citizens**, not civil-service employment.
- **`cost-of-living` (tag 3 → 4, family 5 → 6)** — a קו יסוד (*"מאבק ביוקר המחיה"*) with its own chapter
  and named mechanisms: parallel import and abolishing exclusive-importer status, food-monopoly
  abolition on the Blenikov committee, dismantling the production councils (מועצת הלול, מועצת הצמחים),
  international chains, deregulation. The new economic programme adds the household side — 90% mortgages
  over 40 years and daycare credits worth ~₪2,500/month. Same shape as הדמוקרטים's and אל הדגל's.

**`family_evidence` corrected from `record` to `platform`, and this was a plain data error.** Every
number in this entry is sourced to `beytenu.org.il/party-platform`, the row is described here as "the
only party row on the page verified against a live primary source", and the field still said the
families rested on a record. Contrast עוצמה יהודית, where `record` is *correct* because that row's
families rest on ministerial-action posts — the two rows now demonstrate both values for the right
reasons.

**economic +2 CHALLENGED and HELD, with a move condition — this is the closest call on the page.**
The economic programme is state expansion almost throughout: 90% loan-to-value mortgages over 40 years,
daycare credits, an **expanded negative income tax**, ~30 national infrastructure projects on a
legislated "green track", state guarantees to route institutional money into startups, a defence budget
at **8% of GDP**, and campaigns to keep EU Horizon and the US MOU money flowing. Read alone it is the
+1 band verbatim — "liberalizing *fused with* real state expansion — trust-busting, subsidies, targeted
spending" — and it would move the page's **only** +2 row into the crowd, leaving +2 empty above an
already-empty +3.

It is held at +2 on ביחד's precedent, which is the page's rule for a corpus that pulls both ways: net
it out rather than let the newest document decide. The withdrawal half is unchanged, current, and
stronger than anything else on the page — *"המשך מדיניות ההפרטות, לרבות הפרטת נמל אשדוד ושדה התעופה
בחיפה"*, *"צמצום משרדי הממשלה והמגזר הציבורי"*, and *"ביטול קצבאות הילדים החל מהילד החמישי"*. Two
further reasons: the expansion is **service-conditioned and sectoral** rather than universal (the
mortgage and daycare benefits require full military service plus active reserve duty, argued explicitly
*"במקום להמשיך להוציא סכומים עצומים על מגזרים שלא לוקחים חלק בשוק העבודה"*), which is targeting, not a
welfare floor; and the +2 band's text names *this row's own planks* as its definition, so moving the row
would leave the band defined by an example no row holds — a sign the definition would need rewriting,
which is a bigger claim than this document supports. **Move condition:** the platform dropping the
privatization or public-sector-reduction planks, or a further programme adding **universal** expansion.
Recorded rather than settled quietly, because a future pass will meet this again.

**religiosity −3 unmoved and better evidenced**, now including the core-curriculum funding condition and
the abolition of מוסדות פטור status alongside the four planks already cited, under the platform's own
heading *"הפרדה בין דת למדינה"* and its statement *"אנו מאמינים בהפרדה בין דת למדינה"*. security +2
unmoved: neither document contains conflict content.

**Two tags refused.**

- **`service-conditioned-citizenship` — refused, and this is the FOURTH instance of the same vocabulary
  problem.** The platform conditions *"זכאות לעבודה בשירות המדינה"* on service, and the programme
  conditions housing and daycare benefits on it, which is closer than עמך ישראל's reward ladder was
  (revision 41) — but the tag's founding case is Hendel's **franchise** clause, and employment
  eligibility and a subsidy are not claims about citizenship. Five holders now sit under a label only
  one of them meets, logged from a fourth row.
- **`state-haredi-education` — refused.** Abolishing the special status of מוסדות פטור and conditioning
  funding on core studies is a funding condition, not a stream conversion into ממ"ח. This is the same
  line ש"ס's `opposes-core-curriculum` sits on from the other side (revision 43).

**The education paper itself is the smallest half of this pass**, and worth recording as such: written
with מועצת התלמידים, it is a youth-and-schools programme — class sizes, non-formal-education funding in
statute, mental-health provision, transport, driving-licence costs, statutory standing for student
councils — with **no religion-and-state content at all** and no funding condition of its own. On this
page the education paper is normally where the religiosity number really lives (כחול לבן, אל הדגל); here
it is not, because the platform had already said it plainly. Its one arguable axis line —
*"שוויון תקציבי בין כלל זרמי החינוך"* — is budget equality **between** streams and is not read as
softening −3, since the same platform conditions every stream's funding on core studies.

### הציונות הדתית — Religious Zionist Party · `bibi` · 0 / 3 / 3 · religious_zionist

**Merged with זהות into one ballot line, 2026-09-01.** Smotrich and משה פייגלין signed an agreement
that evening to run as a **technical bloc** (בלוק טכני) — one slate on the ballot, which may split
back into two factions once seated. The agreement's own framing is that each party keeps its
identity, its path and its principles. The motive on both sides is the threshold: RZP has polled at
or below it since עופר וינטר entered the race, and זהות (~1 seat) has not crossed it since 2019.
Reported slate — 1 סמוטריץ', 2 **משה פייגלין**, 3 אורית סטרוק, 4 שריון סמוטריץ' (צביקה מור),
5 שמחה רוטמן, 6 צבי סוכות, 7 אוהד טל, 8 יצחק זאגה (זהות), 9 עומר רחמים — thirteen slots in all, of
which זהות holds **2, 8, 10 and 11**. וינטר was invited by both סמוטריץ' and בן גביר and **declined
the same evening** (*"חייב לקום משהו חדש"*).

**One row, not two.** A voter sees one line, exactly as with יהדות התורה's permanent technical bloc
— which is why this row now also carries `two-faction-list`, the tag that until now had a single
holder. זהות's row is removed under `seed.sql`'s guarded delete (votes checked, `party_lineage`
cleared first); it had no `previous_parties` row to freeze, having been extra-parliamentary in 2022,
so no lineage link changes. **No brand was announced** — every outlet calls it descriptively
(*"הרשימה המאוחדת"*), RZP is the registered list, and the row keeps its name and logo rather than
carrying an invented one.

**The הרשימה המשותפת union rule does not apply to `economic` here, and the reason is the rule's own
precondition.** That rule — axes are the union of the components' published positions — was adopted
on the express condition that the components "differ only in degree, with direction not in dispute".
On economics the direction *is* in dispute: this row is **0**, with `claims-economically-liberal`
carrying the gap between its rhetoric and a finance ministry that runs sectoral budgeting, while
זהות is **+3**, the axis's only doctrinal libertarian. Taking the union would put the list at +3 —
asserting it wants to shrink the state as a matter of principle, which its own #1 spends his working
days contradicting.

- **`economic` 0, unchanged.** RZP holds nine of the thirteen slots including #1 and the finance
  portfolio; a voter choosing this line gets its budgets. The repo owner's call, 2026-09-01, taken
  over NULL (the ביחד precedent for components that genuinely disagree) and over +3 (the union rule
  read literally).
- **`security` +3, unchanged** — both components were already at the pole.
- **`religiosity` +3, unchanged.** Here the components *do* differ only in degree, so the union rule
  applies and takes the pole, which this row already held. See the faction entry below for why
  זהות's +2 is a different mechanism rather than a milder version of the same one.

**Tags: carry what the list adds, refuse what would contradict a number or a family on this same
row.** Of זהות's nineteen, two dedupe away (`sovereignty-annexation`, `anti-two-state`), **seven are
carried** — `gun-rights`, `temple-mount-centred`, `population-transfer`, `cannabis-legalization`,
`permanent-residency-not-citizenship`, `communitarian-devolution`, `jewish-law-parallel-jurisdiction`
— because the delegation a voter elects genuinely contains members who hold them and nothing on the
row says otherwise. **Ten are refused, and the refusals are the informative half:**

- `libertarian`, `flat-tax`, `small-government`, `privatization`, `deregulation`, `anti-monopoly` —
  all six contradict `economic 0` and the `sectoral-budgeting` family entry on this row. A row
  cannot be scored 0 and tagged libertarian.
- `ends-state-religious-funding` — the direct opposite of `sectoral-budgeting`, which stays.
- `professional-army` — contradicts `conscription-split`, which stays.
- `state-institutions-bound-to-halakha` — subsumed by `halakhic-state`, the stronger claim, already here.
- `extra-parliamentary` — no longer true of anybody on this list; #2 is a realistic slot.

Eight of those ten had זהות as their only holder anywhere in either table and leave the vocabulary
with it — every one above except `deregulation` (3 holders) and `anti-monopoly` (7). The row now
carries **22 tags**; its own `families` and `family_evidence` are untouched, and `family_evidence`
stays `record` because a technical bloc publishes no joint platform to read.

**And one FAMILY was retired, which the tag accounting did not predict.** `market-liberal` had
exactly two holders — ישראל ביתנו at economic +2 and זהות at +3 — so removing זהות left it naming a
single party, and `test_every_family_value_is_shared_by_at_least_two_parties` fails on that by
design: a family that groups one row groups nothing and merely duplicates the row. **It was retired
rather than back-filled.** The obvious back-fill candidates are אל הדגל and המפלגה הכלכלית, and both
are economic **+1** — the band table's whole point is that +1 liberalizes *while* expanding the
state, whereas this family's test is "actually withdraws" it, so admitting either would lower a bar
this page has refused to lower before. ישראל ביתנו keeps `universal-conscription` and
`constitutional-reform`; the string is gone from `i18n.js` in all three languages, from
`analytics.js`'s map and from `docs/i18n/family-strings.csv`. **The check that missed this was
mine**: "does `market-liberal` still have a holder?" is the wrong question, and it returned a
reassuring yes. The invariant is two.

**Verified on an already-seeded database, both branches, 2026-09-01.** A fresh install only proves
the literal is spelled right. Two databases were seeded with the *previous* `seed.sql` and the new
one applied on top:

- **no ballot naming זהות** — 19 → 18 rows, `zehut` gone, this row 14 → 22 tags, axes still 0/3/3,
  `two-faction-list` and `cannabis-legalization` present, `libertarian` absent, ישראל ביתנו down to
  two families.
- **one ballot naming זהות** — the row **survives** (19 rows), its ballot intact, and this row still
  updates to 22 tags. That is the vote guard failing safe by design, and it is the operational
  consequence to watch: **if production holds any vote for זהות, both it and the merged list stay on
  the ballot** until an admin reassigns that vote. **Checked against production on 2026-09-02**, on
  the rebuild that shipped this change: the restored snapshot carried no vote for זהות, so the row
  was removed cleanly — `/api/options` returns 18 upcoming rows, no זהות, and this row at 22 tags.

The first run of the second case proved nothing and looked like it had: the ballot insert violated
`votes_upcoming_vote_status_check` (the allowed values are `considering`/`undecided`, not `voted`),
so the guard was exercised against **zero** ballots and reported the same clean removal as the first
database. The tell was `ballots preserved: 0` in *both*. Assert the ballot exists **before**
migrating — this page's own rule about feeding a check input you know should match.

**Flagged expected-unstable.** Smotrich called this *"החיבור הראשון ולא האחרון"* and list submission
closes the week of 2026-09-07; a further merger would renumber the slate and could change what this
row means again.

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

**2026-08-14 — *מילואימניקים הביתה* read, the party's first 2026-cycle policy document. Nothing
moved: no axis, no tag, no family. One claim above is superseded.**

A three-axis plan targeting **≤30 reserve days a year by 2027**: (1) reserve-force efficiency —
return ~50,000 soldiers not currently assigned to active reserve units, raise qualification, new
reserve frameworks, spread security tasks across more units; (2) a national Haredi enlistment
programme in three stages — funded pre-military academies, Haredi hesder yeshivas, youth movements
and expanded ממ"ח education; then expanded dedicated tracks (a larger חטיבת חשמונאים, more Haredi
combat frameworks, units sited near Haredi cities, "לומדים ומשרתים" yeshivas); then a support
envelope (בתי חייל, grants, נצח יהודה); (3) **חוק יסוד המשרתים**, giving servers priority in
discounted housing, daycare, academic admission, student dorms, public housing, civil-service hiring
and government tenders, extended to spouses. Attached as a coalition demand:
*"התוכנית הזו תהיה תנאי מרכזי לכניסה לממשלה עתידית"*.

**The 2026-08-11 entry's stated reason for `basis` is now false, and the value is still right.** It
reads "The party has published nothing for 2026" — that sentence stands as a dated record of what was
true then, and is not edited. The current reason `basis` stays **`record`** is different: this is one
single-issue paper, not a platform. All three axes are still graded from the record, and nothing here
speaks to the economy, the judiciary, or religion-and-state. A row becomes `platform` on a מצע, the
way בית ציוני's did in revision 20 — not on a campaign deck about one dimension.

- **religiosity +3 is confirmed, and reading this as a move away from it inverts the axis.** The axis
  is Jewish religion-and-state; the conscription fight lives in the conscription tags (see the
  `anti-conscription-exemption`/`universal-conscription` note under the axis definition). What the
  plan actually does on this axis is *expand* state religious provision — funded Haredi hesder
  yeshivas, "לומדים ומשרתים" frameworks, ממ"ח expansion, נצח יהודה.
- **economic stays 0.** Allocating housing, land, tenders, academia and daycare by service status is
  a doctrine of civic desert, not of markets versus state. Same call already made for בית ציוני,
  whose economic number was decided on other grounds entirely.
- **security +3 is at the ceiling.** Fourth consecutive reading of this row where that is the reason
  nothing moves.

**`service-conditioned-citizenship` was considered and rejected, and the distinction is the tag's
whole content.** The tag means citizenship-level rights conditioned on service — Hendel's *"will not
be able to vote or be elected"* is the paradigm case. This plan conditions **queue position for
state-allocated goods**, which is a preference scheme; Israel already runs several. Stretching the
tag to cover that turns it into "has veterans' benefits", a near-universal label — the failure that
retired `periphery-development` in revision 19. Revision 20 had already recorded the tag thinning,
since בית ציוני's own newer platform drops the franchise clause it rests on; a fourth holder on the
weakest evidence yet compounds that rather than testing it.

Three more rejected, all on existing precedent:

- **`sanctions-on-non-servers`.** The document is positively framed throughout — *"עדיפות ב…"*, six
  times. The negative half appears once, in Q&A prose (*"מי שמשרת פחות או לא משרת – מקבל הרבה
  פחות"*), with no fine, no named withheld entitlement, nothing like אל הדגל's or בית ציוני's
  enumerated סנקציות lists. כחול לבן earned this tag for individual penalties; הדמוקרטים was refused
  it for targeting institutions. Preference-for-servers and sanctions-on-non-servers are two claims,
  and only the first is written down here.
- **`anti-conscription-exemption`.** The plan is silent on תורתו אומנותו in both directions — it is
  an enlistment-*expansion* programme, not an exemption-abolition one. `scholar-exemption-retained`
  fails on the same silence.
- **`universal-conscription`.** It builds separate Haredi tracks, which is the opposite of the tag.

No new tag was invented for "Haredi enlistment programme": the `conscription-by-incentive` *family*
already carries that dimension, and a tag duplicating a family is the `not-economy-focused` defect
this page cleaned up in revision 17.

**Open question — the `conscription-split` family, left in place under a structural constraint.** The
family was assigned because Solomon, Woldiger and Sofer rebelled against the draft bill *as too weak*,
so "asserting a majority position would state something a third of the faction rejects". Those rebels
would not reject this plan; on the merits the leader has moved to their side and the split looks
resolved by convergence, with `conscription-by-incentive` (enlistment via tracks and incentives, no
individual sanctions) describing the document almost exactly. It stays anyway, because decision 7 of
`docs/design/2026-07-30-party-families-club-traits-design.md` requires every family value to sit on
≥2 parties: moving this row leaves `conscription-split` holding only יהדות התורה and forces a second
reclassification. That is a cascade off one campaign document on a `[R]`-graded row. **Revisit on a
faction vote or a fuller 2026 platform** — not on further campaign material.

**The rhetoric/record gap is recorded here and deliberately not tagged.** The obvious reading —
pressed publicly by MK Vladimir Beliak (the 2026 budget assumed 40 reserve days and orders of 80–110
followed within two months; coalition transfers to exemption-holding sectors) and by Chaim Levinson
(three years of "תהליכים" replaced by כפייה only once the party is behind on the issue) — is that the
plan contradicts the record of the government the party sits in. A `claims-*` tag is this page's idiom
for exactly that gap, and it is still the wrong instrument: the charge is against a **finance
minister's** budget conduct, whereas the party's own Knesset conduct on the draft bill was split with
its rebels on the hawkish side. The two do not resolve into one party-level position, which is why
this is prose. Same treatment as the הדמוקרטים "אוכלוסיות נוספות" ambiguity above.

Sources: the *מילואימניקים הביתה* deck (party-circulated, including its Q&A section) and
[maariv.co.il article-1355768](https://www.maariv.co.il/news/politics/article-1355768), both
2026-08-13/14. **Provenance caveat:** as of reading, the plan is **not** hosted on
`zionutdatit.org.il` — its נבחרת, מצע and news sections carry no מילואים page. Treated as first-party
text on the strength of the deck's own branding and the direct quotation of Smotrich in Maariv, but
this row's next revision should confirm it against a party-hosted copy.

**2026-08-26 — the party's own site enumerated for the first time, and it holds two policy pages
nobody here had read. Three conflict tags added (11 → 14). No axis moved.**

Every previous pass on this row followed links it was handed: thirteen platform PDFs (revision 17),
thirteen `/hityashvut/` pages (2026-07-27), a circulated מילואים deck (2026-08-14). Nobody had asked
the site what it contains. `page-sitemap.xml` answers in one request, and it lists **five pages
published after the last pass looked** — `/victory/` (2025-09-04), `/we_hear_you/` (2026-02-22),
`/we_hear_you-rehovot/`, `/work/` and `/center/` (both 2026-08-17), plus `/judaization/`, which
appeared **the same day this entry was written**. Three of the six are volunteer and polling-station
sign-up forms with no policy content; that is recorded here so the next reader does not re-fetch
them. Two are policy documents, and one of them is the party's entire Gaza programme.

**הכרעה וניצחון (`/victory/`, אלול תשפ"ה / September 2025) — Smotrich's own Gaza plan, and the
source of all three new tags.** It had been on the party's website for eleven months, through two
passes over this row.

- **`territorial-control-gaza`** — *"סיפוח פרימטר ביטחוני מורחב"* immediately on the ultimatum
  expiring, then *"בכל שבוע שהמלחמה תימשך ללא כניעת חמאס והשבת כל החטופים יסופח מהרצועה שטח נוסף"*,
  with *"שליטה מבצעית מלאה של צה״ל בכל הרצועה"* among the seven surrender terms and
  *"רוב שטחי רצועת עזה בריבונות ישראלית"* as the stated end state. **The page's timeline graphic is
  where this stops being a slogan**: four dated annexations — day 14, 21, 28, 35 — then
  *"יום 70-90: העברת האוכלוסייה לשטח שמדרום למורג ולקיחת אחריות אזרחית"*. Third holder, after
  עוצמה יהודית and בית ציוני, and the only one with a schedule.
- **`hardline-on-gaza`** — *"מצור… סגירה מוחלטת של כלל האספקה"* from the moment the population is
  moved, humanitarian supply — *"תשתיות חשמל, מים, מזון ורפואה"* — confined to the humanitarian zone
  *"בלבד"*, and *"מכת אש ותמרון עצים"* in Gaza City and the central camps. Fourth holder.
- **`voluntary-palestinian-emigration-incentives`** — *"פתיחת שערי עזה להגירה מרצון"*, itemised as
  *"ריכוז מאמץ מול מדינות קולטות"*, logistics for departure, and *"מענקי תמרוץ ליוצאים ולמדינות
  הקולטות"*. Fourth holder, and the first whose evidence is a sitting finance minister's own costed
  plan rather than a bill, a ministerial record or a platform plank.

`opposes-hostage-deals` is **reconfirmed and not re-derived**: the row earned it from צביקה מור's
primary placement, and this document supplies the party-level position that placement was evidence
*for* — *"ממשיכים עד הניצחון, בלי עצירות ובלי עסקאות חלקיות"*, with *"שחרור כל החטופים בפעימה
אחת"*. That is the corroboration-is-not-coverage test in `services/backend/CLAUDE.md` passing rather
than failing: the tag was already right, and the evidence behind it is now first-party.

**Three rejected, all on this page's existing precedent:**

- **`population-transfer`.** The emigration half is opt-in — *"מרצון"*, incentivised, coordinated
  with receiving states — which is the exact line drawn for אל הדגל and re-drawn for עוצמה יהודית
  yesterday: compulsion in the instrument, not in the rhetoric around it. The plan's *compulsory*
  movement (day 70–90, south of ציר מורג) is displacement **within** the territory paired with
  Israel *"לקיחת אחריות אזרחית"* for the displaced, which is an occupation-administration claim, not
  removal from the territory. זהות keeps the tag.
- **`security-hawk`** — the Otzma rejection of 2026-08-26 applies unchanged: all five holders are
  centre or centre-right and no far-right row carries it by design.
- **`no-palestinian-state`** — the document simply does not say it. `anti-two-state`, already on this
  row from `/hityashvut/`, covers what is written.

**No axis moves, for the fifth consecutive reading of this row, and the reason is the same one.**
`security` +3 and `religiosity` +3 are at their poles. `economic` stays **0**: the only money here is
emigration grants and receiving-state payments, which is territorial policy denominated in shekels —
the category error this entry warned against for ₪9B of settlement budgets and warns against again
below for חבילת חלוץ. `basis` stays **`record`**; a single-issue campaign document is not a מצע, the
same call made for the מילואים deck.

**מייהדים את הנגב והגליל (`/judaization/`, published 2026-08-26) — read, and deliberately not
tagged.** *"מה שעשינו ביו״ש נעשה בנגב ובגליל"* is the banner, and the first of three stated goals is
*"שינוי דמוגרפי — הגדלת האוכלוסייה היהודית בנגב ובגליל"*, with *"קביעת יעדים מספריים ומדדי ביצוע"*, a
נגב–גליל cabinet to enforce it, and a *"חבילת חלוץ"* of land discounts, purchase grants, tax relief,
daycare subsidy and a dedicated track for reservists and career soldiers.

**This is the second instance of the thing the 2026-07-27 entry above left untagged, and it is much
stronger than the first.** That entry read *"מקסימום שטח תחת ריבונות ישראלית עם מינימום אוכלוסייה
ערבית"* as sovereignty-line drawing around existing population centres — correctly — and recorded
that no tag covers demography-driven policy, adding: *"if it is ever worth a tag it should be added
across rows… not to this row alone."* This page clears that bar in a way the sovereignty page did
not: it is inside the Green Line, it is a named national programme with numerical demographic
targets and an execution cabinet, and it moves people rather than borders. **It is still not tagged
here**, because the instruction that entry left was explicit and it was about scope: ישראל ביתנו's
population-swap plan and אייזנקוט's anti-annexation case are also demographic arguments pointing
elsewhere, and a tag invented on one row is how a vocabulary drifts. **Queued as a cross-row sweep**,
on the same footing as the press-freedom tag queued in revision 24 — not as a follow-up on this row.

Two smaller findings from the same page:

- **`periphery-development` was retired in revision 19 for being near-universal, and the party now
  says so itself**: *"לא עוד ״חיזוק הפריפריה״. משימה ציונית לאומית"*. A retirement decision confirmed
  by the party whose document would have carried the tag is worth more than the count that motivated
  it.
- **`claims-economically-liberal` gets its third and best evidence base.** Deep land and housing
  discounts, development-cost subsidy, graduated tax benefits, company grants, business incentives
  and relocating government units — a finance minister's own party proposing directed subsidy at
  regional scale. The tag records the gap; the number stays 0 because `basis` is `record`.

**The 2026-08-14 provenance caveat is checked and still open.** That entry asked the next revision to
confirm *מילואימניקים הביתה* against a party-hosted copy. The full page sitemap carries **no מילואים
page**, so it remains party-circulated rather than party-published. Recorded as verified-absent
rather than left as a standing question.

Sources: `zionutdatit.org.il/victory/` and `/judaization/`, both read 2026-08-26, plus
`sitemap_index.xml` → `page-sitemap.xml` for the enumeration. Both pages are HTML and extract
cleanly; the `/victory/` **timeline is an image** (`באנר-ראשי-1.png`, 2471×1225) and carries the
four dated annexations and the day 70–90 relocation, none of which appear in the page text — the
image-only-content rule in `services/backend/CLAUDE.md` applying to a web page rather than a PDF.

**2026-08-30 (revision 33) — `/judaization/` re-read, and it is not the page revision 31 read.
No axis moves; no tag added; a second dimension joins the cross-row sweep queue.**

The page's `lastmod` in `page-sitemap.xml` is now **2026-08-27T12:00:04**, one day after revision 31
read it, and **none of the four strings that entry quotes appears anywhere in the current HTML or in
any of its four images** — not *"שינוי דמוגרפי — הגדלת האוכלוסייה היהודית בנגב ובגליל"*, not
*"קביעת יעדים מספריים ומדדי ביצוע"*, not *"חבילת חלוץ"*, not
*"לא עוד ״חיזוק הפריפריה״. משימה ציונית לאומית"*. The **Internet Archive holds no snapshot of this
URL at all** (a CDX query returns an empty result), so the earlier text is unrecoverable and those
quotations can no longer be checked against a source. Revision 31 stands as a dated record and is not
edited. Honesty requires naming the alternative: nothing now available excludes the possibility that
the entry was written from a summarizer's rendering rather than the page, which is the failure
`services/backend/CLAUDE.md` warns about — and being unable to tell the two apart, a week later, is
itself the argument for the rule below.

**A campaign page is a moving target, and revision 31's own mechanism already dates it.** That entry
established `sitemap_index.xml` → `page-sitemap.xml` as the way to learn *what exists*; `lastmod`
extends it at no extra cost to *what changed under a page already read*. One request re-checks every
page on this site against the date it was last read. This is the cheapest half of the enumeration
rule and revision 31 did not state it, because at the time nothing had been read twice.

**What the current page says.** Three pillars — **אדמה / אדם / ביטחון** — under the banner
**״כן. מייהדים.״** and *"מעתיקים את מהפכת ההתיישבות ביו״ש לנגב והגליל"*. Both of those are
**image-only** (`33-1024x516.png`, 2048×1031 at full size) and appear nowhere in the page text: the
same trap `/victory/`'s timeline set, on the same row, on the second consecutive page. The body text
carries the softer *"מייהדים את הנגב והגליל"*; the party's flat affirmation of the word is in the
picture.

- **אדמה** — 20 new settlements in the Galilee and 20 in the Negev, *"הקמת עשרות חוות ועלייה מיידית
  לשטח במוקדים אסטרטגיים"*, *"יצירת רצפים התיישבותיים"*, *"ביטול תוכניות היוצרות רצפים טריטוריאליים
  ערבים"*, and a stated principle: *"קרקע שלא אנחנו מחזיקים בה – יחזיקו בה הערבים"*.
- **אדם** — *"להביא עוד מיליון תושבים יהודים לנגב ולגליל"*, with targeted incentives for
  מילואימניקים ומשפחות משרתות, עולים חדשים, young families, doctors and teachers, and entrepreneurs.
- **ביטחון** — **this pillar has no counterpart at all in revision 31's account of the page.**
  *"הוראת שעה לאומית למאבק בפשיעה המאורגנת"* whose stated purpose is
  *"לפרק את האוטונומיה הערבית החמושה"*, itemised as: *"הגדרת החזקת אמל״ח בלתי חוקי כטרור"*,
  *"הכנסת שב״כ"*, *"מעצרים וצווים מנהליים"*, *"חקיקת חזקות ראייתיות ועונשי מינימום"*, economic
  strangulation of the organisations, a state that *"מפסיקה לשלם פרוטקשיין"* with a safety net for
  refusers, and *"אכיפת עברות נלוות ״מודל ג׳וליאני״"*.

**The security paragraph appears twice on the page with different adjectives, and the pair is worth
recording rather than resolving.** The first reads *"עם כלים חריגים ודרקוניים"*; the block
immediately below restates the identical sentence as *"עם כלים חריגים, ממוקדים ומפוקחים משפטית"*. A
softened revision left standing next to the original — a reader arriving at either one alone would
characterise the instrument differently, and both are the party's own text.

**No axis moves, for the sixth consecutive reading of this row, and the reason is unchanged.**
`security` +3 and `religiosity` +3 are at their poles. `economic` stays **0** and `basis` stays
**`record`**: the חבילת חלוץ-shaped incentive package — land discounts, purchase grants, tax relief,
subsidised development, relocation grants for professionals — is regional policy denominated in
shekels, the category error this entry has now warned against four times (₪9B of settlement budgets,
Gaza emigration grants, the previous version of this page, and this one). What it does do is give
`claims-economically-liberal` a fourth evidence base, and the best-matched one yet: a finance
minister's own party proposing directed subsidy at regional scale while the row's rhetoric is
liberal.

**Two dimensions, neither tagged, both queued — and one of them is new.**

- **Demography inside the Green Line: still queued, and the queue instruction is unchanged.**
  Revision 31 refused this tag on scope, not on evidence, directing that it be added across rows or
  not at all (ישראל ביתנו's population swap and אייזנקוט's anti-annexation case are demographic
  arguments pointing elsewhere). The current version raises the evidence again — the party now
  affirms the word itself in its banner, and the land pillar states the ethnic land-competition
  premise outright — and changes nothing about the scope argument. **The instruction was recorded
  only in that entry and never in Open questions**, which is precisely the mechanism this page
  identified for the `religiosity −3` band going unactioned for two revisions. It is now filed
  there too.
- **Domestic emergency policing directed at Arab *citizens* is new, and no existing tag covers it.**
  Not `security-hawk` — five holders, all centre or centre-right, and by the standing decision no
  far-right row carries it. Not `death-penalty-for-terrorists` — a sentence, not a police power. Not
  `preemptive-security-doctrine` — the conflict, not internal policing. Not `jewish-supremacist` — a
  claim about ideology, not about an instrument, and stretching it here would repeat the
  approximation revision 31 refused for the sovereignty page. Every tag on this row and on
  עוצמה יהודית's is about the territories, Gaza, the judiciary or religion; **the whole internal
  dimension is unlabelled on both**. That is also why a second holder is visible without a sweep:
  עוצמה יהודית holds the national-security ministry and its row carries `gun-rights`, `kahanist` and
  `jewish-supremacist` and nothing about administrative detention or deploying the שב״כ against
  citizens — the same shape of gap that made the workfare tag a genuine vocabulary hole rather than
  an audit artefact. **Refused here anyway, on revision 15's standing reasoning**, and filed as the
  **sixth** tag queued behind the 18-row sweep — demography, filed properly for the first time
  above, is the fifth and was never in the count. The queue is the largest unresolved item on this
  page and this revision adds two to it; it should be run as one pass, not extended a seventh time.

Sources: `zionutdatit.org.il/judaization/` and its four images, fetched 2026-08-30 with a
browser-shaped request; `page-sitemap.xml` for `lastmod`; `web.archive.org` CDX for the absent
snapshot. `wp-json/wp/v2/pages/6992` is linked from the page and returns **403**, so the WordPress
`modified` field could not be read directly — the Yoast `lastmod` is the evidence for the edit date.

#### זהות — the Zehut faction · merged into this row 2026-09-01

Kept in full because seven of this row's tags are sourced here and nowhere else, and because a
technical bloc can split: if it does, this is the scoring that a restored `זהות` row starts from.
The three numbers below are what זהות carried **while it had its own row** — the merged row is
0 / 3 / 3, and the block above says which of these transferred and which were refused.

Source: the party's own full platform, *מחזירים את המדינה לעם — מצע מפלגת זהות תשפ"ו – 2026*
(188pp, `zehut.org.il/docs/zehut-platform-full-he.pdf`, first edition May 2026, written under Moshe
Feiglin). Scored entirely from the primary text — no secondary sources were needed or used.

economic **+3** — the only +3 the axis has ever carried, and **not transferred** to the merged row. This is not
right-of-centre economics, it is a doctrinal libertarian programme: a **flat tax** at a single low
rate on all income types, "no brackets, no credit points, no reliefs for cronies", with a one-page
return; government ministries cut **31 → 11** and entrenched in a Basic Law so the count can no
longer be set by coalition bargaining; the presidency abolished outright; a standing commitment to
vote *against* any bill without demonstrated necessity and to repeal existing ones; broad
deregulation; corporate-tax cuts; privatisation of state transport companies; budgetary pensions
curtailed. Switzerland and Hong Kong are named as the models, alongside Argentina's eight-ministry
reduction, with Reagan and PragerU quoted approvingly. Yisrael Beiteinu's +2 `free-market` is a
different order of claim from this.

security **+3**, the same pole the merged row already held. Cancellation of the Oslo accords and sovereignty over Judea, Samaria **and Gaza**,
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

religiosity **+2**, and this was the interesting row in the table — it is where the axis and `sector`
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
Otzma hold +3 for wanting halakha to reach the citizen; Zehut explicitly does not. **That is why the
merged row stays at +3 rather than moving**: the two differ in degree on a shared direction, which is
exactly the condition the הרשימה המשותפת union rule was adopted for, and the union takes the pole.

This is exactly the direction-versus-motive split of Decision 5 in the religiosity design doc.
`state-institutions-bound-to-halakha`, `ends-state-religious-funding`,
`jewish-law-parallel-jurisdiction` and `communitarian-devolution` carry the shape of the position
that the single number +2 cannot — of those four the merged row keeps the last two, and refuses the
first as subsumed by `halakhic-state` and the second as the direct opposite of `sectoral-budgeting`. **`instrumentally-clerical` deliberately does not apply** — unlike
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

**זהות was first committed as `unaligned` and corrected the same day — the mistaken reasoning is
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
`professional-army`, not `universal-conscription`, was the accurate tag. It is **refused on the
merged row**: RZP's `conscription-split` says the opposite, and the bloc has agreed no joint position.

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
*(**"No platform" stopped being true on 2026-09-04**, when the party published a costed twelve-principle
flagship programme — see the התנתקות 710 section below. `family_evidence` stays `record` anyway, and the
reason that is not a contradiction is set out there.)*

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
- **Negev enforcement is recorded here and deliberately left untagged.** *(Figures superseded by
  revision 30 below — 10,000 structures since the start of 2025, and no longer only the Negev.)*
  ~5,700 illegal structures
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

**2026-08-26 — revision 30. Six tags added (11 → 17), all conflict tags, all first-party, and every
one of them was available on 2026-08-11.** No axis moved: `security` and `religiosity` are already at
the poles and `economic 0` survives a sixth reading with nothing economic in it.

**The finding is about method, and it is a new failure mode for this page.** Revision 18 read "30
posts published 2026-05-26 to 2026-08-04" — a **ten-week window** of a stream that has been running
since the party entered government. Every document below is from **December 2024 to November 2025**,
outside that window, and together they are the party's entire Gaza legislative programme. **A
date-bounded sample of a continuous stream is not a corpus**, and it is worse than an unread platform
because it *reads* as thorough: "30 posts" is a number, it sounds like coverage, and nothing in the
site says how many more there are. ביחד's case had an index that named every document; a news stream
has no index. **What closed the gap was the site's own search box** — three queries (`עזה`,
`מדינה פלסטינית`, `עסקת חטופים`) surfaced all of it in one pass. Search a stream by *subject*, and
do it for each axis you are scoring; do not sample it by date.

- **`no-palestinian-state`** — *"אנחנו לא נאפשר אף הסכם כניעה שיכלול אפילו הצהרה על מדינה
  פלסטינית"* (2024-05-22, from the Temple Mount, on European recognition), and the Oslo bill's
  explanatory notes: *"הקמת מדינה פלסטינית בלב ארץ ישראל תהווה סכנה קיומית"*. Sixth holder.
- **`anti-two-state`** — a bill led by Ben Gvir **with his whole faction** (2025-03-09) to annul the
  Oslo, Hebron and Wye agreements outright, *restore the territories transferred under them*, and
  repeal the implementing legislation; plus *"לבטל את חלוקת השטחים A.B.C שאינה רלוונטית בימינו"*.
  Eighth holder. **This row is the cleanest case the page has for why the two tags are separate**:
  one opposes the state, the other repeals the framework that would produce it. Every other row
  holding both was read as holding one position under two labels.
- **`hardline-on-gaza`** — *"עזה צריכה לספוג גיהנום"*, bombing the aid stores Hamas holds, a total
  cutoff of electricity and water, and explicitly *"הרעבה המונית של מחבלי חמאס ותומכיהם"* before
  returning to fighting (2025-03-03); a bill barring humanitarian transfers; and a bill with קרויזר
  (2025-02-11) widening the perimeter to at least 1 km and requiring a soldier to open **direct
  fire** on any Gaza resident inside it. Third holder, and by some distance the hardest version —
  ישראל ביתנו's is cutting water, electricity and fuel.
- **`territorial-control-gaza`** — *"והחלת ריבונות לצמיתות על שטחים נרחבים ברצועה"*, in the same
  faction statement, as a threatened response to harm to a hostage; Heritage Minister עמיחי אליהו's
  *"עזה היהודית שלנו… עוד נשוב לשם"* with state land and homes on Gaza's coast (2024-12-20); and Ben
  Gvir on 2026-08-16: *"I see all of Gaza as ours. Settlements not just in Gush Katif but throughout
  Gaza."* **Second holder, and the tag reaches this page for the first time** — it has been on
  בית ציוני in `seed.sql` with **zero** occurrences in this document, so it had no recorded
  definition to check a candidate against. Recorded now: it marks holding Gaza territory as policy,
  which בית ציוני holds militarily and this row holds as sovereignty plus resettlement.
- **`voluntary-palestinian-emigration-incentives`** — the party's own bill (2025-02-07), tabled by
  Ben Gvir **with every member of his faction**: an economic aid basket set by the Finance Ministry
  for any Gaza resident who chooses to leave, no eligibility for anyone convicted of or held for
  terror offences, and double repayment plus interest if a recipient seeks to return. פוגל frames it
  as extending to ג'נין. Third holder, after הליכוד and אל הדגל — and **the first whose evidence is
  drafted legislation** rather than a minister's plan or a platform plank.
- **`opposes-hostage-deals`** — *"אם 'העסקה' תעבור, נצא מהממשלה"* (2025-01-17), naming the deal
  *"הרת אסון"* and *"תבוסתני"*, listing every minister and committee chair giving up a post, and
  **the party then did resign**. Third holder, and **the strongest evidence of the three**: הציונות
  הדתית and נעם hold it on the placement and biography of a candidate at #2/#3, this row holds it on
  an executed resignation from government.

**`jewish-supremacist` was carried on general knowledge until now and is now first-party.** The
perimeter bill's explanatory notes call Gazans approaching the fence *"אספסוף עזתי צמא דם"*, and on
the podcast: *"there are people there who are not worthy of life. They shouldn't live. They're not
even people."* Nothing on this row was previously cited for the tag at all.

**economic 0 and `not-economy-focused` confirmed a second time, on a wider and older sample.** Six
more documents, no tax, market, welfare or cost-of-living position. The nearest thing to an economic
instrument is the emigration bill's *"סל סיוע כלכלי"*, which is a security instrument denominated in
shekels — the same distinction that discharged נעם's economic revisit for a teacher's salary floor
(revision 18). Police pay rises in the Segal letter are ministerial administration, not doctrine.

**The `conscription-by-incentive` family becomes first-party.** It had been inferred; Ben Gvir's own
account gives the mechanism — haredi recruitment **to the police** up "hundreds of percent", haredi
units opened in מג"ב, **1,400** haredim enlisted. That is the incentive model in the form this row
actually practises it: an alternative service track opened, with neither sanction nor exemption.

**Two numbers in this entry are now stale and are corrected here rather than left.** `gun-rights`:
**300,000** weapons distributed on the chairman's own count, up from the 280,000 licences recorded on
2026-08-11. Demolitions: **10,000** structures since the start of 2025 (~6,000 in the last year
alone), land returned that the party sizes as Tel Aviv and Givatayim combined — and the 10,000th was
in **ג'ואריש, רמלה**, so the "mainly in the Negev" framing above no longer holds either. The
land-enforcement tag is **declined a third time** on the same reasoning, but it is now the
best-evidenced untagged position on the page.

**Three tags considered and rejected.**

- **`population-transfer`** — this page already draws the line (*"opt-in is a different claim"*,
  under הליכוד) and the bill is opt-in by construction. **Say why it is close, though:** the same
  faction has a bill stripping citizenship or residency from anyone who chooses to live in Gaza, and
  the podcast pairs emigration with *"for the terrorists, no emigration, nothing, just to kill them
  one by one."* The line holds because the tag turns on compulsion in the *instrument*, not on the
  rhetoric around it. הציונות הדתית stays the sole holder — via the זהות faction since 2026-09-01.
- **`security-hawk`** — its five holders are all centre or centre-right rows, and none of the four
  far-right rows carries it. That is not an oversight: on a row with `sovereignty-annexation`,
  `anti-two-state` and `hardline-on-gaza`, a general-disposition tag adds nothing and would erase
  the distinction it exists to draw.
- **`populist`** — the Segal letter is the most personally political document this row has (a
  grievance against a religious-Zionist "elite" that treats him as *"חוזר בתשובה, מזרחי"*), and it
  is tempting. It is rhetoric about the author's standing, not a documented position, and this page
  does not tag style.

**`bibi` confirmed again, with the bargaining now running in both directions.** The recorded
precondition (dismissal of the Attorney General) is unchanged and live — Solberg, as Central
Elections Committee chair, rejected her petition to bar him from speaking at the standby-squads event
(2026-08-24). What is new is the other side: Ben Gvir reads the campaign against him as *"יריית
הפתיחה לקמפיין שנועד להכשיר ממשלת אחדות בלי בן גביר"*, with Eisenkot disqualifying him. The bloc is
unchanged; the row now has a stated risk of exclusion **from within its own bloc**, which no tag
carries.

**Also recorded: the party holds a second ministry.** עמיחי אליהו is Heritage Minister, and the entry
has never said so — the Altalena search operation (located 2026-08-24 at 503 m) is his output, not
the National Security Ministry's. A row scored entirely from one minister's record was missing the
other one.

**Two retrieval notes, both generalizable.**

- **`timesofisrael.com` returns 403 to a User-Agent alone and 200 with `Accept`, `Accept-Language`
  and `Referer` added.** The rule recorded in `services/backend/CLAUDE.md` said to retry a 403 with a
  browser-shaped request; a UA by itself is not browser-shaped enough.
- **A summarizer's rendering of a source is not the source.** WebFetch's summary of that liveblog
  entry gave the "30 to 40 every night" quote and dropped the sentence immediately after it — *"there
  are people there who are not worthy of life… they're not even people"* — which is the single most
  classification-relevant line in the piece. Fetch and read the text when a source is going to be
  cited for a tag.

Sources: 30 posts at `ozma-yeudit.co.il`, published 2026-05-26 to 2026-08-04, read 2026-08-11 — a
**ten-week window**, not the archive; see revision 30 above. A further 11 posts read 2026-08-26,
published **2024-05-22 to 2026-08-24**, reached through the site's own search rather than its feed,
plus the [Times of Israel liveblog entry](https://www.timesofisrael.com/liveblog_entry/ben-gvir-calls-for-killing-30-40-people-in-gaza-daily-in-comments-widely-shared-in-arab-media/)
of 2026-08-16 quoting the *"October 8"* podcast. Ordinary WordPress pages — no retrieval trap,
`.elementor-widget-theme-post-content` carries the body text, and `?s=<term>` searches the archive.

**2026-09-04 — ״התנתקות 710״, the row's first published programme. No axis moved, no tag added, no
tag removed, `seed.sql` unchanged.**

Ben Gvir launched what the party itself calls *"תוכנית הדגל של עוצמה יהודית לקראת הבחירות"* — a
government programme for **voluntary emigration of Gaza residents**, published on the party's own site
([post](https://www.ozma-yeudit.co.il/יו״ר-עוצמה-יהודית-השר-בן-גביר-מציג-את-תו/), 2026-09-04) as the
product of a standing staff team working since 7 October. Twelve principles; a dedicated **Ministry of
Voluntary Emigration** with a minister, a director-general, its own budget and an international
negotiating team; per-person case files, destination-state agreements conditioned on consent and
regularized legal status, security screening, a reception package of up to 24 months, and
**payment-on-performance** to receiving states. Targets: **250,000 in the first year, 1.11 million
within three, 1.86 million within seven**. Cost: **₪10bn** to stand the system up, within an Israeli
framework of **up to ₪50bn**, subject to international participation. Candidate destinations named:
Turkey, Ethiopia, Congo and Arab states. And a coalition demand, stated as such:
*"בממשלה הבאה, הקמת משרד הגירה, עם שר בראשו, תקציבים וסמכויות, תהיה בראש הדרישות הקואליציוניות שלנו"*.

- **`security` is already +3 and there is nowhere for it to go.** This is the row at its own pole,
  restated at unprecedented scale, which is worth saying explicitly: a document can be the most
  significant thing a party has ever published and still move nothing, because the axis was already
  right. Note also what the programme does **not** contain — no sovereignty claim, no annexation
  language, no resettlement of the Strip. `territorial-control-gaza` is held on other evidence and
  gains nothing here; this plan is about the population, not the land.
- **`voluntary-palestinian-emigration-incentives` — the evidence is upgraded, the tag is not.**
  Revision 30 recorded this row as "the first whose evidence is drafted legislation". It is now the
  first whose evidence is a **costed government programme presented as the party's flagship**, which is
  a step up again from a bill.
- **`population-transfer` REJECTED for the fourth time, and this is the hardest instance the line has
  faced.** Principle 1 is *"הגירה מרצון בלבד – יציאה של מי שבוחר בכך ללא כפייה"* and principle 2 forbids
  any exit without a consenting destination state, so the **instrument** contains no compulsion — and
  compulsion in the instrument is what this page has said the tag turns on, three times before.
  **What is new is scale, and scale is not the test**: 1.86 million is approximately the whole
  population of the Strip, so the programme's own success condition is the Strip substantially
  emptied. **The rhetoric points the same way and is likewise not the test** — Ben Gvir closes by
  endorsing רחבעם זאבי (גנדי), whose politics were transfer in as many words:
  *"כמה חבל שלא הקשיבו לגנדי... זה הזמן להודות: גנדי צדק!"*. That is the second time this row has paired
  the opt-in instrument with transfer-adjacent rhetoric (revision 30 recorded the first), which
  **strengthens** the instrument test rather than weakening it: the page would have tagged this row
  twice over by now if rhetoric counted. **Recorded honestly**: at this scale the opt-in/transfer
  distinction rests entirely on the programme's own description of itself, which is the weakest ground
  a line on this page stands on. **Trigger — tag it the moment either appears:** a coercive clause in
  the instrument (a penalty, a withdrawal of status or aid, a deadline) or a party statement that
  those who decline to leave will be made to.
- **economic `0` and `not-economy-focused` confirmed a THIRD time, on the largest number this row has
  ever published.** ₪10bn plus a ₪50bn framework dwarfs every figure in the previous two passes, and it
  is still a security instrument denominated in shekels — the same distinction that discharged the
  emigration bill's *"סל סיוע כלכלי"* (revision 30) and נעם's teacher-salary floor (revision 18). There
  is no tax, market, welfare or cost-of-living position in the document.
- **`family_evidence` stays `record`, and the temptation to flip it is the finding.** The row now has a
  platform-type document, so the preamble's "it publishes no platform" is amended above. But this field
  records what the row's **families** rest on — `judicial-restraint`, `not-economy-focused`,
  `conscription-by-incentive` — and התנתקות 710 evidences none of the three. Flipping it would assert
  that the family assignments had been re-based on a document that does not mention them.
- **No tag for the coalition demand.** *"בראש הדרישות הקואליציוניות שלנו"* is the second row this month
  to make a specific demand a precondition of joining a government (עמך ישראל's conscription law,
  revision 41). Nothing in the vocabulary covers it, and minting a tag for it now would produce a
  two-holder tag whose two instances are about entirely different policies. Recorded in prose on both
  rows instead.

**Four other posts published since revision 30's cutoff were read and change nothing.** Enumerated
through the site's **WordPress REST API** (`/wp-json/wp/v2/posts?after=…`), which returns the archive
by date in one request — a cleaner instrument than revision 30's site search, and the one to use next
time.

- **A Druze-sector campaign HQ** (2026-08-31), headed by גסוב חסון ("אבו דני"), on housing, planning
  and תיקון 116. **No tag**, on the precedent set for עמך ישראל eight days earlier: a campaign aimed at
  a minority records what a party *does*, not what it **is**, and this row is not a Druze-representation
  party. Ben Gvir's formulation — *"מי שנאמן למדינה ב-100% – מגיע לו 100% מהמדינה"* — is
  **loyalty-conditioned entitlement**, and it is refused `service-conditioned-citizenship` for exactly
  the reason revision 41 refused it to עמך ישראל: that tag's founding case is Hendel's **franchise**
  clause, and a benefits claim is not a claim about citizenship. **Third instance of the same
  vocabulary problem**, now logged from a third row.
- **Beit Shemesh declared weapons-eligible except named Neturei Karta streets** (2026-08-31) —
  `gun-rights` reinforced, with the figures moved on again: **126 localities in 2026**, 200+ in total,
  ~**300,000** personal licences. The exclusion is listed street by street, which is an unusually
  concrete instance of this row drawing a line **inside** the Jewish public by anti-Zionist
  affiliation. Recorded; no tag covers it and one row does not make a tag.
- **Damon Prison visit** (2026-08-30, *"נגמרו הקייטנות בבתי הכלא"*) and **a Palestinian-Authority-linked
  event blocked in the Old City** (2026-08-26). Both reinforce `jewish-supremacist` and the row's
  sovereignty-in-Jerusalem posture; neither adds anything the row does not already carry.

Sources for this pass: the party's own site, five posts dated 2026-08-26 to 2026-09-04, enumerated via
`/wp-json/wp/v2/posts` and read in full.

### המפלגה הכלכלית — The Economic Party · `unaligned` · 1 / +2 / −2 · secular

Led by **Prof. Yaron Zelikha**, former Accountant General. An unusual fusion: a large tax cut
(VAT 18→12, marginal income 50→40, corporate 50→40) and abolition of all tariffs and import quotas,
fused with aggressive trust-busting — declare the exclusive importers monopolies, dissolve the
production councils, stop approving mergers, a state-co-funded bank. **economic stays +1 rather than
+2 precisely because that second half is real state expansion**, not standard right-economics, and
+1 keeps the fusion visible.

**2026-08-17 — revision 23. The platform is 13 sub-pages, not one page, and reading them moved
`security` two bands.** [מצע המפלגה הכלכלית](https://www.hakalkalit.org/מצע-המפלגה-הכלכלית) is an
**index**: each section shows an intro and a *המשך לקרא* link to its own page. This entry had been
written from the index alone, so every section was known only by its first paragraph. All 13 read
2026-08-17, plus two off-platform pages
([רפורמה במערכת המשפט](https://www.hakalkalit.org/רפורמה-במערכת-המשפט),
[הון שלטון](https://www.hakalkalit.org/הון-שלטון)) that the index does not link.

**security 0 → +2, and the old score was a positive claim that the platform refutes.** The
[ביטחון](https://www.hakalkalit.org/ביטחון) page opens with three paragraphs on defence spending as
a share of GDP (7% → 5%, closed divisions, empty emergency stores) — which is *budget* policy and
not evidence for this axis at all — and then states a full conflict platform:

- *"המפלגה הכלכלית תתנגד לכל נסיגה או וויתור ולו הקטן ביותר משטחי מדינת ישראל"* — opposed to any
  withdrawal or concession, however small, from any territory Israel holds.
- *"המפלגה הכלכלית תתנגד להקמתה של מדינה פלסטינאית"*.
- *"תתמוך בחיזוק ההתיישבות היהודית ביהודה ושומרון, בנגב בגליל וברמת הגולן"*, on the reasoning that
  settlement contributes to security.
- No Gaza arrangement without dismantling incitement in the schools, and the same demanded of the PA
  in Area A; total abolition of work permits for Palestinians from Judea and Samaria.

That is the **+2** definition as written — no Palestinian state **plus** a territorial claim with
settlement expansion. **Not +3**: the words ריבונות and סיפוח appear nowhere; strengthening
settlement is not applying Israeli law, which is what separates +2 from +3 on this axis.

**This is the inverse of the trap recorded under ישר, and the pair is worth keeping together.**
There, a page called `homeland-security` was *internal* security and contained nothing on the
conflict — the URL invited the wrong axis. Here the page is named for the right axis, opens with
material for the wrong one, and buries the real position in its second half. **Neither the URL nor
the opening paragraph is a reliable index of what a document contains.**

**`single-issue-economy` REMOVED — the platform falsifies it.** The party publishes dedicated pages
on the conflict and the territories, women's equality and gender segregation, environment and animal
rights, health, welfare, pensions, education, transport, agriculture and informal education. That is
a broad platform by any standard. This is the same correction revision 17 made when it removed
`not-economy-focused` from הציונות הדתית: `seed.sql` was asserting something the party's own
material refutes. What survives, and belongs in prose rather than in a tag, is that **the framing is
economic throughout** — health is argued from OECD spending shares, welfare from poverty
measurement, even the security page opens on the defence budget. Arguing everything through
economics is not the same as having no other positions, and the tag could not tell them apart.

**Nine tags added (9 → 17, after the removal).** From the ביטחון page: `no-palestinian-state`,
`pro-settlement` and `security-hawk`. **`pro-settlement` is safe here in a way the doc has had to
warn about elsewhere** — revisions 15 and 21 flagged התיישבות as a homograph that usually means
Negev/Galilee rural settlement rather than the West Bank; this page says *ביהודה ושומרון* explicitly,
so it is the one case where it resolves the other way.

From the conscription section of that same page and the
[שילוב חרדים](https://www.hakalkalit.org/שילוב-חרדים) page: `universal-conscription` (and the family),
`sanctions-on-non-servers` (*"לא תיתן קצבאות... או הטבות... לעריקים"*, no state support for
institutions where deserters study, and *"לכל מי שלא יתגייס תהיה ענישה פרסונאלית"*),
`scholar-exemption-retained`, `state-haredi-education` (*"נקדם הקמת בתי ספר ממלכתיים-חרדים לבנים
ולבנות"*, with an explicit political-economy argument that haredi politicians block it to keep
control) and `workforce-integration`.

**`scholar-exemption-retained` is the third holder and the middle case of three.** This platform
keeps a genuine **פטור** — an exemption, not a deferral — but caps it at **up to 2,000 yeshiva
students**, tested by rabbis, alongside equivalent carve-outs for athletes and the exceptionally
skilled. Ordered by how much survives: כחול לבן keeps *תורתו אומנותו* open-ended with quotas in law;
this row keeps an exemption but caps it hard at a number; ישר abolishes the exemption and replaces it
with a 3% one-year *deferral* that still requires induction and basic training, which is why revision
21 declined the tag there. All three sit at different points, and the tag now marks the boundary
rather than a single position.

**`gender-equality` added — second holder, and the contrast with revision 21 is the point.** That
revision *declined* this tag for ישר because its content was violence-against-women inside a crime
paper. Here it is a dedicated page running well past violence: employment-equality legislation on
pay, promotion and retirement terms; statutory representation of women in senior public office;
gender education from primary school; an explicit campaign against **הדרת נשים והפרדה מגדרית**; and
solutions for **עגונות ומסורבות גט**. A dedicated equality programme is the standard הדמוקרטים set,
and this meets it. The get-refusal plank is also anti-clerical evidence, on revision 15's precedent.

**economic +1 confirmed and unmoved**, with both halves now much larger than this entry recorded.
Also liberalizing: privatizing kashrut, infrastructure PPPs, freezing budgetary-pension accrual,
scrapping tender exemptions. Also expanding: direct farm subsidies on the European model for growers
north of Hadera and south of Gedera, anti-dumping levies, an **agrarian land reform** that reclaims
agricultural land not actually being farmed and reallocates it, forced divestiture above a pension
market-share cap, health spending from 7.3% to 8% of GDP with three new hospitals and a new medical
faculty, transferring public-housing units to 60,000 sitting tenant families, and a ₪10B climate
fund. Neither half wins; +1 is the band for exactly that.

**religiosity −2 confirmed, on the funding criterion — the fourth row in four days.** Kashrut is
privatized outright (*"את הכשרות יש להפריט… לאפשר לכל רב שקיבל הסמכה לרבנות להעניק שירותי כשרות"*,
with the state left supervising and penalising negligence) which is a Rabbinate monopoly ended in as
many words. But state religious funding continues and expands — state-haredi schools promoted, and
*"תגמול ותמרוץ מוסדות חרדים המלמדים לימודי ליבה"*. **Note the instrument**: core studies here are
**incentivized**, not made a condition of funding, which is a weaker lever than ישר, ביחד, כחול לבן
and בית ציוני all use. Nothing on civil marriage. Same landing point as the other three, reached
from a different direction again.

**`judicial-overhaul` considered and REJECTED, and the position deserves recording because the
vocabulary cannot hold it.** The judicial-reform page is Zelikha's testimony to the Constitution
Committee, **dated 2023-01-31** and published by the party as its position. He supports an override
clause — but a symmetrical, escalating-majority one, where each branch can override the other at a
successively larger majority — supports changing judicial appointments on representativeness grounds
(courts drawn from one milieu, with Mizrahim, women, Arabs and haredim absent), and wants ministry
legal advisers reclassified openly as **political-trust** posts. And he **explicitly opposes the
overhaul's flagship bill**: *"אני מתנגד בכל תוקף להצעת החוק של ח"כ רוטמן"*, plus *"אין מקום למונופול
או רוב מוחלט של הממשלה על מינוי שופטים"*, conditioning any reform on broad consensus. Tagging that
`judicial-overhaul` would file him with הציונות הדתית, עוצמה יהודית and נעם, which misrepresents him;
leaving it untagged loses a real position. `constitutionalist` was also declined — he wants stable
rules of the game *and* an override, which that tag does not distinguish. **Two caveats for the next
pass:** the source is three years old, and the party's distinctive argument is that the courts'
failure is *economic* — that they read competition law down in favour of monopolies and banks
(*"ישראל איננה דמוקרטיה מלאה בכל הנוגע לחיינו הכלכליים"*), which is not what any current holder of
`judicial-overhaul` means.

**`agricultural-protectionism` REJECTED, on the ביחד precedent.** This row abolishes *all* tariffs
and quotas and substitutes direct subsidy — the identical structure to ביחד's *"נבטל מכסים ובמקומם
נתמוך ישירות בחקלאים"*, which was not tagged. ישר keeps the tag because it adds what neither of these
has: legislated *ענף אסטרטגי חיוני* status, national production targets and state management of water
and reservoirs. Direct support replacing protection is a liberalizing move with a safety net; that is
not what the tag records.

**An environment tag was considered and deliberately NOT created.** The environment page is a serious
programme — 100% renewable electricity by 2050, a ₪10B climate fund, closing the Haifa Bay
refineries, refusing to renew the Dead Sea minerals concession in 2030, a live-export ban and
cage-free laying hens. No such tag exists in the vocabulary. Inventing one from a single row's audit
is precisely what revision 15 argued against: it would record which party got read this week, not
which parties hold the position. **Filed as an open question** — audit all 18 rows for environmental
content first, then decide.

**Correction worth remembering:** `anti-clerical` was once removed from this party on the reading
that its kashrut position was competition policy. That was wrong and it was restored. Their own text
asks to "take the government, with its political interests, out of granting kashrut" — that is
disestablishment, not price policy — and their haredi section is about ending the
subsidy-for-study model, the same fight from the fiscal side. Both `anti-clerical` and
`kashrut-liberalization` are true.

### אל הדגל — El HaDegel · `unaligned` · 1 / 2 / −2 · secular

**Six sources, and they are not interchangeable.** Four are PDFs, all linked from one page,
`elhadegel.co.il/our-platform`, under labels that do not match their filenames:

| Link label | Document | Extent |
|---|---|---|
| מסמך מדיניות מורחב | `מצע אל הדגל 28.05.2026` — the platform | 25pp, **image-only** |
| חוק הגיוס | `חוק יסוד השירות` — a drafted Basic Law bill | 9pp, extracts cleanly |
| מסמך מדיניות חינוך | the education policy paper | 7pp, **image-only** |
| מסמך תכנית כלכלית | `הכלכלה הציונית של אל הדגל` — the economic paper | 7pp, extracts cleanly |

Plus two bodies of web text: the **`/our-platform`** page itself (four pillar cards — דגל הביטחון,
דגל הממשל, דגל החינוך והלכידות, דגל הכלכלה — three or four slogan bullets each) and the **vision
chapters at `/about-us`** (קיר ברזל, דור הניצחון, אחדות העם, שבירת הגושים, האתגר הדמוגרפי,
ישראל 2050). Those two share no headings with each other and only the הקדמה with the platform PDF.
Earlier revisions cited both pages as "the website"; the economy and education slogans this entry
quotes are from `/our-platform`, and the שבירת הגושים / commission-of-inquiry material is from
`/about-us`.

**Three retrieval traps, and this row has been wrong from each in turn.** The two image-only PDFs
return 25 bytes from 25 pages and 7 bytes from 7 pages — exit code 0, one newline per page — so both
must be read visually and a pipeline checking only whether the command failed reads that as a clean
extraction. The two web bodies overlap just enough at the הקדמה to look like one document. And the
third, found 2026-08-19: **the two documents that went unread the longest were the two that extract
cleanly.** Retrieval difficulty is a bad proxy for coverage — the hard files got read precisely
because they announced themselves as hard, while the service bill and the economic paper sat behind
one `curl` for months. `elhadegel.co.il` itself is **not** a retrieval problem: it returns 200 to
automated fetching and serves every chapter heading in the HTML, unlike `kachollavan.org.il`.

**Correction (2026-08-19): the platform PDF already carried the funding condition, and this entry
said it did not.** The religiosity note below used to read that the education plank appears in the
platform "only as *שכבת בסיס חובה בכל מוסד מתוקצב*", with the funding position confined to the
education paper. That is false. The platform's education chapter, §2 עיגון חוקי (p. 11), carries
**the 50/30/20 split this entry credited to the education paper** — *"קביעה ש~50% מתכניות הלימודים
יהיו אחידות ברמת המדינה; 30% – יוכפפו לסמכות רשויות; 20% – למסגרות החינוך הספציפית"* — the
entrenchment (*"העברת חבילת בסיס לחקיקה, שביטולה תצריך רוב מיוחד"*), and a funding condition in as
many words: *"חיבור תקציב חינוכי מדינתי בלתי תלוי בקבלת התקן – תנאי לקבלת תקציבים"*. So the
`religiosity 0` this row carried until 2026-08-10 was **not** a fair reading of the evidence then
available; the −2 criterion was in the primary document all along and was missed because that
document is image-only. The education paper corroborated a position it did not introduce. **The
lesson is narrower than "read everything" and worth keeping: a second document agreeing with the
first is not evidence the first was read.**

security **+2**, from a full policy programme rather than the single-issue reservist party the old
tags implied: sovereignty over "areas essential to its security", a reserved "right to take
territorial action", preemptive strikes, and rejection of *both* Oslo and conflict management —
Palestinians get self-governance, never a state. The מסלול ההכרעה הריבונית is quantified: gradual
sovereignty over **~50% of Judea and Samaria** (Area C), argued as demographically safe because
Area C is ~60% of the territory with "מאות אלפים" of Palestinian residents — *"כך שאין כאן 'סיפוח
מיליונים'"*. Not +3: secular-nationalist rather than messianic, and neighbours who abandon terror
are offered development and self-rule under a conditional-peace track modelled on תוכנית המאה.

economic +1 for the same reason as Together — eliminating ministries and a 30% budget cut, offset by
massive periphery infrastructure and a strategic-industry programme. The constitutional material
(Basic Law supermajorities, a minister cap, tiered judicial review, an 8-year PM term limit) and
the "El HaDegel Service" Basic Law drafting every citizen — with refusal forfeiting economic and
employment rights — were entirely unrecorded before revision 15.

**economic re-examined a third time on 2026-08-19 against the dedicated economic paper, and stays
+1.** The paper is dated **August 2026** and marked *גרסה מתוקנת ומעודכנת* — newer than the pass
that last confirmed this axis, and it is the document that pass did not have. It does not move the
number; it makes it much harder to move. The website's economy card still reads as +2 or +3 doctrine
(*"יוסרו כל הרגולציות והחסמים על השוק מלבד החיוניים"*, remove every regulation but the essential
ones, alongside the 30% cut), and the paper behind it is the +1 band's fusion in its most explicit
form yet — every chapter costed, with a named funding source:

- **Liberalizing:** abolition of 15–40% tariffs on basic food from the EU, parallel imports, direct
  entry for EU-approved goods, monopoly break-up, one-click bank switching, regulation with a
  five-year expiry that auto-repeals if unproven, a 72-hour declaration-only licence for low-risk
  businesses, and *silence-is-consent* SLAs on licensing and planning.
- **Expanding:** negative income tax raised to a ₪12,000 ceiling tapering to ₪18,000 (₪4B/yr), a
  servers' grant of ₪4,800 for completed regular service and ₪3,600 for 45+ reserve days with **no
  income or children test** (₪1.5B/yr), 100% reserve compensation for the self-employed (up from
  75%) plus a ₪2B state guarantee fund (₪1.2B/yr), a national AI programme at ~$1.5B/yr, and a
  high-speed rail commitment connecting the Galilee and Negev to Gush Dan within an hour.

**Two features argue against +2 specifically, and both are the party's own.** It **rejects the
standard liberal instrument on principle** — periphery tax breaks are dismissed as decades of proven
failure (*"ברגע שהממשלה משתנה ההטבות מבוטלות"*), replaced by zero-regulation innovation zones and
state-built infrastructure. And its financial-centre chapter, otherwise the most market-liberal in
the document, ends on *"שוויון מיסוי הון ועבודה: הגבלת הטבות מס בכלי חיסכון הוניים לבעלי הכנסה
גבוהה מאוד"* — restricting capital tax benefits for the very highest earners. A +2 row does not
write that sentence. **Recorded because the next pass will find the deregulation slogan and reach
for +2 again; it has now been declined three times on three different documents.**

**One discrepancy between the two economic sources, unresolved and left that way.** The platform
(p. 16) legislates *"ממשלה תכלול עד 16 שרים ומשרדים בלבד"*; the August paper legislates a **cap of
18** while aspiring to 12. The newer document loosened the binding number and raised the rhetorical
one. Neither is cited here as "the" figure.

**The economic paper is unusually self-correcting, and that is itself the finding.** It walks back
its own earlier estimates in marked *עדכון חשוב* blocks — the ministry-merger saving is demoted from
₪8–12B/yr to "a long-run ceiling, not guaranteed first-year revenue, because international reviews
put net savings at 1–3%"; the intermediate tax bracket's cost is revised **down** because the
Knesset already enacted part of the reform in early 2026; the undeveloped-land tax is credited to
the state budget as *"ניצחון של הלחץ הציבורי"* rather than claimed as pending. It commits to
publishing a full fiscal assessment with sensitivity ranges before every vote, and states plainly
*"אנחנו מעדיפים תוכנית שמדייקת על פני תוכנית שנשמעת טוב יותר"*. No axis and no tag turns on this;
it is recorded because a party that publishes downward revisions of its own numbers is rare enough
that a future reader should not mistake the +1 for a hedge in the *reading*.

religiosity **−2 (was 0, moved 2026-08-10; re-confirmed 2026-08-19).** The condition on state money
is stated in both the platform (above) and the education paper — *"יישום תכנית 'חבילת הבסיס' תהווה
תנאי לקבלת תקצוב חינוך מהמדינה (בכל הרבדים, כולל בינוי)"* — and for institutions that will not
comply, *"הפסקת תקציב הדרגתית אבל מוחלטת לכל המוסדות שאינם עומדים בקריטריונים לחינוך ציבורי"*, after
a five-year adaptation plan. That is the −2 band's defining criterion, and the same evidence that
moved כחול לבן −1 → −2 on 2026-08-01 and בית ציוני - המילואימניקים 0 → −2 on 2026-08-08. It is
entrenched rather than aspirational: repeal needs a special majority, and the base layer is 50% of
the curriculum nationally with 30% to local authorities, leaving the stream itself 20%.

**Decision 6 is why this took three passes to see, and it is also what holds the row at −2 now.**
Conscription stays off this axis; the exemption fight stays in
`anti-conscription-exemption`/`universal-conscription`. With conscription set aside, "mandatory core
curriculum, offset by a Values Pillar grounded in Jewish heritage plus community autonomy above the
core" was a fair reading of the *slogan*, and the funding clause beneath it was simply unread.

**The service bill contains a second education-funding sanction, and it does NOT move this axis.**
§11(c) strips all direct and indirect state support from any educational institution where more than
**10%** of students or graduates breached the service duty, and bars it from accepting donations of
any kind, in money or in kind, domestic or foreign. That is a funding condition on religious
education with a sharper edge than the curriculum one — but it is conditioned on **service**, not on
curriculum, so Decision 6 keeps it off the religiosity axis and inside
`sanctions-on-non-servers`/`service-conditioned-citizenship`. **Recorded because it reads like −3
evidence and is not**: the −3 band requires disestablishment, and this row still says nothing about
the Rabbinate, marriage, kashrut or Shabbat. כחול לבן sits at −2 without civil marriage; so does
this row, and so does ביחד.

The Values-Pillar offset does not survive the precedent it is measured against. כחול לבן held *a
stated aim that the public space express the state's Jewish identity* and still moved to −2 on the
funding condition; the autonomy here is explicitly the 20% *above* the base layer, the same bounded
devolution as B&W's local-authority Shabbat clause. A Jewish-heritage values component has now three
times failed to offset a funding condition in this document.

**חוק יסוד: שירות חובה למען המדינה — the bill, read 2026-08-19.** The platform names it (*"זהו חוק
יסוד: שירות 'אל הדגל' אותו ניסחנו"*) and previous revisions scored the row from that summary. The
text is a drafted 25th-Knesset bill with blank sponsor lines, and it says more than the summary:

- **24 months from age 18 for every *תושב בישראל*** — citizens, olim and permanent residents alike,
  not only citizens — plus a standing reserve obligation by order, and Knesset power to extend.
- **Four service tracks**, not one: IDF, civilian service (internal security, medicine, agriculture,
  education, welfare, nursing, construction), excellence (arts, exact sciences, sport), and **Torah
  study**. The last two are capped at **2% of each draft cohort each**, and §6(b) forbids assigning
  anyone to a non-military track until the IDF's manpower needs are met "quantitatively and
  qualitatively". §6(c) requires military placement without distinction of gender, worldview,
  religious inclination or place of residence.
- **A מינהלת השירות** whose head is appointed by a panel of the State President, the chair of the
  Foreign Affairs and Defence Committee, and an **opposition** MK — the explanatory notes say
  explicitly this is to insulate the post from political pressure.
- **Entrenchment at 80 MKs** (§14), and a self-executing supremacy clause (§13(d)): if the Knesset
  fails to pass implementing legislation within six months, every law is to be construed to conform
  and any contradicting law is void.
- **§11's sanctions are far more extensive than the tag implied** — eight heads covering state and
  municipal economic benefits, firearms licences, affirmative action, public-sector employment,
  subsidised housing, commercial contracting with the state, appointment as a director or control of
  a public company, and breach as **sufficient grounds for any employer to refuse to hire or to
  dismiss**. §11(b) extends four of those heads to **any corporation contributing to the breach**;
  the explanatory notes name charities that help evaders financially.

**Planks recorded 2026-08-10, all previously absent.** From the website chapters: a demand for a
**state commission of inquiry** into 7 October (*"מי שכשל צריך ללכת הביתה"*, `state-commission-of-inquiry`);
Basic Law **protections for a sitting PM** (`pm-immunity-protections`); a standing pre-committed
**territorial price** for attacks on the state (`territorial-price-doctrine`); and the demographic
chapter's haredi and Arab labour-market integration track, *"היעד איננו 'לגייר' אף קהילה"*
(`workforce-integration`). From the platform PDF: a **voluntary-emigration** benefits basket for
Palestinians choosing to leave, held distinct from `population-transfer` (זהות's, and הציונות הדתית's since the 2026-09-01 merge) because it is
opt-in (`voluntary-palestinian-emigration-incentives`).

**Those first two planks point opposite ways, and that is the finding, not a defect.** Demanding a
state commission of inquiry is the anti-Netanyahu marker; entrenching protections for a sitting PM
is the pro-Netanyahu one. For a party whose organising pitch is שבירת הגושים — refusing the
"רק ביבי"/"רק לא ביבי" binary in as many words — holding both is coherent, and it is the strongest
single piece of evidence for `unaligned` in any of the six sources. Note the platform PDF is
narrower than the website card here: an 8-year term cap with immunity confined to חטא ועוון,
misdemeanours (p. 16, confirmed against the page 2026-08-19). The tag records the website's broader
claim; this sentence records the gap.

**Four tags added 2026-08-19, all from the existing vocabulary.** Three of the four are earnable
from the platform PDF alone, which is the more useful half of the finding: they were missed by an
earlier pass, not created by the new documents.

- `free-trade` — platform p. 22, *"הסרת חסמי יבוא: ביטול מכסים, מכסות ורגולציות מיותרות, התאמת תקני
  יבוא ל-OECD והרחבת חוזי סחר חופשי"*; the economic paper quantifies it at 15–40% on basic food from
  the EU. Fourth holder.
- `anti-monopoly` — platform p. 22, *"מאבק בריכוזיות: אכיפה גמישה וחזקה של חוקי ההגבלים העסקיים,
  פיצול מונופולים"*; the paper adds the food market, banking and discount-chain entry. Sixth holder.
- `public-service-reform` — platform pp. 19–20: a *"חוק שירות ציבורי ממלכתי"* entrenching
  professional standards and barring political appointments, a national public-service authority, and
  a biennial published *"מדדי אמון ושירות"* index carrying a **mandatory Knesset debate**. The
  economic paper adds quarterly public KPIs per ministry with budget consequences. Comparable in
  extent to כחול לבן's צו 8, which founded the tag. Third holder.
- `arab-civil-service` — service bill §8, *"בן העדה הערבית לא יחוייב בשירות צבאי ללא הסכמתו"*, with
  the explanatory notes completing it: *"אולם הם יהיו מחוייבים לשרת באחת ממסגרות השירות האחרות"*.
  That is כחול לבן's founding position in statutory drafting. Third holder.

**Six candidates rejected, each for a reason meant to outlive the row:**

- `scholar-exemption-retained` — **third application of revision 21's test, and the clearest.** The
  Torah track is capped at 2% of a cohort, sits under a state administration, is subordinated to the
  IDF's needs being met first, and is a 24-month *service* obligation rather than a deferral from
  one. That is strictly narrower than ישר's 3% one-year deferral, for which the tag was already
  declined. Tagging it here would erase the distinction the tag exists to draw — the same reasoning
  that keeps it on כחול לבן and המפלגה הכלכלית, who retain real exemptions.
- `permanent-residency-not-citizenship` — the השארות track grants permanent residency with Palestinian
  citizenship, but it is explicitly a **path**: after years, conditional on rejecting terror, civic
  integration and identification with the state's founding principles, a resident *"לבקש אזרחות
  ישראלית מלאה"*, so that *"ההצטרפות לאזרחות הופכת לביטוי של שותפות ולא למניפולציה פוליטית"*. The
  זהות tag (on הציונות הדתית since 2026-09-01) records a permanent ceiling. A conditional path and a ceiling are not the same position.
- `small-government` — the 32→12 ministry ambition is real, but זהות held this tag as libertarian
  doctrine (and the tag left the vocabulary with it on 2026-09-01, refused by the merged row), and this row pairs the cuts with NIT expansion, a ₪2B guarantee fund, a ~$1.5B/yr AI
  programme and a national rail commitment. Applying it would contradict the `economic +1` reading
  three paragraphs above. `deregulation` and `public-service-reform` carry the institutional half
  correctly.
- `tax-cutting` — the 25% intermediate bracket is framed as *completing* a reform the Knesset already
  passed, its cost is revised **downward** for that reason, and it sits beside a plank restricting
  capital tax benefits for the highest earners. That is not the doctrine ישר and המפלגה הכלכלית hold
  the tag for.
- `judicial-overhaul` — a *"פסקת התגברות"* appears (p. 15), but *"מוגבלת בזמן ובנושא"* and paired
  with **strengthening** Knesset committee review of Basic Law implementation, a codified constitution
  drafted by a two-year מועצה ממלכתית לחוקי יסוד ומשטר, and a graded doctrine of judicial review set
  in statute. Filing this with הליכוד/RZP/עוצמה/נעם would misrepresent it; `constitutionalist`, which
  the row already holds, is the accurate tag. Same shape as revision 23's rejection for Zelikha.
- **A workfare tag and an anti-union tag**, both clearly earned and both refused. The row runs a full
  conditional-welfare doctrine — income support conditioned on 20 weekly hours of work, training or
  community service, daycare subsidy moved from a birth test to a work-and-service test with serving
  parents prioritised, and *"מבחן תעסוקה ושירות ולא מבחן ילודה"* — and a distinct labour-organization
  plank (*"ארגוני עובדים: שותפים ולא שחקני וטו"*, limiting direct public funding, opening to
  competition, abolishing institutional veto). Refused on revision 15's standing reasoning: a tag
  born from one row's audit measures reading coverage, not position. **Filed as open questions.**
  ישר's near-identical *"העבודה תשתלם תמיד יותר מקצבה"* — the very sentence that got `welfare-state`
  rejected there — is the immediate proof that the workfare sweep would find more than one holder.

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
than stretched. Compare `communitarian-devolution`'s only other holder — the זהות faction at **+2** on its own
platform, the tag now sitting on הציונות הדתית's **+3** row since the 2026-09-01 merge: the same
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

### האחדות — Unity · **withdrew 2026-09-04, removed from the ballot** · was `unaligned` · 1 / 2 / −2 · traditional

**גלעד ארדן announced on Friday 2026-09-04 that האחדות will not contest the election, and the row
was removed from `upcoming_parties` the same day.** Merger talks with כחול לבן had collapsed earlier
that day; the stated reason is the threshold, not a policy change:
*"התמיכה עד כה במפלגת ״האחדות״ שהקמתי אינה מבטיחה בסבירות גבוהה את מעבר אחוז החסימה, וגם אפשרויות
החיבור עם מפלגות נוספות בגוש האחדות אינן מתממשות"*, and
*"מנהיגות היא גם להכיר במציאות כפי שהיא ולפעול באחריות"*. He also read the electorate as wanting
*"הכרעה ברורה בשאלת זהות ראש הממשלה"* rather than a broad unity government — which is the premise the
whole row was scored on. Sources:
[ynet](https://www.ynet.co.il/news/article/b184d800ofg),
[כאן](https://www.kan.org.il/content/kan-news/politic/live-1095963/),
[ישראל היום](https://www.israelhayom.co.il/news/politics/article/21355002),
[חדשות 13](https://13tv.co.il/item/news/politics/state-policy/ta3n1-905343936/).

**A fourth roster-change shape: a withdrawal has no successor**, so unlike either merge there is no
rename, no new `seed_key`, no surviving brand and no `party_lineage` edit — just the guarded delete,
which is also why this one is the cheapest of the four to undo. **Nothing left the tag vocabulary
with the row**, and no family fell below two holders, so — unlike revision 37 — there is nothing to
retire from `i18n.js`, `analytics.js` or `family-strings.csv`: all 21 tags survive elsewhere and all
three families (`universal-conscription`, `constitutional-reform`, `cost-of-living`) keep at least
two holders. Two tags drop to a **single** holder — `unity-government` (כחול לבן) and `deregulation`
(אל הדגל) — which is permitted for tags and is not for families; that asymmetry is the whole reason
revision 37's `market-liberal` had to go and these two do not.

**Verified on an already-seeded database, both branches, 2026-09-04**, the same way the זהות removal
was — a fresh install would only prove the literal was deleted, not that an existing row moves:

- **no ballot naming האחדות** — 18 → 17 rows, `unity` gone, and a second application of the new file
  leaves 17 (idempotent).
- **one ballot naming האחדות** — the row **survives** at 18 rows with its ballot intact, which is the
  vote guard failing safe. **Production could not be checked**: the cluster was torn down at the time
  of writing, so whether the row actually disappears is decided on the next deploy. If it holds any
  vote for האחדות, the withdrawn party stays on the ballot until an admin reassigns that vote — and
  unlike the זהות case there is **no successor line to reassign it to**.

**The entry is kept in full rather than deleted**, on the זהות precedent: list submission does not
close until the week of 2026-09-07, Erdan withdrew the *candidacy* and explicitly not the political
project (*"אני מסיר היום את מועמדות מפלגת ״האחדות״, אך לא את מחויבותי הציבורית"*), and if the row
returns this is the scoring it starts from. The reasoning below is as it stood on 2026-09-03 and
describes a party that is no longer on the ballot.

New party for 2026, led by גלעד ארדן (Gilad Erdan) — 17 years in the Knesset, Internal Security /
Interior / Strategic Affairs, then ambassador to the UN and the US. Slate: יולי אדלשטיין,
ד״ר עליזה בלוך, אורן סמדג׳ה, אל״ם חזי נחמה. Scored 2026-08-23 from the party's own site
(`haachdut.org.il`), which is the entire published corpus: `/`, `/about` (הדרך שלנו),
`/platform` (אנחנו מתחייבים) and `/candidates`. **No PDFs — the link enumeration was run and
returned nothing**, so unlike אל הדגל there is no second tier of documents to miss. The site
itself says *"האתר בבנייה, תכנים נוספים יועלו בקרוב"*, so this row is expected to need revisiting.

**`unaligned`, and this is the party's central plank rather than a classifier's hedge.**
*"לא ניכנס לשום ממשלה צרה - לא מימין ולא משמאל"*, and specifically neither a left government nor
*"חותמת גומי לממשלת ימין צרה שתנציח את ההשתמטות ותעמיק את הפילוג"*. A right-wing party that
pre-commits to refusing the right's own narrow coalition does not sit in `bibi`.

security **+2** — the band's definition almost verbatim. No Palestinian state
(*"אנחנו מתנגדים נחרצות להקמת מדינה פלסטינית"*), a territorial claim
(*"ארץ ישראל שייכת לעם ישראל"*, settlement strengthened in יהודה ושומרון, הגולן, הגליל and הנגב),
and a preemptive doctrine (*"הכרעה, שלילת יכולות האויב וגדיעת איומים לפני שהם מתפתחים"*).
**Not +3**: סיפוח appears nowhere, there is no Gaza-hardline plank, and the row pairs all of the
above with *"נרחיב את השלום מתוך עוצמה"* — the same shape that holds כחול לבן at +2.

economic **+1** — liberalizing fused with real state expansion, which is exactly what the band is
for. Deregulation and competition (*"נפחית רגולציה וחסמים"*, *"נפתח את המשק לתחרות, נרחיב יבוא
מקביל"*, *"נפעל נגד מונופולים"*) sit alongside a trillion-dollar growth target driven by state
investment in *"תשתיות, בהון אנושי, בבינה מלאכותית"*. **Not +2**: there is no tax plank and no
privatization plank anywhere in the corpus, which is what separates this row from ישראל ביתנו.

**religiosity −2, and the −1 reading was considered and rejected on the כחול לבן precedent.**
The instinct is to score this row −1: its religion-in-public-life material is mild and warm —
*"הזהות היהודית שלנו אינה מבחן. היא בית משותף"*, tradition as שבת/חגים/משפחה, Jewish identity
advanced *"לא באמצעות כפייה או שיפוטיות"*, expanded תנ״ך and מורשת teaching, protection of the
holy sites, and **no** civil marriage, kashrut or Rabbinate plank at all. But that is the first of
the two fights this axis folds together, and the band keys on the second:

- **Core curriculum as a funding condition** — *"מימון ציבורי יותנה בהקניית ליבת ידע ומיומנויות
  מלאה ובמדידה שקופה של תוצאות"*. This is the −2 criterion stated in the band text.
- **Universal conscription with personal sanctions** — *"חוק יסוד השירות"* binding
  *"חובת שירות אישית לכל אזרח ואזרחית"*, *"במקום יעדים מגזריים תהיה אחריות אישית"*, and a legislated
  *"מעמד משרת"* where *"מי שבוחר להשתמט יישא בסנקציות אישיות"*.

That is the same pairing that moved כחול לבן from −1 to −2 once its education paper was read, and
the warning in the axis section above — *the religion-and-state chapter alone will systematically
under-score a party* — applies here with the polarity reversed: this row has no religion-and-state
chapter at all, only tradition-as-identity prose, and scoring from that prose alone reproduces the
same error. Position **within** the band is the low end: nothing is disestablished, and the
adapted-track language for the haredi public (*"נרחיב מסלולים מותאמים לציבור החרדי, שיאפשרו לשמור
על הזהות"*) is accommodationist in a way ישר's is not.

`traditional`, not `secular` — the sector is about constituency and idiom, not the axis, and
*"מסורת שמחברת"* is a whole section of the platform aimed at masorti right-wing voters. It is the
same combination הליכוד carries (`traditional` sector) with the religiosity sign inverted.

**Tags deliberately NOT applied**, each because the evidence is weaker than the tag's founding case:
`reservist-focused` (the corpus mentions מילואימניקים once, in passing —
*"ונקל על המילואימניקים"* — against holders built on a reservist movement); `judicial-overhaul`
(the row explicitly refuses it: *"לא נוביל מתקפה על מערכת המשפט"*, and proposes
חוק יסודות החקיקה while preserving *"עצמאות בית המשפט... ושלטון החוק"*, which is why
`constitutionalist` is the right tag instead); `state-haredi-education` (the adapted tracks are
*service* tracks, not school streams); `anti-netanyahu` (the refusal is of narrow coalitions, not
of a person).

**Not added to `previous_parties`** — the party did not exist at the previous election, so there is
no lineage link to draw either.

### עמך ישראל — Amcha Yisrael · `bibi` · NULL / 3 / −2 · secular

New party, launched **2026-08-25** at the Shalva Center in Jerusalem by
**תא"ל במיל' עופר וינטר** (Brig. Gen. (res.) Ofer Winter), former Givati brigade commander. Slate:
**יוסף חדאד** at #2 — a hasbara activist, Arab-Israeli **Christian** and IDF-disabled Golani combat
commander wounded at Bint Jbeil — then נטעלי שם טוב (news anchor), עו"ד ערן בן ארי (opposition chair
in the Bar Association), ללי דרעי (bereaved mother), סיגל קראוניק (Be'eri widow), דוידי בן ציון
(deputy head, Samaria Regional Council), אל"ם במיל' אלי ג'ינו, אביב עזרא (chair of the reservists'
movement דור הניצחון), פלר חסן-נחום, and the economist רונן בודנרו. **No sitting MK and no defector
from any existing party.**

**The corpus is two events and no document.** Still no website, no platform and no manifesto. The row
was first scored 2026-08-27 from same-day reporting of the launch, where two of the three axes came
out NULL as *positive findings of absence* — verified by keyword sweep across five independently
fetched sources, not left blank for want of looking. A press conference on **2026-09-02** added the
party's first substantive policy statements and moved `religiosity` off NULL; `economic` is still NULL
on the same basis. `basis` stays `record`, since on-the-record statements are not a published
platform.

security **+3**, and it is the only axis with evidence. Winter, at his own launch, on the record, in
front of cameras: *"לעולם לא תהיה פה מדינה פלסטינית. הפיתרון בעזה הוא אחד - הגירה"*, and
*"אויב שיפתח נגדנו במלחמה ישלם מחיר טריטוריאלי כבד"*. Carried by Ynet, i24, מקור ראשון and הארץ
(whose headline is literally the Gaza line); no retraction or qualification in the two days since.
**Record the verbatim word.** He said **הגירה** (emigration), *not* **טרנספר** — the "transfer" gloss
adds a compulsion the Hebrew leaves open, and that distinction decides two tags below.

economic **NULL** — *not* 0. Nothing on tax, cost of living or budgets; a 0 would assert a
confirmed centrist position this party has not taken. It is still NULL after the 2026-09-02 press
conference, whose only spending line of any kind is חדאד's demand for a hasbara ministry
*"עם תקציב עתק"*.

religiosity **was NULL and is now −2** — see the 2026-09-03 block below. It was NULL as a *positive
finding of absence* on 2026-08-27 (nothing on שבת, כשרות, נישואין אזרחיים, הרבנות or הלכה), and it
was listed in `RELIGIOSITY_NULL_BY_DESIGN` in `test_queries.py` as a **placeholder, not a permanent
exemption** — unlike רע"ם and חד"ש-תע"ל, where the axis genuinely does not apply — with Walla's
prediction that the messaging would turn to *שינוי המדיניות סביב שירות החרדים* written down as the
trigger. It did, six days later, and the entry was removed from that set. **The placeholder worked as
designed; it is not a correction.**

**⚠ Two widely-repeated claims about this launch are false.** That Winter's speech addressed **haredi
conscription / IDF integration** and **judicial reform** (*"שינוי משמעותי במערכת המשפט"*) were both
**refuted 0–3** in adversarial verification against the מעריב source they trace to. A third,
attributing a conscription position to אביב עזרא's prior *חוק גיוס אפקטיבי* campaigning, was refuted
the same way — his membership of the list is confirmed, the inference from it is not. Do **not**
score religiosity from any of them.

*(Amended 2026-09-03: the refutations stand as statements about the **launch speech**, which is what
they were checked against, and the third — the inference from עזרא's prior campaigning — is still
refuted. But haredi conscription is now the party's own headline position, stated first-party a week
later. "The launch speech did not say X" and "the party has no position on X" are different
propositions, and only the first was ever verified. The warning is kept because that distinction is
the useful part.)*

**`bibi` — resolved 2026-09-02, and no longer the weakest field on this row.** Winter has now named
Netanyahu himself: *"'עמך ישראל' היא חלק ממחנה הימין ותמליץ על נתניהו כראש הממשלה"*, restated at his
own press conference alongside an explicit refusal of the other camp
(*"ברור שלא נלך עם ליברמן, בנט ואחרים"*). `hard-to-classify-bloc` is **removed** — see the 2026-09-03
block. The reasoning it was carried on is kept below, because the counter-evidence has not gone away;
it has been shown to be about the relationship rather than the bloc, which is exactly the reading
revision 32 took.

The original 2026-08-27 assessment, kept as the record: **`bibi`, on declared camp rather than any
endorsement — then the weakest field on this row.** For:
*"אנחנו חלק ברור ומובהק במחנה הימין"*, *"נעשה הכל כדי להקים ממשלת ימין רחבה ככל הניתן"*, and an
explicit refusal to have גדי איזנקוט as prime minister; Ynet assigns him to the bloc
(*"מזוהה כמי שמעדיף את נתניהו"*) and reports his seats come from coalition voters. Against, and it
is substantial: **Winter has never named נתניהו**, refused both merger and a שיריון, and Netanyahu is
publicly campaigning against him (*"שלוש פטריות אחרי הגשם... פייגלין, מעוז ו-וינטר"*); N12 reports
Netanyahu privately expects him to cross over, and the pollster מנחם לזר places him in a "third
bloc". The reading taken here is that the counter-evidence concerns his relationship with *Netanyahu
personally*, while ruling out the other camp's candidate for PM is a bloc declaration.
`hard-to-classify-bloc` carried the hedge, as it still does on כחול לבן.

`secular`, on the party's own framing — *"עם רוב חילוני"*, and an explicit attempt
*"לבדל את המפלגה מהמפלגות הציוניות-דתיות והימין הקיימות"*. **Held with reservations**: it is a party
self-description relayed through unnamed sources in all three outlets that carry it, deployed
strategically to rebuff a merge-with-Smotrich demand, and hedged by Walla itself
(*"בשלב זה מסתמן כי"*). Winter is religious, דוידי בן ציון of אלון מורה is on the list, and a launch
attendee told the Times of Israel *"Ofer Winter is the old National Religious Party."* `traditional`
is a defensible alternative; `religious`/`haredi` are not.

**Tags deliberately NOT applied**, each on this page's own founding-case test:

- **`voluntary-palestinian-emigration-incentives` AND `population-transfer` — neither fits, which is
  the interesting result.** This page draws the line at opt-in: every holder of the first has an
  explicit *מרצון* plus an instrument (גמליאל's costed plan, עוצמה יהודית's 2025-02-07 bill,
  סמוטריץ' costed grants), and `population-transfer` requires **compulsion in the instrument**, which
  is why it stays with הציונות הדתית alone — זהות's tag, carried in by the 2026-09-01 merge.
  Winter supplied a bare noun — *"הפיתרון בעזה הוא אחד: הגירה"* —
  with no *מרצון*, no incentive, and **no instrument at all**. It is rhetorically stronger than the
  first tag and weaker than the second, and sits in the gap between them. Adding either would dilute
  it with a weaker *kind* of evidence.
- **`security-hawk`** — the revision 30/31 precedent, unchanged: all five holders are
  centre/centre-right and no far-right row carries it, so a +3 row taking it would erase the
  distinction the tag exists to draw.
- **`anti-two-state`** — not stated. `no-palestinian-state` is, verbatim; annulling-Oslo-type
  evidence is what separates the two, and there is none.
- **`sovereignty-annexation` / `territorial-control-gaza` / `hardline-on-gaza`** — verified absent.
  Nothing on West Bank sovereignty. The Gaza line is a demographic *outcome*, where every
  `hardline-on-gaza` holder's evidence is siege-and-supply *conduct*: a different kind of claim.
- **`reservist-movement`** (as a tag) — אביב עזרא chairs דור הניצחון and Winter and ג'ינו are senior
  reservist officers, but that is list composition against holders whose whole identity is the
  movement. It is carried as a *family* only where it is honest, and it is not carried here at all.

**⚠ This row is expected to be unstable, more than any other on this page.** List submission closes
roughly two weeks after launch; Netanyahu is publicly demanding Winter, פייגלין and מעוז withdraw or
merge, and בן גביר has renewed contacts. Polling is one day old, one pollster, and the outlets
disagree — Walla/לזר reports 6 seats, i24 reports 8 with הליכוד −5, and a same-day הארץ headline put
the new right-wing party *below* threshold. **The party may not reach the ballot as an independent
list.**

**2026-09-03 — the party's first substantive policy statements, from a press conference on
2026-09-02. religiosity NULL → −2, the first axis to move on this row; `bibi` resolved; three tags
added and one removed.**

Corpus: four independently fetched outlets covering the same press conference —
[כאן חדשות](https://www.kan.org.il/content/kan-news/politic/1095484/),
[דבר](https://www.davar1.co.il/695768/),
[ynet](https://www.ynet.co.il/news/article/r1q1jabdgx) and
[מעריב](https://www.maariv.co.il/news/elections-2026/article-1362429). Still no website and no
written platform, so `basis` stays `record`; these are on-the-record statements by the chairman and
the deputy chairman at their own event, quoted at length and consistently across all four, which is
a long way above the single launch report revision 32 had.

- **religiosity NULL → −2, and the score is settled by membership rather than by the band prose.**
  Winter: *"אנחנו מתכוונים להביא לשילוב הציבור החרדי בצה"ל בלי פשרות ובלי דחיות"*, *"כל צעיר בגיל
  שירות יתייצב בפני המדינה. אין מגזר מעל החוק"*, and — the operative part —
  *"לא ניכנס לממשלה שלא תעביר לפני הקמתה חוק ששם סוף להשתמטות ומחייב את כולם להתייצב ולתרום. אם זה
  לא יקרה לא נהיה בממשלה. חד וחלק"*, with *"חוק השירות יעבור לפני השבעת הממשלה. לא הבטחה, לא סעיף
  בהסכם קואליציוני"*. **This row satisfies exactly one of the −2 band's three criteria** — universal
  conscription — and is silent on the other two (no core-curriculum funding condition, nothing on the
  Rabbinate's monopolies). What decides it anyway is the vocabulary's own membership: **all nine
  holders of `universal-conscription` sit at religiosity −2 or −3, and not one is NULL, 0 or −1.**
  In this table the conscription criterion has never once co-existed with a non-negative score, so it
  is already worth −2 on its own. −1 was considered and is wrong *in kind*, not in degree — that band
  is "soften the monopolies without disestablishing", and this party softens no monopoly and is not
  pluralist. This is also the axis's own warning working as written: *"read the education and
  conscription material too; the religion-and-state chapter alone will systematically under-score a
  party."* Here there is no religion-and-state chapter at all, and the whole score comes from the
  conscription half.
- **A fourth row satisfying a fourth different subset of the −2 band.** Revisions 20, 21 and 22 each
  recorded a row clearing that band on a different combination of its criteria; this one clears it on
  the narrowest combination yet — one criterion of three. The band text is now the most-cited
  unresolved item on this page by some distance, and this row is the strongest argument yet that it
  should be rewritten as "reduces the haredi sectoral settlement **or** the religious monopolies"
  rather than as a bundle. Filed under Open questions rather than rewritten here on one row.
- **`bibi` resolved, and `hard-to-classify-bloc` removed** (2 holders → 1, כחול לבן alone; rarity is
  not a defect, revision 19). The hedge was carried for one stated reason — *"Winter has never named
  נתניהו"* — and he has now named him twice on the record, first in a statement a week earlier and
  again here: *"בשבוע שעבר אמרתי בקולי ש'עמך ישראל' היא חלק ממחנה הימין ותמליץ על נתניהו כראש
  הממשלה"*, plus *"ברור שלא נלך עם ליברמן, בנט ואחרים שכבר הקימו ממשלה עם תנועת האחים המוסלמים"*.
  **The conditionality is real and does not touch the bloc**: he conditions *entering the coalition*
  on the service law passing before the swearing-in, and he apologised to supporters who were
  disappointed by the recommendation (*"אני מבקש להתנצל בפני מי שהתאכזב"*). Recommending a candidate
  for PM is what this field records; joining his government is not.
- **`universal-conscription` added, as a tag and as the row's second family**, and it is the
  **strongest form any holder states**. The three enforcement models revision 22 catalogued (ביחד
  sanctions-only, ישר criminal penalty, כחול לבן coercion plus fines) are all about what happens to
  non-servers; this one is about *when the law passes* — a precondition to the government being
  sworn in, explicitly not a coalition-agreement clause. A fourth mechanism, and the only one whose
  instrument is the party's own coalition leverage.
- **`anti-conscription-exemption` added** (3 → 4). *"חוק ששם סוף להשתמטות"* is the tag's content
  verbatim; *"אין מגזר מעל החוק"* and *"לא עוד מאותו דבר. מה שהיה לא יהיה"* remove any reading of it
  as a negotiating position.
- **`arab-civil-service` added** (3 → 4), and this is the *correct* match on the name revision 36
  flagged as inviting the wrong one. The tag marks a national-service track for Arab citizens.
  חדאד, the deputy chairman, states it outright: *"תהיה פה שותפות בנטל - לא משנה אם מדובר על יהודים
  או ערבים, חילונים, דתיים או חרדים"*, against Winter's *"כל צעיר בגיל שירות"* and *"אין מגזר מעל
  החוק"*. **Note the cross-row irony and do not let it pass unrecorded**: revision 15's open question
  on הדמוקרטים — does *"הרחבת גיוס של אוכלוסיות נוספות"* include Arab citizens? — has now been
  answered explicitly by a *different* party, from the opposite bloc, through its Arab deputy
  chairman. It does not resolve the question on that row, but it disposes of the reading that the
  vagueness there is merely awkward to write down.
- **`service-conditioned-citizenship` considered and REJECTED, on the name-trap discipline.** Winter
  does say *"מי שישרת, יקבל. מי שיתרום יותר, יקבל הרבה יותר. לוחמים ומשרתי מילואים יהיו בראש סדר
  העדיפויות הלאומי"*. But this tag's founding case is Hendel's **franchise** clause — revision 20
  recorded that the tag "rests on" it even after בית ציוני's own platform declined to restate it —
  and a graduated benefits ladder is not a claim about citizenship. Granting it here would repeat the
  `arab-civil-service` error in the other direction: matching a name instead of a position. **Logged
  as a vocabulary problem rather than settled on this row**: five holders now sit under a label whose
  founding case only one of them meets.
- **`sanctions-on-non-servers` REJECTED** on the revision 15 line. All seven holders name a concrete
  penalty — a fine, a withdrawn entitlement, a criminal charge. This programme names only rewards,
  graduated by contribution. A reward ladder and a penalty schedule are not the same instrument, and
  the tag was created to record the second.
- **`reservist-focused` REJECTED** on the revision 13 standard, which is a costed benefits package
  rather than rhetoric. *"בראש סדר העדיפויות הלאומי"* is a priority claim with no benefit, no number
  and no instrument attached.
- **The Arab-society campaign is recorded in prose and earns no partnership tag.** חדאד is confirmed
  as **deputy chairman** (*"בהובלת עופר וינטר, כשאני סגנו"* — revision 32 had him only as #2), sets an
  explicit target of *"שני מנדטים מהחברה הערבית"*, argues *"בחברה הערבית הסוגיה הפלסטינית נמצאת
  בתחתית סדר העדיפויות"*, and commits the party to *"להעצים את הזהות הערבית-ישראלית במקום
  הפלסטינית בכל מוסדות החינוך הערביים-ישראליים"* alongside a crime-and-protection campaign. That
  last clause is why **`jewish-arab-partnership` is refused**: partnership as this page uses it is
  shared-society equality, and replacing one national identity with another in the state's Arab
  schools is a different position — arguably the opposite one. `arab-representation` and
  `focuses-on-arab-israeli-civil-issues` are refused on revision 36's distinction, which this row
  tests from the other side: both record what a party **is**, and a right-wing Zionist list running an
  Arab-society campaign through an Arab deputy chairman is a striking fact about Israeli politics and
  still not an Arab party.
- **security +3 and economic NULL both held, with nothing new either way.** Neither the press
  conference nor any of the four reports contains a sentence on sovereignty, annexation, the West
  Bank or borders; the security content is Winter's ambition to be defence minister and a claim that
  the current government cannot deliver *"הכרעה ברורה בעזה"*. The +3 continues to rest entirely on
  the two launch quotes, which is worth restating rather than letting a second corpus imply
  corroboration it does not supply.
- **The instability warning is sharper, not softer.** Netanyahu's people offered Winter **all five
  remaining reserved slots on the Likud list, four of them above #30, in exchange for withdrawing**;
  Winter refused to take the call at all (*"אין על מה לדבר"*). סמוטריץ' appealed publicly —
  *"אני קורא לווינטר... עופר, אל תיקח סיכונים"* — and the הציונות הדתית/זהות technical bloc signed the
  previous day (revision 37) is expected to try to add him. Winter's answer is categorical:
  *"אנחנו לא מתכוונים להיכנע. לא ניפול, לא נתפרק... אנחנו לא מחפשים סידור עבודה"*, with the door left
  open only to *"אנשים חדשים ונקיים"* individually. **The row is still expected-unstable**, but the
  instability now has a documented price attached to it.
- **A source-access correction with a rule behind it.** `services/backend/CLAUDE.md` recorded
  `davar1.co.il` as returning **403**. It returned **200** on the first try today with a browser
  User-Agent plus `Accept`, `Accept-Language` and `Referer` — the same shape that fixed
  `kachollavan.org.il` (2026-08-11) and `timesofisrael.com` (2026-08-26). That is the **third**
  instance, and the note has been corrected. A domain written off as blocked costs coverage, not
  effort: this row's whole religiosity score comes from a press conference that דבר covers more fully
  than any of the other three.

**Not added to `previous_parties`** — it did not exist at the previous election, so there is no
lineage link to draw either.

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

**2026-08-31 — `jewish-arab-partnership` added (tag and family, 2 → 3 holders each). No axis moved.**
On 31 August 2026 Abbas and **יואב סגלוביץ'** announced at a Nazareth press conference that Segalovich
takes the **second slot** on Ra'am's list — the first Jewish candidate in the party's history, and the
highest-placed. He is a former ניצב who founded לה"ב 433 and headed the police investigations and
intelligence branch, then sat for יש עתיד and served as **Deputy Minister of Public Security in the
Bennett–Lapid government**, where he ran the government's campaign against crime in Arab society
(*מסלול בטוח*); he resigned from יש עתיד and from the Knesset in early August 2026. Read from ynet,
[וואלה](https://news.walla.co.il/item/3864608) and [דבר](https://www.davar1.co.il/695470), the last two
carrying the statements at length. (The JPost article cited alongside them by a research pass **404s**;
the Hebrew three are the record here.)

**The tag is earned on the same standard הדמוקרטים's was, and by a stronger instance of it.** Revision
36 recorded that row as earning `jewish-arab-partnership` "from the realized list (בשיר at #10) and
from scattered lines in other papers" before its Arab-society paper arrived. Here the realized list is
**#2**, and the framing is the party leader's own, not a classifier's inference:

- *"כדי לייצר שינוי, צריך שותפות. שותפות אזרחית"*, and *"יש מפלגות שמפחדות משותפות... רע"ם לא מפחדת
  משותפות. רע"ם מקדמת אותה"*.
- *"אני לא מחפש מי שדומה לי. אני מחפש מי שיודע לעשות את העבודה"* — his own answer to *"מה ערבי צריך
  ניצב יהודי"*.
- Explicitly **not** a sectoral favour — *"זו לא טובה לערבים"* — and argued to the Jewish public in
  shared-society terms: *"הנשק שיורה היום בטמרה יירה מחר בעפולה... זאת לא בעיה של הערבים. זאת בעיה של
  המדינה"*.
- Segalovich's half is a joint civil agenda — crime, health, welfare, planning and building —
  and *"אני רוצה במפורש לשבור את הפרדיגמה של קווי הגבול וקווי השיח"*.

**The strongest argument against it is recorded rather than buried, because it nearly won.** The
linkage is **technical and personal**: *"אני לא מתחבר לרשימת רע"ם עם סיעה, אני אישית מצטרף לרע"ם"*,
with both sides keeping their positions — *"אני לא מתכוון לשנות את מנסור ואת רע"ם והם לא ישנו אותי"*,
and on LGBTQ rights *"יודעים את עמדתי - היא לא השתנתה. יודעים את עמדתו של מנסור עבאס - גם היא לא
השתנתה"*. That is a coalition of convenience on civil issues, not agreement. It is tagged anyway
because **this family's test is shared-society equality, not shared ideology** — הרשימה המשותפת holds
it on exactly the model of Jews and Arabs acting together across a real disagreement, and Segalovich's
own formulation is that one *"ההתקדמות שלנו היא מתוך הבנת השונות, ולא מדמיון וזהות"*. The refusal
under עמך ישראל is not the contrary precedent it looks like: that row was refused for **identity
replacement** — replacing Palestinian identity with Israeli-Arab identity in the state's Arab schools
— which is a different position, arguably the opposite one.

**`sector` stays `arab` and `focuses-on-arab-israeli-civil-issues` is only reinforced.** A Jewish #2
does not change whose constituency and idiom this row is, and the announcement's whole substantive
content — crime, health, welfare, planning — is the civil-issues tag's own subject matter.

**No axis moved, and one lead is deliberately left unscored.** Nothing in the three sources touches the
economic 0 or the religiosity NULL. On `security`, the only statehood content is **הליכוד's** attack
(*"דוחף להקים מדינה פלסטינית"*), which is a rival's characterisation and not admissible here. A
research pass reported that Abbas said at Ra'am's **2026-08-22** list conference that the State of
Palestine already exists and called for recognition and an end to *"the occupation"* — which, if
sourced, would be the **dated first-party** text this entry has been waiting for since the IDI page was
set aside as pre-2021 Joint List material. **It could not be verified** (the session's search budget
was exhausted), and it is *not* scored on that report. It probably does not reach −3 regardless: this
page's −3 needs withdrawal **plus** right of return **plus** dismantling the settlements, and one
clause is not three. **Trigger:** find the 2026-08-22 conference in a datable first-party source and
re-read the security axis against it.

**Two things still owed on this row.** The civil-service item above is *still* undated — nothing in
this announcement restates it, so the "date it and it earns a tag" trigger stands. And no tag covers
**crime and personal security in Arab society**, which is the substance of both speeches; it is not
created here because it would need the הרשימה המשותפת and הדמוקרטים corpora read for holders, and it
joins the Kaminitz-Law gap already queued behind a pass over the two Arab-list rows. **This pass
covered one of those two rows, not both.**

### הרשימה המשותפת — The Joint List · `opposition` · −3 / −3 / −3 · arab

**Formed 2026-08-20**, when חד"ש-תע"ל and בל"ד signed an agreement to run on one slate: #1 יוסף
ג'בארין (חד"ש chair), #2 אחמד טיבי (תע"ל chair), #3 סאמי אבו שחאדה (בל"ד chair). One upcoming row
replaces the two. Both `previous_parties` rows stay exactly as they were — the two lists genuinely
did run separately in 2022 and that section is frozen — and `party_lineage` carries both
predecessors into this row, the same two-into-one shape as העבודה/מרצ → הדמוקרטים.

**רע"ם is NOT in it** and keeps its own row. It said it was willing to join a technical joint list
provided its political independence was guaranteed; the agreement was signed without it and the door
left open. If it joins before the September list-submission deadline, this row changes again.

**All three axes are the union of the components' published positions** — not an average, and not
the lead party's numbers carried over as a rebrand. This was the repo owner's call on 2026-08-20,
taken over two alternatives: keeping חד"ש-תע"ל's −3 / −2 / NULL (which is what the *Renaming*
warning above had anticipated), or NULLing the two axes where the components differ.

- **economic −3** — unchanged from חד"ש-תע"ל. חד"ש self-defines as communist; בל"ד's −2 was
  social-democratic, and was held apart from −3 precisely to keep the two lists distinguishable to a
  voter choosing between them. That distinction no longer exists to preserve, and חד"ש chairs the
  list.
- **security −3** — up from חד"ש-תע"ל's −2, carried from בל"ד: complete withdrawal from the
  post-1967 territories, a Palestinian state with East Jerusalem as its capital, right of return
  under UNGA 194, dismantling the settlements, opposition to Druze conscription and to national
  service for Arab citizens. It is already the pole of the axis.
- **religiosity −3** — carried from בל"ד, the only component that has published on religion and
  state at all: "complete separation of religion from the state", freedom of worship for all
  religions, and state symbols grounded in constitutional egalitarian principles rather than
  sectarian ones. חד"ש is **silent** on the question, not opposed — which is why its own row is NULL
  rather than a number contradicting this one. That NULL survives on the frozen `previous_parties`
  row and in `RELIGIOSITY_NULL_BY_DESIGN`; read the note beside it before "fixing" the apparent
  inconsistency.

**The cost of the union rule, recorded rather than hidden: the list has published no joint
platform.** Every number above is carried from a component's text, and security and religiosity rest
on בל"ד's programme alone — dated 2018-09-11 and unchanged, which is what the dropped
`program-unchanged-since-2018` tag used to record. ביחד's `security` NULL is the precedent that
argues the other way, and it was decided differently here on purpose: ביחד's components *disagree*
on the conflict, whereas חד"ש and בל"ד differ only in degree, with direction not in dispute.
**Revisit all three axes the moment the list publishes jointly.**

**Two tags were dropped rather than carried.** `pro-joint-list` recorded ג'בארין's goal of
rebuilding the list — a list tagged with wanting to form itself records nothing — and
`program-unchanged-since-2018` is a note about the age of בל"ד's evidence that would now read as a
claim that the joint list itself has a 2018 programme. The remaining 15 tags are the union of both
rows, deduped. `families` is likewise the union (`arab-representation`, `jewish-arab-partnership`,
`welfare-state`), and `family_evidence` stays `record` — there is no joint platform to read.

**Logo**: the 2019 Joint List mark, pure black artwork on transparency, in `PLATE_PARTIES` — shown
unchanged on a near-white plate in dark mode, like ש"ס. See "The logo that could not be recoloured"
under Logos; it took three attempts and the first two were both verified clean by automation while
still looking wrong on the actual site.

### ש"ס — Shas · `bibi` · −2 / 1 / 2 · haredi

**Neither this row nor יהדות התורה has a platform, and that is a finding, not a failed search.**
`shas.org.il` is not merely blocked, it is **unreachable** — `curl` times out and WebFetch returns
`ECONNREFUSED 185.151.196.220:443`, two independent fetchers agreeing, and the Internet Archive's
closest snapshot to 2026 is dated **2022-11-01**, the week of the previous election. `degel.org.il`
resets the connection; `agudatisrael.org.il`, `yahadut-hatorah.org.il` and `shasnet.co.il` do not
resolve at all. This is the opposite of the כחול לבן case in `services/backend/CLAUDE.md`, where a
403 was mistaken for absence: here the block was tested and there is nothing behind it. So the
corpus for both rows is **campaign speech, rabbinic instruction, and the voting record** — and,
uniquely on this page, the record is by far the larger half. Both rows are `record`, and were
already.

**This entry and יהדות התורה's were one merged four-line block until revision 34, scoring both
parties identically on every column with only `religiosity` argued.** That is precisely the collapse
the "axis records direction, tag records motive" convention exists to prevent. No axis moved in the
split — all four numbers turn out to be right — but each is now carried by evidence rather than by
assertion, and the two rows no longer claim to be the same party.

`religiosity` **+2**: communal autonomy and state funding, plus defence of the marriage, kashrut and
Shabbat monopolies — but **not** a programme to derive state law from halakha, which is what
separates them from +3. The 25th Knesset supplies the first hard test this score has ever had, and
it lands on the +2 side of the line twice. **חוק שיפוט בתי דין דתיים (בוררות), תשפ"ו-2026** —
sponsored by MKs Moshe Gafni and Yaakov Asher (יהדות התורה) together with **Yinon Azoulay (ש"ס)**,
passed second and third reading in the early hours of Tuesday **24 March 2026, 65–41** — lets
rabbinical and sharia courts sit as arbitrators in defined civil matters and, under §3(a),
**"רשאי בית הדין לדון ולפסוק בהתאם לדין הדתי שהוא דן לפיו"** — rule according to the religious law
they apply. It reverses בג"ץ 8638/03 אמיר, restoring a practice the High Court had ended two decades
earlier. That is a parallel jurisdiction, not a halakhic state: §2(a)(1) requires every party to sign
an arbitration form, and the statute excludes criminal, administrative, spousal, state-party,
most labour and disciplinary matters, and carves out substantive rights under חוק שיווי זכויות
האישה 1951, protective labour law, disability rights and חוק החוזים האחידים. **The citizen who does
not sign is untouched** — which is exactly the Zehut distinction at the head of that block (a subsection of
הציונות הדתית since the 2026-09-01 merge), and it is
why this legislating party sits at the same +2 as the party that only proposed it.
The second test is **חוק החמץ**, an amendment to the Patient's Rights Law empowering a hospital
director to restrict chametz on Passover, passed **48–43**: religious restriction extended into a
state institution, with no claim on the law of the state.

`economic` **−2**: social-democratic, and this is the one row on the page where the number is
carried by a ministry rather than a manifesto. Shas held **Welfare (Margi), Labour (Ben-Tzur),
Interior (Arbel) and Health (Buso)** until July 2025, and its flagship social programme is the food
voucher: **₪300m earmarked in the 2025 coalition funds, ₪277m after across-the-board cuts**, with
the High Court moving distribution from Interior to Welfare on "professional and equal criteria" and
striking the arnona-discount test. **The criteria the Shas-run Welfare Ministry then wrote use a
per-capita income test *without* a מיצוי כושר השתכרות — an exhaustion-of-earning-capacity test**
(Calcalist, 27 November 2025), which is the mechanism by which a household whose
father learns full-time rather than works stays eligible. **That is the whole shape of this row's
economics in one clause**: a genuinely redistributive instrument, means-tested in universal language,
with the one test that would exclude the sector deliberately left out. The number stays −2 because
the spending is real and the form is universal; `sectoral-budgeting` in the families and
`mizrahi-representation` in the tags carry what the number cannot.

`security` **+1** — "no Palestinian state, but explicitly refusing territorial expansion" — and this
row is the reason that band exists separately from +2. Shas carries **no** `pro-settlement`,
`sovereignty-annexation` or `hardline-on-gaza` tag and has never asked for one. The positive
evidence is the hostage deals, which both Haredi factions **supported** while הציונות הדתית, עוצמה
יהודית and נעם hold `opposes-hostage-deals`: Deri framed the January 2025 agreement as the mitzvah
of **פדיון שבויים** and called it *"הישג גדול"*. **`supports-hostage-deals` was considered as a tag
and rejected** — nearly every party outside the far right supports them, so it would discriminate
nothing; the finding belongs in the axis, where it is what keeps this row off +2.

`bloc` **bibi — kept, and settled by the repo owner on 2026-08-30 (~99% that UTJ goes with
Netanyahu). The evidence stays written out here anyway, because a settled cell that shows its
working is worth more than a confident one that does not.** Against it: Shas
resigned seven ministerial and deputy posts on 16 July 2025 over the stalled exemption law; both
Haredi parties voted to dissolve the Knesset, and it dissolved on 17 July 2026; Rabbi Dov Lando's
*"אין לנו אמון בו"* (~12 May 2026) has never been retracted; and Netanyahu was reduced to **asking**
the Haredi parties to commit to a coalition under him after the election. For it: **Shas stayed in
the coalition when it gave up the ministries**, and its stated condition is about a *law*, not a
person — *"לא ניכנס לקואליציה ולממשלה בלי שנסדיר את מעמדם של לומדי התורה"* (Deri, campaign launch,
Holon, 20 August 2026). No source obtained states a preference for any alternative, and ביחד
publicly refuses them (Bennett, 9 August 2026: *"מי שבאמת רוצה לגייס חרדים... צריך להשאיר את מחוללי
ההשתמטות, דרעי וגפני, מחוץ לממשלה"*). **A bloc value is a positive claim in the same way a `0` on an
axis is** — `unaligned` would assert an availability nobody has stated. The question is **closed**
in Open questions; the trigger that would reopen it is a *positive* signal (a recommendation to
someone other than Netanyahu, or a stated willingness to sit under him not leading), never more
distance. Note the asymmetry with יהדות התורה below: **Gafni said the sentence Deri has not.**

Six tags added, **2 → 8**. `scholar-exemption-retained` is the correction that most needed making:
it sat on הליכוד, כחול לבן, המפלגה הכלכלית and בית ציוני — four parties that merely tolerate the
yeshiva exemption — and on neither of the two organised around it. `rabbinic-authority-led` moves
from a נעם singleton to its paradigm case: the reported 20 August 2026 Deri–Rabbi Yitzhak Yosef
agreement makes **Yosef and the מועצת חכמי התורה partners in the party's political decisions**
(Yosef did *not* receive the formal council presidency, at Deri's insistence).
`jewish-law-parallel-jurisdiction` is earned by the arbitration law above.
`opposes-core-curriculum` is new, the mirror of `core-curriculum`'s seven holders, and rested on
the funding architecture rather than on rhetoric until the 2026-09-03 interview below supplied the
rhetoric too: exempt institutions teach **55%** core and are funded
at 55%, and the government decision of 25 December 2025 setting up a ministerial team on Haredi
education budgets provides for introducing גפ"ן into Haredi schools **"ללא תלות בלימודי ליבה או
מחויבות ללימודי חול"** — without dependence on core studies or any commitment to secular studies.
Shas MK **Yosef Tayeb**, chairing the Education Committee, additionally proposed requiring a special
committee's approval before a school could move from "recognised but unofficial" to state education,
withdrawing it only after publication. `mizrahi-representation` is a deliberate singleton on the
model of `negev-bedouin-representation`: `sector: haredi` is true of both rows and is exactly what
made them look identical. `judicial-overhaul` is from the record and the arithmetic is conclusive —
the reasonableness repeal passed **64–0 on 24 July 2023 with the opposition boycotting**, and 64 was
the whole coalition, so all eleven Shas MKs voted for it. It is reinforced by two 2026 statutes aimed
squarely at High Court rulings: **Basic Law: Torah Study** (House Committee 6–4 on 9 July 2026,
plenary **63–52** on 13 July 2026, Netanyahu absent) and the law freezing arrests of Haredi draft
evaders (**58–54**, and **frozen by a High Court interim order** before it took effect).

`judicial-restraint` added to the families, **3 → 4**, on the same record.

**The 2026-09-03 קול ברמה interview supplies in Deri's own voice what two of this row's tags were
carried by inference — and moves nothing.** Six independently fetched outlets on one radio interview
(N12, i24, מעריב, כיפה, ערוץ 14, וואלה — 3 September 2026), which is the largest same-event
corpus this row has; the axes are unchanged and `seed.sql` is untouched. What it changes is the
basis:

- **`opposes-core-curriculum` now rests on rhetoric as well as on the funding architecture**, and
  the paragraph above saying it does not is amended rather than deleted — it was accurate when
  written. Deri on the חינוך הממלכתי חרדי (ממ"ח) framework: *"יש רצון לסגור את הרשתות של החינוך של
  הציבור החרדי כדי להפוך את זה לממ"ח, כדי להחטיא ולגדל פה דור של ילדים שלא שומעים לגדולי ישראל"*,
  with the objection stated as a slippery slope about supervision rather than about money —
  *"היום נותנים לך את מה שאתה רוצה, מחר בבוקר יבוא מפקח של משרד החינוך ולאט לאט יכתיבו לך את תוכנית
  הלימודים, מה ילמדו, מה האידיאולוגיה"* — and to the teachers themselves, *"תהיו גיבורים, זו מלחמת
  קודש, אתם שליחים של מר"ן"*. He also concedes the delivery failure in the same breath
  (*"לא הצלחנו להביא את מה שהבטחנו לכם, למרות שהכנסנו את זה לתקציב"*), which belongs with the
  promise-versus-delivery finding below rather than against it.
- **`opposes-state-haredi-education` was considered as a new tag and refused**, even though ממ"ח is
  the exact mirror of `state-haredi-education`'s five holders. Deri collapses the two himself in the
  same answer — asked what changes when a Hasidic institution moves to ממ"ח with the same teachers,
  he answers *"זה נהיה פתאום לימודי ליבה"* — so the mechanism the tag would name is the one
  `opposes-core-curriculum` already names, and it would enter the vocabulary as a singleton. **It is
  specifically not extended to יהדות התורה on this evidence**: Deri says *"גדולי ישראל נלחמים בכל
  כוחם נגד הממ"ח"*, but attributing a position to the other row from this row's leader is the
  classify-from-the-party's-own-sources rule stated under בית ציוני, and that row's own material
  already earns the tag independently.
- **`rabbinic-authority-led` gets its cleanest statement**: *"כשהרבנים יחליטו, אחרי שיסדירו את
  מעמדם של לומדי התורה, הם גם יחליטו"*, with the service tracks explicitly not his call.
- **The conscription material goes further than `scholar-exemption-retained` and still earns no new
  tag.** Asked whether he would call a haredi who is *not* learning to enlist, Deri answered
  *"אני לא צריך לקרוא לזה"* and put it on the army — *"הצבא שיודע להפציץ באיראן... שיתמודד. הצבא לא
  רוצה חיילים חרדים... הוא רוצה צבא חילוני, הוא לא רוצה צבא ששומעים לרבנים שלהם"* — plus
  *"כל השנים זה היה אחיזת עיניים גדולה מאוד"* on the integration programmes, *"אין מסלולים חרדיים
  אמיתיים"*, and *"אני לא בדקתי את זה"* when asked about חטיבת החשמונאים, the unit built for exactly
  that. That is a refusal to endorse enlistment for the non-learners the scholar exemption does not
  cover, which is broader than the tag's name — but the `conscription-exemption` **family** is
  already the row's, and a tag splitting learners from non-learners would have this row as its only
  holder. Recorded here instead, which is what the entry text is for.
- **The `religiosity` +2 does not move on any of it.** Both halves are the +2 band verbatim —
  communal autonomy, sectoral funding and the yeshiva exemption — and neither is a claim on the law
  of the state; +3 needs a halakhic-state programme, and refusing the state's inspector inside your
  own schools is the opposite claim.
- **Three party leaders responded by excluding Deri from a future government and the `bloc` stays
  `bibi` and stays closed**, for the reason already given: exclusion by others is not a positive
  signal from this row. בנט (*"אריה דרעי לא יכול לשבת בעוד ממשלה אחת בישראל... לא יישב בקבינט"*),
  איזנקוט (*"אריה, זה נגמר. הפעם אתה תתמודד"*) and ליברמן (*"מעודד ההשתמטות מספר 1 בישראל"*) join
  ביחד's August refusal recorded above. The reopening trigger is unchanged and none of this is it.

**What the record does not support, and it is the headline of this pass.** Four years of maximal
leverage produced **no exemption statute**. What it produced instead: a Basic Law cut down to a
single declarative clause; an arrest-freeze law the High Court froze; and an enforcement vacuum —
**79,000+ conscription orders issued since the 2024 ruling against ~2,100 enlistments, and 17
proactive arrests in the twelve months to January 2026**, against ~32,000 men the IDF classifies as
evaders. The threats were real and mostly not executed: in January 2026 Shas's spokesman said the
party would not vote for the budget without **prior passage** of the conscription law, and eleven
days later Kan reported the climbdown; the budget passed on 29 January 2026 with Haredi consent.
Where the record *is* one of delivery is money — see the education figures under יהדות התורה, which
both parties collected jointly.

### יהדות התורה — United Torah Judaism · `bibi` · −2 / 1 / 2 · haredi

Same four numbers as ש"ס and, until revision 34, the same two tags and the same merged entry. The
axes genuinely do coincide; **almost nothing else does**, and the differences are what this entry is
for. The preamble under ש"ס on the absence of a platform applies here in a stronger form: this row
has never had a website at all.

`religiosity` **+2**, `security` **+1** and `bloc` **bibi** carry the reasoning given under ש"ס —
the arbitration law is **Gafni's and Yaakov Asher's** bill before it is Azoulay's, and on the
hostages Gafni's own formulation was *"החזרת החטופים היא הדבר החשוב ביותר, והיא צריכה להיעשות בכל
מחיר, בכל צורה ובכל דרך"*.

**`bloc` bibi is weaker here than on ש"ס, and it is kept anyway.** On 9 August 2026 Gafni said, on
the record, *"בניגוד לפעמים קודמות, הפעם אני לא עונה מראש שאני הולך עם נתניהו"* — "unlike previous
times, this time I am not answering in advance that I am going with Netanyahu" (Ynet, Ettinger and
Azoulay) — after years in which דגל התורה was treated as a fixed part of the Netanyahu bloc. That is
the single strongest bloc signal any Haredi party has given, and it is still **a refusal to
pre-commit, not a statement of availability**: Ynet frames it as part of a mutual pre-election
display of distance between Likud and the Haredi parties, ביחד publicly excludes them, and Gafni
chairs **דגל התורה**, one of the two factions this row is made of, not the list. `unaligned` would
convert a bargaining posture into a bloc position — and a bargaining posture is the **normal** state
of this relationship, not a departure from it, which is the same baseline error revision 35 records
for the faction split. Closed in Open questions.

`economic` **−2 is the weakest number on this page and is knowingly retained.** Under ש"ס the score
is carried by four ministries and a named programme; here there is no general economic doctrine on
record at all. What exists is allocation: Gafni chaired the **Finance Committee** for most of the
term — Globes' assessment when he resigned it (~15 July 2025) was that he would remain its strongest
figure regardless — and the party's economic footprint is sectoral transfer rather than any position
on markets, tax or the welfare floor. It stays −2 because moving it needs positive evidence in the
other direction and there is none, and because `welfare-state` and `sectoral-budgeting` in the
families already carry the shape. **Move condition:** any published UTJ position on taxation, the
welfare floor or market structure that is not a sectoral allocation.

**Where the money actually landed, for both rows.** The 2026 budget carried **~₪2.4bn of sectoral
Education Ministry budgets for יהדות התורה and ש"ס**, approved by the Finance Committee on 22 March
2026 with half cleared for transfer and half held for ministry legal advisers. Calcalist put the
increase to the Haredi education networks at **₪942m, +32.5% on 2025, of which ~₪724m (23%) is real
growth** beyond wage, demographic and price adjustment. The friction was judicial, not political: a
High Court interim order (Justice Vilner) froze the Finance Committee's 25 December 2025 decision to
move ~₪1.1bn, and the state's own reply indicated **only ₪82m of it had not already been paid** —
Haredi politicians called the freeze *"הכרזת מלחמה"*. **This is the answer to promise-versus-delivery
that the conscription story hides:** the parties failed completely on the exemption statute and
succeeded almost completely on the budget.

Six tags added, **2 → 8**: `scholar-exemption-retained`, `rabbinic-authority-led`,
`jewish-law-parallel-jurisdiction`, `opposes-core-curriculum` and `judicial-overhaul` for the reasons
given under ש"ס, plus **`two-faction-list`**, a new singleton recording this row's permanent
structure: since its founding in **1992** יהדות התורה has been a **joint list of two independent
parties** — אגודת ישראל (Hasidic) and דגל התורה (Lithuanian) — which "מתפקדות בכנסת בסיעה משותפת, אך
כמפלגות עצמאיות" and hold **separate מועצות גדולי תורה that rarely convene together**. The tag names
the standing arrangement, not any one rupture. `mizrahi-representation` is deliberately **not** here
— this row is Ashkenazi, Lithuanian and Hasidic, and the tag is the main thing distinguishing the two
sectors that `sector: haredi` flattens.

**The 16 July 2026 split into two Knesset factions is the end-of-term ritual, not news, and revision
34 got this wrong.** That entry presented it as a 2026 event and built an open question on it. The
base rate refutes that: **the faction has split into its components at the end of every Knesset term
up to the 25th except the 15th, 18th and 19th, joint-run negotiations have reopened each time, and
every single time they have succeeded and the two parties have run again on one list** (he.wikipedia,
`יהדות התורה`, read 2026-08-30). Splits have occurred mid-term too — Ravitz filed the separation
request in January 2005 when Litzman took the Finance Committee chair against Rav Elyashiv's
instruction to keep דגל התורה in opposition. Maklev's *"הפירוד הוא טכני… אנחנו לא מתגרשים אלא
מתחדשים ונפרדים לתקופה"* is therefore an accurate description of a recurring procedure, and reading
it as a hedge about a possible breakup inverts it. **The lesson is the one this page keeps
relearning: a fact can be verified, correctly dated, correctly quoted and still wrong, because the
error is in the baseline it is read against.** Every source in revision 34's corpus was reporting a
routine event as though it were a development, and the research pass's own corroborating line — "UTJ
has split at the end of most Knesset terms since the 13th and reunited each time" — was present and
under-weighted.

`judicial-restraint` added to the families, **3 → 4**, on the record shared with ש"ס.

**`conscription-split` in the families is confirmed, and the structure above is *why* it is the
right value.** The families design justified it on דגל התורה and אגודת ישראל voting opposite ways on
the draft bill. That is not a party failing to hold a line — it is **two independent parties with two
separate councils, each holding its own line**, appearing on one ballot slip. The positions are not
converging either: Goldknopf (אגודת ישראל) demanded in January 2026 that **all
sanctions be abolished** — *"if there are those who study Torah, exempt them from everything. They
should not be tied to quotas or targets"*, with a "yellow star" comparison that drew rebukes from
Lapid, Smotrich and Bismuth alike — while ש"ס's spokesman was arguing in the same week that *"the
only thing that will stop the arrests is not demonstrations, but legislation"* and Deri was trying to
prevent the Bnei Brak rally. **ש"ס is `conscription-exemption` and this row is `conscription-split`,
and the difference is real: one party has a line, the other has two.**

**The operative decision-maker is not the faction.** Rabbi Dov Lando — rosh yeshiva of Slabodka and
head of דגל התורה's council, **not an MK**, a styling JPost got wrong — wrote *"אין לנו אמון בו"* of
Netanyahu around 12 May 2026 and on 24–25 May instructed UTJ lawmakers to stop cooperating with the
coalition's draft bill, which is what ended the legislative track. The instruction is attributable to
Lando personally, not to the מועצת גדולי התורה as a body. `rabbinic-authority-led` is the tag for it.

---

## Previous parties

These describe each party **as it stood at the previous election** and are frozen. Most carry the
same reasoning as their upcoming counterpart at an earlier stage; only the differences are noted.

- **הליכוד** `bibi` · 1 / 2 / 2 · traditional — economic and religiosity as above, including
  `instrumentally-clerical`. **`security` diverges from the upcoming row as of revision 24**: that row
  moved to +3 on a record built entirely after November 2022, so this one keeps +2 and its original
  four tags, per the no-back-dating convention.
- **יש עתיד** `opposition` · 0 / 0 / −2 · secular — strong separationist.
- **הציונות הדתית** `bibi` · 0 / 3 / 3 · religious_zionist — the three original tags only; neither
  the 2026 primary findings nor the `/victory/` conflict tags are back-dated here. *(This line read
  "four" until 2026-08-26. It was right when written and went stale on 2026-08-11, when the
  vocabulary sweep removed `not-economy-focused` from **both** rows — the sweep's own entry says so;
  nobody re-counted here. הליכוד's "original four" two lines above **is** still correct, which is why
  the wrong one survived a read. Verified against a seeded database, not by eye.)*
- **המחנה הממלכתי** `unaligned` · 1 / NULL / −1 · secular — security NULL with
  `avoids-security-topic`. This pairing is the reference example of "NULL means no stated position,
  and a tag says why", and `test_migration.py` asserts it directly.
- **ישראל ביתנו** `opposition` · 2 / 2 / −3 · secular.
- **ש"ס**, **יהדות התורה** `bibi` · −2 / 1 / 2 · haredi — the two original tags only. Revision
  34 split the upcoming rows and added six tags to each, all of it on 2023–2026 evidence (the
  reasonableness repeal is July 2023, the arbitration law March 2026, the faction split July
  2026); **none of it is back-dated here**, per the no-back-dating convention. These two rows
  legitimately still describe one merged position, because at the November 2022 election that is
  what the record supported.
- **רע"ם** `opposition` · 0 / NULL / NULL · arab — the security −2 above is a 2026 statement and is
  deliberately not back-dated.
- **חד"ש-תע"ל** `opposition` · −3 / −2 / NULL · arab — frozen at its 2022 run. Its upcoming
  successor merged into הרשימה המשותפת on 2026-08-20 and is scored −3 / −3 / −3; this row is
  deliberately **not** back-dated to match, and its religiosity NULL is the one asserted by
  `RELIGIOSITY_NULL_BY_DESIGN`.
- **העבודה**, **מרצ** `opposition` · −2 / −1 / −2 · secular — both link to הדמוקרטים via
  `party_lineage`.
- **בל"ד** `opposition` · −2 / −3 / −3 · arab — religiosity populated, see הרשימה המשותפת above;
  this row is frozen at its 2022 run and keeps economic −2, which the merged row does not.

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

### Four logos are self-hosted under `/logos/`, and none is a matter of taste

`services/frontend/logos/` is copied into the frontend image as a whole directory, so adding a file
there is a data change. All four party logos that live there had to leave Wikimedia/CDN hosting:

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
- **עמך ישראל** (`amcha-yisrael.png`) — the party is days old and has no artwork anywhere but inside a
  **Ynet news photo**, served through a `cdn-cgi/image` transform URL. Those rewrite and expire, and
  a news CDN is the same hotlinking exposure as `*.fbcdn.net` above. The file is the mark keyed out
  of that JPEG and self-hosted. **How the background was removed matters, because two obvious methods
  both fail here and fail invisibly on the light card**: keying on HSL *saturation* is degenerate on
  a near-white ground — measured, the empty gap between the two glyph lines reads **55% saturation,
  higher than the blue stroke itself**, because tiny chroma at L≈0.98 computes as huge S — and keying
  on darkness picks up the JPEG's ringing as a grey halo. Both produce a file that looks perfect on
  white and shows a blocky halo only once the dark card is behind it. What works is measuring the
  ground (a uniform neutral **#F2F2F2**, from the four corners) and **unpremultiplying** it:
  `alpha = 1 - min(R,G,B)/bg`, floored at 0.10 to drop the compression noise, with the colour
  unpremultiplied back out. Background then sits at α≈0.02 and ink at α≈0.72–0.81, a gap wide enough
  to threshold safely. Kept **lossless** (`oxipng`, never `pngquant`): the mark's two rules fade to
  transparent, and quantising 35,490 colours to 256 is the og-card banding failure. It takes the
  normal dark-mode recolour — blue and purple both sit below the 0.5 luminance threshold and lift to
  lighter versions of the same hue, so the two-tone survives; it needs no entry in
  `SKIP_RECOLOR_PARTIES`.

Both were verified by rendering the real `logos.js` and `style.css` in headless Chromium over HTTP
in both themes, not by inspecting the files. Both use `oxipng` lossless and **not** `pngquant` —
the blue in each is faceted and bands.
- **נעם** (`noam.png`) — **the only one of the four that is here because its source disappeared**,
  not because the source was unusable. The row pointed at a Wikimedia file that now returns **404**;
  the replacement the repo owner supplied is a 1600×1600 dark-navy tile whose wordmark occupies 13%
  of the square, so it is cropped to the measured text block (900×296, 3.04:1) and self-hosted
  because a cropped file is no longer the file at the URL. Shown **unchanged in both themes** — see
  the נעם note below for why the recolour's own solid-tile guard already handles it and why no
  `SKIP_RECOLOR_PARTIES` entry belongs there.


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

**זהות's logo is dark artwork and needs no special handling — verified, not assumed.** *(Kept as
the reference case for נעם below; זהות itself stopped being a row on 2026-09-01 and the merged
הציונות הדתית row keeps its own self-hosted logo.)* The Wikimedia
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

~~**נעם's logo is the same case as זהות's**~~ — **that artwork is gone.** The Wikimedia file the
row pointed at (`/commons/6/6e/…_j%2Cul.jpg`) now returns **404**, so the description below it is
kept only as the record of what used to be there: a `#003369` navy wordmark between two `#00b2ef`
cyan bars, 45.3% perceptually-dark pixels, lifted to `#a7d2ff` by `recolorLogoForDark()`. None of
that applies to the replacement, and reasoning from it would be wrong in every particular.

The replacement (2026-09-02, supplied by the repo owner) is
`/wikipedia/he/e/e8/סמל_מפלגת_נעם.jpeg`, self-hosted as `noam.png` — see the self-hosted section
above. It is the **opposite kind of artwork**: a 1600×1600 dark-navy **tile** carrying a
light wordmark (white לישראל, cyan נעם) over a faint Star-of-David gradient, with a
בראשות אבי מעוז sub-line. Where the old file was dark ink needing to be lifted, this one is already
light-on-dark and must not be touched at all.

**It needs no `logos.js` change, and specifically no `SKIP_RECOLOR_PARTIES` entry — verified, not
assumed.** `recolorLogoForDark()`'s own first gate returns `null` for it: the file is fully opaque,
so `opaque / total` measures **1.0000** against a `> 0.9` threshold, and the function bails at its
"solid-tile logo -- leave as-is" line before touching a pixel. Simulating that gate on the actual
cropped file is what established this; an entry in `SKIP_RECOLOR_PARTIES` would be dead weight
asserting a rule the code already applies.

**The same guard, the opposite outcome — and the tile's colour is the whole difference.**
הציונות הדתית's published PNG trips this identical `> 0.9` check and that is precisely why it could
not be used: its baked-in background is **white**, so the untouched tile renders as a white plate on
the dark cards. נעם's tile is `#1B3A5C`-ish navy against a `#161B22` card, so the same bail-out
yields the correct result on both grounds. Do not read "the solid-tile guard fires" as either good
or bad news on its own — it means *the artwork is shown as drawn*, which is right only when the
artwork was drawn for a ground close to the card's.

**Cropped, at the repo owner's request, because the wordmark was 13% of a square.** The band the
text occupies was measured, not eyeballed — bright-pixel rows fall in three groups (main wordmark
666–877, the rule 893–904, the sub-line 946–992) across columns 288–1395. Cropping to that block
with 28px of padding and scaling to 900px wide gives **900×296, aspect 3.04:1**, which puts the
wordmark at ~59% of the tile's height instead of 13%. That aspect is deliberate: ביחד's file is
3.11:1 and `.logo-wide` is the shape this grid already fits by width. **No `PADDED_CRESTS` entry** —
that factor corrects transparent artwork that fails to span its own canvas, and a tile spans its
canvas by definition.

**PNG, and losslessly optimised only (`oxipng`, never `pngquant`).** The background is a gradient,
which is the `og-card.png` trap: `pngquant` bands a gradient visibly. At 130KB it is the largest file in
`logos/` — just above `uefa-nations-league.svg`'s 117KB — which is accepted because it is fetched
once and the alternative is a lossy gradient.

**Do not add it to `OUTLINE_CLUBS`**, for the reason given above.

**Do not hotlink social-media CDNs.** Those URLs are signed and expire, the CDN may refuse hotlinks,
and — the one that actually bit, on F.C. Kiryat Yam — tracker blockers drop `*.fbcdn.net` in the
browser, so the crest is invisible to many visitors while `curl` fetches it happily. That class of
bug is undetectable server-side. Check a candidate URL by loading it **in a real browser from the
app's own origin**, not just with `curl`: the fbcdn crest passed curl and failed in-browser.

### The logo that could not be recoloured

`הרשימה המשותפת` is the row that broke the recolour pipeline's assumptions, and the lesson is about
**verification**, not about logos.

The 2019 Joint List mark is a two-line Arabic/Hebrew wordmark in pure black on transparency —
textbook input for `recolorLogoForDark()`. It took three attempts:

1. **Plain recolour** (shipped 2026-08-20). Every ink pixel measured as lifted to white. Reported as
   verified. The repo owner saw black dots.
2. **Recolour composed with the Shas flood fill** (`FILL_COUNTERS_PARTIES`, same day). Diagnosed as
   the five enclosed bowls of ة and م on the Arabic line, showing the dark card through. Measured
   again — 316 pixels moved from card-dark to light, in Chromium, against the live page. Reported as
   verified. The repo owner saw black dots.
3. **Near-white plate, artwork unchanged** (`PLATE_PARTIES`) — what ships.

**Both failed verifications were real measurements of the wrong thing.** The first measured the
400px canvas, where the Hebrew letters' gaps are open channels that register as clean; the browser
scales that canvas to roughly 156px, where they close into marks. The second fixed the enclosed
subset and measured the enclosed subset. Only a screenshot from the owner's own browser showed what
was actually happening: **the recoloured canvas comes back speckled with black dots through the
glyph bodies**, dense and scattered, nothing to do with counters or letterform gaps. The source SVG
renders clean at every size (48 unique colours in a magnified crop), and the live canvas read back
from headless Chromium contains **zero** pixels darker than the card. It is a rasterisation artefact
of that browser, and no amount of measuring from here can reproduce it.

So the plate is not a tuning of the recolour, it is a refusal to depend on it: no canvas, no
`getImageData`, no `crossOrigin`, no per-logo pixel thresholds. The browser renders the original SVG
on a light ground, so dark mode reproduces exactly what light mode already shows.

**This reopens the no-plate rule for parties** (parties recolour, clubs get an outline), decided when
the logo chips were designed. The repo owner chose it on 2026-08-20 after seeing all three options
rendered at true display size, because no recolour-based option could be made to look right on their
machine. ש"ס already reads as a white tablet, so the plate is not a new visual language — but it is a
second party that no longer follows the recolour rule, and a third would mean the rule is the
exception.

The transferable rule: **when a visual fix cannot be confirmed from the machine that renders it for
the user, stop measuring and change the mechanism.** Two rounds of increasingly precise measurement
bought nothing here, because the defect was never in the pixels being measured.

---

## Open questions

- ~~**Will יהדות התורה be on the ballot as one list?**~~ — **closed the day it was opened,
  2026-08-30, and it should never have been opened.** Revision 34 read the 16 July 2026 faction
  split as a live risk to this row's existence. It is the end-of-term ritual: the faction has split
  into its components at the end of **every** Knesset term up to the 25th except the 15th, 18th and
  19th, and **every single time** the reopened joint-run negotiation has succeeded and the two
  parties have run again on one list. The prior is a joint run, and the Kikar HaShabbat briefing
  about דגל weighing an independent run is what that negotiation looks like from the outside every
  cycle. **`two-faction-list` now records the standing structure rather than a 2026 event** — see
  that entry, which also carries the method lesson, since the failure was not a bad source but a
  missing baseline.
- ~~**Will either Haredi row leave `bibi`?**~~ — **closed 2026-08-30 by the repo owner:**
  `bibi` stays on both, on the judgement that UTJ going with Netanyahu is a ~99% call. Revision 34
  had already kept it while calling it the page's most contestable cell; the owner's read removes
  the contest, not the evidence, and the evidence both ways stays written out under ש"ס so a future
  reader can see what was weighed. Gafni's 9 August 2026 *"הפעם אני לא עונה מראש שאני הולך עם
  נתניהו"* is a refusal to pre-commit — a bargaining posture in a coalition negotiation, which is
  the normal state of this relationship rather than a signal of realignment. **If it ever does move,
  the trigger is a positive one**: a post-election recommendation to a candidate other than
  Netanyahu, or a stated willingness to sit in a coalition he does not lead. Neither Lando's *"אין
  לנו אמון בו"* (about trust in a person) nor the dissolution vote (about a law) is that.
- **What is the live status of the Bismuth (ביסמוט) exemption bill, and does ש"ס actually back
  it?** The January 2026 coalition text is documented; the August 2026 one is not. Deri is
  reported to accept flexible sanctions while Rabbi Yitzhak Yosef — newly a partner in the
  party's political decisions — is reported to reject any conscription clause at all. That is an
  unresolved split *inside* the row this pass scored as having a line, and it is the one thing
  that would put `conscription-split` on ש"ס too.
- ~~**The Arab bloc may restructure.**~~ — **resolved 2026-08-20.** חד"ש, תע"ל and בל"ד signed a
  joint-run agreement and the two upcoming rows merged into `הרשימה המשותפת`; the commented-out
  `seed.sql` insert this item pointed at was deleted, because the row is real now. **The prediction
  in it was wrong in a way worth keeping**: it said the affected rows would need "renaming, not
  reclassifying", and both halves turned out false — two rows merging into one is not a rename, and
  the union scoring moved two axes (security −2 → −3, religiosity NULL → −3). Anticipating a
  restructure is not the same as anticipating its shape. **Still open in a narrower form:** רע"ם
  declined to join and runs alone, with the door left open until the September list-submission
  deadline — if it joins, this row changes again.
- **ביחד's `security`** is the only NULL axis on a Jewish *upcoming* party (המחנה הממלכתי carries a
  NULL security among the frozen previous rows, for the same "no stated position" reason). It
  resolves only if the components merge or publish a joint position — or splits into two rows if the
  list dissolves. **Re-verified 2026-08-01: still no joint platform**, and the dissolution watch is
  still live, so the split branch is the likelier one.
  **Sharpened 2026-08-17 (revision 22), and the finding cuts the other way from how it reads.** The
  list *does* publish jointly — four plans on `be-yahad.org.il/plans/`, under the list's own brand.
  Security is **not one of them**. So this is no longer "no joint platform exists"; it is a list that
  publishes joint policy on cost of living, education and the servants law and **declines to publish
  on the conflict** — which is exactly what an unresolvable internal contradiction looks like from
  the outside. The NULL is stronger for it, not weaker. Re-check `/plans/` for a security page as the
  resolution trigger, rather than waiting for a full joint platform that may never come.
  **Trigger fired once with no result, 2026-08-26 (revision 29):** two new plans (aging, women's
  status), corpus 4 → 6, neither of them security. The women's plan **does** discuss the IDF —
  expanding women's combat roles and a body for reservists' families — so the list now publishes on
  the army while still publishing nothing on the conflict, the territories or statehood. Declining
  the subject next to a document that touches the military is stronger than silence. Keep the same
  trigger, and note the index is **paginated** (`/plans/page/2/`): enumerate every page, not just
  the first.
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
- **The `religiosity −3` band criterion conflates disestablishment with anti-clericalism, and its
  trigger condition has now fired.** Revision 20 said this should be rewritten "rather than
  stretched **if a second pluralist-funding party ever arrives**" — and recorded it only in the
  change history, never here, which is why it went unactioned. Revision 21 (2026-08-16) supplied
  that second party: ישר demands civil partnership, kashrut reform and devolved Shabbat while
  *keeping* state religious funding, exactly as בית ציוני does. **Two rows now sit at −2 for the
  same reason, and it is a reason the band text does not state.** The −3 row reads "end the
  Rabbinate's monopolies outright, civil marriage, no state religious funding" as though the three
  travelled together; these two rows have the middle one, want the first devolved rather than
  ended, and reject the third outright. **Do not resolve this by moving either row** — both were
  scored consistently. Resolve it by rewriting the band so the funding criterion is explicitly the
  decisive one and civil marriage is explicitly not, which is what both revisions actually applied.
  **Third instance, 2026-08-17 (revision 22): ביחד.** This one satisfies a *different* subset again —
  it **does** end a Rabbinate monopoly outright (kashrut, *"נשבור את מונופול הרבנות"*), publishes
  nothing on marriage, and fails the funding test. Three rows at −2, three different subsets of the
  −3 band's three criteria, every one scored consistently. The band text is the defect, not any of
  the rows, and it is now the single most-cited unresolved item on this page.
  **Fourth instance, 2026-09-03 (revision 41): עמך ישראל, and it is the narrowest case yet.** This
  row clears the **−2** band on **one** of that band's own three criteria — universal conscription —
  with no core-curriculum funding condition and nothing whatever on the monopolies, because it has
  published no religion-and-state material at all. What justified the score was not the band prose
  but the vocabulary's membership: **all nine `universal-conscription` holders are at −2 or −3, none
  at NULL, 0 or −1.** So the criterion is *already* treated as sufficient in practice while the band
  is written as a bundle, and the two have now visibly diverged. **The proposed rewrite is
  disjunctive**: a row sits at −2 if it reduces the haredi sectoral settlement (conscription, or
  core-curriculum funding) **or** the religious monopolies — the funding criterion of the −3 band
  staying decisive between −2 and −3, per the three instances above. Recorded, not applied: rewriting
  the axis from one row is what revision 15 refused for tags, and the same reasoning holds here.
- **No environment/climate tag exists, and one row now clearly earns one.** המפלגה הכלכלית publishes
  a full programme (100% renewable electricity by 2050, a ₪10B climate fund, closing the Haifa Bay
  refineries, refusing to renew the Dead Sea concession, live-export ban, cage-free hens). Creating
  the tag from that single audit was refused on revision 15's reasoning — a tag born from one row's
  reading measures audit coverage, not position. **Resolution: sweep all 18 rows for environmental
  content first, then create the tag (or don't) with membership decided in one pass.** הדמוקרטים and
  ביחד are the likeliest additional holders and neither has been checked for it.
  **Partial data point, 2026-08-26:** ביחד's `/plans/` corpus is now six documents and **none of them
  is environmental**. That is not a verdict — none of the six is a document where the subject would
  appear — but it does mean this row's likely-holder status rests on nothing read so far.
  **Correction and a second data point, 2026-09-03 (revision 40):** the sentence above is wrong about
  הדמוקרטים — its *מצע סביבה* paper has been read since 2026-08-01 and is listed in that entry's
  sources; what has not happened is the *sweep*, which is a different thing, and the two were
  conflated. The row's rural paper adds more (accelerated renewable transition and storage,
  agrivoltaics with continued cultivation required, integrated national energy planning against
  *"פעילות בלתי מתואמת"*), so this is now a **second** row with a clearly qualifying programme and the
  tag still does not exist. That strengthens the case for doing the sweep, and it does not change the
  reason for refusing to create the tag from one row at a time.
- **`security 0` now has exactly one holder, יש עתיד `[p]`, and it has never been re-verified.**
  Revision 23 removed the other one after finding a full conflict platform behind it, and the band's
  explanatory note had been built on that wrong example. A `0` asserts a party has genuinely taken no
  side — it is a positive claim, and the cheapest one to leave standing by inertia because it reads
  as neutrality. **Check יש עתיד against a source before this band is cited as evidence for
  anything.** It is a `previous_parties` row, so the stakes are lower, but the same reasoning that
  caught המפלגה הכלכלית applies.
- **No press-freedom tag exists, and one row now clearly earns one.** שלמה קרעי (#22 on Likud's 2026
  list, and a riser from 25th to 13th in the raw vote) has as Communications Minister banned Al Jazeera
  and repeatedly extended it, advanced a **permanent** statutory power to ban foreign outlets deemed a
  security threat **without court oversight**, carried a cabinet decision cutting all state advertising
  and contact with הארץ, moved to privatise כאן and close its news division, and sought government
  oversight of television ratings — condemned on record by RSF, CPJ, the IFJ and the European
  Broadcasting Union. **No existing tag covers any of this**; `governance-reform` is the institutional
  tag and points the other way. Refused in revision 24 on revision 15's standing reasoning — a tag
  created from one row's audit measures reading coverage, not position. **Resolution: sweep all 18 rows
  for press-and-broadcasting content first, then create the tag (or don't) with membership decided in
  one pass.** This is the second tag now queued behind such a sweep, alongside the environment tag, and
  they should be done together.
- **No workfare tag and no labour-organization tag exist, and אל הדגל clearly earns both.** Its
  economic paper conditions income support on 20 weekly hours of work, funded training or community
  service, moves the daycare subsidy from a birth test to a work-and-service test with serving
  parents prioritised (*"מבחן תעסוקה ושירות ולא מבחן ילודה"*), and separately treats labour
  organizations as *"שותפים ולא שחקני וטו"* — limiting their direct public funding, opening them to
  competition and abolishing institutional veto over government reform. Refused in revision 25 on
  revision 15's standing reasoning. **These differ from the environment and press-freedom queue in one
  important way: a second holder is already visible without a sweep.** ישר's
  *"נבטיח שהעבודה תשתלם תמיד יותר מקצבה"* is the sentence that got `welfare-state` *rejected* for that
  row in revision 21, and הציונות הדתית's רווחה paper was described as workfare-framed in revision 17
  — so the workfare position is attested on at least three rows and is a genuine vocabulary gap rather
  than an audit artefact. **Resolution: sweep all 18 rows for welfare-conditionality and for
  labour-organization content, then decide membership in one pass.** This made **four** tags queued
  behind an 18-row sweep; the queue is now the largest single unresolved item on this page and should
  be run as one pass rather than growing by one tag per audit. **Revision 33 took it to six** — see
  the two bullets below, and note that one of them had been queued since revision 31 without ever
  being filed here.
- **No demography tag exists, and הציונות הדתית has now earned one twice.** Revision 9 read
  *"מקסימום שטח תחת ריבונות ישראלית עם מינימום אוכלוסייה ערבית"* on the sovereignty page and left it
  untagged with an explicit instruction — *"if it is ever worth a tag it should be added across
  rows… not to this row alone"* — because ישראל ביתנו's population-swap plan and אייזנקוט's
  anti-annexation case are demographic arguments pointing in three different directions. Revision 31
  found `/judaization/` and re-queued it on the same footing; revision 33 re-read the rewritten page
  and found the party affirming the word itself (**״כן. מייהדים.״**) beside an explicit
  ethnic-land-competition premise (*"קרקע שלא אנחנו מחזיקים בה – יחזיקו בה הערבים"*). The evidence
  keeps strengthening and the scope argument is untouched by it. **This bullet is the actual finding
  of revision 33 on this point**: the instruction lived in a party entry for two revisions and never
  here, which is exactly the mechanism that left the `religiosity −3` band unactioned. **Resolution:
  sweep all 18 rows for demographic-engineering content, then decide membership in one pass.**
- **No domestic-policing tag exists, and two rows earn one without a sweep being needed to find
  them.** הציונות הדתית's `/judaization/` proposes a national הוראת שעה against organised crime
  whose stated goal is *"לפרק את האוטונומיה הערבית החמושה"* — illegal weapons possession defined as
  terrorism, שב״כ deployment, administrative detention and orders, evidentiary presumptions and
  minimum sentences, *"מודל ג׳וליאני"* enforcement. עוצמה יהודית has held the national-security
  ministry for the whole period and its row records none of this. **No existing tag covers the
  internal dimension at all**: `security-hawk` is centre and centre-right by design, and
  `death-penalty-for-terrorists`, `preemptive-security-doctrine` and `jewish-supremacist` each name
  something else (a sentence, the conflict, an ideology). Every tag on both far-right rows is about
  the territories, Gaza, the judiciary or religion. **Resolution: sweep all 18 rows for internal
  security and policing content — הליכוד, ישראל ביתנו, אל הדגל and בית ציוני are the other likely
  holders and none has been checked — then decide membership in one pass.**
- ~~**זהות is the only `judicial-restraint` family member without the `judicial-overhaul` tag.**~~
  **Resolved by removal, 2026-09-01** — and it did not resolve the way the question expected. זהות
  merged into הציונות הדתית, which already carries `judicial-overhaul`, so the family's members
  (הליכוד, הציונות הדתית, עוצמה יהודית, נעם) now carry it unanimously and the gap closed without
  anyone reading the platform against the membership test. The reading is still owed if the technical
  bloc splits and a זהות row is restored; the faction entry under הציונות הדתית is where it starts.
- **הליכוד's 2026 list was not certified when revision 24 read it.** The 21–23 ordering
  (קרעי/ביסמוט/ביטן versus the reverse) and the 16–17 ordering are disputed between counts, and the
  exact set of Netanyahu's reserved slots is reported inconsistently (eight, at 3/5/9/11/15/18/26/29,
  is the best-supported version). **None of it changes a tag** — every tag rests on a candidate's
  record, not on their precise slot — but the realized list quoted in that entry should be reconciled
  against the certified filing, and the "eight reserved slots" claim confirmed, once it exists.
- **The vocabulary has no tag for Arab, Druze and Bedouin land-use planning, and one may be earned.**
  הדמוקרטים's חברה ערבית paper (2026-08-31) demands statutory master plans for those localities and
  *"נבטל את חוק קמיניץ"* — a named statute, not a sentiment, which is the opposite of the
  near-universal rhetoric that got `periphery-development` retired in revision 19. It was **not**
  created on that row alone, because הרשימה המשותפת and רע"ם almost certainly hold the same position
  and revision 19's rule is to read the content first and decide membership in one pass. The trigger
  is a pass over the two Arab-list rows' own platforms; if both carry it, a three-holder tag spanning
  `opposition` and `arab-representation` records something the axes cannot.
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
document.** Checked section by section. *(Amended 2026-08-16: revision 21 supplied one for ישר —
fast rail linking periphery to centre, *"חיבור הפריפריה הוא מנוע צמיחה לאומי"*, differential
budgeting, employment centres. This **strengthens** the retirement rather than reversing it: the
deciding argument was never that the holders lacked evidence, it was that periphery development is
near-universal Israeli rhetoric and the honest end state is a tag on most of the table. A fourth
documented programme is one more data point for that, not a reason to revive a tag whose membership
had inverted.)* *(Amended 2026-09-03: revision 40 supplied a **fifth** — הדמוקרטים's dedicated
תוכנית פיתוח הצפון והדרום, a multi-year budget framework, a national administration in the PMO and at
least ₪15B added to תנופה. Same conclusion for the same reason: the count of documented programmes
rising is the retirement argument, not a case against it.)* Meanwhile this page documents periphery programmes for two
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
layer up**: at the time of the fold the `judicial-restraint` *family* covered הליכוד,
הציונות הדתית, עוצמה יהודית, זהות and נעם, so the tag was grouping nothing the family did not. Second, נעם itself now carries
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
| 2026-08-16 | revision 21 — **ישר's full principles corpus read for the first time**: nine principles papers, the 10-step brochure (2026-06-03) and the registrar-approved statement of party goals (2025-12-17). Revision 8 had scored the row from "eight principles documents"; there are eleven documents in all. **No axis moved** — economic +1, security +1 and religiosity −2 all confirmed against first-party text. **The religiosity justification was false and was deleted rather than patched**, on revision 20's precedent: it read "this platform demands no civil marriage", and `principles/aliyah-and-integration` carries a **מעמד אישי** section stating *"נפעל למיסוד זוגיות אזרחית בישראל"* plus respectful conversion and IDF-standard burial for terror victims, and a **המרחב הציבורי והשבת** section devolving Shabbat to municipalities and communities. Religion-and-state policy filed under immigration absorption — the mirror of the `homeland-security` trap already recorded for this row, where a URL invited the wrong axis; here a URL concealed the right one. Held at −2 by the funding criterion (revision 20's test): funding for religious education is kept and conditioned, *זהות יהודית-ישראלית* is mandated in the national core, the Rabbinate is not touched. **Three sentences elsewhere in this document cited ישר as the −2 party *without* civil marriage and all three were corrected** — the band table, the אל הדגל entry and the המפלגה הכלכלית entry. **A fourth correction is a factual overstatement about the party**: כחול לבן's entry said the *"תורתו אומנותו"* exemption is "the exact compromise Eisenkot refuses", but the service paper reserves *"עד 3%"* of each cohort for a **one-year Torah-study deferral** on the same footing as its athlete/scientist carve-out, with induction and basic training required of every recipient. That is a bounded deferral, not a retained exemption, so `scholar-exemption-retained` was **considered and rejected** for this row and the −1/−2 gap now rests on that distinction rather than on a refusal that was never total. **9 tags added** (18 → 27), all from the existing vocabulary: `civil-marriage`, `kashrut-liberalization`, `religious-pluralism`, `municipal-devolution`, `communitarian-devolution`, `state-haredi-education`, `arab-civil-service`, `workforce-integration`, `term-limits`. `arab-civil-service` **loses its single-holder status** (כחול לבן was alone), and `state-haredi-education` closes a gap where this entry had asserted the position in prose since revision 7 while the tag was missing. **Six candidates rejected**, each with a reason meant to outlive the row: `scholar-exemption-retained` (above), `state-commission-of-inquiry` (declined a third time, revisions 15 and 20), `periphery-development` (retired revision 19 — this corpus would have earned it, which **strengthens** the retirement; the retirement section is amended to say so rather than left asserting no holder had evidence), `anti-corruption` (near-universal rhetoric, the `periphery-development` failure mode; `governance-reform` already carries the institutional half), `gender-equality` (crime policy in a crime paper, not a dedicated equality programme as הדמוקרטים's was) and `welfare-state` (this row runs the opposite doctrine, *"העבודה תשתלם תמיד יותר מקצבה"*, restated verbatim). **security's demographic premise became first-party** — the registered goals commit to *"הבטחת רוב יהודי מוצק"* — while the inference from it (no annexation) still rests only on Eisenkot's statements, since eleven documents contain no sentence on statehood, the territories or sovereignty. Two earlier warnings re-checked and **both held**: `homeland-security` remains internal security only, and `inlocation-and-aliya`'s *"אזורי עדיפות לאומית"* still names no region; the agriculture paper adds a **third** instance of the התיישבות homograph (rural/border settlement, not the West Bank). Also logged: the aliya target is a million in a decade **and two million by 2048**, not the single figure this entry recorded, and the economics page **still contains Hebrew lorem ipsum**, so absences there are unwritten rather than positions. Revision 20's open question about the −3 band criterion was recorded only in this table and never in Open questions; it is now filed there, with its stated trigger ("a second pluralist-funding party") met by this row |
| 2026-08-17 | revision 22 — **ביחד's plans corpus read in full for the first time.** The entry cited one page (`plans/yoker`) and referred to "the education and civil-service plans" in prose without linking either; the party publishes **four** (`yokermichya`, `education`, `servant-law-new`, `meshartim`) and only the `/plans/` index says so. **No axis moved.** **One justification reversed:** the entry said `kashrut-liberalization` is *not* anti-clerical evidence here because the reform works "inside the Rabbinate's framework" — the live plan makes *"נשבור את מונופול הרבנות"* a headline plank, with automatic recognition of international certifiers and supervision moved to the certifying body, and states that the Rabbinate-certificate obligation *"מרוקנת מתוכן חלקים מהרפורמה"*. Kashrut is now the strongest single piece of anti-clerical evidence on this row. **The signal was a moved URL** — `plans/yoker` 301s to `plans/yokermichya` — so a redirect on a cited source is recorded as a re-read trigger. The four education claims sitting next to that sentence were all correct but **unsourced**, which is why the stale one beside them went unnoticed. **7 tags added** (9 → 16), all existing vocabulary: `core-curriculum` (the 60% funding condition — the criterion that *defines* the −2 band this row has always sat in, untagged), `state-haredi-education` (90% of haredi-supervised pupils to state-haredi institutions within eight years), `municipal-devolution` (70% of education decisions to local authorities), `reservist-focused`, `sanctions-on-non-servers` (individual benefits, the side of the line revision 15 drew when it denied this tag to הדמוקרטים), `service-conditioned-citizenship`, `workforce-integration`. **`universal-conscription` confirmed with a mechanism note**: three holders now use three different enforcement models — ביחד sanctions-only with no criminal penalty, ישר דין פלילי, כחול לבן coercion plus fines. `conscription-by-incentive` still wrong here (defined by rejecting sanctions, which this programme is built on); `welfare-state` rejected (conditional, single-population, deficit-neutral by construction). **economic +1 confirmed** with every listed measure verified against live text, plus the previously unrecorded scale of the statist half: ₪8.8B redirected and a housing benefit the party itself costs at **~₪16B/yr**, argued as costless because it is forgone land revenue — recorded here as the state expansion it is, not as the accounting the party gives it. **security NULL re-verified and strengthened**: the list *does* publish joint plans, on four topics, and the conflict is not among them — a declined subject rather than an absent platform. **religiosity −2 confirmed by the funding criterion for the third row in three days**, and this one satisfies a different subset of the −3 band's criteria again (ends a Rabbinate monopoly outright, silent on marriage, fails on funding), making the band text the most-cited unresolved item on this page |
| 2026-08-17 | revision 23 — **המפלגה הכלכלית read against its full platform for the first time, and `security` moved 0 → +2.** The `מצע` URL is an **index**: each section shows one intro paragraph and a *המשך לקרא* link to its own page, so the entry had been written from first paragraphs only. All 13 sub-pages read, plus two the index does not link (`רפורמה-במערכת-המשפט`, `הון-שלטון`). **The `/ביטחון` page is a full conflict platform** — *"תתנגד לכל נסיגה או וויתור ולו הקטן ביותר משטחי מדינת ישראל"*, *"תתנגד להקמתה של מדינה פלסטינאית"*, *"תתמוך בחיזוק ההתיישבות היהודית ביהודה ושומרון"*, no Gaza deal without dismantling incitement education, and abolition of Palestinian work permits. That is the +2 definition verbatim; **not +3** because ריבונות/סיפוח appear nowhere. **The old `0` was not a gap but a false positive claim**, and the band table used this very row as its worked example of what `0` means ("an economics party that genuinely takes no conflict position") — that sentence is now deleted and the band left with one unaudited holder, יש עתיד `[p]`, flagged in Open questions. **Inverse of the ישר `homeland-security` trap**: there a URL invited the wrong axis; here the page is named for the right axis, opens on defence-budget material belonging to no axis, and buries the real position in its second half. **`single-issue-economy` REMOVED** — the party publishes dedicated pages on the conflict, women's equality, environment and animal rights, health, welfare, pensions, education, transport and agriculture; same correction revision 17 made removing `not-economy-focused` from הציונות הדתית. The true observation it was standing in for — that the *framing* is economic throughout — survives in prose, since a tag cannot separate "argues everything through economics" from "holds no other positions". **9 tags added** (9 → 17 net): `no-palestinian-state`, `pro-settlement`, `security-hawk`, `universal-conscription` (+ family), `sanctions-on-non-servers`, `scholar-exemption-retained`, `state-haredi-education`, `workforce-integration`, `gender-equality`. **`pro-settlement` is the one case where the התיישבות homograph resolves toward the West Bank** — the page says ביהודה ושומרון explicitly, unlike the Negev/Galilee usages flagged in revisions 15 and 21. **`scholar-exemption-retained` gains a third holder and now marks a boundary**: כחול לבן keeps תורתו אומנותו open-ended, this row keeps a real פטור capped at 2,000 yeshiva students under rabbinic testing, ישר abolishes the exemption for a 3% one-year deferral requiring basic training (tag declined there in revision 21). **`gender-equality` gains a second holder, and the contrast with revision 21 is deliberate** — declined for ישר as violence policy in a crime paper, granted here for a dedicated programme covering pay/promotion equality, statutory representation, gender education, הדרת נשים והפרדה מגדרית and עגונות ומסורבות גט. **economic +1 and religiosity −2 both confirmed and unmoved.** religiosity is the **fourth row in four days** held at −2 by the funding criterion, reached differently again: kashrut privatized outright (*"את הכשרות יש להפריט"*) but state religious funding retained and expanded, and core studies **incentivized rather than made a funding condition** — a weaker lever than the other three use. **Three rejections recorded with reasons:** `judicial-overhaul` (Zelikha supports a *symmetrical* escalating-majority override and political-trust legal advisers but *"מתנגד בכל תוקף"* to Rothman's bill and to government control of appointments — filing him with RZP/Otzma/נעם would misrepresent him; source also dated 2023-01-31, and his distinctive claim is that the courts' failure is **economic**), `agricultural-protectionism` (identical abolish-tariffs-substitute-direct-subsidy structure to ביחד, which was not tagged; ישר keeps it for legislated ענף אסטרטגי חיוני status and production targets that neither of the others has) and a **new environment tag**, refused despite clear evidence because a tag created from one row's audit measures reading coverage — filed as an open question to be resolved by sweeping all 18 rows in one pass |
| 2026-08-18 | revision 24 — **הליכוד read against a candidate list for the first time**, its 2026 primary (98% counted, 17 Aug). **`security` +2 → +3 on `upcoming_parties`, the only axis this pass moved** — and it moved on the *government's* record, not the list: the 8 Feb 2026 Security Cabinet package extending control into Areas A and B, the Ministerial Committee on Legislation backing a statutory West Bank Heritage Authority (the first application of domestic Israeli law to territory rather than persons), 54 new settlements by cabinet decision in 2025, E1 approved with an acceleration agreement signed by Netanyahu personally. The "Netanyahu never intended to annex" line is an unnamed official on *formal declaration*, contradicted four months later against explicit US requests; Crisis Group titles it *Sovereignty in All but Name*. **`previous_parties` deliberately held at +2** — the whole record postdates November 2022 — so the two rows now diverge on this axis and the band table marks הליכוד `[p]` at +2 and `[u]` at +3. **economic +1 and religiosity +2 both confirmed**: the list supplies the +1 band's two halves simultaneously (אלי כהן/ישראל כץ/אוחנה liberalizing, רגב/חיים כץ expanding), and ברקת's fall to #24 is explicitly *not* read as an economic verdict — it was a leadership purge, and תדמור, another economic liberal, entered at #27. `conscription-exemption` reconfirmed by a fresh instance of its own mechanism: אופיר כץ at #10 stripped Dan Illouz of two committees over the haredi draft. **Ten tags added, 4 → 14** — the row had the thinnest tag set on this page because it publishes no platform and had never been audited: `judicial-overhaul` (closing the largest gap on the page — the party whose own Justice Minister wrote it, at #7, did not carry it), `no-palestinian-state`, `anti-two-state`, `security-hawk` (three gaps contradicting the row's own band), `sovereignty-annexation`, `pro-settlement`, `hardline-on-gaza`, `preemptive-security-doctrine`, `scholar-exemption-retained`, `voluntary-palestinian-emigration-incentives`. **That last tag was RENAMED** from `voluntary-emigration-incentives` across both holders: the old name never said whose emigration, and it is deliberately *not* narrowed to Gaza, since אל הדגל's plank covers "Palestinians choosing to leave" with no geographic limit — naming a place the evidence does not support is the התיישבות homograph failure in reverse. **Seven rejections recorded**, the most instructive being `opposes-western-wall-compromise`, **considered and dropped once checked**: the Kotel bill is מאוז's private member's bill at preliminary reading, its text does not name the Western Wall, Levin was an advocate rather than its sponsor, and **Netanyahu pulled it from the Ministerial Committee for Legislation** — leadership declining is evidence *against* a party line, the mirror of the punished-dissent test that keeps `conscription-exemption`. Also refused: `far-right` (journalists' characterisation, not a party source — but אלמוג כהן's עוצמה יהודית defection at #14, for whom Netanyahu waived the membership rule, is recorded with a trigger), `opposes-hostage-deals` (זוהר at #13 publicly carried the deal), `pm-immunity-protections`, `anti-lgbt` **and** `lgbt-rights` (the row genuinely splits — אוחנה voted for a civil-marriage bill as sitting Speaker while שיקלי called Pride "disgraceful vulgarity" — so neither is true of the party), and `deregulation` (audit coverage). A press-freedom tag for קרעי's programme was refused and **queued behind an 18-row sweep**, alongside the environment tag. Four thin records left explicitly unresolved rather than inferred |
| 2026-08-19 | revision 25 — **אל הדגל's two unread documents read, and the row's own record corrected.** The `/our-platform` page links **four** PDFs; two had never been cited anywhere — the drafted Basic Law (`חוק יסוד השירות`, 9pp) and the economic paper (`הכלכלה הציונית`, 7pp, dated **August 2026** and marked *גרסה מתוקנת*, i.e. newer than the pass that last confirmed the axis it speaks to). **No axis moved: 1 / 2 / −2 all confirmed.** **The most consequential finding is about this document, not the party.** The entry asserted that the education-funding condition lived only in the education paper and that the platform showed *שכבת בסיס חובה בכל מוסד מתוקצב* alone; the platform's §2 עיגון חוקי (p. 11) carries the **50/30/20 split the entry credited to the education paper**, the special-majority entrenchment, and *"תנאי לקבלת תקציבים"* verbatim. So the `religiosity 0` held until 2026-08-10 was a misreading of evidence already in hand, not a gap in it — **a second document agreeing with the first is not evidence the first was read.** **A third retrieval trap recorded, inverting the first two: the two documents that went unread longest were the two that extract cleanly** — the image-only pair got read precisely because they announced themselves as hard. **economic +1 declined for the third time on a third document**, now against a fully costed programme; the two planks that argue against +2 are the party's own — periphery tax breaks rejected **on principle** as proven failures, and *"שוויון מיסוי הון ועבודה"* restricting capital tax benefits for the highest earners. Also logged: the paper is unusually self-correcting (ministry-merger savings demoted from ₪8–12B/yr to a long-run ceiling on 1–3% international evidence; the tax-bracket cost revised **down** because the Knesset already enacted part of it), and it **contradicts the platform** on the minister cap — 16 in the platform, 18 statutory with a 12 aspiration in the paper; recorded, not resolved. **The service bill does NOT move religiosity, and that is recorded because it reads like −3 evidence**: §11(c) strips all state support and bans all donations to any institution where >10% of students or graduates breached the service duty, but it conditions on **service**, so Decision 6 keeps it off the axis. **4 tags added (20 → 24), all existing vocabulary**, and **three of the four are earnable from the platform PDF alone** — missed by an earlier pass rather than created by the new documents: `free-trade` and `anti-monopoly` (both p. 22), `public-service-reform` (pp. 19–20, a חוק שירות ציבורי ממלכתי plus a biennial trust index carrying a mandatory Knesset debate — comparable to כחול לבן's צו 8, which founded the tag) and `arab-civil-service` (bill §8 plus its explanatory notes, כחול לבן's founding position in statutory drafting). **Six rejections**, the sharpest being `scholar-exemption-retained` — **third application of revision 21's test and the clearest**: a 2%-of-cohort Torah track under a state administration, subordinated to the IDF's needs being met first, as a 24-month *service* obligation, is strictly narrower than the 3% one-year deferral already declined for ישר. Also refused: `permanent-residency-not-citizenship` (זהות's tag marks a permanent ceiling; this row's השארות track is a conditional **path** to full citizenship), `small-government` (זהות holds it as libertarian doctrine; this row pairs ministry cuts with NIT expansion, a ₪2B guarantee fund and a ~$1.5B/yr AI programme — it would contradict its own economic +1), `tax-cutting` (the 25% bracket *completes* an enacted reform, cost revised down, paired with restricting capital tax benefits), `judicial-overhaul` (the override clause is bounded *מוגבלת בזמן ובנושא* and paired with **strengthening** review of Basic Law implementation and a codified constitution — `constitutionalist`, already held, is the accurate tag; same shape as revision 23's Zelikha rejection), and **a workfare tag and a labour-organization tag**, both clearly earned and both queued behind an 18-row sweep. **That queue now holds four tags** and is flagged as the largest unresolved item on this page. Source accounting corrected throughout: **six** sources, not three, and the website quotes are from `/our-platform` (a fourth body of text) rather than the `/about-us` chapters they were attributed to |
| 2026-08-20 | revision 26 — **חד"ש-תע"ל and בל"ד merged into הרשימה המשותפת**, the first merge this file has recorded between two *upcoming* rows (העבודה/מרצ → הדמוקרטים was a previous→upcoming lineage link, which is a different operation: both predecessors keep their own rows). One `joint-list` row replaces two; `previous_parties` is untouched and both 2022 rows stay frozen. **The scoring rule was the decision, not the merge**: axes are the **union** of the components' published positions, chosen by the repo owner over two alternatives (carry חד"ש-תע"ל's numbers as a rebrand; or NULL the axes where the components differ). **economic −3** unchanged, **security −2 → −3** and **religiosity NULL → −3**, both carried from בל"ד alone. The cost is recorded in the entry rather than hidden: the list has published **no joint platform**, so every number rests on component text, and בל"ד's programme is the 2018 one. Decided against the ביחד `security` NULL precedent deliberately — ביחד's components *disagree* on the conflict, while חד"ש and בל"ד differ only in degree. **15 tags**, the union deduped, minus two dropped as no longer true of the list: `pro-joint-list` (the goal is achieved; a list tagged with wanting to form itself records nothing) and `program-unchanged-since-2018` (a note about בל"ד's evidence age that would now assert the joint list has a 2018 programme). **רע"ם declined and keeps its own row** — the door is open until the September deadline, so the open question narrows rather than closing. **Two anticipations in this file were wrong and are kept as such**: both the *Renaming* warning and the *Arab bloc may restructure* open question predicted "renaming, not reclassifying", and neither half held. **Mechanically**: `seed.sql` gained a guarded `DELETE` for `upcoming_parties` mirroring the clubs one, and it must clear `party_lineage` first — `party_lineage.upcoming_party_id` has **no** `ON DELETE CASCADE`, so removing a party that still carries a link raises inside `init_db`, which runs on every backend pod boot (a CrashLoopBackOff on startup, not one failed request). Both statements carry the same vote guard, verified by migrating a seeded database with a vote on חד"ש-תע"ל: that row and its lineage link both survived while בל"ד was removed. **No frontend change** — the logo is pure black on transparency and the existing `recolorLogoForDark()` lifts it to white correctly, so it needs no `logos.js` exception entry |
| 2026-08-20 | revision 27 — **הרשימה המשותפת's logo corrected the same day it shipped, and revision 26's "No frontend change" reasoning is wrong.** That row said the mark needs no `logos.js` entry because `recolorLogoForDark()` lifts every ink pixel to white — which it does, and which was measured before shipping. The measurement was of the wrong thing. What the lift leaves behind is **five enclosed transparent regions, all on the Arabic line** (the closed bowls of ة and م, ~9×10px on the 400px canvas), and transparent means they show the dark card through. That is typographically correct — a counter *is* the background — and it still reads as **black dots punched into white letters** at 3.4rem, because a counter that small stops reading as a counter. **Being right about the typography did not make it look right**; only rendering it at card size catches that, and the pre-ship check rendered it at 400px and judged it clean. Now in a new **`FILL_COUNTERS_PARTIES`** set (mode `recolor-fill`): `fillLogoInteriorForDark()`, the same flood fill ש"ס uses, **composed with the recolour rather than replacing it**. The literal ש"ס treatment was rendered and **rejected** — fill-only leaves the ink black, producing a near-invisible black wordmark on the dark card. Both artworks are "dark ink on transparency" and need opposite things, so the selector is not whether enclosed transparency exists but **what the gap should become**: the page (ש"ס) or the ink (here). `recolorLogoForDark()`/`fillLogoInteriorForDark()` now accept a `<canvas>` as well as an `<img>` so the two can chain. Verified in Chromium against the real `logos.js`, reading the canvas back: **exactly 316 pixels** moved from card-dark to light (the 315 enclosed pixels plus rounding), glyph anti-aliasing untouched, and ש"ס and הליכוד rendering identically to before. **No classification change** |
| 2026-08-20 | revision 28
| 2026-08-26 | revision 29 — **ביחד's corpus 4 → 6**: the `הזדקנות-בכבוד` (aging) and `women` plans read for the first time. **No axis moved.** `gender-equality` added (16 → 17 tags) on revision 23's line — four of the plan's seven sections are non-violence (50% representation in the senior civil service and government boards, a mandatory gender opinion on every bill, a party-funding incentive for women on lists, daycare subsidy plus paternity leave, Equal Opportunities enforcement powers, high-tech targets), which is the shape granted to המפלגה הכלכלית and not the "crime policy in a crime paper" shape declined for ישר. **`welfare-state` added to the families (3 → 4), overturning the rejection recorded in revision 22** — the aging plan re-indexes the old-age pension to the **average wage** instead of the CPI, reversing the 2003 de-indexation, plus a differential rise for ~350,000 under ₪10,000 with the poorest's pension doubled and an automatic indexation mechanism for Holocaust survivors, with **no funding source or offsetting cut named anywhere**. That is a change to the statutory formula of a universal entitlement, the same class of act as בית ציוני's public housing 50,000 → 110,000 (revision 20); the old rejection stands as a correct finding about the *servants law*, which is a different document. **economic +1 confirmed** with a stated move condition, since three revisions running have added statist material without moving it. **security NULL re-verified against six documents**, and sharpened: the women's plan discusses the IDF (combat roles, reservists' families) while the corpus still contains no sentence on the conflict. **religiosity −2 confirmed by the funding criterion**, on this row's first religion-and-state material that is neither education nor kashrut — repealing the laws that expanded the rabbinical courts' authority, דיינים training, preventive measures on get-refusal and עגינות, women in the religious councils and rabbi-electing assemblies, repeal of the academic gender-separation law. **`civil-marriage` rejected, and its absence is now a position**: a women's-status plan that answers עגינות from inside the rabbinical system declined to propose it where the subject demanded it. `religious-pluralism` and `affirmative-action` also rejected (the latter on revision 21's `anti-corruption`-next-to-`governance-reform` reasoning). **Method note: the `/plans/` index is paginated** — revision 22's "enumerate the index" rule stops one page short of being sufficient. Also recorded: the aging plan's section 06 carries a drafting error, *"נבטל את נקבע יעדים…"*, whose literal reading is the opposite of the plan's position — **הרשימה המשותפת's logo moved to a near-white plate (`PLATE_PARTIES`), and both earlier fixes were reverted.** Revision 27 diagnosed the black dots as the five enclosed Arabic bowls and composed the ש"ס flood fill with the recolour; it measured 316 pixels moving from card-dark to light, in Chromium, against the live page, and **the dots were still there**. A screenshot from the repo owner's own browser showed why: the recoloured canvas comes back **speckled with black dots through the glyph bodies**, dense and scattered, unrelated to counters or letterform gaps. The source SVG renders clean at every size (48 unique colours in a magnified crop) and the live canvas read back from headless Chromium holds **zero** pixels darker than the card — it is a rasterisation artefact this repo cannot reproduce, so no measurement taken here could ever have caught it. **Both failed fixes were real measurements of the wrong thing**, which is the finding worth keeping: revision 26 measured the 400px canvas rather than the ~156px it renders at, and revision 27 fixed the enclosed subset and then measured the enclosed subset. The plate refuses the mechanism instead of tuning it — no canvas, no `getImageData`, no `crossOrigin`, no per-logo thresholds — so dark mode reproduces exactly what light mode shows. `FILL_COUNTERS_PARTIES` and `recolorThenFillForDark()` are **removed**, and both pixel functions are back to their original `<img>`-only signatures. **This reopens the no-plate rule for parties**, chosen by the repo owner after seeing all three options rendered at true display size; ש"ס already reads as a white tablet, so a third such party would mean the recolour rule has become the exception. **No classification change** |
| 2026-08-26 | revision 30 — **עוצמה יהודית: six conflict tags added (11 → 17), every one first-party and every one available at the previous pass.** **No axis moved** (`security +3` and `religiosity +3` are already at the poles; `economic 0` survives a sixth reading). `no-palestinian-state` (*"לא נאפשר אף הסכם כניעה שיכלול אפילו הצהרה על מדינה פלסטינית"*), `anti-two-state` (a whole-faction bill annulling Oslo, Hebron and Wye and restoring the territories transferred under them — **this row is the page's cleanest case for why the two tags are separate**), `hardline-on-gaza` (*"עזה צריכה לספוג גיהנום"*, bombing aid stores, total water/electricity cutoff, explicit mass starvation, a 1 km perimeter with direct fire on any resident inside it), `territorial-control-gaza` (*"החלת ריבונות לצמיתות על שטחים נרחבים ברצועה"*, אליהו's *"עזה היהודית שלנו"*, and Ben Gvir's "settlements throughout Gaza") — **which reaches this document for the first time**, having sat in `seed.sql` on בית ציוני with zero occurrences here, so it had no definition a candidate could be checked against; `voluntary-palestinian-emigration-incentives` (the party's own 2025-02-07 bill, the first holder whose evidence is drafted legislation); `opposes-hostage-deals` (the 2025-01-17 resignation letter, **acted on** — stronger evidence than either existing holder's candidate placement). **The method finding is the point of the pass:** revision 18 read "30 posts, 2026-05-26 to 2026-08-04", a **ten-week window** of a stream running since the party entered government; the entire Gaza programme is Dec 2024 – Nov 2025 and fell outside it. **A date-bounded sample of a continuous stream is not a corpus, and it reads as more thorough than an unread platform** — the site has no index to contradict it. Three subject searches (`עזה`, `מדינה פלסטינית`, `עסקת חטופים`) surfaced all of it. `jewish-supremacist` becomes first-party for the first time (*"אספסוף עזתי צמא דם"* in a bill's explanatory notes; *"they're not even people"* on the podcast). **Three rejections with reasons:** `population-transfer` (the bill is opt-in, and this page's line turns on compulsion in the instrument, not the rhetoric around it — though a citizenship-stripping bill sits beside it), `security-hawk` (all five holders are centre/centre-right and no far-right row carries it; a disposition tag would erase the distinction it exists to draw) and `populist` (the Segal letter is grievance about the author's standing, not a position). Two numbers corrected: 300,000 weapons (was 280,000 licences) and 10,000 demolitions since 2025, the 10,000th in **ג'ואריש, רמלה**, so "mainly in the Negev" no longer holds. The `conscription-by-incentive` family becomes first-party (haredi police recruitment, מג"ב haredi units, 1,400 enlisted). Also recorded: the party holds a **second ministry** (עמיחי אליהו, Heritage) which this entry had never mentioned, and Ben Gvir now reads a campaign to form a unity government **without him** — exclusion pressure from inside his own bloc. **Two retrieval notes:** `timesofisrael.com` 403s a User-Agent alone and 200s with `Accept`/`Accept-Language`/`Referer` — a UA by itself is not browser-shaped enough; and **a summarizer's rendering of a source is not the source**, since WebFetch's summary of that liveblog dropped the single most classification-relevant sentence in it
| 2026-08-26 | revision 31 — **הציונות הדתית: the party's own site enumerated for the first time.** Every prior pass followed links it was handed — 13 platform PDFs (revision 17), 13 `/hityashvut/` pages, a circulated מילואים deck — and none asked `page-sitemap.xml` what the site holds. It answers in **one request** and lists five pages published since the last pass, one of them **the same day**. Three are sign-up forms; two are policy. **הכרעה וניצחון (`/victory/`, September 2025) is the party's entire Gaza programme and had been public for eleven months** across two passes over this row. **Three tags added (11 → 14), all first-party:** `territorial-control-gaza` (*"סיפוח פרימטר ביטחוני מורחב"*, then a further annexation *"בכל שבוע שהמלחמה תימשך"* — and **the page's timeline image**, not its text, carries four *dated* annexations at days 14/21/28/35 plus *"יום 70-90: העברת האוכלוסייה לשטח שמדרום למורג"*; the image-only-content rule applying to a web page rather than a PDF), `hardline-on-gaza` (*"מצור… סגירה מוחלטת של כלל האספקה"*, aid confined to the humanitarian zone *"בלבד"*) and `voluntary-palestinian-emigration-incentives` (*"מענקי תמרוץ ליוצאים ולמדינות הקולטות"* — the first holder whose evidence is a sitting finance minister's costed plan). `opposes-hostage-deals` **reconfirmed, not re-derived**: it was held on צביקה מור's primary placement and this supplies the party-level position that placement was evidence *for*. **No axis moved — fifth consecutive reading**, `security`/`religiosity` at their poles and `economic` 0 because emigration grants are territorial policy denominated in shekels; `basis` stays `record` (a single-issue document is not a מצע). **מייהדים את הנגב והגליל (`/judaization/`, published that day) read and deliberately NOT tagged** — *"מה שעשינו ביו״ש נעשה בנגב ובגליל"*, *"שינוי דמוגרפי"* with numerical targets and a נגב–גליל cabinet. It is the second and far stronger instance of what the 2026-07-27 entry left untagged, and clears that entry's bar (inside the Green Line, moves people not borders) — but that entry's instruction was about **scope**, so it is **queued as a cross-row sweep**, like the press-freedom tag in revision 24. Same page **confirms revision 19's retirement of `periphery-development` from the party's own mouth** (*"לא עוד ״חיזוק הפריפריה״"*) and gives `claims-economically-liberal` its best evidence yet. **Three rejections:** `population-transfer` (the emigration is opt-in; the compulsory movement is displacement *within* Gaza paired with Israel *"לקיחת אחריות אזרחית"*, an occupation-administration claim), `security-hawk` (revision 30's precedent unchanged) and `no-palestinian-state` (not stated; `anti-two-state` already covers it). **The 2026-08-14 provenance caveat is closed as verified-absent**: the sitemap carries no מילואים page, so that deck stays party-circulated |
| 2026-08-23 | האחדות (Unity) added — new party, scored from its own site |
| 2026-08-27 | revision 32 — **עמך ישראל added**, the page's first row scored from a single launch event: the party is two days old, has no site and no platform, and the corpus is same-day reporting of what וינטר said on stage. **`security` +3 on two verbatim quotes** (*"לעולם לא תהיה פה מדינה פלסטינית"*, *"הפיתרון בעזה הוא אחד - הגירה"*, *"מחיר טריטוריאלי כבד"*); **`economic` and `religiosity` both NULL as positive findings of absence**, verified by keyword sweep across five independently fetched sources rather than left blank for want of looking. **The row's most useful output is a tag gap, not a tag**: `voluntary-palestinian-emigration-incentives` and `population-transfer` BOTH refused, because this page's line is opt-in-with-an-instrument versus compulsion-in-the-instrument, and a bare *הגירה* with no mechanism sits between them — the first time the two tags' founding cases have been shown to leave a hole. Also refused: `security-hawk` (revision 30/31 precedent), `anti-two-state`, `sovereignty-annexation`, `territorial-control-gaza`, `hardline-on-gaza` (a demographic outcome is not siege conduct) and `reservist-movement` as a tag. **Three claims refuted 0–3 and recorded as such** — that the speech covered haredi conscription, that it covered judicial reform, and that אביב עזרא's prior conscription campaigning transfers to the party — all traceable to one מעריב piece, and all of them the kind of plausible detail that would have moved `religiosity` off NULL wrongly. `bloc` `bibi` is flagged as the weakest field on the row (declared camp and a refusal of איזנקוט, but no Netanyahu endorsement, refused merger, and Netanyahu campaigning against him). **A third self-hosted logo**, and the keying method is written down because two obvious approaches fail *only* on the dark card: HSL saturation is degenerate on a near-white ground (the empty gap between glyph lines measured **higher** saturation than the blue stroke) and darkness-keying lifts JPEG ringing; unpremultiplying a measured #F2F2F2 ground is what works. Row flagged **expected-unstable**: list submission closes in ~2 weeks, Netanyahu is demanding withdrawal or merger, and the first three polls disagree (6 seats / 8 seats / below threshold) |
| 2026-08-30 | revision 33 — **הציונות הדתית: `/judaization/` re-read and found REWRITTEN.** `page-sitemap.xml` puts its `lastmod` at 2026-08-27, one day after revision 31 read it, and not one of the four strings that entry quotes survives in the current HTML or its images; the Internet Archive has no snapshot of the URL, so the earlier text is unrecoverable and those quotations can no longer be checked. Revision 31 stands as a dated record. **The rule this produces**: `lastmod` already dates every page on a site enumerated the revision-31 way, so re-checking a page already read costs the same single request as discovering a new one. The current version is a three-pillar programme (אדמה / אדם / ביטחון) whose banner **״כן. מייהדים.״** is image-only — the `/victory/` trap a second time on the same row — and whose **third pillar has no counterpart in revision 31's account**: a national הוראת שעה against organised crime aimed at *"לפרק את האוטונומיה הערבית החמושה"*, with weapons possession defined as terrorism, שב"כ deployment, administrative detention, evidentiary presumptions and *"מודל ג׳וליאני"* enforcement. The security paragraph appears twice with different adjectives (*"ודרקוניים"* / *"ממוקדים ומפוקחים משפטית"*), both party text. **No axis moved** — sixth consecutive reading; +3/+3 at their poles and the incentive package is regional subsidy denominated in shekels, `claims-economically-liberal`'s fourth and best evidence base. **No tag added.** Two dimensions queued behind the 18-row sweep instead — demography (queued since revision 31 but never filed in Open questions until now, the same mechanism that stalled the `religiosity −3` band) and domestic policing of Arab citizens, which no tag covers and which עוצמה יהודית visibly earns too. Queue 4 → 6 |
| 2026-08-30 | revision 34 — **ש"ס and יהדות התורה split into two entries and evidenced for the first time.** The two rows had shared one four-line block scoring them identically on every column, with only `religiosity` argued — the exact collapse the "axis records direction, tag records motive" convention exists to prevent, and the thinnest entry on a 3,400-line page. **No axis moved**: `religiosity` +2 confirmed by **חוק שיפוט בתי דין דתיים (בוררות), תשפ"ו-2026** (Gafni, Yaakov Asher, Yinon Azoulay; 65–41, 24 March 2026), which lets religious courts arbitrate civil matters **by the religious law they apply** but only on both parties' signature — a parallel jurisdiction, not a halakhic state, so the same +2 as זהות, which only proposed it; `economic` −2 confirmed for ש"ס by the food-voucher criteria its own Welfare Ministry wrote (per-capita income **without** a מיצוי כושר השתכרות test) and **knowingly retained as the page's weakest number** for יהדות התורה, which has no economic doctrine on record at all; `security` +1 confirmed by both factions **supporting** the hostage deals on פדיון שבויים grounds, against `opposes-hostage-deals` on the three far-right rows; `bloc` bibi **kept on both and now the most contestable cell on the page**, with the evidence both ways written out and an explicit move condition in Open questions. **Twelve tags added, 2 → 8 on each row.** `scholar-exemption-retained` is the correction that most needed making — it sat on four parties that merely tolerate the yeshiva exemption and on neither of the two organised around it. `rabbinic-authority-led` moves from a נעם singleton to its paradigm case; `jewish-law-parallel-jurisdiction` from a Zehut singleton to the parties that legislated it; `judicial-overhaul` from the record (the reasonableness repeal passed **64–0** with the opposition boycotting, and 64 was the whole coalition, so the arithmetic settles it), reinforced by Basic Law: Torah Study (63–52) and the arrest-freeze law (58–54, frozen by the High Court). Two new tags, both deliberate singletons or near: `opposes-core-curriculum` (the mirror of `core-curriculum`'s seven holders, resting on the 55% funding architecture and the 25 December 2025 government decision to introduce גפ"ן **"ללא תלות בלימודי ליבה"**) and, on יהדות התורה alone, `two-faction-list` — **whose justification was wrong as written and was corrected the same day, see revision 35**. `mizrahi-representation` on ש"ס alone, since `sector: haredi` is what made the two rows look identical. `judicial-restraint` added to both families, 3 → 4. **Method note, and the reason this row is worth reading twice: the platform is genuinely absent and that was tested, not assumed** — `shas.org.il` returns `ECONNREFUSED` to two independent fetchers and its newest Wayback snapshot is 2022-11-01, and no דגל/אגודה host resolves at all. **The headline of the record is that four years of maximal leverage produced no exemption statute** (79,000+ conscription orders → ~2,100 enlistments; 17 proactive arrests in a year) **while the budget delivered almost completely** (~₪2.4bn sectoral education budgets in 2026, a ₪942m/+32.5% rise, ₪1.1bn already paid before the Knesset approved it) |
| 2026-08-30 | revision 35 — **יהדות התורה's faction split is a ritual, not an event, and revision 34 read it as news.** The repo owner flagged it within the hour: אגודת ישראל and דגל התורה have run together and sat as independent parties since **1992**, and he.wikipedia states the base rate exactly — the faction has split into its components **at the end of every Knesset term up to the 25th except the 15th, 18th and 19th**, and **every single time** the reopened joint-run negotiation succeeded and the two ran again on one list. So the **16 July 2026** split carried no information, the Kikar HaShabbat briefing about דגל weighing an independent run is what that negotiation looks like from outside every cycle, and Maklev's *"אנחנו לא מתגרשים אלא מתחדשים ונפרדים לתקופה"* describes a procedure rather than hedging about a breakup. **`two-faction-list` is kept and its justification replaced**: it now records the standing structure — a joint list of two independent parties with **separate מועצות גדולי תורה that rarely convene together** — which is also *why* `conscription-split` is the right family, since two councils holding two lines is not one party failing to hold one. The **"will it be on the ballot as one list" open question is closed the day it was opened**, and **`bloc: bibi` is closed too, by the owner** (~99% that UTJ goes with Netanyahu); the evidence both ways stays under ש"ס, and the move trigger stays a *positive* signal. **The method lesson is the durable half, and it is a new shape for this page: every source in revision 34's corpus was accurate, correctly dated and correctly quoted, and the conclusion was still wrong, because the error was in the baseline the facts were read against.** Worse, the disconfirming sentence was **already in the research output** — "UTJ has split at the end of most Knesset terms since the 13th and reunited each time" — and was read and under-weighted, which no amount of further sourcing would have fixed. This is the sibling of the "reachable is not current" and "corroboration is not coverage" rules in `services/backend/CLAUDE.md`: **for any fact about a recurring institution, establish the base rate before deciding the fact is a development.** No axis, bloc, sector, tag or family value changed |
| 2026-08-31 | revision 36 — **הדמוקרטים's corpus 10 → 11 (חברה ערבית), and the August platform booklet proven to be a re-package.** **No axis moved and no tag was added; `seed.sql` is unchanged** — the first pass on this page to end that way, which is the outcome worth recording rather than hiding. The new paper is the row's strongest first-party evidence for `jewish-arab-partnership`, held until now off the realized list. **Four tags considered and rejected**, each on a precedent rather than on taste: `affirmative-action` (the paper asks for *"ייצוג הולם"* with no target and no mechanism, while revision 29 refused the same tag to ביחד on a **50% target plus a party-funding incentive** — granting it here would lower a bar set five days earlier), `arab-representation` and `focuses-on-arab-israeli-civil-issues` (both record what a party *is*, the `reservist-movement` distinction this row already carries), and `sectoral-budgeting` (held for coalition funds; a gap-closing חומש is not that, and the row's own economic paper runs *"במקום תקציבים מגזריים"*, so the tension is recorded in prose instead). **A name trap logged**: `arab-civil-service` is a national-service track for Arab citizens, not civil-service employment — it invites exactly the wrong match on a paper about representation in the ministries. **security −1 held at eleven papers**: revision 15's standing instruction was to re-open it if a *third* document leaned on the −1/−2 boundary, and this one leans in neither direction (מדינה פלסטינית, פלסטינ, כיבוש, שתי מדינות = 0 each). **The finding is a silence**: גיוס, שירות לאומי and שירות אזרחי are also 0, so the dedicated Arab-society paper is the most natural place revision 15's *"אוכלוסיות נוספות"* ambiguity would have been clarified and it was not — the open question narrows toward deliberate rather than unfinished. **`plan-8-26-he.pdf` (16pp, 2026-08-11, linked from the homepage as the platform) contributes nothing**: six chapters are verbatim at 48/48, 44/44, 39/39, 40/40, 39/39 and 36/36 sentences, and the crime and להט"ב chapters' apparent 17/26 and 9/36 divergence was **a `pdftotext` bullet-column artifact, not a finding** — every distinctive token is in both and the chapters match in length to within 4%. It omits מילואימניקים, שיווין מגדרי and חברה ערבית entirely (0 of the latter's 34 sentences), so it is a strict subset. **Checking tokens before believing a sentence diff** is the reusable half; the mirror of it is that the S3 bucket refuses `ListObjectsV2` and no page on `democrats.org.il` links the topic PDFs at all, so the booklet was reachable only by enumerating the site — revision 31's rule finding a document that then turned out to be worth nothing, which is still the rule working. **A tag gap filed rather than filled**: nothing covers the Kaminitz-Law repeal and Arab/Druze/Bedouin master planning, and it is queued behind a pass over the two Arab-list rows |
| 2026-09-01 | revision 37 — **הציונות הדתית and זהות merged into one ballot line**, the second merge between two `upcoming_parties` rows (after חד"ש-תע"ל + בל"ד → הרשימה המשותפת) and the first where the components **contradict each other**. Signed the same evening as a **technical bloc** (בלוק טכני) that may split once seated, each party keeping its own identity and principles; פייגלין at **#2**, זהות holding slots 2, 8, 10 and 11 of thirteen; וינטר invited by both סמוטריץ' and בן גביר and declining the same evening. **One row, not two** — a voter sees one line, the יהדות התורה precedent, so the row takes `two-faction-list` (1 → 2 holders) and the `zehut` row is removed under `seed.sql`'s guarded delete. **The decision was the `economic` axis, not the merge.** הרשימה המשותפת's union rule was adopted on the express condition that components *"differ only in degree, with direction not in dispute"*; here direction **is** in dispute — 0 against +3, a finance minister running sectoral budgeting against the axis's only doctrinal libertarian — so the rule's own precondition excludes it. **`economic` held at 0** (repo owner's call, over NULL on the ביחד precedent and over +3 on the union rule read literally): RZP holds nine of thirteen slots including #1 and the portfolio. **`security` and `religiosity` unchanged at +3** — the first because both components were already at the pole, the second because there the components *do* differ only in degree, so the union rule applies and takes the pole. **Tag rule stated for the first time: carry what the list adds, refuse what would contradict a number or a family on the same row.** Of זהות's nineteen, 2 dedupe, **7 carried** (`gun-rights`, `temple-mount-centred`, `population-transfer`, `cannabis-legalization`, `permanent-residency-not-citizenship`, `communitarian-devolution`, `jewish-law-parallel-jurisdiction`) and **10 refused** — six economic-liberal tags plus `ends-state-religious-funding` (the opposite of `sectoral-budgeting`), `professional-army` (the opposite of `conscription-split`), `state-institutions-bound-to-halakha` (subsumed by `halakhic-state`) and `extra-parliamentary` (no longer true; #2 is realistic). Row 14 → **22 tags**. **Eight tags leave the vocabulary with the row** — `libertarian`, `flat-tax`, `small-government`, `privatization`, `state-institutions-bound-to-halakha`, `ends-state-religious-funding`, `professional-army`, `extra-parliamentary` — and the `economic` **+3 band is now empty**. **And a FAMILY was retired that the tag accounting did not predict: `market-liberal`** — its only two holders were ישראל ביתנו (+2) and זהות (+3), so the merge left it naming one party, which `test_every_family_value_is_shared_by_at_least_two_parties` rejects. Retired rather than back-filled: the only candidates (אל הדגל, המפלגה הכלכלית) are economic **+1**, and this family's test is *actually withdraws the state*, so admitting them would lower a bar revision 25 already refused. Removed from `i18n.js` (all three languages), `analytics.js` and `docs/i18n/family-strings.csv`; ישראל ביתנו keeps two families. **The pre-flight check that missed it asked whether the family still had *a* holder — the invariant is two**, and the test is what caught it. **זהות's 89-line entry is kept in full as a `####` faction subsection of הציונות הדתית**, not deleted: seven of the merged row's tags are sourced there and nowhere else, and a technical bloc can split — if it does, that is the scoring a restored row starts from. **One open question resolved by removal rather than by reading**: זהות was the only `judicial-restraint` family member without `judicial-overhaul`, and the family is now unanimous because the surviving row already carried it — the platform check it was queued for is still owed if the bloc splits. **No brand was announced** (every outlet says *"הרשימה המאוחדת"*), so the row keeps RZP's name and logo rather than an invented one. `previous_parties` untouched — זהות was extra-parliamentary in 2022 and has no row there, so no `party_lineage` link changes. Row flagged **expected-unstable**: סמוטריץ' called it *"החיבור הראשון ולא האחרון"* and list submission closes the week of 2026-09-07 |
| 2026-09-02 | revision 38 — **נעם's logo replaced; the old Wikimedia file now 404s.** A dead source, not a preference, so the note describing the old artwork (navy wordmark between cyan bars, 45.3% dark pixels, lifted by `recolorLogoForDark()`) is struck through and kept as a record — none of it applies to the replacement, which is the **opposite kind of artwork**: a fully opaque dark-navy tile carrying a light wordmark. **No `logos.js` change, and specifically no `SKIP_RECOLOR_PARTIES` entry — verified by simulating the function's own first gate on the real file**, which measures `opaque / total` = **1.0000** against its `> 0.9` solid-tile threshold and returns `null` before touching a pixel. An entry would have asserted a rule the code already applies. **The same guard, the opposite outcome**: הציונות הדתית's PNG trips this identical check and that is exactly why it was unusable, because its baked-in tile is *white* and renders as a plate on the dark cards — so "the solid-tile guard fires" is neither good nor bad news by itself, it means the artwork is shown as drawn, which is right only when it was drawn for a ground close to the card's. **Cropped at the repo owner's request** because the wordmark was 13% of a 1600×1600 square: bright-pixel rows measured into three bands (wordmark 666–877, rule 893–904, בראשות אבי מעוז 946–992) over columns 288–1395, cropped with 28px padding and scaled to **900×296, 3.04:1** — the wordmark now ~59% of the tile height, and the aspect deliberately matches ביחד's 3.11:1, the shape `.logo-wide` already fits by width. **No `PADDED_CRESTS` entry**: that factor corrects transparent artwork that fails to span its own canvas, and a tile spans its canvas by definition. Self-hosted as the **fourth** file in `logos/` — a cropped file is no longer the file at the URL — and `oxipng` lossless only, never `pngquant`, because the background is a gradient (the `og-card.png` trap) |
| 2026-09-02 | revision 39 — **ישר's corpus 11 → 13 documents**: two new principles papers read ([שיקום ושגשוג הצפון](https://yasharwitheisenkot.com/principles/north-reconstruction-and-prosperity/), published 2026-08-17; [הגיל השלישי](https://yasharwitheisenkot.com/principles/senior-citizens/), published 2026-09-01). **No axis moved, no tag added, `seed.sql` unchanged** — the second pass on this page to end that way, after revision 36. **`principles-sitemap.xml` enumerates the corpus in one request** (11 papers plus the index), which is revision 31's technique applied to a second row, and its value here is the `lastmod` column rather than the count: it **proves revision 21 was not incomplete** (both new papers postdate it), it forces *papers* and *documents* to be counted separately (the brochure and the registered goals are not in it), and it flags that **`aliyah-and-integration` was modified 2026-08-18, two days after revision 21 read it** — the one page every religion-and-state finding on this row rests on. Re-checked live: all four cited phrases still present, religiosity −2 stands. **A `lastmod` after the read is a re-read trigger of the same class as revision 22's moved URL, and it arrives earlier.** **`welfare-state` re-rejected, and revision 21's stated reason struck through** — that reason quoted the economics paper's *"העבודה תשתלם תמיד יותר מקצבה"*, and **revision 29 bars the move**, having granted the tag to ביחד while leaving that row's identical workfare finding standing on the holding that an aging plan is *"a different class of document"*. Re-earned on the aging paper alone and **narrowly**: it has an unrestricted *"מנגנון קבע לשימור ערך הקצבאות"* and names no funding source, but it names **no formula, baseline or scope**, where ביחד named the average wage against the CPI and the 2003 de-indexation it reverses. The countable discriminator is stark — **the senior-citizens paper carries no shekel figure anywhere** (its only numerals are a 13% population share and two uses of אחוז), the sole paper in this corpus with no costed measure, against a north paper two weeks older carrying ₪15B/₪6B/₪3B/₪250M/₪225M and two new tax brackets; revision 19's standard is *a costed package, not rhetoric*. **The earning line is recorded** so the next pass tests instead of re-arguing: name the formula or baseline, or extend the rise past the low-income cohort. Also flagged: the page's most universal measure, mandatory LTC insurance, uses **נבחן** against נפעל ×8 / נקדם ×6 — **do not score an examination as a commitment**. **economic +1 confirmed (sixth reading)**: north grows both halves again (2.5%/5% corporate-tax brackets, Eilat-model depreciation, a business-arnona cut and a planning "green track" against ₪15B over five years and a national-priority law for the confrontation line), while senior-citizens is the corpus's **first purely expansionary document, without one liberalizing sentence** — recorded because it does *not* move the axis. **security +1 unmoved**, and the north paper is the **second URL on this row that invites the wrong axis**: a paper on the northern border with nothing on Lebanon, Hezbollah, doctrine, statehood or the territories — its ביטחון is מיגון and organised crime — bringing the count to **thirteen documents with no sentence on the conflict**. Fourth instance of the התיישבות homograph (Galilee pioneering, not the West Bank), and the first time *"עדיפות לאומית"* is attached to a **named** region (the northern confrontation line) — a data point, **not** a resolution of `inlocation-and-aliya`'s unnamed one. **`service-conditioned-citizenship` gains its sharpest sentence in the table**: north's 0–3 daycare subsidy pays **₪2,000 where a parent completed military service and ₪3,000 for an active reservist**, with no rate for a parent who did not serve — a universal child benefit differentiated by service status, where every prior instance on this row was welfare doctrine. **A fourteenth document is cross-referenced and does not exist** — north forward-references *"תכנית ישר! לחיזוק הפריפריה הגאוגרפית ופיתוח אזורי"*, which is on no page in the sitemap (`inlocation-and-aliya` is *לעליית המיליונים… In-location*, immigration); absences there are unwritten, not positions. `periphery-development` **stays retired** — a costed ₪15B regional programme plus a forward-referenced periphery plan is the third pass running to strengthen revision 19, not to challenge it. **Method note: religiosity −2 was confirmed by a search that nearly lied.** Word-level hits for גיור/דתי/יהודי and for עזה on both pages are **all locality names in the contact form's dropdown** (בר גיורא, כפר הנוער הדתי, כפר עזה, מחנה יהודית) — a WordPress settlement list of several hundred entries can manufacture apparent evidence for religion, Gaza and the territories at once. **Read the hit, not the count** |
| 2026-09-03 | revision 40 — **הדמוקרטים's corpus 11 → 13 documents**: two new topic papers read ([תוכנית פיתוח הצפון והדרום](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%AA%D7%95%D7%9B%D7%A0%D7%99%D7%AA+%D7%9C%D7%A4%D7%99%D7%AA%D7%95%D7%97+%D7%94%D7%A6%D7%A4%D7%95%D7%9F+%D7%95%D7%94%D7%93%D7%A8%D7%95%D7%9D.pdf), [המרחב הכפרי ושמירה על החקלאות הישראלית](https://democrats-media.s3.us-east-1.amazonaws.com/%D7%94%D7%9E%D7%A8%D7%97%D7%91+%D7%94%D7%9B%D7%A4%D7%A8%D7%99+%D7%95%D7%A9%D7%9E%D7%99%D7%A8%D7%94+%D7%A2%D7%9C+%D7%94%D7%97%D7%A7%D7%9C%D7%90%D7%95%D7%AA+%D7%94%D7%99%D7%A9%D7%A8%D7%90%D7%9C%D7%99%D7%AA.pdf)), supplied by the repo owner — re-enumerating the site confirmed revision 36's finding that **no page on `democrats.org.il` links the topic PDFs and the bucket refuses `ListObjectsV2`**, so this corpus can only grow by someone handing over a URL, which is a bound on the enumeration rule rather than a failure of it. **No axis moved.** **4 tags added** (17 → 21), all existing vocabulary: `agricultural-protectionism` (**loses single-holder status**, ישר was alone — and the tag now spans +1 and −2, so agricultural protection is shown not to be an artefact of the economic axis; granted on the *rejection* standard, since revision 23 refused it to המפלגה הכלכלית for abolishing tariffs in favour of direct subsidy while this paper manages trade *"כך שתגן על הייצור המקומי"*, and it clears ישר's national-production-targets and water-management elements outright), `cost-of-living` (a step titled *"נוריד את יוקר המחיה"* — **but the economic paper already supported it on 2026-08-01**, so the new paper found a membership gap rather than creating one), `municipal-devolution` and `communitarian-devolution` (both, on the ישר precedent that wording naming both levels earns both: resourced powers expansion plus energy-siting decisions taken *"בשיתוף ובהסכמה עם הרשויות המקומיות והיישובים הנוגעים בדבר"* — agreement, not consultation). **Four candidates rejected**: `statist` (its four holders are all economic 0/+1, where the axis hides state expansion; on a −2 the axis already says it — and `statist` is logged as one of the few tags this page never defines in prose), `anti-monopoly` (*"פערי התיווך"* is intermediation margin, not market structure; the economic paper may earn it, but that is a different pass), `periphery-development` (**retired revision 19 — this is the fifth documented programme, which strengthens the retirement**; the retirement section is amended rather than left stale) and an environment tag (declined revision 23, second qualifying corpus, same reasoning). **security −1 held on a stronger footing than revision 36's**: the four boundary tokens are 0 in both papers as they were in חברה ערבית, but that paper had *no* security content while this one's first step is a full war-termination and regional-arrangement programme — writing that much about ending the war and still naming neither the state nor the occupation is declining the subject, not omitting it for space; revision 15's "if a third document leans on the boundary" is **not** triggered. **`anti-annexation` became fiscal and was found under the wrong-looking heading** — *"במקום תקציבי עתק למאחזים ולסיפוח והטבות מס למתנחלים"* sits in a regional-development paper, the mirror of ישר's `aliyah-and-integration` concealing religion-and-state policy. **Two homographs logged, the second a live trap**: `התיישבות` ×4 in the rural paper is kibbutzim/moshavim/border localities (the page's **fourth** instance, and the sharpest, on a row that carries `anti-annexation` and defunds מאחזים in its other new paper), and `גיוס` ×1 in the north–south paper is **recruitment of municipal staff, not conscription** — the token revision 15's open question is tracked by, returning a hit that bears on it not at all, the same shape as this repo's `pgrep -f` and `grep '^gate:'` failures. Open question unchanged; the party constitution PDF logged as seen and deliberately skipped |
| 2026-09-03 | revision 41 — **עמך ישראל's first substantive policy statements** (press conference 2026-09-02, four independently fetched outlets: כאן, דבר, ynet, מעריב). **religiosity NULL → −2 — the first axis to move on this row, and the placeholder mechanism working exactly as written rather than a correction.** Revision 32 put the row in `RELIGIOSITY_NULL_BY_DESIGN` as a **placeholder with a stated trigger** ("Walla predicts the messaging will turn to שירות החרדים; when it does, that test fails, which is the point"). It did, six days later: Winter made *"חוק ששם סוף להשתמטות"* passing **before the government is sworn in** a precondition for entering any coalition — *"לא סעיף בהסכם קואליציוני"* — plus *"שילוב הציבור החרדי בצה"ל בלי פשרות ובלי דחיות"* and *"אין מגזר מעל החוק"*. **The score was settled by membership, not by the band prose**: this row satisfies exactly ONE of the −2 band's three criteria and is silent on the other two, but **all nine `universal-conscription` holders sit at −2 or −3 and not one is NULL, 0 or −1**, so the criterion is already treated as sufficient in practice; −1 was rejected as wrong *in kind* (that band is "soften the monopolies", and this row softens none). Logged as the **fourth** instance of the −2/−3 band defect, and the narrowest, with a disjunctive rewrite proposed in Open questions. **`bibi` resolved and `hard-to-classify-bloc` REMOVED** (2 → 1 holder): the hedge was carried on one stated reason — "Winter has never named נתניהו" — and he now has, twice on the record, alongside *"ברור שלא נלך עם ליברמן, בנט ואחרים"*. His condition binds *coalition entry*, not the recommendation, and the two are different fields. **3 tags added**: `universal-conscription` (also the row's second family, and the **strongest form any holder states** — a fourth enforcement model, one whose instrument is the party's own coalition leverage rather than a penalty on non-servers), `anti-conscription-exemption` (3 → 4) and `arab-civil-service` (3 → 4). **`arab-civil-service` is the *correct* match on the name revision 36 flagged as inviting the wrong one**, stated by the Arab deputy chairman: *"שותפות בנטל - לא משנה אם מדובר על יהודים או ערבים"* — and the cross-row irony is recorded, since revision 15's open question about whether הדמוקרטים's *"אוכלוסיות נוספות"* includes Arab citizens has now been answered explicitly by a party from the opposite bloc. **Three tags rejected on their founding cases**: `service-conditioned-citizenship` (this tag rests on Hendel's **franchise** clause; a graduated benefits ladder is not a claim about citizenship, and granting it would repeat the `arab-civil-service` name trap in the other direction — **logged as a vocabulary problem**, five holders under a label only one of them meets), `sanctions-on-non-servers` (all seven holders name a concrete penalty; this programme names only rewards — a reward ladder and a penalty schedule are different instruments) and `reservist-focused` (revision 13's costed-package standard; *"בראש סדר העדיפויות הלאומי"* has no benefit, number or instrument attached). **The Arab-society campaign earns no partnership tag and is recorded in prose**: חדאד confirmed as **deputy chairman** (revision 32 had him only at #2), targeting *"שני מנדטים מהחברה הערבית"* — but `jewish-arab-partnership` is refused because *"להעצים את הזהות הערבית-ישראלית במקום הפלסטינית בכל מוסדות החינוך הערביים-ישראליים"* is identity replacement, not shared-society equality, and `arab-representation`/`focuses-on-arab-israeli-civil-issues` on revision 36's what-a-party-**is** distinction, tested here from the other side. **security +3 and economic NULL both held with nothing new either way** — no sentence on sovereignty, annexation, the West Bank or borders in any of the four reports, so the +3 still rests entirely on the two launch quotes, restated rather than left to look corroborated. **Revision 32's "two false claims" warning is amended, not deleted**: its refutations were checked against the **launch speech** and stand as such, but "the launch speech did not say X" and "the party has no position on X" are different propositions and only the first was verified. **Row still expected-unstable, now with a price on it**: Netanyahu offered all five remaining Likud reserved slots, four above #30, for withdrawal, and Winter refused to take the call (*"אין על מה לדבר"*); סמוטריץ' appealed publicly. **Source-access correction — third instance of the same rule**: `davar1.co.il` is recorded in `services/backend/CLAUDE.md` as 403 and returned **200** on the first try with browser-shaped headers, as `kachollavan.org.il` and `timesofisrael.com` did before it; the note is fixed, and the cost of the wrong belief was coverage, since דבר covers this press conference more fully than the other three outlets |
| 2026-09-04 | revision 42 — **האחדות withdrew from the election and its row was removed**, the first roster change on this page that is neither a rename nor a merge. גלעד ארדן announced it on Friday 2026-09-04, hours after merger talks with כחול לבן collapsed, on the threshold and not on policy: *"התמיכה עד כה... אינה מבטיחה בסבירות גבוהה את מעבר אחוז החסימה, וגם אפשרויות החיבור עם מפלגות נוספות בגוש האחדות אינן מתממשות"*. **`upcoming_parties` 18 → 17 rows** via the same guarded delete revisions 26 and 37 used — `seed_key IS NOT NULL` plus the vote guard — with **no `party_lineage` statement involved at all**, the one respect in which a withdrawal is cheaper than a merge: there is no successor to link to and the row never had a `previous_parties` predecessor either. **The tag and family accounting came out empty, and it was still worth running**: all 21 tags survive on other rows and all three families keep two holders, so unlike revision 37 nothing leaves `i18n.js`, `analytics.js` or `family-strings.csv`. Two tags fall to a single holder — `unity-government` (כחול לבן) and `deregulation` (אל הדגל) — which is fine for a tag and would not be for a family; `statist` 4 → 3 holders, so revision 40's rejection passage is amended from *"all four"* to *"all three"* rather than left asserting a membership that has moved. **The 89-line entry is kept in full**, marked withdrawn at the heading, on the זהות precedent: list submission does not close until the week of 2026-09-07 and Erdan withdrew the candidacy explicitly and not the project. Band tables amended in three places (economic +1, security +2, religiosity −2); no surviving row's axes moved. **Expect more of these before submission closes** — איזנקוט's response was *"ראוי שכל מפלגה על גבול אחוז החסימה תעשה כך"* plus *"אנחנו מכינים הפתעות לשלושת הימים הקרובים"*, aimed at גנץ and טרופר |
| 2026-09-04 | revision 43 — **ש"ס read against a six-outlet corpus of one radio interview** (קול ברמה, 3 September 2026: N12, i24, מעריב, כיפה, ערוץ 14, וואלה). **No axis moved, no tag added, no tag removed, `seed.sql` unchanged** — the third pass on this page to end that way, and the reason is worth recording: everything Deri said was already scored, so the pass converted two tags from inference to first-party statement rather than changing anything. `opposes-core-curriculum` had rested on the funding architecture and a committee bill; it now rests on Deri's own account of ממ"ח as a supervision slippery slope (*"מחר בבוקר יבוא מפקח של משרד החינוך ולאט לאט יכתיבו לך את תוכנית הלימודים, מה ילמדו, מה האידיאולוגיה"*) and on *"זו מלחמת קודש"* to the teachers, so revision 34's *"rather than on rhetoric"* clause is amended in place rather than deleted. `rabbinic-authority-led` gets *"כשהרבנים יחליטו... הם גם יחליטו"*. **`opposes-state-haredi-education` considered and refused** — Deri collapses ממ"ח into לימודי ליבה himself (*"זה נהיה פתאום לימודי ליבה"*), so it would name a mechanism `opposes-core-curriculum` already names and enter as a singleton; **and it is deliberately not extended to יהדות התורה** on Deri's *"גדולי ישראל"*, which would be the classify-from-the-party's-own-sources violation recorded under בית ציוני. **The conscription half goes further than any tag on the row and still earns none**: refusing to call *non-learners* to enlist (*"אני לא צריך לקרוא לזה... שיתמודד"*, *"הצבא לא רוצה חיילים חרדים"*, *"כל השנים זה היה אחיזת עיניים"*, and *"אני לא בדקתי את זה"* about חטיבת החשמונאים) is broader than `scholar-exemption-retained`, but a learners/non-learners split would be a singleton and the `conscription-exemption` family already carries the shape. **religiosity held at +2** — refusing the state's inspector inside your own schools is not a claim on the law of the state, and +3 needs one. **`bloc` bibi held and left closed** although בנט, איזנקוט and ליברמן all responded by excluding Deri from a future government: exclusion by others is not a positive signal from this row, which is the trigger this question was closed with. **Fetching note**: `mako.co.il` returns **400** to WebFetch and `i24news.tv` returns a JavaScript app shell (WebFetch reports the page as having no article text at all); both return the full article to a browser-shaped `curl`, so neither is a missing source |
| 2026-09-04 | revision 44 — **רע"ם: `jewish-arab-partnership` added as tag and family (2 → 3 holders each), no axis moved.** יואב סגלוביץ' — former ניצב, founder of לה"ב 433, head of the police investigations and intelligence branch, then יש עתיד MK and **Deputy Minister of Public Security in the Bennett–Lapid government** — took the **second slot** on Ra'am's list at a Nazareth press conference on **2026-08-31**, the first Jewish candidate in the party's history. **Earned on the standard revision 36 used for הדמוקרטים** ("from the realized list, בשיר at #10") by a stronger instance of it — #2 rather than #10 — plus the leader's own framing: *"כדי לייצר שינוי, צריך שותפות. שותפות אזרחית"*, *"אני לא מחפש מי שדומה לי"*, *"זו לא טובה לערבים"*, and the shared-society argument addressed to Jewish citizens (*"הנשק שיורה היום בטמרה יירה מחר בעפולה... זאת בעיה של המדינה"*). **The counter-argument is recorded because it nearly won**: the linkage is technical and personal (*"אני לא מתחבר לרשימת רע"ם עם סיעה, אני אישית מצטרף"*) with both sides keeping their positions, LGBTQ included. Tagged anyway because **the family's test is shared-society equality, not shared ideology** — which is how הרשימה המשותפת holds it — and because עמך ישראל's refusal three days earlier was for **identity replacement**, a different position rather than a weaker version of the same one. **`sector` stays `arab`** and `focuses-on-arab-israeli-civil-issues` is only reinforced: a Jewish #2 does not change whose constituency a row is. **security −2 held, and a lead deliberately left unscored** — the only statehood content in the corpus is הליכוד's attack, which is a rival's characterisation; a research pass reported Abbas saying at the **2026-08-22** list conference that the State of Palestine exists and calling to end *"the occupation"*, which would be the dated first-party text this entry has wanted since the IDI page was set aside — **it could not be verified** (search budget exhausted) and is not scored on the report. It likely would not reach −3 anyway: −3 needs withdrawal **plus** right of return **plus** dismantling settlements. **A cited source that does not exist**: the JPost article the research pass listed as corroboration returns **404**, so the row rests on ynet, וואלה and דבר. **Two debts restated rather than paid**: the civil-service tag trigger is still undated, and no tag covers crime and personal security in Arab society — not created here because holders would need the הרשימה המשותפת and הדמוקרטים corpora, so it joins the Kaminitz-Law gap queued behind a pass over the two Arab-list rows. **This pass covered one of those two** |
| 2026-09-04 | revision 45 — **עוצמה יהודית published its first programme, ״התנתקות 710״, and nothing moved.** A costed twelve-principle government plan for **voluntary emigration from Gaza** — a dedicated ministry with its own budget and negotiating team, destination-state agreements paid on performance, targets of **250k in year one, 1.11m in three years, 1.86m in seven**, **₪10bn** to stand up inside a **₪50bn** framework — announced as the party's flagship and as *"בראש הדרישות הקואליציוניות שלנו"*. **`security` is already +3, so the most significant document this row has ever published moves no axis** — worth stating rather than hiding, and note what the plan omits: no sovereignty claim, no annexation, no resettlement, so `territorial-control-gaza` gains nothing (this is about the population, not the land). `voluntary-palestinian-emigration-incentives` **held with its evidence upgraded** from drafted legislation (revision 30's "first whose evidence is a bill") to a costed flagship programme. **`population-transfer` refused a fourth time, against the hardest instance yet**: the instrument contains no compulsion (*"הגירה מרצון בלבד... ללא כפייה"*, plus a consenting-destination requirement), and **scale is not the test** even though 1.86m is approximately the whole Strip, nor is rhetoric even though Ben Gvir closes by endorsing גנדי (*"גנדי צדק!"*) — the second opt-in-instrument/transfer-rhetoric pairing on this row, which **strengthens** the instrument test rather than eroding it. Recorded honestly: at this scale the line rests on the programme's own self-description, and a **trigger** is written for the tag — any coercive clause, or a statement that non-leavers will be made to. **economic 0 and `not-economy-focused` confirmed a third time on the largest figure this row has ever published**, a security instrument denominated in shekels (the revision 30 / revision 18 distinction). **`family_evidence` stays `record` and the temptation to flip it is the finding** — the field records what the row's three FAMILIES rest on, and this document evidences none of them; the preamble's "it publishes no platform" is amended in place instead. **Four other posts since revision 30's cutoff read and changed nothing**: a **Druze-sector HQ** (no tag, on the עמך ישראל precedent that a campaign at a minority is what a party *does*, not what it **is**; and `service-conditioned-citizenship` refused a third time — *"מי שנאמן למדינה ב-100%"* is loyalty-conditioned **entitlement**, not a franchise claim), Beit Shemesh weapons-eligibility excluding named נטורי קרתא streets (`gun-rights` figures now 126 localities in 2026 and ~300,000 licences), a Damon Prison visit and a blocked PA event. **Retrieval note**: the site's **WordPress REST API** (`/wp-json/wp/v2/posts?after=…`) enumerates the archive by date in one request — cleaner than revision 30's site search, and the instrument to use next time |
| 2026-09-04 | revision 46 — **ישראל ביתנו: two new documents read, and the pass turned into a gap audit.** **Four tags added (8 → 12)** — `core-curriculum` (6 → 7), `sanctions-on-non-servers` (6 → 7), `arab-civil-service` (4 → 5) and `cost-of-living` (tag 3 → 4, **family 5 → 6**) — **all four sourced from the platform this entry has cited since 2026-07-27**, three of them from the party's own seven קווי יסוד. **The lesson is about the instrument, not the row**: the 2026-08-02 re-verification checked the fifteen claims the entry already made, found one wrong, and could not find what the entry never said. A verification pass and an audit pass are different instruments, and this row had had the first twice and the second never. `core-curriculum` is the sharpest miss — *"חובת לימודי ליבה בכל מוסד חינוך כתנאי לקבלת תמיכה ממשלתית"* is the **funding condition** the −2 band is written around, sitting unrecorded on the row that anchors −3. **`family_evidence` corrected `record` → `platform`**, a plain data error on a row described here as the only one verified against a live primary source; עוצמה יהודית keeps `record` correctly, so the two rows now demonstrate both values for the right reasons. **economic +2 CHALLENGED AND HELD — the closest call on the page.** [ליברמן's economic programme](https://beytenu.org.il/התכנית-הכלכלית-של-אביגדור-ליברמן/) (2026-03-04, modified 2026-06-23, never read before today) is state expansion nearly throughout — 90% LTV mortgages over 40 years, daycare credits, an **expanded negative income tax**, ~30 infrastructure projects on a legislated green track, state guarantees routing institutional money into startups, defence at **8% of GDP** — i.e. the +1 band verbatim, and moving the row would empty +2 above an already-empty +3. Held on ביחד's net-it-out precedent: the withdrawal half is unchanged and current (*"המשך מדיניות ההפרטות... נמל אשדוד ושדה התעופה בחיפה"*, *"צמצום משרדי הממשלה והמגזר הציבורי"*, *"ביטול קצבאות הילדים החל מהילד החמישי"*), the expansion is **service-conditioned and sectoral** rather than universal (*"במקום להמשיך להוציא סכומים עצומים על מגזרים שלא לוקחים חלק בשוק העבודה"*), and the +2 band's text is defined **by this row's own planks**, so moving it would leave the band citing an example no row holds. **Move condition written into the entry.** **religiosity −3 and security +2 unmoved.** **Two refusals**: `service-conditioned-citizenship` — refused for the **fourth** time and from a fourth row, even though the platform conditions *"זכאות לעבודה בשירות המדינה"* on service, because the founding case is Hendel's **franchise** clause; and `state-haredi-education`, since abolishing מוסדות פטור status is a funding condition, not a stream conversion. **The education paper (2026-08-26, written with מועצת התלמידים) was the smallest half** — class sizes, statutory funding for non-formal education, mental-health provision, transport, statutory standing for student councils, and **no religion-and-state content at all**, which is notable precisely because on this page the education paper is normally where the religiosity number lives |
