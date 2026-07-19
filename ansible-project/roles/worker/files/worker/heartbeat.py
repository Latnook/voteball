"""A file-based liveness signal for the worker.

The worker is a plain batch loop with no HTTP server, so Kubernetes has nothing to poll to decide
whether the process is healthy. The convention for that situation is a "heartbeat file": the loop
updates a file's timestamp every iteration, and an `exec` liveness probe (defined in the Helm chart,
a later plan) restarts the pod if that file ever goes stale.

Semantics chosen for THIS worker (see worker.py's loop): the file is touched every iteration even
after a caught error, so the meaning is "the loop is still spinning", NOT "the database is
reachable". A DB outage must not restart the worker -- the loop already catches and retries -- but a
genuinely wedged process (stuck loop) will stop touching the file and get restarted.
"""
import os
import pathlib

# /tmp is deliberate: under securityContext.readOnlyRootFilesystem: true the container's root fs is
# read-only, so the worker can only write to paths backed by a writable volume. The chart mounts an
# emptyDir at /tmp for exactly this. Overridable via env for local runs / tests.
DEFAULT_PATH = os.environ.get('HEARTBEAT_FILE', '/tmp/heartbeat')


def touch(path=DEFAULT_PATH):
    """Create the heartbeat file if it doesn't exist and bump its modification time to 'now'.

    pathlib's Path.touch() does both in one call -- create-if-missing plus mtime update -- which is
    all the liveness probe cares about (it only ever reads the file's age, never its contents).
    """
    pathlib.Path(path).touch()
