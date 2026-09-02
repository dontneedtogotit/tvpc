"""Launch mpv picture-in-picture windows, single or grid, with optional
fullscreen and per-window audio control."""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Optional

from .config import Camera


PIP_W = 480
PIP_H = 270
PIP_MARGIN = 24


@dataclass
class MpvProc:
    camera: Camera
    proc: subprocess.Popen
    fullscreen: bool = False


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
    elif total <= 9:
        cols = 3
    else:
        cols = 4
    row = index // cols
    col = index % cols
    x = sw - w - PIP_MARGIN - col * (w + PIP_MARGIN)
    y = sh - h - PIP_MARGIN - row * (h + PIP_MARGIN)
    return x, y


def _build_cmd(cam: Camera, x: int, y: int, w: int, h: int,
               fullscreen: bool = False, audio: bool = True) -> List[str]:
    cmd = [
        "mpv", "--no-terminal", "--quiet",
        f"--title=tvpc-cameras: {cam.name}",
        "--border=no", "--title-bar=no",
        "--no-osc", "--no-input-terminal", "--no-input-cursor",
        "--keep-open=always",
        "--rtsp-transport=tcp",
        "--hwdec=auto-safe",
        "--force-window=immediate",
    ]
    if fullscreen:
        cmd.append("--fullscreen")
    else:
        cmd.append(f"--geometry={w}x{h}+{x}+{y}")
        cmd.append("--ontop")
        cmd.append("--on-top-level=system")
    if not audio or not cam.audio:
        cmd.append("--no-audio")
    cmd += cam.credential_args()
    cmd.append(cam.url)
    return cmd


class PipManager:
    """Tracks running mpv PiP processes so we can close them on exit."""

    def __init__(self) -> None:
        self._procs: Dict[str, MpvProc] = {}  # cam.name -> MpvProc

    def is_available(self) -> bool:
        return _have_mpv()

    def is_open(self, cam: Camera) -> bool:
        return cam.name in self._procs

    def open_one(self, cam: Camera, fullscreen: bool = False) -> Optional[MpvProc]:
        if not _have_mpv():
            return None
        # Allow only one window per camera.
        if cam.name in self._procs:
            return self._procs[cam.name]
        x, y = _grid_pos(0, 1, PIP_W, PIP_H)
        proc = subprocess.Popen(
            _build_cmd(cam, x, y, PIP_W, PIP_H, fullscreen=fullscreen, audio=cam.audio),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":0")},
        )
        entry = MpvProc(camera=cam, proc=proc, fullscreen=fullscreen)
        self._procs[cam.name] = entry
        return entry

    def open_grid(self, cameras: List[Camera], cols: int = 2) -> int:
        """Open a grid of PiP windows.

        cols=2 → 2×2, cols=3 → 3×3, cols=4 → 4×4.
        """
        if not _have_mpv():
            return 0
        opened = 0
        total = min(len(cameras), cols * cols)
        for i, cam in enumerate(cameras[:total]):
            x, y = _grid_pos(i, total, PIP_W, PIP_H)
            proc = subprocess.Popen(
                _build_cmd(cam, x, y, PIP_W, PIP_H, audio=cam.audio),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":0")},
            )
            self._procs[cam.name] = MpvProc(camera=cam, proc=proc)
            opened += 1
        return opened

    def close(self, cam: Camera) -> None:
        entry = self._procs.pop(cam.name, None)
        if entry is None:
            return
        try:
            entry.proc.terminate()
            try:
                entry.proc.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                entry.proc.kill()
        except Exception:  # noqa: BLE001
            pass

    def reap(self) -> None:
        alive: Dict[str, MpvProc] = {}
        for name, entry in self._procs.items():
            if entry.proc.poll() is None:
                alive[name] = entry
        self._procs = alive

    def close_all(self) -> None:
        for name in list(self._procs):
            entry = self._procs.pop(name)
            try:
                entry.proc.terminate()
            except Exception:  # noqa: BLE001
                pass
        for entry in self._procs.values():
            try:
                entry.proc.wait(timeout=1.5)
            except Exception:  # noqa: BLE001
                try:
                    entry.proc.kill()
                except Exception:  # noqa: BLE001
                    pass
        self._procs = {}
