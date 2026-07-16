# A ballot can now name up to 3 clubs per league, across any number of leagues. So every rollup
# table below (except the rollup_national_* ones) carries TWO kinds of rows per vote:
#   - one LEAGUE-SCOPE row per distinct league the vote touched (club_id IS NULL), deduped so a
#     voter who picked 3 clubs in one league is counted once at that league's scope, not 3 times;
#   - one CLUB-SCOPE row per specific club pick (club_id set).
# "Distinct league touched" is the union of vote_clubs.league_id and vote_leagues.league_id for
# that vote -- a vote_leagues row is a "just this league, no club" pick, and every vote_clubs row
# also implies its vote touched that league.
#
# National totals (rollup_national_previous/_upcoming/_previous_upcoming) are separate: they hold
# exactly one row's worth of counting per vote, with no league/club dimension, because summing the
# league/club-scoped rollups for "national" would count a multi-team ballot multiple times.

_VOTE_LEAGUES_TOUCHED_CTE = '''
    SELECT vote_id, league_id FROM vote_clubs
    UNION
    SELECT vote_id, league_id FROM vote_leagues
'''


def recompute(conn):
    cur = conn.cursor()

    _recompute_previous(cur)
    _recompute_upcoming(cur)
    _recompute_previous_upcoming(cur)
    _recompute_national(cur)

    conn.commit()
    cur.close()


def _recompute_previous(cur):
    cur.execute('TRUNCATE rollup_previous')

    cur.execute(f'''
        INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count)
        SELECT vlt.league_id, NULL, v.previous_party_id, COUNT(*)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        GROUP BY vlt.league_id, v.previous_party_id
    ''')

    cur.execute('''
        INSERT INTO rollup_previous (league_id, club_id, previous_party_id, vote_count)
        SELECT vc.league_id, vc.club_id, v.previous_party_id, COUNT(*)
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        GROUP BY vc.league_id, vc.club_id, v.previous_party_id
    ''')


def _recompute_upcoming(cur):
    cur.execute('TRUNCATE rollup_upcoming')

    cur.execute(f'''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT vlt.league_id, NULL, vup.upcoming_party_id, COUNT(*)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY vlt.league_id, vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT vc.league_id, vc.club_id, vup.upcoming_party_id, COUNT(*)
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY vc.league_id, vc.club_id, vup.upcoming_party_id
    ''')

    cur.execute(f'''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT vlt.league_id, NULL, NULL, COUNT(*)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        WHERE v.upcoming_vote_status = 'undecided'
        GROUP BY vlt.league_id
    ''')
    cur.execute('''
        INSERT INTO rollup_upcoming (league_id, club_id, upcoming_party_id, vote_count)
        SELECT vc.league_id, vc.club_id, NULL, COUNT(*)
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        WHERE v.upcoming_vote_status = 'undecided'
        GROUP BY vc.league_id, vc.club_id
    ''')


def _recompute_previous_upcoming(cur):
    cur.execute('TRUNCATE rollup_previous_upcoming')

    cur.execute(f'''
        INSERT INTO rollup_previous_upcoming
            (previous_party_id, upcoming_party_id, league_id, club_id, vote_count)
        SELECT v.previous_party_id, vup.upcoming_party_id, vlt.league_id, NULL, COUNT(*)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.previous_party_id, vup.upcoming_party_id, vlt.league_id
    ''')
    cur.execute('''
        INSERT INTO rollup_previous_upcoming
            (previous_party_id, upcoming_party_id, league_id, club_id, vote_count)
        SELECT v.previous_party_id, vup.upcoming_party_id, vc.league_id, vc.club_id, COUNT(*)
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.previous_party_id, vup.upcoming_party_id, vc.league_id, vc.club_id
    ''')

    cur.execute(f'''
        INSERT INTO rollup_previous_upcoming
            (previous_party_id, upcoming_party_id, league_id, club_id, vote_count)
        SELECT v.previous_party_id, NULL, vlt.league_id, NULL, COUNT(*)
        FROM ({_VOTE_LEAGUES_TOUCHED_CTE}) vlt
        JOIN votes v ON v.id = vlt.vote_id
        WHERE v.upcoming_vote_status = 'undecided'
        GROUP BY v.previous_party_id, vlt.league_id
    ''')
    cur.execute('''
        INSERT INTO rollup_previous_upcoming
            (previous_party_id, upcoming_party_id, league_id, club_id, vote_count)
        SELECT v.previous_party_id, NULL, vc.league_id, vc.club_id, COUNT(*)
        FROM vote_clubs vc
        JOIN votes v ON v.id = vc.vote_id
        WHERE v.upcoming_vote_status = 'undecided'
        GROUP BY v.previous_party_id, vc.league_id, vc.club_id
    ''')


def _recompute_national(cur):
    cur.execute('TRUNCATE rollup_national_previous')
    cur.execute('''
        INSERT INTO rollup_national_previous (previous_party_id, vote_count)
        SELECT previous_party_id, COUNT(*) FROM votes GROUP BY previous_party_id
    ''')

    cur.execute('TRUNCATE rollup_national_upcoming')
    cur.execute('''
        INSERT INTO rollup_national_upcoming (upcoming_party_id, vote_count)
        SELECT vup.upcoming_party_id, COUNT(*)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_national_upcoming (upcoming_party_id, vote_count)
        SELECT NULL, COUNT(*) FROM votes WHERE upcoming_vote_status = 'undecided'
        HAVING COUNT(*) > 0
    ''')

    cur.execute('TRUNCATE rollup_national_previous_upcoming')
    cur.execute('''
        INSERT INTO rollup_national_previous_upcoming
            (previous_party_id, upcoming_party_id, vote_count)
        SELECT v.previous_party_id, vup.upcoming_party_id, COUNT(*)
        FROM votes v
        JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
        GROUP BY v.previous_party_id, vup.upcoming_party_id
    ''')
    cur.execute('''
        INSERT INTO rollup_national_previous_upcoming
            (previous_party_id, upcoming_party_id, vote_count)
        SELECT previous_party_id, NULL, COUNT(*)
        FROM votes
        WHERE upcoming_vote_status = 'undecided'
        GROUP BY previous_party_id
    ''')
