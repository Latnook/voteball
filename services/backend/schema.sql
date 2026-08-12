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

-- Hebrew/English bilingual names (docs/design/2026-07-14-hebrew-english-i18n-design.md).
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

-- Russian as a third display language (see the Languages section of the root CLAUDE.md).
-- Same structural-only rule as the bilingual block above: backfill lives in seed.sql.
-- Nullable like name_he, which is what lets this ship ahead of the translations and lets an
-- untranslated row fall back to its English name instead of rendering blank.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS name_ru TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS name_ru TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS name_ru TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS name_ru TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS previous_parties_name_ru_uidx ON previous_parties (name_ru) WHERE name_ru IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS upcoming_parties_name_ru_uidx ON upcoming_parties (name_ru) WHERE name_ru IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS leagues_name_ru_uidx ON leagues (name_ru) WHERE name_ru IS NOT NULL;
-- Global, not per-league: clubs_name_ru_uidx is created new, so it goes straight to the shape the
-- en/he indexes only reach after the DROP/CREATE further down (decision 7).
CREATE UNIQUE INDEX IF NOT EXISTS clubs_name_ru_uidx ON clubs (name_ru) WHERE name_ru IS NOT NULL;

-- One club can now be votable under two leagues (continental competition + domestic league) --
-- see docs/design/2026-07-15-clubs-leagues-admin-crud-design.md decision 10.
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

-- Whether this league's clubs are split into divisions rendered as headers inside its single tab
-- (the UEFA Nations League's A-D tiers). A league-level flag rather than something inferred from
-- the clubs, because clubs.group_label belongs to a club's NATIONS LEAGUE membership while the
-- club itself can sit in two leagues: the 16 nations that also play in the 2026 World Cup carry a
-- label and render under BOTH tabs, which put "League A"/"League B" headers on the World Cup tab.
-- Inferring "this league has divisions" from "some club here is labelled" reproduces that bug; and
-- inferring it from "every club here is labelled" breaks as soon as an admin adds an unlabelled
-- club to the Nations League, which is a supported case (it renders first, headerless).
ALTER TABLE leagues ADD COLUMN IF NOT EXISTS has_divisions BOOLEAN NOT NULL DEFAULT FALSE;

-- Division label within the club's league -- the UEFA Nations League's A/B/C/D tiers, rendered as
-- headers inside the single Nations League tab (docs/design/2026-08-07-nations-league-design.md
-- decision 1). Nullable because every other league is undivided, and a club with no label renders
-- headerless above the first division rather than disappearing.
--
-- Deliberately NOT named by create_club/rename_club in queries.py (decision 5): those statements
-- replace every field they list, so an admin PATCH that forwarded a subset would write NULL here --
-- the same trap patchClubLeagues in admin.js already works around for the name columns.
ALTER TABLE clubs ADD COLUMN IF NOT EXISTS group_label TEXT;

-- Party ideology categorization (docs/design/2026-07-16-party-categorization-analytics-design.md).
-- Independent columns on both tables, not shared through party_lineage below -- a split/merged party
-- can be ideologically distinct from its lineage predecessor (e.g. Otzma Yehudit vs. Religious
-- Zionist). economic/security are nullable: several real parties genuinely have no stated position
-- (rather than a fabricated "0" implying a confirmed centrist stance).
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS bloc TEXT
    CHECK (bloc IN ('bibi', 'opposition', 'unaligned'));
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS economic INTEGER
    CHECK (economic BETWEEN -3 AND 3);
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS security INTEGER
    CHECK (security BETWEEN -3 AND 3);
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS sector TEXT
    CHECK (sector IN ('secular', 'traditional', 'religious_zionist', 'haredi', 'arab'));
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS tags TEXT[];

ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS bloc TEXT
    CHECK (bloc IN ('bibi', 'opposition', 'unaligned'));
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS economic INTEGER
    CHECK (economic BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS security INTEGER
    CHECK (security BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS sector TEXT
    CHECK (sector IN ('secular', 'traditional', 'religious_zionist', 'haredi', 'arab'));
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS tags TEXT[];

-- Families: a closed, deliberately-shared vocabulary naming what parties have in common, as opposed
-- to `tags`, which is per-party evidence and 71% singletons on this table. family_evidence records
-- whether the assignment came from the voting record or from the platform alone -- eight upcoming
-- parties have no usable record. See docs/design/2026-07-30-party-families-club-traits-design.md.
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS families TEXT[];
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS family_evidence TEXT
    CHECK (family_evidence IS NULL OR family_evidence IN ('record', 'platform'));

-- Religion-and-state policy axis (docs/design/2026-07-21-religiosity-axis-design.md).
-- -3 separationist .. +3 theocratic. Measures what a party wants the STATE to do about religion,
-- NOT how observant its base is -- that is `sector`, which is categorical and cannot be averaged.
-- Nullable on the same terms as economic/security: the Arab parties are scoped out entirely
-- (Decision 3), since "how religiously Jewish should Israel be" is not a question they answer.
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS religiosity INTEGER
    CHECK (religiosity BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS religiosity INTEGER
    CHECK (religiosity BETWEEN -3 AND 3);

-- Stable seed identity (2026-08-12). Every statement in seed.sql matches on seed_key and
-- nothing else. Display names cannot serve as identity: the admin endpoints overwrite the
-- legacy `name` column with name_he on ANY save (including a no-op one), and seed.sql used
-- to rewrite its own name_en literals -- 104 of 212 production clubs and 3 of 10 leagues
-- carry a drifted `name` because of it. seed_key is never displayed, never writable through
-- the API and never changes once assigned.
--
-- NULL means "created through the admin UI", which is what makes seed.sql's declarative
-- removal safe: it only ever deletes rows it owns. The index is partial so it only covers
-- rows that actually carry a key, stating that intent explicitly -- NOT because a plain
-- unique index would reject multiple NULLs; Postgres treats NULLs as distinct for
-- uniqueness, so a plain unique index already permits unlimited NULLs.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS seed_key TEXT;
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS seed_key TEXT;
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS seed_key TEXT;
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS seed_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS leagues_seed_key_uidx          ON leagues (seed_key)          WHERE seed_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS clubs_seed_key_uidx            ON clubs (seed_key)            WHERE seed_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS previous_parties_seed_key_uidx ON previous_parties (seed_key) WHERE seed_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS upcoming_parties_seed_key_uidx ON upcoming_parties (seed_key) WHERE seed_key IS NOT NULL;

-- Column-level provenance (2026-08-12). Lists the columns a human has actually CHANGED
-- through the admin UI; seed.sql overwrites every column not listed here.
--
-- This inverts the old rule. Names and logo_url used to be guarded with COALESCE/IS NULL so
-- they could only fill an empty cell -- which meant editing a literal reached a fresh
-- database only, and moving an already-seeded value needed a separate patch statement
-- appended to the file. There were about twenty such patches. With the exception recorded
-- explicitly, the base statement can be authoritative and no patch is needed.
--
-- Empty for every existing row on purpose: verified 2026-08-12 that production and a fresh
-- seed differ in 107 fields, ALL of them the vestigial legacy `name` column, so no live
-- admin edit exists to preserve.
ALTER TABLE leagues           ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE clubs             ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE previous_parties  ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE upcoming_parties  ADD COLUMN IF NOT EXISTS admin_edited TEXT[] NOT NULL DEFAULT '{}';

-- Moved here from seed.sql (design decision 6): this is a migration, and schema.sql is the
-- migration file. It must run BEFORE seed.sql's adoption statements, which key on name_en
-- and name_he -- a database restored from a snapshot old enough to predate those columns
-- would otherwise have every row fail to adopt and raise the duplicate guard.
UPDATE leagues           SET name_en = name WHERE name_en IS NULL;
UPDATE clubs             SET name_en = name WHERE name_en IS NULL;
UPDATE previous_parties  SET name_he = name WHERE name_he IS NULL;
UPDATE upcoming_parties  SET name_he = name WHERE name_he IS NULL;

-- Continuity, independent of ideology: which upcoming party continues which previous party. A split
-- is multiple rows sharing one previous_party_id; a merge is multiple rows sharing one
-- upcoming_party_id; a party with no row on either side is a genuine dead end or a fresh entrant.
CREATE TABLE IF NOT EXISTS party_lineage (
    previous_party_id INTEGER NOT NULL REFERENCES previous_parties(id),
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id),
    PRIMARY KEY (previous_party_id, upcoming_party_id)
);

-- Per-voter vote-switch classification (worker-computed, same league/club/national scoping pattern
-- as the existing rollup_previous/rollup_national_previous tables).
CREATE TABLE IF NOT EXISTS rollup_vote_switch (
    league_id INTEGER,
    club_id INTEGER,
    switch_status TEXT NOT NULL CHECK (switch_status IN
        ('new_voter', 'undecided', 'stayed', 'hedging', 'switched')),
    vote_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rollup_national_vote_switch (
    switch_status TEXT NOT NULL CHECK (switch_status IN
        ('new_voter', 'undecided', 'stayed', 'hedging', 'switched')),
    vote_count INTEGER NOT NULL
);

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

-- Salted hash of the voter's IP, used ONLY to rate-limit ballot stuffing (see app.py). Never the raw
-- address: the hash is one-way and salted with VOTE_IP_SALT, so the table holds no address and the
-- hashes are useless outside this deployment. Rotating the salt resets all limits.
--
-- ADD COLUMN IF NOT EXISTS rather than editing the CREATE above, because schema.sql is re-run on
-- every backend start (db.init_db) and must stay idempotent -- CREATE TABLE IF NOT EXISTS would skip
-- an existing votes table entirely, so a plain column edit would never reach a live database.
ALTER TABLE votes ADD COLUMN IF NOT EXISTS ip_hash TEXT;
CREATE INDEX IF NOT EXISTS votes_ip_hash_created_at_idx ON votes (ip_hash, created_at);

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

-- Ballot weight for the intended-vote lean (docs/design/2026-08-10-intended-vote-lean-design.md).
-- vote_count counts PICKS -- a ballot may name up to 3 parties -- so averaging on it gives a
-- 3-party ballot triple the say of a 1-party one. weight carries SUM(1.0/k) so each ballot totals
-- exactly 1. vote_count stays INTEGER and keeps driving the displayed breakdown bars.
-- ADD COLUMN IF NOT EXISTS, not a CREATE TABLE edit: schema.sql re-runs on every backend boot and
-- CREATE TABLE IF NOT EXISTS skips an existing table, so a CREATE edit never reaches a live DB.
ALTER TABLE rollup_upcoming ADD COLUMN IF NOT EXISTS weight NUMERIC NOT NULL DEFAULT 0;
ALTER TABLE rollup_national_upcoming ADD COLUMN IF NOT EXISTS weight NUMERIC NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS rollup_national_previous_upcoming (
    previous_party_id INTEGER,
    upcoming_party_id INTEGER,
    vote_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rollup_national_previous_upcoming_previous ON rollup_national_previous_upcoming (previous_party_id);
CREATE INDEX IF NOT EXISTS idx_rollup_national_previous_upcoming_upcoming ON rollup_national_previous_upcoming (upcoming_party_id);
