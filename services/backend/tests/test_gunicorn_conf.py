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
