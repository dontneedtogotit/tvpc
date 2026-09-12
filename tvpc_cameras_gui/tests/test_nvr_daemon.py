"""Unit tests for NvrDaemon coordinator."""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from PySide6.QtCore import QCoreApplication

from tvpc_cameras_gui.config import Camera
from tvpc_cameras_gui.nvr_daemon import NvrDaemon

app = QCoreApplication.instance() or QCoreApplication([])


class TestNvrDaemon(unittest.TestCase):
    @patch("tvpc_cameras_gui.nvr_daemon.cfg.load_cameras")
    @patch("tvpc_cameras_gui.nvr_daemon.load_settings")
    @patch("tvpc_cameras_gui.nvr_daemon.load_bosch_config")
    def setUp(self, mock_bosch_cfg, mock_settings, mock_cams) -> None:
        mock_settings.return_value = {
            "popup_on_motion": True,
            "popup_duration": 10.0,
            "max_storage_gb": 10.0,
            "max_retention_days": 7,
            "min_free_space_gb": 2.0,
        }
        mock_cams.return_value = [
            Camera(name="Front Door", url="rtsp://192.168.1.10/live"),
            Camera(name="Driveway", url="rtsp://192.168.1.20/live"),
        ]
        bcfg = MagicMock()
        bcfg.enabled = False
        mock_bosch_cfg.return_value = bcfg

        self.daemon = NvrDaemon()

    def tearDown(self) -> None:
        self.daemon.stop()

    def test_daemon_initialization(self) -> None:
        self.assertIsNotNone(self.daemon.storage)
        self.assertIsNotNone(self.daemon.popup_mgr)
        self.assertIsNotNone(self.daemon.motion_detector)
        self.assertIsNotNone(self.daemon.bosch_client)

    @patch("tvpc_cameras_gui.nvr_daemon.cfg.load_cameras")
    def test_on_motion_triggers_popup(self, mock_cams) -> None:
        cam = Camera(name="Front Door", url="rtsp://192.168.1.10/live")
        mock_cams.return_value = [cam]

        self.daemon.popup_mgr.trigger_popup = MagicMock(return_value=True)
        self.daemon._on_motion_detected("Front Door", 0.35)

        self.assertTrue(self.daemon.popup_mgr.trigger_popup.called)
        self.assertEqual(self.daemon.popup_mgr.trigger_popup.call_args[0][0].name, "Front Door")

    @patch("tvpc_cameras_gui.nvr_daemon.cfg.load_cameras")
    def test_on_bosch_zone_triggers_forced_popup_and_recording(self, mock_cams) -> None:
        cam = Camera(name="Driveway", url="rtsp://192.168.1.20/live")
        mock_cams.return_value = [cam]

        self.daemon.popup_mgr.trigger_popup = MagicMock(return_value=True)
        self.daemon.recording_mgr.start_recording = MagicMock()

        self.daemon._on_bosch_zone(2, "Burglary Alarm", "Driveway")

        self.assertTrue(self.daemon.popup_mgr.trigger_popup.called)
        # Verify force=True was passed so alarm bypasses motion cooldown
        self.assertTrue(self.daemon.popup_mgr.trigger_popup.call_args[1].get("force"))
        self.assertTrue(self.daemon.recording_mgr.start_recording.called)


if __name__ == "__main__":
    unittest.main()
