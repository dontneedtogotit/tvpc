"""Desktop notification helper.

Uses notify-send on Linux when available, otherwise falls back to
a no-op (the caller can handle the fallback if desired).
"""
from __future__ import annotations

import shutil
import subprocess
from typing import Optional


def _have_notify_send() -> bool:
    return shutil.which("notify-send") is not None


def send(title: str, body: str = "", urgency: str = "normal") -> bool:
    """Send a desktop notification.

    Returns True if the notification was sent, False if notify-send
    is not available or failed.
    """
    if not _have_notify_send():
        return False
    try:
        subprocess.run(
            ["notify-send", f"--urgency={urgency}", title, body],
            timeout=5,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


def send_camera_offline(cam_name: str) -> bool:
    return send(
        "Camera offline",
        f"{cam_name} is no longer reachable.",
        urgency="critical",
    )


def send_camera_online(cam_name: str) -> bool:
    return send(
        "Camera back online",
        f"{cam_name} is reachable again.",
        urgency="normal",
    )


def send_motion_detected(cam_name: str) -> bool:
    return send(
        "Motion detected",
        f"Motion detected on {cam_name}.",
        urgency="normal",
    )


def send_recording_started(cam_name: str) -> bool:
    return send(
        "Recording started",
        f"Recording {cam_name} to disk.",
        urgency="low",
    )


def send_recording_stopped(cam_name: str) -> bool:
    return send(
        "Recording stopped",
        f"Saved recording of {cam_name}.",
        urgency="low",
    )
