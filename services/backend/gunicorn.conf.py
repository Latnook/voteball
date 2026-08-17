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
