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


class TestRecordingCredentials(unittest.TestCase):
    def test_inject_credentials(self) -> None:
        from tvpc_cameras_gui.recording import _inject_credentials, _build_record_cmd
        from tvpc_cameras_gui.config import Camera
        from pathlib import Path

        # RTSP without credentials
        url = _inject_credentials("rtsp://192.168.1.50:554/live", "admin", "secret123")
        self.assertEqual(url, "rtsp://admin:secret123@192.168.1.50:554/live")

        # RTSP with existing credentials should not double-inject
        url_already = _inject_credentials("rtsp://user:pass@192.168.1.50:554/live", "admin", "secret")
        self.assertEqual(url_already, "rtsp://user:pass@192.168.1.50:554/live")

        # HTTP should pass through
        url_http = _inject_credentials("http://192.168.1.50/video.mjpg", "admin", "secret")
        self.assertEqual(url_http, "http://192.168.1.50/video.mjpg")

        # Command build check
        cam = Camera(name="TestCam", url="rtsp://192.168.1.50/h264", user="adm", password="pwd")
        cmd = _build_record_cmd(cam, Path("/tmp/out.mkv"))
        self.assertIn("rtsp://adm:pwd@192.168.1.50/h264", cmd)


class TestDialogs(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import os
        os.environ["QT_QPA_PLATFORM"] = "offscreen"
        from PySide6.QtWidgets import QApplication
        cls._app = QApplication.instance() or QApplication([])

    def test_scan_dialog_instantiation_and_filtering(self) -> None:
        from tvpc_cameras_gui.scan_dialog import ScanDialog
        from tvpc_cameras_gui.discover import DiscoveredCamera
        dlg = ScanDialog()
        self.assertIsNotNone(dlg._progress)
        self.assertIsNotNone(dlg._filter_edit)
        self.assertIsNotNone(dlg._adv_group)

        # Test adding a discovered camera and filter
        cam = DiscoveredCamera(method="rtsp", host="192.168.1.100", port=554, url="rtsp://192.168.1.100/live", vendor="Hikvision")
        dlg._on_found(cam)
        self.assertEqual(dlg._list.count(), 1)

        # Test select all
        dlg._select_all()
        self.assertEqual(len(dlg._list.selectedItems()), 1)
        self.assertTrue(dlg._add_btn.isEnabled())

        # Test filter
        dlg._filter_edit.setText("nonexistent")
        self.assertTrue(dlg._list.item(0).isHidden())
        dlg._filter_edit.setText("hikvision")
        self.assertFalse(dlg._list.item(0).isHidden())

    def test_edit_dialog_presets(self) -> None:
        from tvpc_cameras_gui.edit_dialog import CameraEditDialog
        dlg = CameraEditDialog()
        self.assertIsNotNone(dlg._test_btn)
        self.assertIsNotNone(dlg._preset_combo)

        # Choose a preset
        dlg._preset_combo.setCurrentIndex(1)
        self.assertIn("Streaming/Channels/101", dlg._url.text())

        # Verify Tuya presets exist
        presets_text = [dlg._preset_combo.itemText(i) for i in range(dlg._preset_combo.count())]
        self.assertTrue(any("Tuya" in p for p in presets_text), f"Tuya preset not in {presets_text}")

    def test_scan_dialog_cloud_camera_item(self) -> None:
        from tvpc_cameras_gui.scan_dialog import ScanDialog
        from tvpc_cameras_gui.discover import DiscoveredCamera
        dlg = ScanDialog()
        cloud_cam = DiscoveredCamera(
            method="cloud",
            host="192.168.0.185",
            url="",
            vendor="Orion / Tuya / Grid Connect",
            note="Cloud-only (Tuya port 6668 detected).",
        )
        dlg._on_found(cloud_cam)
        self.assertEqual(dlg._list.count(), 1)
        item = dlg._list.item(0)
        self.assertIn("192.168.0.185", item.text())
        self.assertIn("Orion / Tuya / Grid Connect", item.text())

    def test_recording_history_dialog(self) -> None:
        from tvpc_cameras_gui.recording_history import RecordingHistoryDialog
        dlg = RecordingHistoryDialog()
        self.assertIsNotNone(dlg._play_btn)
        self.assertIsNotNone(dlg._open_btn)
        self.assertIsNotNone(dlg._delete_btn)


if __name__ == "__main__":
    unittest.main(verbosity=2)
