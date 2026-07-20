"""LISTEN/NOTIFY wake-up, against a real Postgres (same style as the other worker tests)."""
import threading
import time

import notifications
import db


def test_times_out_and_returns_false_when_nothing_happens():
    """The periodic backstop: no notification means wait_for_change still returns, reporting False."""
    listener = notifications.open_listener(db.get_db)
    try:
        start = time.monotonic()
        woke = notifications.wait_for_change(listener, timeout=1.0, debounce=0.1)
        elapsed = time.monotonic() - start

        assert woke is False, 'no NOTIFY was sent, so it must report a timeout, not a wake'
        assert 0.9 <= elapsed < 3.0, f'should wait about the timeout, waited {elapsed:.2f}s'
    finally:
        listener.close()


def test_wakes_promptly_on_notify(conn):
    """A committed NOTIFY must wake the listener far faster than the poll interval."""
    listener = notifications.open_listener(db.get_db)
    try:
        def notify_soon():
            time.sleep(0.3)
            cur = conn.cursor()
            cur.execute(f'NOTIFY {notifications.CHANNEL}')
            conn.commit()          # NOTIFY is transactional: nothing is delivered until COMMIT
            cur.close()

        t = threading.Thread(target=notify_soon)
        start = time.monotonic()
        t.start()
        woke = notifications.wait_for_change(listener, timeout=20.0, debounce=0.2)
        elapsed = time.monotonic() - start
        t.join()

        assert woke is True, 'a committed NOTIFY must wake the listener'
        assert elapsed < 5.0, f'woke after {elapsed:.2f}s; should be ~0.3s + debounce, not the timeout'
    finally:
        listener.close()


def test_rolled_back_notify_does_not_wake(conn):
    """NOTIFY is transactional -- a rolled-back vote must not trigger a recompute."""
    listener = notifications.open_listener(db.get_db)
    try:
        cur = conn.cursor()
        cur.execute(f'NOTIFY {notifications.CHANNEL}')
        conn.rollback()
        cur.close()

        woke = notifications.wait_for_change(listener, timeout=1.5, debounce=0.1)
        assert woke is False, 'a rolled-back NOTIFY must never be delivered'
    finally:
        listener.close()


def test_burst_is_coalesced_into_one_wake(conn):
    """50 votes in quick succession should cause one recompute, not 50."""
    listener = notifications.open_listener(db.get_db)
    try:
        def burst():
            time.sleep(0.2)
            cur = conn.cursor()
            for _ in range(50):
                cur.execute(f'NOTIFY {notifications.CHANNEL}')
                conn.commit()
            cur.close()

        t = threading.Thread(target=burst)
        t.start()
        assert notifications.wait_for_change(listener, timeout=20.0, debounce=0.5) is True
        t.join()

        # The debounce drained the burst, so a second wait sees a quiet channel and times out
        # rather than firing 49 more times.
        assert notifications.wait_for_change(listener, timeout=1.0, debounce=0.1) is False, \
            'the burst should have been coalesced, leaving no queued notifications'
    finally:
        listener.close()
