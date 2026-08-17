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


def test_mark_process_dead_is_a_clean_no_op_when_multiproc_dir_is_unset(monkeypatch):
    # CRITICAL regression test. On a live pod today, no chart/terraform/script in this repo sets
    # PROMETHEUS_MULTIPROC_DIR -- it arrives in a later plan -- so this is the actual production
    # state, hit on every worker exit (OOM, gunicorn's default 30s timeout, or a plain SIGTERM from a
    # rolling update / ArgoCD sync / Spot reclaim). Unfixed, this calls the REAL
    # prometheus_client.multiprocess.mark_process_dead(pid), which does os.path.join(None, ...) and
    # raises TypeError. gunicorn 23's reap_workers() catches only OSError, so that exception escapes
    # into the arbiter's main loop and takes the whole master down -- turning a routine worker exit
    # or a graceful SIGTERM into a crashed pod instead of a clean exit 0.
    monkeypatch.delenv('PROMETHEUS_MULTIPROC_DIR', raising=False)
    module = _load()

    module._mark_process_dead(4242)   # must return cleanly, must NOT raise


def test_mark_process_dead_reaps_live_gauge_files_when_multiproc_dir_is_set(tmp_path, monkeypatch):
    # When the directory IS configured, the real prometheus_client call must run and must actually
    # remove the dead process's 'live*'-mode gauge file (the only file kind mark_process_dead ever
    # touches, per prometheus_client 0.26.0 -- see child_exit's docstring).
    monkeypatch.setenv('PROMETHEUS_MULTIPROC_DIR', str(tmp_path))
    module = _load()

    pid = 4242
    live_file = tmp_path / f'gauge_livesum_{pid}.db'
    live_file.write_bytes(b'stale')

    module._mark_process_dead(pid)   # must not raise

    assert not live_file.exists()


def test_child_exit_calls_mark_process_dead_with_the_worker_pid(monkeypatch):
    reaped = []
    module = _load()
    monkeypatch.setattr(module, '_mark_process_dead', reaped.append)

    class FakeWorker:
        pid = 4242

    module.child_exit(server=None, worker=FakeWorker())
    assert reaped == [4242]
