def _seed_votes(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party B') RETURNING id")
    party_b = cur.fetchone()[0]

    # Vote 1: voted Party X, considering both A and B
    cur.execute(
        '''INSERT INTO votes (league_id, club_id, previous_vote_status, previous_party_id,
           upcoming_vote_status, cookie_token) VALUES (%s, %s, 'voted', %s, 'considering', 't1') RETURNING id''',
        (league_id, club_id, party_x)
    )
    v1 = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v1, party_a))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v1, party_b))

    # Vote 2: did not vote previously, undecided now
    cur.execute(
        '''INSERT INTO votes (league_id, club_id, previous_vote_status, previous_party_id,
           upcoming_vote_status, cookie_token) VALUES (%s, %s, 'did_not_vote', NULL, 'undecided', 't2')''',
        (league_id, club_id)
    )

    conn.commit()
    cur.close()
    return league_id, club_id, party_x, party_a, party_b


def test_recompute_builds_previous_and_upcoming_rollups(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT previous_party_id, vote_count FROM rollup_previous ORDER BY previous_party_id NULLS LAST')
    previous_rows = cur.fetchall()
    assert (party_x, 1) in previous_rows
    assert (None, 1) in previous_rows

    cur.execute('SELECT upcoming_party_id, vote_count FROM rollup_upcoming ORDER BY upcoming_party_id NULLS LAST')
    upcoming_rows = cur.fetchall()
    assert (party_a, 1) in upcoming_rows
    assert (party_b, 1) in upcoming_rows
    assert (None, 1) in upcoming_rows  # the undecided vote
    cur.close()


def test_recompute_is_idempotent(conn):
    import rollups
    _seed_votes(conn)

    rollups.recompute(conn)
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM rollup_previous')
    first_count = cur.fetchone()[0]
    cur.close()

    rollups.recompute(conn)
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM rollup_previous')
    second_count = cur.fetchone()[0]
    cur.close()

    assert first_count == second_count
