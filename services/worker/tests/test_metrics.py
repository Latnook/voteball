"""The worker's metric contract, and the staleness gauge that is the point of it.

The worker is notification-driven with a polling backstop. If LISTEN stops delivering and the poll
loop wedges, the site keeps serving stale rollups with every pod Ready and every existing alert
quiet. time() - last_success is the only signal that catches it.
"""
import os
import time
import urllib.request

# worker.py reads SNS_TOPIC at module scope, so it must be set BEFORE the import -- the same
# arrangement test_worker_loop.py already uses. conftest.py does not set it.
os.environ.setdefault('SNS_TOPIC', 'arn:aws:sns:il-central-1:000000000000:test-topic')

import metrics  # noqa: E402
import worker  # noqa: E402  (import after env setup, matches test_worker_loop.py)


def _reading(name, label=None):
    from prometheus_client import generate_latest, REGISTRY
    for line in generate_latest(REGISTRY).decode().splitlines():
        if not line.startswith(name):
            continue
        if label and label not in line:
            continue
        return float(line.rsplit(' ', 1)[1])
    return 0.0


def test_a_successful_iteration_is_counted_and_timestamped(conn, monkeypatch):
    monkeypatch.setattr(worker.rollups, 'recompute', lambda c: None)
    monkeypatch.setattr(worker.alerts, 'check_and_notify', lambda c, s, t: None)
    before = _reading('voteball_worker_recompute_total', 'result="success"')

    worker.run_iteration(sns=None, s3=None, snapshot_fingerprint=None)

    assert _reading('voteball_worker_recompute_total', 'result="success"') == before + 1
    assert _reading('voteball_worker_last_success_timestamp_seconds') > time.time() - 60


def test_a_failed_iteration_is_counted_and_does_not_raise(conn, monkeypatch):
    def explode(_conn):
        raise RuntimeError('database went away')

    monkeypatch.setattr(worker.rollups, 'recompute', explode)
    before = _reading('voteball_worker_recompute_total', 'result="failure"')

    worker.run_iteration(sns=None, s3=None, snapshot_fingerprint=None)   # must not raise

    assert _reading('voteball_worker_recompute_total', 'result="failure"') == before + 1


def test_a_failure_does_not_advance_the_freshness_gauge(conn, monkeypatch):
    # If a failed recompute bumped the timestamp, the staleness alert could never fire -- the exact
    # silent failure this gauge exists to catch.
    monkeypatch.setattr(worker.rollups, 'recompute', lambda c: None)
    monkeypatch.setattr(worker.alerts, 'check_and_notify', lambda c, s, t: None)
    worker.run_iteration(sns=None, s3=None, snapshot_fingerprint=None)
    good = _reading('voteball_worker_last_success_timestamp_seconds')

    def explode(_conn):
        raise RuntimeError('database went away')

    monkeypatch.setattr(worker.rollups, 'recompute', explode)
    worker.run_iteration(sns=None, s3=None, snapshot_fingerprint=None)

    assert _reading('voteball_worker_last_success_timestamp_seconds') == good


def test_duration_is_observed_for_every_iteration(conn, monkeypatch):
    monkeypatch.setattr(worker.rollups, 'recompute', lambda c: None)
    monkeypatch.setattr(worker.alerts, 'check_and_notify', lambda c, s, t: None)
    worker.run_iteration(sns=None, s3=None, snapshot_fingerprint=None)
    assert _reading('voteball_worker_recompute_duration_seconds_count') >= 1


def test_serve_exposes_the_metrics_over_http():
    metrics.serve(port=19100)
    body = urllib.request.urlopen('http://127.0.0.1:19100/metrics', timeout=5).read().decode()
    assert 'voteball_worker_recompute_total' in body
