"""Camera health monitoring.

Periodically probes each camera's stream URL and reports online/offline
status. Runs in a QThread so the GUI stays responsive.
"""
from __future__ import annotations

import shutil
import socket
import subprocess
import time
from typing import Dict, List, Optional

from PySide6.QtCore import QObject, QThread, Signal

from .config import Camera


def _probe_url(url: str, user: str = "", password: str = "", timeout: float = 3.0) -> bool:
    """Quick liveness check for a camera URL.

    Uses ffprobe if available, otherwise falls back to a TCP connect
    to the URL's host/port.
    """
    if shutil.which("ffprobe"):
        try:
            args = [
                "ffprobe", "-v", "error",
                "-rtsp_transport", "tcp",
                "-i", url,
                "-show_entries", "stream=codec_name",
                "-of", "csv=p=0",
            ]
            if user:
                args += ["-user", user, "-password", password]
            result = subprocess.run(
                args, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=timeout,
            )
            return result.returncode == 0
        except (subprocess.TimeoutExpired, OSError):
            return False
    else:
        # Fallback: TCP connect to host:port.
        from urllib.parse import urlparse
        try:
            p = urlparse(url)
            host = p.hostname or ""
            port = p.port or (554 if p.scheme == "rtsp" else 80)
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except (OSError, ValueError):
            return False


class HealthWorker(QObject):
    """Probes cameras and emits status changes."""
    status_changed = Signal(str, bool, str)  # cam_name, is_online, url
    all_checked = Signal()

    def __init__(self, cameras: List[Camera], interval: float = 30.0) -> None:
        super().__init__()
        self._cameras = cameras
        self._interval = interval
        self._cancel = False
        self._known: Dict[str, bool] = {}

    def cancel(self) -> None:
        self._cancel = True

    def update_cameras(self, cameras: List[Camera]) -> None:
        self._cameras = cameras

    def run(self) -> None:
        try:
            while not self._cancel:
                self._check_all()
                self.all_checked.emit()
                # Sleep in small chunks so cancellation is responsive.
                deadline = time.time() + self._interval
                while time.time() < deadline and not self._cancel:
                    time.sleep(0.5)
        except Exception:  # noqa: BLE001
            pass

    def _check_all(self) -> None:
        for cam in self._cameras:
            if self._cancel:
                return
            is_online = _probe_url(cam.url, cam.user, cam.password)
            prev = self._known.get(cam.name)
            self._known[cam.name] = is_online
            if prev is None or prev != is_online:
                self.status_changed.emit(cam.name, is_online, cam.url)


def start_health_monitor(parent, cameras: List[Camera],
                         interval: float = 30.0,
                         on_status_change=None,
                         on_all_checked=None) -> tuple[QThread, HealthWorker]:
    """Start a health monitor on a new QThread."""
    thread = QThread(parent)
    worker = HealthWorker(cameras, interval=interval)
    worker.moveToThread(thread)
    thread.started.connect(worker.run)
    if on_status_change is not None:
        worker.status_changed.connect(on_status_change)
    if on_all_checked is not None:
        worker.all_checked.connect(on_all_checked)
    worker.all_checked.connect(thread.quit)
    thread.start()
    return thread, worker
