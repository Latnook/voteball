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
    assert cur.fetchone()[0] == 9
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 205
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 13
    cur.execute('SELECT COUNT(*) FROM upcoming_parties')
    assert cur.fetchone()[0] == 18
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


def test_all_seeded_rows_have_russian(conn):
    cur = conn.cursor()
    for table in ('leagues', 'clubs', 'previous_parties', 'upcoming_parties'):
        cur.execute(f'SELECT COUNT(*) FROM {table} WHERE name_ru IS NULL')
        assert cur.fetchone()[0] == 0, f'{table} has rows missing name_ru'
    cur.close()


def test_sample_russian_translations(conn):
    cur = conn.cursor()
    # Keyed on name_en = 'Premier League', i.e. AFTER seed.sql rewrites it from 'EPL'. The Russian
    # block keys on the legacy `name` column precisely so this row still gets filled.
    cur.execute("SELECT name_ru FROM leagues WHERE name_en = 'Premier League'")
    assert cur.fetchone()[0] == 'Премьер-лига'
    cur.execute("SELECT name_ru FROM clubs WHERE name_en = 'Maccabi Haifa' LIMIT 1")
    assert cur.fetchone()[0] == 'Маккаби Хайфа'
    cur.execute("SELECT name_ru FROM previous_parties WHERE name_he = 'ישראל ביתנו'")
    assert cur.fetchone()[0] == 'Наш дом Израиль'
    cur.execute("SELECT name_ru FROM upcoming_parties WHERE name_he = 'הדמוקרטים'")
    assert cur.fetchone()[0] == 'Ха-Демократим'
    cur.close()


def test_seeded_russian_names_are_cyrillic(conn):
    # A Latin homoglyph (P/A/M for Cyrillic Р/А/М) is invisible on screen but breaks Russian text
    # search and collation -- one reached the translation worksheet and was caught by codepoint
    # inspection, not by reading. Assert the property rather than trusting review.
    cur = conn.cursor()
    for table in ('leagues', 'clubs', 'previous_parties', 'upcoming_parties'):
        cur.execute(f"SELECT name_en, name_ru FROM {table} WHERE name_ru ~ '[A-Za-z]'")
        offenders = cur.fetchall()
        assert offenders == [], f'{table} has Latin characters in name_ru: {offenders}'
    cur.close()


def test_league_names_survive_name_drift(conn):
    # rename_league sets the legacy `name` column to name_he -- even on a no-op rename -- so on any
    # cluster where a league has ever been saved through the admin UI, `name` no longer holds 'UCL'.
    # A seed block keyed on `name` alone then silently leaves those leagues untranslated, which is
    # exactly how UCL, EPL and Bundesliga lost their Russian names. Keying on name_en alone fails
    # differently (seed.sql rewrites it unguarded), so the block matches on `name OR name_he`.
    cur = conn.cursor()
    cur.execute('UPDATE leagues SET name = name_he')
    cur.execute('UPDATE leagues SET name_ru = NULL')
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute('SELECT name_en FROM leagues WHERE name_ru IS NULL')
    assert cur.fetchall() == [], 'league name drift must not leave leagues without a Russian name'
    cur.execute("SELECT name_ru FROM leagues WHERE name_en = 'UEFA Champions League'")
    assert cur.fetchone()[0] == 'Лига чемпионов'
    cur.execute("SELECT name_ru FROM leagues WHERE name_en = 'Bundesliga'")
    assert cur.fetchone()[0] == 'Бундеслига'
    cur.execute('SELECT COUNT(*) FROM leagues')
    assert cur.fetchone()[0] == 9, 'the OR-match must not create or duplicate rows'
    cur.close()


def test_admin_renamed_league_is_not_overwritten(conn):
    # The other half of the same guard: filling an empty name_ru must never revert a name a human
    # typed. COALESCE per column is what allows both at once.
    cur = conn.cursor()
    cur.execute(
        "UPDATE leagues SET name = 'ליגת האלופות שלי', name_he = 'ליגת האלופות שלי', "
        "name_ru = 'МОЯ ЛИГА' WHERE name_en = 'UEFA Champions League'"
    )
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT name_he, name_ru FROM leagues WHERE name_en = 'UEFA Champions League'")
    assert cur.fetchone() == ('ליגת האלופות שלי', 'МОЯ ЛИГА')
    cur.close()


BRAZIL_CREST = (
    'https://upload.wikimedia.org/wikipedia/commons/3/32/'
    'Confedera%C3%A7%C3%A3o_Brasileira_de_Futebol_logo_%282020%29.svg'
)


def test_seeded_world_cup_flag_is_replaced_by_the_crest(conn):
    # The national-team block seeded flagcdn.com flags until 2026-07-30, so on every already-seeded
    # database the crests are only reachable if the guard also accepts that known-seeded value. A
    # plain "AND logo_url IS NULL" guard makes this block a no-op in production -- which is exactly
    # how a guarded logo_url edit silently fails to ship.
    cur = conn.cursor()
    cur.execute("UPDATE clubs SET logo_url = 'https://flagcdn.com/br.svg' WHERE name_en = 'Brazil'")
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT logo_url FROM clubs WHERE name_en = 'Brazil'")
    assert cur.fetchone()[0] == BRAZIL_CREST
    cur.close()


def test_admin_curated_club_logo_survives_the_crest_seed(conn):
    # The other half of that guard: widening it to accept the old flag must not widen it to accept
    # anything an admin typed into the admin UI's Logo URL field.
    cur = conn.cursor()
    cur.execute("UPDATE clubs SET logo_url = 'https://example.test/my-brazil.png' WHERE name_en = 'Brazil'")
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT logo_url FROM clubs WHERE name_en = 'Brazil'")
    assert cur.fetchone()[0] == 'https://example.test/my-brazil.png'
    cur.close()


def test_all_world_cup_clubs_carry_a_crest(conn):
    # All 48 qualified nations, not just the sample the two tests above pin: a name_en typo in the
    # VALUES block matches nothing and leaves that nation on a monogram, with no error anywhere.
    cur = conn.cursor()
    cur.execute(
        "SELECT c.name_en, c.logo_url FROM clubs c "
        "JOIN leagues l ON l.id = c.league_id "
        # name OR name_en, for the same reason seed.sql's leagues block does: neither column alone
        # identifies a league across every state the table can be in (see services/backend/CLAUDE.md).
        "WHERE (l.name = 'World Cup 2026' OR l.name_en = 'World Cup 2026')"
    )
    rows = cur.fetchall()
    assert len(rows) == 48
    assert [r for r in rows if not (r[1] or '').startswith('https://upload.wikimedia.org/')] == []
    cur.close()


def test_partial_unique_index_rejects_duplicate_name_ru(conn):
    cur = conn.cursor()
    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute(
            "INSERT INTO previous_parties (name, name_en, name_he, name_ru) "
            "VALUES ('z', 'Unique English', 'ייחודי בעברית', 'Ликуд')"
        )
    conn.rollback()
    cur.close()


def test_partial_unique_index_allows_many_null_name_ru(conn):
    # The index is partial (WHERE name_ru IS NOT NULL). A plain unique index would make every
    # untranslated row collide with every other, which is what makes shipping the column ahead of
    # a translation safe.
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO previous_parties (name, name_en, name_he) VALUES "
        "('nr1', 'No Russian One', 'בלי רוסית א'), ('nr2', 'No Russian Two', 'בלי רוסית ב')"
    )
    conn.commit()
    cur.execute('SELECT COUNT(*) FROM previous_parties WHERE name_ru IS NULL')
    assert cur.fetchone()[0] == 2
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
            sector = 'traditional', religiosity = 2, tags = ARRAY['test-tag']
        WHERE name = 'הליכוד'
    ''')
    cur.execute("SELECT bloc, economic, security, sector, religiosity, tags FROM previous_parties WHERE name = 'הליכוד'")
    row = cur.fetchone()
    assert row == ('bibi', 2, 2, 'traditional', 2, ['test-tag'])

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE previous_parties SET bloc = 'not-a-real-bloc' WHERE name = 'הליכוד'")
    conn.rollback()

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE previous_parties SET religiosity = -4 WHERE name = 'הליכוד'")
    conn.rollback()

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE previous_parties SET religiosity = 4 WHERE name = 'הליכוד'")
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

    cur.execute("SELECT bloc, economic, security, sector, religiosity FROM previous_parties WHERE name_he = 'אחר'")
    assert cur.fetchone() == (None, None, None, None, None)

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
    assert cur.fetchone()[0] == 9, 'league name drift must not create a phantom duplicate league'
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 205, 'league name drift must not duplicate that league\'s clubs'
    cur.execute("SELECT COUNT(*) FROM clubs WHERE name_en = 'Paris Saint-Germain'")
    assert cur.fetchone()[0] == 1
    cur.close()


def test_seeded_party_lineage(conn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM party_lineage')
    assert cur.fetchone()[0] == 14

    cur.execute('''
        SELECT u.name_en FROM party_lineage pl
        JOIN previous_parties p ON p.id = pl.previous_party_id
        JOIN upcoming_parties u ON u.id = pl.upcoming_party_id
        WHERE p.name_he = 'הציונות הדתית'
        ORDER BY u.name_en
    ''')
    successors = {r[0] for r in cur.fetchall()}
    assert successors == {'Noam', 'Otzma Yehudit', 'Religious Zionist Party'}

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


def test_family_columns_round_trip_and_constrain(conn):
    cur = conn.cursor()
    cur.execute("""
        UPDATE upcoming_parties
        SET families = ARRAY['welfare-state', 'cost-of-living'], family_evidence = 'record'
        WHERE name_he = 'ש"ס'
    """)
    cur.execute("SELECT families, family_evidence FROM upcoming_parties WHERE name_he = 'ש\"ס'")
    families, evidence = cur.fetchone()
    assert families == ['welfare-state', 'cost-of-living']
    assert evidence == 'record'

    cur.execute("UPDATE upcoming_parties SET family_evidence = 'platform' WHERE name_he = 'ש\"ס'")
    cur.execute("SELECT family_evidence FROM upcoming_parties WHERE name_he = 'ש\"ס'")
    assert cur.fetchone()[0] == 'platform'

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE upcoming_parties SET family_evidence = 'vibes' WHERE name_he = 'ש\"ס'")
    conn.rollback()
    cur.close()


def test_nations_league_is_seeded_after_the_world_cup(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT name_en, name_he, name_ru, sort_order, logo_url FROM leagues "
        "WHERE name_en = 'Nations League'"
    )
    row = cur.fetchone()
    assert row is not None, 'Nations League league row is missing'
    name_en, name_he, name_ru, sort_order, logo_url = row
    assert (name_he, name_ru) == ('ליגת האומות', 'Лига наций УЕФА')
    assert logo_url == '/logos/uefa-nations-league.svg'

    cur.execute("SELECT sort_order FROM leagues WHERE name_en = 'World Cup 2026'")
    world_cup_order = cur.fetchone()[0]
    assert sort_order > world_cup_order
    cur.close()


NATIONS_LEAGUE_INSERTED_NATIONS = [
    'Albania', 'Andorra', 'Armenia', 'Azerbaijan', 'Belarus', 'Bulgaria', 'Cyprus', 'Denmark',
    'Estonia', 'Faroe Islands', 'Finland', 'Georgia', 'Gibraltar', 'Greece', 'Hungary', 'Iceland',
    'Israel', 'Italy', 'Kazakhstan', 'Kosovo', 'Latvia', 'Liechtenstein', 'Lithuania', 'Luxembourg',
    'Malta', 'Moldova', 'Montenegro', 'North Macedonia', 'Northern Ireland', 'Poland',
    'Republic of Ireland', 'Romania', 'San Marino', 'Serbia', 'Slovakia', 'Slovenia', 'Ukraine',
    'Wales',
]


def test_nations_league_inserted_nations_are_seeded_with_divisions(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en, c.group_label
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id
           WHERE l.name_en = 'Nations League'"""
    )
    seeded = dict(cur.fetchall())
    assert sorted(seeded) == sorted(NATIONS_LEAGUE_INSERTED_NATIONS)
    assert all(label in ('A', 'B', 'C', 'D') for label in seeded.values()), seeded
    cur.close()


def test_every_nations_league_team_has_a_crest_and_three_names(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'
             AND (c.logo_url IS NULL OR c.name_he IS NULL OR c.name_ru IS NULL)"""
    )
    assert cur.fetchall() == []
    cur.close()


LINKED_WORLD_CUP_NATIONS = [
    'Austria', 'Belgium', 'Bosnia and Herzegovina', 'Croatia', 'Czech Republic', 'England',
    'France', 'Germany', 'Netherlands', 'Norway', 'Portugal', 'Scotland', 'Spain', 'Sweden',
    'Switzerland', 'Turkey',
]


def test_shared_nations_are_linked_not_duplicated(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT name_en, COUNT(*) FROM clubs WHERE name_en = ANY(%s) GROUP BY name_en HAVING COUNT(*) > 1",
        (LINKED_WORLD_CUP_NATIONS,)
    )
    assert cur.fetchall() == [], 'a shared nation was inserted twice instead of linked'

    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues wc ON wc.id = c.league_id AND wc.name_en = 'World Cup 2026'
           JOIN leagues nl ON nl.id = c.domestic_league_id AND nl.name_en = 'Nations League'
           WHERE c.name_en = ANY(%s)""",
        (LINKED_WORLD_CUP_NATIONS,)
    )
    assert sorted(r[0] for r in cur.fetchall()) == sorted(LINKED_WORLD_CUP_NATIONS)
    cur.close()


def test_nations_league_has_54_votable_teams(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT COUNT(*) FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'"""
    )
    assert cur.fetchone()[0] == 54
    cur.close()


def test_nations_league_divisions_are_fully_populated(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.group_label, COUNT(*)
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'
           GROUP BY c.group_label"""
    )
    assert dict(cur.fetchall()) == {'A': 16, 'B': 16, 'C': 16, 'D': 6}
    cur.close()


def test_every_nations_league_team_including_linked_has_a_crest(conn):
    # The 16 linked nations must keep the crest and names their World Cup row already carries --
    # they are deliberately absent from the Nations League crest block (a duplicate name_en key in a
    # VALUES block makes the join ambiguous), so this is what proves they were not left blank.
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'
             AND (c.logo_url IS NULL OR c.name_he IS NULL OR c.name_ru IS NULL)"""
    )
    assert cur.fetchall() == []
    cur.close()
