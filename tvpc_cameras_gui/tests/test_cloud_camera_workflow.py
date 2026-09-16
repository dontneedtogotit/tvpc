"""Tests for cloud-only cameras and ONVIF/RTSP activation workflow."""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from PySide6.QtWidgets import QApplication, QListWidgetItem
from PySide6.QtCore import Qt

from tvpc_cameras_gui.discover import DiscoveredCamera
from tvpc_cameras_gui.brand_help import (
    get_brand_template_url,
    find_brand_guide,
    BRAND_GUIDES,
)
from tvpc_cameras_gui.scan_dialog import _result_text, _SingleProbeWorker


app = QApplication.instance() or QApplication([])


class TestCloudCameraWorkflow(unittest.TestCase):
    def test_get_brand_template_url_tuya(self) -> None:
        url, user = get_brand_template_url("Tuya / Orion / Grid Connect", "192.168.1.50")
        self.assertEqual(url, "rtsp://192.168.1.50:554/live/ch0")
        self.assertEqual(user, "admin")

    def test_get_brand_template_url_tapo(self) -> None:
        url, user = get_brand_template_url("TP-Link Tapo C200", "192.168.1.60", user="myuser")
        self.assertEqual(url, "rtsp://192.168.1.60:554/stream1")
        self.assertEqual(user, "myuser")

    def test_get_brand_template_url_reolink(self) -> None:
        url, user = get_brand_template_url("Reolink E1", "192.168.1.70")
        self.assertIn("h264Preview_01_main", url)
        self.assertEqual(user, "admin")

    def test_get_brand_template_url_hikvision(self) -> None:
        url, user = get_brand_template_url("Hikvision", "192.168.1.80")
        self.assertIn("/Streaming/Channels/101", url)
        self.assertEqual(user, "admin")

    def test_get_brand_template_url_dahua(self) -> None:
        url, user = get_brand_template_url("Dahua", "192.168.1.90")
        self.assertIn("/cam/realmonitor", url)
        self.assertEqual(user, "admin")

    def test_get_brand_template_url_generic_fallback(self) -> None:
        url, user = get_brand_template_url("UnknownBrandXYZ", "192.168.1.100")
        self.assertIn("rtsp://192.168.1.100", url)
        self.assertEqual(user, "admin")

    def test_result_text_badges_cloud_camera(self) -> None:
        cam_cloud = DiscoveredCamera(
            host="192.168.1.50",
            url="",
            method="cloud",
            vendor="Orion / Tuya",
            mac="aa:bb:cc:dd:ee:ff",
            note="Cloud-only Tuya port 6668 detected",
        )
        text = _result_text(cam_cloud)
        self.assertIn("⚠️ [Needs Local ONVIF/RTSP]", text)
        self.assertIn("192.168.1.50", text)
        self.assertIn("Orion / Tuya", text)

        cam_active = DiscoveredCamera(
            host="192.168.1.50",
            url="rtsp://192.168.1.50:554/live/ch0",
            method="rtsp",
            vendor="Orion / Tuya",
        )
        text_active = _result_text(cam_active)
        self.assertNotIn("⚠️ [Needs Local ONVIF/RTSP]", text_active)
        self.assertIn("192.168.1.50", text_active)

    @patch("tvpc_cameras_gui.discover.probe_ip_stream_url")
    def test_single_probe_worker_success(self, mock_probe: MagicMock) -> None:
        mock_probe.return_value = ("rtsp://192.168.1.50:554/live/ch0", "Tuya", "IPC")

        cam = DiscoveredCamera(host="192.168.1.50", url="", method="cloud", vendor="Tuya")
        item = QListWidgetItem()
        worker = _SingleProbeWorker([(item, cam)], user="admin", password="123")

        results = []
        worker.result.connect(lambda it, c: results.append((it, c)))
        worker.run()

        self.assertEqual(len(results), 1)
        it, updated_cam = results[0]
        self.assertIsNotNone(updated_cam)
        self.assertEqual(updated_cam.url, "rtsp://192.168.1.50:554/live/ch0")
        self.assertEqual(updated_cam.method, "rtsp")

    @patch("tvpc_cameras_gui.discover.quick_probe_all_ports")
    @patch("tvpc_cameras_gui.discover.probe_ip_stream_url")
    def test_single_probe_worker_failure(self, mock_probe: MagicMock, mock_quick: MagicMock) -> None:
        mock_probe.return_value = None
        mock_quick.return_value = []

        cam = DiscoveredCamera(host="192.168.1.50", url="", method="cloud", vendor="Tuya")
        item = QListWidgetItem()
        worker = _SingleProbeWorker([(item, cam)], user="admin", password="123")

        results = []
        worker.result.connect(lambda it, c: results.append((it, c)))
        worker.run()

        self.assertEqual(len(results), 1)
        it, updated_cam = results[0]
        self.assertIsNone(updated_cam)


if __name__ == "__main__":
    unittest.main()
