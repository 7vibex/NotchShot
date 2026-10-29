import math
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_recording_cadence import capture, interval_metrics, window_metrics


class RecordingCadenceTests(unittest.TestCase):
    def test_regular_thirty_fps(self):
        result = window_metrics([number / 30 for number in range(1800)], 0, 60)
        self.assertAlmostEqual(result['fps'], 30)
        self.assertAlmostEqual(result['frameSpanFPS'], 30)
        self.assertAlmostEqual(result['maximumGapSeconds'], 1 / 30)

    def test_a_stall_is_visible_in_rate_and_gaps(self):
        times = [number / 30 for number in range(1800) if not 900 <= number < 930]
        result = window_metrics(times, 0, 60)
        self.assertAlmostEqual(result['fps'], 29.5)
        self.assertGreater(result['maximumGapSeconds'], 1)
        self.assertEqual(result['gapsOver100ms'], 1)

    def test_held_tail_does_not_disappear_from_fps(self):
        result = window_metrics([number / 30 for number in range(1500)], 0, 60)
        self.assertAlmostEqual(result['frameSpanFPS'], 30)
        self.assertAlmostEqual(result['fps'], 25)
        self.assertGreater(result['maximumGapIncludingBoundariesSeconds'], 10)

    def test_window_is_half_open(self):
        result = window_metrics([0, 1, 2, 3, 4], 1, 4)
        self.assertEqual(result['frames'], 3)
        self.assertEqual(result['fps'], 1)

    def test_presentation_order_does_not_depend_on_packet_decode_order(self):
        self.assertEqual(interval_metrics([0, 2, 1, 3]), interval_metrics([0, 1, 2, 3]))

    def test_invalid_or_ambiguous_measurements_fail(self):
        for times in [[], [0], [0, 0], [0, math.nan], [0, math.inf]]:
            with self.subTest(times=times), self.assertRaises(ValueError):
                interval_metrics(times)
        for start, end in [(1, 1), (2, 1), (0, math.inf)]:
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                window_metrics([0, 1, 2], start, end)
        with self.assertRaises(ValueError):
            window_metrics([0, 1, math.nan], 0, 2)

    def test_locked_or_off_console_session_cannot_launch_capture(self):
        for state in [{'onConsole': True, 'screenLocked': True},
                      {'onConsole': False, 'screenLocked': False},
                      {'onConsole': None, 'screenLocked': None}]:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as root:
                session = mock.Mock()
                session.snapshot.return_value = state
                with mock.patch('audit_recording_cadence.subprocess.Popen') as spawn, \
                     self.assertRaisesRegex(RuntimeError, 'locked or unavailable'):
                    capture(Path('/unused.app'), Path(root), 60, 80, 15, [], session)
                spawn.assert_not_called()

    def test_lock_between_idle_preflight_and_launch_is_rechecked(self):
        unlocked = {'onConsole': True, 'screenLocked': None}
        locked = {'onConsole': True, 'screenLocked': True}
        session = mock.Mock()
        session.snapshot.side_effect = [unlocked] * 4 + [locked]
        with tempfile.TemporaryDirectory() as root, \
             mock.patch('audit_recording_cadence.HostCPU') as host, \
             mock.patch('audit_recording_cadence.time.sleep'), \
             mock.patch('audit_recording_cadence.subprocess.Popen') as spawn:
            host.return_value.idle.return_value = 90
            with self.assertRaisesRegex(RuntimeError, 'locked or unavailable'):
                capture(Path('/unused.app'), Path(root), 60, 80, 15, [], session)
            spawn.assert_not_called()

    def test_mid_capture_lock_stops_only_owned_group_and_keeps_scratch(self):
        unlocked = {'onConsole': True, 'screenLocked': None}
        locked = {'onConsole': True, 'screenLocked': True}
        session = mock.Mock()
        session.snapshot.side_effect = [unlocked] * 5 + [locked]
        child = mock.Mock(pid=12345)
        child.poll.return_value = None
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            scratch = directory / 'InProgress' / 'draft.mp4'
            scratch.parent.mkdir()
            scratch.write_bytes(b'isolated draft')
            with mock.patch('audit_recording_cadence.HostCPU') as host, \
                 mock.patch('audit_recording_cadence.time.sleep'), \
                 mock.patch('audit_recording_cadence.subprocess.Popen', return_value=child), \
                 mock.patch('audit_recording_cadence.os.killpg') as stop:
                host.return_value.idle.return_value = 90
                with self.assertRaisesRegex(RuntimeError, 'locked during capture'):
                    capture(Path('/unused.app'), directory, 60, 80, 15, [], session)
                stop.assert_called_once_with(12345, 9)
                child.wait.assert_called_once()
                self.assertEqual(scratch.read_bytes(), b'isolated draft')

    def test_lock_after_child_exit_is_not_classified_as_during_capture(self):
        session = mock.Mock()
        session.snapshot.return_value = {'onConsole': True, 'screenLocked': None}
        child = mock.Mock(pid=12345)
        child.poll.side_effect = [None, 0, 0]
        child.wait.return_value = 0
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            (directory / 'completed.json').write_text(json.dumps({'active': False, 'playable': True, 'duration': 60}))
            with mock.patch('audit_recording_cadence.HostCPU') as host, \
                 mock.patch('audit_recording_cadence.time.sleep'), \
                 mock.patch('audit_recording_cadence.subprocess.Popen', return_value=child), \
                 mock.patch('audit_recording_cadence.os.killpg') as stop:
                host.return_value.idle.return_value = 90
                capture(Path('/unused.app'), directory, 60, 80, 15, [], session)
                self.assertEqual(session.snapshot.call_count, 5)
                stop.assert_not_called()
                rows = json.loads((directory / 'host.json').read_text())
                self.assertEqual(rows[-1]['phase'], 'postCapture')
                self.assertIsNone(rows[-1]['session'])


if __name__ == '__main__':
    unittest.main()
