def test_health(client):
    resp = client.get('/health')
    assert resp.status_code == 200
    assert resp.get_json() == {'status': 'ok'}


def test_options_endpoint(client):
    resp = client.get('/api/options')
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'leagues' in body
    assert any(l['name'] == 'EPL' for l in body['leagues'])


def test_vote_endpoint_sets_cookie_and_rejects_duplicate(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201
    assert 'voteball_token' in resp.headers.get('Set-Cookie', '')

    resp2 = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp2.status_code == 409


def test_vote_endpoint_invalid_previous_vote_status_returns_400(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'not_a_real_status', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 400
    body = resp.get_json()
    assert body == {'error': 'invalid vote data'}
    assert 'CheckViolation' not in str(body)
    assert 'psycopg2' not in str(body)


def test_results_by_club_endpoint(client, conn):
    import queries
    cur = conn.cursor()
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.close()

    resp = client.get(f'/api/results?by=club&id={club_id}')
    assert resp.status_code == 200
    assert resp.get_json() == {'previous': [], 'upcoming': []}


def test_sync_previous_parties_requires_admin_secret(client):
    resp = client.post('/api/admin/sync-previous-parties')
    assert resp.status_code == 401


def test_sync_previous_parties_with_valid_secret(client, monkeypatch):
    import knesset_sync

    def fake_fetch():
        return [{'knesset_faction_id': '1096', 'name': 'Likud'}]

    monkeypatch.setattr(knesset_sync, 'fetch_current_factions', fake_fetch)

    resp = client.post('/api/admin/sync-previous-parties', headers={'X-Admin-Secret': 'test-admin-secret'})
    assert resp.status_code == 200
    assert resp.get_json() == {'synced': 1}
