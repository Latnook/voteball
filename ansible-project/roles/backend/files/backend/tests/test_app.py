def test_health(client):
    resp = client.get('/health')
    assert resp.status_code == 200
    assert resp.get_json() == {'status': 'ok'}


def test_options_endpoint(client):
    resp = client.get('/api/options')
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'leagues' in body
    assert any(l['name_en'] == 'Premier League' for l in body['leagues'])
    assert any(l['name_he'] == 'הפרמייר ליג' for l in body['leagues'])


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

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Test Party', 'name_he': 'מפלגת בדיקה'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_id}', json={'name_en': 'Renamed', 'name_he': 'שם חדש'}, headers=headers)
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

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Test Party', 'name_he': 'מפלגת בדיקה'}, headers=headers)
    assert resp.status_code == 201
    party_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_id}', json={'name_en': 'Renamed', 'name_he': 'שם חדש'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/previous-parties/{party_id}', headers=headers)
    assert resp.status_code == 404


def test_previous_party_admin_routes_require_authentication(client):
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401

    resp = client.patch('/api/admin/previous-parties/1', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401

    resp = client.delete('/api/admin/previous-parties/1')
    assert resp.status_code == 401


def test_create_upcoming_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}


def test_create_upcoming_party_duplicate_hebrew_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'First EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Second EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}


def test_create_upcoming_party_duplicate_english_name_returns_409(client, admin_headers):
    # name_en collides while name_he differs, so only name_en_uidx fires (not the legacy `name`
    # constraint) - this is the only way to reach the English-specific message.
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Shared EN', 'name_he': 'עברית ראשונה'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Shared EN', 'name_he': 'עברית שנייה'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this English name already exists'}


def test_rename_upcoming_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    party_two_target = resp.get_json()['id']
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Party Two', 'name_he': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/upcoming-parties/{party_two_id}', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}
    assert party_two_target > 0


def test_create_previous_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Dup Party', 'name_he': 'Dup Party'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}


def test_create_previous_party_duplicate_hebrew_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'First EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Second EN', 'name_he': 'שם משותף'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}


def test_create_previous_party_duplicate_english_name_returns_409(client, admin_headers):
    # name_en collides while name_he differs, so only name_en_uidx fires (not the legacy `name`
    # constraint) - this is the only way to reach the English-specific message.
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Shared EN', 'name_he': 'עברית ראשונה'}, headers=headers)
    assert resp.status_code == 201

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Shared EN', 'name_he': 'עברית שנייה'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this English name already exists'}


def test_rename_previous_party_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    party_one_id = resp.get_json()['id']
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Party Two', 'name_he': 'Party Two'}, headers=headers)
    party_two_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/previous-parties/{party_two_id}', json={'name_en': 'Party One', 'name_he': 'Party One'}, headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': 'a party with this Hebrew name already exists'}
    assert party_one_id > 0


def test_delete_upcoming_party_blocked_when_referenced_by_votes(client, conn, admin_headers):
    headers = admin_headers
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Referenced Party', 'name_he': 'Referenced Party'}, headers=headers)
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

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Referenced Previous Party', 'name_he': 'Referenced Previous Party'}, headers=headers)
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

    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Source Party', 'name_he': 'Source Party'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Target Party', 'name_he': 'Target Party'}, headers=headers)
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
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Solo Party', 'name_he': 'Solo Party'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/previous-parties/{party_id}/reassign', json={'target_id': party_id}, headers=headers)
    assert resp.status_code == 400


def test_previous_party_reassign_rejects_nonexistent_target(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/previous-parties', json={'name_en': 'Solo Party 2', 'name_he': 'Solo Party 2'}, headers=headers)
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

    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Up Source', 'name_he': 'Up Source'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Up Target', 'name_he': 'Up Target'}, headers=headers)
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
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Up Solo', 'name_he': 'Up Solo'}, headers=headers)
    party_id = resp.get_json()['id']

    resp = client.post(f'/api/admin/upcoming-parties/{party_id}/reassign', json={'target_id': party_id}, headers=headers)
    assert resp.status_code == 400


def test_upcoming_party_reassign_rejects_nonexistent_target(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/upcoming-parties', json={'name_en': 'Up Solo 2', 'name_he': 'Up Solo 2'}, headers=headers)
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


def test_clubs_domestic_league_id_and_global_name_uniqueness(conn):
    import pytest
    import psycopg2
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'UCL'")
    ucl_id = cur.fetchone()[0]

    # A club can hold two distinct league slots.
    cur.execute(
        "INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he) "
        "VALUES (%s, %s, 'Test United', 'Test United', 'טסט יונייטד') RETURNING id",
        (ucl_id, epl_id)
    )
    conn.commit()

    # Global name uniqueness: the same name_en under a *different* league now collides
    # (this is the exact bug that let Arsenal exist twice before this migration).
    with pytest.raises(psycopg2.errors.UniqueViolation):
        cur.execute(
            "INSERT INTO clubs (league_id, name, name_en, name_he) "
            "VALUES (%s, 'Test United', 'Test United', 'אחר')",
            (epl_id,)
        )
    conn.rollback()

    # A club's two league slots can't be the same league.
    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute(
            "INSERT INTO clubs (league_id, domestic_league_id, name, name_en, name_he) "
            "VALUES (%s, %s, 'Same Slot FC', 'Same Slot FC', 'קבוצה')",
            (epl_id, epl_id)
        )
    conn.rollback()
    cur.close()


def test_seed_data_dedupes_ucl_clubs_with_domestic_leagues(conn):
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'UCL'")
    ucl_id = cur.fetchone()[0]
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    epl_id = cur.fetchone()[0]

    cur.execute("SELECT league_id, domestic_league_id FROM clubs WHERE name_en = 'Arsenal'")
    rows = cur.fetchall()
    assert len(rows) == 1, "Arsenal must be exactly one row after dedup"
    assert rows[0] == (ucl_id, epl_id)

    # PSG has no seeded domestic league and stays UCL-only.
    cur.execute("SELECT league_id, domestic_league_id FROM clubs WHERE name_en = 'Paris Saint-Germain'")
    rows = cur.fetchall()
    assert len(rows) == 1
    assert rows[0] == (ucl_id, None)
    cur.close()


def test_league_admin_crud(client, admin_headers):
    headers = admin_headers

    resp = client.post('/api/admin/leagues', json={'name_en': 'Test League', 'name_he': 'ליגת בדיקה'}, headers=headers)
    assert resp.status_code == 201
    league_id = resp.get_json()['id']

    resp = client.patch(f'/api/admin/leagues/{league_id}', json={'name_en': 'Renamed League', 'name_he': 'שם חדש'}, headers=headers)
    assert resp.status_code == 200

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 204

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 404


def test_league_admin_routes_require_authentication(client):
    resp = client.post('/api/admin/leagues', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401
    resp = client.patch('/api/admin/leagues/1', json={'name_en': 'X', 'name_he': 'א'})
    assert resp.status_code == 401
    resp = client.delete('/api/admin/leagues/1')
    assert resp.status_code == 401


def test_create_league_duplicate_name_returns_409(client, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'Dup League', 'name_he': 'Dup League'}, headers=headers)
    assert resp.status_code == 201
    resp = client.post('/api/admin/leagues', json={'name_en': 'Dup League', 'name_he': 'Dup League'}, headers=headers)
    assert resp.status_code == 409


def test_delete_league_blocked_when_clubs_reference_it(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'League With Club', 'name_he': 'ליגה עם קבוצה'}, headers=headers)
    league_id = resp.get_json()['id']
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en, name_he) VALUES (%s, 'Lone Club', 'Lone Club', 'קבוצה בודדה')",
        (league_id,)
    )
    conn.commit()
    cur.close()

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 club(s) still belong to this league'}


def test_delete_league_blocked_when_votes_reference_it(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'Voted League', 'name_he': 'ליגה עם הצבעה'}, headers=admin_headers)
    league_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': league_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert resp.status_code == 201

    resp = client.delete(f'/api/admin/leagues/{league_id}', headers=headers)
    assert resp.status_code == 409
    assert resp.get_json() == {'error': '1 vote(s) still reference this league'}


def test_league_reassign_moves_votes_and_requires_zero_clubs(client, conn, admin_headers):
    headers = admin_headers
    resp = client.post('/api/admin/leagues', json={'name_en': 'Source League', 'name_he': 'ליגת מקור'}, headers=headers)
    source_id = resp.get_json()['id']
    resp = client.post('/api/admin/leagues', json={'name_en': 'Target League', 'name_he': 'ליגת יעד'}, headers=headers)
    target_id = resp.get_json()['id']

    resp = client.post('/api/vote', json={
        'league_id': source_id, 'club_id': None,
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    vote_id = resp.get_json()['vote_id']

    resp = client.get(f'/api/admin/leagues/{source_id}/reassign-count?target_id={target_id}', headers=headers)
    assert resp.get_json() == {'count': 1}

    resp = client.post(f'/api/admin/leagues/{source_id}/reassign', json={'target_id': target_id}, headers=headers)
    assert resp.status_code == 200
    assert resp.get_json() == {'reassigned': 1}

    resp = client.get('/api/admin/votes', headers=headers)
    vote = next(v for v in resp.get_json()['votes'] if v['id'] == vote_id)
    assert vote['league_id'] == target_id

    # Now block reassign on a league that still has a club.
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en, name_he) VALUES (%s, 'Blocker Club', 'Blocker Club', 'קבוצה חוסמת')",
        (target_id,)
    )
    conn.commit()
    cur.close()
    resp = client.post('/api/admin/leagues', json={'name_en': 'Third League', 'name_he': 'ליגה שלישית'}, headers=headers)
    third_id = resp.get_json()['id']
    resp = client.post(f'/api/admin/leagues/{target_id}/reassign', json={'target_id': third_id}, headers=headers)
    assert resp.status_code == 400
