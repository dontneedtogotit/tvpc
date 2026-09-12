"""Smart TV PiP Pop-up manager for camera alerts (motion, doorbell, alarm)."""
from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from typing import Optional

from PySide6.QtCore import QObject, QTimer, Signal

from .config import Camera
from .pip import _build_cmd, _screen_size, PIP_MARGIN, PIP_W, PIP_H


def play_chime() -> None:
    """Play a soft notification sound in a background thread."""
    sound_files = [
        "/usr/share/sounds/freedesktop/stereo/bell.oga",
        "/usr/share/sounds/freedesktop/stereo/complete.oga",
        "/usr/share/sounds/gnome/default/alerts/glass.ogg",
        "/usr/share/sounds/sound-icons/prompt.wav",
    ]
    chosen = next((f for f in sound_files if os.path.exists(f)), None)

    def _worker():
        if chosen:
            if shutil.which("pw-play"):
                subprocess.run(["pw-play", chosen], capture_output=True)
                return
            if shutil.which("paplay"):
                subprocess.run(["paplay", chosen], capture_output=True)
                return
            if shutil.which("canberra-gtk-play"):
                subprocess.run(["canberra-gtk-play", "-f", chosen], capture_output=True)
                return
            if shutil.which("mpv"):
                subprocess.run(["mpv", "--no-terminal", "--really-quiet", chosen], capture_output=True)
                return

    threading.Thread(target=_worker, daemon=True).start()


class SmartPopupManager(QObject):
    """Manages transient TV picture-in-picture popups on alert triggers."""

    popup_opened = Signal(str)   # camera_name
    popup_closed = Signal(str)   # camera_name

    def __init__(
        self,
        parent: Optional[QObject] = None,
        duration_seconds: float = 15.0,
        cooldown_seconds: float = 20.0,
        sound_enabled: bool = True,
    ) -> None:
        super().__init__(parent)
        self.duration_seconds = duration_seconds
        self.cooldown_seconds = cooldown_seconds
        self.sound_enabled = sound_enabled

        self._active_proc: Optional[subprocess.Popen] = None
        self._active_cam_name: str = ""
        self._last_trigger_time: float = 0.0

        self._dismiss_timer = QTimer(self)
        self._dismiss_timer.setSingleShot(True)
        self._dismiss_timer.timeout.connect(self.close_popup)

    def is_active(self) -> bool:
        """Return True if a popup window is currently displaying."""
        if self._active_proc is None:
            return False
        if self._active_proc.poll() is not None:
            self._active_proc = None
            self._active_cam_name = ""
            return False
        return True

    def trigger_popup(self, camera: Camera, force: bool = False) -> bool:
        """Trigger a transient popup for a camera.

        Returns True if popup was launched, False if suppressed by cooldown.
        """
        now = time.time()
        if not force:
            if (now - self._last_trigger_time) < self.cooldown_seconds:
                return False

        self.close_popup()

        if not shutil.which("mpv"):
            return False

        sw, sh = _screen_size()
        x = sw - PIP_W - PIP_MARGIN
        y = sh - PIP_H - PIP_MARGIN

        cmd = _build_cmd(
            camera,
            x=x,
            y=y,
            w=PIP_W,
            h=PIP_H,
            fullscreen=False,
            audio=False,
        )

        try:
            self._active_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._active_cam_name = camera.name
            self._last_trigger_time = now

            if self.sound_enabled:
                play_chime()

            if self.duration_seconds > 0:
                self._dismiss_timer.start(int(self.duration_seconds * 1000))

            self.popup_opened.emit(camera.name)
            return True
        except Exception:
            return False

    def close_popup(self) -> None:
        """Dismiss the active popup immediately."""
        self._dismiss_timer.stop()
        if self._active_proc is not None:
            try:
                self._active_proc.terminate()
                self._active_proc.wait(timeout=1.0)
            except Exception:
                try:
                    self._active_proc.kill()
                except Exception:
                    pass
            name = self._active_cam_name
            self._active_proc = None
            self._active_cam_name = ""
            if name:
                self.popup_closed.emit(name)
