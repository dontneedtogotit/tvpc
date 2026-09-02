"""Loopback tests for the network discovery primitives.

These tests do not touch the network. They spin up tiny in-process RTSP
and HTTP servers on 127.0.0.1, then verify that the discovery code in
tvpc_cameras_gui.discover correctly identifies them.
"""
from __future__ import annotations

import http.server
import socket
import socketserver
import threading
import time
import unittest
from typing import Tuple


# Bring the package in via sys.path when running this file directly.
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tvpc_cameras_gui import discover  # noqa: E402


# ---------------------------------------------------------------------------
# Mock RTSP server
# ---------------------------------------------------------------------------
class _MockRtspServer:
    """Answers DESCRIBE with a Hikvision-looking response and 200/OK."""

    SDP = (
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=Hikvision RTSP Server\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        "m=video 0 RTP/AVP 96\r\n"
        "a=rtpmap:96 H264/90000\r\n"
    )

    def __init__(self) -> None:
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
                return  # socket closed during shutdown
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
            request_line = data.split(b"\r\n", 1)[0].decode("ascii", "replace")
            # Hikvision: Server header reveals vendor in the body.
            response = (
                "RTSP/1.0 200 OK\r\n"
                "CSeq: 1\r\n"
                "Content-Type: application/sdp\r\n"
                "Server: Hikvision-Webs\r\n"
                f"Content-Length: {len(self.SDP)}\r\n"
                "\r\n"
            ) + self.SDP
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
# Mock HTTP server (Hikvision ISAPI)
# ---------------------------------------------------------------------------
class _MockHttpHandler(http.server.BaseHTTPRequestHandler):
    ROUTES = {
        "/ISAPI/Streaming/channels": "Hikvision streaming XML",
        "/ISAPI/System/deviceInfo": "<DeviceInfo><firmware>5.7.10</firmware></DeviceInfo>",
    }

    def log_message(self, *_args, **_kwargs) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        body = self.ROUTES.get(self.path)
        if body is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body_bytes = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Server", "Hikvision-Webs")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)


class _MockHttpServer:
    def __init__(self) -> None:
        self.httpd = socketserver.TCPServer(("127.0.0.1", 0), _MockHttpHandler)
        self.port = self.httpd.server_address[1]
        self._thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self._thread.start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self._thread.join(timeout=1.0)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class TestRtsp(unittest.TestCase):
    def test_describe(self) -> None:
        s = _MockRtspServer()
        try:
            info = discover.rtsp_describe("127.0.0.1", s.port, "/Streaming/Channels/101",
                                          timeout=2.0)
            self.assertIsNotNone(info, "DESCRIBE returned None")
            self.assertIn("Hikvision", info["server"])
            self.assertIn("Hikvision", info["body"])
            vendor = discover.identify_vendor_from_rtsp(info)
            self.assertEqual(vendor, "Hikvision")
        finally:
            s.close()

    def test_probe_paths(self) -> None:
        s = _MockRtspServer()
        try:
            cam = discover.rtsp_probe_paths(
                "127.0.0.1", s.port,
                paths=["/nope", "/also-nope", "/Streaming/Channels/101"],
                timeout=2.0,
            )
            self.assertIsNotNone(cam)
            assert cam is not None
            self.assertEqual(cam.method, "rtsp")
            self.assertEqual(cam.vendor, "Hikvision")
            self.assertIn("127.0.0.1", cam.host)
        finally:
            s.close()


class TestHttp(unittest.TestCase):
    def test_probe_finds_hikvision(self) -> None:
        s = _MockHttpServer()
        try:
            cams = discover.http_probe("127.0.0.1", s.port, timeout=2.0)
            self.assertGreater(len(cams), 0, "no HTTP probe matched")
            urls = {c.url for c in cams}
            self.assertTrue(
                any("/ISAPI/Streaming/channels" in u for u in urls),
                f"no Hikvision stream URL found in {urls}",
            )
            vendors = {c.vendor for c in cams}
            self.assertIn("Hikvision", vendors)
        finally:
            s.close()


class TestSubnetMath(unittest.TestCase):
    def test_hosts_in(self) -> None:
        from ipaddress import IPv4Network
        n = IPv4Network("192.168.1.0/24")
        hosts = list(discover.hosts_in(n))
        self.assertEqual(len(hosts), 254)
        self.assertEqual(hosts[0], "192.168.1.1")
        self.assertEqual(hosts[-1], "192.168.1.254")

    def test_parallel_tcp(self) -> None:
        s = _MockRtspServer()
        try:
            hosts = [f"127.0.0.1" for _ in range(8)]
            hits = discover.parallel_tcp_open(hosts, s.port, workers=4)
            self.assertIn("127.0.0.1", hits)
        finally:
            s.close()


class TestMdnsParser(unittest.TestCase):
    def test_query_and_response(self) -> None:
        # Build a fake mDNS response with one PTR answer. Format:
        #   header (12 bytes)
        #   question: _rtsp._tcp.local PTR IN
        #   answer:   Front Door._rtsp._tcp.local PTR IN 10
        #             "Front Door._rtsp._tcp.local"
        def _enc(labels: str) -> bytes:
            out = b""
            for label in labels.split("."):
                out += bytes([len(label)]) + label.encode()
            return out + b"\x00"
        qname = _enc("_rtsp._tcp.local")
        aname = _enc("Front Door._rtsp._tcp.local")
        header = b"\xaa\xbb\x85\x00"      # standard response, AA
        header += b"\x00\x01"             # QDCOUNT = 1
        header += b"\x00\x01"             # ANCOUNT = 1
        header += b"\x00\x00\x00\x00"     # NS/AR counts
        question = qname + b"\x00\x0c\x00\x01"
        answer = aname + b"\x00\x0c\x00\x01\x00\x00\x00\x0a" \
                 + len(aname).to_bytes(2, "big") + aname
        pkt = header + question + answer
        names = discover._parse_dns_ptr_answers(pkt)
        self.assertEqual(len(names), 1)
        self.assertTrue(names[0].startswith("Front Door._rtsp._tcp.local"))

    def test_query_construction(self) -> None:
        pkt = discover._build_dns_query("_rtsp._tcp.local")
        # header (12) + qname + qtype(2) + qclass(2)
        self.assertGreaterEqual(len(pkt), 12)
        # transaction id is arbitrary but non-zero
        self.assertNotEqual(pkt[:2], b"\x00\x00")


class TestScanWorkerEndToEnd(unittest.TestCase):
    """Full ScanWorker pipeline against an in-process mock RTSP server."""

    def test_finds_mock_on_alt_port(self) -> None:
        from PySide6.QtWidgets import QApplication
        import socket as _socket
        import threading as _threading

        # Pick a high port for the mock and bind to it before any other
        # test gets a chance to grab it.
        sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        for port in (8554, 10554, 11554, 12554):
            try:
                sock.bind(("127.0.0.1", port))
                break
            except OSError:
                continue
        else:
            self.skipTest("no free high port for mock RTSP server")
        sock.listen(8)
        sock.settimeout(0.2)
        bound_port = sock.getsockname()[1]

        sdp = ("v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Dahua RTSP Server\r\n"
               "c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=video 0 RTP/AVP 96\r\n"
               "a=rtpmap:96 H264/90000\r\n")

        def _handle(conn: "_socket.socket") -> None:
            try:
                conn.settimeout(2.0)
                data = b""
                while b"\r\n\r\n" not in data and len(data) < 4096:
                    chunk = conn.recv(1024)
                    if not chunk:
                        break
                    data += chunk
                resp = ("RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
                        "Content-Type: application/sdp\r\n"
                        "Server: Dahua\r\n"
                        f"Content-Length: {len(sdp)}\r\n\r\n{sdp}").encode()
                conn.sendall(resp)
            except OSError:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

        stop = _threading.Event()

        def _serve() -> None:
            while not stop.is_set():
                try:
                    conn, _ = sock.accept()
                except _socket.timeout:
                    continue
                except OSError:
                    return
                _threading.Thread(target=_handle, args=(conn,), daemon=True).start()
            sock.close()

        _threading.Thread(target=_serve, daemon=True).start()
        try:
            # Add the bound port to the RTSP ports so the parallel sweep
            # finds it. Restore the original list when done.
            from tvpc_cameras_gui import discover
            from tvpc_cameras_gui.scan import ScanWorker
            old_ports = discover.RTSP_PORTS
            discover.RTSP_PORTS = (bound_port, *old_ports)
            try:
                # Run synchronously: no QThread, no app.exec(). The worker
                # is a QObject but its signals can be emitted directly when
                # the slot is on the same thread as the caller.
                QApplication.instance() or QApplication.instance()
                worker = ScanWorker(cidr="127.0.0.1/32", workers=16, do_onvif_enrich=False)
                found: list = []
                worker.found.connect(lambda c: found.append(c))
                worker.finished.connect(lambda: None)  # nothing — we just collect
                worker.run()
            finally:
                discover.RTSP_PORTS = old_ports
            self.assertGreater(len(found), 0, "ScanWorker did not find the mock RTSP server")
            self.assertTrue(any(c.vendor == "Dahua" for c in found),
                            f"Dahua not identified: {found}")
        finally:
            stop.set()
            time.sleep(0.2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
