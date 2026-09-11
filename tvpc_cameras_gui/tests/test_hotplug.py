"""Unit tests for HotplugMonitor."""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from PySide6.QtWidgets import QApplication

from tvpc_cameras_gui.discover import DiscoveredCamera
from tvpc_cameras_gui.hotplug import HotplugMonitor

app = QApplication.instance() or QApplication([])


class TestHotplugMonitor(unittest.TestCase):
    @patch("tvpc_cameras_gui.hotplug.cfg.load_cameras", return_value=[])
    @patch("tvpc_cameras_gui.hotplug.list_v4l2_devices", return_value=[{"device": "/dev/video0", "name": "Webcam 1"}])
    def test_init_seeds_devices(self, mock_v4l2, mock_cams) -> None:
        monitor = HotplugMonitor(enable_network_watch=False)
        self.assertIn("/dev/video0", monitor._known_v4l2)

    @patch("tvpc_cameras_gui.hotplug.cfg.load_cameras", return_value=[])
    @patch("tvpc_cameras_gui.hotplug.list_v4l2_devices")
    def test_detects_plugged_and_unplugged_v4l2(self, mock_v4l2, mock_cams) -> None:
        # Initial: only /dev/video0
        mock_v4l2.return_value = [{"device": "/dev/video0", "name": "Webcam 1"}]
        monitor = HotplugMonitor(enable_network_watch=False)

        plugged = []
        unplugged = []
        monitor.v4l2_plugged.connect(lambda d: plugged.append(d))
        monitor.v4l2_unplugged.connect(lambda p: unplugged.append(p))

        # Plug in /dev/video2
        mock_v4l2.return_value = [
            {"device": "/dev/video0", "name": "Webcam 1"},
            {"device": "/dev/video2", "name": "USB Capture Card"},
        ]
        monitor._on_tick()

        self.assertEqual(len(plugged), 1)
        self.assertEqual(plugged[0]["device"], "/dev/video2")
        self.assertEqual(len(unplugged), 0)

        # Unplug /dev/video0
        mock_v4l2.return_value = [
            {"device": "/dev/video2", "name": "USB Capture Card"},
        ]
        monitor._on_tick()

        self.assertEqual(len(unplugged), 1)
        self.assertEqual(unplugged[0], "/dev/video0")

    @patch("tvpc_cameras_gui.hotplug.disc.quick_probe_all_ports")
    @patch("tvpc_cameras_gui.hotplug.disc.arp_hosts", return_value=["192.168.1.188"])
    @patch("tvpc_cameras_gui.hotplug.cfg.load_cameras", return_value=[])
    @patch("tvpc_cameras_gui.hotplug.list_v4l2_devices", return_value=[])
    def test_scan_arp_changes_emits_discovered(self, mock_v4l2, mock_cams, mock_arp, mock_probe) -> None:
        monitor = HotplugMonitor(enable_network_watch=False)

        discovered = []
        monitor.camera_discovered.connect(lambda c: discovered.append(c))

        mock_probe.return_value = [
            DiscoveredCamera(
                method="rtsp",
                host="192.168.1.188",
                url="rtsp://192.168.1.188:554/live",
                vendor="Generic RTSP",
            )
        ]

        monitor._scan_arp_changes()
        self.assertEqual(len(discovered), 1)
        self.assertEqual(discovered[0].url, "rtsp://192.168.1.188:554/live")


if __name__ == "__main__":
    unittest.main()
