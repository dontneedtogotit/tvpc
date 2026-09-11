"""Local V4L2 / USB webcam and capture device helpers."""
from __future__ import annotations

import fcntl
import os
from pathlib import Path
import struct
from typing import Any, Dict, List, Optional


VIDIOC_QUERYCAP = 0x80685600
V4L2_CAP_VIDEO_CAPTURE = 0x00000001
V4L2_CAP_VIDEO_CAPTURE_MPLANE = 0x00001000
V4L2_CAP_DEVICE_CAPS = 0x80000000


def is_v4l2(url: str) -> bool:
    """Return True if the URL refers to a local V4L2 video device."""
    clean = url.strip()
    return clean.startswith("/dev/video") or clean.startswith("v4l2://") or clean.startswith("av://v4l2:")


def normalize_v4l2_device(url: str) -> str:
    """Convert any v4l2 URL representation into a clean path like /dev/video0."""
    clean = url.strip()
    if clean.startswith("v4l2://"):
        clean = clean[len("v4l2://"):]
    elif clean.startswith("av://v4l2:"):
        clean = clean[len("av://v4l2:"):]
    return clean


def mpv_v4l2_url(url: str) -> str:
    """Return the URL formatted for mpv playback of a V4L2 device."""
    dev = normalize_v4l2_device(url)
    return f"av://v4l2:{dev}"


def query_v4l2_device(device_path: str) -> Optional[Dict[str, Any]]:
    """Query V4L2 device capabilities and driver information.

    Returns a dict with driver, card, bus_info, and is_capture flag,
    or None if the device cannot be queried.
    """
    dev_path = Path(device_path)
    if not dev_path.exists():
        return None

    dev_name = dev_path.name
    sysfs_name_path = Path("/sys/class/video4linux") / dev_name / "name"
    sysfs_name = ""
    if sysfs_name_path.exists():
        try:
            sysfs_name = sysfs_name_path.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            pass

    card_name = sysfs_name or dev_name
    driver_name = ""
    bus_info = ""
    is_capture = False

    try:
        with open(device_path, "rb") as f:
            buf = bytearray(104)
            fcntl.ioctl(f.fileno(), VIDIOC_QUERYCAP, buf)
            driver_raw, card_raw, bus_raw, _ver, caps, dev_caps = struct.unpack("16s32s32sIII", buf[:92])
            driver_name = driver_raw.split(b"\x00")[0].decode("utf-8", errors="replace").strip()
            decoded_card = card_raw.split(b"\x00")[0].decode("utf-8", errors="replace").strip()
            if decoded_card:
                card_name = decoded_card
            bus_info = bus_raw.split(b"\x00")[0].decode("utf-8", errors="replace").strip()

            effective_caps = dev_caps if (caps & V4L2_CAP_DEVICE_CAPS) else caps
            is_capture = bool(effective_caps & (V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_VIDEO_CAPTURE_MPLANE))
    except Exception:
        if sysfs_name and not is_capture:
            is_capture = True

    return {
        "device": device_path,
        "name": card_name,
        "driver": driver_name,
        "bus_info": bus_info,
        "is_capture": is_capture,
    }


def list_v4l2_devices(capture_only: bool = True) -> List[Dict[str, Any]]:
    """Scan and list available local video devices.

    By default returns only video capture devices (webcams, capture cards),
    filtering out metadata/output nodes.
    """
    sysfs_dir = Path("/sys/class/video4linux")
    devices: List[Dict[str, Any]] = []

    if sysfs_dir.is_dir():
        entries = sorted(sysfs_dir.iterdir(), key=lambda p: (len(p.name), p.name))
        for entry in entries:
            dev_path = f"/dev/{entry.name}"
            info = query_v4l2_device(dev_path)
            if info:
                if not capture_only or info.get("is_capture"):
                    devices.append(info)
    else:
        dev_dir = Path("/dev")
        for dev in sorted(dev_dir.glob("video*"), key=lambda p: (len(p.name), p.name)):
            info = query_v4l2_device(str(dev))
            if info:
                if not capture_only or info.get("is_capture"):
                    devices.append(info)

    return devices
