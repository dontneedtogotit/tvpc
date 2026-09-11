"""Unit tests for PTZ client and dialog."""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from PySide6.QtWidgets import QApplication

from tvpc_cameras_gui.config import Camera
from tvpc_cameras_gui.ptz import PtzClient, PtzDialog, _create_wsse_header

app = QApplication.instance() or QApplication([])


class TestPtz(unittest.TestCase):
    def setUp(self) -> None:
        self.camera = Camera(
            name="Backyard PTZ",
            url="rtsp://192.168.1.120:554/live",
            user="admin",
            password="secretpassword",
        )
        self.client = PtzClient(self.camera)

    def test_create_wsse_header(self) -> None:
        empty = _create_wsse_header("", "")
        self.assertEqual(empty, "")

        header = _create_wsse_header("admin", "12345")
        self.assertIn("<wsse:Security", header)
        self.assertIn("<wsse:Username>admin</wsse:Username>", header)
        self.assertIn("PasswordDigest", header)
        self.assertIn("Nonce", header)

    def test_ptz_client_host_parsing(self) -> None:
        self.assertEqual(self.client.host, "192.168.1.120")
        # 554 is mapped to default HTTP port 80 for ONVIF/CGI
        self.assertEqual(self.client.port, 80)

    @patch("urllib.request.urlopen")
    def test_do_move_onvif_success(self, mock_urlopen) -> None:
        mock_resp = MagicMock()
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        self.client._do_move(pan=0.5, tilt=0.0, zoom=0.0)
        self.assertTrue(mock_urlopen.called)
        req = mock_urlopen.call_args[0][0]
        self.assertIn("http://192.168.1.120", req.full_url)
        self.assertEqual(req.method, "POST")
        self.assertIn("ContinuousMove", req.data.decode("utf-8"))

    @patch("urllib.request.urlopen")
    def test_do_move_cgi_fallback(self, mock_urlopen) -> None:
        # First calls fail (ONVIF), then Dahua CGI succeeds
        calls = []

        def fake_urlopen(req, timeout=1.0):
            calls.append(req.full_url)
            if "cgi-bin/ptz.cgi" in req.full_url:
                mock_resp = MagicMock()
                mock_resp.__enter__.return_value = mock_resp
                return mock_resp
            raise OSError("ONVIF port closed")

        mock_urlopen.side_effect = fake_urlopen
        self.client._do_move(pan=0.0, tilt=1.0, zoom=0.0)

        # Check that Dahua CGI fallback was reached with code=Up
        cgi_calls = [u for u in calls if "cgi-bin/ptz.cgi" in u]
        self.assertTrue(len(cgi_calls) > 0)
        self.assertIn("code=Up", cgi_calls[0])

    @patch("urllib.request.urlopen")
    def test_do_stop(self, mock_urlopen) -> None:
        mock_resp = MagicMock()
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        self.client._do_stop()
        self.assertTrue(mock_urlopen.called)
        req = mock_urlopen.call_args[0][0]
        self.assertIn("Stop", req.data.decode("utf-8"))

    def test_ptz_dialog_init(self) -> None:
        dlg = PtzDialog(camera=self.camera)
        self.assertIn("Backyard PTZ", dlg.windowTitle())
        self.assertIsNotNone(dlg.client)


if __name__ == "__main__":
    unittest.main()
