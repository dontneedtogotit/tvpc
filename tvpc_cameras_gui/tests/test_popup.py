"""Unit tests for SmartPopupManager."""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from PySide6.QtWidgets import QApplication

from tvpc_cameras_gui.config import Camera
from tvpc_cameras_gui.popup import SmartPopupManager

app = QApplication.instance() or QApplication([])


class TestSmartPopup(unittest.TestCase):
    def setUp(self) -> None:
        self.cam = Camera(name="Front Door", url="rtsp://192.168.1.10/live")
        self.mgr = SmartPopupManager(duration_seconds=10.0, cooldown_seconds=5.0, sound_enabled=False)

    def tearDown(self) -> None:
        self.mgr.close_popup()

    def test_init_inactive(self) -> None:
        self.assertFalse(self.mgr.is_active())

    @patch("shutil.which", return_value="/usr/bin/mpv")
    @patch("subprocess.Popen")
    def test_trigger_popup_spawns_process(self, mock_popen, mock_which) -> None:
        mock_proc = MagicMock()
        mock_proc.poll.return_value = None
        mock_popen.return_value = mock_proc

        opened = []
        self.mgr.popup_opened.connect(lambda name: opened.append(name))

        res = self.mgr.trigger_popup(self.cam)
        self.assertTrue(res)
        self.assertTrue(self.mgr.is_active())
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0], "Front Door")

        # Second trigger within cooldown should return False
        res2 = self.mgr.trigger_popup(self.cam, force=False)
        self.assertFalse(res2)

        # Force trigger bypasses cooldown
        res3 = self.mgr.trigger_popup(self.cam, force=True)
        self.assertTrue(res3)

    @patch("shutil.which", return_value="/usr/bin/mpv")
    @patch("subprocess.Popen")
    def test_close_popup(self, mock_popen, mock_which) -> None:
        mock_proc = MagicMock()
        mock_proc.poll.return_value = None
        mock_popen.return_value = mock_proc

        closed = []
        self.mgr.popup_closed.connect(lambda name: closed.append(name))

        self.mgr.trigger_popup(self.cam)
        self.mgr.close_popup()

        self.assertTrue(mock_proc.terminate.called)
        self.assertEqual(len(closed), 1)
        self.assertEqual(closed[0], "Front Door")
        self.assertFalse(self.mgr.is_active())


if __name__ == "__main__":
    unittest.main()
