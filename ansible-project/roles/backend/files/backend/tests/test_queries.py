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

    assert options['previous_parties'] == []
    assert options['upcoming_parties'] == []


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


def test_upsert_previous_parties_inserts_and_updates(conn):
    import queries
    n = queries.upsert_previous_parties(conn, [
        {'knesset_faction_id': '1096', 'name': 'Likud'},
        {'knesset_faction_id': '1101', 'name': 'Torah Judaism'},
    ])
    assert n == 2

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 2
    cur.close()

    # Re-sync with an updated faction id for the same name — should update, not duplicate
    queries.upsert_previous_parties(conn, [
        {'knesset_faction_id': '9999', 'name': 'Likud'},
    ])
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] == 2
    cur.execute("SELECT knesset_faction_id FROM previous_parties WHERE name = 'Likud'")
    assert cur.fetchone()[0] == '9999'
    cur.close()
