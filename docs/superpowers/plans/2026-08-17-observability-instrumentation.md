# Application Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the backend and worker expose Prometheus metrics — request rate, latency, build
identity, votes cast, and rollup freshness — so the observability stack has application signals to
scrape.

**Architecture:** Each service gets one new `metrics.py` module holding every metric definition, plus
small call sites in existing code. The backend runs 2 gunicorn workers per pod, so it uses
`prometheus_client`'s multiprocess mode with a shared directory under the existing `/tmp` emptyDir.
The worker is single-process and runs a plain metrics HTTP server on port 9100. No Kubernetes changes
are in this plan — chart wiring, ServiceMonitors and NetworkPolicies come in plan 2.

**Tech Stack:** Python 3.12, Flask 3.1, gunicorn 23, `prometheus_client`, pytest against a real
Postgres container.

**Spec:** `docs/design/2026-08-17-observability-design.md` (sections 4 and 5)

## Global Constraints

- **Metric naming:** every metric is prefixed `voteball_`, counters end `_total`, durations end
  `_seconds`. Copied verbatim from spec §4 and §5 tables — do not rename.
- **`endpoint` label is Flask's URL *rule*, never the request path.** `/api/admin/clubs/<int:club_id>`
  is one series; `/api/admin/clubs/42` would be one per club. Requests matching no rule are labelled
  `unmatched`.
- **`voteball_app_info` must be a `Gauge` with `multiprocess_mode='max'`.** The default (`'all'`)
  exports one series per worker PID, and PIDs change on every restart. `Info` is unsupported in
  multiprocess mode entirely — do not "improve" the Gauge into one.
- **Histogram buckets:** `(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)` seconds. The `1.0` boundary is the
  latency SLO, so it must stay a real bucket edge.
- **Adding any source file requires updating that service's `Dockerfile` `COPY` line.** A file on disk
  but missing from `COPY` is absent from the image with no build error.
- **`requirements.txt` is production-only; `requirements-dev.txt` adds pytest.** `tests/test_requirements.py`
  fails if a declared package is never imported or an imported package is undeclared.
- **Both services are separate Docker build contexts with no shared package.** The worker deliberately
  duplicates rather than imports from the backend. Do not introduce a shared module.
- Every backend route must still guarantee `conn.close()` on all exit paths.
- Commit after each task. Never force-push. No `Claude-Session:` trailer in any commit message.

---

### Task 1: Backend metrics module

**Files:**
- Create: `services/backend/metrics.py`
- Create: `services/backend/tests/test_metrics.py`
- Modify: `services/backend/requirements.txt`
- Modify: `services/backend/Dockerfile` (the `COPY` line)

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `metrics.REQUESTS`, `metrics.LATENCY`, `metrics.APP_INFO`, `metrics.VOTES_CAST`,
  `metrics.VOTES_REJECTED`, `metrics.DB_ERRORS` (prometheus_client collectors);
  `metrics.endpoint_label(url_rule) -> str`; `metrics.set_app_info() -> None`;
  `metrics.render_latest() -> tuple[bytes, str]`

- [ ] **Step 1: Pin the dependency at its current version**

Do not guess the version — resolve it:

```bash
cd services/backend
source .venv/bin/activate     # create with `python -m venv .venv` if absent
pip install prometheus-client
pip show prometheus-client | grep ^Version
```

Add the resolved version to `services/backend/requirements.txt`, after `itsdangerous==2.2.0`:

```
# Metrics exposition for /metrics. Multiprocess mode is mandatory here -- gunicorn runs 2 workers
# per pod and each is a separate process with its own counters; see metrics.py.
prometheus-client==<the version pip reported>
```

Then install the dev requirements so the suite can run: `pip install -r requirements-dev.txt`

- [ ] **Step 2: Write the failing test**

Create `services/backend/tests/test_metrics.py`:

```python
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd services/backend && python -m pytest tests/test_metrics.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'metrics'`

- [ ] **Step 4: Write the implementation**

Create `services/backend/metrics.py`:

```python
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd services/backend && python -m pytest tests/test_metrics.py -v`
Expected: PASS, 7 tests

- [ ] **Step 6: Add the file to the image**

Modify `services/backend/Dockerfile`, adding `metrics.py` to the existing `COPY` line:

```dockerfile
COPY app.py db.py metrics.py queries.py gunicorn.conf.py migrate.py schema.sql seed.sql ./
```

- [ ] **Step 7: Verify the requirements contract still holds**

Run: `cd services/backend && python -m pytest tests/test_requirements.py -v`
Expected: PASS. If it fails with "declared but never imported", that is correct — `prometheus-client`
is imported by `metrics.py`, so confirm `metrics.py` was actually created in `services/backend/` and
not elsewhere.

- [ ] **Step 8: Commit**

```bash
git add services/backend/metrics.py services/backend/tests/test_metrics.py \
        services/backend/requirements.txt services/backend/Dockerfile
git commit -m "feat(backend): declare the application metrics

Every label here is bounded by construction: endpoint is Flask's URL rule
rather than the request path, and unmatched requests collapse to one
series so a 404 flood cannot mint them.

app_info is a Gauge with multiprocess_mode='max' because the default
exports one series per gunicorn worker PID, and PIDs change on every
restart -- unbounded cardinality in the metric meant to demonstrate the
opposite. Info is unsupported in multiprocess mode, so the Gauge is
load-bearing rather than stylistic.

ensure_multiproc_dir() runs before any metric is defined: the migration
Job runs this same image, and a missing directory raises at metric
creation, which would fail every release."
git push origin master
```

---

### Task 2: Request hooks and the `/metrics` endpoint

**Files:**
- Modify: `services/backend/app.py` (imports, two hooks, one route)
- Modify: `services/backend/tests/test_metrics.py` (append)

**Interfaces:**
- Consumes: `metrics.REQUESTS`, `metrics.LATENCY`, `metrics.endpoint_label`, `metrics.render_latest`,
  `metrics.set_app_info` from Task 1
- Produces: `GET /metrics` returning Prometheus text exposition; every response counted

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_metrics.py`:

```python
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd services/backend && python -m pytest tests/test_metrics.py -v -k "endpoint or counted or scraping or latency"`
Expected: FAIL — `/metrics` returns 404

- [ ] **Step 3: Write the implementation**

In `services/backend/app.py`, add to the imports at the top (after `import queries`):

```python
import time
import metrics
```

and add `Response` to the existing Flask import line:

```python
from flask import Flask, jsonify, request, make_response, Response
```

Immediately after `app = Flask(__name__)` and its existing configuration block, add:

```python
# Publish the running build's identity once per worker process. With multiprocess_mode='max' the
# workers collapse to a single series -- see metrics.py.
metrics.set_app_info()


@app.before_request
def _metrics_start_timer():
    request.environ['voteball.start'] = time.perf_counter()


@app.after_request
def _metrics_record(response):
    """Count every response and observe its latency.

    Runs for error responses too, including the 500 Flask synthesises from an unhandled exception --
    which is exactly the case this instrumentation exists for, since /health is static and the
    liveness probe is a bare TCP check, so a backend that 500s on every API call still looks Ready.

    /metrics itself is excluded: counting scrapes adds a fixed background request rate that never
    falls to zero and is indistinguishable from real traffic.
    """
    if request.path == '/metrics':
        return response
    endpoint = metrics.endpoint_label(request.url_rule)
    started = request.environ.get('voteball.start')
    if started is not None:
        metrics.LATENCY.labels(request.method, endpoint).observe(time.perf_counter() - started)
    metrics.REQUESTS.labels(request.method, endpoint, str(response.status_code)).inc()
    return response


@app.route('/metrics', methods=['GET'])
def prometheus_metrics():
    """Scrape target. NOT reachable from the internet: nginx proxies only /api/*, so this path has no
    public route, and in-cluster only the observability namespace is admitted to port 5000 (see the
    NetworkPolicy in charts/voteball). Deliberately separate from /health, which the probes use."""
    payload, content_type = metrics.render_latest()
    return Response(payload, mimetype=content_type)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd services/backend && python -m pytest tests/test_metrics.py -v`
Expected: PASS, 12 tests

- [ ] **Step 5: Run the whole backend suite for regressions**

Run: `cd services/backend && python -m pytest tests/ -q`
(Requires the Postgres container: `docker start voteball-test-db` — see `services/backend/CLAUDE.md`.)
Expected: all tests pass. The suite was 250 tests before this plan; expect 262.

- [ ] **Step 6: Commit**

```bash
git add services/backend/app.py services/backend/tests/test_metrics.py
git commit -m "feat(backend): count and time every request, serve /metrics

after_request runs for error responses too, which is the case this exists
for: /health is a static response and liveness is a bare TCP check, so a
backend that 500s on every API call reports Ready and no existing alert
fires.

/metrics excludes itself from the counters -- counting scrapes adds a
constant background request rate that never falls to zero and reads as
real traffic."
git push origin master
```

---

### Task 3: Gunicorn multiprocess plumbing

**Files:**
- Modify: `services/backend/gunicorn.conf.py`
- Create: `services/backend/tests/test_gunicorn_conf.py`

**Interfaces:**
- Consumes: nothing from earlier tasks at runtime (deliberately does not import `metrics`)
- Produces: a wiped, existing `PROMETHEUS_MULTIPROC_DIR` before workers fork; dead workers' counter
  files reaped

- [ ] **Step 1: Write the failing test**

Create `services/backend/tests/test_gunicorn_conf.py`:

```python
"""gunicorn.conf.py's metrics plumbing.

Loaded by path because the filename contains a dot ('gunicorn.conf'), which is not a legal module
name -- gunicorn itself loads it the same way.
"""
import importlib.util
import pathlib

CONF = pathlib.Path(__file__).resolve().parent.parent / 'gunicorn.conf.py'


def _load():
    spec = importlib.util.spec_from_file_location('gunicorn_conf_under_test', CONF)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_multiproc_dir_starts_empty(tmp_path, monkeypatch):
    # An emptyDir survives a container restart within the same pod, so counter files from the
    # previous process can linger and would be summed into the new one's totals.
    stale = tmp_path / 'prom'
    stale.mkdir()
    (stale / 'counter_999.db').write_bytes(b'stale')
    monkeypatch.setenv('PROMETHEUS_MULTIPROC_DIR', str(stale))

    _load()._reset_multiproc_dir()

    assert stale.is_dir()
    assert list(stale.iterdir()) == []


def test_multiproc_dir_is_created_when_absent(tmp_path, monkeypatch):
    target = tmp_path / 'prom'
    monkeypatch.setenv('PROMETHEUS_MULTIPROC_DIR', str(target))
    _load()._reset_multiproc_dir()
    assert target.is_dir()


def test_no_multiproc_dir_configured_is_a_no_op(monkeypatch):
    monkeypatch.delenv('PROMETHEUS_MULTIPROC_DIR', raising=False)
    _load()._reset_multiproc_dir()   # must not raise


def test_child_exit_reaps_the_dead_workers_counters(monkeypatch):
    # Without this, a departed worker's counters are summed forever and the traffic of a process
    # that no longer exists reads as live.
    reaped = []
    module = _load()
    monkeypatch.setattr(module, '_mark_process_dead', reaped.append)

    class FakeWorker:
        pid = 4242

    module.child_exit(server=None, worker=FakeWorker())
    assert reaped == [4242]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd services/backend && python -m pytest tests/test_gunicorn_conf.py -v`
Expected: FAIL — `module has no attribute '_reset_multiproc_dir'`

- [ ] **Step 3: Write the implementation**

Replace the contents of `services/backend/gunicorn.conf.py` with:

```python
import os
import pathlib
import shutil

# Production WSGI server config. Werkzeug's app.run() (still used for local dev in app.py's
# __main__) is single-threaded and explicitly not for production; gunicorn replaces it here.
bind = '0.0.0.0:5000'
workers = int(os.environ.get('GUNICORN_WORKERS', '2'))


def _reset_multiproc_dir():
    """Give the metrics multiprocess directory a clean, existing home before any worker forks.

    Deliberately implemented with os/shutil rather than by importing metrics.py: in multiprocess
    mode prometheus_client writes a file per process the moment a metric is DEFINED, so importing
    metrics.py before the directory exists is exactly the failure this function prevents.

    The wipe matters because an emptyDir survives a container restart within the same pod -- counter
    files written by the previous process would otherwise be summed into the new one's totals.
    """
    path = os.environ.get('PROMETHEUS_MULTIPROC_DIR')
    if not path:
        return
    directory = pathlib.Path(path)
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)


def _mark_process_dead(pid):
    """Indirection so the reaping can be asserted without a real prometheus_client registry."""
    from prometheus_client import multiprocess
    multiprocess.mark_process_dead(pid)


def on_starting(server):
    """Bootstrap the schema once per pod, in the master before workers fork.

    Under app.run() this lived in app.py's __main__ block; gunicorn imports app:app instead, so
    __main__ never runs and the bootstrap has to move here. Running it in on_starting (not per
    worker) keeps it to one invocation per pod -- the same concurrency the 2-replica Deployment
    already produced under the old dev-server entrypoint, and schema.sql/seed.sql are idempotent.

    The metrics directory is reset FIRST and before any application import, for the reason in
    _reset_multiproc_dir's docstring.
    """
    _reset_multiproc_dir()
    import db
    conn = db.get_db()
    try:
        db.init_db(conn)
    finally:
        conn.close()


def child_exit(server, worker):
    """Reap a departed worker's counter files.

    Without this, prometheus_client keeps summing the files of processes that no longer exist, so
    the traffic of a worker that died an hour ago is still reported as current.
    """
    _mark_process_dead(worker.pid)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd services/backend && python -m pytest tests/test_gunicorn_conf.py -v`
Expected: PASS, 4 tests

- [ ] **Step 5: Prove multiprocess aggregation actually sums across processes**

This is the property the whole task exists for, and none of the tests above prove it. Run it by hand:

```bash
cd services/backend
export PROMETHEUS_MULTIPROC_DIR=/tmp/prom-check
rm -rf "$PROMETHEUS_MULTIPROC_DIR" && mkdir -p "$PROMETHEUS_MULTIPROC_DIR"
python - <<'PY'
import os
import metrics
for pid_slot in range(2):                 # simulate two workers by forking
    if os.fork() == 0:
        metrics.REQUESTS.labels('GET', '/health', '200').inc()
        os._exit(0)
os.wait(); os.wait()
text = metrics.render_latest()[0].decode()
line = [l for l in text.splitlines() if l.startswith('voteball_http_requests_total{')][0]
print(line)
assert line.endswith(' 2.0'), f'expected the two workers to sum to 2.0, got: {line}'
print('OK: multiprocess aggregation sums across processes')
PY
rm -rf "$PROMETHEUS_MULTIPROC_DIR"
```

Expected: `OK: multiprocess aggregation sums across processes`. If it prints `1.0`, multiprocess mode
is not active and `/metrics` would report half the real traffic in production.

- [ ] **Step 6: Commit**

```bash
git add services/backend/gunicorn.conf.py services/backend/tests/test_gunicorn_conf.py
git commit -m "feat(backend): multiprocess metrics plumbing for gunicorn

Two workers per pod means two sets of counters and a scrape served by
whichever one accepts the connection -- so without this, /metrics reports
roughly half the real traffic and wobbles between scrapes.

_reset_multiproc_dir uses os/shutil rather than importing metrics.py on
purpose: in multiprocess mode a metric writes its file at DEFINITION
time, so importing metrics before the directory exists is the failure
being prevented. The wipe matters because an emptyDir survives a
container restart within the same pod.

child_exit reaps a dead worker's files; without it the traffic of a
process that exited an hour ago is still summed as current."
git push origin master
```

---

### Task 4: Business and dependency metrics

**Files:**
- Modify: `services/backend/app.py` (the `vote()` route, lines ~170-222)
- Modify: `services/backend/db.py` (`get_db`)
- Modify: `services/backend/tests/test_metrics.py` (append)

**Interfaces:**
- Consumes: `metrics.VOTES_CAST`, `metrics.VOTES_REJECTED`, `metrics.DB_ERRORS` from Task 1
- Produces: `voteball_votes_cast_total` incremented once per recorded ballot;
  `voteball_votes_rejected_total{reason}` over the bounded set
  `{considering-without-parties, too-many-parties, invalid-team-picks, rate-limited, duplicate, invalid-data}`;
  `voteball_db_errors_total{operation="connect"}`

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_metrics.py`:

```python
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd services/backend && python -m pytest tests/test_metrics.py -v -k "ballot or dependency"`
Expected: FAIL — counters stay at their previous values

- [ ] **Step 3: Write the implementation**

In `services/backend/app.py`, edit the `vote()` route. Each early return gains a counted reason, and
the success path increments the business metric. The reasons are a fixed set of six — do not
interpolate a message into the label:

```python
    if body.get('upcoming_vote_status') == 'considering' and not body.get('upcoming_party_ids'):
        metrics.VOTES_REJECTED.labels(reason='considering-without-parties').inc()
        return jsonify({'error': 'select at least one upcoming party when status is considering'}), 400
    if len(body.get('upcoming_party_ids') or []) > 3:
        metrics.VOTES_REJECTED.labels(reason='too-many-parties').inc()
        return jsonify({'error': 'select at most 3 upcoming parties'}), 400
```

```python
        picks_error = _validate_team_picks(conn, team_picks)
        if picks_error:
            metrics.VOTES_REJECTED.labels(reason='invalid-team-picks').inc()
            return jsonify({'error': picks_error}), 400
```

```python
        if queries.count_recent_votes_by_ip(conn, ip_hash, VOTE_IP_WINDOW_HOURS) >= MAX_VOTES_PER_IP:
            metrics.VOTES_REJECTED.labels(reason='rate-limited').inc()
            return jsonify({'error': 'Too many votes from this connection. Try again later.'}), 429
```

```python
    except ValueError:
        metrics.VOTES_REJECTED.labels(reason='duplicate').inc()
        return jsonify({'error': 'You have already voted'}), 409
    except Exception:
        metrics.VOTES_REJECTED.labels(reason='invalid-data').inc()
        return jsonify({'error': 'invalid vote data'}), 400
    finally:
        conn.close()

    metrics.VOTES_CAST.inc()
    resp = make_response(jsonify({'vote_id': vote_id}), 201)
```

In `services/backend/db.py`, add `import metrics` to the imports and replace `get_db` entirely:

```python
def get_db():
    try:
        return psycopg2.connect(
            host=DB_HOST, dbname=DB_NAME,
            user=DB_USER, password=DB_PASS,
            sslmode=DB_SSLMODE
        )
    except Exception:
        # One counter at the single place every route opens its connection. This is the signal the
        # 5xx drill produces: the pod stays Ready and /health keeps answering, because neither
        # touches the database -- only the per-request connection does.
        metrics.DB_ERRORS.labels(operation='connect').inc()
        raise
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd services/backend && python -m pytest tests/test_metrics.py -v`
Expected: PASS, 15 tests

- [ ] **Step 5: Run the whole backend suite**

Run: `cd services/backend && python -m pytest tests/ -q`
Expected: all pass. `test_requirements.py` must still pass — `db.py` now imports `metrics`, which is
a local module and therefore not a declared dependency.

- [ ] **Step 6: Commit**

```bash
git add services/backend/app.py services/backend/db.py services/backend/tests/test_metrics.py
git commit -m "feat(backend): count ballots cast, ballots refused, and connection failures

votes_cast_total is the business metric the brief asks for -- the action
this site exists for. The rejection reasons are a fixed set of six taken
from the validation branches themselves, never an interpolated message,
so the label stays bounded.

db_errors_total sits in get_db, the single place every route opens its
connection. That is precisely the path the 5xx drill breaks: /health is
static and liveness is a bare TCP check, so neither notices, and without
this counter nothing distinguishes a dead database from a quiet night."
git push origin master
```

---

### Task 5: Worker metrics

**Files:**
- Create: `services/worker/metrics.py`
- Create: `services/worker/tests/test_metrics.py`
- Modify: `services/worker/worker.py`
- Modify: `services/worker/requirements.txt`
- Modify: `services/worker/Dockerfile` (the `COPY` line)

**Interfaces:**
- Consumes: nothing from the backend — the worker is a separate build context and deliberately
  duplicates rather than imports
- Produces: `metrics.RECOMPUTES` (labels: `result`), `metrics.RECOMPUTE_DURATION`,
  `metrics.LAST_SUCCESS`, `metrics.NOTIFICATIONS`; `metrics.serve(port=None) -> None`

- [ ] **Step 1: Pin the dependency**

Resolve the version the same way as Task 1 and append to `services/worker/requirements.txt`:

```
# Metrics exposition on WORKER_METRICS_PORT. Single process here, so no multiprocess mode -- unlike
# the backend, which runs 2 gunicorn workers per pod.
prometheus-client==<the version pip reported>
```

- [ ] **Step 2: Write the failing test**

Create `services/worker/tests/test_metrics.py`:

```python
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd services/worker && python -m pytest tests/test_metrics.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'metrics'`

- [ ] **Step 4: Write the implementation**

Create `services/worker/metrics.py`:

```python
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
    loop is unaffected.
    """
    start_http_server(port or METRICS_PORT)
```

In `services/worker/worker.py`, add `import metrics` to the imports, then instrument
`run_iteration`'s body:

```python
def run_iteration(sns, s3, snapshot_fingerprint):
    """... keep the existing docstring ..."""
    conn = None
    started = time.perf_counter()
    try:
        conn = db.get_db()
        rollups.recompute(conn)
        alerts.check_and_notify(conn, sns, SNS_TOPIC)
        if s3 is not None:
            snapshot_fingerprint = snapshots.export_if_changed(
                conn, s3, S3_BUCKET, S3_SNAPSHOT_PREFIX, snapshot_fingerprint
            )
        print('Rollups recomputed, milestones checked.')
        metrics.RECOMPUTES.labels(result='success').inc()
        # Set only on success: a failed cycle that advanced this would make the staleness alert
        # unfireable, which is the failure the gauge exists to catch.
        metrics.LAST_SUCCESS.set(time.time())
    except Exception as e:
        metrics.RECOMPUTES.labels(result='failure').inc()
        print(f'Worker iteration failed, will retry next cycle: {e}')
    finally:
        metrics.RECOMPUTE_DURATION.observe(time.perf_counter() - started)
        if conn is not None:
            conn.close()
    return snapshot_fingerprint
```

and in the `__main__` block, start the server and count notified wake-ups:

```python
if __name__ == '__main__':
    sns = boto3.client('sns', region_name=AWS_REGION)
    # Only build an S3 client if a bucket is configured; otherwise stay None and skip S3 work.
    s3 = boto3.client('s3', region_name=AWS_REGION) if S3_BUCKET else None
    metrics.serve()
    print('Voteball worker started...')
```

```python
            if notifications.wait_for_change(listener, POLL_INTERVAL, DEBOUNCE_SECONDS):
                metrics.NOTIFICATIONS.inc()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd services/worker && python -m pytest tests/test_metrics.py -v`
Expected: PASS, 5 tests

- [ ] **Step 6: Add the file to the image and verify the requirements contract**

Modify `services/worker/Dockerfile`, adding `metrics.py` to the `COPY` line (keep the existing
filenames exactly, adding this one):

```dockerfile
COPY worker.py db.py metrics.py rollups.py alerts.py snapshots.py heartbeat.py notifications.py ./
```

Run: `cd services/worker && python -m pytest tests/ -q`
Expected: all pass, including `test_requirements.py`.

- [ ] **Step 7: Commit**

```bash
git add services/worker/metrics.py services/worker/tests/test_metrics.py \
        services/worker/worker.py services/worker/requirements.txt services/worker/Dockerfile
git commit -m "feat(worker): expose recompute health and rollup freshness

last_success_timestamp is the metric that matters here. The loop is
notification-driven with a polling backstop, so if LISTEN stops
delivering and the poll wedges, the site serves stale results with every
pod Ready and every existing alert quiet. Alert on the age of this gauge,
not its value.

It is set only on success -- a failed cycle that advanced it would make
the staleness alert unfireable, which is exactly the silent failure it
exists to catch. A test pins that.

Its own module rather than an import from the backend: separate build
contexts, no shared package, same reason db.py is duplicated."
git push origin master
```

---

### Task 6: Whole-repo verification

**Files:**
- Modify: `docs/design/2026-08-17-observability-design.md` (Verification section correction)

**Interfaces:**
- Consumes: everything from Tasks 1-5
- Produces: a verified, lint-clean tree ready for plan 2 (chart wiring)

- [ ] **Step 1: Run both suites in full**

```bash
docker start voteball-test-db 2>/dev/null || docker run -d --name voteball-test-db \
  -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
cd services/backend && python -m pytest tests/ -q
cd ../worker && python -m pytest tests/ -q
```

Expected: both green. Record the two test counts — they go in the plan-2 documentation update.

- [ ] **Step 2: Run the linter CI runs before any test**

Run: `ruff check services/`
Expected: no findings. CI lints before it tests, so a lint error here blocks deployment regardless of
whether the tests pass.

- [ ] **Step 3: Build both images to prove the COPY lines are right**

```bash
docker build -t voteball-backend-check services/backend
docker build -t voteball-worker-check services/worker
docker run --rm voteball-backend-check python -c "import metrics; print('backend metrics.py present')"
docker run --rm voteball-worker-check python -c "import metrics; print('worker metrics.py present')"
docker rmi voteball-backend-check voteball-worker-check
```

Expected: both print their line. A missing `COPY` entry produces no build error and only shows up as
this `ImportError` — or, unbuilt, as a crash-looping pod in production.

- [ ] **Step 4: Correct one wrong claim in the design doc**

The Verification section says new tests must be assigned to `run-ci-suite.sh`'s `PYTHON_GROUP` or
`GIT_GROUP`. That is wrong for the tests in this plan: `run-ci-suite.sh` classifies only
`scripts/tests/*.sh`, and pytest files under `services/*/tests/` are run by CI's separate pytest
stages. The rule applies to plan 3, which adds shell tests.

In `docs/design/2026-08-17-observability-design.md`, replace this bullet:

```markdown
- `scripts/tests/run-ci-suite.sh` — the new tests must be assigned to `PYTHON_GROUP` or `GIT_GROUP`,
  which the suite enforces
```

with:

```markdown
- `scripts/tests/run-ci-suite.sh` — note its group lists classify only `scripts/tests/*.sh`, so the
  pytest files added for instrumentation need no entry; the shell tests added for the CI/CD gates
  (§11, §12) do, and the suite fails if one is in neither group
```

- [ ] **Step 5: Commit**

```bash
git add docs/design/2026-08-17-observability-design.md
git commit -m "docs(design): correct the CI-suite grouping claim

run-ci-suite.sh's PYTHON_GROUP/GIT_GROUP lists classify scripts/tests/*.sh
only. The pytest files added for instrumentation are run by CI's separate
pytest stages and need no entry; the rule applies to the shell tests the
pipeline work will add."
git push origin master
```

- [ ] **Step 6: Delete this plan**

Per the repo's standing rule, an executed plan is deleted in the same commit as its last task — a
plan that outlives its execution reads like pending work. The design doc is the durable record.

```bash
git rm -r docs/superpowers
git commit -m "chore: remove the executed instrumentation plan

Standing rule: a plan is deleted the moment it is executed. Git history is
the archive; docs/design/2026-08-17-observability-design.md is the record."
git push origin master
```

---

## What plan 2 covers (not this plan)

So the next session knows where the boundary is: chart wiring (named Service ports, the worker
Service, the nginx exporter sidecar, `APP_VERSION` and `PROMETHEUS_MULTIPROC_DIR` env, ServiceMonitors,
the scrape NetworkPolicies and the ALB-rule narrowing of §7a), the Terraform stack changes (namespace
rename, EBS CSI, PVC, retention), `charts/observability` with the three dashboards and the platform
alerts, and the `destroy.sh` PVC step. Plan 3 covers the CI validation stage, the CD monitoring gate,
the four drills, and the evidence set.
