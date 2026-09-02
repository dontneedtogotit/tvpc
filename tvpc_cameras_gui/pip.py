"""Launch mpv picture-in-picture windows, single or 2x2 grid."""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional

from .config import Camera


PIP_W = 480
PIP_H = 270
PIP_MARGIN = 24


@dataclass
class MpvProc:
    camera: Camera
    proc: subprocess.Popen


def _have_mpv() -> bool:
    return shutil.which("mpv") is not None


def _screen_size() -> tuple[int, int]:
    w = h = 0
    if shutil.which("xdpyinfo"):
        try:
            out = subprocess.check_output(["xdpyinfo"], text=True, timeout=2)
            for line in out.splitlines():
                if "dimensions:" in line:
                    parts = line.split(":", 1)[1].strip().split("x")
                    w, h = int(parts[0]), int(parts[1])
                    break
        except Exception:  # noqa: BLE001
            pass
    return (w or 1920, h or 1080)


def _grid_pos(index: int, total: int, w: int, h: int) -> tuple[int, int]:
    sw, sh = _screen_size()
    if total <= 1:
        cols = 1
    elif total <= 4:
        cols = 2
    else:
        cols = 3
    row = index // cols
    col = index % cols
    x = sw - w - PIP_MARGIN - col * (w + PIP_MARGIN)
    y = sh - h - PIP_MARGIN - row * (h + PIP_MARGIN)
    return x, y


def _build_cmd(cam: Camera, x: int, y: int, w: int, h: int) -> List[str]:
    cmd = [
        "mpv", "--no-terminal", "--quiet",
        f"--title=tvpc-cameras: {cam.name}",
        f"--geometry={w}x{h}+{x}+{y}",
        "--border=no", "--title-bar=no",
        "--no-osc", "--no-input-terminal", "--no-input-cursor",
        "--keep-open=always",
        "--ontop", "--on-top-level=system",
        "--rtsp-transport=tcp",
        "--hwdec=auto-safe",
        "--force-window=immediate",
    ]
    cmd += cam.credential_args()
    cmd.append(cam.url)
    return cmd


class PipManager:
    """Tracks running mpv PiP processes so we can close them on exit."""

    def __init__(self) -> None:
        self._procs: List[MpvProc] = []

    def is_available(self) -> bool:
        return _have_mpv()

    def open_one(self, cam: Camera) -> Optional[MpvProc]:
        if not _have_mpv():
            return None
        # Allow only one window per camera.
        for entry in self._procs:
            if entry.camera.url == cam.url and entry.camera.name == cam.name:
                return entry
        x, y = _grid_pos(0, 1, PIP_W, PIP_H)
        proc = subprocess.Popen(
            _build_cmd(cam, x, y, PIP_W, PIP_H),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":0")},
        )
        entry = MpvProc(camera=cam, proc=proc)
        self._procs.append(entry)
        return entry

    def open_grid(self, cameras: List[Camera]) -> int:
        if not _have_mpv():
            return 0
        opened = 0
        for i, cam in enumerate(cameras[:4]):
            x, y = _grid_pos(i, min(len(cameras), 4), PIP_W, PIP_H)
            proc = subprocess.Popen(
                _build_cmd(cam, x, y, PIP_W, PIP_H),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":0")},
            )
            self._procs.append(MpvProc(camera=cam, proc=proc))
            opened += 1
        return opened

    def reap(self) -> None:
        alive: List[MpvProc] = []
        for entry in self._procs:
            if entry.proc.poll() is None:
                alive.append(entry)
        self._procs = alive

    def close_all(self) -> None:
        for entry in self._procs:
            try:
                entry.proc.terminate()
            except Exception:  # noqa: BLE001
                pass
        for entry in self._procs:
            try:
                entry.proc.wait(timeout=1.5)
            except Exception:  # noqa: BLE001
                try:
                    entry.proc.kill()
                except Exception:  # noqa: BLE001
                    pass
        self._procs = []
