"""The metric contract: names, label cardinality, and the two multiprocess traps.

Three of these assert properties that are INVISIBLE when rendering in single-process mode, which is
how the test suite runs. They are asserted by introspection deliberately -- the alternative is
discovering them on a cluster, where the symptom is a metric that silently grows a new series on
every pod restart.
"""
import re

import metrics


def test_endpoint_label_uses_the_rule_not_the_concrete_path():
    class FakeRule:
        rule = '/api/admin/clubs/<int:club_id>'

    assert metrics.endpoint_label(FakeRule()) == '/api/admin/clubs/<int:club_id>'


def test_unmatched_requests_collapse_to_one_label():
    # A 404 flood must not be able to mint one series per bogus URL.
    assert metrics.endpoint_label(None) == 'unmatched'


def test_app_info_collapses_across_worker_processes():
    # multiprocess_mode='all' (the default) would export one series per worker PID, and PIDs change
    # on every restart -- unbounded cardinality in the metric meant to model good labelling.
    assert metrics.APP_INFO._multiprocess_mode == 'max'


def test_latency_histogram_has_a_bucket_on_the_slo_boundary():
    # The 1s latency SLO is read off this edge; without it the SLO is interpolated between 0.5 and 2.5.
    assert 1.0 in metrics.LATENCY._upper_bounds


def test_render_latest_exposes_every_declared_metric():
    payload, content_type = metrics.render_latest()
    text = payload.decode()
    for name in (
        'voteball_http_requests_total',
        'voteball_http_request_duration_seconds',
        'voteball_app_info',
        'voteball_votes_cast_total',
        'voteball_votes_rejected_total',
        'voteball_db_errors_total',
    ):
        assert name in text, f'{name} missing from /metrics output'
    assert content_type.startswith('text/plain')


def test_set_app_info_publishes_the_build_identity(monkeypatch):
    monkeypatch.setenv('APP_VERSION', 'abc1234')
    monkeypatch.setenv('APP_RELEASE', 'sha256:feedface')
    metrics.set_app_info()
    text = metrics.render_latest()[0].decode()
    assert 'abc1234' in text
    # All three labels, by name: a dashboard variable and every release-filtered panel key on
    # `release`, and a renamed or dropped label empties them silently rather than failing.
    for label in ('version="abc1234"', 'git_sha="abc1234"', 'release="sha256:feedface"'):
        assert label in text, f'{label} missing from voteball_app_info'


def test_release_falls_back_to_the_version_when_no_digest_is_pinned(monkeypatch):
    # A pod with no digest pinned is a supported state (a fresh fork, a rebuild against a new
    # registry), not an error. The fallback keeps `release` meaningful there instead of putting
    # 'unknown' -- or an empty string -- into every release-filtered panel.
    monkeypatch.setenv('APP_VERSION', 'abc1234')
    monkeypatch.delenv('APP_RELEASE', raising=False)
    metrics.set_app_info()
    text = metrics.render_latest()[0].decode()
    assert 'release="abc1234"' in text


def test_importing_metrics_survives_a_multiproc_dir_that_does_not_exist(tmp_path, monkeypatch):
    # The migration Job runs the SAME image as the backend. If a missing directory could fail this
    # import, a missing directory would fail every release.
    target = tmp_path / 'not-created-yet'
    monkeypatch.setenv('PROMETHEUS_MULTIPROC_DIR', str(target))
    metrics.ensure_multiproc_dir()
    assert target.is_dir()


def test_importing_metrics_survives_a_multiproc_dir_that_cannot_be_created(tmp_path, monkeypatch):
    # migrate-job.yaml runs readOnlyRootFilesystem: true with NO /tmp emptyDir (unlike backend,
    # worker and backup) and consumes app-config's PROMETHEUS_MULTIPROC_DIR via envFrom -- so a
    # read-only parent is the real production shape this guards, not a hypothetical. mkdir(parents=
    # True, exist_ok=True) raises PermissionError on it; ensure_multiproc_dir() must swallow that
    # instead of letting it escape, because this function runs at MODULE IMPORT time and an import
    # failure here would fail the schema-migration Job that gates every release.
    readonly_parent = tmp_path / 'readonly-parent'
    readonly_parent.mkdir(mode=0o555)
    target = readonly_parent / 'prom'
    monkeypatch.setenv('PROMETHEUS_MULTIPROC_DIR', str(target))
    try:
        metrics.ensure_multiproc_dir()   # must not raise
        assert not target.exists()
    finally:
        readonly_parent.chmod(0o755)


def _requests_total(text, endpoint, status):
    """Read one counter value out of the exposition text."""
    for line in text.splitlines():
        if line.startswith('voteball_http_requests_total{') and \
                f'endpoint="{endpoint}"' in line and f'status="{status}"' in line:
            return float(line.rsplit(' ', 1)[1])
    return 0.0


def test_metrics_endpoint_serves_prometheus_text(client):
    response = client.get('/metrics')
    assert response.status_code == 200
    assert 'voteball_http_requests_total' in response.get_data(as_text=True)


def test_a_request_is_counted_against_its_rule(client):
    before = _requests_total(client.get('/metrics').get_data(as_text=True), '/health', '200')
    client.get('/health')
    after = _requests_total(client.get('/metrics').get_data(as_text=True), '/health', '200')
    assert after == before + 1


def test_an_unmatched_request_is_counted_as_unmatched(client):
    before = _requests_total(client.get('/metrics').get_data(as_text=True), 'unmatched', '404')
    client.get('/no-such-path-exists')
    after = _requests_total(client.get('/metrics').get_data(as_text=True), 'unmatched', '404')
    assert after == before + 1


def test_scraping_metrics_does_not_count_itself(client):
    # Counting scrapes would inflate the request rate by a fixed background level that looks like
    # real traffic and never goes to zero.
    client.get('/metrics')
    text = client.get('/metrics').get_data(as_text=True)
    assert _requests_total(text, '/metrics', '200') == 0.0


def test_latency_is_observed_for_a_served_request(client):
    client.get('/health')
    text = client.get('/metrics').get_data(as_text=True)
    assert 'voteball_http_request_duration_seconds_bucket' in text
    assert 'endpoint="/health"' in text


def test_method_label_passes_valid_verbs_unchanged():
    for verb in ('GET', 'POST', 'PATCH', 'DELETE', 'PUT', 'HEAD', 'OPTIONS'):
        assert metrics.method_label(verb) == verb


def test_method_label_collapses_arbitrary_tokens_to_other():
    for token in ('FOOBAR', 'WHATEVER-123', 'ZZZ', 'invalid', 'custom'):
        assert metrics.method_label(token) == 'other'


def test_arbitrary_method_tokens_do_not_create_distinct_series(client):
    # An attacker sending different junk tokens should not mint new series. Every junk token
    # collapses to 'other', so two requests with two different junk verbs must land on the SAME
    # series -- i.e. every method="other" line seen must be labelled identically, regardless of how
    # many such lines exist across the session's shared registry (another test issuing some other
    # nonstandard-verb request is not a regression here).
    text_before = client.get('/metrics').get_data(as_text=True)
    other_lines_before = {
        line for line in text_before.splitlines()
        if 'voteball_http_requests_total{' in line and 'method="other"' in line
    }

    client.open('/no-such-path-exists', method='JUNKVERB1')
    client.open('/no-such-path-exists', method='JUNKVERB2')
    text = client.get('/metrics').get_data(as_text=True)

    other_method_lines = {
        line for line in text.splitlines()
        if 'voteball_http_requests_total{' in line and 'method="other"' in line
    }
    # Both junk-verb requests must have landed on a series that already existed (or on exactly one
    # new series shared by both) -- never one distinct series per junk token.
    new_lines = other_method_lines - other_lines_before
    assert len(new_lines) <= 1, \
        f'Expected junk tokens to collapse onto a single series, got {len(new_lines)} new series'

    # Verify neither junk token appears anywhere in the exposition
    assert 'JUNKVERB1' not in text, 'Junk token JUNKVERB1 appears in exposition'
    assert 'JUNKVERB2' not in text, 'Junk token JUNKVERB2 appears in exposition'


def test_metrics_response_header_is_well_formed(client):
    # render_latest() returns prometheus_client's CONTENT_TYPE_LATEST, which carries its own
    # charset. Passing it through Werkzeug's mimetype= parameter appends a second charset,
    # rendering the header unparseable by scrapers. This test asserts on the actual HTTP response
    # header, not on render_latest()'s return value -- the prior content-type assertion only checks
    # the function's output directly, which is exactly why the double-charset slipped through.
    response = client.get('/metrics')
    content_type = response.headers['Content-Type']
    # The header should contain charset=utf-8 exactly once.
    assert content_type.count('charset=utf-8') == 1, \
        f'Content-Type header has wrong charset count: {content_type}'


def _counter_value(text, name, label=None):
    for line in text.splitlines():
        if not line.startswith(name):
            continue
        if label and label not in line:
            continue
        return float(line.rsplit(' ', 1)[1])
    return 0.0


def test_a_recorded_ballot_increments_the_business_metric(client, conn):
    # Ballot shape copied from test_app.py's existing vote tests -- a pick is
    # {'league_id': ..., 'club_id': None}, meaning "this league, no specific club".
    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.close()

    before = _counter_value(client.get('/metrics').get_data(as_text=True), 'voteball_votes_cast_total')

    response = client.post('/api/vote', json={
        'team_picks': [{'league_id': league_id, 'club_id': None}],
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert response.status_code == 201

    after = _counter_value(client.get('/metrics').get_data(as_text=True), 'voteball_votes_cast_total')
    assert after == before + 1


def test_a_rejected_ballot_is_counted_with_its_reason(client, conn):
    text = client.get('/metrics').get_data(as_text=True)
    before = _counter_value(text, 'voteball_votes_rejected_total', 'reason="too-many-parties"')

    response = client.post('/api/vote', json={
        'team_picks': [],
        'upcoming_party_ids': [1, 2, 3, 4],
    })
    assert response.status_code == 400

    text = client.get('/metrics').get_data(as_text=True)
    after = _counter_value(text, 'voteball_votes_rejected_total', 'reason="too-many-parties"')
    assert after == before + 1


ALL_SIX_REJECTION_REASONS = frozenset({
    'considering-without-parties',
    'too-many-parties',
    'invalid-team-picks',
    'rate-limited',
    'duplicate',
    'invalid-data',
})


def _rejection_reasons_in_output(text):
    """Every distinct reason="..." value currently exposed on voteball_votes_rejected_total."""
    reasons = set()
    for line in text.splitlines():
        if not line.startswith('voteball_votes_rejected_total{'):
            continue
        match = re.search(r'reason="([^"]+)"', line)
        if match:
            reasons.add(match.group(1))
    return reasons


def test_every_rejection_reason_the_code_can_produce_is_one_of_the_six(client, conn):
    """Pins all SIX rejection literals, not just too-many-parties (the only one the test above
    covers). A typo in any of the other five would otherwise pass the suite silently -- exactly the
    kind of silent-success failure this whole instrumentation plan exists to prevent.

    Each of the six is triggered through the real /api/vote code path, one request per reason, so a
    renamed or dropped .labels(reason=...) call in app.py fails this test too -- this does not just
    read app.py and assert the literal is spelled right there, it proves the running code actually
    produces it. The output-side check then confirms nothing else escapes the closed set.
    """
    import app as app_module

    cur = conn.cursor()
    cur.execute("SELECT id FROM leagues WHERE name = 'EPL'")
    league_id = cur.fetchone()[0]
    cur.close()

    def rejected_count(reason):
        text = client.get('/metrics').get_data(as_text=True)
        return _counter_value(text, 'voteball_votes_rejected_total', f'reason="{reason}"')

    # 1. considering-without-parties
    before = rejected_count('considering-without-parties')
    r = client.post('/api/vote', json={
        'upcoming_vote_status': 'considering', 'upcoming_party_ids': [],
    })
    assert r.status_code == 400
    assert rejected_count('considering-without-parties') == before + 1

    # 2. too-many-parties
    before = rejected_count('too-many-parties')
    r = client.post('/api/vote', json={'upcoming_party_ids': [1, 2, 3, 4]})
    assert r.status_code == 400
    assert rejected_count('too-many-parties') == before + 1

    # 3. invalid-team-picks (team_picks must be a non-empty list)
    before = rejected_count('invalid-team-picks')
    r = client.post('/api/vote', json={'team_picks': []})
    assert r.status_code == 400
    assert rejected_count('invalid-team-picks') == before + 1

    # 4. rate-limited -- a dedicated address so it can't collide with the default-IP votes cast
    # elsewhere in this test.
    before = rejected_count('rate-limited')
    headers = {'X-Forwarded-For': '203.0.113.77, 10.0.0.1'}
    for _ in range(app_module.MAX_VOTES_PER_IP):
        client.set_cookie('voteball_token', '', expires=0)
        r = client.post('/api/vote', json={
            'team_picks': [{'league_id': league_id, 'club_id': None}],
            'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
            'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
        }, headers=headers)
        assert r.status_code == 201, r.status_code
    client.set_cookie('voteball_token', '', expires=0)
    r = client.post('/api/vote', json={
        'team_picks': [{'league_id': league_id, 'club_id': None}],
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    }, headers=headers)
    assert r.status_code == 429
    assert rejected_count('rate-limited') == before + 1

    # 5. duplicate -- same cookie, second ballot
    client.set_cookie('voteball_token', '', expires=0)
    before = rejected_count('duplicate')
    ballot = {
        'team_picks': [{'league_id': league_id, 'club_id': None}],
        'previous_vote_status': 'did_not_vote', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    }
    r1 = client.post('/api/vote', json=ballot)
    assert r1.status_code == 201
    r2 = client.post('/api/vote', json=ballot)
    assert r2.status_code == 409
    assert rejected_count('duplicate') == before + 1

    # 6. invalid-data -- a value that fails the DB CHECK constraint, not caught by _validate_team_picks
    client.set_cookie('voteball_token', '', expires=0)
    before = rejected_count('invalid-data')
    r = client.post('/api/vote', json={
        'team_picks': [{'league_id': league_id, 'club_id': None}],
        'previous_vote_status': 'not_a_real_status', 'previous_party_id': None,
        'upcoming_vote_status': 'undecided', 'upcoming_party_ids': [],
    })
    assert r.status_code == 400
    assert rejected_count('invalid-data') == before + 1

    # Closed-set check: nothing outside the six ever appears in the exposition.
    text = client.get('/metrics').get_data(as_text=True)
    seen = _rejection_reasons_in_output(text)
    assert seen <= ALL_SIX_REJECTION_REASONS, \
        f'unexpected reason label(s) not in the documented six: {seen - ALL_SIX_REJECTION_REASONS}'
    assert seen == ALL_SIX_REJECTION_REASONS, \
        f'not all six reasons were produced by this run: missing {ALL_SIX_REJECTION_REASONS - seen}'


def test_a_rejected_ballot_leaves_votes_cast_unchanged(client, conn):
    # Nothing currently catches a regression that moves VOTES_CAST.inc() somewhere it fires
    # unconditionally -- a rejected ballot must never be counted as cast.
    before = _counter_value(client.get('/metrics').get_data(as_text=True), 'voteball_votes_cast_total')

    response = client.post('/api/vote', json={
        'team_picks': [],
        'upcoming_party_ids': [1, 2, 3, 4],
    })
    assert response.status_code == 400

    after = _counter_value(client.get('/metrics').get_data(as_text=True), 'voteball_votes_cast_total')
    assert after == before


def test_an_unreachable_database_is_counted_as_a_dependency_failure(monkeypatch):
    # The 5xx drill of the design doc breaks exactly this path: the pod stays Ready, /health keeps
    # returning 200, and every request fails when it opens its connection.
    import db
    import psycopg2

    def explode(*args, **kwargs):
        raise psycopg2.OperationalError('could not connect to server')

    monkeypatch.setattr(psycopg2, 'connect', explode)
    before = _counter_value(metrics.render_latest()[0].decode(),
                            'voteball_db_errors_total', 'operation="connect"')
    try:
        db.get_db()
    except psycopg2.OperationalError:
        pass
    after = _counter_value(metrics.render_latest()[0].decode(),
                           'voteball_db_errors_total', 'operation="connect"')
    assert after == before + 1
