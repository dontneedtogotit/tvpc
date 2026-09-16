"""Automatic update checker and updater for tvpc-cameras-gui standalone installation."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Optional, Tuple

REPO_URL = "https://github.com/dontneedtogotit/tvpc.git"
REPO_ARCHIVE_URL = "https://github.com/dontneedtogotit/tvpc/archive/{ref}.tar.gz"
GITHUB_API_URL = "https://api.github.com/repos/dontneedtogotit/tvpc/commits/main"


def get_install_dir() -> Path:
    """Return the base directory where tvpc-cameras-gui is installed."""
    return Path(__file__).resolve().parent.parent


def is_git_repo(path: Optional[Path] = None) -> bool:
    """Check if the given path (or install dir) is a git repository."""
    d = path or get_install_dir()
    return (d / ".git").is_dir()


def get_installed_version(install_dir: Optional[Path] = None) -> Optional[str]:
    """Get the currently installed commit hash or version string."""
    base = install_dir or get_install_dir()
    version_file = base / ".version"
    if version_file.is_file():
        try:
            val = version_file.read_text(encoding="utf-8").strip()
            if val:
                return val
        except OSError:
            pass

    if is_git_repo(base):
        try:
            res = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=str(base),
                capture_output=True,
                text=True,
                timeout=2.0,
                check=False,
            )
            if res.returncode == 0 and res.stdout.strip():
                return res.stdout.strip()
        except Exception:
            pass

    return None


def get_remote_version(timeout: float = 2.0) -> Optional[str]:
    """Fetch the latest commit SHA for main branch from GitHub.

    Tries `git ls-remote` first for speed and zero rate limits,
    then falls back to the GitHub REST API.
    """
    # Attempt 1: git ls-remote (fast, anonymous, no rate limits)
    try:
        res = subprocess.run(
            ["git", "ls-remote", REPO_URL, "refs/heads/main"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if res.returncode == 0 and res.stdout:
            parts = res.stdout.split()
            if parts:
                sha = parts[0].strip()
                if len(sha) == 40:
                    return sha
    except Exception:
        pass

    # Attempt 2: GitHub API via urllib
    try:
        req = urllib.request.Request(
            GITHUB_API_URL,
            headers={
                "User-Agent": "tvpc-cameras-gui-updater",
                "Accept": "application/vnd.github.v3+json",
            },
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                import json
                data = json.loads(resp.read().decode("utf-8"))
                sha = data.get("sha")
                if sha and isinstance(sha, str) and len(sha) == 40:
                    return sha
    except Exception:
        pass

    return None


def check_for_update(timeout: float = 2.0) -> Tuple[bool, Optional[str], Optional[str]]:
    """Check if an update is available.

    Returns:
        (has_update, current_version, remote_version)
    """
    current = get_installed_version()
    remote = get_remote_version(timeout=timeout)

    if not remote:
        return False, current, None

    if not current:
        # No recorded version yet; treat as update needed if in standalone dir
        standalone_dir = Path.home() / ".local/share/tvpc-cameras-gui"
        if get_install_dir() == standalone_dir:
            return True, None, remote
        return False, current, remote

    has_update = current != remote
    return has_update, current, remote


def apply_update(remote_version: str, install_dir: Optional[Path] = None) -> bool:
    """Download and apply update for the standalone installation."""
    base = install_dir or get_install_dir()
    home = Path.home()
    is_standalone = (base == home / ".local/share/tvpc-cameras-gui")

    # If it's a git repo in development mode (not standalone), update via git pull
    if is_git_repo(base) and not is_standalone:
        try:
            res = subprocess.run(
                ["git", "pull", "--ff-only"],
                cwd=str(base),
                capture_output=True,
                text=True,
                timeout=10.0,
                check=False,
            )
            return res.returncode == 0
        except Exception:
            return False

    # For standalone installation: download and unpack tarball
    candidate_urls = [
        "https://github.com/dontneedtogotit/tvpc/archive/refs/heads/main.tar.gz",
        f"https://api.github.com/repos/dontneedtogotit/tvpc/tarball/{remote_version}",
        f"https://github.com/dontneedtogotit/tvpc/archive/{remote_version}.tar.gz",
    ]
    tmp_dir = Path(tempfile.mkdtemp(prefix="tvpc_update_"))
    tar_path = tmp_dir / "repo.tar.gz"

    try:
        downloaded = False
        for tarball_url in candidate_urls:
            try:
                req = urllib.request.Request(
                    tarball_url,
                    headers={"User-Agent": "tvpc-cameras-gui-updater"},
                )
                with urllib.request.urlopen(req, timeout=15.0) as resp, open(tar_path, "wb") as f:
                    shutil.copyfileobj(resp, f)
                downloaded = True
                break
            except Exception:
                continue

        if not downloaded:
            return False

        # Extract archive
        with tarfile.open(tar_path, "r:gz") as tar:
            try:
                tar.extractall(path=tmp_dir, filter="data")
            except TypeError:
                tar.extractall(path=tmp_dir)

        # Find the extracted root (e.g. tvpc-main or tvpc-<sha>)
        extracted_dirs = [p for p in tmp_dir.iterdir() if p.is_dir() and p != tmp_dir]
        if not extracted_dirs:
            return False
        extracted_root = extracted_dirs[0]

        src_pkg = extracted_root / "tvpc_cameras_gui"
        if not src_pkg.is_dir():
            return False

        # Target package directory
        target_pkg = base / "tvpc_cameras_gui"
        target_pkg.mkdir(parents=True, exist_ok=True)

        # Sync files into target package
        for root, dirs, files in os.walk(src_pkg):
            rel_dir = Path(root).relative_to(src_pkg)
            dest_dir = target_pkg / rel_dir
            dest_dir.mkdir(parents=True, exist_ok=True)
            for f in files:
                if f.endswith((".pyc", ".pyo")):
                    continue
                shutil.copy2(Path(root) / f, dest_dir / f)

        # Update .version file
        (base / ".version").write_text(remote_version.strip() + "\n", encoding="utf-8")

        # Update wrapper and desktop file if in home/.local (only when not in custom test dir)
        if install_dir is None:
            bin_file = home / ".local/bin/tvpc-cameras-gui"
            if bin_file.is_file():
                _ensure_wrapper_script(bin_file, base)

            desktop_file = home / ".local/share/applications/tvpc-cameras-gui.desktop"
            src_desktop = extracted_root / "standalone/tvpc-cameras-gui.desktop"
            if desktop_file.exists() or src_desktop.is_file():
                _ensure_desktop_entry(desktop_file)
        elif (base.parent / "bin/tvpc-cameras-gui").is_file():
            _ensure_wrapper_script(base.parent / "bin/tvpc-cameras-gui", base)

        return True
    except Exception as e:
        print(f"tvpc-cameras-gui updater error: {e}", file=sys.stderr)
        return False
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _ensure_wrapper_script(bin_path: Path, app_dir: Path) -> None:
    """Ensure the ~/.local/bin/tvpc-cameras-gui wrapper exports PYTHONPATH and handles fallbacks."""
    wrapper_content = f"""#!/usr/bin/env bash
# Launcher for tvpc-cameras-gui standalone install.
set -euo pipefail
APP_DIR="{app_dir}"
STANDALONE_DIR="${{HOME}}/.local/share/tvpc-cameras-gui"
if [ ! -d "${{APP_DIR}}" ] && [ -d "${{STANDALONE_DIR}}" ]; then
    APP_DIR="${{STANDALONE_DIR}}"
fi
export PYTHONPATH="${{APP_DIR}}:${{PYTHONPATH:-}}"
if [ -x "${{APP_DIR}}/.venv/bin/python" ]; then
    exec "${{APP_DIR}}/.venv/bin/python" -m tvpc_cameras_gui "$@"
elif [ -x "${{STANDALONE_DIR}}/.venv/bin/python" ]; then
    exec "${{STANDALONE_DIR}}/.venv/bin/python" -m tvpc_cameras_gui "$@"
fi
PYTHON="$(command -v python3 || command -v python)"
if [ -z "${{PYTHON}}" ]; then
    echo "Python not found. Please install python3." >&2
    exit 1
fi
exec "${{PYTHON}}" -m tvpc_cameras_gui "$@"
"""
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.write_text(wrapper_content, encoding="utf-8")
    bin_path.chmod(0o755)


def _ensure_desktop_entry(desktop_path: Path) -> None:
    """Ensure ~/.local/share/applications/tvpc-cameras-gui.desktop uses the correct launcher and icon."""
    desktop_content = """[Desktop Entry]
Type=Application
Name=tvpc Cameras
Comment=IP security camera manager with live previews
Exec=tvpc-cameras-gui
Icon=camera-web
Terminal=false
Categories=AudioVideo;Video;Network;Utility;
Keywords=camera;security;rtsp;onvif;surveillance;tvpc;
StartupNotify=true
StartupWMClass=tvpc-cameras-gui
"""
    desktop_path.parent.mkdir(parents=True, exist_ok=True)
    desktop_path.write_text(desktop_content, encoding="utf-8")
    desktop_path.chmod(0o644)


def check_and_apply_update(timeout: float = 2.0, force: bool = False) -> bool:
    """Check for updates and apply them if available.

    Returns True if an update was successfully applied.
    """
    if not force and os.environ.get("TVPC_NO_UPDATE", "").lower() in ("1", "true", "yes"):
        return False

    try:
        has_update, current, remote = check_for_update(timeout=timeout)
        if (has_update or force) and remote:
            curr_str = current[:8] if current else "none"
            print(f"tvpc-cameras-gui: updating from {curr_str} to {remote[:8]}...", file=sys.stderr)
            if apply_update(remote):
                print(f"tvpc-cameras-gui: updated to {remote[:8]}.", file=sys.stderr)
                return True
            else:
                print("tvpc-cameras-gui: update failed, continuing with installed version.", file=sys.stderr)
    except Exception as e:
        print(f"tvpc-cameras-gui: update check failed ({e}), continuing.", file=sys.stderr)

    return False
