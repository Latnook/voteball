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
import os

from psycopg2 import sql

import db


def _set_grafana_password(conn):
    """Give the grafana_ro role its password, from the environment.

    schema.sql creates the role with no password, because it runs on every backend boot and can
    carry no secret. This runs only in the migrate Job, which is the one place the password is
    projected -- see charts/voteball/templates/externalsecret.yaml.

    DELIBERATELY OPTIONAL. If GRAFANA_DB_PASSWORD is absent the Job prints a notice and succeeds.
    A missing monitoring credential must never block a release: this Job is a pre-upgrade Helm hook,
    so raising here would stop the application from deploying because a dashboard cannot log in.
    """
    password = os.environ.get('GRAFANA_DB_PASSWORD', '')
    if not password:
        print('GRAFANA_DB_PASSWORD not set; leaving grafana_ro without a password '
              '(the Grafana PostgreSQL data source will not authenticate until it is seeded).')
        return

    cur = conn.cursor()
    # Parameterised as a VALUE is not possible here -- ALTER ROLE takes a literal, not a bind
    # parameter -- so quote it with psycopg2's own literal quoting rather than an f-string.
    cur.execute(sql.SQL('ALTER ROLE grafana_ro WITH PASSWORD {}').format(sql.Literal(password)))
    conn.commit()
    cur.close()
    print('grafana_ro password set.')


def main():
    """Open a connection, apply schema + seed once, set the Grafana role's password, and close it."""
    conn = db.get_db()
    try:
        db.init_db(conn)
        print('Schema and seed applied.')
        _set_grafana_password(conn)
    finally:
        # try/finally so the connection is released even if init_db raises -- the same
        # close-on-every-exit-path discipline the app's request handlers follow.
        conn.close()


if __name__ == '__main__':
    main()
