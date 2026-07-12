import os
import sys
import pytest
import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('DB_HOST', 'localhost')
os.environ.setdefault('DB_NAME', 'postgres')
os.environ.setdefault('DB_USER', 'postgres')
os.environ.setdefault('DB_PASS', 'test')
os.environ.setdefault('DB_SSLMODE', 'disable')
os.environ.setdefault('SNS_TOPIC', 'arn:aws:sns:il-central-1:000000000000:test')
os.environ.setdefault('AWS_REGION', 'il-central-1')
os.environ.setdefault('ADMIN_SECRET', 'test-admin-secret')

import db as db_module


@pytest.fixture
def conn():
    connection = db_module.get_db()
    cur = connection.cursor()
    cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, votes, rollup_previous,
            rollup_upcoming, rollup_previous_upcoming, clubs, leagues, previous_parties,
            upcoming_parties, alert_state CASCADE
    ''')
    connection.commit()
    cur.close()
    db_module.init_db(connection)
    yield connection
    connection.close()


@pytest.fixture
def client(conn):
    import app as app_module
    app_module.app.config['TESTING'] = True
    with app_module.app.test_client() as c:
        yield c
