import psycopg2


def get_options(conn):
    cur = conn.cursor()

    cur.execute('SELECT id, name FROM leagues ORDER BY name')
    leagues = [{'id': r[0], 'name': r[1]} for r in cur.fetchall()]

    cur.execute('SELECT id, league_id, name FROM clubs ORDER BY name')
    clubs = [{'id': r[0], 'league_id': r[1], 'name': r[2]} for r in cur.fetchall()]

    cur.execute('SELECT id, name FROM previous_parties ORDER BY name')
    previous_parties = [{'id': r[0], 'name': r[1]} for r in cur.fetchall()]

    cur.execute('SELECT id, name FROM upcoming_parties ORDER BY name')
    upcoming_parties = [{'id': r[0], 'name': r[1]} for r in cur.fetchall()]

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

    cur = conn.cursor()
    cur.execute(
        f'SELECT league_id, club_id, SUM(vote_count) FROM {table} '
        f'WHERE {column} = %s GROUP BY league_id, club_id',
        (party_id,)
    )
    breakdown = [{'league_id': r[0], 'club_id': r[1], 'count': r[2]} for r in cur.fetchall()]
    cur.close()
    return {'breakdown': breakdown}


def upsert_previous_parties(conn, factions):
    cur = conn.cursor()
    count = 0
    for faction in factions:
        cur.execute(
            '''INSERT INTO previous_parties (name, knesset_faction_id, updated_at)
               VALUES (%s, %s, NOW())
               ON CONFLICT (name) DO UPDATE SET
                   knesset_faction_id = EXCLUDED.knesset_faction_id,
                   updated_at = NOW()''',
            (faction['name'], faction['knesset_faction_id'])
        )
        count += 1
    conn.commit()
    cur.close()
    return count


def create_upcoming_party(conn, name):
    cur = conn.cursor()
    cur.execute('INSERT INTO upcoming_parties (name) VALUES (%s) RETURNING id', (name,))
    party_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    return party_id


def rename_upcoming_party(conn, party_id, new_name):
    cur = conn.cursor()
    cur.execute('UPDATE upcoming_parties SET name = %s, updated_at = NOW() WHERE id = %s', (new_name, party_id))
    updated = cur.rowcount > 0
    conn.commit()
    cur.close()
    return updated


def delete_upcoming_party(conn, party_id):
    cur = conn.cursor()
    cur.execute('DELETE FROM upcoming_parties WHERE id = %s', (party_id,))
    deleted = cur.rowcount > 0
    conn.commit()
    cur.close()
    return deleted
