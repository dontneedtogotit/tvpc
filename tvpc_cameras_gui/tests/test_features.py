"""Tests for config, recording, notifications, and health modules."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest

# Ensure the package is importable.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))


class TestConfigNewFields(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.mkdtemp()
        os.environ["XDG_CONFIG_HOME"] = self._tmpdir

    def test_round_trip_new_fields(self) -> None:
        from tvpc_cameras_gui import config
        cam = config.Camera(
            name="Test Cam", url="rtsp://192.168.1.1/stream",
            user="admin", password="secret", notes="A test camera",
            group="Backyard", profile="sub", audio=False,
        )
        config.save_cameras([cam])
        loaded = config.load_cameras()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0].group, "Backyard")
        self.assertEqual(loaded[0].profile, "sub")
        self.assertEqual(loaded[0].audio, False)

    def test_legacy_format_still_works(self) -> None:
        from tvpc_cameras_gui import config
        # Write a legacy 5-field line directly.
        config.ensure_conf()
        with open(config.CONF_FILE, "w") as f:
            f.write("Old Cam|rtsp://192.168.1.2/live|admin|pass|some notes\n")
        loaded = config.load_cameras()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0].name, "Old Cam")
        self.assertEqual(loaded[0].group, "")
        self.assertEqual(loaded[0].profile, "main")
        self.assertEqual(loaded[0].audio, True)

    def test_audio_parsing(self) -> None:
        from tvpc_cameras_gui import config
        config.ensure_conf()
        cases = {
            "1": True, "true": True, "yes": True, "on": True,
            "0": False, "false": False, "no": False, "off": False,
            "": True,  # empty defaults to True
        }
        for val, expected in cases.items():
            with open(config.CONF_FILE, "w") as f:
                f.write(f"Cam|rtsp://x|user|pass|notes|group|main|{val}\n")
            loaded = config.load_cameras()
            self.assertEqual(loaded[0].audio, expected, f"audio={val!r}")

    def test_record_path_created(self) -> None:
        from tvpc_cameras_gui import config
        path = config.record_path()
        self.assertTrue(path.exists())
        self.assertTrue(path.is_dir())


class TestRecordingManager(unittest.TestCase):
    def test_disk_usage(self) -> None:
        from tvpc_cameras_gui.recording import RecordingManager
        usage = RecordingManager.disk_usage()
        self.assertIsInstance(usage, str)
        self.assertTrue(usage.endswith("B") or usage.endswith("KB") or usage.endswith("MB"))

    def test_history_empty(self) -> None:
        from tvpc_cameras_gui.recording import RecordingManager
        rm = RecordingManager()
        hist = rm.recording_history()
        self.assertEqual(hist, [])


class TestNotifications(unittest.TestCase):
    def test_send_returns_bool(self) -> None:
        from tvpc_cameras_gui import notifications
        result = notifications.send("Test", "Body")
        self.assertIsInstance(result, bool)

    def test_helpers_return_bool(self) -> None:
        from tvpc_cameras_gui import notifications
        self.assertIsInstance(notifications.send_camera_offline("Cam"), bool)
        self.assertIsInstance(notifications.send_camera_online("Cam"), bool)
        self.assertIsInstance(notifications.send_motion_detected("Cam"), bool)
        self.assertIsInstance(notifications.send_recording_started("Cam"), bool)
        self.assertIsInstance(notifications.send_recording_stopped("Cam"), bool)


class TestHealthWorker(unittest.TestCase):
    def test_no_cameras_no_crash(self) -> None:
        from tvpc_cameras_gui.health import HealthWorker
        w = HealthWorker([], interval=1)
        w.run()  # should return immediately without error

    def test_cancel(self) -> None:
        from tvpc_cameras_gui.health import HealthWorker
        from tvpc_cameras_gui.config import Camera
        cams = [Camera(name="Test", url="rtsp://192.168.1.1/nonexistent")]
        w = HealthWorker(cams, interval=60)
        w.cancel()
        self.assertTrue(w._cancel)


if __name__ == "__main__":
    unittest.main(verbosity=2)
