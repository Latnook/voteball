import os

import heartbeat


def test_touch_creates_file(tmp_path):
    # A brand-new heartbeat path should be created on first touch.
    p = tmp_path / 'hb'
    assert not p.exists()
    heartbeat.touch(str(p))
    assert p.exists()


def test_touch_updates_mtime(tmp_path):
    # Touching an existing file must bump its modification time -- that mtime is exactly what the
    # Kubernetes liveness probe will inspect ("is this file fresh?").
    p = tmp_path / 'hb'
    heartbeat.touch(str(p))
    os.utime(str(p), (0, 0))  # force mtime to the epoch, i.e. "very stale"
    heartbeat.touch(str(p))
    assert p.stat().st_mtime > 0


def test_default_path_is_tmp():
    # /tmp is chosen because it stays writable under readOnlyRootFilesystem: true (the chart mounts
    # an emptyDir there). If this default ever drifts, the probe and the volume mount drift with it.
    assert heartbeat.DEFAULT_PATH == '/tmp/heartbeat'
