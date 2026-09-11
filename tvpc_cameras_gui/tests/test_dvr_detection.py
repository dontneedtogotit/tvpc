"""Unit tests for DVR and connected camera detection."""
from __future__ import annotations

import http.server
import json
import os
import socket
import socketserver
import sys
import threading
import unittest
from typing import Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from tvpc_cameras_gui import discover
from tvpc_cameras_gui.scan_dialog import _result_text, _METHOD_ICONS


# ---------------------------------------------------------------------------
# Mock RTSP Multi-Channel Server
# ---------------------------------------------------------------------------
class _MockMultiChannelRtspServer:
    """Answers RTSP DESCRIBE for configured channel paths."""

    def __init__(self, valid_paths: set[str], server_header: str = "Hikvision-Webs") -> None:
        self.valid_paths = valid_paths
        self.server_header = server_header
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.sock.listen(8)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        self.sock.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(2.0)
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 4096:
                chunk = conn.recv(1024)
                if not chunk:
                    break
                data += chunk
            first_line = data.split(b"\r\n")[0].decode("ascii", "replace")
            parts = first_line.split()
            path = ""
            if len(parts) >= 2:
                url = parts[1]
                if "//" in url:
                    path = "/" + url.split("//", 1)[1].split("/", 1)[-1]
                else:
                    path = url

            if path in self.valid_paths:
                sdp = (
                    "v=0\r\n"
                    "o=- 0 0 IN IP4 127.0.0.1\r\n"
                    "s=DVR Stream\r\n"
                    "c=IN IP4 127.0.0.1\r\n"
                    "t=0 0\r\n"
                    "m=video 0 RTP/AVP 96\r\n"
                    "a=rtpmap:96 H264/90000\r\n"
                )
                response = (
                    "RTSP/1.0 200 OK\r\n"
                    "CSeq: 1\r\n"
                    "Content-Type: application/sdp\r\n"
                    f"Server: {self.server_header}\r\n"
                    f"Content-Length: {len(sdp)}\r\n"
                    "\r\n"
                    f"{sdp}"
                )
            else:
                response = (
                    "RTSP/1.0 404 Not Found\r\n"
                    "CSeq: 1\r\n"
                    f"Server: {self.server_header}\r\n"
                    "Content-Length: 0\r\n"
                    "\r\n"
                )
            conn.sendall(response.encode())
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def close(self) -> None:
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        self._thread.join(timeout=1.0)


# ---------------------------------------------------------------------------
# Mock HTTP Handler with routing
# ---------------------------------------------------------------------------
class _MockHttpHandler(http.server.BaseHTTPRequestHandler):
    routes: dict = {}

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        full_path = self.path
        handler_data = self.routes.get(full_path) or self.routes.get(path)
        if handler_data:
            status, ctype, body = handler_data
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode() if isinstance(body, str) else body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args, **kwargs) -> None:
        pass


def _start_http_server(routes: dict) -> Tuple[socketserver.TCPServer, int]:
    class CustomHandler(_MockHttpHandler):
        pass
    CustomHandler.routes = routes
    srv = socketserver.TCPServer(("127.0.0.1", 0), CustomHandler)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    return srv, port


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class TestDvrDataModel(unittest.TestCase):
    """Test DiscoveredCamera model with DVR enhancements."""

    def test_discovered_camera_dvr_fields(self) -> None:
        cam = discover.DiscoveredCamera(
            host="192.168.1.100",
            url="rtsp://192.168.1.100:554/Streaming/Channels/101",
            method="dvr",
            vendor="Hikvision",
            model="DS-7204HGHI-K1",
            note="DVR Channel 1",
            port=554,
            channel=1,
            total_channels=4,
            is_dvr=True,
            dvr_type="Hikvision 4-Channel DVR",
        )
        self.assertTrue(cam.is_dvr)
        self.assertEqual(cam.channel, 1)
        self.assertEqual(cam.total_channels, 4)
        disp = cam.display()
        self.assertIn("Camera 1/4", disp)
        self.assertIn("Hikvision", disp)
        self.assertIn("192.168.1.100:554", disp)

    def test_result_text_dvr_formatting(self) -> None:
        self.assertIn("dvr", _METHOD_ICONS)
        self.assertEqual(_METHOD_ICONS["dvr"], "📼")

        cam = discover.DiscoveredCamera(
            host="192.168.1.50",
            url="rtsp://192.168.1.50:554/cam/realmonitor?channel=2&subtype=0",
            method="dvr",
            vendor="Dahua",
            note="DVR Channel 2 (Driveway)",
            port=554,
            channel=2,
            total_channels=8,
            is_dvr=True,
            dvr_type="Dahua 8-Channel DVR",
        )
        text = _result_text(cam)
        self.assertIn("📼", text)
        self.assertIn("Camera 2/8", text)
        self.assertIn("192.168.1.50", text)


class TestHikvisionDvrDetection(unittest.TestCase):
    """Test Hikvision DVR ISAPI and RTSP channel detection."""

    def test_hikvision_isapi_dvr(self) -> None:
        routes = {
            "/ISAPI/System/deviceInfo": (
                200,
                "application/xml",
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<DeviceInfo version="2.0">\n'
                '  <deviceName>Hikvision DVR</deviceName>\n'
                '  <model>DS-7204HQHI-K1</model>\n'
                '  <firmwareVersion>V4.25.000</firmwareVersion>\n'
                '  <deviceType>DVR</deviceType>\n'
                '</DeviceInfo>'
            ),
            "/ISAPI/Streaming/channels": (
                200,
                "application/xml",
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<StreamingChannelList version="2.0">\n'
                '  <StreamingChannel><id>101</id><channelName>Front Door</channelName><enabled>true</enabled></StreamingChannel>\n'
                '  <StreamingChannel><id>102</id><channelName>Front Door</channelName><enabled>true</enabled></StreamingChannel>\n'
                '  <StreamingChannel><id>201</id><channelName>Backyard</channelName><enabled>true</enabled></StreamingChannel>\n'
                '  <StreamingChannel><id>301</id><channelName>Garage</channelName><enabled>true</enabled></StreamingChannel>\n'
                '  <StreamingChannel><id>401</id><channelName>Driveway</channelName><enabled>true</enabled></StreamingChannel>\n'
                '</StreamingChannelList>'
            ),
        }
        srv, port = _start_http_server(routes)
        try:
            cams = discover.detect_hikvision_dvr("127.0.0.1", rtsp_port=554, http_port=port, timeout=1.0)
            self.assertEqual(len(cams), 4)
            self.assertTrue(all(c.is_dvr for c in cams))
            self.assertEqual(cams[0].channel, 1)
            self.assertEqual(cams[0].url, "rtsp://127.0.0.1:554/Streaming/Channels/101")
            self.assertIn("Front Door", cams[0].note)
            self.assertEqual(cams[1].channel, 2)
            self.assertEqual(cams[1].url, "rtsp://127.0.0.1:554/Streaming/Channels/201")
            self.assertIn("Backyard", cams[1].note)
            self.assertEqual(cams[3].channel, 4)
            self.assertEqual(cams[3].url, "rtsp://127.0.0.1:554/Streaming/Channels/401")
        finally:
            srv.shutdown()
            srv.server_close()

    def test_hikvision_rtsp_fallback_dvr(self) -> None:
        valid_paths = {
            "/Streaming/Channels/101",
            "/Streaming/Channels/201",
            "/Streaming/Channels/301",
            "/Streaming/Channels/401",
        }
        rtsp_srv = _MockMultiChannelRtspServer(valid_paths, server_header="Hikvision-Webs")
        try:
            cams = discover.detect_hikvision_dvr("127.0.0.1", rtsp_port=rtsp_srv.port, http_port=65534, timeout=1.0)
            self.assertEqual(len(cams), 4)
            self.assertEqual(cams[0].channel, 1)
            self.assertEqual(cams[0].url, f"rtsp://127.0.0.1:{rtsp_srv.port}/Streaming/Channels/101")
            self.assertEqual(cams[1].channel, 2)
            self.assertEqual(cams[1].url, f"rtsp://127.0.0.1:{rtsp_srv.port}/Streaming/Channels/201")
            self.assertEqual(cams[3].channel, 4)
            self.assertEqual(cams[3].url, f"rtsp://127.0.0.1:{rtsp_srv.port}/Streaming/Channels/401")
        finally:
            rtsp_srv.close()


class TestDahuaDvrDetection(unittest.TestCase):
    """Test Dahua / Amcrest DVR CGI and RTSP channel detection."""

    def test_dahua_cgi_dvr(self) -> None:
        routes = {
            "/cgi-bin/devInfo.cgi?action=get": (
                200,
                "text/plain",
                "deviceType=XVR\r\nvendor=Dahua\r\nhardwareVersion=1.00\r\n"
            ),
            "/cgi-bin/configManager.cgi?action=getConfig&name=ChannelTitle": (
                200,
                "text/plain",
                "table.ChannelTitle[0].Name=Porch\r\n"
                "table.ChannelTitle[1].Name=Garden\r\n"
                "table.ChannelTitle[2].Name=Side Alley\r\n"
                "table.ChannelTitle[3].Name=Gate\r\n"
            ),
        }
        srv, port = _start_http_server(routes)
        try:
            cams = discover.detect_dahua_dvr("127.0.0.1", rtsp_port=554, http_port=port, timeout=1.0)
            self.assertEqual(len(cams), 4)
            self.assertTrue(all(c.is_dvr for c in cams))
            self.assertEqual(cams[0].channel, 1)
            self.assertEqual(cams[0].url, "rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0")
            self.assertIn("Porch", cams[0].note)
            self.assertEqual(cams[1].channel, 2)
            self.assertIn("Garden", cams[1].note)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_dahua_rtsp_fallback_dvr(self) -> None:
        valid_paths = {
            "/cam/realmonitor?channel=1&subtype=0",
            "/cam/realmonitor?channel=2&subtype=0",
        }
        rtsp_srv = _MockMultiChannelRtspServer(valid_paths, server_header="Dahua RTSP Server")
        try:
            cams = discover.detect_dahua_dvr("127.0.0.1", rtsp_port=rtsp_srv.port, http_port=65534, timeout=1.0)
            self.assertEqual(len(cams), 2)
            self.assertEqual(cams[0].channel, 1)
            self.assertEqual(cams[1].channel, 2)
        finally:
            rtsp_srv.close()


class TestReolinkNvrDetection(unittest.TestCase):
    """Test Reolink NVR API and online channel filtering."""

    def test_reolink_nvr_online_channels_only(self) -> None:
        routes = {
            "/api.cgi?cmd=GetDevInfo": (
                200,
                "application/json",
                json.dumps([{
                    "cmd": "GetDevInfo",
                    "code": 0,
                    "value": {
                        "DevInfo": {
                            "type": "NVR",
                            "model": "RLN8-410",
                            "name": "Home Reolink NVR"
                        }
                    }
                }])
            ),
            "/api.cgi?cmd=GetChannelstatus": (
                200,
                "application/json",
                json.dumps([{
                    "cmd": "GetChannelstatus",
                    "code": 0,
                    "value": {
                        "status": [
                            {"channel": 0, "online": 1, "name": "Front Cam"},
                            {"channel": 1, "online": 1, "name": "Back Cam"},
                            {"channel": 2, "online": 0, "name": ""},
                            {"channel": 3, "online": 0, "name": ""}
                        ]
                    }
                }])
            ),
        }
        srv, port = _start_http_server(routes)
        try:
            cams = discover.detect_reolink_dvr("127.0.0.1", rtsp_port=554, http_port=port, timeout=1.0)
            self.assertEqual(len(cams), 2)
            self.assertEqual(cams[0].channel, 1)
            self.assertEqual(cams[0].url, "rtsp://127.0.0.1:554/h264Preview_01_main")
            self.assertIn("Front Cam", cams[0].note)
            self.assertEqual(cams[1].channel, 2)
            self.assertEqual(cams[1].url, "rtsp://127.0.0.1:554/h264Preview_02_main")
            self.assertIn("Back Cam", cams[1].note)
        finally:
            srv.shutdown()
            srv.server_close()


class TestGenericDvrDetection(unittest.TestCase):
    """Test generic RTSP channel detection and standalone camera non-match."""

    def test_generic_rtsp_dvr_channels(self) -> None:
        valid_paths = {
            "/ch1/main",
            "/ch2/main",
            "/ch3/main",
        }
        rtsp_srv = _MockMultiChannelRtspServer(valid_paths, server_header="Generic-DVR")
        try:
            cams = discover.detect_generic_rtsp_dvr("127.0.0.1", rtsp_port=rtsp_srv.port, timeout=1.0)
            self.assertEqual(len(cams), 3)
            self.assertTrue(all(c.is_dvr for c in cams))
            self.assertEqual(cams[0].channel, 1)
            self.assertEqual(cams[1].channel, 2)
            self.assertEqual(cams[2].channel, 3)
        finally:
            rtsp_srv.close()

    def test_standalone_camera_not_detected_as_dvr(self) -> None:
        valid_paths = {
            "/live/main",
            "/Streaming/Channels/101",
        }
        rtsp_srv = _MockMultiChannelRtspServer(valid_paths, server_header="Standalone-Cam")
        try:
            cams = discover.detect_dvr_channels("127.0.0.1", rtsp_port=rtsp_srv.port, http_port=65534, timeout=0.8)
            self.assertEqual(cams, [])
        finally:
            rtsp_srv.close()


if __name__ == "__main__":
    unittest.main()
