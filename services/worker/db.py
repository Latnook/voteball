import os
import psycopg2

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ.get('DB_NAME', 'postgres')
DB_USER = os.environ.get('DB_USER', 'postgres')
DB_PASS = os.environ['DB_PASS']
DB_SSLMODE = os.environ.get('DB_SSLMODE', 'require')


def get_db():
    # connect_timeout bounds a TCP-level outage (e.g. a NetworkPolicy cutting the route to RDS, the
    # cause proven by the 2026-08-18 egress drill) to a fast, countable failure instead of a hang.
    # Without it connect() blocks indefinitely, so run_iteration()'s try/except never gets a chance
    # to record the failure (RECOMPUTES{result="failure"}) or keep LAST_SUCCESS aging visibly -- a
    # hung connect is a worse outcome for monitoring than a raised one, because a raise is an event
    # that can be counted and a hang is the absence of one. See services/backend/db.py for the
    # matching fix on the request path.
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS,
        sslmode=DB_SSLMODE,
        connect_timeout=5
    )
