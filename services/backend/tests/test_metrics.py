"""The metric contract: names, label cardinality, and the two multiprocess traps.

Three of these assert properties that are INVISIBLE when rendering in single-process mode, which is
how the test suite runs. They are asserted by introspection deliberately -- the alternative is
discovering them on a cluster, where the symptom is a metric that silently grows a new series on
every pod restart.
"""
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
    metrics.set_app_info()
    text = metrics.render_latest()[0].decode()
    assert 'abc1234' in text


def test_importing_metrics_survives_a_multiproc_dir_that_does_not_exist(tmp_path, monkeypatch):
    # The migration Job runs the SAME image as the backend. If a missing directory could fail this
    # import, a missing directory would fail every release.
    target = tmp_path / 'not-created-yet'
    monkeypatch.setenv('PROMETHEUS_MULTIPROC_DIR', str(target))
    metrics.ensure_multiproc_dir()
    assert target.is_dir()
