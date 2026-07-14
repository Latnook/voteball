# Hebrew/English site-wide language mode

Status: approved
Date: 2026-07-14

## Context

The site's UI chrome is English-only while `previous_parties`/`upcoming_parties` names are seeded in
Hebrew only, and `leagues`/`clubs` names are seeded in English only (World Cup countries, European
clubs, and the Israeli Premier League clubs are all stored under their English/transliterated names
today). There is no language concept anywhere in the stack — no toggle, no per-language storage, no
RTL handling, no UI string dictionary.

This adds a real bilingual mode: a Hebrew/English toggle that switches both the UI chrome (labels,
buttons, headings, error messages) and every league/club/party name, with full RTL layout in Hebrew
mode. Default language is auto-detected from `navigator.language` on first visit and then persisted
per-browser.

## Decisions

1. **Two columns per table, not a separate translations table or a frontend-only dictionary.**
   `name_en`/`name_he` on `leagues`, `clubs`, `previous_parties`, `upcoming_parties`, replacing the
   single `name` column. Matches the existing flat-table style; a generic `(entity_type, entity_id,
   lang, name)` translations table is more machinery than two fixed languages across four fixed
   tables needs, and a frontend-only dictionary would decouple translation maintenance from the admin
   party-CRUD workflow (an admin adding a party through `admin.html` must get both names immediately,
   not after a separate JS-file edit and redeploy).
2. **Two-commit migration**, since the backend reruns `schema.sql`+`seed.sql` on every pod boot (the
   only schema-change mechanism this app has — see `db.py`'s `init_db`) against a live RDS that
   already holds real votes referencing party/club IDs by FK:
   - **Commit A (this feature)**: `ALTER TABLE ... ADD COLUMN IF NOT EXISTS name_en/name_he` (nullable)
     on all four tables, idempotent backfill `UPDATE`s that copy the existing `name` value into
     whichever language column it already represents, and `seed.sql` `UPDATE`s that fill in the
     *other* language for every currently-seeded row, keyed by the language already present (no new
     rows, no ID churn). The legacy `name` column and its `UNIQUE` constraint are left untouched.
   - **Commit B (follow-up, after Commit A is deployed and the live DB verified fully backfilled)**:
     add `NOT NULL` + `UNIQUE(name_en)`/`UNIQUE(name_he)` (and `UNIQUE(league_id, name_en/he)` for
     `clubs`), drop `name`, and delete the now-dead backfill statements. Not part of this plan's
     scope — tracked as a follow-up once Commit A is confirmed live.
3. **Every league/club gets both names**, not just the Israeli Premier League. See the Translation
   content section — the full set (World Cup countries, UCL/EPL/La Liga/Serie A/Bundesliga clubs, the
   7 league/competition names, and all Israeli clubs) has been translated and user-reviewed.
4. **Full UI translation**, not just entity names — headings, buttons, form labels, and error messages
   across `index.html`, `results.html`, and `admin.html` all get Hebrew versions via a shared string
   dictionary.
5. **Full RTL layout in Hebrew mode** — `dir="rtl"` on `<html>`, mirrored form/table layout — not just
   Hebrew text in a left-to-right shell.
6. **No page reload on toggle.** Switching language re-renders in place using already-fetched data
   (see Frontend mechanism) so in-progress form state (selected dropdown, checked boxes, an open admin
   rename input) survives the switch.
7. **Default language: auto-detected from `navigator.language`** on first visit (`he*` → Hebrew,
   anything else → English), then persisted in `localStorage` so the choice sticks across visits and
   pages. The toggle always lets a visitor override it.
8. **Duplicate-name admin errors name the colliding language** (e.g. "a party with this English name
   already exists" vs. "...Hebrew name...") rather than a single generic message, since the admin now
   edits two independent unique fields per party and needs to know which one collided.
9. **No admin UI for leagues/clubs** — unchanged from today; those stay seed-only, translated once as
   static content, not exposed to the admin party-CRUD workflow.

## Data model

```sql
-- schema.sql, Commit A: additive only, all four tables get the same shape
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS name_he TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS name_he TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS name_he TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS name_he TEXT;

-- Backfill: `leagues`/`clubs` were always seeded in English; `previous_parties`/`upcoming_parties`
-- were always seeded in Hebrew. No-ops once already backfilled or once `name` is eventually dropped
-- in Commit B (guarded so Commit A stays safe to rerun indefinitely, matching this file's existing
-- rerun-every-boot convention).
UPDATE leagues           SET name_en = name WHERE name_en IS NULL;
UPDATE clubs              SET name_en = name WHERE name_en IS NULL;
UPDATE previous_parties  SET name_he = name WHERE name_he IS NULL;
UPDATE upcoming_parties  SET name_he = name WHERE name_he IS NULL;
```

`seed.sql` then adds the *other* language for every existing row via `UPDATE ... SET name_he = 'X'
WHERE name_en = 'Y' AND name_he IS NULL` (leagues/clubs) or `UPDATE ... SET name_en = 'X' WHERE
name_he = 'Y' AND name_en IS NULL` (parties) for each row in the Translation content section below,
and inserts any brand-new rows (e.g. the Joint List — see below) with both columns populated directly.
`ON CONFLICT` targets on the `INSERT` statements move from `(name)`/`(league_id, name)` to
`(name_en)`/`(league_id, name_en)` (arbitrary but consistent choice of which column anchors
conflict detection, since both are unique-once-backfilled).

## Backend

`queries.py`:

- `get_options()`: all four `SELECT`s add `name_en, name_he` and drop `name`; returned dicts carry
  both fields, e.g. `{'id': 1, 'name_en': 'Likud', 'name_he': 'הליכוד'}`.
- `create_previous_party`/`rename_previous_party`/`create_upcoming_party`/`rename_upcoming_party` take
  `name_en, name_he` instead of `name`. On `psycopg2.errors.UniqueViolation`, inspect
  `err.diag.constraint_name` (`..._name_en_key` vs `..._name_he_key`) to raise a
  `DuplicatePartyNameError` carrying which language collided.
- No change to `insert_vote`, `get_results_by_*`, `get_votes`, delete/reassign/count functions — all
  operate on IDs only.

`app.py`:

- The four party create/rename routes read `name_en`/`name_he` from the request body (400 if either is
  blank after `.strip()`), and turn the two `DuplicatePartyNameError` variants into
  `jsonify({'error': 'a party with this English name already exists'})` / `'...Hebrew name...'`, 409.
- No change to `/api/vote`, `/api/results`, or any other route.

## Admin UI (`admin.html`/`admin.js`)

- Add-party and rename forms for both party tabs get two inputs (English name, Hebrew name — the
  Hebrew input gets `dir="rtl"`) instead of one; `addParty`/`startRename` send `{name_en, name_he}`.
- Party list rows, the reassign-target `<select>`, and the votes table's party/league/club lookups
  switch from `party.name` to a `localizedName(entity)` helper (see below) driven by the admin panel's
  own language toggle.
- Duplicate-name errors surface the backend's language-specific message directly — no extra frontend
  logic.

## Frontend i18n mechanism (shared across `index.html`, `results.html`, `admin.html`)

New shared `i18n.js`, included on all three pages before the page-specific script:

- An `en`/`he` string dictionary for UI chrome (headings, labels, buttons, error messages) and a
  `t(key)` lookup.
- `localizedName(entity)` — returns `entity.name_en` or `entity.name_he` based on current language;
  used everywhere `.name` is read today across `vote.js`, `results.js`, `admin.js`.
- Language state in `localStorage` (`voteballLang`), auto-detected from `navigator.language` on first
  visit (Decision 7).
- `setLang(lang)` — writes storage, sets `document.documentElement.lang`/`dir`, and dispatches a
  `voteball:langchange` event instead of reloading.
- A first-paint inline `<script>` in each page's `<head>` (before `style.css` loads) reads
  storage/detects language and sets `lang`/`dir` on `<html>` immediately, avoiding a flash of
  wrong-direction content before `i18n.js` itself loads.
- A toggle ("EN | עב") in the header of all three pages calls `setLang()`.

**No-reload re-render (Decision 6):** every page already keeps its fetched data in memory
(`optionsData`, and `results.js` gains a small cache of its last-rendered rows). On
`voteball:langchange`, each page re-invokes its own existing render functions against that cached
data — no network refetch for pure relabeling. To avoid destroying in-progress form/selection state,
entity-bearing DOM elements (`<option>`, checkbox/radio labels, table cells, party rows) carry
`data-entity-type`/`data-entity-id`, and the langchange handler relabels them **in place** via
`localizedName()` rather than rebuilding the DOM (relabeling an `<option>`'s `textContent` doesn't
reset its parent `<select>`'s selected value; relabeling a checkbox's label text node doesn't uncheck
it). Static chrome text uses `data-i18n="key"` and is reapplied the same way.

**RTL styling:** `style.css` gets targeted `[dir="rtl"]` overrides for the layout-sensitive spots —
results bar labels/alignment (`.bar-label`, `.bar-count`), votes table `text-align`, form label flow.
`system-ui` already covers Hebrew glyphs on every target platform — no font/CDN dependency.

## Translation content

Reviewed and corrected by the user (2026-07-14). This is the authoritative source for the `UPDATE`/
`INSERT` statements in `seed.sql` — English is `name_en`, Hebrew is `name_he`.

### Leagues

| name_en | name_he |
|---|---|
| World Cup 2026 | מונדיאל 2026 |
| UCL | ליגת האלופות |
| EPL | הפרמייר ליג |
| La Liga | לה ליגה |
| Serie A | סרייה A |
| Bundesliga | הבונדסליגה |
| Israeli Premier League | ליגת העל |

### World Cup 2026 — countries (clubs table, league = World Cup 2026)

Brazil/ברזיל, Argentina/ארגנטינה, France/צרפת, England/אנגליה, Spain/ספרד, Germany/גרמניה,
Portugal/פורטוגל, Netherlands/הולנד, Italy/איטליה, Belgium/בלגיה, Croatia/קרואטיה, Uruguay/אורוגוואי,
Colombia/קולומביה, Mexico/מקסיקו, USA/ארה"ב, Canada/קנדה, Japan/יפן, South Korea/דרום קוריאה,
Morocco/מרוקו, Senegal/סנגל, Nigeria/ניגריה, Ghana/גאנה, Egypt/מצרים, Tunisia/תוניסיה,
Algeria/אלג'יריה, Ivory Coast/חוף השנהב, Cameroon/קמרון, Australia/אוסטרליה, Iran/איראן,
Saudi Arabia/ערב הסעודית, Qatar/קטאר, Ecuador/אקוודור, Chile/צ'ילה, Peru/פרו, Poland/פולין,
Switzerland/שווייץ, Denmark/דנמרק, Sweden/שוודיה, Serbia/סרביה, Israel/ישראל

### UCL clubs

Real Madrid/ריאל מדריד, Manchester City/מנצ'סטר סיטי, Bayern Munich/באיירן מינכן, Barcelona/ברצלונה,
Liverpool/ליברפול, Paris Saint-Germain/פריז סן ז'רמן, Inter Milan/אינטר מילאן, Juventus/יובנטוס,
Manchester United/מנצ'סטר יונייטד, Chelsea/צ'לסי, Arsenal/ארסנל, AC Milan/מילאן,
Atletico Madrid/אתלטיקו מדריד, Borussia Dortmund/בורוסיה דורטמונד, Napoli/נאפולי, Porto/פורטו,
Benfica/בנפיקה, Ajax/אייאקס

### EPL clubs

Arsenal/ארסנל, Aston Villa/אסטון וילה, Bournemouth/בורנמות', Brentford/ברנטפורד,
Brighton & Hove Albion/ברייטון והוב אלביון, Chelsea/צ'לסי, Crystal Palace/קריסטל פאלאס,
Everton/אברטון, Fulham/פולהאם, Ipswich Town/איפסוויץ' טאון, Leicester City/לסטר סיטי,
Liverpool/ליברפול, Manchester City/מנצ'סטר סיטי, Manchester United/מנצ'סטר יונייטד,
Newcastle United/ניוקאסל יונייטד, Nottingham Forest/נוטינגהאם פורסט, Southampton/סאות'המפטון,
Tottenham Hotspur/טוטנהאם הוטספר, West Ham United/ווסט האם יונייטד,
Wolverhampton Wanderers/וולברהמפטון וונדררס

### La Liga clubs

Real Madrid/ריאל מדריד, Barcelona/ברצלונה, Atletico Madrid/אתלטיקו מדריד,
Athletic Bilbao/אתלטיק בילבאו, Real Sociedad/ריאל סוסיאדד, Real Betis/ריאל בטיס,
Villarreal/ויאריאל, Valencia/ולנסיה, Sevilla/סביליה, Girona/ז'ירונה, Osasuna/אוססונה,
Celta Vigo/סלטה ויגו, Rayo Vallecano/ראיו ואייקאנו, Getafe/חטאפה, Las Palmas/לאס פלמאס,
Alaves/אלאבס, Espanyol/אספניול, Leganes/לגאנס, Mallorca/מיורקה, Valladolid/ויאדוליד

### Serie A clubs

Inter Milan/אינטר מילאן, AC Milan/מילאן, Juventus/יובנטוס, Napoli/נאפולי, Roma/רומא, Lazio/לאציו,
Atalanta/אטלנטה, Fiorentina/פיורנטינה, Bologna/בולוניה, Torino/טורינו, Udinese/אודינזה,
Genoa/ג'נואה, Cagliari/קליארי, Verona/ורונה, Lecce/לצ'ה, Parma/פארמה, Como/קומו, Venezia/ונציה,
Empoli/אמפולי, Monza/מונצה

### Bundesliga clubs

Bayern Munich/באיירן מינכן, Borussia Dortmund/בורוסיה דורטמונד, RB Leipzig/לייפציג,
Bayer Leverkusen/באייר לברקוזן, Eintracht Frankfurt/איינטרכט פרנקפורט, VfB Stuttgart/שטוטגרט,
Borussia Monchengladbach/בורוסיה מנשנגלדבך, SC Freiburg/פרייבורג, Werder Bremen/וורדר ברמן,
Union Berlin/אוניון ברלין, Mainz 05/מיינץ 05, Wolfsburg/וולפסבורג, Hoffenheim/הופנהיים,
FC Augsburg/אוגסבורג, VfL Bochum/בוכום, FC Heidenheim/היידנהיים, Holstein Kiel/הולשטיין קיל,
St. Pauli/זנקט פאולי

### Israeli Premier League clubs

Maccabi Haifa/מכבי חיפה, Maccabi Tel Aviv/מכבי תל אביב, Hapoel Beer Sheva/הפועל באר שבע,
Hapoel Tel Aviv/הפועל תל אביב, Beitar Jerusalem/בית"ר ירושלים, Maccabi Netanya/מכבי נתניה,
Hapoel Haifa/הפועל חיפה, Bnei Sakhnin/בני סכנין, Ashdod/מ.ס. אשדוד, Hapoel Jerusalem/הפועל ירושלים,
Kiryat Shmona/עירוני קריית שמונה, Maccabi Bnei Reineh/מכבי בני ריינה,
Hapoel Petah Tikva/הפועל פתח תקווה, Hapoel Kfar Saba/הפועל כפר סבא

### Previous Knesset parties (existing rows — `name_he` is the current `name`, `name_en` is new)

Likud/הליכוד, Yesh Atid/יש עתיד, Religious Zionist Party/הציונות הדתית,
National Unity/המחנה הממלכתי, Yisrael Beiteinu/ישראל ביתנו, Shas/ש"ס,
United Torah Judaism/יהדות התורה, Ra'am/רע"ם, Hadash-Ta'al/חד"ש-תע"ל, Labor/העבודה, Meretz/מרצ,
Balad/בל"ד, Jewish Home/הבית היהודי, Other/אחר

### Upcoming election parties (existing rows, `name_en` new, **plus one new row**)

Likud/הליכוד, Yesh/ישר, Yachad/ביחד, The Democrats/הדמוקרטים, Blue and White/כחול לבן,
Yisrael Beiteinu/ישראל ביתנו, Religious Zionist Party/הציונות הדתית, Otzma Yehudit/עוצמה יהודית,
Hadash-Ta'al/חד"ש-תע"ל, Balad/בל"ד, The Economic Party/המפלגה הכלכלית, El HaDegel/אל הדגל,
The Reservists/המילואימניקים

**New row (Decision 3 / user request):** The Joint List/הרשימה המשותפת — inserted directly with both
columns populated (not a backfill target, since it doesn't exist in today's seed data). Added to
`upcoming_parties` only; `previous_parties` reflects the current Knesset's actual composition, in
which Hadash-Ta'al and Balad ran separately, so no matching entry belongs there.

## Testing

Backend (`tests/test_app.py`, `tests/test_queries.py`):

- `get_options` returns `name_en`/`name_he` (not `name`) for all four entity types.
- Party create/rename require both `name_en` and `name_he` (400 if either is blank).
- Duplicate-name collisions on `name_en` vs. `name_he` each produce the correct language-specific 409
  message.
- Existing reassign/delete-guard/vote tests continue to pass unchanged (they operate on IDs, not
  names).
- `conftest.py`'s `DROP TABLE ... CASCADE` list and any fixture data that seeds parties/clubs by
  `name` get updated to the two-column shape.

Frontend: no automated suite (per `CLAUDE.md`) — verified manually by driving all three pages in a
browser:

- First visit in a Hebrew-locale browser defaults to Hebrew + RTL; English-locale defaults to English
  + LTR; the toggle overrides either and persists across page navigations within the same browser.
- Every party/club/league name displays correctly in both languages on `index.html`, `results.html`,
  and `admin.html`.
- Switching language mid-form (a league selected, some checkboxes checked) preserves that state —
  only the labels change.
- Admin add/rename requires both names; a duplicate on just the English or just the Hebrew name shows
  the correct language-specific error.
- RTL layout looks correct (not just mirrored text) on all three pages: form fields, results bars,
  votes table.

## Non-goals

- Commit B (dropping the legacy `name` column, adding `NOT NULL`/`UNIQUE` on the new columns) — a
  separate follow-up once Commit A is live and the production DB is confirmed fully backfilled.
- Any language beyond Hebrew/English.
- Admin UI for leagues/clubs (unchanged — still seed-only).
- Per-user server-side language preference (e.g. tied to the `voteball_token` cookie) — the toggle is
  purely a `localStorage` client preference.
- Translating the worker's SNS alert text or any other non-UI-facing string.
