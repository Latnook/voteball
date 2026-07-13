import pytest
import queries


def test_get_options_returns_seeded_leagues(conn):
    options = queries.get_options(conn)
    league_names = {l['name'] for l in options['leagues']}
    assert 'EPL' in league_names
    assert 'Israeli Premier League' in league_names

    club_names = {c['name'] for c in options['clubs']}
    assert 'Liverpool' in club_names

    epl = next(l for l in options['leagues'] if l['name'] == 'EPL')
    epl_clubs = [c for c in options['clubs'] if c['league_id'] == epl['id']]
    assert len(epl_clubs) == 20

    previous_names = {p['name'] for p in options['previous_parties']}
    assert previous_names == {
        'הליכוד', 'יש עתיד', 'הציונות הדתית', 'המחנה הממלכתי', 'ישראל ביתנו',
        'ש"ס', 'יהדות התורה', 'רע"ם', 'חד"ש-תע"ל', 'העבודה', 'מרצ', 'בל"ד',
        'הבית היהודי', 'אחר',
    }

    upcoming_names = {p['name'] for p in options['upcoming_parties']}
    assert upcoming_names == {
        'הליכוד', 'ישר', 'ביחד', 'הדמוקרטים', 'כחול לבן', 'ישראל ביתנו',
        'הציונות הדתית', 'עוצמה יהודית', 'חד"ש-תע"ל', 'בל"ד',
        'המפלגה הכלכלית', 'אל הדגל', 'המילואימניקים',
    }


def _epl_and_liverpool(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.close()
    return league_id, club_id


def test_insert_vote_league_only_did_not_vote_undecided(conn):
    league_id, _ = _epl_and_liverpool(conn)

    vote_id = queries.insert_vote(
        conn,
        league_id=league_id, club_id=None,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='token-a',
    )
    assert vote_id > 0

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM vote_upcoming_parties WHERE vote_id = %s', (vote_id,))
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
        league_id=league_id, club_id=club_id,
        previous_vote_status='voted', previous_party_id=previous_party_id,
        upcoming_vote_status='considering', upcoming_party_ids=[party_a, party_b],
        cookie_token='token-b',
    )

    cur = conn.cursor()
    cur.execute('SELECT upcoming_party_id FROM vote_upcoming_parties WHERE vote_id = %s ORDER BY upcoming_party_id', (vote_id,))
    assert [r[0] for r in cur.fetchall()] == sorted([party_a, party_b])
    cur.close()


def test_insert_vote_invalid_previous_vote_status_raises_and_rolls_back(conn):
    league_id, _ = _epl_and_liverpool(conn)

    with pytest.raises(Exception):
        queries.insert_vote(
            conn, league_id=league_id, club_id=None,
            previous_vote_status='not_a_real_status', previous_party_id=None,
            upcoming_vote_status='undecided', upcoming_party_ids=[],
            cookie_token='bad-status-token',
        )

    # connection must be usable afterward - proves rollback happened
    vote_id = queries.insert_vote(
        conn, league_id=league_id, club_id=None,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='good-token-after-bad',
    )
    assert vote_id > 0


def test_insert_vote_duplicate_cookie_token_rejected(conn):
    league_id, _ = _epl_and_liverpool(conn)

    queries.insert_vote(
        conn, league_id=league_id, club_id=None,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='dup-token',
    )
    with pytest.raises(ValueError):
        queries.insert_vote(
            conn, league_id=league_id, club_id=None,
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
    import queries
    league_id, club_id, party_x = _seed_rollup_rows(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, party_a, 5)
    )
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
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
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
        (party_x, party_a, 5)
    )
    cur.execute(
        'INSERT INTO rollup_previous_upcoming (previous_party_id, upcoming_party_id, vote_count) VALUES (%s, %s, %s)',
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

    party_id = queries.create_upcoming_party(conn, 'New Party')
    assert party_id > 0

    assert queries.rename_upcoming_party(conn, party_id, 'Renamed Party') is True
    cur = conn.cursor()
    cur.execute('SELECT name FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 'Renamed Party'
    cur.close()

    assert queries.delete_upcoming_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM upcoming_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_upcoming_party(conn, 999999, 'Nope') is False
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
        conn, league_id=league_id, club_id=club_id,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[party_a, party_b],
        cookie_token='votes-token-1',
    )
    undecided_vote_id = queries.insert_vote(
        conn, league_id=league_id, club_id=None,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='votes-token-2',
    )

    votes = queries.get_votes(conn)
    assert [v['id'] for v in votes] == sorted(v['id'] for v in votes)

    by_id = {v['id']: v for v in votes}

    considering = by_id[considering_vote_id]
    assert sorted(considering['upcoming_party_ids']) == sorted([party_a, party_b])
    assert considering['league_id'] == league_id
    assert considering['club_id'] == club_id
    assert considering['previous_vote_status'] == 'did_not_vote'
    assert considering['previous_party_id'] is None
    assert considering['upcoming_vote_status'] == 'considering'
    assert 'created_at' in considering
    assert 'cookie_token' not in considering

    undecided = by_id[undecided_vote_id]
    assert undecided['upcoming_party_ids'] == []


def test_delete_vote_removes_row_and_cascades_join_table(conn):
    league_id, club_id = _epl_and_liverpool(conn)

    cur = conn.cursor()
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party C') RETURNING id")
    party_c = cur.fetchone()[0]
    conn.commit()
    cur.close()

    vote_id = queries.insert_vote(
        conn, league_id=league_id, club_id=club_id,
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
    cur.close()


def test_delete_vote_returns_false_for_nonexistent_id(conn):
    assert queries.delete_vote(conn, 999999) is False


def test_create_rename_delete_previous_party(conn):
    import queries

    party_id = queries.create_previous_party(conn, 'New Party')
    assert party_id > 0

    assert queries.rename_previous_party(conn, party_id, 'Renamed Party') is True
    cur = conn.cursor()
    cur.execute('SELECT name FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 'Renamed Party'
    cur.close()

    assert queries.delete_previous_party(conn, party_id) is True
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties WHERE id = %s', (party_id,))
    assert cur.fetchone()[0] == 0
    cur.close()

    assert queries.rename_previous_party(conn, 999999, 'Nope') is False
    assert queries.delete_previous_party(conn, 999999) is False


def test_create_previous_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Dup Previous Party')

    with pytest.raises(queries.DuplicatePartyNameError):
        queries.create_previous_party(conn, 'Dup Previous Party')

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_previous_party(conn, 'Another Previous Party')
    assert party_id > 0


def test_rename_previous_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_previous_party(conn, 'Party X')
    party_id = queries.create_previous_party(conn, 'Party Y')

    with pytest.raises(queries.DuplicatePartyNameError):
        queries.rename_previous_party(conn, party_id, 'Party X')

    # connection must be usable afterward - proves rollback happened
    assert queries.rename_previous_party(conn, party_id, 'Party Z') is True


def test_create_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Dup Upcoming Party')

    with pytest.raises(queries.DuplicatePartyNameError):
        queries.create_upcoming_party(conn, 'Dup Upcoming Party')

    # connection must be usable afterward - proves rollback happened
    party_id = queries.create_upcoming_party(conn, 'Another Upcoming Party')
    assert party_id > 0


def test_rename_upcoming_party_duplicate_name_rolls_back_and_conn_still_usable(conn):
    import queries

    queries.create_upcoming_party(conn, 'Party X')
    party_id = queries.create_upcoming_party(conn, 'Party Y')

    with pytest.raises(queries.DuplicatePartyNameError):
        queries.rename_upcoming_party(conn, party_id, 'Party X')

    # connection must be usable afterward - proves rollback happened
    assert queries.rename_upcoming_party(conn, party_id, 'Party Z') is True


def test_count_votes_for_previous_party(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    party_id = queries.create_previous_party(conn, 'Counted Party')

    assert queries.count_votes_for_previous_party(conn, party_id) == 0

    queries.insert_vote(
        conn, league_id=league_id, club_id=club_id,
        previous_vote_status='voted', previous_party_id=party_id,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='count-prev-token-1',
    )
    assert queries.count_votes_for_previous_party(conn, party_id) == 1


def test_count_votes_for_upcoming_party(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    party_id = queries.create_upcoming_party(conn, 'Counted Upcoming Party')

    assert queries.count_votes_for_upcoming_party(conn, party_id) == 0

    queries.insert_vote(
        conn, league_id=league_id, club_id=club_id,
        previous_vote_status='did_not_vote', previous_party_id=None,
        upcoming_vote_status='considering', upcoming_party_ids=[party_id],
        cookie_token='count-up-token-1',
    )
    assert queries.count_votes_for_upcoming_party(conn, party_id) == 1


def test_reassign_previous_party_votes_updates_matching_rows_only(conn):
    league_id, club_id = _epl_and_liverpool(conn)
    source_id = queries.create_previous_party(conn, 'Reassign Source')
    target_id = queries.create_previous_party(conn, 'Reassign Target')
    other_id = queries.create_previous_party(conn, 'Reassign Other')

    v1 = queries.insert_vote(
        conn, league_id=league_id, club_id=club_id,
        previous_vote_status='voted', previous_party_id=source_id,
        upcoming_vote_status='undecided', upcoming_party_ids=[],
        cookie_token='reassign-prev-1',
    )
    v2 = queries.insert_vote(
        conn, league_id=league_id, club_id=club_id,
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
    party_id = queries.create_previous_party(conn, 'Exists Check')
    assert queries.previous_party_exists(conn, party_id) is True
    assert queries.previous_party_exists(conn, 999999) is False
