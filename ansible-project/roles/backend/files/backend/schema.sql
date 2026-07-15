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
