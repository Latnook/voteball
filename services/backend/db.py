import os

import metrics
import psycopg2

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ.get('DB_NAME', 'postgres')
DB_USER = os.environ.get('DB_USER', 'postgres')
DB_PASS = os.environ['DB_PASS']
DB_SSLMODE = os.environ.get('DB_SSLMODE', 'require')


def get_db():
    try:
        return psycopg2.connect(
            host=DB_HOST, dbname=DB_NAME,
            user=DB_USER, password=DB_PASS,
            sslmode=DB_SSLMODE,
            # Without this, a database that is unreachable at the TCP level -- exactly what the
            # 2026-08-18 egress drill produced -- makes connect() HANG instead of erroring. A hung
            # connect means the Flask request never completes, after_request() never runs, and
            # neither voteball_http_requests_total nor voteball_db_errors_total ever increments: the
            # outage becomes invisible to every ratio-based alert, and only nginx's own 60s timeout
            # eventually returns a 504 to the visitor. 5s bounds the hang so the except below (and
            # its DB_ERRORS counter) is reached quickly, turning an un-countable hang into a fast,
            # countable 500.
            connect_timeout=5
        )
    except Exception:
        # One counter at the single place every route opens its connection. This is the signal the
        # 5xx drill produces: the pod stays Ready and /health keeps answering, because neither
        # touches the database -- only the per-request connection does.
        metrics.DB_ERRORS.labels(operation='connect').inc()
        raise


def init_db(conn):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(base_dir, 'schema.sql')) as f:
        schema_sql = f.read()
    with open(os.path.join(base_dir, 'seed.sql')) as f:
        seed_sql = f.read()

    cur = conn.cursor()
    cur.execute(schema_sql)
    cur.execute(seed_sql)
    conn.commit()
    cur.close()
