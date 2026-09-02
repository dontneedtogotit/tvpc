"""Camera configuration: load / save the cameras.conf file."""
from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import List, Optional


CONF_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "tvpc"
CONF_FILE = CONF_DIR / "cameras.conf"


@dataclass
class Camera:
    name: str
    url: str
    user: str = ""
    password: str = ""
    notes: str = ""

    def credential_args(self) -> List[str]:
        args: List[str] = []
        if self.user:
            args += ["--user", self.user, "--password", self.password]
        return args

    def display(self) -> str:
        if self.user:
            return f"{self.name}  ({self.url}  as {self.user})"
        return f"{self.name}  ({self.url})"


def ensure_conf() -> Path:
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    if not CONF_FILE.exists():
        CONF_FILE.touch()
    return CONF_FILE


def load_cameras() -> List[Camera]:
    """Read cameras.conf, ignoring blanks and lines starting with '#'.

    Format is `NAME|URL|USER|PASS|NOTES`. The legacy format with just
    `NAME|URL` (or `NAME|URL|USER|PASS`) is also accepted.
    """
    ensure_conf()
    out: List[Camera] = []
    for raw in CONF_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        # Pad to 5 fields.
        while len(parts) < 5:
            parts.append("")
        name, url, user, password, notes = parts[:5]
        if not name or not url:
            continue
        out.append(Camera(name=name, url=url, user=user, password=password, notes=notes))
    return out


def save_cameras(cameras: List[Camera]) -> None:
    ensure_conf()
    tmp = CONF_FILE.with_suffix(".conf.tmp")
    lines = [
        "# tvpc cameras — one per line: NAME|URL|USER|PASS|NOTES",
        "# Edited by tvpc-cameras-gui. Also readable by the bash tvpc-cameras script.",
    ]
    for cam in cameras:
        lines.append("|".join([cam.name, cam.url, cam.user, cam.password, cam.notes]))
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    shutil.move(str(tmp), str(CONF_FILE))


def add_camera(cam: Camera) -> List[Camera]:
    cams = load_cameras()
    cams.append(cam)
    save_cameras(cams)
    return cams


def remove_camera(index: int) -> List[Camera]:
    cams = load_cameras()
    if 0 <= index < len(cams):
        cams.pop(index)
        save_cameras(cams)
    return cams


def update_camera(index: int, cam: Camera) -> List[Camera]:
    cams = load_cameras()
    if 0 <= index < len(cams):
        cams[index] = cam
        save_cameras(cams)
    return cams


def config_path() -> Path:
    return ensure_conf()
