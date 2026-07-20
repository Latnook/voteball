import os
import psycopg2

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ.get('DB_NAME', 'postgres')
DB_USER = os.environ.get('DB_USER', 'postgres')
DB_PASS = os.environ['DB_PASS']
DB_SSLMODE = os.environ.get('DB_SSLMODE', 'require')


def get_db():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS,
        sslmode=DB_SSLMODE
    )


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
