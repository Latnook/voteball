import psycopg2
import pytest

import db as db_module


def test_all_seeded_rows_have_both_languages(conn):
    cur = conn.cursor()
    for table in ('leagues', 'clubs', 'previous_parties', 'upcoming_parties'):
        cur.execute(f'SELECT COUNT(*) FROM {table} WHERE name_en IS NULL OR name_he IS NULL')
        assert cur.fetchone()[0] == 0, f'{table} has rows missing name_en/name_he'
    cur.close()


def test_seeded_row_counts(conn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM leagues')
    assert cur.fetchone()[0] == 8
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 165
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 13
    cur.execute('SELECT COUNT(*) FROM upcoming_parties')
    assert cur.fetchone()[0] == 16
    cur.close()


def test_sample_translations(conn):
    cur = conn.cursor()
    cur.execute("SELECT name_he FROM leagues WHERE name_en = 'Premier League'")
    assert cur.fetchone()[0] == 'הפרמייר ליג'
    cur.execute("SELECT name_he FROM clubs WHERE name_en = 'Real Madrid' LIMIT 1")
    assert cur.fetchone()[0] == 'ריאל מדריד'
    cur.execute("SELECT name_en FROM previous_parties WHERE name_he = 'הליכוד'")
    assert cur.fetchone()[0] == 'Likud'
    cur.execute("SELECT name_en FROM upcoming_parties WHERE name_he = 'ביחד'")
    assert cur.fetchone()[0] == 'Together'
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


def test_party_ideology_columns_and_lineage_table_exist(conn):
    cur = conn.cursor()
    cur.execute('''
        UPDATE previous_parties SET bloc = 'bibi', economic = 2, security = 2,
            sector = 'traditional', tags = ARRAY['test-tag']
        WHERE name = 'הליכוד'
    ''')
    cur.execute("SELECT bloc, economic, security, sector, tags FROM previous_parties WHERE name = 'הליכוד'")
    row = cur.fetchone()
    assert row == ('bibi', 2, 2, 'traditional', ['test-tag'])

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE previous_parties SET bloc = 'not-a-real-bloc' WHERE name = 'הליכוד'")
    conn.rollback()

    cur.execute("SELECT id FROM previous_parties WHERE name = 'יש עתיד'")
    prev_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties WHERE name = 'עוצמה יהודית'")
    up_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_id, up_id)
    )
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id FROM party_lineage WHERE previous_party_id = %s AND upcoming_party_id = %s',
        (prev_id, up_id)
    )
    assert cur.fetchone() == (prev_id, up_id)
    conn.commit()
    cur.close()


def test_vote_switch_rollup_tables_exist(conn):
    cur = conn.cursor()
    cur.execute('''
        INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count)
        VALUES (NULL, NULL, 'stayed', 5)
    ''')
    cur.execute('''
        INSERT INTO rollup_national_vote_switch (switch_status, vote_count)
        VALUES ('stayed', 5)
    ''')
    conn.commit()
    cur.execute('SELECT switch_status, vote_count FROM rollup_national_vote_switch')
    assert cur.fetchone() == ('stayed', 5)

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (NULL, NULL, 'not-a-real-status', 1)")
    conn.rollback()
    cur.close()


def test_seeded_parties_have_ideology_classification(conn):
    cur = conn.cursor()
    cur.execute("SELECT name_en, bloc, sector FROM previous_parties WHERE name_he != 'אחר'")
    for name_en, bloc, sector in cur.fetchall():
        assert bloc is not None, f'{name_en} (previous) missing bloc'
        assert sector is not None, f'{name_en} (previous) missing sector'

    cur.execute("SELECT bloc, economic, security, sector FROM previous_parties WHERE name_he = 'אחר'")
    assert cur.fetchone() == (None, None, None, None)

    cur.execute('SELECT name_en, bloc, sector FROM upcoming_parties')
    for name_en, bloc, sector in cur.fetchall():
        assert bloc is not None, f'{name_en} (upcoming) missing bloc'
        assert sector is not None, f'{name_en} (upcoming) missing sector'

    cur.execute("SELECT economic, security, tags FROM previous_parties WHERE name_he = 'המחנה הממלכתי'")
    economic, security, tags = cur.fetchone()
    assert economic == 1
    assert security is None
    assert 'avoids-security-topic' in tags
    cur.close()


def test_seed_rerun_survives_league_name_drift(conn):
    # Mirrors what an admin rename does in production (queries.py's rename_league/rename_club
    # always set the legacy `name` column to the Hebrew value) -- reproduces the 2026-07-17
    # incident where this left seed.sql unable to recognize UCL/EPL already exist, so it
    # inserted phantom duplicate leagues, duplicated every club under them, and crashed with a
    # clubs_name_en_uidx UniqueViolation on the very next backend pod boot.
    cur = conn.cursor()
    cur.execute("UPDATE leagues SET name = name_he WHERE name_en = 'UEFA Champions League'")
    cur.execute("UPDATE leagues SET name = name_he WHERE name_en = 'Premier League'")
    conn.commit()
    cur.close()

    db_module.init_db(conn)  # must not raise

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM leagues')
    assert cur.fetchone()[0] == 8, 'league name drift must not create a phantom duplicate league'
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 165, 'league name drift must not duplicate that league\'s clubs'
    cur.execute("SELECT COUNT(*) FROM clubs WHERE name_en = 'Paris Saint-Germain'")
    assert cur.fetchone()[0] == 1
    cur.close()


def test_seeded_party_lineage(conn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM party_lineage')
    assert cur.fetchone()[0] == 13

    cur.execute('''
        SELECT u.name_en FROM party_lineage pl
        JOIN previous_parties p ON p.id = pl.previous_party_id
        JOIN upcoming_parties u ON u.id = pl.upcoming_party_id
        WHERE p.name_he = 'הציונות הדתית'
        ORDER BY u.name_en
    ''')
    successors = {r[0] for r in cur.fetchall()}
    assert successors == {'Otzma Yehudit', 'Religious Zionist Party'}

    cur.execute('''
        SELECT p.name_en FROM party_lineage pl
        JOIN previous_parties p ON p.id = pl.previous_party_id
        JOIN upcoming_parties u ON u.id = pl.upcoming_party_id
        WHERE u.name_he = 'הדמוקרטים'
        ORDER BY p.name_en
    ''')
    predecessors = {r[0] for r in cur.fetchall()}
    assert predecessors == {'Labor', 'Meretz'}
    cur.close()
