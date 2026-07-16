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

    # Vote 1: picked Liverpool in EPL, voted Party X, considering both A and B
    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'considering', 't1') RETURNING id''',
        (party_x,)
    )
    v1 = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (v1, club_id, league_id))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v1, party_a))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (v1, party_b))

    # Vote 2: picked Liverpool in EPL, did not vote previously, undecided now
    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('did_not_vote', NULL, 'undecided', 't2') RETURNING id'''
    )
    v2 = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (v2, club_id, league_id))

    conn.commit()
    cur.close()
    return league_id, club_id, party_x, party_a, party_b


def test_recompute_builds_previous_and_upcoming_rollups(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT previous_party_id, vote_count FROM rollup_previous WHERE club_id = %s ORDER BY previous_party_id NULLS LAST', (club_id,))
    previous_rows = cur.fetchall()
    assert (party_x, 1) in previous_rows
    assert (None, 1) in previous_rows

    cur.execute('SELECT upcoming_party_id, vote_count FROM rollup_upcoming WHERE club_id = %s ORDER BY upcoming_party_id NULLS LAST', (club_id,))
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


def test_recompute_builds_previous_upcoming_crosstab(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id, vote_count FROM rollup_previous_upcoming '
        'WHERE club_id = %s '
        'ORDER BY previous_party_id NULLS LAST, upcoming_party_id NULLS LAST',
        (club_id,)
    )
    rows = cur.fetchall()
    cur.close()

    assert (party_x, party_a, 1) in rows
    assert (party_x, party_b, 1) in rows
    assert (None, None, 1) in rows  # did-not-vote AND undecided, from vote 2


def test_recompute_previous_upcoming_crosstab_carries_league_and_club(conn):
    import rollups
    league_id, club_id, party_x, party_a, party_b = _seed_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT previous_party_id, upcoming_party_id, league_id, club_id, vote_count '
        'FROM rollup_previous_upcoming WHERE club_id IS NOT NULL '
        'ORDER BY previous_party_id NULLS LAST, upcoming_party_id NULLS LAST'
    )
    rows = cur.fetchall()
    cur.close()

    # Every club-scope row (including the undecided/NULL-party branch) is tagged with the
    # league+club it came from, so a club/league filter over the migration matrix is possible.
    assert (party_x, party_a, league_id, club_id, 1) in rows
    assert (party_x, party_b, league_id, club_id, 1) in rows
    assert (None, None, league_id, club_id, 1) in rows


def test_recompute_league_scope_dedups_multi_club_ballot(conn):
    """A voter who picks 3 clubs in the SAME league must count once at league scope
    (club_id IS NULL), not three times -- the over-count bug the redesign guards against."""
    import rollups
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    club_ids = []
    for name in ('Liverpool', 'Arsenal', 'Chelsea'):
        cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, %s) RETURNING id", (league_id, name))
        club_ids.append(cur.fetchone()[0])
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]

    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'undecided', 't1') RETURNING id''',
        (party_x,)
    )
    vote_id = cur.fetchone()[0]
    for club_id in club_ids:
        cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_id, club_id, league_id))
    conn.commit()
    cur.close()

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT vote_count FROM rollup_previous WHERE league_id = %s AND club_id IS NULL AND previous_party_id = %s',
        (league_id, party_x)
    )
    league_scope_count = cur.fetchone()[0]
    assert league_scope_count == 1  # one vote, once at league scope

    cur.execute(
        'SELECT COUNT(*) FROM rollup_previous WHERE league_id = %s AND club_id IS NOT NULL AND previous_party_id = %s',
        (league_id, party_x)
    )
    club_scope_row_count = cur.fetchone()[0]
    assert club_scope_row_count == 3  # once per club picked

    # Same dedup applies to the undecided branch of rollup_upcoming at league scope.
    cur.execute(
        'SELECT vote_count FROM rollup_upcoming WHERE league_id = %s AND club_id IS NULL AND upcoming_party_id IS NULL',
        (league_id,)
    )
    undecided_league_scope = cur.fetchone()[0]
    assert undecided_league_scope == 1
    cur.close()


def test_recompute_national_tables_count_multi_pick_vote_once(conn):
    """The over-count regression guard: a ballot with clubs in 3 different leagues must count
    ONCE nationally, not 3 times, even though it produces 3+ rows in the per-scope rollups."""
    import rollups
    cur = conn.cursor()
    league_ids = []
    club_ids = []
    for league_name, club_name in (('EPL', 'Liverpool'), ('La Liga', 'Barcelona'), ('Serie A', 'Juventus')):
        cur.execute("INSERT INTO leagues (name) VALUES (%s) RETURNING id", (league_name,))
        league_id = cur.fetchone()[0]
        league_ids.append(league_id)
        cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, %s) RETURNING id", (league_id, club_name))
        club_ids.append(cur.fetchone()[0])
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Party A') RETURNING id")
    party_a = cur.fetchone()[0]

    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'considering', 't1') RETURNING id''',
        (party_x,)
    )
    vote_id = cur.fetchone()[0]
    for league_id, club_id in zip(league_ids, club_ids):
        cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_id, club_id, league_id))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (vote_id, party_a))
    conn.commit()
    cur.close()

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT vote_count FROM rollup_national_previous WHERE previous_party_id = %s', (party_x,))
    assert cur.fetchone()[0] == 1

    cur.execute('SELECT vote_count FROM rollup_national_upcoming WHERE upcoming_party_id = %s', (party_a,))
    assert cur.fetchone()[0] == 1

    cur.execute(
        'SELECT vote_count FROM rollup_national_previous_upcoming WHERE previous_party_id = %s AND upcoming_party_id = %s',
        (party_x, party_a)
    )
    assert cur.fetchone()[0] == 1

    # Meanwhile the per-scope rollup legitimately has 3 club-scope rows (one per league picked).
    cur.execute('SELECT COUNT(*) FROM rollup_previous WHERE previous_party_id = %s AND club_id IS NOT NULL', (party_x,))
    assert cur.fetchone()[0] == 3
    cur.close()


def test_recompute_national_undecided_branch(conn):
    import rollups
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]

    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('did_not_vote', NULL, 'undecided', 't1') RETURNING id'''
    )
    vote_id = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_id, club_id, league_id))
    conn.commit()
    cur.close()

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT vote_count FROM rollup_national_upcoming WHERE upcoming_party_id IS NULL')
    assert cur.fetchone()[0] == 1
    cur.execute('SELECT vote_count FROM rollup_national_previous_upcoming WHERE previous_party_id IS NULL AND upcoming_party_id IS NULL')
    assert cur.fetchone()[0] == 1
    cur.close()


def test_recompute_just_league_pick_counts_at_league_scope_only(conn):
    """A vote_leagues ("just this league") pick has no club, so it must show up as a league-scope
    row (club_id IS NULL) and must NOT produce any club-scope row."""
    import rollups
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]

    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'undecided', 't1') RETURNING id''',
        (party_x,)
    )
    vote_id = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_leagues (vote_id, league_id) VALUES (%s, %s)', (vote_id, league_id))
    conn.commit()
    cur.close()

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT vote_count FROM rollup_previous WHERE league_id = %s AND club_id IS NULL AND previous_party_id = %s',
        (league_id, party_x)
    )
    assert cur.fetchone()[0] == 1
    cur.execute('SELECT COUNT(*) FROM rollup_previous WHERE league_id = %s AND club_id IS NOT NULL', (league_id,))
    assert cur.fetchone()[0] == 0
    cur.close()


def _seed_switch_votes(conn):
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]

    cur.execute("INSERT INTO previous_parties (name) VALUES ('Prev A') RETURNING id")
    prev_a = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Prev B (no lineage)') RETURNING id")
    prev_b = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Up A') RETURNING id")
    up_a = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Up Other') RETURNING id")
    up_other = cur.fetchone()[0]

    # Prev A's only lineage successor is Up A
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_a, up_a)
    )

    def _vote(prev_status, prev_party, up_status, up_picks, token):
        cur.execute(
            '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
               VALUES (%s, %s, %s, %s) RETURNING id''',
            (prev_status, prev_party, up_status, token)
        )
        vote_id = cur.fetchone()[0]
        cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_id, club_id, league_id))
        for pick in up_picks:
            cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (vote_id, pick))
        return vote_id

    stayed_vote = _vote('voted', prev_a, 'considering', [up_a], 'switch-stayed')
    hedging_vote = _vote('voted', prev_a, 'considering', [up_a, up_other], 'switch-hedging')
    switched_vote = _vote('voted', prev_a, 'considering', [up_other], 'switch-switched')
    no_lineage_vote = _vote('voted', prev_b, 'considering', [up_other], 'switch-no-lineage')
    new_voter_vote = _vote('did_not_vote', None, 'considering', [up_other], 'switch-new-voter')
    undecided_vote = _vote('voted', prev_a, 'undecided', [], 'switch-undecided')

    conn.commit()
    cur.close()
    return {
        'league_id': league_id, 'club_id': club_id,
        'stayed': stayed_vote, 'hedging': hedging_vote, 'switched': switched_vote,
        'no_lineage': no_lineage_vote, 'new_voter': new_voter_vote, 'undecided': undecided_vote,
    }


def test_recompute_vote_switch_classifies_each_status(conn):
    import rollups
    ids = _seed_switch_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT switch_status, vote_count FROM rollup_vote_switch WHERE club_id = %s ORDER BY switch_status',
        (ids['club_id'],)
    )
    rows = dict(cur.fetchall())
    cur.close()

    assert rows['stayed'] == 1
    assert rows['hedging'] == 1
    # 'switched' includes both the vote whose successor wasn't picked and the vote with no lineage at all
    assert rows['switched'] == 2
    assert rows['new_voter'] == 1
    assert rows['undecided'] == 1


def test_recompute_national_vote_switch_matches_club_scope(conn):
    import rollups
    _seed_switch_votes(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute('SELECT switch_status, vote_count FROM rollup_national_vote_switch ORDER BY switch_status')
    rows = dict(cur.fetchall())
    cur.close()

    assert rows['stayed'] == 1
    assert rows['hedging'] == 1
    assert rows['switched'] == 2
    assert rows['new_voter'] == 1
    assert rows['undecided'] == 1


def test_recompute_vote_switch_stayed_via_merge(conn):
    """A previous party that merged into an upcoming party (i.e. party_lineage has MULTIPLE
    previous parties pointing at the same upcoming party) should still classify as 'stayed' for
    a voter whose sole pick is that shared successor -- not just for a 1:1 identity mapping."""
    import rollups
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO clubs (league_id, name) VALUES (%s, 'Liverpool') RETURNING id", (league_id,))
    club_id = cur.fetchone()[0]

    cur.execute("INSERT INTO previous_parties (name) VALUES ('Prev Merge A') RETURNING id")
    prev_merge_a = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Prev Merge B') RETURNING id")
    prev_merge_b = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Merged Party') RETURNING id")
    merged = cur.fetchone()[0]

    # Both predecessors merged into the same upcoming party.
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_merge_a, merged)
    )
    cur.execute(
        'INSERT INTO party_lineage (previous_party_id, upcoming_party_id) VALUES (%s, %s)',
        (prev_merge_b, merged)
    )

    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'considering', 'merge-stayed-a') RETURNING id''',
        (prev_merge_a,)
    )
    vote_a = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_a, club_id, league_id))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (vote_a, merged))

    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'considering', 'merge-stayed-b') RETURNING id''',
        (prev_merge_b,)
    )
    vote_b = cur.fetchone()[0]
    cur.execute('INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)', (vote_b, club_id, league_id))
    cur.execute('INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)', (vote_b, merged))

    conn.commit()
    cur.close()

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        "SELECT vote_count FROM rollup_national_vote_switch WHERE switch_status = 'stayed'"
    )
    row = cur.fetchone()
    cur.close()
    assert row[0] == 2
