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
    assert cur.fetchone()[0] == 14
    cur.execute('SELECT COUNT(*) FROM upcoming_parties')
    assert cur.fetchone()[0] == 17
    cur.close()


def test_sample_translations(conn):
    cur = conn.cursor()
    cur.execute("SELECT name_he FROM leagues WHERE name_en = 'Premier League'")
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
