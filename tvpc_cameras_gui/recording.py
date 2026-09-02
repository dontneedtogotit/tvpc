"""Stream recording manager.

Records camera streams to disk using ffmpeg. Recordings are saved to
~/.config/tvpc/recordings/ with timestamped filenames.
"""
from __future__ import annotations

import shutil
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

from .config import Camera, RECORD_DIR


@dataclass
class Recording:
    camera: Camera
    started_at: float
    file_path: Path
    proc: subprocess.Popen

    @property
    def duration(self) -> float:
        return time.time() - self.started_at

    @property
    def display_duration(self) -> str:
        d = int(self.duration)
        h, rem = divmod(d, 3600)
        m, s = divmod(rem, 60)
        if h:
            return f"{h}:{m:02d}:{s:02d}"
        return f"{m}:{s:02d}"


def _have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def _build_record_cmd(cam: Camera, output: Path) -> List[str]:
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning",
        "-rtsp_transport", "tcp",
        "-i", cam.url,
        "-c", "copy",
        "-f", "matroska",
        "-y",
        str(output),
    ]
    return cmd


class RecordingManager:
    """Manages active recordings and provides recording history."""

    def __init__(self) -> None:
        self._active: Dict[str, Recording] = {}  # camera name -> Recording

    def is_available(self) -> bool:
        return _have_ffmpeg()

    def is_recording(self, cam: Camera) -> bool:
        return cam.name in self._active

    def toggle(self, cam: Camera) -> Optional[Recording]:
        """Toggle recording for a camera. Returns the Recording if now
        recording, or None if stopped.
        """
        if self.is_recording(cam):
            self.stop(cam)
            return None
        return self.start(cam)

    def start(self, cam: Camera) -> Optional[Recording]:
        if not _have_ffmpeg():
            return None
        if self.is_recording(cam):
            return self._active[cam.name]

        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in cam.name)
        filename = f"{safe_name}_{ts}.mkv"
        output = RECORD_DIR / filename

        proc = subprocess.Popen(
            _build_record_cmd(cam, output),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        rec = Recording(camera=cam, started_at=time.time(), file_path=output, proc=proc)
        self._active[cam.name] = rec
        return rec

    def stop(self, cam: Camera) -> None:
        rec = self._active.pop(cam.name, None)
        if rec is None:
            return
        try:
            rec.proc.terminate()
            try:
                rec.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                rec.proc.kill()
        except Exception:  # noqa: BLE001
            pass

    def stop_all(self) -> None:
        for cam in list(self._active):
            self.stop(self._active[cam].camera)

    def active_recordings(self) -> List[Recording]:
        # Reap finished processes.
        finished = []
        for name, rec in list(self._active.items()):
            if rec.proc.poll() is not None:
                finished.append(name)
        for name in finished:
            del self._active[name]
        return list(self._active.values())

    def recording_history(self, limit: int = 50) -> List[Path]:
        """Return recent recording files, newest first."""
        if not RECORD_DIR.exists():
            return []
        files = sorted(RECORD_DIR.glob("*.mkv"), key=lambda p: p.stat().st_mtime, reverse=True)
        return files[:limit]

    @staticmethod
    def disk_usage() -> str:
        """Return human-readable total size of recordings directory."""
        if not RECORD_DIR.exists():
            return "0 B"
        total = sum(f.stat().st_size for f in RECORD_DIR.rglob("*") if f.is_file())
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if total < 1024:
                return f"{total:.1f} {unit}"
            total /= 1024
        return f"{total:.1f} PB"
