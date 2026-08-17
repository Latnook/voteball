"""Prometheus instrumentation for the backend.

Two things here are not obvious and both cost real debugging time if changed:

MULTIPROCESS MODE. gunicorn runs 2 workers per pod (gunicorn.conf.py), each a separate process with
its own counters. A scrape is served by whichever worker accepts the connection, so without
multiprocess mode /metrics reports roughly HALF the real traffic and the number wobbles between
scrapes -- wrong in a plausible way, which is the worst kind. In multiprocess mode workers write
counter files into PROMETHEUS_MULTIPROC_DIR and /metrics sums them.

CARDINALITY. Every label here has a bounded value set. `endpoint` is Flask's URL RULE, not the
request path: /api/admin/clubs/<int:club_id> is one series where /api/admin/clubs/42 would be one
series per club. Requests matching no rule collapse to 'unmatched' so a 404 flood cannot mint series
either. Never add a label carrying a user id, a request id, or a raw URL.
"""
import os
import pathlib

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    multiprocess,
)


def ensure_multiproc_dir():
    """Create PROMETHEUS_MULTIPROC_DIR if it is set but missing, before any metric is defined.

    In multiprocess mode prometheus_client writes a file per process at metric CREATION time, so a
    missing directory raises during import -- and this module is imported by app.py, which is also
    what migrate.py's image runs. A missing directory must therefore never be able to fail an
    import, or it would fail the schema-migration Job that gates every release.

    Wiping stale files is deliberately NOT done here; that belongs to the gunicorn master before it
    forks (see gunicorn.conf.py). This function only guarantees the directory exists.
    """
    path = os.environ.get('PROMETHEUS_MULTIPROC_DIR')
    if path:
        pathlib.Path(path).mkdir(parents=True, exist_ok=True)


ensure_multiproc_dir()


REQUESTS = Counter(
    'voteball_http_requests_total',
    'HTTP requests handled by the backend.',
    ['method', 'endpoint', 'status'],
)

LATENCY = Histogram(
    'voteball_http_request_duration_seconds',
    'Wall-clock time to produce a response.',
    ['method', 'endpoint'],
    # 1.0 is the latency SLO boundary and must stay a real bucket edge, or histogram_quantile
    # interpolates the SLO between 0.5 and 2.5 and reports a number nothing measured.
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

APP_INFO = Gauge(
    'voteball_app_info',
    'Build identity of the running backend. Always 1; the labels carry the information.',
    ['version', 'git_sha'],
    # 'max' collapses all workers to one series. The default 'all' would label each series with the
    # worker's PID, and PIDs change on every restart. Info/Enum are unsupported in multiprocess mode,
    # so this Gauge is the only available shape -- do not convert it.
    multiprocess_mode='max',
)

VOTES_CAST = Counter(
    'voteball_votes_cast_total',
    'Ballots successfully recorded. The business metric: the action this site exists for.',
)

VOTES_REJECTED = Counter(
    'voteball_votes_rejected_total',
    'Ballots refused, by validation reason.',
    ['reason'],
)

DB_ERRORS = Counter(
    'voteball_db_errors_total',
    'Database operations that raised, by operation.',
    ['operation'],
)


def endpoint_label(url_rule):
    """The bounded form of "which endpoint was this". See the cardinality note above."""
    return url_rule.rule if url_rule is not None else 'unmatched'


def method_label(method):
    """The bounded form of "which HTTP verb was this". See the cardinality note above.

    request.method is whatever verb the client wrote on the request line, gunicorn accepts arbitrary
    tokens, and nginx proxies anything under /api/* regardless of verb -- so the verb is
    attacker-controlled and unbounded without this guard. Any method outside the seven verbs this app
    can actually serve collapses to 'other'.
    """
    valid_methods = {'GET', 'POST', 'PATCH', 'DELETE', 'PUT', 'HEAD', 'OPTIONS'}
    return method if method in valid_methods else 'other'


def set_app_info():
    """Publish the running build's identity.

    APP_VERSION is the image tag, which this project sets to the short git SHA
    (scripts/sync-values-from-tf.sh and Jenkinsfile-cd's promote step both write it), so version and
    git_sha carry the same value by construction. Both labels exist because the brief asks for both
    and a future release scheme may separate them.
    """
    version = os.environ.get('APP_VERSION', 'unknown')
    APP_INFO.labels(version=version, git_sha=version).set(1)


def render_latest():
    """Return (payload, content_type) for the /metrics response.

    Reads the environment on every call rather than at import so tests can exercise both modes.
    """
    if os.environ.get('PROMETHEUS_MULTIPROC_DIR'):
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
    else:
        registry = REGISTRY
    return generate_latest(registry), CONTENT_TYPE_LATEST
