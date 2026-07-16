def recompute(conn):
    cur = conn.cursor()

    cur.execute('TRUNCATE rollup_previous')
    cur.execute('''
        INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count)
        SELECT league_id, club_id, previous_party_id, COUNT(*)
        FROM votes
        GROUP BY league_id, club_id, previous_party_id
    ''')

    cur.execute('TRUNCATE rollup_upcoming')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT v.league_id, v.club_id, vup.upcoming_party_id, COUNT(*)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.league_id, v.club_id, vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT league_id, club_id, NULL, COUNT(*)
        FROM votes
        WHERE upcoming_vote_status = 'undecided'
        GROUP BY league_id, club_id
    ''')

    cur.execute('TRUNCATE rollup_previous_upcoming')
    cur.execute('''
        INSERT INTO rollup_previous_upcoming
            (previous_party_id, upcoming_party_id, league_id, club_id, vote_count)
        SELECT v.previous_party_id, vup.upcoming_party_id, v.league_id, v.club_id, COUNT(*)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.previous_party_id, vup.upcoming_party_id, v.league_id, v.club_id
    ''')
    cur.execute('''
        INSERT INTO rollup_previous_upcoming
            (previous_party_id, upcoming_party_id, league_id, club_id, vote_count)
        SELECT previous_party_id, NULL, league_id, club_id, COUNT(*)
        FROM votes
        WHERE upcoming_vote_status = 'undecided'
        GROUP BY previous_party_id, league_id, club_id
    ''')

    conn.commit()
    cur.close()
