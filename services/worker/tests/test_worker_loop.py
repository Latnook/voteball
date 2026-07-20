import os
import sys
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('SNS_TOPIC', 'arn:aws:sns:il-central-1:000000000000:test-topic')

import worker  # noqa: E402  (import after env setup, matches conftest.py pattern)


def test_run_iteration_success_closes_connection():
    # Happy path: opens a connection, recomputes, notifies, and always closes the connection.
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn) as mock_get_db, \
         patch('worker.rollups.recompute') as mock_recompute, \
         patch('worker.alerts.check_and_notify') as mock_notify:
        worker.run_iteration(MagicMock(), None, None)

    mock_get_db.assert_called_once()
    mock_recompute.assert_called_once_with(mock_conn)
    mock_notify.assert_called_once()
    mock_conn.close.assert_called_once()


def test_run_iteration_exports_snapshot_when_s3_present():
    # When an S3 client is supplied, the snapshot step runs and its returned fingerprint is what
    # run_iteration hands back (so the loop can thread it into the next call).
    mock_conn = MagicMock()
    fake_s3 = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute'), \
         patch('worker.alerts.check_and_notify'), \
         patch('worker.snapshots.export_if_changed', return_value='fp-new') as mock_export:
        result = worker.run_iteration(MagicMock(), fake_s3, 'fp-old')

    mock_export.assert_called_once()
    assert result == 'fp-new'


def test_run_iteration_skips_snapshot_when_s3_is_none():
    # No S3 client (the k3s case, where S3_BUCKET is unset) => no snapshot call at all, and the
    # fingerprint passes straight through unchanged. This is what keeps the change inert on k3s.
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute'), \
         patch('worker.alerts.check_and_notify'), \
         patch('worker.snapshots.export_if_changed') as mock_export:
        result = worker.run_iteration(MagicMock(), None, 'fp-old')

    mock_export.assert_not_called()
    assert result == 'fp-old'


def test_run_iteration_survives_recompute_failure_and_still_closes_connection():
    # A transient DB blip during recompute must be swallowed (logged, not raised) so Kubernetes
    # doesn't turn a brief hiccup into a crash-restart loop -- and the connection still closes.
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute', side_effect=RuntimeError('connection reset')), \
         patch('worker.alerts.check_and_notify') as mock_notify:
        worker.run_iteration(MagicMock(), None, None)  # must not raise

    mock_conn.close.assert_called_once()
    mock_notify.assert_not_called()


def test_run_iteration_survives_alerts_failure_and_still_closes_connection():
    # Same resilience guarantee if the failure happens during the alerts step instead.
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute') as mock_recompute, \
         patch('worker.alerts.check_and_notify', side_effect=RuntimeError('sns unavailable')):
        worker.run_iteration(MagicMock(), None, None)

    mock_recompute.assert_called_once_with(mock_conn)
    mock_conn.close.assert_called_once()


def test_run_iteration_survives_connection_failure_with_no_connection_to_close():
    # If get_db() itself fails, there's no connection to close and nothing should raise.
    with patch('worker.db.get_db', side_effect=RuntimeError('could not connect to server')):
        worker.run_iteration(MagicMock(), None, None)  # must not raise
