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

    cur.execute('SELECT id, name_en, name_he FROM leagues ORDER BY name_en')
    leagues = [{'id': r[0], 'name_en': r[1], 'name_he': r[2]} for r in cur.fetchall()]

    cur.execute('SELECT id, league_id, domestic_league_id, name_en, name_he FROM clubs ORDER BY name_en')
    clubs = [
        {'id': r[0], 'league_id': r[1], 'domestic_league_id': r[2], 'name_en': r[3], 'name_he': r[4]}
        for r in cur.fetchall()
    ]

    cur.execute('SELECT id, name_en, name_he FROM previous_parties ORDER BY name_en')
    previous_parties = [{'id': r[0], 'name_en': r[1], 'name_he': r[2]} for r in cur.fetchall()]

    cur.execute('SELECT id, name_en, name_he FROM upcoming_parties ORDER BY name_en')
    upcoming_parties = [{'id': r[0], 'name_en': r[1], 'name_he': r[2]} for r in cur.fetchall()]

    cur.close()
    return {
        'leagues': leagues,
        'clubs': clubs,
        'previous_parties': previous_parties,
        'upcoming_parties': upcoming_parties,
    }


def insert_vote(conn, league_id, club_id, previous_vote_status, previous_party_id,
                 upcoming_vote_status, upcoming_party_ids, cookie_token):
    cur = conn.cursor()
    try:
        cur.execute(
            '''INSERT INTO votes
               (league_id, club_id, previous_vote_status, previous_party_id,
                upcoming_vote_status, cookie_token)
               VALUES (%s, %s, %s, %s, %s, %s) RETURNING id''',
            (league_id, club_id, previous_vote_status, previous_party_id,
             upcoming_vote_status, cookie_token)
        )
        vote_id = cur.fetchone()[0]

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
    return _results_for_filter(conn, 'league_id = %s', (league_id,))


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

    cur.execute(
        f'SELECT {other_column}, SUM(vote_count) FROM rollup_previous_upcoming '
        f'WHERE {column} = %s GROUP BY {other_column}',
        (party_id,)
    )
    crosstab = [{other_column: r[0], 'count': r[1]} for r in cur.fetchall()]

    cur.close()
    return {'breakdown': breakdown, 'crosstab': crosstab}


def create_upcoming_party(conn, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO upcoming_parties (name, name_en, name_he) VALUES (%s, %s, %s) RETURNING id',
            (name_he, name_en, name_he)
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


def rename_upcoming_party(conn, party_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE upcoming_parties SET name = %s, name_en = %s, name_he = %s, updated_at = NOW() WHERE id = %s',
            (name_he, name_en, name_he, party_id)
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


def create_previous_party(conn, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO previous_parties (name, name_en, name_he) VALUES (%s, %s, %s) RETURNING id',
            (name_he, name_en, name_he)
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


def rename_previous_party(conn, party_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE previous_parties SET name = %s, name_en = %s, name_he = %s, updated_at = NOW() WHERE id = %s',
            (name_he, name_en, name_he, party_id)
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
    cur = conn.cursor()
    cur.execute(
        '''SELECT v.id, v.league_id, v.club_id, v.previous_vote_status,
                  v.previous_party_id, v.upcoming_vote_status, v.created_at,
                  COALESCE(
                      array_agg(vup.upcoming_party_id) FILTER (WHERE vup.upcoming_party_id IS NOT NULL),
                      ARRAY[]::INTEGER[]
                  ) AS upcoming_party_ids
           FROM votes v
           LEFT JOIN vote_upcoming_parties vup ON vup.vote_id = v.id
           GROUP BY v.id
           ORDER BY v.id'''
    )
    votes = [
        {
            'id': r[0],
            'league_id': r[1],
            'club_id': r[2],
            'previous_vote_status': r[3],
            'previous_party_id': r[4],
            'upcoming_vote_status': r[5],
            'created_at': r[6].isoformat(),
            'upcoming_party_ids': list(r[7]),
        }
        for r in cur.fetchall()
    ]
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


def create_league(conn, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO leagues (name, name_en, name_he) VALUES (%s, %s, %s) RETURNING id',
            (name_he, name_en, name_he)
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


def rename_league(conn, league_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE leagues SET name = %s, name_en = %s, name_he = %s WHERE id = %s',
            (name_he, name_en, name_he, league_id)
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


def count_votes_for_league(conn, league_id):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes WHERE league_id = %s', (league_id,))
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
            'UPDATE votes SET league_id = %s WHERE league_id = %s',
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


class DuplicateClubNameError(Exception):
    def __init__(self, language):
        self.language = language
        super().__init__(f'a club with this {language} name already exists')


def create_club(conn, league_id, domestic_league_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he) '
            'VALUES (%s, %s, %s, %s, %s) RETURNING id',
            (league_id, domestic_league_id, name_he, name_en, name_he)
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


def rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he):
    cur = conn.cursor()
    try:
        cur.execute(
            'UPDATE clubs SET league_id = %s, domestic_league_id = %s, name = %s, name_en = %s, name_he = %s '
            'WHERE id = %s',
            (league_id, domestic_league_id, name_he, name_en, name_he, club_id)
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
    cur.execute('SELECT COUNT(*) FROM votes WHERE club_id = %s', (club_id,))
    count = cur.fetchone()[0]
    cur.close()
    return count


def reassign_club_votes(conn, source_id, target_id):
    cur = conn.cursor()
    try:
        cur.execute('UPDATE votes SET club_id = %s WHERE club_id = %s', (target_id, source_id))
        reassigned = cur.rowcount
        conn.commit()
        return reassigned
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
