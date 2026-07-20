"""Wait for the backend to signal that votes changed, instead of polling on a fixed timer.

The backend issues `NOTIFY votes_changed` inside the vote transaction (see backend/queries.py), so a
notification arrives only when a vote actually commits. This turns the results lag from "up to the
poll interval" into "sub-second", without adding a queue or any AWS infrastructure -- Postgres
already had the primitive.

Two deliberate properties:

* **The poll is kept as a backstop.** `wait_for_change` returns after `timeout` even with no
  notification, so the worker still recomputes periodically. A missed notification (listener
  reconnect, worker restart, a vote inserted by something other than the API) costs latency, never
  correctness.
* **Bursts are debounced.** After the first notification it drains anything that arrives within
  `debounce`, so 50 votes in a second cause one recompute rather than 50. That matters because
  rollups.recompute() rebuilds the rollup tables wholesale rather than incrementally.
"""
import select

import psycopg2.extensions

CHANNEL = 'votes_changed'


def open_listener(connect):
    """Return an autocommit connection LISTENing on the votes channel.

    Kept separate from the connection used for recomputation: LISTEN has to sit outside a
    transaction, and the recompute path opens and closes its own connection per iteration.
    """
    conn = connect()
    conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()
    cur.execute(f'LISTEN {CHANNEL}')
    cur.close()
    return conn


def wait_for_change(conn, timeout, debounce=2.0):
    """Block until a vote lands or `timeout` elapses.

    Returns True if woken by a notification, False if the timeout expired (the periodic backstop).
    Raises if the connection is broken, so the caller can reconnect.
    """
    if not select.select([conn], [], [], timeout)[0]:
        return False

    conn.poll()
    conn.notifies.clear()

    # Coalesce a burst: keep draining until the channel goes quiet for `debounce` seconds.
    while select.select([conn], [], [], debounce)[0]:
        conn.poll()
        conn.notifies.clear()

    return True
