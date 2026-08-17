import os
import pathlib
import shutil

# Production WSGI server config. Werkzeug's app.run() (still used for local dev in app.py's
# __main__) is single-threaded and explicitly not for production; gunicorn replaces it here.
bind = '0.0.0.0:5000'
workers = int(os.environ.get('GUNICORN_WORKERS', '2'))


def _reset_multiproc_dir():
    """Give the metrics multiprocess directory a clean, existing home before any worker forks.

    Deliberately implemented with os/shutil rather than by importing metrics.py, and the reason is
    the WIPE, not the directory-must-exist-before-import case (metrics.py already calls
    ensure_multiproc_dir() before defining any metric, so that particular failure can't happen here
    regardless of import order). If the master imported metrics.py itself, importing it would DEFINE
    the metrics and write this process's own counter_<masterpid>.db -- and the rmtree() below would
    then unlink a file the master still holds mmapped, silently losing anything later incremented in
    the master, including DB_ERRORS from on_starting's own db.get_db() call. Doing the wipe with
    plain os/shutil, before metrics.py is ever imported by anyone, avoids that.

    The wipe itself matters because an emptyDir survives a container restart within the same pod --
    counter files written by the previous process would otherwise be summed into the new one's
    totals.
    """
    path = os.environ.get('PROMETHEUS_MULTIPROC_DIR')
    if not path:
        return
    directory = pathlib.Path(path)
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)


def _mark_process_dead(pid):
    """Indirection so the reaping can be asserted without a real prometheus_client registry.

    Returns early, before ever touching prometheus_client, when PROMETHEUS_MULTIPROC_DIR is unset or
    empty. No chart, terraform or script in this repo sets that variable yet -- it arrives in a later
    plan -- so on a live pod it currently IS unset, and multiprocess.mark_process_dead(pid) resolves
    it with os.path.join(None, ...), raising TypeError. gunicorn 23's reap_workers() catches only
    OSError, so that exception used to escape into the arbiter's main loop: a worker killed while
    running (OOM, the default 30s timeout) took the whole master down, and a plain SIGTERM -- every
    rolling update, every ArgoCD sync, every Spot reclaim -- exited 1 with a traceback instead of
    draining in-flight requests and exiting 0.
    """
    path = os.environ.get('PROMETHEUS_MULTIPROC_DIR')
    if not path:
        return
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
    """Reap a departed worker's 'live*' gauge files.

    prometheus_client 0.26.0's multiprocess.mark_process_dead(pid) removes ONLY the five
    gauge_{mode}_{pid}.db files for the 'live*' multiprocess_mode gauges (livesum/livemax/livemin/
    liveall/livemostrecent) -- it never touches counter or histogram files, and this branch declares
    no 'live*' gauge, so today the call is a no-op. Keep it anyway: it is the documented idiom, and it
    becomes meaningful the moment a 'live*' gauge is added.

    A departed worker's COUNTER file is deliberately left in place and kept in the sum -- that is
    correct, not a gap. A counter that stops rising yields rate() == 0; deleting its file on exit
    would cause a counter reset and a false rate spike instead. Do not "fix" APP_INFO (multiprocess_
    mode='max') into a 'livemax' gauge thinking that mode is safely reaped by this hook: 'live*' modes
    report only currently-alive processes, so voteball_app_info would vanish the instant its worker
    exits, per worker, rather than persisting as the build's identity.
    """
    _mark_process_dead(worker.pid)
