import pytest
import queries


def test_get_options_returns_seeded_leagues(conn):
    options = queries.get_options(conn)
    league_names_en = {l['name_en'] for l in options['leagues']}
    assert 'Premier League' in league_names_en
    assert 'Israeli Premier League' in league_names_en

    epl = next(l for l in options['leagues'] if l['name_en'] == 'Premier League')
    assert epl['name_he'] == 'הפרמייר ליג'

    club_names_en = {c['name_en'] for c in options['clubs']}
    assert 'Liverpool' in club_names_en
    liverpool = next(c for c in options['clubs'] if c['name_en'] == 'Liverpool')
    assert liverpool['name_he'] == 'ליברפול'

    epl_clubs = [c for c in options['clubs'] if c['league_id'] == epl['id']]
    assert len(epl_clubs) == 16

    previous_names_en = {p['name_en'] for p in options['previous_parties']}
    assert previous_names_en == {
        'Likud', 'Yesh Atid', 'Religious Zionist Party', 'National Unity', 'Yisrael Beiteinu',
        'Shas', 'United Torah Judaism', "Ra'am", "Hadash-Ta'al", 'Labor', 'Meretz', 'Balad',
        'Other',
    }
    previous_names_he = {p['name_he'] for p in options['previous_parties']}
    assert previous_names_he == {
        'הליכוד', 'יש עתיד', 'הציונות הדתית', 'המחנה הממלכתי', 'ישראל ביתנו',
        'ש"ס', 'יהדות התורה', 'רע"ם', 'חד"ש-תע"ל', 'העבודה', 'מרצ', 'בל"ד',
        'אחר',
    }

    upcoming_names_en = {p['name_en'] for p in options['upcoming_parties']}
    assert upcoming_names_en == {
        'Likud', 'Yashar', 'Together', 'The Democrats', 'Blue and White', 'Yisrael Beiteinu',
        'Religious Zionist Party', 'Otzma Yehudit', "Hadash-Ta'al", 'Balad', "Ra'am",
        'Shas', 'United Torah Judaism',
        'The Economic Party', 'El HaDegel', 'The Reservists',
    }
    upcoming_names_he = {p['name_he'] for p in options['upcoming_parties']}
    assert upcoming_names_he == {
        'הליכוד', 'ישר', 'ביחד', 'הדמוקרטים', 'כחול לבן', 'ישראל ביתנו',
        'הציונות הדתית', 'עוצמה יהודית', 'חד"ש-תע"ל', 'בל"ד', 'רע"ם',
        'ש"ס', 'יהדות התורה',
        'המפלגה הכלכלית', 'אל הדגל', 'המילואימניקים',
    }


def test_get_options_exposes_ideology_and_lineage(conn):
    cur = conn.cursor()
    cur.execute('''
        UPDATE previous_parties SET bloc = 'bibi', economic = 1, security = 2,
            sector = 'traditional', religiosity = 1, tags = ARRAY['a', 'b']
        WHERE name_he = 'הליכוד'
    ''')
    cur.execute("SELECT id FROM previous_parties WHERE name_he = 'הליכוד'")
    prev_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties WHERE name_he = 'הליכוד'")
    up_id = cur.fetchone()[0]
    # Delete any existing lineage entry first to ensure we have a clean slate for this test
    cur.execute(
        'DELETE FROM party_lineage WHERE previous_party_id = %s AND upcoming_party_id = %s',
        (prev_id, up_id)
    )
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_id, up_id)
    )
    conn.commit()
    cur.close()

    options = queries.get_options(conn)

    likud = next(p for p in options['previous_parties'] if p['id'] == prev_id)
    assert likud['bloc'] == 'bibi'
    assert likud['economic'] == 1
    assert likud['security'] == 2
    assert likud['sector'] == 'traditional'
    assert likud['religiosity'] == 1
    assert likud['tags'] == ['a', 'b']

    assert 'party_lineage' in options
    assert {'previous_party_id': prev_id, 'upcoming_party_id': up_id} in options['party_lineage']


def _epl_and_liverpool(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.close()
    return league_id, club_id


def _pick(league_id, club_id=None):
    return {'league_id': league_id, 'club_id': club_id}


def test_insert_vote_league_only_did_not_vote_undecided(conn):
    league_id, _ = _epl_and_liverpool(conn)

    vote_id = queries.insert_vote(
        conn,
        team_picks=[_pick(league_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='token-a',
    )
    assert vote_id > 0

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM vote_upcoming_parties WHERE vote_id = %s', (vote_id,))
    assert cur.fetchone()[0] == 0
    cur.execute('SELECT league_id FROM vote_leagues WHERE vote_id = %s', (vote_id,))
    assert cur.fetchone()[0] == league_id
    cur.execute('SELECT COUNT(*) FROM vote_clubs WHERE vote_id = %s', (vote_id,))
    assert cur.fetchone()[0] == 0
    cur.close()


def test_insert_vote_with_club_and_multiple_upcoming_parties(conn):
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Test Faction') RETURNING id")
    previous_party_id = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party B') RETURNING id")
    party_b = cur.fetchone()[0]
    conn.commit()
    cur.close()

    vote_id = queries.insert_vote(
        conn,
        team_picks=[_pick(league_id, club_id)],
        previous_vote_status='voted', previous_party_id=previous_party_id,
        upcoming_vote_status='considering', upcoming_party_ids=[party_a, party_b],
        cookie_token='token-b',
    )

    cur = conn.cursor()
    cur.execute('SELECT upcoming_party_id FROM vote_upcoming_parties WHERE vote_id = %s ORDER BY upcoming_party_id', (vote_id,))
    assert [r[0] for r in cur.fetchall()] == sorted([party_a, party_b])
    cur.close()


def test_insert_vote_multi_league_multi_club(conn):
    epl_id, liverpool_id = _epl_and_liverpool(conn)
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Barcelona'")
    barcelona_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Real Madrid'")
    real_madrid_id = cur.fetchone()[0]
    cur.close()

    vote_id = queries.insert_vote(
        conn,
        team_picks=[
            _pick(epl_id, liverpool_id),
            _pick(la_liga_id, barcelona_id),
            _pick(la_liga_id, real_madrid_id),
        ],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='multi-league-token',
    )

    cur = conn.cursor()
    cur.execute('SELECT club_id, league_id FROM vote_clubs WHERE vote_id = %s ORDER BY club_id', (vote_id,))
    rows = cur.fetchall()
    cur.close()
    assert sorted(rows) == sorted([(liverpool_id, epl_id), (barcelona_id, la_liga_id), (real_madrid_id, la_liga_id)])


def test_insert_vote_same_club_under_two_leagues_produces_two_rows(conn):
    """A dual-league club (e.g. a UCL club with a domestic league too) picked once under each of
    its two tabs must produce two independent vote_clubs rows, one per league context."""
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'UCL'")
    ucl_id = cur.fetchone()[0]
    cur.execute("SELECT id, domestic_league_id FROM clubs WHERE name = 'Real Madrid'")
    real_madrid_id, la_liga_id = cur.fetchone()
    cur.close()
    assert la_liga_id is not None  # Real Madrid is seeded UCL-primary/La-Liga-domestic

    vote_id = queries.insert_vote(
        conn,
        team_picks=[_pick(ucl_id, real_madrid_id), _pick(la_liga_id, real_madrid_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='dual-league-token',
    )

    cur = conn.cursor()
    cur.execute('SELECT league_id FROM vote_clubs WHERE vote_id = %s AND club_id = %s ORDER BY league_id', (vote_id, real_madrid_id))
    rows = [r[0] for r in cur.fetchall()]
    cur.close()
    assert sorted(rows) == sorted([ucl_id, la_liga_id])


def test_insert_vote_invalid_previous_vote_status_raises_and_rolls_back(conn):
    league_id, _ = _epl_and_liverpool(conn)

    with pytest.raises(Exception):
        queries.insert_vote(
            conn, team_picks=[_pick(league_id)],
            previous_vote_status='not_a_real_status', previous_party_id=None,
            upcoming_vote_status='undecided', upcoming_party_ids=[],
            cookie_token='bad-status-token',
        )

    # connection must be usable afterward - proves rollback happened
    vote_id = queries.insert_vote(
        conn, team_picks=[_pick(league_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='good-token-after-bad',
    )
    assert vote_id > 0


def test_insert_vote_duplicate_cookie_token_rejected(conn):
    league_id, _ = _epl_and_liverpool(conn)

    queries.insert_vote(
        conn, team_picks=[_pick(league_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='dup-token',
    )
    with pytest.raises(ValueError):
        queries.insert_vote(
            conn, team_picks=[_pick(league_id)],
            previous_vote_status='did_not_vote', previous_party_id=None,
            upcoming_vote_status='undecided', upcoming_party_ids=[],
            cookie_token='dup-token',
        )


def _seed_rollup_rows(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]

    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, party_x, 7)
    )
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, %s, NULL, %s)',
        (league_id, club_id, 3)
    )
    conn.commit()
    cur.close()
    return league_id, club_id, party_x


def test_get_results_by_club_includes_did_not_vote(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    result = queries.get_results_by_club(conn, club_id)
    previous = {row['party_id']: row['count'] for row in result['previous']}
    assert previous[party_x] == 7
    assert previous[None] == 3


def test_get_results_by_party_previous(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    result = queries.get_results_by_party(conn, 'previous', party_x)
    assert result['breakdown'] == [{'league_id': league_id, 'club_id': club_id, 'count': 7}]


def test_get_results_by_party_previous_includes_crosstab(conn):
    # crosstab is a national (no league/club dimension) migration figure, so it's seeded via
    # rollup_national_previous_upcoming, not the per-scope rollup_previous_upcoming.
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_national_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, party_a, 5)
    )
    cur.execute(
        'INSERT INTO rollup_national_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, None, 2)
    )
    conn.commit()
    cur.close()

    result = queries.get_results_by_party(conn, 'previous', party_x)
    crosstab = {row['upcoming_party_id']: row['count'] for row in result['crosstab']}
    assert crosstab[party_a] == 5
    assert crosstab[None] == 2


def test_get_results_by_party_upcoming_includes_crosstab(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_national_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, party_a, 5)
    )
    cur.execute(
        'INSERT INTO rollup_national_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (None, party_a, 4)
    )
    conn.commit()
    cur.close()

    result = queries.get_results_by_party(conn, 'upcoming', party_a)
    crosstab = {row['previous_party_id']: row['count'] for row in result['crosstab']}
    assert crosstab[party_x] == 5
    assert crosstab[None] == 4


def test_get_results_by_party_crosstab_empty_when_no_data(conn):
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    result = queries.get_results_by_party(conn, 'previous', party_x)
    assert result['crosstab'] == []


def test_create_rename_delete_upcoming_party(conn):
    import queries

    party_id = queries.create_upcoming_party(conn, 'New Party', 'מפלגה חדשה')
    assert party_id > 0

    assert queries.rename_upcoming_party(conn, party_id, 'Renamed Party', 'מפלגה משודרגת') is True
    cur = conn.cursor()
    cur.execute('SELECT name_en, name_he FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone() == ('Renamed Party', 'מפלגה משודרגת')
    cur.close()

    assert queries.delete_upcoming_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_upcoming_party(conn, 999999, 'Nope', 'לא') is False
    assert queries.delete_upcoming_party(conn, 999999) is False


def test_get_votes_includes_upcoming_party_ids_and_empty_list_when_none(conn):
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party B') RETURNING id")
    party_b = cur.fetchone()[0]
    conn.commit()
    cur.close()

    considering_vote_id = queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[party_a, party_b],
        cookie_token='votes-token-1',
    )
    undecided_vote_id = queries.insert_vote(
        conn, team_picks=[_pick(league_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='votes-token-2',
    )

    votes = queries.get_votes(conn)
    assert [v['id'] for v in votes] == sorted(v['id'] for v in votes)

    by_id = {v['id']: v for v in votes}

    considering = by_id[considering_vote_id]
    assert sorted(considering['upcoming_party_ids']) == sorted([party_a, party_b])
    assert considering['team_picks'] == [{'league_id': league_id, 'club_id': club_id}]
    assert considering['previous_vote_status'] == 'did_not_vote'
    assert considering['previous_party_id'] is None
    assert considering['upcoming_vote_status'] == 'considering'
    assert 'created_at' in considering
    assert 'cookie_token' not in considering

    undecided = by_id[undecided_vote_id]
    assert undecided['upcoming_party_ids'] == []
    assert undecided['team_picks'] == [{'league_id': league_id, 'club_id': None}]


def test_get_votes_no_cartesian_inflation_with_multiple_clubs_and_upcoming_parties(conn):
    """Regression guard: a vote with 3 club picks AND 2 upcoming-party picks must show exactly
    3 team_picks and exactly 2 upcoming_party_ids in get_votes -- not 6 of either (the cartesian
    trap a naive multi-LEFT-JOIN + array_agg would fall into)."""
    epl_id, liverpool_id = _epl_and_liverpool(conn)
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'La Liga'")
    la_liga_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Barcelona'")
    barcelona_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Real Madrid'")
    real_madrid_id = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party B') RETURNING id")
    party_b = cur.fetchone()[0]
    conn.commit()
    cur.close()

    vote_id = queries.insert_vote(
        conn,
        team_picks=[_pick(epl_id, liverpool_id), _pick(la_liga_id, barcelona_id), _pick(la_liga_id, real_madrid_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[party_a, party_b],
        cookie_token='no-inflation-token',
    )

    vote = next(v for v in queries.get_votes(conn) if v['id'] == vote_id)
    assert len(vote['team_picks']) == 3
    assert len(vote['upcoming_party_ids']) == 2
    assert sorted(vote['upcoming_party_ids']) == sorted([party_a, party_b])


def test_delete_vote_removes_row_and_cascades_join_table(conn):
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party C') RETURNING id")
    party_c = cur.fetchone()[0]
    conn.commit()
    cur.close()

    vote_id = queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[party_c],
        cookie_token='delete-token-1',
    )

    assert queries.delete_vote(conn, vote_id) is True

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes WHERE id = %s', (vote_id,))
    assert cur.fetchone()[0] == 0
    cur.execute('SELECT COUNT(*) FROM vote_upcoming_parties WHERE vote_id = %s', (vote_id,))
    assert cur.fetchone()[0] == 0
    cur.execute('SELECT COUNT(*) FROM vote_clubs WHERE vote_id = %s', (vote_id,))
    assert cur.fetchone()[0] == 0
    cur.close()


def test_delete_vote_returns_false_for_nonexistent_id(conn):
    assert queries.delete_vote(conn, 999999) is False


def test_create_rename_delete_previous_party(conn):
    import queries

    party_id = queries.create_previous_party(conn, 'New Party', 'מפלגה חדשה')
    assert party_id > 0

    assert queries.rename_previous_party(conn, party_id, 'Renamed Party', 'מפלגה משודרגת') is True
    cur = conn.cursor()
    cur.execute('SELECT name_en, name_he FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone() == ('Renamed Party', 'מפלגה משודרגת')
    cur.close()

    assert queries.delete_previous_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_previous_party(conn, 999999, 'Nope', 'לא') is False
    assert queries.delete_previous_party(conn, 999999) is False


def test_create_previous_party_duplicate_english_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Dup Previous Party', 'מפלגה כפולה')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_previous_party(conn, 'Dup Previous Party', 'מפלגה אחרת')
    assert excinfo.value.language == 'en'

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_previous_party(conn, 'Another Previous Party', 'מפלגה נוספת')
    assert party_id > 0


def test_create_previous_party_duplicate_hebrew_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'First Party', 'שם משותף')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_previous_party(conn, 'Second Party', 'שם משותף')
    assert excinfo.value.language == 'he'

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_previous_party(conn, 'Third Party', 'שם ייחודי')
    assert party_id > 0


def test_rename_previous_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Party X', 'מפלגה X')
    party_id = queries.create_previous_party(conn, 'Party Y', 'מפלגה Y')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.rename_previous_party(conn, party_id, 'Party X', 'שם חדש')
    assert excinfo.value.language == 'en'

    # connection must be usable afterward - proves rollback happened
    assert queries.rename_previous_party(conn, party_id, 'Party Z', 'שם חדש') is True


def test_create_upcoming_party_duplicate_english_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Dup Upcoming Party', 'מפלגה כפולה')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_upcoming_party(conn, 'Dup Upcoming Party', 'מפלגה אחרת')
    assert excinfo.value.language == 'en'

    party_id = queries.create_upcoming_party(conn, 'Another Upcoming Party', 'מפלגה נוספת')
    assert party_id > 0


def test_create_upcoming_party_duplicate_hebrew_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'First Up Party', 'שם משותף עתידי')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.create_upcoming_party(conn, 'Second Up Party', 'שם משותף עתידי')
    assert excinfo.value.language == 'he'


def test_rename_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Party X', 'מפלגה X')
    party_id = queries.create_upcoming_party(conn, 'Party Y', 'מפלגה Y')

    with pytest.raises(queries.DuplicatePartyNameError) as excinfo:
        queries.rename_upcoming_party(conn, party_id, 'Party X', 'שם חדש')
    assert excinfo.value.language == 'en'

    # connection must be usable afterward - proves rollback happened
    assert queries.rename_upcoming_party(conn, party_id, 'Party Z', 'שם חדש') is True


def test_count_votes_for_previous_party(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    party_id = queries.create_previous_party(conn, 'Counted Party', 'Counted Party')

    assert queries.count_votes_for_previous_party(conn, party_id) == 0

    queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='voted', previous_party_id=party_id,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='count-prev-token-1',
    )
    assert queries.count_votes_for_previous_party(conn, party_id) == 1


def test_count_votes_for_upcoming_party(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    party_id = queries.create_upcoming_party(conn, 'Counted Upcoming Party', 'Counted Upcoming Party')

    assert queries.count_votes_for_upcoming_party(conn, party_id) == 0

    queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[party_id],
        cookie_token='count-up-token-1',
    )
    assert queries.count_votes_for_upcoming_party(conn, party_id) == 1


def test_reassign_previous_party_votes_updates_matching_rows_only(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    source_id = queries.create_previous_party(conn, 'Reassign Source', 'Reassign Source')
    target_id = queries.create_previous_party(conn, 'Reassign Target', 'Reassign Target')
    other_id = queries.create_previous_party(conn, 'Reassign Other', 'Reassign Other')

    v1 = queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='voted', previous_party_id=source_id,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-prev-1',
    )
    v2 = queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='voted', previous_party_id=other_id,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-prev-2',
    )

    reassigned = queries.reassign_previous_party_votes(conn, source_id, target_id)
    assert reassigned == 1

    votes_by_id = {v['id']: v for v in queries.get_votes(conn)}
    assert votes_by_id[v1]['previous_party_id'] == target_id
    assert votes_by_id[v2]['previous_party_id'] == other_id


def test_previous_party_exists(conn):
    party_id = queries.create_previous_party(conn, 'Exists Check', 'Exists Check')
    assert queries.previous_party_exists(conn, party_id) is True
    assert queries.previous_party_exists(conn, 999999) is False


def test_reassign_upcoming_party_votes_handles_collision_and_simple_case(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    source_id = queries.create_upcoming_party(conn, 'Reassign Up Source', 'Reassign Up Source')
    target_id = queries.create_upcoming_party(conn, 'Reassign Up Target', 'Reassign Up Target')
    other_id = queries.create_upcoming_party(conn, 'Reassign Up Other', 'Reassign Up Other')

    v_simple = queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[source_id, other_id],
        cookie_token='reassign-up-1',
    )
    v_collision = queries.insert_vote(
        conn, team_picks=[_pick(league_id, club_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[source_id, target_id],
        cookie_token='reassign-up-2',
    )

    reassigned = queries.reassign_upcoming_party_votes(conn, source_id, target_id)
    assert reassigned == 2

    votes_by_id = {v['id']: v for v in queries.get_votes(conn)}
    assert sorted(votes_by_id[v_simple]['upcoming_party_ids']) == sorted([target_id, other_id])
    assert votes_by_id[v_collision]['upcoming_party_ids'] == [target_id]


def test_upcoming_party_exists(conn):
    party_id = queries.create_upcoming_party(conn, 'Exists Check Upcoming', 'Exists Check Upcoming')
    assert queries.upcoming_party_exists(conn, party_id) is True
    assert queries.upcoming_party_exists(conn, 999999) is False


def test_count_votes_for_league_and_club_count_distinct_votes(conn):
    epl_id, liverpool_id = _epl_and_liverpool(conn)
    cur = conn.cursor()
    cur.execute("SELECT id FROM clubs WHERE name = 'Arsenal'")
    arsenal_id = cur.fetchone()[0]
    cur.close()

    assert queries.count_votes_for_league(conn, epl_id) == 0
    assert queries.count_votes_for_club(conn, liverpool_id) == 0

    # One vote picks two clubs in the same league -- must count once at league scope, but
    # count_votes_for_club is per-club so each club's own count is still 1.
    queries.insert_vote(
        conn, team_picks=[_pick(epl_id, liverpool_id), _pick(epl_id, arsenal_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='count-league-1',
    )
    assert queries.count_votes_for_league(conn, epl_id) == 1
    assert queries.count_votes_for_club(conn, liverpool_id) == 1
    assert queries.count_votes_for_club(conn, arsenal_id) == 1

    # A "just this league" pick also counts at league scope.
    queries.insert_vote(
        conn, team_picks=[_pick(epl_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='count-league-2',
    )
    assert queries.count_votes_for_league(conn, epl_id) == 2


def test_get_results_by_league_dedups_multi_club_ballot(conn):
    """A voter with 3 club picks in one league counts once at league scope (club_id IS NULL),
    even though the underlying rollup also carries 3 club-scope rows for the same vote."""
    epl_id, liverpool_id = _epl_and_liverpool(conn)
    cur = conn.cursor()
    cur.execute("SELECT id FROM clubs WHERE name = 'Arsenal'")
    arsenal_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES '
        '(%s, NULL, %s, %s), (%s, %s, %s, %s), (%s, %s, %s, %s)',
        (epl_id, party_x, 1, epl_id, liverpool_id, party_x, 1, epl_id, arsenal_id, party_x, 1)
    )
    conn.commit()
    cur.close()

    result = queries.get_results_by_league(conn, epl_id)
    previous = {row['party_id']: row['count'] for row in result['previous']}
    assert previous[party_x] == 1  # league scope: one vote, not summed across its 2 club rows


def test_reassign_league_votes_rewrites_vote_leagues_and_vote_clubs(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('Source League') RETURNING id")
    source_id = cur.fetchone()[0]
    cur.execute("INSERT INTO leagues (name) VALUES ('Target League') RETURNING id")
    target_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Source Club') RETURNING id", (source_id,))
    club_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    # A club still nominally lives under source_id here -- reassign_league_votes must still
    # rewrite vote_clubs rows referencing it (the "club moved off the league after votes were
    # cast" case is simulated by NOT moving the club, since the app-level precondition that
    # blocks league reassign while clubs remain is enforced in app.py, not this query function).
    v_just_league = queries.insert_vote(
        conn, team_picks=[_pick(source_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-league-1',
    )
    v_club = queries.insert_vote(
        conn, team_picks=[_pick(source_id, club_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-league-2',
    )

    reassigned = queries.reassign_league_votes(conn, source_id, target_id)
    assert reassigned == 2

    votes_by_id = {v['id']: v for v in queries.get_votes(conn)}
    assert votes_by_id[v_just_league]['team_picks'] == [{'league_id': target_id, 'club_id': None}]
    assert votes_by_id[v_club]['team_picks'] == [{'league_id': target_id, 'club_id': club_id}]


def test_reassign_league_votes_dedups_collision(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('Source League 2') RETURNING id")
    source_id = cur.fetchone()[0]
    cur.execute("INSERT INTO leagues (name) VALUES ('Target League 2') RETURNING id")
    target_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    # A vote that already has a "just this league" pick under BOTH source and target -- the
    # reassign must dedup rather than violate the (vote_id, league_id) primary key.
    vote_id = queries.insert_vote(
        conn, team_picks=[_pick(source_id), _pick(target_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-league-collision',
    )

    reassigned = queries.reassign_league_votes(conn, source_id, target_id)
    assert reassigned == 1

    vote = next(v for v in queries.get_votes(conn) if v['id'] == vote_id)
    assert vote['team_picks'] == [{'league_id': target_id, 'club_id': None}]


def test_reassign_club_votes_dedups_collision(conn):
    epl_id, liverpool_id = _epl_and_liverpool(conn)
    cur = conn.cursor()
    cur.execute("SELECT id FROM clubs WHERE name = 'Arsenal'")
    arsenal_id = cur.fetchone()[0]
    cur.close()

    # A vote that already has both the source and target club picked under the same league --
    # reassign must dedup rather than violate the (vote_id, club_id, league_id) primary key.
    vote_id = queries.insert_vote(
        conn, team_picks=[_pick(epl_id, liverpool_id), _pick(epl_id, arsenal_id)],
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-club-collision',
    )

    reassigned = queries.reassign_club_votes(conn, liverpool_id, arsenal_id)
    assert reassigned == 1

    vote = next(v for v in queries.get_votes(conn) if v['id'] == vote_id)
    assert vote['team_picks'] == [{'league_id': epl_id, 'club_id': arsenal_id}]


def test_get_results_switch_scopes(conn):
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute(
        'INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, 'stayed', 7)
    )
    cur.execute(
        'INSERT INTO rollup_vote_switch (league_id, club_id, switch_status, vote_count) VALUES (%s, NULL, %s, %s)',
        (league_id, 'switched', 3)
    )
    cur.execute(
        'INSERT INTO rollup_national_vote_switch (switch_status, vote_count) VALUES (%s, %s)',
        ('stayed', 100)
    )
    conn.commit()
    cur.close()

    club_result = queries.get_results_switch(conn, club_id=club_id)
    assert {'status': 'stayed', 'count': 7} in club_result['breakdown']

    league_result = queries.get_results_switch(conn, league_id=league_id)
    assert {'status': 'switched', 'count': 3} in league_result['breakdown']

    national_result = queries.get_results_switch(conn)
    assert {'status': 'stayed', 'count': 100} in national_result['breakdown']


def test_get_clubs_breakdown_shape(conn):
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, %s, %s, %s)',
        (league_id, club_id, party_id, 9)
    )
    # a league-scope row (club_id IS NULL) must NOT appear in the per-club breakdown
    cur.execute(
        'INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count) VALUES (%s, NULL, %s, %s)',
        (league_id, party_id, 40)
    )
    conn.commit()
    cur.close()

    breakdown = queries.get_clubs_breakdown(conn)
    entry = next(e for e in breakdown if e['club_id'] == club_id)
    assert entry['previous'] == [{'party_id': party_id, 'count': 9}]


# Parties deliberately left NULL on the religiosity axis: the Arab parties are scoped out
# (design Decision 3 -- "how religiously Jewish should the state be" is not a question they
# answer), Yashar has no declared ideology, and "Other" is a catch-all, not a party.
RELIGIOSITY_NULL_BY_DESIGN = {'רע"ם', 'חד"ש-תע"ל', 'בל"ד', 'ישר', 'אחר'}


def test_every_seeded_party_is_classified(conn):
    options = queries.get_options(conn)

    for key in ('previous_parties', 'upcoming_parties'):
        for party in options[key]:
            name = party['name_he']
            if name == 'אחר':
                continue
            assert party['bloc'] is not None, f'{key}/{name} has no bloc'
            assert party['sector'] is not None, f'{key}/{name} has no sector'
            if name in RELIGIOSITY_NULL_BY_DESIGN:
                assert party['religiosity'] is None, \
                    f'{key}/{name} is NULL by design but has a religiosity value'
            else:
                assert party['religiosity'] is not None, \
                    f'{key}/{name} is missing a religiosity value'
                assert -3 <= party['religiosity'] <= 3
