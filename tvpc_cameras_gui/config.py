"""Camera configuration: load / save the cameras.conf file."""
from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import List


CONF_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "tvpc"
CONF_FILE = CONF_DIR / "cameras.conf"
RECORD_DIR = CONF_DIR / "recordings"


@dataclass
class Camera:
    name: str
    url: str
    user: str = ""
    password: str = ""
    notes: str = ""
    group: str = ""
    profile: str = "main"       # "main" or "sub"
    audio: bool = True          # play audio in PiP windows

    def credential_args(self) -> List[str]:
        args: List[str] = []
        if self.user:
            args += ["--user", self.user, "--password", self.password]
        return args

    def display(self) -> str:
        group_prefix = f"[{self.group}] " if self.group else ""
        if self.user:
            return f"{group_prefix}{self.name}  ({self.url}  as {self.user})"
        return f"{group_prefix}{self.name}  ({self.url})"

    def stream_url(self) -> str:
        """Return the effective stream URL for the selected profile.

        Many cameras expose the same URL for both profiles; this hook
        lets us swap in a sub-stream variant later if needed.
        """
        return self.url


def ensure_conf() -> Path:
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    RECORD_DIR.mkdir(parents=True, exist_ok=True)
    if not CONF_FILE.exists():
        CONF_FILE.touch()
    return CONF_FILE


def load_cameras() -> List[Camera]:
    """Read cameras.conf, ignoring blanks and lines starting with '#'.

    Format is `NAME|URL|USER|PASS|NOTES|GROUP|PROFILE|AUDIO`.
    Legacy formats with fewer fields are accepted and padded.
    """
    ensure_conf()
    out: List[Camera] = []
    for raw in CONF_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        while len(parts) < 8:
            parts.append("")
        name, url, user, password, notes, group, profile, audio = parts[:8]
        if not name or not url:
            continue
        # Parse audio as bool (default True).
        audio_str = audio.strip().lower()
        audio_val = audio_str not in ("0", "false", "no", "off")
        profile_val = profile.strip() or "main"
        out.append(Camera(
            name=name, url=url, user=user, password=password,
            notes=notes, group=group.strip(), profile=profile_val,
            audio=audio_val,
        ))
    return out


def save_cameras(cameras: List[Camera]) -> None:
    ensure_conf()
    tmp = CONF_FILE.with_suffix(".conf.tmp")
    lines = [
        "# tvpc cameras — one per line: NAME|URL|USER|PASS|NOTES|GROUP|PROFILE|AUDIO",
        "# Edited by tvpc-cameras-gui. Also readable by the bash tvpc-cameras script.",
        "# AUDIO: 1/true = play audio, 0/false = mute. PROFILE: main or sub.",
    ]
    for cam in cameras:
        audio_str = "1" if cam.audio else "0"
        lines.append("|".join([
            cam.name, cam.url, cam.user, cam.password, cam.notes,
            cam.group, cam.profile, audio_str,
        ]))
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


def record_path() -> Path:
    ensure_conf()
    return RECORD_DIR
