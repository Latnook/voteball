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
