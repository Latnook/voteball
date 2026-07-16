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

-- One club can now be votable under two leagues (continental competition + domestic league) --
-- see docs/superpowers/specs/2026-07-15-clubs-leagues-admin-crud-design.md decision 10.
ALTER TABLE clubs ADD COLUMN IF NOT EXISTS domestic_league_id INTEGER REFERENCES leagues(id);

-- Admin-curated logo/crest/flag URLs for the frontend redesign. Nullable by design: the frontend
-- falls back to a generated monogram/flag when unset, so this never blocks seeding or admin CRUD.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS logo_url TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS logo_url TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS logo_url TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS logo_url TEXT;

-- Explicit display ordering for leagues (e.g. pinning the Israeli Premier League first). Nullable
-- so unranked leagues fall back to alphabetical (see get_options's ORDER BY sort_order NULLS LAST).
ALTER TABLE leagues ADD COLUMN IF NOT EXISTS sort_order INTEGER;

DO $$
BEGIN
    ALTER TABLE clubs ADD CONSTRAINT clubs_domestic_league_differs
        CHECK (domestic_league_id IS DISTINCT FROM league_id);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Club name uniqueness moves from per-league to global (decision 7) -- per-league uniqueness
-- is what let the same real club exist as two separate rows in two different leagues.
DROP INDEX IF EXISTS clubs_league_name_en_uidx;
DROP INDEX IF EXISTS clubs_league_name_he_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_en_uidx ON clubs (name_en) WHERE name_en IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_he_uidx ON clubs (name_he) WHERE name_he IS NOT NULL;

CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    previous_vote_status TEXT NOT NULL CHECK (previous_vote_status IN ('voted', 'did_not_vote')),
    previous_party_id INTEGER REFERENCES previous_parties(id),
    upcoming_vote_status TEXT NOT NULL CHECK (upcoming_vote_status IN ('considering', 'undecided')),
    cookie_token TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- A ballot can now name up to 3 clubs per league, across any number of leagues (multi-team
-- ballots) -- so the old singular votes.league_id/club_id columns can no longer represent a
-- ballot. Pre-launch, no real vote data exists, so this drop is safe with no migration; kept
-- idempotent (IF EXISTS) since schema.sql re-runs on every backend boot, including redeploys
-- after the columns are already gone.
ALTER TABLE votes DROP COLUMN IF EXISTS league_id;
ALTER TABLE votes DROP COLUMN IF EXISTS club_id;

CREATE TABLE IF NOT EXISTS vote_clubs (
    vote_id   INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    club_id   INTEGER NOT NULL REFERENCES clubs(id),
    league_id INTEGER NOT NULL REFERENCES leagues(id),  -- which tab the club was picked under
    PRIMARY KEY (vote_id, club_id, league_id)
);
CREATE INDEX IF NOT EXISTS idx_vote_clubs_club ON vote_clubs (club_id);
CREATE INDEX IF NOT EXISTS idx_vote_clubs_league ON vote_clubs (league_id);

CREATE TABLE IF NOT EXISTS vote_leagues (  -- "just this league, no specific club"
    vote_id   INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    PRIMARY KEY (vote_id, league_id)
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

-- Adds a league/club dimension to the previous<->upcoming migration rollup so results can answer
-- "fans of MY club who voted like me last time -- where are they headed now", not just the global
-- migration. Nullable like the rest of the rollup dimensions (a NULL club_id row is still league-wide).
ALTER TABLE rollup_previous_upcoming ADD COLUMN IF NOT EXISTS league_id INTEGER;
ALTER TABLE rollup_previous_upcoming ADD COLUMN IF NOT EXISTS club_id INTEGER;
CREATE INDEX IF NOT EXISTS idx_rollup_previous_upcoming_league_club ON rollup_previous_upcoming (league_id, club_id);

-- National totals need their own rollup tables, separate from rollup_previous/rollup_upcoming/
-- rollup_previous_upcoming. Those three now carry TWO kinds of rows per multi-team ballot --
-- one league-scope row per distinct league touched (club_id IS NULL) plus one club-scope row per
-- club pick -- so summing them with no filter would count a multi-pick voter multiple times.
-- These national tables hold exactly one row's worth of counting per vote, with no league/club
-- dimension, and back only the national-scoped reads (GET /api/results?by=all, the no-filter
-- branch of /api/results/segment, and the crosstab in get_results_by_party).
CREATE TABLE IF NOT EXISTS rollup_national_previous (
    previous_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_national_previous_party ON rollup_national_previous (previous_party_id);

CREATE TABLE IF NOT EXISTS rollup_national_upcoming (
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_national_upcoming_party ON rollup_national_upcoming (upcoming_party_id);

CREATE TABLE IF NOT EXISTS rollup_national_previous_upcoming (
    previous_party_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_national_previous_upcoming_previous ON rollup_national_previous_upcoming (previous_party_id);
CREATE INDEX IF NOT EXISTS idx_rollup_national_previous_upcoming_upcoming ON rollup_national_previous_upcoming (upcoming_party_id);
