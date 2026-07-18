import os

# Production WSGI server config. Werkzeug's app.run() (still used for local dev in app.py's
# __main__) is single-threaded and explicitly not for production; gunicorn replaces it here.
bind = '0.0.0.0:5000'
workers = int(os.environ.get('GUNICORN_WORKERS', '2'))


def on_starting(server):
    """Bootstrap the schema once per pod, in the master before workers fork.

    Under app.run() this lived in app.py's __main__ block; gunicorn imports app:app instead, so
    __main__ never runs and the bootstrap has to move here. Running it in on_starting (not per
    worker) keeps it to one invocation per pod -- the same concurrency the 2-replica Deployment
    already produced under the old dev-server entrypoint, and schema.sql/seed.sql are idempotent.
    """
    import db
    conn = db.get_db()
    try:
        db.init_db(conn)
    finally:
        conn.close()
