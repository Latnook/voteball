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


def test_upcoming_party_admin_crud(client, admin_headers):
    headers = admin_headers

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Test Party'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_id}', json={'name': 'Renamed'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/upcoming-parties/{party_id}', headers=headers)
    assert resp.status_code == 404


def test_admin_votes_list_requires_authentication(client):
    resp = client.get('/api/admin/votes')
    assert resp.status_code == 401


def test_admin_votes_list_returns_votes_with_valid_secret(client, conn, admin_headers):
    headers = admin_headers
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


def test_admin_votes_delete_requires_authentication_and_handles_not_found(client, conn, admin_headers):
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

    headers = admin_headers
    resp = client.delete(f'/api/admin/votes/{vote_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/votes/{vote_id}', headers=headers)
    assert resp.status_code == 404


def test_previous_party_admin_crud(client, admin_headers):
    headers = admin_headers

    resp = client.post('/api/admin/previous-parties', json={'name': 'Test Party'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_id}', json={'name': 'Renamed'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 404


def test_previous_party_admin_routes_require_authentication(client):
    resp = client.post('/api/admin/previous-parties', json={'name': 'X'})
    assert resp.status_code == 401

    resp = client.patch('/api/admin/previous-parties/1', json={'name': 'X'})
    assert resp.status_code == 401

    resp = client.delete('/api/admin/previous-parties/1')
    assert resp.status_code == 401


def test_create_upcoming_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}


def test_rename_upcoming_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Party One'}, headers=headers)
    party_two_target = resp.get_json()['id']
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_two_id}', json={'name': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}
    assert party_two_target > 0


def test_create_previous_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}


def test_rename_previous_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name': 'Party One'}, headers=headers)
    party_one_id = resp.get_json()['id']
    resp = client.post('/api/admin/previous-parties', json={'name': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_two_id}', json={'name': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this name already exists'}
    assert party_one_id > 0


def test_delete_upcoming_party_blocked_when_referenced_by_votes(client, conn, admin_headers):
    headers = admin_headers
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


def test_delete_previous_party_blocked_when_referenced_by_votes(client, conn, admin_headers):
    headers = admin_headers
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


def test_previous_party_reassign_moves_votes_and_updates_count(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/previous-parties', json={'name': 'Source Party'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/previous-parties', json={'name': 'Target Party'}, headers=headers)
    target_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'voted', 'previous_party_id': source_id,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    vote_id = resp.get_json()['vote_id']

    resp = client.get(f'/api/admin/previous-parties/{source_id}/reassign-count?target_id={target_id}', headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {'count': 1}

    resp = client.post(f'/api/admin/previous-parties/{source_id}/reassign', json={'target_id': target_id}, headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {'reassigned': 1}

    resp = client.get('/api/admin/votes', headers=headers)
    vote = next(v for v in resp.get_json()['votes'] if v['id'] == vote_id)
    assert vote['previous_party_id'] == target_id

    resp = client.get(f'/api/admin/previous-parties/{source_id}/reassign-count?target_id={target_id}', headers=headers)
    assert resp.get_json() == {'count': 0}


def test_previous_party_reassign_rejects_equal_source_and_target(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name': 'Solo Party'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/previous-parties/{party_id}/reassign', json={'target_id': party_id}, headers=headers)
    assert resp.status_code == 400


def test_previous_party_reassign_rejects_nonexistent_target(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name': 'Solo Party 2'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/previous-parties/{party_id}/reassign', json={'target_id': 999999}, headers=headers)
    assert resp.status_code == 404


def test_previous_party_reassign_requires_authentication(client):
    resp = client.get('/api/admin/previous-parties/1/reassign-count?target_id=2')
    assert resp.status_code == 401

    resp = client.post('/api/admin/previous-parties/1/reassign', json={'target_id': 2})
    assert resp.status_code == 401


def test_upcoming_party_reassign_moves_votes_and_updates_count(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Up Source'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Up Target'}, headers=headers)
    target_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': [source_id],
    })
    vote_id = resp.get_json()['vote_id']

    resp = client.get(f'/api/admin/upcoming-parties/{source_id}/reassign-count?target_id={target_id}', headers=headers)
    assert resp.get_json() == {'count': 1}

    resp = client.post(f'/api/admin/upcoming-parties/{source_id}/reassign', json={'target_id': target_id}, headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {'reassigned': 1}

    resp = client.get('/api/admin/votes', headers=headers)
    vote = next(v for v in resp.get_json()['votes'] if v['id'] == vote_id)
    assert vote['upcoming_party_ids'] == [target_id]


def test_upcoming_party_reassign_rejects_equal_source_and_target(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Up Solo'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/upcoming-parties/{party_id}/reassign', json={'target_id': party_id}, headers=headers)
    assert resp.status_code == 400


def test_upcoming_party_reassign_rejects_nonexistent_target(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name': 'Up Solo 2'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/upcoming-parties/{party_id}/reassign', json={'target_id': 999999}, headers=headers)
    assert resp.status_code == 404


def test_upcoming_party_reassign_requires_authentication(client):
    resp = client.get('/api/admin/upcoming-parties/1/reassign-count?target_id=2')
    assert resp.status_code == 401

    resp = client.post('/api/admin/upcoming-parties/1/reassign', json={'target_id': 2})
    assert resp.status_code == 401


def test_admin_login_succeeds_with_correct_credentials(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin', 'password': 'test-admin-password'})
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'token' in body
    assert isinstance(body['token'], str)
    assert len(body['token']) > 0


def test_admin_login_rejects_wrong_password(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin', 'password': 'wrong'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_admin_login_rejects_wrong_username(client):
    resp = client.post('/api/admin/login', json={'username': 'nobody', 'password': 'test-admin-password'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_admin_login_rejects_missing_username(client):
    resp = client.post('/api/admin/login', json={'password': 'test-admin-password'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_admin_login_rejects_missing_password(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_require_admin_rejects_missing_authorization_header(client):
    resp = client.get('/api/admin/votes')
    assert resp.status_code == 401


def test_require_admin_rejects_non_bearer_header(client):
    resp = client.get('/api/admin/votes', headers={'Authorization': 'Basic dGVzdA=='})
    assert resp.status_code == 401


def test_require_admin_rejects_token_with_bad_signature(client):
    resp = client.get('/api/admin/votes', headers={'Authorization': 'Bearer not-a-real-token'})
    assert resp.status_code == 401


def test_require_admin_rejects_expired_token(client):
    import app as app_module
    from unittest.mock import patch
    import time as time_module

    with patch.object(time_module, 'time', return_value=time_module.time() - 100000):
        old_token = app_module._admin_token_serializer.dumps(app_module.ADMIN_USERNAME)

    resp = client.get('/api/admin/votes', headers={'Authorization': f'Bearer {old_token}'})
    assert resp.status_code == 401
