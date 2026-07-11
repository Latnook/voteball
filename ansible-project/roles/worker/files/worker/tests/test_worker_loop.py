import os
import sys
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault('SNS_TOPIC', 'arn:aws:sns:il-central-1:000000000000:test-topic')

import worker  # noqa: E402  (import after env setup, matches conftest.py pattern)


def test_run_iteration_success_closes_connection():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn) as mock_get_db, \
         patch('worker.rollups.recompute') as mock_recompute, \
         patch('worker.alerts.check_and_notify') as mock_notify:
        worker.run_iteration(MagicMock())

    mock_get_db.assert_called_once()
    mock_recompute.assert_called_once_with(mock_conn)
    mock_notify.assert_called_once()
    mock_conn.close.assert_called_once()


def test_run_iteration_survives_recompute_failure_and_still_closes_connection():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute', side_effect=RuntimeError('connection reset')), \
         patch('worker.alerts.check_and_notify') as mock_notify:
        # Must not raise -- a transient DB blip should be logged, not crash the process.
        worker.run_iteration(MagicMock())

    mock_conn.close.assert_called_once()
    mock_notify.assert_not_called()


def test_run_iteration_survives_alerts_failure_and_still_closes_connection():
    mock_conn = MagicMock()
    with patch('worker.db.get_db', return_value=mock_conn), \
         patch('worker.rollups.recompute') as mock_recompute, \
         patch('worker.alerts.check_and_notify', side_effect=RuntimeError('sns unavailable')):
        worker.run_iteration(MagicMock())

    mock_recompute.assert_called_once_with(mock_conn)
    mock_conn.close.assert_called_once()


def test_run_iteration_survives_connection_failure_with_no_connection_to_close():
    with patch('worker.db.get_db', side_effect=RuntimeError('could not connect to server')):
        # Should not raise, and there's nothing to close since get_db() never returned.
        worker.run_iteration(MagicMock())
