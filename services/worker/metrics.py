"""Prometheus instrumentation for the worker.

Deliberately its own module rather than an import from services/backend: the two services are
separate Docker build contexts with no shared package, the same reason db.py is duplicated. The
shapes differ anyway -- the worker is a single process, so none of the backend's multiprocess
machinery applies here.

The gauge is the important one. This loop is notification-driven (LISTEN/NOTIFY) with a 30s polling
backstop; if notifications stop arriving AND the poll loop wedges, the site serves stale rollups
while every pod reports Ready and every existing alert stays quiet. `time() - last_success` is the
only signal that sees it.
"""
import os

from prometheus_client import Counter, Gauge, Histogram, start_http_server

# Scraped by a ServiceMonitor (charts/voteball, plan 2). Not reachable from outside the cluster: the
# devops-app namespace is default-deny and only the observability namespace is admitted to this port.
METRICS_PORT = int(os.environ.get('WORKER_METRICS_PORT', '9100'))

RECOMPUTES = Counter(
    'voteball_worker_recompute_total',
    'Rollup recompute cycles, by outcome.',
    ['result'],
)

RECOMPUTE_DURATION = Histogram(
    'voteball_worker_recompute_duration_seconds',
    'Wall-clock time for one recompute cycle.',
    # rollups.recompute() rebuilds every rollup table wholesale, so this grows with the vote count.
    # Buckets reach further than the backend's for that reason.
    buckets=(0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0),
)

LAST_SUCCESS = Gauge(
    'voteball_worker_last_success_timestamp_seconds',
    'Unix time of the last SUCCESSFUL recompute. Alert on age, not on value.',
)

NOTIFICATIONS = Counter(
    'voteball_worker_notifications_received_total',
    'Wake-ups caused by a NOTIFY rather than by the polling backstop.',
)


def serve(port=None):
    """Start the metrics HTTP server in a background thread.

    start_http_server spawns its own daemon thread, so this returns immediately and the caller's
    loop is unaffected. Returns the (httpd, thread) pair start_http_server itself returns, so a
    caller (or a test) can shut the server down instead of leaking a listening socket and a daemon
    thread for the rest of the process's life.
    """
    return start_http_server(port or METRICS_PORT)
