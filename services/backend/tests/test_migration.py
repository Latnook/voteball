import os

import psycopg2
import psycopg2.sql
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
    assert cur.fetchone()[0] == 10
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 226
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 13
    cur.execute('SELECT COUNT(*) FROM upcoming_parties')
    assert cur.fetchone()[0] == 19
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
    assert cur.fetchone()[0] == 10, 'the OR-match must not create or duplicate rows'
    cur.close()


def test_admin_renamed_league_is_not_overwritten(conn):
    # The other half of the same guard: an admin edit must never be reverted on the next boot.
    # Since the 2026-08-12 seed_key/admin_edited redesign, protection is per-column and explicit
    # (admin_edited), not implicit in "the value is already non-NULL" -- so this now records the
    # edit the same way the admin API does. `name` itself is never touched by the leagues UPDATE
    # regardless of admin_edited, so it needs no entry there.
    cur = conn.cursor()
    cur.execute(
        "UPDATE leagues SET name = 'ליגת האלופות שלי', name_he = 'ליגת האלופות שלי', "
        "name_ru = 'МОЯ ЛИГА', admin_edited = ARRAY['name_he', 'name_ru'] "
        "WHERE name_en = 'UEFA Champions League'"
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
    # Protection is now admin_edited, not "logo_url IS NULL (or still the old flag) never matches
    # a value an admin set" -- so the choice has to be recorded as an edit the same way the admin
    # API does.
    cur = conn.cursor()
    cur.execute("UPDATE clubs SET logo_url = 'https://example.test/my-brazil.png', "
                "admin_edited = ARRAY['logo_url'] WHERE name_en = 'Brazil'")
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
    assert cur.fetchone()[0] == 10, 'league name drift must not create a phantom duplicate league'
    cur.execute('SELECT COUNT(*) FROM clubs')
    assert cur.fetchone()[0] == 226, 'league name drift must not duplicate that league\'s clubs'
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


# Clubs whose ONLY seeded league is the Europa League -- this app seeds six domestic leagues
# (Israeli Premier League, Liga Leumit, Premier League, La Liga, Bundesliga, Serie A) and every
# club here plays in none of them, so the competition is the only place it can be voted for. The list
# used to enumerate the absent domestic leagues instead; it was already missing Poland's when
# Lech Poznan was added, which is what enumerating rather than stating the rule costs.
EUROPA_LEAGUE_ONLY_CLUBS = [
    'Celje', 'Celtic', 'Dinamo Zagreb', 'Lech Poznań', 'Levski Sofia', 'Lyon', 'NEC',
    'Olympiacos', 'Olympique de Marseille', 'Sparta Prague', 'Stade Rennais', 'Sturm Graz',
    'Torreense', 'Union Saint-Gilloise',
]

# Clubs already seeded under a domestic league that gain the Europa League as their SECOND league.
LINKED_EUROPA_LEAGUE_CLUBS = [
    'AC Milan', 'Bayer Leverkusen', 'Bournemouth', 'Celta Vigo', 'Crystal Palace',
    "Hapoel Be'er Sheva", 'Juventus', 'Real Sociedad', 'Sunderland', 'TSG Hoffenheim',
]


def test_europa_league_sits_between_the_champions_league_and_the_world_cup(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT name, name_he, name_ru, sort_order, logo_url FROM leagues "
        "WHERE name_en = 'UEFA Europa League'"
    )
    row = cur.fetchone()
    assert row is not None, 'UEFA Europa League league row is missing'
    name, name_he, name_ru, sort_order, logo_url = row
    assert (name_he, name_ru) == ('הליגה האירופית', 'Лига Европы')
    assert logo_url == '/logos/uefa-europa-league.svg'
    # The legacy `name` column holds the final English name, unlike UCL's 'UCL' placeholder: nothing
    # renames this league, which is what lets the leagues INSERT skip a third identity branch for it.
    assert name == 'UEFA Europa League'

    cur.execute(
        "SELECT name_en, sort_order FROM leagues "
        "WHERE name_en IN ('UEFA Champions League', 'World Cup 2026')"
    )
    orders = dict(cur.fetchall())
    assert orders['UEFA Champions League'] < sort_order < orders['World Cup 2026']
    cur.close()


SUPERSEDED_EUROPA_LEAGUE_NAME_RU = 'Лига Европы УЕФА'


def test_europa_league_russian_rename_reaches_an_already_seeded_row(conn):
    # The names VALUES block only COALESCEs an empty name_ru, so editing the tuple never reaches a
    # database seeded with the old name. Only the separate rename statement moves it.
    cur = conn.cursor()
    cur.execute(
        "UPDATE leagues SET name_ru = %s WHERE name_en = 'UEFA Europa League'",
        (SUPERSEDED_EUROPA_LEAGUE_NAME_RU,),
    )
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT name_ru FROM leagues WHERE name_en = 'UEFA Europa League'")
    assert cur.fetchone()[0] == 'Лига Европы'
    cur.close()


def test_europa_league_russian_rename_leaves_an_admin_choice_alone(conn):
    # Protection is now admin_edited, not "this exact superseded string never matches an admin's
    # own text" -- so the choice has to be recorded as an edit the same way the admin API does.
    admin_choice = 'Еврокубок'
    cur = conn.cursor()
    cur.execute(
        "UPDATE leagues SET name_ru = %s, admin_edited = ARRAY['name_ru'] "
        "WHERE name_en = 'UEFA Europa League'",
        (admin_choice,),
    )
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT name_ru FROM leagues WHERE name_en = 'UEFA Europa League'")
    assert cur.fetchone()[0] == admin_choice
    cur.close()


def test_europa_league_only_clubs_are_seeded_under_it(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id
           WHERE l.name_en = 'UEFA Europa League'"""
    )
    assert sorted(r[0] for r in cur.fetchall()) == sorted(EUROPA_LEAGUE_ONLY_CLUBS)
    cur.close()


def test_shared_europa_league_clubs_are_linked_not_duplicated(conn):
    cur = conn.cursor()
    cur.execute(
        'SELECT name_en, COUNT(*) FROM clubs WHERE name_en = ANY(%s) '
        'GROUP BY name_en HAVING COUNT(*) > 1',
        (LINKED_EUROPA_LEAGUE_CLUBS,)
    )
    assert cur.fetchall() == [], 'a dual-league club was inserted twice instead of linked'

    # Linked in the "reverse direction": the domestic league stays primary, the competition is the
    # secondary link. Asserting the direction matters -- the two are not interchangeable to the
    # admin UI, which only lets you edit a club from its primary league's row.
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues uel ON uel.id = c.domestic_league_id AND uel.name_en = 'UEFA Europa League'
           WHERE c.name_en = ANY(%s)""",
        (LINKED_EUROPA_LEAGUE_CLUBS,)
    )
    assert sorted(r[0] for r in cur.fetchall()) == sorted(LINKED_EUROPA_LEAGUE_CLUBS)
    cur.close()


def test_europa_league_votable_teams_are_the_two_rosters_combined(conn):
    # The number is DERIVED from the two roster lists above, not restated -- those lists are
    # already pinned exactly by the two tests before this one, so what is left for this one to
    # prove is that the OR-join counts each club ONCE. A hardcoded total proved the same thing
    # and went stale on every roster change (it said 20 when the roster reached 24).
    cur = conn.cursor()
    cur.execute(
        """SELECT COUNT(*) FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'UEFA Europa League'"""
    )
    expected = len(EUROPA_LEAGUE_ONLY_CLUBS) + len(LINKED_EUROPA_LEAGUE_CLUBS)
    assert cur.fetchone()[0] == expected
    cur.close()


def test_every_europa_league_club_has_a_crest_and_three_names(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'UEFA Europa League'
             AND (c.logo_url IS NULL OR c.name_he IS NULL OR c.name_ru IS NULL)"""
    )
    assert cur.fetchall() == []
    cur.close()


def test_every_champions_league_club_has_a_crest_and_three_names(conn):
    # The Europa League, Nations League and World Cup rosters each had this check; the Champions
    # League did not, so its clubs were the one competition where a missing name_ru or logo_url
    # would ship silently. Same query as its Europa League twin, so the two rot together or not
    # at all.
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'UEFA Champions League'
             AND (c.logo_url IS NULL OR c.name_he IS NULL OR c.name_ru IS NULL)"""
    )
    assert cur.fetchall() == []
    cur.close()


def test_no_club_is_in_both_european_competitions(conn):
    # domestic_league_id holds one link, so this is structurally impossible -- but a seed statement
    # that moved a club from one cup to the other would show up here as a club whose primary league
    # is one competition and whose secondary is the other.
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues a ON a.id = c.league_id
           JOIN leagues b ON b.id = c.domestic_league_id
           WHERE a.name_en IN ('UEFA Champions League', 'UEFA Europa League')
             AND b.name_en IN ('UEFA Champions League', 'UEFA Europa League')"""
    )
    assert cur.fetchall() == []
    cur.close()


def test_europa_league_link_does_not_overwrite_an_admin_set_second_league(conn):
    # domestic_league_id IS admin-writable (PATCH /api/admin/clubs/<id>, and the admin UI's
    # continental-competition buttons), so it yields to admin_edited like the name columns do --
    # the same mechanism as everything else here, not a guard specific to this column. Without
    # recording the edit, re-running seed.sql -- which init_db does on every pod boot -- would
    # silently move a club an admin had put in the other competition.
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name_en = 'UEFA Champions League'")
    ucl_id = cur.fetchone()[0]
    cur.execute(
        "UPDATE clubs SET domestic_league_id = %s, admin_edited = ARRAY['domestic_league_id'] "
        "WHERE name_en = 'Juventus'", (ucl_id,)
    )
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT domestic_league_id FROM clubs WHERE name_en = 'Juventus'")
    assert cur.fetchone()[0] == ucl_id, 'seed.sql overwrote an admin-set second league'
    cur.close()


def test_europa_league_link_is_re_applied_after_a_raw_clear(conn):
    # The negative case the positive test above doesn't cover: a raw clear of domestic_league_id
    # that does NOT record admin_edited (unlike an admin PATCH, which always does) writes exactly
    # the state the seed statement's ELSE branch fills, so seed.sql re-links the club on the next
    # backend pod boot -- init_db runs on every one. Roster/link membership for the clubs seed.sql
    # names is owned by seed.sql; a removal made outside admin_edited-tracked channels does not
    # stick. This is the behaviour test_removing_a_seeded_club_from_the_europa_league_is_re_applied
    # used to pin before Task 7 inverted whole-club deletion; that inversion left this narrower,
    # still-live case with no direct test. See
    # docs/design/2026-08-12-seed-sql-declarative-design.md.
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name_en = 'UEFA Europa League'")
    uel_id = cur.fetchone()[0]
    cur.execute("UPDATE clubs SET domestic_league_id = NULL WHERE name_en = 'Juventus'")
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT domestic_league_id FROM clubs WHERE name_en = 'Juventus'")
    assert cur.fetchone()[0] == uel_id
    cur.close()


def test_league_move_does_not_overwrite_an_admin_set_league(conn):
    # I1: league_id (which league a club is filed under) is admin-writable via
    # PATCH /api/admin/clubs/<id>, the same as domestic_league_id above, so it must yield to
    # admin_edited the same way -- seed.sql used to overwrite league_id unconditionally with no
    # guard at all, which would silently revert an admin's league move on every pod boot.
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name_en = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    cur.execute(
        "UPDATE clubs SET league_id = %s, admin_edited = ARRAY['league_id'] "
        "WHERE name_en = 'Juventus'", (la_liga_id,)
    )
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT league_id FROM clubs WHERE name_en = 'Juventus'")
    assert cur.fetchone()[0] == la_liga_id, 'seed.sql overwrote an admin-set league'
    cur.close()


def test_league_id_is_re_applied_after_a_raw_move(conn):
    # The negative case the positive test above doesn't cover: a raw change to league_id that
    # does NOT record admin_edited (unlike an admin PATCH, which always does) writes exactly
    # the state the seed statement's ELSE branch fills, so seed.sql moves the club back to its
    # seeded league on the next backend pod boot -- init_db runs on every one.
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name_en = 'Serie A'")
    serie_a_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name_en = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    cur.execute("UPDATE clubs SET league_id = %s WHERE name_en = 'Juventus'", (la_liga_id,))
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT league_id FROM clubs WHERE name_en = 'Juventus'")
    assert cur.fetchone()[0] == serie_a_id
    cur.close()


# Competition emblems that moved from a Wikimedia URL to a self-hosted, cropped file. Each needs its
# own correction statement in seed.sql: the leagues logo block is guarded on `logo_url IS NULL`, so an
# edited tuple reaches a fresh database only -- which is every database the test suite builds, and
# none of the ones in production. Seeding the superseded URL first is the only way to test the part
# that actually matters.
SELF_HOSTED_LEAGUE_EMBLEMS = [
    ('UEFA Champions League',
     'https://upload.wikimedia.org/wikipedia/commons/d/d1/UEFA_Champions_League_logo_no_text.svg',
     '/logos/uefa-champions-league.svg'),
    ('Bundesliga',
     'https://upload.wikimedia.org/wikipedia/he/d/df/Bundesliga_logo_%282017%29.svg',
     '/logos/bundesliga.svg'),
    ('Serie A',
     'https://upload.wikimedia.org/wikipedia/commons/e/e9/Serie_A_logo_2022.svg',
     '/logos/serie-a.svg'),
]


@pytest.mark.parametrize('name_en, superseded, expected', SELF_HOSTED_LEAGUE_EMBLEMS)
def test_league_emblem_correction_reaches_an_already_seeded_row(conn, name_en, superseded, expected):
    cur = conn.cursor()
    cur.execute('UPDATE leagues SET logo_url = %s WHERE name_en = %s', (superseded, name_en))
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute('SELECT logo_url FROM leagues WHERE name_en = %s', (name_en,))
    assert cur.fetchone()[0] == expected
    cur.close()


@pytest.mark.parametrize('name_en, superseded, expected', SELF_HOSTED_LEAGUE_EMBLEMS)
def test_league_emblem_correction_leaves_an_admin_choice_alone(conn, name_en, superseded, expected):
    # Protection is now admin_edited, not "logo_url IS NULL never matches a value an admin set" --
    # so the choice has to be recorded as an edit the same way the admin API does.
    admin_choice = 'https://example.invalid/admins-own-emblem.svg'
    cur = conn.cursor()
    cur.execute(
        "UPDATE leagues SET logo_url = %s, admin_edited = ARRAY['logo_url'] WHERE name_en = %s",
        (admin_choice, name_en),
    )
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute('SELECT logo_url FROM leagues WHERE name_en = %s', (name_en,))
    assert cur.fetchone()[0] == admin_choice
    cur.close()


DEAD_FRANCE_CREST = 'https://upload.wikimedia.org/wikipedia/en/f/f4/France_NT_2026_logo.svg'
FRANCE_CREST = 'https://upload.wikimedia.org/wikipedia/en/1/12/France_national_football_team_seal.svg'


def test_france_crest_correction_reaches_an_already_seeded_row(conn):
    # The World Cup crest block is guarded on "NULL or still a flagcdn flag", so a database that
    # already holds the superseded Wikimedia URL matches neither and the edited tuple never reaches
    # it. Only the separate correction statement moves it -- which is the whole point of that
    # statement existing, and is invisible on a fresh database, where the tuple sets it anyway.
    cur = conn.cursor()
    cur.execute("UPDATE clubs SET logo_url = %s WHERE name_en = 'France'", (DEAD_FRANCE_CREST,))
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT logo_url FROM clubs WHERE name_en = 'France'")
    assert cur.fetchone()[0] == FRANCE_CREST
    cur.close()


def test_france_crest_correction_leaves_an_admin_chosen_crest_alone(conn):
    # Protection is now admin_edited, not "this exact superseded URL never matches an admin's own
    # choice" -- so the choice has to be recorded as an edit the same way the admin API does.
    admin_choice = 'https://example.invalid/admins-own-france.svg'
    cur = conn.cursor()
    cur.execute("UPDATE clubs SET logo_url = %s, admin_edited = ARRAY['logo_url'] "
                "WHERE name_en = 'France'", (admin_choice,))
    conn.commit()
    cur.close()

    db_module.init_db(conn)

    cur = conn.cursor()
    cur.execute("SELECT logo_url FROM clubs WHERE name_en = 'France'")
    assert cur.fetchone()[0] == admin_choice
    cur.close()


def test_no_seeded_logo_points_at_the_dead_france_file(conn):
    cur = conn.cursor()
    cur.execute('SELECT name_en FROM clubs WHERE logo_url = %s', (DEAD_FRANCE_CREST,))
    assert cur.fetchall() == []
    cur.close()


SEEDED_TABLES = ('leagues', 'clubs', 'previous_parties', 'upcoming_parties')


def test_seed_provenance_columns_exist(conn):
    """seed_key is immutable identity; admin_edited is column-level provenance.

    Both replace inference from display names, which the admin UI and seed.sql
    both rewrite -- 104 of 212 production clubs carry a drifted legacy `name`.
    """
    cur = conn.cursor()
    for table in SEEDED_TABLES:
        cur.execute(
            'SELECT column_name, data_type, is_nullable, column_default '
            'FROM information_schema.columns '
            'WHERE table_name = %s AND column_name IN (%s, %s)',
            (table, 'seed_key', 'admin_edited'))
        found = {r[0]: r for r in cur.fetchall()}
        assert 'seed_key' in found, f'{table} is missing seed_key'
        assert 'admin_edited' in found, f'{table} is missing admin_edited'
        # data_type: without this, changing admin_edited from TEXT[] to plain TEXT (kept
        # NOT NULL DEFAULT '') still passed every other assertion here.
        assert found['seed_key'][1] == 'text', f'{table}.seed_key must be text'
        assert found['admin_edited'][1] == 'ARRAY', f'{table}.admin_edited must be an array type'
        # seed_key must stay nullable: NULL is what marks an admin-created row, and the
        # declarative DELETE a later task adds keys on `seed_key IS NOT NULL` to avoid ever
        # deleting a row seed.sql does not own. NOT NULL here would break every admin-created row.
        assert found['seed_key'][2] == 'YES', f'{table}.seed_key must stay nullable'
        assert found['admin_edited'][2] == 'NO', f'{table}.admin_edited must be NOT NULL'
        assert found['admin_edited'][3] is not None, \
            f'{table}.admin_edited needs a default, or every insert must name it'
    cur.close()


def test_seed_key_uidx_is_partial(conn):
    """The four seed_key unique indexes must carry the `seed_key IS NOT NULL` predicate.

    A plain (non-partial) UNIQUE index already permits unlimited NULLs -- Postgres treats
    NULLs as distinct for uniqueness purposes -- so a behavioural test that only inserts two
    NULLs and checks they coexist cannot tell a partial index from a plain one. This asserts
    the index DEFINITION carries the predicate, which is the only way to pin the intent that
    NULL means "not seed-owned", not merely an accident of NULL comparison semantics.
    """
    cur = conn.cursor()
    for table in SEEDED_TABLES:
        cur.execute(
            "SELECT indexdef FROM pg_indexes WHERE indexname = %s",
            (f'{table}_seed_key_uidx',))
        row = cur.fetchone()
        assert row is not None, f'{table}_seed_key_uidx does not exist'
        assert 'WHERE (seed_key IS NOT NULL)' in row[0], \
            f'{table}_seed_key_uidx is missing its partial predicate: {row[0]}'
    cur.close()


def test_seed_key_is_unique_but_allows_admin_created_rows(conn):
    """NULL seed_key means "created through the admin UI", and seed.sql ignores those.

    So the index must be partial: many NULLs allowed, duplicates of a real key not. (The
    "many NULLs allowed" half holds for any unique index, partial or not -- Postgres treats
    NULLs as distinct -- so this test only pins the "duplicates of a real key are rejected"
    half; test_seed_key_uidx_is_partial above is what actually distinguishes partial from
    plain.)
    """
    cur = conn.cursor()
    # Assign the key explicitly rather than reading one from the table: this task adds the
    # column but nothing populates it until Task 4, so a SELECT ... WHERE seed_key IS NOT NULL
    # returns no rows here and the test would fail on a TypeError instead of its assertion.
    cur.execute("INSERT INTO leagues (name, name_en) VALUES ('Placeholder A', 'Placeholder A')")
    cur.execute("INSERT INTO leagues (name, name_en) VALUES ('Placeholder B', 'Placeholder B')")
    conn.commit()  # two NULL seed_keys coexist

    cur.execute("UPDATE leagues SET seed_key = 'placeholder-a' WHERE name_en = 'Placeholder A'")
    conn.commit()

    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute("UPDATE leagues SET seed_key = 'placeholder-a' WHERE name_en = 'Placeholder B'")
    conn.rollback()
    cur.close()


# test_removing_a_seeded_club_from_the_europa_league_is_re_applied inverted here: removal is now
# declarative (a club seed.sql no longer names is deleted, guarded on seed_key IS NOT NULL and on
# no vote referencing it) instead of a link that a guarded UPDATE silently re-applied. See
# docs/design/2026-08-12-seed-sql-declarative-design.md. The narrower case that test used to pin --
# a raw domestic_league_id clear that skips admin_edited being re-applied -- is unchanged and still
# live; test_europa_league_link_is_re_applied_after_a_raw_clear (below, next to its positive-case
# counterpart) now pins it directly.


def test_seeded_club_absent_from_the_table_is_removed(conn):
    """Removal now sticks. Previously a guarded link statement re-applied it on the next
    boot, which test_removing_a_seeded_club_from_the_europa_league_is_re_applied pinned."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE seed_key = 'la-liga'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, seed_key, name, name_en) "
                "VALUES (%s, 'ruritania-united', 'Ruritania United', 'Ruritania United')",
                (league_id,))
    conn.commit()

    db_module.init_db(conn)

    cur.execute("SELECT count(*) FROM clubs WHERE seed_key = 'ruritania-united'")
    assert cur.fetchone()[0] == 0
    cur.close()


def test_a_voted_for_club_is_never_deleted(conn):
    """vote_clubs.club_id has no ON DELETE CASCADE, so deleting a voted-for club raises
    inside init_db -- a CrashLoopBackOff on every pod boot, not one failed request."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE seed_key = 'la-liga'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, seed_key, name, name_en) "
                "VALUES (%s, 'ruritania-city', 'Ruritania City', 'Ruritania City') "
                "RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO votes (previous_vote_status, upcoming_vote_status, cookie_token) "
        "VALUES ('did_not_vote', 'undecided', 'ruritania-city-vote') RETURNING id")
    vote_id = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)',
                (vote_id, club_id, league_id))
    conn.commit()

    db_module.init_db(conn)  # must not raise

    cur.execute('SELECT count(*) FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == 1
    cur.close()


def test_seeded_upcoming_party_absent_from_the_table_is_removed(conn):
    """upcoming_parties got the clubs removal rule on 2026-08-20, for the
    חד"ש-תע"ל + בל"ד merge into הרשימה המשותפת."""
    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (seed_key, name, name_en) "
                "VALUES ('ruritanian-front', 'Ruritanian Front', 'Ruritanian Front')")
    conn.commit()

    db_module.init_db(conn)

    cur.execute("SELECT count(*) FROM upcoming_parties WHERE seed_key = 'ruritanian-front'")
    assert cur.fetchone()[0] == 0
    cur.close()


def test_removing_an_upcoming_party_clears_its_lineage_first(conn):
    """The trap with no clubs equivalent: party_lineage.upcoming_party_id references
    upcoming_parties(id) with NO ON DELETE CASCADE, so deleting a party that still carries
    a lineage link raises inside init_db -- a CrashLoopBackOff on every backend pod boot,
    not one failed request. seed.sql clears the links in a separate statement first."""
    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (seed_key, name, name_en) "
                "VALUES ('ruritanian-bloc', 'Ruritanian Bloc', 'Ruritanian Bloc') RETURNING id")
    party_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM previous_parties WHERE seed_key = 'likud'")
    previous_id = cur.fetchone()[0]
    cur.execute('INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
                (previous_id, party_id))
    conn.commit()

    db_module.init_db(conn)  # must not raise on the foreign key

    cur.execute('SELECT count(*) FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.execute('SELECT count(*) FROM party_lineage WHERE upcoming_party_id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()


def test_a_voted_for_upcoming_party_is_never_deleted(conn):
    """The guard fails safe in the opposite direction from the clubs one, and the
    consequence is worse. vote_clubs has no cascade, so an unguarded club delete RAISES;
    vote_upcoming_parties.upcoming_party_id DOES cascade, so dropping the vote guard from
    BOTH statements below deletes the row and its ballot with no error at all -- verified
    by mutating seed.sql, which turns this test's first assertion into a bare 0 == 1.
    Dropping it from only the party DELETE raises on the party_lineage FK instead, because
    the surviving lineage link trips it first; that loud failure is incidental, not a
    safety net, so both statements carry the guard."""
    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (seed_key, name, name_en) "
                "VALUES ('ruritanian-union', 'Ruritanian Union', 'Ruritanian Union') RETURNING id")
    party_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM previous_parties WHERE seed_key = 'likud'")
    previous_id = cur.fetchone()[0]
    cur.execute('INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
                (previous_id, party_id))
    cur.execute(
        "INSERT INTO votes (previous_vote_status, upcoming_vote_status, cookie_token) "
        "VALUES ('did_not_vote', 'considering', 'ruritanian-union-vote') RETURNING id")
    vote_id = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)',
                (vote_id, party_id))
    conn.commit()

    db_module.init_db(conn)  # must not raise

    cur.execute('SELECT count(*) FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 1
    cur.execute('SELECT count(*) FROM vote_upcoming_parties WHERE upcoming_party_id = %s',
                (party_id,))
    assert cur.fetchone()[0] == 1, 'the ballot was destroyed by the cascade'
    cur.execute('SELECT count(*) FROM party_lineage WHERE upcoming_party_id = %s', (party_id,))
    assert cur.fetchone()[0] == 1, 'the kept row survived with its history cut'
    cur.close()


def test_the_joint_list_merged_both_arab_predecessors(conn):
    """חד"ש-תע"ל + בל"ד -> הרשימה המשותפת (2026-08-20). Axes are the union of the two
    components; previous_parties is frozen and keeps both rows separately."""
    cur = conn.cursor()
    cur.execute("SELECT name_en, economic, security, religiosity FROM upcoming_parties "
                "WHERE seed_key = 'joint-list'")
    assert cur.fetchone() == ('The Joint List', -3, -3, -3)

    cur.execute("SELECT count(*) FROM upcoming_parties WHERE seed_key IN ('hadash-ta-al', 'balad')")
    assert cur.fetchone()[0] == 0

    # Frozen at their 2022 run, and deliberately not back-dated to the merged row's numbers.
    cur.execute("SELECT count(*) FROM previous_parties WHERE seed_key IN ('hadash-ta-al', 'balad')")
    assert cur.fetchone()[0] == 2

    cur.execute("""SELECT p.seed_key FROM party_lineage l
                   JOIN previous_parties p ON p.id = l.previous_party_id
                   JOIN upcoming_parties u ON u.id = l.upcoming_party_id
                   WHERE u.seed_key = 'joint-list' ORDER BY p.seed_key""")
    assert [r[0] for r in cur.fetchall()] == ['balad', 'hadash-ta-al']

    # רע"ם declined to join and keeps its own row.
    cur.execute("SELECT count(*) FROM upcoming_parties WHERE seed_key = 'ra-am'")
    assert cur.fetchone()[0] == 1
    cur.close()


def test_seed_overwrites_a_column_the_admin_never_touched(conn):
    """The guarantee the whole redesign exists for, and which nothing used to test.

    Under the old COALESCE/IS NULL guards this was FALSE: editing a literal reached a
    fresh database only, so every corrected value needed its own patch statement.
    """
    cur = conn.cursor()
    cur.execute("UPDATE leagues SET name_ru = 'stale value' WHERE seed_key = 'la-liga'")
    conn.commit()

    db_module.init_db(conn)  # what happens on every backend pod boot

    cur.execute("SELECT name_ru FROM leagues WHERE seed_key = 'la-liga'")
    assert cur.fetchone()[0] == 'Ла Лига'
    cur.close()


def test_seed_leaves_an_admin_edited_column_alone(conn):
    cur = conn.cursor()
    cur.execute("UPDATE leagues SET name_ru = 'Моя Лига', admin_edited = ARRAY['name_ru'] "
                "WHERE seed_key = 'la-liga'")
    conn.commit()

    db_module.init_db(conn)

    cur.execute("SELECT name_ru, name_he FROM leagues WHERE seed_key = 'la-liga'")
    name_ru, name_he = cur.fetchone()
    assert name_ru == 'Моя Лига', 'an admin edit was overwritten'
    assert name_he == 'לה ליגה', 'provenance must be per-column, not per-row'
    cur.close()


def test_every_league_is_adopted_by_seed_key(conn):
    cur = conn.cursor()
    cur.execute('SELECT count(*) FROM leagues WHERE seed_key IS NULL')
    assert cur.fetchone()[0] == 0
    cur.execute('SELECT count(DISTINCT seed_key), count(*) FROM leagues')
    distinct, total = cur.fetchone()
    assert distinct == total
    cur.close()


def test_dual_league_clubs_keep_both_leagues(conn):
    """A club playing two competitions must keep league_id AND domestic_league_id.

    _VOTE_LEAGUES_TOUCHED_CTE in services/worker/rollups.py derives league scope from both
    columns, so losing one silently under-counts a multi-league ballot.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT l.seed_key, d.seed_key FROM clubs c
        JOIN leagues l ON l.id = c.league_id
        LEFT JOIN leagues d ON d.id = c.domestic_league_id
        WHERE c.seed_key = 'bayern-munich'""")
    league, domestic = cur.fetchone()
    assert league == 'uefa-champions-league'
    assert domestic == 'bundesliga'
    cur.close()


def test_nations_league_divisions_survive(conn):
    cur = conn.cursor()
    cur.execute("SELECT group_label FROM clubs WHERE seed_key = 'france'")
    assert cur.fetchone()[0] == 'A'
    cur.execute("SELECT count(*) FROM clubs WHERE group_label IS NOT NULL")
    assert cur.fetchone()[0] > 0
    cur.close()


def test_admin_created_club_survives_reseeding(conn):
    """seed_key IS NULL means the admin created it, so declarative removal must skip it."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE seed_key = 'la-liga'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name, name_en) "
                "VALUES (%s, 'Ruritania FC', 'Ruritania FC') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    conn.commit()

    db_module.init_db(conn)

    cur.execute('SELECT count(*) FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == 1, 'seed.sql deleted a club it does not own'
    cur.close()


def test_club_seed_overwrites_a_column_the_admin_never_touched(conn):
    """The clubs equivalent of test_seed_overwrites_a_column_the_admin_never_touched.

    Under the old COALESCE/IS NULL guards this was FALSE for clubs too: editing a literal
    reached a fresh database only, so every corrected value needed its own patch statement
    (the France crest correction, the Kiryat Yam correction, ...). Clubs previously only had
    this guarantee pinned indirectly, through value-specific tests -- this is the direct one.
    """
    cur = conn.cursor()
    cur.execute("UPDATE clubs SET name_ru = 'stale value' WHERE seed_key = 'bayern-munich'")
    conn.commit()

    db_module.init_db(conn)  # what happens on every backend pod boot

    cur.execute("SELECT name_ru FROM clubs WHERE seed_key = 'bayern-munich'")
    assert cur.fetchone()[0] == 'Бавария'
    cur.close()


def test_other_has_no_ideology(conn):
    """'אחר' is a catch-all ballot option, not a party -- every axis stays NULL."""
    cur = conn.cursor()
    cur.execute("SELECT bloc, economic, security, religiosity, sector "
                "FROM previous_parties WHERE name_he = 'אחר'")
    assert all(v is None for v in cur.fetchone())
    cur.close()


def test_ideology_edits_reach_an_already_seeded_database(conn):
    """The six ideology columns stay UNGUARDED -- a guard makes every later edit
    unreachable in production, which is always already seeded.

    bloc is 'opposition' here, not the brief's literal 'wrong': previous_parties_bloc_check
    (schema.sql) rejects any value outside ('bibi', 'opposition', 'unaligned'), so a genuinely
    invalid value can never reach the table to prove the point with -- the UPDATE itself would
    fail before init_db ever ran. 'opposition' is still wrong for הליכוד (seeded as 'bibi'), so
    it exercises the same unguarded-overwrite behaviour without fighting the CHECK constraint.
    """
    cur = conn.cursor()
    cur.execute("UPDATE previous_parties SET economic = -3, bloc = 'opposition' "
                "WHERE name_he = 'הליכוד'")
    conn.commit()

    db_module.init_db(conn)

    cur.execute("SELECT economic, bloc FROM previous_parties WHERE name_he = 'הליכוד'")
    assert cur.fetchone() == (1, 'bibi')
    cur.close()


def test_party_lineage_is_rebuilt_by_key(conn):
    cur = conn.cursor()
    cur.execute('SELECT count(*) FROM party_lineage')
    assert cur.fetchone()[0] == 14
    cur.close()



def test_grafana_ro_role_exists_after_init(conn):
    """schema.sql creates the read-only role, so a GRANT naming it never fails."""
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro'")
    assert cur.fetchone() is not None
    cur.close()


def test_grafana_ro_role_has_no_password_from_schema(conn):
    """schema.sql must NOT set a password. Only migrate.py does, from the environment.

    schema.sql runs on every backend boot (app.py's __main__ guard and gunicorn's on_starting hook,
    not just the migrate Job), so it can carry no secret and must not depend on one being present.
    A role with no password cannot authenticate under scram-sha-256, so the intermediate state
    fails closed.

    grafana_ro is a cluster-level role, not scoped to this test's database, so the `conn` fixture's
    per-test DROP TABLE/init_db cycle does not reset it -- a password set by a different test (e.g.
    test_migrate.py's `_set_grafana_password` coverage) survives between tests. Drop the role first
    so this test proves what schema.sql itself does on a *fresh* CREATE ROLE, not whatever password
    state a previous test happened to leave behind.
    """
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro'")
    if cur.fetchone():
        cur.execute('DROP OWNED BY grafana_ro CASCADE')
        cur.execute('DROP ROLE grafana_ro')
        conn.commit()
    db_module.init_db(conn)  # recreates grafana_ro fresh, via schema.sql's CREATE ROLE

    cur.execute("SELECT rolpassword FROM pg_authid WHERE rolname = 'grafana_ro'")
    row = cur.fetchone()
    assert row is not None
    assert row[0] is None, 'schema.sql set a password on grafana_ro; only migrate.py may do that'
    cur.close()


def test_grafana_view_hides_voter_identifiers(conn):
    """v_grafana_votes must not expose cookie_token or ip_hash.

    Both link a ballot to a person. The site promises an anonymous poll, and a Grafana query box is
    exactly where that leaks. See the design doc's decision 3.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'v_grafana_votes'
    """)
    cols = {r[0] for r in cur.fetchall()}
    assert cols, 'v_grafana_votes does not exist'
    # Exact-set equality, not a subset check. The ADD direction is the privacy-relevant one here --
    # a subset check only proves the columns this test already knows about are still present; it
    # says nothing about a column joining the view later, which is exactly how a future
    # voter-identifying column would reach the dashboard unnoticed.
    assert cols == {
        'id', 'created_at', 'previous_vote_status', 'upcoming_vote_status', 'previous_party_id',
    }
    cur.close()


def test_grafana_ro_cannot_read_raw_votes(conn):
    """The base votes table is REVOKEd; only the view is readable."""
    cur = conn.cursor()
    cur.execute("SELECT has_table_privilege('grafana_ro', 'votes', 'SELECT')")
    assert cur.fetchone()[0] is False, 'grafana_ro can read raw votes -- cookie_token is exposed'
    cur.execute("SELECT has_table_privilege('grafana_ro', 'v_grafana_votes', 'SELECT')")
    assert cur.fetchone()[0] is True
    cur.execute("SELECT has_table_privilege('grafana_ro', 'rollup_previous', 'SELECT')")
    assert cur.fetchone()[0] is True
    cur.close()


def test_grafana_ro_can_read_exactly_the_allowlist_and_nothing_else(conn):
    """`ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro` in
    schema.sql is a STANDING grant scoped to the whole `public` schema, not to the 13 objects
    schema.sql explicitly names -- it applies to every table or view created in `public` from that
    point on, by anyone, with no review step. The REVOKE list right above it is hardcoded to four
    table names and does not grow on its own, so a future table carrying a voter identifier (the
    way `votes` does) would be readable by grafana_ro the day it is added, unless someone remembers
    to extend that list by hand.

    This is the guard: assert the exact set of objects grafana_ro can SELECT across ALL of `public`
    equals the intended allowlist and nothing more. A new table then fails this test loudly instead
    of leaking silently, and whoever adds it has to make a deliberate decision about grafana_ro's
    access to it -- see docs/security.md's "Grafana data sources" section.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relkind IN ('r', 'v')  -- ordinary tables and views only
           AND has_table_privilege('grafana_ro', quote_ident(n.nspname) || '.' || quote_ident(c.relname), 'SELECT')
    """)
    readable = {r[0] for r in cur.fetchall()}
    cur.close()

    expected = {
        # The 8 rollup tables.
        'rollup_previous', 'rollup_upcoming', 'rollup_previous_upcoming',
        'rollup_national_previous', 'rollup_national_upcoming', 'rollup_national_previous_upcoming',
        'rollup_vote_switch', 'rollup_national_vote_switch',
        # The 4 reference tables.
        'leagues', 'clubs', 'previous_parties', 'upcoming_parties',
        # The one view.
        'v_grafana_votes',
    }
    extra = readable - expected
    missing = expected - readable
    assert not extra, (
        f'grafana_ro can read {sorted(extra)}, which is NOT on the intended allowlist -- this is '
        f'the ALTER DEFAULT PRIVILEGES grant reaching a table it should not; add it to the REVOKE '
        f'list in schema.sql if it carries anything voter-identifying, or to `expected` above with '
        f'a deliberate note if the exposure is intended'
    )
    assert not missing, f'grafana_ro lost SELECT on {sorted(missing)} -- a dashboard panel just broke'


def test_grafana_ro_cannot_write(conn):
    """Read-only means read-only, on every table it can see."""
    cur = conn.cursor()
    for tbl in ('rollup_previous', 'leagues', 'clubs', 'upcoming_parties'):
        for priv in ('INSERT', 'UPDATE', 'DELETE'):
            cur.execute('SELECT has_table_privilege(%s, %s, %s)', ('grafana_ro', tbl, priv))
            assert cur.fetchone()[0] is False, f'grafana_ro has {priv} on {tbl}'
    cur.close()


def test_grafana_ro_creation_degrades_to_notice_without_privilege(conn):
    """CREATE ROLE is cluster-level and needs superuser or CREATEROLE. schema.sql runs on every
    backend boot, so a connecting user that ever lacks that privilege must not abort init_db --
    that would crash-loop every pod over a monitoring nicety, not just skip a dashboard credential.

    Proves the degradation for real: reset grafana_ro to "does not exist" (RDS's master user
    starts every real database this way too), then re-run the exact grafana block from schema.sql
    as a role with neither CREATEROLE nor superuser. The DO blocks must not raise, and -- because
    the failure is real, not swallowed by a broader catch elsewhere -- the role must still not
    exist afterwards.

    test_unprivileged is granted INHERIT membership in `postgres` -- the same role that owns
    every table -- so it has the ordinary object-level access schema.sql's other, unguarded
    statements need (e.g. CREATE OR REPLACE VIEW reading `votes`). Role ATTRIBUTES such as
    CREATEROLE are never inherited through membership, only privileges granted via GRANT are, so
    this isolates exactly the property under test: a connecting role that can do everything the
    app's normal DB user can, except create another role.
    """
    cur = conn.cursor()
    cur.execute('DROP OWNED BY grafana_ro CASCADE')
    cur.execute('DROP ROLE grafana_ro')
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'test_unprivileged'")
    if cur.fetchone():
        cur.execute('DROP OWNED BY test_unprivileged CASCADE')
        cur.execute('DROP ROLE test_unprivileged')
    cur.execute("CREATE ROLE test_unprivileged LOGIN PASSWORD 'test' NOSUPERUSER NOCREATEROLE INHERIT")
    cur.execute(psycopg2.sql.SQL('GRANT CONNECT ON DATABASE {} TO test_unprivileged')
                .format(psycopg2.sql.Identifier(db_module.DB_NAME)))
    cur.execute('GRANT postgres TO test_unprivileged')
    conn.commit()
    cur.close()

    base_dir = os.path.dirname(os.path.abspath(db_module.__file__))
    with open(os.path.join(base_dir, 'schema.sql')) as f:
        schema_sql = f.read()
    marker = "-- Grafana's read-only access."
    assert marker in schema_sql, 'schema.sql no longer carries the grafana block this test exercises'
    grafana_sql = schema_sql[schema_sql.index(marker):]

    unpriv_conn = psycopg2.connect(
        host=db_module.DB_HOST, dbname=db_module.DB_NAME,
        user='test_unprivileged', password='test',
        sslmode=db_module.DB_SSLMODE,
    )
    try:
        ucur = unpriv_conn.cursor()
        ucur.execute(grafana_sql)  # must NOT raise -- this is the property under test
        unpriv_conn.commit()
        ucur.close()
    finally:
        unpriv_conn.close()

    cur = conn.cursor()
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro'")
    assert cur.fetchone() is None, (
        'grafana_ro was created by a role with no CREATEROLE privilege -- '
        'either the test setup or the degradation guard is broken'
    )
    cur.execute('DROP OWNED BY test_unprivileged CASCADE')
    cur.execute('DROP ROLE test_unprivileged')
    conn.commit()
    cur.close()
