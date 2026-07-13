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


def test_vote_endpoint_considering_with_no_parties_returns_400(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 400
    assert resp.get_json() == {'error': 'select at least one upcoming party when status is considering'}


def test_vote_endpoint_considering_with_more_than_three_parties_returns_400(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM upcoming_parties ORDER BY id LIMIT 4")
    party_ids = [r[0] for r in cur.fetchall()]
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': party_ids,
    })
    assert resp.status_code == 400
    assert resp.get_json() == {'error': 'select at most 3 upcoming parties'}


def test_vote_endpoint_considering_with_parties_succeeds(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.execute("INSERT INTO upcoming_parties (name) VALUES ('Test Party') RETURNING id")
    party_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': [party_id],
    })
    assert resp.status_code == 201
    assert 'vote_id' in resp.get_json()


def test_results_by_club_endpoint(client, conn):
    import queries
    cur = conn.cursor()
    cur.execute("SELECT id FROM clubs WHERE name = 'Liverpool'")
    club_id = cur.fetchone()[0]
    cur.close()

    resp = client.get(f'/api/results?by=club&id={club_id}')
    assert resp.status_code == 200
    assert resp.get_json() == {'previous': [], 'upcoming': []}


def test_upcoming_party_admin_crud(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Test Party'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_id}', json={'name': 'Renamed'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 404


def test_admin_votes_list_requires_admin_secret(client):
    resp = client.get('/api/admin/votes')
    assert resp.status_code == 401


def test_admin_votes_list_returns_votes_with_valid_secret(client, conn):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201

    resp = client.get('/api/admin/votes', headers=headers)
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'votes' in body
    assert len(body['votes']) == 1
    assert body['votes'][0]['league_id'] == league_id
    assert 'cookie_token' not in body['votes'][0]


def test_admin_votes_delete_requires_admin_secret_and_handles_not_found(client, conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    vote_id = resp.get_json()['vote_id']

    resp = client.delete(f'/api/admin/votes/{vote_id}')
    assert resp.status_code == 401

    headers = {'X-Admin-Secret': 'test-admin-secret'}
    resp = client.delete(f'/api/admin/votes/{vote_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/votes/{vote_id}', headers=headers)
    assert resp.status_code == 404


def test_previous_party_admin_crud(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}

    resp = client.post('/api/admin/previous-parties', json={'name': 'Test Party'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_id}', json={'name': 'Renamed'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 404


def test_previous_party_admin_routes_require_admin_secret(client):
    resp = client.post('/api/admin/previous-parties', json={'name': 'X'})
    assert resp.status_code == 401

    resp = client.patch('/api/admin/previous-parties/1', json={'name': 'X'})
    assert resp.status_code == 401

    resp = client.delete('/api/admin/previous-parties/1')
    assert resp.status_code == 401


def test_create_upcoming_party_duplicate_name_returns_409(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}


def test_rename_upcoming_party_duplicate_name_returns_409(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Party One'}, headers=headers)
    party_two_target = resp.get_json()['id']
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_two_id}', json={'name': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}
    assert party_two_target > 0


def test_create_previous_party_duplicate_name_returns_409(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    resp = client.post('/api/admin/previous-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}


def test_rename_previous_party_duplicate_name_returns_409(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    resp = client.post('/api/admin/previous-parties', json={'name': 'Party One'}, headers=headers)
    party_one_id = resp.get_json()['id']
    resp = client.post('/api/admin/previous-parties', json={'name': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_two_id}', json={'name': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}
    assert party_one_id > 0


def test_delete_upcoming_party_blocked_when_referenced_by_votes(client, conn):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Referenced Party'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': [party_id],
    })
    assert resp.status_code == 201

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 vote(s) still reference this party'}


def test_delete_previous_party_blocked_when_referenced_by_votes(client, conn):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/previous-parties', json={'name': 'Referenced Previous Party'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'voted', 'previous_party_id': party_id,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 vote(s) still reference this party'}
