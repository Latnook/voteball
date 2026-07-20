"""Standalone schema-bootstrap entrypoint: `python migrate.py`.

The schema/seed are created by db.init_db(), which today also runs from two other places:
  - app.py's `if __name__ == '__main__'` guard (local dev via the Flask dev server), and
  - gunicorn.conf.py's on_starting hook (the k3s container, since gunicorn imports app.py and so
    the __main__ guard never fires).

This module makes the same bootstrap runnable as its OWN short-lived process. That's what the EKS
Helm pre-install/pre-upgrade migration Job (a later plan) will execute: running init_db exactly
once per release, instead of every backend replica racing to run it on startup. It changes nothing
about the current k3s path -- on_starting stays -- and it's safe to run anytime, because init_db is
idempotent (CREATE TABLE IF NOT EXISTS + seed inserts guarded by ON CONFLICT DO NOTHING).
"""
import db


def main():
    """Open a connection, apply schema + seed once, and close it."""
    conn = db.get_db()
    try:
        db.init_db(conn)
        print('Schema and seed applied.')
    finally:
        # try/finally so the connection is released even if init_db raises -- the same
        # close-on-every-exit-path discipline the app's request handlers follow.
        conn.close()


if __name__ == '__main__':
    main()
