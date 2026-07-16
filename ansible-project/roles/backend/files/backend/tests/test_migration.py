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
    assert cur.fetchone()[0] == 136
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

    cur.execute("SELECT id FROM previous_parties WHERE name = 'הליכוד'")
    prev_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties WHERE name = 'הליכוד'")
    up_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_id, up_id)
    )
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id FROM party_lineage WHERE previous_party_id = %s',
        (prev_id,)
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
