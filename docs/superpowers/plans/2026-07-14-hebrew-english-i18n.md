# Hebrew/English Site-Wide Language Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Hebrew/English language toggle to Voteball that translates every UI string and every league/club/party name, with full RTL layout in Hebrew mode, backed by a `name_en`/`name_he` schema migration that's safe to run against the live production database.

**Architecture:** `leagues`, `clubs`, `previous_parties`, `upcoming_parties` each gain `name_en`/`name_he` columns (backfilled from the legacy `name` column, translated via `seed.sql`, protected by partial unique indexes) alongside the untouched legacy `name` column. The Flask backend (`queries.py`/`app.py`) serves and accepts both language fields instead of one. The frontend (plain HTML/CSS/vanilla JS, no build step) gets a shared `i18n.js` — a string dictionary, a `localizedName()` helper, `localStorage`-backed language state, and a toggle that re-renders in place (no page reload) via each page's existing render functions.

**Tech Stack:** Flask 3.1 + psycopg2 (backend), Postgres 17, plain HTML/CSS/vanilla JS (frontend, no build step), pytest (backend tests only — no frontend test runner in this project).

## Global Constraints

- Postgres connections use `sslmode=require` in production, `disable` in tests (existing `DB_SSLMODE` env var — unchanged by this plan).
- Every backend route acquires its own `psycopg2` connection via `db.get_db()` and must `conn.close()` on every exit path via `try/finally` (existing pattern — preserved in all edits).
- Query functions that mutate data must `conn.rollback()` in a broad `except` before re-raising (existing pattern — preserved).
- Admin routes stay behind the existing `require_admin` decorator — no auth changes in this plan.
- Frontend renders all backend-derived and admin-entered names via `createElement`/`textContent`, never `innerHTML` string interpolation (existing XSS posture — preserved in every new/modified render function).
- No build step for the frontend — every file is served as-is by nginx.
- `schema.sql` + `seed.sql` are rerun by the backend on every pod boot (`db.py`'s `init_db`) — every SQL statement in Task 1 must be idempotent (safe to execute repeatedly with no cumulative effect after the first run).
- Design reference: `docs/superpowers/specs/2026-07-14-hebrew-english-i18n-design.md` — read it if any task instruction here seems to conflict with it; this plan implements only that spec's Commit A (the `NOT NULL`/`UNIQUE` upgrade and legacy `name` column drop is Commit B, explicitly out of scope — see that spec's Non-goals).

All SQL in Task 1 has already been executed end-to-end against a throwaway Postgres 17 container during planning (clean run, zero remaining NULLs, correct row counts, duplicate-detection confirmed working, a second rerun is a verified no-op) — the exact statements below are what was tested, not a fresh draft.

---

## Task 1: Schema + seed data migration

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/schema.sql`
- Modify: `ansible-project/roles/backend/files/backend/seed.sql`
- Test: `ansible-project/roles/backend/files/backend/tests/test_migration.py` (new)

**Interfaces:**
- Produces: `leagues`, `clubs`, `previous_parties`, `upcoming_parties` each have nullable `name_en TEXT`, `name_he TEXT` columns, fully populated for every seeded row, plus partial unique indexes `<table>_name_en_uidx` / `<table>_name_he_uidx` (and `clubs_league_name_en_uidx` / `clubs_league_name_he_uidx`, scoped by `league_id`) enforcing uniqueness among non-NULL values. The legacy `name` column is untouched and still `NOT NULL UNIQUE`. Later tasks consume `name_en`/`name_he` via `queries.py`.

- [ ] **Step 1: Replace `schema.sql` with the migrated version**

Overwrite `ansible-project/roles/backend/files/backend/schema.sql` with:

```sql
CREATE TABLE IF NOT EXISTS leagues (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS clubs (
    id SERIAL PRIMARY KEY,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    name TEXT NOT NULL,
    UNIQUE (league_id, name)
);

CREATE TABLE IF NOT EXISTS previous_parties (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS upcoming_parties (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Hebrew/English bilingual names (docs/superpowers/specs/2026-07-14-hebrew-english-i18n-design.md).
-- Purely structural here — no data touched. All backfill lives in seed.sql, ordered after its
-- existing INSERTs, because on a fresh/restored-empty database there are zero rows at this point
-- for a schema.sql-level backfill to touch.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS name_he TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS name_he TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS name_he TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS name_he TEXT;

-- Partial unique indexes: enforce uniqueness only among rows that already have a value, so this
-- can't fail at deploy time on account of a not-yet-backfilled row (e.g. a party added through the
-- admin UI after seed.sql was last updated).
CREATE UNIQUE INDEX IF NOT EXISTS previous_parties_name_en_uidx ON previous_parties (name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS previous_parties_name_he_uidx ON previous_parties (name_he) WHERE name_he IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS upcoming_parties_name_en_uidx ON upcoming_parties (name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS upcoming_parties_name_he_uidx ON upcoming_parties (name_he) WHERE name_he IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS leagues_name_en_uidx ON leagues (name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS leagues_name_he_uidx ON leagues (name_he) WHERE name_he IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_league_name_en_uidx ON clubs (league_id, name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_league_name_he_uidx ON clubs (league_id, name_he) WHERE name_he IS NOT NULL;

CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    club_id INTEGER REFERENCES clubs(id),
    previous_vote_status TEXT NOT NULL CHECK (previous_vote_status IN ('voted', 'did_not_vote')),
    previous_party_id INTEGER REFERENCES previous_parties(id),
    upcoming_vote_status TEXT NOT NULL CHECK (upcoming_vote_status IN ('considering', 'undecided')),
    cookie_token TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS vote_upcoming_parties (
    vote_id INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id) ON DELETE CASCADE,
    PRIMARY KEY (vote_id, upcoming_party_id)
);

CREATE TABLE IF NOT EXISTS alert_state (
    id INTEGER PRIMARY KEY DEFAULT 1,
    last_seen_total INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT single_row CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS rollup_previous (
    league_id INTEGER NOT NULL,
    club_id INTEGER,
    previous_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_league_club ON rollup_previous (league_id, club_id);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_party ON rollup_previous (previous_party_id);

CREATE TABLE IF NOT EXISTS rollup_upcoming (
    league_id INTEGER NOT NULL,
    club_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_upcoming_league_club ON rollup_upcoming (league_id, club_id);
CREATE INDEX IF NOT EXISTS idx_rollup_upcoming_party ON rollup_upcoming (upcoming_party_id);

CREATE TABLE IF NOT EXISTS rollup_previous_upcoming (
    previous_party_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_previous ON rollup_previous_upcoming (previous_party_id);
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_upcoming ON rollup_previous_upcoming (upcoming_party_id);
```

- [ ] **Step 2: Replace `seed.sql` with the migrated version**

Overwrite `ansible-project/roles/backend/files/backend/seed.sql` with:

```sql
INSERT INTO alert_state (id, last_seen_total) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;

INSERT INTO leagues (name) VALUES
    ('World Cup 2026'), ('UCL'), ('EPL'), ('La Liga'), ('Serie A'), ('Bundesliga'), ('Israeli Premier League')
ON CONFLICT (name) DO NOTHING;

INSERT INTO clubs (league_id, name)
SELECT l.id, c.name FROM leagues l
JOIN (VALUES
    ('World Cup 2026', 'Brazil'), ('World Cup 2026', 'Argentina'), ('World Cup 2026', 'France'),
    ('World Cup 2026', 'England'), ('World Cup 2026', 'Spain'), ('World Cup 2026', 'Germany'),
    ('World Cup 2026', 'Portugal'), ('World Cup 2026', 'Netherlands'), ('World Cup 2026', 'Italy'),
    ('World Cup 2026', 'Belgium'), ('World Cup 2026', 'Croatia'), ('World Cup 2026', 'Uruguay'),
    ('World Cup 2026', 'Colombia'), ('World Cup 2026', 'Mexico'), ('World Cup 2026', 'USA'),
    ('World Cup 2026', 'Canada'), ('World Cup 2026', 'Japan'), ('World Cup 2026', 'South Korea'),
    ('World Cup 2026', 'Morocco'), ('World Cup 2026', 'Senegal'), ('World Cup 2026', 'Nigeria'),
    ('World Cup 2026', 'Ghana'), ('World Cup 2026', 'Egypt'), ('World Cup 2026', 'Tunisia'),
    ('World Cup 2026', 'Algeria'), ('World Cup 2026', 'Ivory Coast'), ('World Cup 2026', 'Cameroon'),
    ('World Cup 2026', 'Australia'), ('World Cup 2026', 'Iran'), ('World Cup 2026', 'Saudi Arabia'),
    ('World Cup 2026', 'Qatar'), ('World Cup 2026', 'Ecuador'), ('World Cup 2026', 'Chile'),
    ('World Cup 2026', 'Peru'), ('World Cup 2026', 'Poland'), ('World Cup 2026', 'Switzerland'),
    ('World Cup 2026', 'Denmark'), ('World Cup 2026', 'Sweden'), ('World Cup 2026', 'Serbia'),
    ('World Cup 2026', 'Israel'),

    ('UCL', 'Real Madrid'), ('UCL', 'Manchester City'), ('UCL', 'Bayern Munich'),
    ('UCL', 'Barcelona'), ('UCL', 'Liverpool'), ('UCL', 'Paris Saint-Germain'),
    ('UCL', 'Inter Milan'), ('UCL', 'Juventus'), ('UCL', 'Manchester United'),
    ('UCL', 'Chelsea'), ('UCL', 'Arsenal'), ('UCL', 'AC Milan'),
    ('UCL', 'Atletico Madrid'), ('UCL', 'Borussia Dortmund'), ('UCL', 'Napoli'),
    ('UCL', 'Porto'), ('UCL', 'Benfica'), ('UCL', 'Ajax'),

    ('EPL', 'Arsenal'), ('EPL', 'Aston Villa'), ('EPL', 'Bournemouth'),
    ('EPL', 'Brentford'), ('EPL', 'Brighton & Hove Albion'), ('EPL', 'Chelsea'),
    ('EPL', 'Crystal Palace'), ('EPL', 'Everton'), ('EPL', 'Fulham'),
    ('EPL', 'Ipswich Town'), ('EPL', 'Leicester City'), ('EPL', 'Liverpool'),
    ('EPL', 'Manchester City'), ('EPL', 'Manchester United'), ('EPL', 'Newcastle United'),
    ('EPL', 'Nottingham Forest'), ('EPL', 'Southampton'), ('EPL', 'Tottenham Hotspur'),
    ('EPL', 'West Ham United'), ('EPL', 'Wolverhampton Wanderers'),

    ('La Liga', 'Real Madrid'), ('La Liga', 'Barcelona'), ('La Liga', 'Atletico Madrid'),
    ('La Liga', 'Athletic Bilbao'), ('La Liga', 'Real Sociedad'), ('La Liga', 'Real Betis'),
    ('La Liga', 'Villarreal'), ('La Liga', 'Valencia'), ('La Liga', 'Sevilla'),
    ('La Liga', 'Girona'), ('La Liga', 'Osasuna'), ('La Liga', 'Celta Vigo'),
    ('La Liga', 'Rayo Vallecano'), ('La Liga', 'Getafe'), ('La Liga', 'Las Palmas'),
    ('La Liga', 'Alaves'), ('La Liga', 'Espanyol'), ('La Liga', 'Leganes'),
    ('La Liga', 'Mallorca'), ('La Liga', 'Valladolid'),

    ('Serie A', 'Inter Milan'), ('Serie A', 'AC Milan'), ('Serie A', 'Juventus'),
    ('Serie A', 'Napoli'), ('Serie A', 'Roma'), ('Serie A', 'Lazio'),
    ('Serie A', 'Atalanta'), ('Serie A', 'Fiorentina'), ('Serie A', 'Bologna'),
    ('Serie A', 'Torino'), ('Serie A', 'Udinese'), ('Serie A', 'Genoa'),
    ('Serie A', 'Cagliari'), ('Serie A', 'Verona'), ('Serie A', 'Lecce'),
    ('Serie A', 'Parma'), ('Serie A', 'Como'), ('Serie A', 'Venezia'),
    ('Serie A', 'Empoli'), ('Serie A', 'Monza'),

    ('Bundesliga', 'Bayern Munich'), ('Bundesliga', 'Borussia Dortmund'), ('Bundesliga', 'RB Leipzig'),
    ('Bundesliga', 'Bayer Leverkusen'), ('Bundesliga', 'Eintracht Frankfurt'), ('Bundesliga', 'VfB Stuttgart'),
    ('Bundesliga', 'Borussia Monchengladbach'), ('Bundesliga', 'SC Freiburg'), ('Bundesliga', 'Werder Bremen'),
    ('Bundesliga', 'Union Berlin'), ('Bundesliga', 'Mainz 05'), ('Bundesliga', 'Wolfsburg'),
    ('Bundesliga', 'Hoffenheim'), ('Bundesliga', 'FC Augsburg'), ('Bundesliga', 'VfL Bochum'),
    ('Bundesliga', 'FC Heidenheim'), ('Bundesliga', 'Holstein Kiel'), ('Bundesliga', 'St. Pauli'),

    ('Israeli Premier League', 'Maccabi Haifa'), ('Israeli Premier League', 'Maccabi Tel Aviv'),
    ('Israeli Premier League', 'Hapoel Beer Sheva'), ('Israeli Premier League', 'Hapoel Tel Aviv'),
    ('Israeli Premier League', 'Beitar Jerusalem'), ('Israeli Premier League', 'Maccabi Netanya'),
    ('Israeli Premier League', 'Hapoel Haifa'), ('Israeli Premier League', 'Bnei Sakhnin'),
    ('Israeli Premier League', 'Ashdod'), ('Israeli Premier League', 'Hapoel Jerusalem'),
    ('Israeli Premier League', 'Kiryat Shmona'), ('Israeli Premier League', 'Maccabi Bnei Reineh'),
    ('Israeli Premier League', 'Hapoel Petah Tikva'), ('Israeli Premier League', 'Hapoel Kfar Saba')
) AS c(league_name, name) ON l.name = c.league_name
ON CONFLICT (league_id, name) DO NOTHING;

INSERT INTO previous_parties (name) VALUES
    ('הליכוד'), ('יש עתיד'), ('הציונות הדתית'), ('המחנה הממלכתי'),
    ('ישראל ביתנו'), ('ש"ס'), ('יהדות התורה'), ('רע"ם'),
    ('חד"ש-תע"ל'), ('העבודה'), ('מרצ'), ('בל"ד'), ('הבית היהודי'), ('אחר')
ON CONFLICT (name) DO NOTHING;

INSERT INTO upcoming_parties (name) VALUES
    ('הליכוד'), ('ישר'), ('ביחד'), ('הדמוקרטים'), ('כחול לבן'),
    ('ישראל ביתנו'), ('הציונות הדתית'), ('עוצמה יהודית'), ('חד"ש-תע"ל'),
    ('בל"ד'), ('המפלגה הכלכלית'), ('אל הדגל'), ('המילואימניקים')
ON CONFLICT (name) DO NOTHING;

-- Backfill each row's own language from the legacy `name` column.
UPDATE leagues           SET name_en = name WHERE name_en IS NULL;
UPDATE clubs             SET name_en = name WHERE name_en IS NULL;
UPDATE previous_parties  SET name_he = name WHERE name_he IS NULL;
UPDATE upcoming_parties  SET name_he = name WHERE name_he IS NULL;

-- Leagues
UPDATE leagues SET name_he = 'מונדיאל 2026' WHERE name_en = 'World Cup 2026' AND name_he IS NULL;
UPDATE leagues SET name_he = 'ליגת האלופות' WHERE name_en = 'UCL' AND name_he IS NULL;
UPDATE leagues SET name_he = 'הפרמייר ליג' WHERE name_en = 'EPL' AND name_he IS NULL;
UPDATE leagues SET name_he = 'לה ליגה' WHERE name_en = 'La Liga' AND name_he IS NULL;
UPDATE leagues SET name_he = 'סרייה A' WHERE name_en = 'Serie A' AND name_he IS NULL;
UPDATE leagues SET name_he = 'הבונדסליגה' WHERE name_en = 'Bundesliga' AND name_he IS NULL;
UPDATE leagues SET name_he = 'ליגת העל' WHERE name_en = 'Israeli Premier League' AND name_he IS NULL;

-- World Cup 2026 countries
UPDATE clubs SET name_he = 'ברזיל' WHERE name_en = 'Brazil' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארגנטינה' WHERE name_en = 'Argentina' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צרפת' WHERE name_en = 'France' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אנגליה' WHERE name_en = 'England' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ספרד' WHERE name_en = 'Spain' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גרמניה' WHERE name_en = 'Germany' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פורטוגל' WHERE name_en = 'Portugal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הולנד' WHERE name_en = 'Netherlands' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איטליה' WHERE name_en = 'Italy' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בלגיה' WHERE name_en = 'Belgium' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קרואטיה' WHERE name_en = 'Croatia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אורוגוואי' WHERE name_en = 'Uruguay' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קולומביה' WHERE name_en = 'Colombia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מקסיקו' WHERE name_en = 'Mexico' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארה"ב' WHERE name_en = 'USA' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קנדה' WHERE name_en = 'Canada' AND name_he IS NULL;
UPDATE clubs SET name_he = 'יפן' WHERE name_en = 'Japan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'דרום קוריאה' WHERE name_en = 'South Korea' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מרוקו' WHERE name_en = 'Morocco' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סנגל' WHERE name_en = 'Senegal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ניגריה' WHERE name_en = 'Nigeria' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גאנה' WHERE name_en = 'Ghana' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מצרים' WHERE name_en = 'Egypt' AND name_he IS NULL;
UPDATE clubs SET name_he = 'תוניסיה' WHERE name_en = 'Tunisia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלג''יריה' WHERE name_en = 'Algeria' AND name_he IS NULL;
UPDATE clubs SET name_he = 'חוף השנהב' WHERE name_en = 'Ivory Coast' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קמרון' WHERE name_en = 'Cameroon' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוסטרליה' WHERE name_en = 'Australia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איראן' WHERE name_en = 'Iran' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ערב הסעודית' WHERE name_en = 'Saudi Arabia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קטאר' WHERE name_en = 'Qatar' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אקוודור' WHERE name_en = 'Ecuador' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צ''ילה' WHERE name_en = 'Chile' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרו' WHERE name_en = 'Peru' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פולין' WHERE name_en = 'Poland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שווייץ' WHERE name_en = 'Switzerland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'דנמרק' WHERE name_en = 'Denmark' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שוודיה' WHERE name_en = 'Sweden' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סרביה' WHERE name_en = 'Serbia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ישראל' WHERE name_en = 'Israel' AND name_he IS NULL;

-- UCL clubs
UPDATE clubs SET name_he = 'ריאל מדריד' WHERE name_en = 'Real Madrid' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מנצ''סטר סיטי' WHERE name_en = 'Manchester City' AND name_he IS NULL;
UPDATE clubs SET name_he = 'באיירן מינכן' WHERE name_en = 'Bayern Munich' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברצלונה' WHERE name_en = 'Barcelona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ליברפול' WHERE name_en = 'Liverpool' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פריז סן ז''רמן' WHERE name_en = 'Paris Saint-Germain' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אינטר מילאן' WHERE name_en = 'Inter Milan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'יובנטוס' WHERE name_en = 'Juventus' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מנצ''סטר יונייטד' WHERE name_en = 'Manchester United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צ''לסי' WHERE name_en = 'Chelsea' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארסנל' WHERE name_en = 'Arsenal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מילאן' WHERE name_en = 'AC Milan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אתלטיקו מדריד' WHERE name_en = 'Atletico Madrid' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורוסיה דורטמונד' WHERE name_en = 'Borussia Dortmund' AND name_he IS NULL;
UPDATE clubs SET name_he = 'נאפולי' WHERE name_en = 'Napoli' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פורטו' WHERE name_en = 'Porto' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בנפיקה' WHERE name_en = 'Benfica' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אייאקס' WHERE name_en = 'Ajax' AND name_he IS NULL;

-- EPL clubs not already covered by UCL
UPDATE clubs SET name_he = 'אסטון וילה' WHERE name_en = 'Aston Villa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורנמות''' WHERE name_en = 'Bournemouth' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברנטפורד' WHERE name_en = 'Brentford' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברייטון והוב אלביון' WHERE name_en = 'Brighton & Hove Albion' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קריסטל פאלאס' WHERE name_en = 'Crystal Palace' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אברטון' WHERE name_en = 'Everton' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פולהאם' WHERE name_en = 'Fulham' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איפסוויץ'' טאון' WHERE name_en = 'Ipswich Town' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לסטר סיטי' WHERE name_en = 'Leicester City' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ניוקאסל יונייטד' WHERE name_en = 'Newcastle United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'נוטינגהאם פורסט' WHERE name_en = 'Nottingham Forest' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סאות''המפטון' WHERE name_en = 'Southampton' AND name_he IS NULL;
UPDATE clubs SET name_he = 'טוטנהאם הוטספר' WHERE name_en = 'Tottenham Hotspur' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ווסט האם יונייטד' WHERE name_en = 'West Ham United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וולברהמפטון וונדררס' WHERE name_en = 'Wolverhampton Wanderers' AND name_he IS NULL;

-- La Liga clubs not already covered by UCL
UPDATE clubs SET name_he = 'אתלטיק בילבאו' WHERE name_en = 'Athletic Bilbao' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ריאל סוסיאדד' WHERE name_en = 'Real Sociedad' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ריאל בטיס' WHERE name_en = 'Real Betis' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ויאריאל' WHERE name_en = 'Villarreal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ולנסיה' WHERE name_en = 'Valencia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סביליה' WHERE name_en = 'Sevilla' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ז''ירונה' WHERE name_en = 'Girona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוססונה' WHERE name_en = 'Osasuna' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סלטה ויגו' WHERE name_en = 'Celta Vigo' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ראיו ואייקאנו' WHERE name_en = 'Rayo Vallecano' AND name_he IS NULL;
UPDATE clubs SET name_he = 'חטאפה' WHERE name_en = 'Getafe' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לאס פלמאס' WHERE name_en = 'Las Palmas' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלאבס' WHERE name_en = 'Alaves' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אספניול' WHERE name_en = 'Espanyol' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לגאנס' WHERE name_en = 'Leganes' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מיורקה' WHERE name_en = 'Mallorca' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ויאדוליד' WHERE name_en = 'Valladolid' AND name_he IS NULL;

-- Serie A clubs not already covered by UCL
UPDATE clubs SET name_he = 'רומא' WHERE name_en = 'Roma' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לאציו' WHERE name_en = 'Lazio' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אטלנטה' WHERE name_en = 'Atalanta' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פיורנטינה' WHERE name_en = 'Fiorentina' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בולוניה' WHERE name_en = 'Bologna' AND name_he IS NULL;
UPDATE clubs SET name_he = 'טורינו' WHERE name_en = 'Torino' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אודינזה' WHERE name_en = 'Udinese' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ג''נואה' WHERE name_en = 'Genoa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קליארי' WHERE name_en = 'Cagliari' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ורונה' WHERE name_en = 'Verona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לצ''ה' WHERE name_en = 'Lecce' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פארמה' WHERE name_en = 'Parma' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קומו' WHERE name_en = 'Como' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ונציה' WHERE name_en = 'Venezia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אמפולי' WHERE name_en = 'Empoli' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מונצה' WHERE name_en = 'Monza' AND name_he IS NULL;

-- Bundesliga clubs not already covered by UCL
UPDATE clubs SET name_he = 'לייפציג' WHERE name_en = 'RB Leipzig' AND name_he IS NULL;
UPDATE clubs SET name_he = 'באייר לברקוזן' WHERE name_en = 'Bayer Leverkusen' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איינטרכט פרנקפורט' WHERE name_en = 'Eintracht Frankfurt' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שטוטגרט' WHERE name_en = 'VfB Stuttgart' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורוסיה מנשנגלדבך' WHERE name_en = 'Borussia Monchengladbach' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרייבורג' WHERE name_en = 'SC Freiburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וורדר ברמן' WHERE name_en = 'Werder Bremen' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוניון ברלין' WHERE name_en = 'Union Berlin' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מיינץ 05' WHERE name_en = 'Mainz 05' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וולפסבורג' WHERE name_en = 'Wolfsburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הופנהיים' WHERE name_en = 'Hoffenheim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוגסבורג' WHERE name_en = 'FC Augsburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בוכום' WHERE name_en = 'VfL Bochum' AND name_he IS NULL;
UPDATE clubs SET name_he = 'היידנהיים' WHERE name_en = 'FC Heidenheim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הולשטיין קיל' WHERE name_en = 'Holstein Kiel' AND name_he IS NULL;
UPDATE clubs SET name_he = 'זנקט פאולי' WHERE name_en = 'St. Pauli' AND name_he IS NULL;

-- Israeli Premier League clubs
UPDATE clubs SET name_he = 'מכבי חיפה' WHERE name_en = 'Maccabi Haifa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי תל אביב' WHERE name_en = 'Maccabi Tel Aviv' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל באר שבע' WHERE name_en = 'Hapoel Beer Sheva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל תל אביב' WHERE name_en = 'Hapoel Tel Aviv' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בית"ר ירושלים' WHERE name_en = 'Beitar Jerusalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי נתניה' WHERE name_en = 'Maccabi Netanya' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל חיפה' WHERE name_en = 'Hapoel Haifa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בני סכנין' WHERE name_en = 'Bnei Sakhnin' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מ.ס. אשדוד' WHERE name_en = 'Ashdod' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל ירושלים' WHERE name_en = 'Hapoel Jerusalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'עירוני קריית שמונה' WHERE name_en = 'Kiryat Shmona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי בני ריינה' WHERE name_en = 'Maccabi Bnei Reineh' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל פתח תקווה' WHERE name_en = 'Hapoel Petah Tikva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל כפר סבא' WHERE name_en = 'Hapoel Kfar Saba' AND name_he IS NULL;

-- Previous Knesset parties
UPDATE previous_parties SET name_en = 'Likud' WHERE name_he = 'הליכוד' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Yesh Atid' WHERE name_he = 'יש עתיד' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Religious Zionist Party' WHERE name_he = 'הציונות הדתית' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'National Unity' WHERE name_he = 'המחנה הממלכתי' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Yisrael Beiteinu' WHERE name_he = 'ישראל ביתנו' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Shas' WHERE name_he = 'ש"ס' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'United Torah Judaism' WHERE name_he = 'יהדות התורה' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Ra''am' WHERE name_he = 'רע"ם' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Hadash-Ta''al' WHERE name_he = 'חד"ש-תע"ל' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Labor' WHERE name_he = 'העבודה' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Meretz' WHERE name_he = 'מרצ' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Balad' WHERE name_he = 'בל"ד' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Jewish Home' WHERE name_he = 'הבית היהודי' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Other' WHERE name_he = 'אחר' AND name_en IS NULL;

-- Upcoming election parties
UPDATE upcoming_parties SET name_en = 'Likud' WHERE name_he = 'הליכוד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yesh' WHERE name_he = 'ישר' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yachad' WHERE name_he = 'ביחד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Democrats' WHERE name_he = 'הדמוקרטים' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Blue and White' WHERE name_he = 'כחול לבן' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yisrael Beiteinu' WHERE name_he = 'ישראל ביתנו' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Religious Zionist Party' WHERE name_he = 'הציונות הדתית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Otzma Yehudit' WHERE name_he = 'עוצמה יהודית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Hadash-Ta''al' WHERE name_he = 'חד"ש-תע"ל' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Balad' WHERE name_he = 'בל"ד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Economic Party' WHERE name_he = 'המפלגה הכלכלית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'El HaDegel' WHERE name_he = 'אל הדגל' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Reservists' WHERE name_he = 'המילואימניקים' AND name_en IS NULL;

-- New party: The Joint List (not a backfill target)
INSERT INTO upcoming_parties (name, name_en, name_he) VALUES ('הרשימה המשותפת', 'The Joint List', 'הרשימה המשותפת') ON CONFLICT (name) DO NOTHING;
```

- [ ] **Step 3: Write a migration verification test**

Create `ansible-project/roles/backend/files/backend/tests/test_migration.py`:

```python
import psycopg2
import pytest


def test_all_seeded_rows_have_both_languages(conn):
    cur = conn.cursor()
    for table in ('leagues', 'clubs', 'previous_parties', 'upcoming_parties'):
        cur.execute(f'SELECT COUNT(*) FROM {table} WHERE name_en IS NULL OR name_he IS NULL')
        assert cur.fetchone()[0] == 0, f'{table} has rows missing name_en/name_he'
    cur.close()


def test_seeded_row_counts(conn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM leagues')
    assert cur.fetchone()[0] == 7
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 150
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 14
    cur.execute('SELECT COUNT(*) FROM upcoming_parties')
    assert cur.fetchone()[0] == 14
    cur.close()


def test_sample_translations(conn):
    cur = conn.cursor()
    cur.execute("SELECT name_he FROM leagues WHERE name_en = 'EPL'")
    assert cur.fetchone()[0] == 'הפרמייר ליג'
    cur.execute("SELECT name_he FROM clubs WHERE name_en = 'Real Madrid' LIMIT 1")
    assert cur.fetchone()[0] == 'ריאל מדריד'
    cur.execute("SELECT name_en FROM previous_parties WHERE name_he = 'הליכוד'")
    assert cur.fetchone()[0] == 'Likud'
    cur.execute("SELECT name_he FROM upcoming_parties WHERE name_en = 'The Joint List'")
    assert cur.fetchone()[0] == 'הרשימה המשותפת'
    cur.close()


def test_partial_unique_index_rejects_duplicate_name_en(conn):
    cur = conn.cursor()
    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute("INSERT INTO previous_parties (name, name_en, name_he) VALUES ('x', 'Likud', 'ייחודי')")
    conn.rollback()
    cur.close()


def test_partial_unique_index_rejects_duplicate_name_he(conn):
    cur = conn.cursor()
    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute("INSERT INTO previous_parties (name, name_en, name_he) VALUES ('y', 'Unique English', 'הליכוד')")
    conn.rollback()
    cur.close()
```

- [ ] **Step 4: Run the test suite**

```bash
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd ansible-project/roles/backend/files/backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest tests/test_migration.py -v
```

Expected: all 5 tests PASS. If `docker run` fails because a container named `voteball-test-db` already exists from a previous session, run `docker rm -f voteball-test-db` first.

- [ ] **Step 5: Commit**

```bash
git add ansible-project/roles/backend/files/backend/schema.sql \
        ansible-project/roles/backend/files/backend/seed.sql \
        ansible-project/roles/backend/files/backend/tests/test_migration.py
git commit -m "Add name_en/name_he bilingual columns to leagues, clubs, and parties

Purely additive migration (Commit A of the two-commit plan in the design
spec) - adds nullable name_en/name_he columns, backfills every seeded row
in both languages, and protects uniqueness with partial unique indexes
that can't fail on account of an unknown legacy row. The old name column
is untouched."
```

---

## Task 2: `queries.py` — `get_options()` returns both languages

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py:8-29`
- Test: `ansible-project/roles/backend/files/backend/tests/test_queries.py:5-30`

**Interfaces:**
- Produces: `queries.get_options(conn)` returns `{'leagues': [{'id', 'name_en', 'name_he'}], 'clubs': [{'id', 'league_id', 'name_en', 'name_he'}], 'previous_parties': [{'id', 'name_en', 'name_he'}], 'upcoming_parties': [{'id', 'name_en', 'name_he'}]}` — no `name` key anywhere in the response.

- [ ] **Step 1: Update the failing test first**

Replace `test_get_options_returns_seeded_leagues` in `tests/test_queries.py` (lines 5-30) with:

```python
def test_get_options_returns_seeded_leagues(conn):
    options = queries.get_options(conn)
    league_names_en = {l['name_en'] for l in options['leagues']}
    assert 'EPL' in league_names_en
    assert 'Israeli Premier League' in league_names_en

    epl = next(l for l in options['leagues'] if l['name_en'] == 'EPL')
    assert epl['name_he'] == 'הפרמייר ליג'

    club_names_en = {c['name_en'] for c in options['clubs']}
    assert 'Liverpool' in club_names_en
    liverpool = next(c for c in options['clubs'] if c['name_en'] == 'Liverpool')
    assert liverpool['name_he'] == 'ליברפול'

    epl_clubs = [c for c in options['clubs'] if c['league_id'] == epl['id']]
    assert len(epl_clubs) == 20

    previous_names_en = {p['name_en'] for p in options['previous_parties']}
    assert previous_names_en == {
        'Likud', 'Yesh Atid', 'Religious Zionist Party', 'National Unity', 'Yisrael Beiteinu',
        'Shas', 'United Torah Judaism', "Ra'am", "Hadash-Ta'al", 'Labor', 'Meretz', 'Balad',
        'Jewish Home', 'Other',
    }
    previous_names_he = {p['name_he'] for p in options['previous_parties']}
    assert previous_names_he == {
        'הליכוד', 'יש עתיד', 'הציונות הדתית', 'המחנה הממלכתי', 'ישראל ביתנו',
        'ש"ס', 'יהדות התורה', 'רע"ם', 'חד"ש-תע"ל', 'העבודה', 'מרצ', 'בל"ד',
        'הבית היהודי', 'אחר',
    }

    upcoming_names_en = {p['name_en'] for p in options['upcoming_parties']}
    assert upcoming_names_en == {
        'Likud', 'Yesh', 'Yachad', 'The Democrats', 'Blue and White', 'Yisrael Beiteinu',
        'Religious Zionist Party', 'Otzma Yehudit', "Hadash-Ta'al", 'Balad',
        'The Economic Party', 'El HaDegel', 'The Reservists', 'The Joint List',
    }
    upcoming_names_he = {p['name_he'] for p in options['upcoming_parties']}
    assert upcoming_names_he == {
        'הליכוד', 'ישר', 'ביחד', 'הדמוקרטים', 'כחול לבן', 'ישראל ביתנו',
        'הציונות הדתית', 'עוצמה יהודית', 'חד"ש-תע"ל', 'בל"ד',
        'המפלגה הכלכלית', 'אל הדגל', 'המילואימניקים', 'הרשימה המשותפת',
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
python -m pytest tests/test_queries.py::test_get_options_returns_seeded_leagues -v
```

Expected: FAIL with `KeyError: 'name_en'` (the current `get_options` still returns `name`).

- [ ] **Step 3: Update `get_options()`**

In `ansible-project/roles/backend/files/backend/queries.py`, replace the `get_options` function (lines 8-29) with:

```python
def get_options(conn):
    cur = conn.cursor()

    cur.execute('SELECT id, name_en, name_he FROM leagues ORDER BY name_en')
    leagues = [{'id': r[0], 'name_en': r[1], 'name_he': r[2]} for r in cur.fetchall()]

    cur.execute('SELECT id, league_id, name_en, name_he FROM clubs ORDER BY name_en')
    clubs = [{'id': r[0], 'league_id': r[1], 'name_en': r[2], 'name_he': r[3]} for r in cur.fetchall()]

    cur.execute('SELECT id, name_en, name_he FROM previous_parties ORDER BY name_en')
    previous_parties = [{'id': r[0], 'name_en': r[1], 'name_he': r[2]} for r in cur.fetchall()]

    cur.execute('SELECT id, name_en, name_he FROM upcoming_parties ORDER BY name_en')
    upcoming_parties = [{'id': r[0], 'name_en': r[1], 'name_he': r[2]} for r in cur.fetchall()]

    cur.close()
    return {
        'leagues': leagues,
        'clubs': clubs,
        'previous_parties': previous_parties,
        'upcoming_parties': upcoming_parties,
    }
```

- [ ] **Step 4: Run it to verify it passes**

```bash
python -m pytest tests/test_queries.py::test_get_options_returns_seeded_leagues -v
```

Expected: PASS.

- [ ] **Step 5: Update `test_options_endpoint` in `test_app.py`**

In `ansible-project/roles/backend/files/backend/tests/test_app.py`, replace `test_options_endpoint` (lines 7-12) with:

```python
def test_options_endpoint(client):
    resp = client.get('/api/options')
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'leagues' in body
    assert any(l['name_en'] == 'EPL' for l in body['leagues'])
    assert any(l['name_he'] == 'הפרמייר ליג' for l in body['leagues'])
```

- [ ] **Step 6: Run the full test suite**

```bash
python -m pytest tests/ -v
```

Expected: `test_get_options_returns_seeded_leagues` and `test_options_endpoint` PASS. Other tests that reference `['name']` on options data (party CRUD tests) will still FAIL at this point — that's expected, Task 4 fixes those. Confirm the failures are all in `test_*party*` / `test_create_rename_delete_*` tests, not new unrelated breakage.

- [ ] **Step 7: Commit**

```bash
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py \
        ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Return name_en/name_he instead of name from get_options()"
```

---

## Task 3: `queries.py` — bilingual party create/rename + language-aware duplicate errors

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/queries.py` (party functions)
- Modify: `ansible-project/roles/backend/files/backend/tests/test_queries.py` (all party-function call sites)

**Interfaces:**
- Consumes: partial unique index names from Task 1 (`previous_parties_name_en_uidx`, `previous_parties_name_he_uidx`, `upcoming_parties_name_en_uidx`, `upcoming_parties_name_he_uidx`).
- Produces: `queries.create_previous_party(conn, name_en, name_he) -> int`, `queries.rename_previous_party(conn, party_id, name_en, name_he) -> bool`, `queries.create_upcoming_party(conn, name_en, name_he) -> int`, `queries.rename_upcoming_party(conn, party_id, name_en, name_he) -> bool`. `queries.DuplicatePartyNameError` gains a `.language` attribute (`'en'` or `'he'`) — Task 4 reads this to build the HTTP error message.

- [ ] **Step 1: Update the failing tests first**

In `ansible-project/roles/backend/files/backend/tests/test_queries.py`, replace `test_create_rename_delete_upcoming_party` (lines 223-243) with:

```python
def test_create_rename_delete_upcoming_party(conn):
    import queries

    party_id = queries.create_upcoming_party(conn, 'New Party', 'מפלגה חדשה')
    assert party_id > 0

    assert queries.rename_upcoming_party(conn, party_id, 'Renamed Party', 'מפלגה משודרגת') is True
    cur = conn.cursor()
    cur.execute('SELECT name_en, name_he FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone() == ('Renamed Party', 'מפלגה משודרגת')
    cur.close()

    assert queries.delete_upcoming_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_upcoming_party(conn, 999999, 'Nope', 'לא') is False
    assert queries.delete_upcoming_party(conn, 999999) is False
```

Replace `test_create_rename_delete_previous_party` (lines 318-337) with:

```python
def test_create_rename_delete_previous_party(conn):
    import queries

    party_id = queries.create_previous_party(conn, 'New Party', 'מפלגה חדשה')
    assert party_id > 0

    assert queries.rename_previous_party(conn, party_id, 'Renamed Party', 'מפלגה משודרגת') is True
    cur = conn.cursor()
    cur.execute('SELECT name_en, name_he FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone() == ('Renamed Party', 'מפלגה משודרגת')
    cur.close()

    assert queries.delete_previous_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_previous_party(conn, 999999, 'Nope', 'לא') is False
    assert queries.delete_previous_party(conn, 999999) is False
```

Replace `test_create_previous_party_duplicate_name_rolls_back_and_conn_still_usable` (lines 340-350) with:

```python
def test_create_previous_party_duplicate_english_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Dup Previous Party', 'מפלגה כפולה')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_previous_party(conn, 'Dup Previous Party', 'מפלגה אחרת')
    assert excinfo.value.language == 'en'

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_previous_party(conn, 'Another Previous Party', 'מפלגה נוספת')
    assert party_id > 0


def test_create_previous_party_duplicate_hebrew_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'First Party', 'שם משותף')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_previous_party(conn, 'Second Party', 'שם משותף')
    assert excinfo.value.language == 'he'

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_previous_party(conn, 'Third Party', 'שם ייחודי')
    assert party_id > 0
```

Replace `test_rename_previous_party_duplicate_name_rolls_back_and_conn_still_usable` (lines 353-363) with:

```python
def test_rename_previous_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Party X', 'מפלגה X')
    party_id = queries.create_previous_party(conn, 'Party Y', 'מפלגה Y')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.rename_previous_party(conn, party_id, 'Party X', 'שם חדש')
    assert excinfo.value.language == 'en'

    # connection must be usable afterward - proves rollback happened
    assert queries.rename_previous_party(conn, party_id, 'Party Z', 'שם חדש') is True
```

Replace `test_create_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable` (lines 366-376) with:

```python
def test_create_upcoming_party_duplicate_english_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Dup Upcoming Party', 'מפלגה כפולה')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_upcoming_party(conn, 'Dup Upcoming Party', 'מפלגה אחרת')
    assert excinfo.value.language == 'en'

    party_id = queries.create_upcoming_party(conn, 'Another Upcoming Party', 'מפלגה נוספת')
    assert party_id > 0


def test_create_upcoming_party_duplicate_hebrew_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'First Up Party', 'שם משותף עתידי')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_upcoming_party(conn, 'Second Up Party', 'שם משותף עתידי')
    assert excinfo.value.language == 'he'
```

Replace `test_rename_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable` (lines 379-389) with:

```python
def test_rename_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Party X', 'מפלגה X')
    party_id = queries.create_upcoming_party(conn, 'Party Y', 'מפלגה Y')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.rename_upcoming_party(conn, party_id, 'Party X', 'שם חדש')
    assert excinfo.value.language == 'en'

    # connection must be usable afterward - proves rollback happened
    assert queries.rename_upcoming_party(conn, party_id, 'Party Z', 'שם חדש') is True
```

Now update every remaining "setup only" call site (these don't test naming, just need a valid party to exist — pass the same string as both languages):

- `test_count_votes_for_previous_party`: `queries.create_previous_party(conn, 'Counted Party')` → `queries.create_previous_party(conn, 'Counted Party', 'Counted Party')`
- `test_count_votes_for_upcoming_party`: `queries.create_upcoming_party(conn, 'Counted Upcoming Party')` → `queries.create_upcoming_party(conn, 'Counted Upcoming Party', 'Counted Upcoming Party')`
- `test_reassign_previous_party_votes_updates_matching_rows_only`: the three `queries.create_previous_party(conn, 'Reassign Source')` / `'Reassign Target'` / `'Reassign Other'` calls each get a second identical-string argument, e.g. `queries.create_previous_party(conn, 'Reassign Source', 'Reassign Source')`
- `test_previous_party_exists`: `queries.create_previous_party(conn, 'Exists Check')` → `queries.create_previous_party(conn, 'Exists Check', 'Exists Check')`
- `test_reassign_upcoming_party_votes_handles_collision_and_simple_case`: the three `queries.create_upcoming_party(conn, 'Reassign Up Source')` / `'Reassign Up Target'` / `'Reassign Up Other'` calls each get a second identical-string argument
- `test_upcoming_party_exists`: `queries.create_upcoming_party(conn, 'Exists Check Upcoming')` → `queries.create_upcoming_party(conn, 'Exists Check Upcoming', 'Exists Check Upcoming')`

- [ ] **Step 2: Run to verify failures**

```bash
python -m pytest tests/test_queries.py -v -k "party or Party"
```

Expected: `TypeError: create_previous_party() missing 1 required positional argument: 'name_he'` (or similar) on every test touching party creation — confirms the tests now expect the new signature.

- [ ] **Step 3: Implement the new `queries.py` party functions**

In `ansible-project/roles/backend/files/backend/queries.py`, replace `class DuplicatePartyNameError` (lines 4-5) with:

```python
class DuplicatePartyNameError(Exception):
    def __init__(self, language):
        self.language = language  # 'en' or 'he'
        super().__init__(f'a party with this {language} name already exists')


def _duplicate_party_language(err):
    constraint = err.diag.constraint_name or ''
    if constraint.endswith('_name_en_uidx'):
        return 'en'
    return 'he'
```

(`_duplicate_party_language` defaults to `'he'` for anything other than an explicit `_name_en_uidx` hit — this also correctly covers the legacy `name` column's original `UNIQUE` constraint, since every party row's `name` value equals its `name_he` value both for existing rows, backfilled via `name_he = name`, and for new rows created below, which insert `name_he` into the legacy `name` column too — a `name` collision is therefore always a `name_he` collision in substance.)

Replace `create_upcoming_party` (lines 116-130) with:

```python
def create_upcoming_party(conn, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO upcoming_parties (name, name_en, name_he) VALUES (%s, %s, %s) RETURNING id',
            (name_he, name_en, name_he)
        )
        party_id = cur.fetchone()[0]
        conn.commit()
        return party_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

Replace `rename_upcoming_party` (lines 133-147) with:

```python
def rename_upcoming_party(conn, party_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE upcoming_parties SET name = %s, name_en = %s, name_he = %s, updated_at = NOW() WHERE id = %s',
            (name_he, name_en, name_he, party_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

Replace `create_previous_party` (lines 164-178) with:

```python
def create_previous_party(conn, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO previous_parties (name, name_en, name_he) VALUES (%s, %s, %s) RETURNING id',
            (name_he, name_en, name_he)
        )
        party_id = cur.fetchone()[0]
        conn.commit()
        return party_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

Replace `rename_previous_party` (lines 181-195) with:

```python
def rename_previous_party(conn, party_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE previous_parties SET name = %s, name_en = %s, name_he = %s, updated_at = NOW() WHERE id = %s',
            (name_he, name_en, name_he, party_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
python -m pytest tests/test_queries.py -v
```

Expected: every test in the file PASSES.

- [ ] **Step 5: Commit**

```bash
git add ansible-project/roles/backend/files/backend/queries.py \
        ansible-project/roles/backend/files/backend/tests/test_queries.py
git commit -m "Make party create/rename bilingual with language-aware duplicate errors"
```

---

## Task 4: `app.py` — bilingual party routes + full `test_app.py` update

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/app.py:132-266`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_app.py`

**Interfaces:**
- Consumes: `queries.create_previous_party(conn, name_en, name_he)`, `queries.rename_previous_party(conn, party_id, name_en, name_he)`, `queries.create_upcoming_party(conn, name_en, name_he)`, `queries.rename_upcoming_party(conn, party_id, name_en, name_he)`, `queries.DuplicatePartyNameError` (with `.language`) from Task 3.
- Produces: `POST /api/admin/{previous,upcoming}-parties` and `PATCH /api/admin/{previous,upcoming}-parties/<id>` now require JSON bodies `{"name_en": "...", "name_he": "..."}` (400 if either is blank after `.strip()`); 409 responses read `{"error": "a party with this English name already exists"}` or `{"error": "a party with this Hebrew name already exists"}`.

- [ ] **Step 1: Update `app.py` route bodies**

In `ansible-project/roles/backend/files/backend/app.py`, add this helper right after the `require_admin` decorator definition (after line 34):

```python
def _duplicate_party_error_response(err):
    message = 'a party with this English name already exists' if err.language == 'en' \
        else 'a party with this Hebrew name already exists'
    return jsonify({'error': message}), 409
```

Replace `create_upcoming_party_route` (lines 132-146) with:

```python
@app.route('/api/admin/upcoming-parties', methods=['POST'])
@require_admin
def create_upcoming_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_upcoming_party(conn, name_en, name_he)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he}), 201
```

Replace `rename_upcoming_party_route` (lines 149-165) with:

```python
@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_upcoming_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_upcoming_party(conn, party_id, name_en, name_he)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he})
```

Replace `create_previous_party_route` (lines 217-231) with:

```python
@app.route('/api/admin/previous-parties', methods=['POST'])
@require_admin
def create_previous_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_previous_party(conn, name_en, name_he)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he}), 201
```

Replace `rename_previous_party_route` (lines 234-250) with:

```python
@app.route('/api/admin/previous-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_previous_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_previous_party(conn, party_id, name_en, name_he)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he})
```

- [ ] **Step 2: Rewrite `test_app.py`'s party-related tests**

Every `json={'name': 'X'}` sent to a party create/rename route becomes `json={'name_en': 'X', 'name_he': 'X'}` (the exact string reused for both — these tests don't exercise translation content, just that both fields round-trip and duplicate detection works end-to-end). Because both fields are identical in these tests, a duplicate collides on `name_en` first (confirmed during planning: when both columns would collide simultaneously, Postgres reports the `name_en` partial index first), so existing duplicate-name assertions become the English-specific message.

Replace `test_upcoming_party_admin_crud` (lines 117-131) with:

```python
def test_upcoming_party_admin_crud(client, admin_headers):
    headers = admin_headers

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Test Party', 'name_he': 'מפלגת בדיקה'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_id}', json={'name_en': 'Renamed', 'name_he': 'שם חדש'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 404
```

Replace `test_previous_party_admin_crud` (lines 188-202) with:

```python
def test_previous_party_admin_crud(client, admin_headers):
    headers = admin_headers

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Test Party', 'name_he': 'מפלגת בדיקה'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_id}', json={'name_en': 'Renamed', 'name_he': 'שם חדש'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 404
```

Replace `test_previous_party_admin_routes_require_authentication` (lines 205-213) with:

```python
def test_previous_party_admin_routes_require_authentication(client):
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401

    resp = client.patch('/api/admin/previous-parties/1', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401

    resp = client.delete('/api/admin/previous-parties/1')
    assert resp.status_code == 401
```

Replace the four duplicate-name tests (lines 216-259) with:

```python
def test_create_upcoming_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this English name already exists'}


def test_create_upcoming_party_duplicate_hebrew_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'First EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Second EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}


def test_rename_upcoming_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    party_two_target = resp.get_json()['id']
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Party Two', 'name_he': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_two_id}', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this English name already exists'}
    assert party_two_target > 0


def test_create_previous_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this English name already exists'}


def test_create_previous_party_duplicate_hebrew_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'First EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Second EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}


def test_rename_previous_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    party_one_id = resp.get_json()['id']
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Party Two', 'name_he': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_two_id}', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this English name already exists'}
    assert party_one_id > 0
```

Now update the remaining "setup only" call sites (party creation used as prerequisite for delete-guard/reassign tests, not testing naming) — each `json={'name': 'X'}` becomes `json={'name_en': 'X', 'name_he': 'X'}`:

- `test_delete_upcoming_party_blocked_when_referenced_by_votes` (line 270): `json={'name': 'Referenced Party'}` → `json={'name_en': 'Referenced Party', 'name_he': 'Referenced Party'}`
- `test_delete_previous_party_blocked_when_referenced_by_votes` (line 293): `json={'name': 'Referenced Previous Party'}` → `json={'name_en': 'Referenced Previous Party', 'name_he': 'Referenced Previous Party'}`
- `test_previous_party_reassign_moves_votes_and_updates_count` (lines 316, 318): `'Source Party'` and `'Target Party'` each become `{'name_en': X, 'name_he': X}`
- `test_previous_party_reassign_rejects_equal_source_and_target` (line 346): `'Solo Party'` → `{'name_en': 'Solo Party', 'name_he': 'Solo Party'}`
- `test_previous_party_reassign_rejects_nonexistent_target` (line 355): `'Solo Party 2'` → `{'name_en': 'Solo Party 2', 'name_he': 'Solo Party 2'}`
- `test_upcoming_party_reassign_moves_votes_and_updates_count` (lines 378, 380): `'Up Source'` and `'Up Target'` each become `{'name_en': X, 'name_he': X}`
- `test_upcoming_party_reassign_rejects_equal_source_and_target` (line 404): `'Up Solo'` → `{'name_en': 'Up Solo', 'name_he': 'Up Solo'}`
- `test_upcoming_party_reassign_rejects_nonexistent_target` (line 413): `'Up Solo 2'` → `{'name_en': 'Up Solo 2', 'name_he': 'Up Solo 2'}`

- [ ] **Step 3: Run the full backend test suite**

```bash
python -m pytest tests/ -v
```

Expected: every test in `tests/` PASSES (this is the point where all backend work converges — Tasks 1-4 combined).

- [ ] **Step 4: Commit**

```bash
git add ansible-project/roles/backend/files/backend/app.py \
        ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Require name_en/name_he on party create/rename routes; language-specific 409s"
```

---

## Task 5: Shared `i18n.js` module

**Files:**
- Create: `ansible-project/roles/frontend/files/nginx/i18n.js`

**Interfaces:**
- Produces: global functions `t(key)`, `localizedName(entity)`, `getLang()`, `setLang(lang)`, and a `voteball:langchange` `CustomEvent` dispatched on `document` whenever the language changes. `document.documentElement.lang`/`dir` are kept in sync with the current language at all times, starting from the very first script execution (before body paint) through every subsequent toggle. Tasks 6-8 (`vote.js`, `results.js`, `admin.js`) consume all of these.

- [ ] **Step 1: Create `i18n.js`**

Create `ansible-project/roles/frontend/files/nginx/i18n.js`:

```javascript
const LANG_STORAGE_KEY = 'voteballLang';

const DICTIONARY = {
  en: {
    voteIntro: 'Football fandom vs. how you vote — anonymous, one vote per browser.',
    voteLegendLeague: '1. League',
    voteLabelLeague: 'League:',
    voteLabelClub: 'Club (optional, or leave blank if you just follow the league):',
    voteClubPlaceholderOption: '— just the league —',
    voteLegendPrevious: '2. Current Knesset — who did you vote for?',
    voteDidNotVote: "Didn't vote / not eligible",
    voteLegendUpcoming: '3. Upcoming election — who are you considering? (choose up to 3)',
    voteUndecided: 'Undecided / prefer not to say',
    voteSubmit: 'Submit vote',
    voteErrorLoadForm: "Couldn't load the form — try refreshing.",
    voteErrorRequiredFields: 'Please fill in all required fields.',
    voteErrorPickParty: "Pick at least one party you're considering, or mark yourself undecided.",
    voteErrorSubmit: 'Something went wrong submitting your vote.',

    resultsTitle: 'Voteball — Results',
    resultsHeading: 'Voteball — Results',
    resultsModeClubLeague: 'Start from a club/league',
    resultsModeParty: 'Start from a party',
    resultsLabelLeague: 'League:',
    resultsLabelClub: 'Club (optional):',
    resultsClubPlaceholderOption: '— whole league —',
    resultsLabelPartyType: 'Party type:',
    resultsPartyTypePrevious: 'Previous (current Knesset)',
    resultsPartyTypeUpcoming: 'Upcoming election',
    resultsLabelParty: 'Party:',
    resultsHeadingPrevious: 'Previous Knesset vote breakdown',
    resultsHeadingUpcoming: 'Upcoming election breakdown',
    resultsDidNotVote: 'Did not vote',
    resultsUndecided: 'Undecided',
    resultsLeagueWideSuffix: ' (league-wide)',
    resultsErrorLoad: "Couldn't load results — try refreshing.",

    adminTitle: 'Voteball — Admin',
    adminHeading: 'Voteball — Admin',
    adminLabelUsername: 'Username:',
    adminLabelPassword: 'Password:',
    adminLogIn: 'Log in',
    adminTabPrevious: 'Previous Parties',
    adminTabUpcoming: 'Upcoming Parties',
    adminTabVotes: 'Votes',
    adminLogOut: 'Log out',
    adminHeadingPrevious: 'Previous Parties',
    adminHeadingUpcoming: 'Upcoming Parties',
    adminHeadingVotes: 'Votes',
    adminPlaceholderNameEn: 'English name',
    adminPlaceholderNameHe: 'Hebrew name',
    adminAdd: 'Add',
    adminRename: 'Rename',
    adminReassign: 'Reassign votes…',
    adminDelete: 'Delete',
    adminSave: 'Save',
    adminReassignGo: 'Reassign',
    adminColId: 'ID',
    adminColCreated: 'Created',
    adminColLeague: 'League',
    adminColClub: 'Club',
    adminColPrevious: 'Previous vote',
    adminColUpcoming: 'Upcoming vote',
    adminDidNotVote: 'did not vote',
    adminUndecided: 'undecided',
    adminSomethingWrong: 'Something went wrong.',
    adminSomethingWrongRetry: 'Something went wrong — try again.',
    adminSessionExpired: 'Session expired — re-enter the secret.',
    adminIncorrectCredentials: 'Incorrect username or password.',
  },
  he: {
    voteIntro: 'אהדה לכדורגל מול הצבעה פוליטית — אנונימי, הצבעה אחת לדפדפן.',
    voteLegendLeague: '1. ליגה',
    voteLabelLeague: 'ליגה:',
    voteLabelClub: 'קבוצה (רשות, השאירו ריק אם אתם עוקבים רק אחרי הליגה):',
    voteClubPlaceholderOption: '— רק הליגה —',
    voteLegendPrevious: '2. הכנסת הנוכחית — למי הצבעתם?',
    voteDidNotVote: 'לא הצבעתי / לא זכאי',
    voteLegendUpcoming: '3. הבחירות הקרובות — למי אתם שוקלים להצביע? (עד 3)',
    voteUndecided: 'עדיין לא החלטתי / מעדיף/ה לא לומר',
    voteSubmit: 'שליחת הצבעה',
    voteErrorLoadForm: 'לא הצלחנו לטעון את הטופס — נסו לרענן.',
    voteErrorRequiredFields: 'נא למלא את כל השדות הנדרשים.',
    voteErrorPickParty: 'בחרו לפחות מפלגה אחת שאתם שוקלים, או סמנו שעדיין לא החלטתם.',
    voteErrorSubmit: 'משהו השתבש בשליחת ההצבעה.',

    resultsTitle: 'ווטבול — תוצאות',
    resultsHeading: 'ווטבול — תוצאות',
    resultsModeClubLeague: 'התחלה מקבוצה/ליגה',
    resultsModeParty: 'התחלה ממפלגה',
    resultsLabelLeague: 'ליגה:',
    resultsLabelClub: 'קבוצה (רשות):',
    resultsClubPlaceholderOption: '— כל הליגה —',
    resultsLabelPartyType: 'סוג מפלגה:',
    resultsPartyTypePrevious: 'הכנסת הנוכחית',
    resultsPartyTypeUpcoming: 'הבחירות הקרובות',
    resultsLabelParty: 'מפלגה:',
    resultsHeadingPrevious: 'התפלגות הצבעה בהכנסת הנוכחית',
    resultsHeadingUpcoming: 'התפלגות הבחירות הקרובות',
    resultsDidNotVote: 'לא הצביע/ה',
    resultsUndecided: 'לא החליט/ה',
    resultsLeagueWideSuffix: ' (כלל הליגה)',
    resultsErrorLoad: 'לא הצלחנו לטעון את התוצאות — נסו לרענן.',

    adminTitle: 'ווטבול — ניהול',
    adminHeading: 'ווטבול — ניהול',
    adminLabelUsername: 'שם משתמש:',
    adminLabelPassword: 'סיסמה:',
    adminLogIn: 'התחברות',
    adminTabPrevious: 'מפלגות קודמות',
    adminTabUpcoming: 'מפלגות עתידיות',
    adminTabVotes: 'הצבעות',
    adminLogOut: 'התנתקות',
    adminHeadingPrevious: 'מפלגות קודמות',
    adminHeadingUpcoming: 'מפלגות עתידיות',
    adminHeadingVotes: 'הצבעות',
    adminPlaceholderNameEn: 'שם באנגלית',
    adminPlaceholderNameHe: 'שם בעברית',
    adminAdd: 'הוספה',
    adminRename: 'שינוי שם',
    adminReassign: 'העברת הצבעות…',
    adminDelete: 'מחיקה',
    adminSave: 'שמירה',
    adminReassignGo: 'העברה',
    adminColId: 'מזהה',
    adminColCreated: 'נוצר',
    adminColLeague: 'ליגה',
    adminColClub: 'קבוצה',
    adminColPrevious: 'הצבעה קודמת',
    adminColUpcoming: 'הצבעה עתידית',
    adminDidNotVote: 'לא הצביע/ה',
    adminUndecided: 'לא החליט/ה',
    adminSomethingWrong: 'משהו השתבש.',
    adminSomethingWrongRetry: 'משהו השתבש — נסו שוב.',
    adminSessionExpired: 'ההתחברות פגה — יש להזין את הסיסמה מחדש.',
    adminIncorrectCredentials: 'שם משתמש או סיסמה שגויים.',
  },
};

function detectInitialLang() {
  const stored = localStorage.getItem(LANG_STORAGE_KEY);
  if (stored === 'en' || stored === 'he') return stored;
  return (navigator.language || '').toLowerCase().startsWith('he') ? 'he' : 'en';
}

let currentLang = detectInitialLang();

function getLang() {
  return currentLang;
}

function applyDocumentDirection() {
  document.documentElement.lang = currentLang;
  document.documentElement.dir = currentLang === 'he' ? 'rtl' : 'ltr';
}

function t(key) {
  return DICTIONARY[currentLang][key] || key;
}

function localizedName(entity) {
  return currentLang === 'he' ? entity.name_he : entity.name_en;
}

function applyStaticText() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    el.placeholder = t(el.dataset.i18nPlaceholder);
  });
}

function setLang(lang) {
  if (lang !== 'en' && lang !== 'he') return;
  currentLang = lang;
  localStorage.setItem(LANG_STORAGE_KEY, lang);
  applyDocumentDirection();
  applyStaticText();
  updateLangToggleButtons();
  document.dispatchEvent(new CustomEvent('voteball:langchange'));
}

function updateLangToggleButtons() {
  const toggle = document.getElementById('lang-toggle');
  if (!toggle) return;
  toggle.querySelectorAll('button[data-lang]').forEach(btn => {
    btn.setAttribute('aria-pressed', String(btn.dataset.lang === currentLang));
  });
}

function initLangToggle() {
  const toggle = document.getElementById('lang-toggle');
  if (!toggle) return;
  toggle.querySelectorAll('button[data-lang]').forEach(btn => {
    btn.addEventListener('click', () => setLang(btn.dataset.lang));
  });
  updateLangToggleButtons();
}

// Runs immediately, in <head>, before <body> is parsed — sets lang/dir before first paint.
applyDocumentDirection();

document.addEventListener('DOMContentLoaded', () => {
  applyStaticText();
  initLangToggle();
});
```

- [ ] **Step 2: Sanity-check the file loads without a syntax error**

```bash
node --check ansible-project/roles/frontend/files/nginx/i18n.js
```

Expected: no output (Node's `--check` prints nothing on success). If `node` isn't installed, skip this step — Task 6's manual browser verification will catch any syntax error immediately (the whole page fails to load).

- [ ] **Step 3: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/i18n.js
git commit -m "Add shared i18n.js: EN/HE dictionary, localizedName(), lang toggle, RTL"
```

---

## Task 6: `index.html` + `vote.js` — voting form in both languages

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/index.html`
- Modify: `ansible-project/roles/frontend/files/nginx/vote.js`
- Modify: `ansible-project/roles/frontend/files/nginx/style.css`

**Interfaces:**
- Consumes: `t(key)`, `localizedName(entity)`, `voteball:langchange` event from Task 5's `i18n.js`.

- [ ] **Step 1: Replace `index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <script src="i18n.js"></script>
  <title>Voteball</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <div id="lang-toggle" class="lang-toggle">
    <button type="button" data-lang="en" aria-pressed="true">EN</button>
    <button type="button" data-lang="he" aria-pressed="false">עב</button>
  </div>

  <h1>Voteball</h1>
  <p data-i18n="voteIntro">Football fandom vs. how you vote — anonymous, one vote per browser.</p>

  <form id="vote-form">
    <fieldset>
      <legend data-i18n="voteLegendLeague">1. League</legend>
      <label><span data-i18n="voteLabelLeague">League:</span> <select id="league-select" required></select></label>
      <label><span data-i18n="voteLabelClub">Club (optional, or leave blank if you just follow the league):</span>
        <select id="club-select"><option value="" data-i18n="voteClubPlaceholderOption">— just the league —</option></select>
      </label>
    </fieldset>

    <fieldset>
      <legend data-i18n="voteLegendPrevious">2. Current Knesset — who did you vote for?</legend>
      <div id="previous-party-options"></div>
      <label><input type="radio" name="previous" value="did_not_vote" required> <span data-i18n="voteDidNotVote">Didn't vote / not eligible</span></label>
    </fieldset>

    <fieldset>
      <legend data-i18n="voteLegendUpcoming">3. Upcoming election — who are you considering? (choose up to 3)</legend>
      <div id="upcoming-party-options"></div>
      <label><input type="checkbox" id="undecided-checkbox"> <span data-i18n="voteUndecided">Undecided / prefer not to say</span></label>
    </fieldset>

    <button type="submit" data-i18n="voteSubmit">Submit vote</button>
    <p class="error" id="error-message"></p>
  </form>

  <script src="vote.js"></script>
</body>
</html>
```

- [ ] **Step 2: Replace `vote.js`**

```javascript
let optionsData = null;

function renderLeagueOptions() {
  const leagueSelect = document.getElementById('league-select');
  const previousValue = leagueSelect.value;
  leagueSelect.innerHTML = '';
  optionsData.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    leagueSelect.appendChild(opt);
  });
  if (previousValue) leagueSelect.value = previousValue;
}

function renderClubs() {
  const leagueSelect = document.getElementById('league-select');
  const clubSelect = document.getElementById('club-select');
  const previousValue = clubSelect.value;
  clubSelect.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
  const leagueId = parseInt(leagueSelect.value, 10);
  optionsData.clubs.filter(c => c.league_id === leagueId).forEach(c => {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = localizedName(c);
    clubSelect.appendChild(opt);
  });
  if (previousValue) clubSelect.value = previousValue;
}

function renderPreviousPartyOptions() {
  const prevDiv = document.getElementById('previous-party-options');
  const checkedInput = document.querySelector('input[name="previous"]:checked');
  const checkedId = checkedInput ? checkedInput.value : null;
  prevDiv.innerHTML = '';
  optionsData.previous_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'radio';
    input.name = 'previous';
    input.value = p.id;
    if (String(p.id) === checkedId) input.checked = true;
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + localizedName(p)));
    prevDiv.appendChild(label);
  });
}

function renderUpcomingPartyOptions() {
  const upcomingDiv = document.getElementById('upcoming-party-options');
  const checkedIds = new Set(Array.from(document.querySelectorAll('.upcoming-checkbox:checked')).map(cb => cb.value));
  upcomingDiv.innerHTML = '';
  optionsData.upcoming_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'upcoming-checkbox';
    input.value = p.id;
    if (checkedIds.has(String(p.id))) input.checked = true;
    input.addEventListener('change', enforceUpcomingPartyLimit);
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + localizedName(p)));
    upcomingDiv.appendChild(label);
  });
  enforceUpcomingPartyLimit();
}

async function loadOptions() {
  try {
    const res = await fetch('/api/options');
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    optionsData = await res.json();
  } catch (err) {
    document.getElementById('error-message').textContent = t('voteErrorLoadForm');
    return;
  }

  renderLeagueOptions();
  document.getElementById('league-select').addEventListener('change', renderClubs);
  renderClubs();
  renderPreviousPartyOptions();
  renderUpcomingPartyOptions();
}

function enforceUpcomingPartyLimit() {
  const checkboxes = document.querySelectorAll('.upcoming-checkbox');
  const checkedCount = document.querySelectorAll('.upcoming-checkbox:checked').length;
  checkboxes.forEach(cb => {
    cb.disabled = !cb.checked && checkedCount >= 3;
  });
}

function selectedUpcomingPartyIds() {
  return Array.from(document.querySelectorAll('.upcoming-checkbox:checked')).map(cb => parseInt(cb.value, 10));
}

document.getElementById('undecided-checkbox').addEventListener('change', (e) => {
  document.querySelectorAll('.upcoming-checkbox').forEach(cb => {
    cb.disabled = e.target.checked;
    if (e.target.checked) cb.checked = false;
  });
});

document.getElementById('vote-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('error-message');
  errorEl.textContent = '';

  const leagueId = parseInt(document.getElementById('league-select').value, 10);
  const clubValue = document.getElementById('club-select').value;
  const previousChoice = document.querySelector('input[name="previous"]:checked');
  const undecided = document.getElementById('undecided-checkbox').checked;
  const upcomingIds = selectedUpcomingPartyIds();

  if (!leagueId || !previousChoice) {
    errorEl.textContent = t('voteErrorRequiredFields');
    return;
  }
  if (!undecided && upcomingIds.length === 0) {
    errorEl.textContent = t('voteErrorPickParty');
    return;
  }

  const body = {
    league_id: leagueId,
    club_id: clubValue ? parseInt(clubValue, 10) : null,
    previous_vote_status: previousChoice.value === 'did_not_vote' ? 'did_not_vote' : 'voted',
    previous_party_id: previousChoice.value === 'did_not_vote' ? null : parseInt(previousChoice.value, 10),
    upcoming_vote_status: undecided ? 'undecided' : 'considering',
    upcoming_party_ids: undecided ? [] : upcomingIds,
  };

  const res = await fetch('/api/vote', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  if (res.status === 409) {
    window.location.href = 'results.html';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = t('voteErrorSubmit');
    return;
  }
  window.location.href = 'results.html';
});

document.addEventListener('voteball:langchange', () => {
  if (!optionsData) return;
  renderLeagueOptions();
  renderClubs();
  renderPreviousPartyOptions();
  renderUpcomingPartyOptions();
});

loadOptions();
```

Note: `renderLeagueOptions`/`renderClubs`/`renderPreviousPartyOptions`/`renderUpcomingPartyOptions` are each idempotent — they read the currently-selected/checked value(s) before clearing and rebuilding, then restore them. This is what makes them safe to call both on initial load and on every `voteball:langchange` without losing in-progress form state.

- [ ] **Step 3: Add the language toggle style**

In `ansible-project/roles/frontend/files/nginx/style.css`, append:

```css
.lang-toggle { display: flex; gap: 0.4rem; justify-content: flex-end; margin-bottom: 0.5rem; }
.lang-toggle button { background: #eee; color: #333; padding: 0.3rem 0.7rem; font-size: 0.85rem; }
.lang-toggle button[aria-pressed="true"] { background: #1a73e8; color: white; }
```

- [ ] **Step 4: Manual verification**

No automated frontend test suite exists in this project (per `CLAUDE.md`) — verify by running the real stack locally.

```bash
# Terminal 1: test database (reuse if already running from Task 1)
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17

# Terminal 2: backend, listening on :5000
cd ansible-project/roles/backend/files/backend
source .venv/bin/activate
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  ADMIN_USERNAME=testadmin ADMIN_PASSWORD_HASH="$(python3 -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('test-admin-password'))")" \
  ADMIN_SESSION_SECRET=test-session-secret-not-for-production \
  python app.py

# Terminal 3: frontend, listening on :8080, proxying /api to the backend on :5000
cd /home/latnook/Documents/Voteball/.claude/worktrees/admin-ui/ansible-project/roles/frontend/files/nginx
cat > /tmp/local-nginx.conf << 'EOF'
events {}
http {
  server {
    listen 80;
    location / {
      root /usr/share/nginx/html;
      try_files $uri $uri.html $uri/ =404;
    }
    location /api/ {
      proxy_pass http://127.0.0.1:5000;
    }
  }
}
EOF
docker run -d --name voteball-local-frontend --network host \
  -v "$(pwd):/usr/share/nginx/html:ro" \
  -v /tmp/local-nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine
```

Then open `http://localhost:8080/index.html` in a browser and check:
- Page loads in English (or Hebrew, if the browser's language is Hebrew) with correctly-rendered league/club/party names in the selected language.
- Clicking "עב" flips the whole page to Hebrew, right-to-left, without a page reload (watch the URL bar / network tab — no navigation event) — form labels, legends, buttons, and every party/club/league name are all in Hebrew.
- Select a league, pick a club, check a party checkbox, then click the language toggle — the same league/club stay selected and the same checkbox stays checked, just relabeled.
- Reload the page — the previously chosen language persists (`localStorage`).
- Submitting a vote still works and redirects to `results.html`.

Tear down when done: `docker rm -f voteball-local-frontend voteball-test-db` (leave `voteball-test-db` running if Task 7/8 will reuse it in the same session — just note it needs a fresh `db.init_db` per test run, which `pytest`'s `conn` fixture already handles automatically for the automated suite; the manual `python app.py` process re-seeds on every restart).

- [ ] **Step 5: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/index.html \
        ansible-project/roles/frontend/files/nginx/vote.js \
        ansible-project/roles/frontend/files/nginx/style.css
git commit -m "Wire index.html/vote.js to the Hebrew/English language toggle"
```

---

## Task 7: `results.html` + `results.js` — results dashboard in both languages

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/results.html`
- Modify: `ansible-project/roles/frontend/files/nginx/results.js`

**Interfaces:**
- Consumes: `t(key)`, `localizedName(entity)`, `voteball:langchange` event from Task 5's `i18n.js`.

- [ ] **Step 1: Replace `results.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <script src="i18n.js"></script>
  <title data-i18n="resultsTitle">Voteball — Results</title>
  <link rel="stylesheet" href="style.css">
  <style>
    .bar-row { display: flex; align-items: center; margin: 0.3rem 0; }
    .bar-label { width: 220px; font-size: 0.9rem; }
    .bar-track { flex: 1; background: #eee; border-radius: 4px; height: 1.2rem; margin: 0 0.5rem; }
    .bar-fill { background: #1a73e8; height: 100%; border-radius: 4px; }
    .bar-count { width: 40px; text-align: right; font-size: 0.85rem; }
    .toggle { margin-bottom: 1rem; }
    [dir="rtl"] .bar-label { text-align: right; }
    [dir="rtl"] .bar-count { text-align: left; }
  </style>
</head>
<body>
  <div id="lang-toggle" class="lang-toggle">
    <button type="button" data-lang="en" aria-pressed="true">EN</button>
    <button type="button" data-lang="he" aria-pressed="false">עב</button>
  </div>

  <h1 data-i18n="resultsHeading">Voteball — Results</h1>
  <p id="total-votes"></p>

  <div class="toggle">
    <label><input type="radio" name="mode" value="club-league" checked> <span data-i18n="resultsModeClubLeague">Start from a club/league</span></label>
    <label><input type="radio" name="mode" value="party"> <span data-i18n="resultsModeParty">Start from a party</span></label>
  </div>

  <div id="club-league-mode">
    <label><span data-i18n="resultsLabelLeague">League:</span> <select id="league-picker"></select></label>
    <label><span data-i18n="resultsLabelClub">Club (optional):</span> <select id="club-picker"><option value="" data-i18n="resultsClubPlaceholderOption">— whole league —</option></select></label>
  </div>

  <div id="party-mode" style="display:none">
    <label><span data-i18n="resultsLabelPartyType">Party type:</span>
      <select id="party-type-picker">
        <option value="previous" data-i18n="resultsPartyTypePrevious">Previous (current Knesset)</option>
        <option value="upcoming" data-i18n="resultsPartyTypeUpcoming">Upcoming election</option>
      </select>
    </label>
    <label><span data-i18n="resultsLabelParty">Party:</span> <select id="party-picker"></select></label>
  </div>

  <h2 data-i18n="resultsHeadingPrevious">Previous Knesset vote breakdown</h2>
  <div id="previous-results"></div>

  <h2 data-i18n="resultsHeadingUpcoming">Upcoming election breakdown</h2>
  <div id="upcoming-results"></div>

  <script src="results.js"></script>
</body>
</html>
```

- [ ] **Step 2: Replace `results.js`**

```javascript
let optionsData = null;
let lastClubLeagueData = null;
let lastPartyData = null;

function renderBars(containerId, rows, nameLookup) {
  const container = document.getElementById(containerId);
  container.innerHTML = '';
  const total = rows.reduce((sum, r) => sum + r.count, 0) || 1;
  rows.sort((a, b) => b.count - a.count);
  rows.forEach(r => {
    const label = nameLookup(r);
    const pct = Math.round((r.count / total) * 100);
    const row = document.createElement('div');
    row.className = 'bar-row';

    const labelDiv = document.createElement('div');
    labelDiv.className = 'bar-label';
    labelDiv.textContent = label;

    const trackDiv = document.createElement('div');
    trackDiv.className = 'bar-track';
    const fillDiv = document.createElement('div');
    fillDiv.className = 'bar-fill';
    fillDiv.style.width = `${pct}%`;
    trackDiv.appendChild(fillDiv);

    const countDiv = document.createElement('div');
    countDiv.className = 'bar-count';
    countDiv.textContent = r.count;

    row.appendChild(labelDiv);
    row.appendChild(trackDiv);
    row.appendChild(countDiv);
    container.appendChild(row);
  });
}

function previousPartyName(id) {
  if (id === null) return t('resultsDidNotVote');
  const p = optionsData.previous_parties.find(p => p.id === id);
  return p ? localizedName(p) : `#${id}`;
}

function upcomingPartyName(id) {
  if (id === null) return t('resultsUndecided');
  const p = optionsData.upcoming_parties.find(p => p.id === id);
  return p ? localizedName(p) : `#${id}`;
}

function clubOrLeagueName(row) {
  if (row.club_id) {
    const c = optionsData.clubs.find(c => c.id === row.club_id);
    return c ? localizedName(c) : `club #${row.club_id}`;
  }
  const l = optionsData.leagues.find(l => l.id === row.league_id);
  return l ? `${localizedName(l)}${t('resultsLeagueWideSuffix')}` : `league #${row.league_id}`;
}

function showResultsError(containerIds) {
  containerIds.forEach(id => {
    const el = document.getElementById(id);
    if (el) el.innerHTML = `<p class="error">${t('resultsErrorLoad')}</p>`;
  });
}

function renderClubLeagueResults() {
  if (!lastClubLeagueData) return;
  renderBars('previous-results', lastClubLeagueData.previous.map(r => ({ count: r.count, key: r.party_id })), r => previousPartyName(r.key));
  renderBars('upcoming-results', lastClubLeagueData.upcoming.map(r => ({ count: r.count, key: r.party_id })), r => upcomingPartyName(r.key));
}

async function loadResultsByClubOrLeague() {
  const clubId = document.getElementById('club-picker').value;
  const leagueId = document.getElementById('league-picker').value;

  const query = clubId ? `by=club&id=${clubId}` : `by=league&id=${leagueId}`;
  let data;
  try {
    const res = await fetch(`/api/results?${query}`);
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    data = await res.json();
  } catch (err) {
    showResultsError(['previous-results', 'upcoming-results']);
    return;
  }

  lastClubLeagueData = data;
  renderClubLeagueResults();
}

function renderPartyResults() {
  if (!lastPartyData) return;
  const { partyType, targetId, otherId, breakdown, crosstab } = lastPartyData;
  const otherNameLookup = partyType === 'previous' ? upcomingPartyName : previousPartyName;
  const otherKey = partyType === 'previous' ? 'upcoming_party_id' : 'previous_party_id';

  renderBars(targetId, breakdown.map(r => ({ count: r.count, club_id: r.club_id, league_id: r.league_id })), clubOrLeagueName);
  renderBars(otherId, crosstab.map(r => ({ count: r.count, key: r[otherKey] })), r => otherNameLookup(r.key));
}

async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';

  let data;
  try {
    const res = await fetch(`/api/results?by=party&type=${partyType}&id=${partyId}`);
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    data = await res.json();
  } catch (err) {
    showResultsError([targetId, otherId]);
    return;
  }

  lastPartyData = { partyType, targetId, otherId, breakdown: data.breakdown, crosstab: data.crosstab };
  renderPartyResults();
}

function renderLeaguePickerOptions() {
  const leaguePicker = document.getElementById('league-picker');
  const previousValue = leaguePicker.value;
  leaguePicker.innerHTML = '';
  optionsData.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    leaguePicker.appendChild(opt);
  });
  if (previousValue) leaguePicker.value = previousValue;
}

function renderClubPickerOptions() {
  const leaguePicker = document.getElementById('league-picker');
  const clubPicker = document.getElementById('club-picker');
  const previousValue = clubPicker.value;
  clubPicker.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
  const leagueId = parseInt(leaguePicker.value, 10);
  optionsData.clubs.filter(c => c.league_id === leagueId).forEach(c => {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = localizedName(c);
    clubPicker.appendChild(opt);
  });
  if (previousValue) clubPicker.value = previousValue;
}

function renderPartyPicker() {
  const partyType = document.getElementById('party-type-picker').value;
  const picker = document.getElementById('party-picker');
  const previousValue = picker.value;
  picker.innerHTML = '';
  const list = partyType === 'previous' ? optionsData.previous_parties : optionsData.upcoming_parties;
  list.forEach(p => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = localizedName(p);
    picker.appendChild(opt);
  });
  if (previousValue) picker.value = previousValue;
  loadResultsByParty();
}

async function init() {
  try {
    const res = await fetch('/api/options');
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    optionsData = await res.json();
  } catch (err) {
    showResultsError(['previous-results', 'upcoming-results']);
    return;
  }

  renderLeaguePickerOptions();
  const leaguePicker = document.getElementById('league-picker');
  const clubPicker = document.getElementById('club-picker');
  renderClubPickerOptions();
  leaguePicker.addEventListener('change', () => { renderClubPickerOptions(); loadResultsByClubOrLeague(); });
  clubPicker.addEventListener('change', loadResultsByClubOrLeague);

  document.querySelectorAll('input[name="mode"]').forEach(radio => {
    radio.addEventListener('change', () => {
      const isClubLeague = document.querySelector('input[name="mode"]:checked').value === 'club-league';
      document.getElementById('club-league-mode').style.display = isClubLeague ? 'block' : 'none';
      document.getElementById('party-mode').style.display = isClubLeague ? 'none' : 'block';
      if (isClubLeague) loadResultsByClubOrLeague(); else renderPartyPicker();
    });
  });

  document.getElementById('party-type-picker').addEventListener('change', renderPartyPicker);
  document.getElementById('party-picker').addEventListener('change', loadResultsByParty);

  loadResultsByClubOrLeague();
}

document.addEventListener('voteball:langchange', () => {
  if (!optionsData) return;
  renderLeaguePickerOptions();
  renderClubPickerOptions();
  const isPartyMode = document.querySelector('input[name="mode"]:checked').value === 'party';
  if (isPartyMode) {
    renderPartyPicker();
  } else {
    renderClubLeagueResults();
  }
});

init();
```

Note on `renderPartyPicker()`: it re-populates the `<select>` (preserving the selected value) and then calls `loadResultsByParty()`, matching the existing code's behavior on every filter change. Calling it from the `voteball:langchange` handler while in party mode does trigger one results refetch — that mirrors how the picker already behaves on any other change, and the alternative (fully decoupling "repopulate options" from "load data") isn't how the original code was structured, so this plan doesn't introduce a new inconsistency.

- [ ] **Step 3: Manual verification**

Using the same three-terminal local setup from Task 6 Step 4 (backend on `:5000`, frontend nginx on `:8080`), open `http://localhost:8080/results.html`:
- Both "Previous Knesset" and "Upcoming election" headings and bar labels render in the selected language.
- Toggle language while in club/league mode — bar labels relabel in place, no network request needed (check the browser's network tab — no new `/api/results` call fires).
- Switch to "Start from a party" mode, pick a party, toggle language — the party picker's selected party stays selected, bars relabel.
- Toggle to Hebrew and confirm the bars right-align (`.bar-label`) and the vote counts left-align (`.bar-count`) — the mirrored RTL layout, not just translated text.

- [ ] **Step 4: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/results.html \
        ansible-project/roles/frontend/files/nginx/results.js
git commit -m "Wire results.html/results.js to the Hebrew/English language toggle"
```

---

## Task 8: `admin.html` + `admin.js` — admin panel in both languages, bilingual party forms

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/admin.html`
- Modify: `ansible-project/roles/frontend/files/nginx/admin.js`

**Interfaces:**
- Consumes: `t(key)`, `localizedName(entity)`, `voteball:langchange` event from Task 5's `i18n.js`; `{name_en, name_he}` request/response shape from Task 4's admin routes.

- [ ] **Step 1: Replace `admin.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <script src="i18n.js"></script>
  <title data-i18n="adminTitle">Voteball — Admin</title>
  <link rel="stylesheet" href="style.css">
  <style>
    .tab-bar { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    .tab-button { background: #eee; color: #333; }
    .tab-button.active { background: #1a73e8; color: white; }
    .tab-section { display: none; }
    .tab-section.active { display: block; }
    .party-row { display: flex; align-items: center; gap: 0.5rem; margin: 0.4rem 0; flex-wrap: wrap; }
    .party-row .party-name { flex: 1; min-width: 120px; }
    .party-row button, .reassign-form button { font-size: 0.85rem; padding: 0.3rem 0.6rem; }
    .reassign-form { margin: 0.4rem 0 0.4rem 1rem; padding: 0.5rem; border: 1px solid #ccc; border-radius: 6px; width: 100%; }
    table.votes-table { border-collapse: collapse; width: 100%; font-size: 0.9rem; }
    table.votes-table th, table.votes-table td { border: 1px solid #ccc; padding: 0.4rem; text-align: left; }
    .row-error { color: #c00; font-size: 0.85rem; width: 100%; }
    [dir="rtl"] table.votes-table th, [dir="rtl"] table.votes-table td { text-align: right; }
    [dir="rtl"] .party-row .party-name { text-align: right; }
  </style>
</head>
<body>
  <div id="lang-toggle" class="lang-toggle">
    <button type="button" data-lang="en" aria-pressed="true">EN</button>
    <button type="button" data-lang="he" aria-pressed="false">עב</button>
  </div>

  <h1 data-i18n="adminHeading">Voteball — Admin</h1>

  <div id="secret-gate">
    <form id="secret-form">
      <label><span data-i18n="adminLabelUsername">Username:</span> <input type="text" id="username-input" required autocomplete="username"></label>
      <label><span data-i18n="adminLabelPassword">Password:</span> <input type="password" id="password-input" required autocomplete="current-password"></label>
      <button type="submit" data-i18n="adminLogIn">Log in</button>
      <p class="error" id="secret-error"></p>
    </form>
  </div>

  <div id="admin-content" style="display:none">
    <div class="tab-bar">
      <button type="button" class="tab-button active" data-tab="previous" data-i18n="adminTabPrevious">Previous Parties</button>
      <button type="button" class="tab-button" data-tab="upcoming" data-i18n="adminTabUpcoming">Upcoming Parties</button>
      <button type="button" class="tab-button" data-tab="votes" data-i18n="adminTabVotes">Votes</button>
      <button type="button" id="logout-button" data-i18n="adminLogOut">Log out</button>
    </div>

    <section id="tab-previous" class="tab-section active">
      <h2 data-i18n="adminHeadingPrevious">Previous Parties</h2>
      <div id="previous-party-list"></div>
      <form id="previous-party-add-form">
        <input type="text" id="previous-party-add-input-en" data-i18n-placeholder="adminPlaceholderNameEn" placeholder="English name" required>
        <input type="text" id="previous-party-add-input-he" data-i18n-placeholder="adminPlaceholderNameHe" placeholder="Hebrew name" dir="rtl" required>
        <button type="submit" data-i18n="adminAdd">Add</button>
      </form>
      <p class="error" id="previous-party-form-error"></p>
    </section>

    <section id="tab-upcoming" class="tab-section">
      <h2 data-i18n="adminHeadingUpcoming">Upcoming Parties</h2>
      <div id="upcoming-party-list"></div>
      <form id="upcoming-party-add-form">
        <input type="text" id="upcoming-party-add-input-en" data-i18n-placeholder="adminPlaceholderNameEn" placeholder="English name" required>
        <input type="text" id="upcoming-party-add-input-he" data-i18n-placeholder="adminPlaceholderNameHe" placeholder="Hebrew name" dir="rtl" required>
        <button type="submit" data-i18n="adminAdd">Add</button>
      </form>
      <p class="error" id="upcoming-party-form-error"></p>
    </section>

    <section id="tab-votes" class="tab-section">
      <h2 data-i18n="adminHeadingVotes">Votes</h2>
      <div id="votes-table-container"></div>
    </section>
  </div>

  <script src="admin.js"></script>
</body>
</html>
```

- [ ] **Step 2: Replace `admin.js`**

```javascript
const ADMIN_TOKEN_KEY = 'voteballAdminToken';
let optionsData = null;
let lastVotesData = null;
const loadedTabs = new Set();
const openRenamePartyIds = new Set();

function adminHeaders() {
  return { 'Authorization': 'Bearer ' + (sessionStorage.getItem(ADMIN_TOKEN_KEY) || '') };
}

async function adminFetch(url, options = {}) {
  const headers = Object.assign({}, options.headers, adminHeaders());
  const res = await fetch(url, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    sessionStorage.removeItem(ADMIN_TOKEN_KEY);
    showGate(t('adminSessionExpired'));
    return null;
  }
  return res;
}

function showGate(message) {
  document.getElementById('admin-content').style.display = 'none';
  document.getElementById('secret-gate').style.display = 'block';
  document.getElementById('secret-error').textContent = message || '';
}

function showContent() {
  document.getElementById('secret-gate').style.display = 'none';
  document.getElementById('admin-content').style.display = 'block';
}

async function getOptionsData() {
  if (optionsData) return optionsData;
  const res = await fetch('/api/options');
  optionsData = await res.json();
  return optionsData;
}

function activateTab(tab) {
  document.querySelectorAll('.tab-button').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.tab === tab);
  });
  document.querySelectorAll('.tab-section').forEach(section => {
    section.classList.toggle('active', section.id === `tab-${tab}`);
  });
  loadTab(tab);
}

function loadTab(tab) {
  if (loadedTabs.has(tab)) return;
  loadedTabs.add(tab);
  if (tab === 'previous') loadPartyTab('previous');
  else if (tab === 'upcoming') loadPartyTab('upcoming');
  else if (tab === 'votes') loadVotesTab();
}

function partyEndpoint(type) {
  return type === 'previous' ? '/api/admin/previous-parties' : '/api/admin/upcoming-parties';
}

function partyListKey(type) {
  return type === 'previous' ? 'previous_parties' : 'upcoming_parties';
}

async function loadPartyTab(type) {
  const data = await getOptionsData();
  renderPartyList(type, data[partyListKey(type)]);
}

function renderPartyList(type, parties) {
  const container = document.getElementById(`${type}-party-list`);
  container.innerHTML = '';
  parties.forEach(party => container.appendChild(renderPartyRow(type, party, parties)));
}

function renderPartyRow(type, party, allParties) {
  const row = document.createElement('div');
  row.className = 'party-row';
  row.dataset.partyId = party.id;

  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = localizedName(party);
  row.appendChild(nameSpan);

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRename(type, party, row));
  row.appendChild(renameBtn);

  const reassignBtn = document.createElement('button');
  reassignBtn.type = 'button';
  reassignBtn.textContent = t('adminReassign');
  reassignBtn.addEventListener('click', () => toggleReassignForm(type, party, allParties, row));
  row.appendChild(reassignBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = t('adminDelete');
  deleteBtn.addEventListener('click', () => deleteParty(type, party));
  row.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  row.appendChild(errorSpan);

  return row;
}

function startRename(type, party, row) {
  openRenamePartyIds.add(party.id);
  const nameSpan = row.querySelector('.party-name');
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.value = party.name_en;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.value = party.name_he;
  inputHe.dir = 'rtl';
  nameSpan.replaceWith(inputEn);
  inputEn.after(inputHe);

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = t('adminSave');
  inputHe.after(saveBtn);
  inputEn.focus();

  saveBtn.addEventListener('click', async () => {
    const errorSpan = row.querySelector('.row-error');
    errorSpan.textContent = '';

    let res;
    try {
      res = await adminFetch(`${partyEndpoint(type)}/${party.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    openRenamePartyIds.delete(party.id);
    optionsData = null;
    loadedTabs.delete(type);
    loadPartyTab(type);
  });
}

async function deleteParty(type, party) {
  if (!confirm(`Delete "${localizedName(party)}"? This cannot be undone.`)) return;

  let res;
  try {
    res = await adminFetch(`${partyEndpoint(type)}/${party.id}`, { method: 'DELETE' });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete(type);
  loadPartyTab(type);
}

async function addParty(e, type) {
  e.preventDefault();
  const inputEn = document.getElementById(`${type}-party-add-input-en`);
  const inputHe = document.getElementById(`${type}-party-add-input-he`);
  const errorEl = document.getElementById(`${type}-party-form-error`);
  errorEl.textContent = '';

  let res;
  try {
    res = await adminFetch(partyEndpoint(type), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
    });
  } catch (err) {
    errorEl.textContent = t('adminSomethingWrong');
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    errorEl.textContent = body.error || t('adminSomethingWrong');
    return;
  }
  inputEn.value = '';
  inputHe.value = '';
  optionsData = null;
  loadedTabs.delete(type);
  loadPartyTab(type);
}

document.getElementById('previous-party-add-form').addEventListener('submit', (e) => addParty(e, 'previous'));
document.getElementById('upcoming-party-add-form').addEventListener('submit', (e) => addParty(e, 'upcoming'));

document.querySelectorAll('.tab-button').forEach(btn => {
  btn.addEventListener('click', () => activateTab(btn.dataset.tab));
});

document.getElementById('secret-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const username = document.getElementById('username-input').value;
  const password = document.getElementById('password-input').value;
  const errorEl = document.getElementById('secret-error');
  errorEl.textContent = '';

  let res;
  try {
    res = await fetch('/api/admin/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
  } catch (err) {
    errorEl.textContent = t('adminSomethingWrongRetry');
    return;
  }

  if (res.status === 401) {
    errorEl.textContent = t('adminIncorrectCredentials');
    document.getElementById('password-input').value = '';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = t('adminSomethingWrongRetry');
    return;
  }

  const { token } = await res.json();
  sessionStorage.setItem(ADMIN_TOKEN_KEY, token);
  showContent();
  activateTab('previous');
});

async function tryEnterWithStoredToken() {
  const stored = sessionStorage.getItem(ADMIN_TOKEN_KEY);
  if (!stored) return;
  let res;
  try {
    res = await fetch('/api/admin/votes', { headers: { 'Authorization': `Bearer ${stored}` } });
  } catch (err) {
    return;
  }
  if (res.ok) {
    showContent();
    activateTab('previous');
  } else {
    sessionStorage.removeItem(ADMIN_TOKEN_KEY);
  }
}

document.getElementById('logout-button').addEventListener('click', () => {
  sessionStorage.removeItem(ADMIN_TOKEN_KEY);
  showGate();
});

tryEnterWithStoredToken();

function toggleReassignForm(type, sourceParty, allParties, row) {
  const existing = row.querySelector('.reassign-form');
  if (existing) {
    existing.remove();
    return;
  }

  const form = document.createElement('div');
  form.className = 'reassign-form';

  const select = document.createElement('select');
  allParties.filter(p => p.id !== sourceParty.id).forEach(p => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = localizedName(p);
    select.appendChild(opt);
  });
  form.appendChild(select);

  const goBtn = document.createElement('button');
  goBtn.type = 'button';
  goBtn.textContent = t('adminReassignGo');
  form.appendChild(goBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  form.appendChild(errorSpan);

  goBtn.addEventListener('click', async () => {
    if (!select.value) return;
    const targetId = parseInt(select.value, 10);
    errorSpan.textContent = '';

    let countRes;
    try {
      countRes = await adminFetch(`${partyEndpoint(type)}/${sourceParty.id}/reassign-count?target_id=${targetId}`);
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (countRes === null) return;
    if (!countRes.ok) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    const { count } = await countRes.json();
    const targetParty = allParties.find(p => p.id === targetId);
    if (!confirm(`Reassign ${count} votes from "${localizedName(sourceParty)}" to "${localizedName(targetParty)}"? This cannot be undone.`)) {
      return;
    }

    let res;
    try {
      res = await adminFetch(`${partyEndpoint(type)}/${sourceParty.id}/reassign`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_id: targetId }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete(type);
    loadedTabs.delete('votes');
    loadPartyTab(type);
  });

  row.appendChild(form);
}

function leagueName(data, id) {
  const l = data.leagues.find(l => l.id === id);
  return l ? localizedName(l) : `league #${id}`;
}

function clubName(data, id) {
  if (id === null) return '—';
  const c = data.clubs.find(c => c.id === id);
  return c ? localizedName(c) : `club #${id}`;
}

function previousPartyName(data, id) {
  if (id === null) return t('adminDidNotVote');
  const p = data.previous_parties.find(p => p.id === id);
  return p ? localizedName(p) : `#${id}`;
}

function upcomingPartyNames(data, ids) {
  if (!ids.length) return t('adminUndecided');
  return ids.map(id => {
    const p = data.upcoming_parties.find(p => p.id === id);
    return p ? localizedName(p) : `#${id}`;
  }).join(', ');
}

async function loadVotesTab() {
  const data = await getOptionsData();
  let res;
  try {
    res = await adminFetch('/api/admin/votes');
  } catch (err) {
    return;
  }
  if (res === null || !res.ok) return;
  const { votes } = await res.json();
  lastVotesData = votes.slice().reverse();
  renderVotesTable(data, lastVotesData);
}

function renderVotesTable(data, votes) {
  const container = document.getElementById('votes-table-container');
  container.innerHTML = '';

  const table = document.createElement('table');
  table.className = 'votes-table';

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  [t('adminColId'), t('adminColCreated'), t('adminColLeague'), t('adminColClub'), t('adminColPrevious'), t('adminColUpcoming'), ''].forEach(text => {
    const th = document.createElement('th');
    th.textContent = text;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  votes.forEach(v => {
    const tr = document.createElement('tr');
    [
      v.id,
      v.created_at,
      leagueName(data, v.league_id),
      clubName(data, v.club_id),
      previousPartyName(data, v.previous_party_id),
      upcomingPartyNames(data, v.upcoming_party_ids),
    ].forEach(text => {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    });

    const actionTd = document.createElement('td');
    const deleteBtn = document.createElement('button');
    deleteBtn.type = 'button';
    deleteBtn.textContent = t('adminDelete');
    deleteBtn.addEventListener('click', async () => {
      if (!confirm(`Delete vote #${v.id}? This cannot be undone.`)) return;
      let res;
      try {
        res = await adminFetch(`/api/admin/votes/${v.id}`, { method: 'DELETE' });
      } catch (err) {
        alert(t('adminSomethingWrong'));
        return;
      }
      if (res === null) return;
      if (!res.ok) {
        alert(t('adminSomethingWrong'));
        return;
      }
      tr.remove();
    });
    actionTd.appendChild(deleteBtn);
    tr.appendChild(actionTd);

    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  container.appendChild(table);
}

document.addEventListener('voteball:langchange', () => {
  if (optionsData) {
    ['previous', 'upcoming'].forEach(type => {
      if (!loadedTabs.has(type)) return;
      const container = document.getElementById(`${type}-party-list`);
      const hasOpenReassignForm = container.querySelector('.reassign-form') !== null;
      const hasOpenRename = Array.from(container.querySelectorAll('.party-row')).some(
        row => openRenamePartyIds.has(parseInt(row.dataset.partyId, 10))
      );
      if (hasOpenRename || hasOpenReassignForm) return; // leave in-progress edits/open forms alone
      renderPartyList(type, optionsData[partyListKey(type)]);
    });
  }
  if (optionsData && lastVotesData && loadedTabs.has('votes')) {
    renderVotesTable(optionsData, lastVotesData);
  }
});
```

Note: unlike the party row buttons in Task 6/7 (which reuse the shared `t()`/`localizedName()` via re-render on every `voteball:langchange`), the dynamically-created buttons here (`renameBtn`, `reassignBtn`, `deleteBtn`, `saveBtn`, `goBtn`, vote-table `deleteBtn`) don't carry `data-i18n` — they don't need to, since `renderPartyList`/`renderVotesTable` are already fully re-invoked from scratch on every language change (except for rows with an open rename/reassign form, deliberately skipped to preserve that in-progress state).

- [ ] **Step 3: Manual verification**

Using the same three-terminal local setup from Task 6 Step 4, open `http://localhost:8080/admin.html`:
- Log in with `testadmin` / `test-admin-password` (matching the env vars used to start the backend in Step 4 of Task 6).
- Toggle language on the login gate — labels and the login button retranslate; log in still works.
- Once logged in, toggle language — tab labels, headings, party rows, and the "Add" form's placeholders all retranslate.
- Click "Rename" on a party row, then toggle the language — confirm the open rename inputs (with their current values) are left completely alone, not reset or blown away, while the rest of the party list still updates.
- Add a new party with only an English name filled in (leave Hebrew blank) — confirm it's rejected client-side (`required` attribute) or server-side with a 400.
- Add a party whose Hebrew name matches an existing party's Hebrew name but with a different English name — confirm the error specifically says "Hebrew name" (not the generic English message).
- Open the Votes tab, toggle language — table headers and "did not vote"/"undecided" fallback text retranslate; delete still works.
- Toggle to Hebrew — votes table columns and party-row text right-align (RTL), not just translated.

- [ ] **Step 4: Tear down local verification containers**

```bash
docker rm -f voteball-local-frontend voteball-test-db
```

- [ ] **Step 5: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/admin.html \
        ansible-project/roles/frontend/files/nginx/admin.js
git commit -m "Wire admin.html/admin.js to the Hebrew/English language toggle and bilingual party forms"
```

---

## Post-plan note: Commit B

This plan implements Commit A only (per the design spec's Decision 2). Once this branch is deployed and confirmed live, a small follow-up change (not part of this plan) upgrades the partial unique indexes to full `NOT NULL` + `UNIQUE` constraints and drops the legacy `name` column — only after confirming `SELECT COUNT(*) FROM <table> WHERE name_en IS NULL OR name_he IS NULL` returns `0` for all four tables on the live database.
