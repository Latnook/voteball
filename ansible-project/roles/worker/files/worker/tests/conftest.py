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
CREATE TABLE clubs (id SERIAL PRIMARY KEY, league_id INTEGER NOT NULL REFERENCES leagues(id), name TEXT NOT NULL);
CREATE TABLE previous_parties (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE upcoming_parties (id SERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE votes (
    id SERIAL PRIMARY KEY,
    league_id INTEGER NOT NULL REFERENCES leagues(id),
    club_id INTEGER REFERENCES clubs(id),
    previous_vote_status TEXT NOT NULL,
    previous_party_id INTEGER REFERENCES previous_parties(id),
    upcoming_vote_status TEXT NOT NULL,
    cookie_token TEXT NOT NULL UNIQUE
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
'''


@pytest.fixture
def conn():
    connection = db_module.get_db()
    cur = connection.cursor()
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, votes, rollup_previous,
            rollup_upcoming, rollup_previous_upcoming, clubs, leagues, previous_parties,
            upcoming_parties, alert_state CASCADE
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
