"""connect_timeout on the database connection -- see the comment in db.py.

Without it, a TCP-level outage (a NetworkPolicy cutting the route to RDS, the exact cause proven by
the 2026-08-18 egress drill) makes psycopg2.connect() HANG rather than error, so no metric ever sees
it. This asserts on the kwarg actually passed to psycopg2.connect, not on hang behaviour -- a real
hang cannot be simulated here without blocking the suite for the timeout duration itself.
"""
import db
import psycopg2


def test_get_db_passes_a_connect_timeout(monkeypatch):
    captured = {}

    def fake_connect(*args, **kwargs):
        captured.update(kwargs)
        return object()

    monkeypatch.setattr(psycopg2, 'connect', fake_connect)
    db.get_db()

    assert captured.get('connect_timeout') == 5
