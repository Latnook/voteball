import os
import sys
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('DB_HOST', 'localhost')
os.environ.setdefault('DB_NAME', 'postgres')
os.environ.setdefault('DB_USER', 'postgres')
os.environ.setdefault('DB_PASS', 'test')
os.environ.setdefault('DB_SSLMODE', 'disable')

import db as db_module

SCHEMA = '''
CREATE TABLE leagues (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE clubs (id SERIAL PRIMARY KEY, league_id INTEGER NOT NULL REFERENCES leagues(id), domestic_league_id INTEGER REFERENCES leagues(id), name TEXT NOT NULL);
CREATE TABLE previous_parties (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE upcoming_parties (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE votes (
    id SERIAL PRIMARY KEY,
    previous_vote_status TEXT NOT NULL,
    previous_party_id INTEGER REFERENCES previous_parties(id),
    upcoming_vote_status TEXT NOT NULL,
    cookie_token TEXT NOT NULL UNIQUE
);
CREATE TABLE vote_clubs (
    vote_id INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    club_id INTEGER NOT NULL REFERENCES clubs(id),
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    PRIMARY KEY (vote_id, club_id, league_id)
);
CREATE TABLE vote_leagues (
    vote_id INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    PRIMARY KEY (vote_id, league_id)
);
CREATE TABLE vote_upcoming_parties (
    vote_id INTEGER NOT NULL REFERENCES votes(id) ON DELETE CASCADE,
    upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id) ON DELETE CASCADE,
    PRIMARY KEY (vote_id, upcoming_party_id)
);
CREATE TABLE alert_state (id INTEGER PRIMARY KEY DEFAULT 1, last_seen_total INTEGER NOT NULL DEFAULT 0);
CREATE TABLE rollup_previous (league_id INTEGER NOT NULL, club_id INTEGER, previous_party_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_upcoming (league_id INTEGER NOT NULL, club_id INTEGER, upcoming_party_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_previous_upcoming (previous_party_id INTEGER, upcoming_party_id INTEGER, league_id INTEGER, club_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_national_previous (previous_party_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_national_upcoming (upcoming_party_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_national_previous_upcoming (previous_party_id INTEGER, upcoming_party_id INTEGER, vote_count INTEGER NOT NULL);
CREATE TABLE party_lineage (previous_party_id INTEGER NOT NULL REFERENCES previous_parties(id), upcoming_party_id INTEGER NOT NULL REFERENCES upcoming_parties(id), PRIMARY KEY (previous_party_id, upcoming_party_id));
CREATE TABLE rollup_vote_switch (league_id INTEGER, club_id INTEGER, switch_status TEXT NOT NULL, vote_count INTEGER NOT NULL);
CREATE TABLE rollup_national_vote_switch (switch_status TEXT NOT NULL, vote_count INTEGER NOT NULL);
'''


@pytest.fixture
def conn():
    connection = db_module.get_db()
    cur = connection.cursor()
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, vote_clubs, vote_leagues, votes,
            rollup_previous, rollup_upcoming, rollup_previous_upcoming,
            rollup_national_previous, rollup_national_upcoming, rollup_national_previous_upcoming,
            rollup_vote_switch, rollup_national_vote_switch, party_lineage,
            clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE
    ''')
    cur.execute(SCHEMA)
    connection.commit()
    cur.close()

    cur = connection.cursor()
    cur.execute('INSERT INTO alert_state (id, last_seen_total) VALUES (1, 0)')
    connection.commit()
    cur.close()

    yield connection
    connection.close()
