import psycopg2


class DuplicatePartyNameError(Exception):
    def __init__(self, language):
        self.language = language  # 'en' or 'he'
        super().__init__(f'a party with this {language} name already exists')


def _duplicate_party_language(err):
    constraint = err.diag.constraint_name or ''
    if constraint.endswith('_name_en_uidx'):
        return 'en'
    return 'he'


def get_options(conn):
    cur = conn.cursor()

    cur.execute('SELECT id, name_en, name_he, logo_url FROM leagues ORDER BY name_en')
    leagues = [{'id': r[0], 'name_en': r[1], 'name_he': r[2], 'logo_url': r[3]} for r in cur.fetchall()]

    cur.execute(
        'SELECT id, league_id, domestic_league_id, name_en, name_he, logo_url FROM clubs ORDER BY name_en'
    )
    clubs = [
        {
            'id': r[0], 'league_id': r[1], 'domestic_league_id': r[2],
            'name_en': r[3], 'name_he': r[4], 'logo_url': r[5],
        }
        for r in cur.fetchall()
    ]

    cur.execute('SELECT id, name_en, name_he, logo_url FROM previous_parties ORDER BY name_en')
    previous_parties = [
        {'id': r[0], 'name_en': r[1], 'name_he': r[2], 'logo_url': r[3]} for r in cur.fetchall()
    ]

    cur.execute('SELECT id, name_en, name_he, logo_url FROM upcoming_parties ORDER BY name_en')
    upcoming_parties = [
        {'id': r[0], 'name_en': r[1], 'name_he': r[2], 'logo_url': r[3]} for r in cur.fetchall()
    ]

    cur.close()
    return {
        'leagues': leagues,
        'clubs': clubs,
        'previous_parties': previous_parties,
        'upcoming_parties': upcoming_parties,
    }


def insert_vote(conn, team_picks, previous_vote_status, previous_party_id,
                 upcoming_vote_status, upcoming_party_ids, cookie_token):
    """team_picks: list of {'league_id': int, 'club_id': int|None}. club_id None means
    "just this league, no specific club" and is stored in vote_leagues; a set club_id is
    stored in vote_clubs alongside the league it was picked under."""
    cur = conn.cursor()
    try:
        cur.execute(
            '''INSERT INTO votes
               (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
               VALUES (%s, %s, %s, %s) RETURNING id''',
            (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
        )
        vote_id = cur.fetchone()[0]

        for pick in team_picks:
            if pick['club_id'] is None:
                cur.execute(
                    'INSERT INTO vote_leagues (vote_id, league_id) VALUES (%s, %s)',
                    (vote_id, pick['league_id'])
                )
            else:
                cur.execute(
                    'INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)',
                    (vote_id, pick['club_id'], pick['league_id'])
                )

        for party_id in upcoming_party_ids:
            cur.execute(
                'INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)',
                (vote_id, party_id)
            )

        conn.commit()
        return vote_id
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        raise ValueError(f'duplicate cookie_token: {cookie_token}')
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def get_results_by_club(conn, club_id):
    return _results_for_filter(conn, 'club_id = %s', (club_id,))


def get_results_by_league(conn, league_id):
    # club_id IS NULL selects the league-scope rows only (one per vote that touched this league),
    # so a voter who picked 3 clubs in this league is counted once here, not three times -- the
    # separate club_id-set rows are what ?by=club reads.
    return _results_for_filter(conn, 'league_id = %s AND club_id IS NULL', (league_id,))


def _results_for_filter(conn, where_clause, params):
    cur = conn.cursor()
    cur.execute(
        f'SELECT previous_party_id, SUM(vote_count) FROM rollup_previous '
        f'WHERE {where_clause} GROUP BY previous_party_id',
        params
    )
    previous = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.execute(
        f'SELECT upcoming_party_id, SUM(vote_count) FROM rollup_upcoming '
        f'WHERE {where_clause} GROUP BY upcoming_party_id',
        params
    )
    upcoming = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.close()
    return {'previous': previous, 'upcoming': upcoming}


def get_results_all(conn):
    # National totals read the national rollup tables (one row's worth of counting per vote, no
    # league/club dimension) -- NOT a no-filter sum over rollup_previous/rollup_upcoming, since
    # those now carry multiple rows per multi-team ballot and would over-count it nationally.
    cur = conn.cursor()
    cur.execute('SELECT previous_party_id, SUM(vote_count) FROM rollup_national_previous GROUP BY previous_party_id')
    previous = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.execute('SELECT upcoming_party_id, SUM(vote_count) FROM rollup_national_upcoming GROUP BY upcoming_party_id')
    upcoming = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.close()
    return {'previous': previous, 'upcoming': upcoming}


def get_results_segment(conn, previous_party_id, club_id=None, league_id=None):
    cur = conn.cursor()

    if club_id is not None:
        where_sql = 'previous_party_id = %s AND club_id = %s'
        params = [previous_party_id, club_id]
        upcoming_table = 'rollup_previous_upcoming'
        total_table = 'rollup_previous'
    elif league_id is not None:
        where_sql = 'previous_party_id = %s AND league_id = %s AND club_id IS NULL'
        params = [previous_party_id, league_id]
        upcoming_table = 'rollup_previous_upcoming'
        total_table = 'rollup_previous'
    else:
        # No scope given -- national segment. Read the national tables (one row's worth of
        # counting per vote), not the per-scope tables with no filter (which would over-count).
        where_sql = 'previous_party_id = %s'
        params = [previous_party_id]
        upcoming_table = 'rollup_national_previous_upcoming'
        total_table = 'rollup_national_previous'

    cur.execute(
        f'SELECT upcoming_party_id, SUM(vote_count) FROM {upcoming_table} '
        f'WHERE {where_sql} GROUP BY upcoming_party_id',
        params
    )
    upcoming = [{'party_id': r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.execute(
        f'SELECT COALESCE(SUM(vote_count), 0) FROM {total_table} WHERE {where_sql}',
        params
    )
    total = cur.fetchone()[0]

    cur.close()
    return {'upcoming': upcoming, 'total': total}


def get_results_by_party(conn, party_type, party_id):
    table = 'rollup_previous' if party_type == 'previous' else 'rollup_upcoming'
    column = 'previous_party_id' if party_type == 'previous' else 'upcoming_party_id'
    other_column = 'upcoming_party_id' if party_type == 'previous' else 'previous_party_id'

    cur = conn.cursor()
    cur.execute(
        f'SELECT league_id, club_id, SUM(vote_count) FROM {table} '
        f'WHERE {column} = %s GROUP BY league_id, club_id',
        (party_id,)
    )
    breakdown = [{'league_id': r[0], 'club_id': r[1], 'count': r[2]} for r in cur.fetchall()]

    # crosstab is a national migration figure (no league/club dimension), so it reads the
    # national table -- rollup_previous_upcoming would over-count a multi-team voter here.
    cur.execute(
        f'SELECT {other_column}, SUM(vote_count) FROM rollup_national_previous_upcoming '
        f'WHERE {column} = %s GROUP BY {other_column}',
        (party_id,)
    )
    crosstab = [{other_column: r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.close()
    return {'breakdown': breakdown, 'crosstab': crosstab}


def create_upcoming_party(conn, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO upcoming_parties (name, name_en, name_he, logo_url) '
            'VALUES (%s, %s, %s, %s) RETURNING id',
            (name_he, name_en, name_he, logo_url)
        )
        party_id = cur.fetchone()[0]
        conn.commit()
        return party_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_upcoming_party(conn, party_id, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE upcoming_parties SET name = %s, name_en = %s, name_he = %s, logo_url = %s, '
            'updated_at = NOW() WHERE id = %s',
            (name_he, name_en, name_he, logo_url, party_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_upcoming_party(conn, party_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM upcoming_parties WHERE id = %s', (party_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def create_previous_party(conn, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO previous_parties (name, name_en, name_he, logo_url) '
            'VALUES (%s, %s, %s, %s) RETURNING id',
            (name_he, name_en, name_he, logo_url)
        )
        party_id = cur.fetchone()[0]
        conn.commit()
        return party_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_previous_party(conn, party_id, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE previous_parties SET name = %s, name_en = %s, name_he = %s, logo_url = %s, '
            'updated_at = NOW() WHERE id = %s',
            (name_he, name_en, name_he, logo_url, party_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_previous_party(conn, party_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM previous_parties WHERE id = %s', (party_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def get_votes(conn):
    # Assembled from separate queries rather than one multi-LEFT-JOIN + array_agg: a vote can now
    # have several vote_clubs/vote_leagues rows AND several vote_upcoming_parties rows, and joining
    # all of them in one query produces a cartesian product that inflates every aggregate. Fetching
    # each child table separately and assembling in Python keeps each list correct independently.
    cur = conn.cursor()
    cur.execute(
        '''SELECT id, previous_vote_status, previous_party_id, upcoming_vote_status, created_at
           FROM votes ORDER BY id'''
    )
    votes = [
        {
            'id': r[0],
            'previous_vote_status': r[1],
            'previous_party_id': r[2],
            'upcoming_vote_status': r[3],
            'created_at': r[4].isoformat(),
            'team_picks': [],
            'upcoming_party_ids': [],
        }
        for r in cur.fetchall()
    ]
    votes_by_id = {v['id']: v for v in votes}

    cur.execute('SELECT vote_id, club_id, league_id FROM vote_clubs ORDER BY vote_id')
    for vote_id, club_id, league_id in cur.fetchall():
        if vote_id in votes_by_id:
            votes_by_id[vote_id]['team_picks'].append({'league_id': league_id, 'club_id': club_id})

    cur.execute('SELECT vote_id, league_id FROM vote_leagues ORDER BY vote_id')
    for vote_id, league_id in cur.fetchall():
        if vote_id in votes_by_id:
            votes_by_id[vote_id]['team_picks'].append({'league_id': league_id, 'club_id': None})

    cur.execute('SELECT vote_id, upcoming_party_id FROM vote_upcoming_parties ORDER BY vote_id')
    for vote_id, upcoming_party_id in cur.fetchall():
        if vote_id in votes_by_id:
            votes_by_id[vote_id]['upcoming_party_ids'].append(upcoming_party_id)

    cur.close()
    return votes


def delete_vote(conn, vote_id):
    cur = conn.cursor()
    cur.execute('DELETE FROM votes WHERE id = %s', (vote_id,))
    deleted = cur.rowcount > 0
    conn.commit()
    cur.close()
    return deleted


def count_votes_for_previous_party(conn, party_id):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes WHERE previous_party_id = %s', (party_id,))
    count = cur.fetchone()[0]
    cur.close()
    return count


def count_votes_for_upcoming_party(conn, party_id):
    cur = conn.cursor()
    cur.execute(
        'SELECT COUNT(DISTINCT vote_id) FROM vote_upcoming_parties WHERE upcoming_party_id = %s',
        (party_id,)
    )
    count = cur.fetchone()[0]
    cur.close()
    return count


def previous_party_exists(conn, party_id):
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM previous_parties WHERE id = %s', (party_id,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def reassign_previous_party_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE votes SET previous_party_id = %s WHERE previous_party_id = %s',
            (target_id, source_id)
        )
        reassigned = cur.rowcount
        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def upcoming_party_exists(conn, party_id):
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM upcoming_parties WHERE id = %s', (party_id,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def reassign_upcoming_party_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute(
            'SELECT COUNT(DISTINCT vote_id) FROM vote_upcoming_parties WHERE upcoming_party_id = %s',
            (source_id,)
        )
        reassigned = cur.fetchone()[0]

        # Drop rows where the vote already has target among its picks - avoids violating
        # the (vote_id, upcoming_party_id) primary key on the UPDATE below.
        cur.execute(
            '''DELETE FROM vote_upcoming_parties
               WHERE upcoming_party_id = %s
                 AND vote_id IN (
                     SELECT vote_id FROM vote_upcoming_parties WHERE upcoming_party_id = %s
                 )''',
            (source_id, target_id)
        )
        cur.execute(
            'UPDATE vote_upcoming_parties SET upcoming_party_id = %s WHERE upcoming_party_id = %s',
            (target_id, source_id)
        )
        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def create_league(conn, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO leagues (name, name_en, name_he, logo_url) VALUES (%s, %s, %s, %s) RETURNING id',
            (name_he, name_en, name_he, logo_url)
        )
        league_id = cur.fetchone()[0]
        conn.commit()
        return league_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_league(conn, league_id, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE leagues SET name = %s, name_en = %s, name_he = %s, logo_url = %s WHERE id = %s',
            (name_he, name_en, name_he, logo_url, league_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicatePartyNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_league(conn, league_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM leagues WHERE id = %s', (league_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def league_exists(conn, league_id):
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM leagues WHERE id = %s', (league_id,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def get_all_league_ids(conn):
    cur = conn.cursor()
    cur.execute('SELECT id FROM leagues')
    ids = {r[0] for r in cur.fetchall()}
    cur.close()
    return ids


def get_clubs_league_map(conn):
    """{club_id: {'league_id': int, 'domestic_league_id': int|None}} -- used to validate that a
    /api/vote team pick's (club_id, league_id) pair is one of that club's real two leagues."""
    cur = conn.cursor()
    cur.execute('SELECT id, league_id, domestic_league_id FROM clubs')
    result = {r[0]: {'league_id': r[1], 'domestic_league_id': r[2]} for r in cur.fetchall()}
    cur.close()
    return result


def count_votes_for_league(conn, league_id):
    cur = conn.cursor()
    cur.execute(
        '''SELECT COUNT(DISTINCT vote_id) FROM (
               SELECT vote_id FROM vote_clubs WHERE league_id = %s
               UNION
               SELECT vote_id FROM vote_leagues WHERE league_id = %s
           ) u''',
        (league_id, league_id)
    )
    count = cur.fetchone()[0]
    cur.close()
    return count


def count_clubs_for_league(conn, league_id):
    cur = conn.cursor()
    cur.execute(
        'SELECT COUNT(*) FROM clubs WHERE league_id = %s OR domestic_league_id = %s',
        (league_id, league_id)
    )
    count = cur.fetchone()[0]
    cur.close()
    return count


def reassign_league_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute(
            '''SELECT COUNT(DISTINCT vote_id) FROM (
                   SELECT vote_id FROM vote_clubs WHERE league_id = %s
                   UNION
                   SELECT vote_id FROM vote_leagues WHERE league_id = %s
               ) u''',
            (source_id, source_id)
        )
        reassigned = cur.fetchone()[0]

        # vote_leagues: drop rows where the vote already has the target league (avoids violating
        # the (vote_id, league_id) primary key on the UPDATE), same pattern as
        # reassign_upcoming_party_votes.
        cur.execute(
            '''DELETE FROM vote_leagues
               WHERE league_id = %s
                 AND vote_id IN (SELECT vote_id FROM vote_leagues WHERE league_id = %s)''',
            (source_id, target_id)
        )
        cur.execute(
            'UPDATE vote_leagues SET league_id = %s WHERE league_id = %s',
            (target_id, source_id)
        )

        # vote_clubs: a club pick's league_id records which tab it was picked under, and can
        # still reference the source league even after the "source league has zero clubs"
        # precondition is met (a club could've been moved off that league after votes were cast
        # under it) -- so these rows must be rewritten too, not just vote_leagues. Dedup on
        # (vote_id, club_id) collisions between source and target league.
        cur.execute(
            '''DELETE FROM vote_clubs vc1
               WHERE vc1.league_id = %s
                 AND EXISTS (
                     SELECT 1 FROM vote_clubs vc2
                     WHERE vc2.vote_id = vc1.vote_id AND vc2.club_id = vc1.club_id
                       AND vc2.league_id = %s
                 )''',
            (source_id, target_id)
        )
        cur.execute(
            'UPDATE vote_clubs SET league_id = %s WHERE league_id = %s',
            (target_id, source_id)
        )

        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


class DuplicateClubNameError(Exception):
    def __init__(self, language):
        self.language = language
        super().__init__(f'a club with this {language} name already exists')


def create_club(conn, league_id, domestic_league_id, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he, logo_url) '
            'VALUES (%s, %s, %s, %s, %s, %s) RETURNING id',
            (league_id, domestic_league_id, name_he, name_en, name_he, logo_url)
        )
        club_id = cur.fetchone()[0]
        conn.commit()
        return club_id
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicateClubNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he, logo_url=None):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE clubs SET league_id = %s, domestic_league_id = %s, name = %s, name_en = %s, '
            'name_he = %s, logo_url = %s WHERE id = %s',
            (league_id, domestic_league_id, name_he, name_en, name_he, logo_url, club_id)
        )
        updated = cur.rowcount > 0
        conn.commit()
        return updated
    except psycopg2.errors.UniqueViolation as err:
        conn.rollback()
        raise DuplicateClubNameError(_duplicate_party_language(err))
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def delete_club(conn, club_id):
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM clubs WHERE id = %s', (club_id,))
        deleted = cur.rowcount > 0
        conn.commit()
        return deleted
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def club_exists(conn, club_id):
    cur = conn.cursor()
    cur.execute('SELECT 1 FROM clubs WHERE id = %s', (club_id,))
    exists = cur.fetchone() is not None
    cur.close()
    return exists


def get_club_leagues(conn, club_id):
    cur = conn.cursor()
    cur.execute('SELECT league_id, domestic_league_id FROM clubs WHERE id = %s', (club_id,))
    row = cur.fetchone()
    cur.close()
    if row is None:
        return None
    return {'league_id': row[0], 'domestic_league_id': row[1]}


def count_votes_for_club(conn, club_id):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(DISTINCT vote_id) FROM vote_clubs WHERE club_id = %s', (club_id,))
    count = cur.fetchone()[0]
    cur.close()
    return count


def reassign_club_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute('SELECT COUNT(DISTINCT vote_id) FROM vote_clubs WHERE club_id = %s', (source_id,))
        reassigned = cur.fetchone()[0]

        # Drop rows where the vote already has the target club under the same league (avoids
        # violating the (vote_id, club_id, league_id) primary key on the UPDATE below), same
        # delete-then-update dedup pattern as reassign_upcoming_party_votes.
        cur.execute(
            '''DELETE FROM vote_clubs vc1
               WHERE vc1.club_id = %s
                 AND EXISTS (
                     SELECT 1 FROM vote_clubs vc2
                     WHERE vc2.vote_id = vc1.vote_id AND vc2.club_id = %s
                       AND vc2.league_id = vc1.league_id
                 )''',
            (source_id, target_id)
        )
        cur.execute('UPDATE vote_clubs SET club_id = %s WHERE club_id = %s', (target_id, source_id))
        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
