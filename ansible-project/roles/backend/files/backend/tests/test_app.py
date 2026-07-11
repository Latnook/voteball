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
