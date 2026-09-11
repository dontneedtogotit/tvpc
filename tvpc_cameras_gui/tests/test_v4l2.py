"""Unit tests for V4L2 USB camera device detection."""
from __future__ import annotations

import os
import struct
import unittest
from unittest.mock import patch, mock_open, MagicMock

from tvpc_cameras_gui.v4l2 import (
    is_v4l2,
    normalize_v4l2_device,
    query_v4l2_device,
    list_v4l2_devices,
)


class TestV4L2(unittest.TestCase):
    def test_is_v4l2(self) -> None:
        self.assertTrue(is_v4l2("/dev/video0"))
        self.assertTrue(is_v4l2("/dev/video12"))
        self.assertTrue(is_v4l2("av://v4l2:/dev/video0"))
        self.assertTrue(is_v4l2("v4l2:///dev/video0"))
        self.assertFalse(is_v4l2("rtsp://192.168.1.100/live"))
        self.assertFalse(is_v4l2("http://192.168.1.100:8080/mjpg"))
        self.assertFalse(is_v4l2(""))

    def test_normalize_v4l2_device(self) -> None:
        self.assertEqual(normalize_v4l2_device("/dev/video0"), "/dev/video0")
        self.assertEqual(normalize_v4l2_device("av://v4l2:/dev/video2"), "/dev/video2")
        self.assertEqual(normalize_v4l2_device("v4l2:///dev/video1"), "/dev/video1")
        self.assertEqual(normalize_v4l2_device("rtsp://192.168.1.1/live"), "rtsp://192.168.1.1/live")

    @patch("tvpc_cameras_gui.v4l2.fcntl.ioctl")
    @patch("tvpc_cameras_gui.v4l2.os.open")
    @patch("tvpc_cameras_gui.v4l2.os.close")
    @patch("tvpc_cameras_gui.v4l2.os.path.exists", return_value=True)
    def test_query_v4l2_device_capture(self, mock_exists, mock_close, mock_open_fd, mock_ioctl) -> None:
        mock_open_fd.return_value = 3

        def fake_ioctl(fd, req, buf):
            # driver(16), card(32), bus_info(32), version(4), capabilities(4), device_caps(4), reserved(12)
            card = b"USB Camera HD\x00".ljust(32, b"\x00")
            driver = b"uvcvideo\x00".ljust(16, b"\x00")
            bus = b"usb-0000:00:14.0\x00".ljust(32, b"\x00")
            version = 0x00050400
            # V4L2_CAP_VIDEO_CAPTURE = 0x00000001
            # V4L2_CAP_DEVICE_CAPS = 0x80000000
            caps = 0x80000001
            device_caps = 0x00000001
            reserved = b"\x00" * 12
            packed = driver + card + bus + struct.pack("=III", version, caps, device_caps) + reserved
            buf[:] = packed
            return 0

        mock_ioctl.side_effect = fake_ioctl

        res = query_v4l2_device("/dev/video0")
        self.assertIsNotNone(res)
        self.assertEqual(res["device"], "/dev/video0")
        self.assertEqual(res["name"], "USB Camera HD")
        self.assertEqual(res["driver"], "uvcvideo")
        self.assertTrue(res["is_capture"])

    @patch("tvpc_cameras_gui.v4l2.fcntl.ioctl")
    @patch("builtins.open")
    @patch("pathlib.Path.exists", return_value=True)
    def test_query_v4l2_device_metadata_only(self, mock_exists, mock_open_file, mock_ioctl) -> None:
        def fake_ioctl(fd, req, buf):
            card = b"USB Camera Metadata\x00".ljust(32, b"\x00")
            driver = b"uvcvideo\x00".ljust(16, b"\x00")
            bus = b"usb-0000:00:14.0\x00".ljust(32, b"\x00")
            version = 0x00050400
            # V4L2_CAP_META_CAPTURE = 0x00800000
            caps = 0x80000000
            device_caps = 0x00800000
            reserved = b"\x00" * 12
            packed = driver + card + bus + struct.pack("=III", version, caps, device_caps) + reserved
            buf[:] = packed
            return 0

        mock_ioctl.side_effect = fake_ioctl

        res = query_v4l2_device("/dev/video1")
        self.assertIsNotNone(res)
        self.assertFalse(res["is_capture"])

    @patch("pathlib.Path.is_dir", return_value=True)
    @patch("pathlib.Path.iterdir")
    @patch("tvpc_cameras_gui.v4l2.query_v4l2_device")
    def test_list_v4l2_devices_capture_only(self, mock_query, mock_iterdir, mock_is_dir) -> None:
        m0 = MagicMock()
        m0.name = "video0"
        m1 = MagicMock()
        m1.name = "video1"
        mock_iterdir.return_value = [m0, m1]

        mock_query.side_effect = lambda p: {
            "/dev/video0": {"device": "/dev/video0", "name": "Cam0", "is_capture": True},
            "/dev/video1": {"device": "/dev/video1", "name": "Cam1-Meta", "is_capture": False},
        }.get(p)

        cams = list_v4l2_devices(capture_only=True)
        self.assertEqual(len(cams), 1)
        self.assertEqual(cams[0]["device"], "/dev/video0")

        all_cams = list_v4l2_devices(capture_only=False)
        self.assertEqual(len(all_cams), 2)


if __name__ == "__main__":
    unittest.main()
