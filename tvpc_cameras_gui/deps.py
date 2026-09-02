"""Dependency detection and installation for the camera GUI.

Knows how to check for PySide6, ffmpeg, ffprobe and mpv, how to map
them to apt / pip packages on the current distro, and how to run the
install with progress reporting.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, List, Optional


@dataclass
class Dependency:
    name: str           # human-readable name
    purpose: str        # one-line description of what it's for
    check_cmd: str      # command to test (e.g. "ffmpeg")
    apt_package: str    # apt package name
    pip_package: str    # pip package name (empty if not installable via pip)
    found: bool = False
    path: str = ""


@dataclass
class DependencyReport:
    dependencies: List[Dependency] = field(default_factory=list)

    @property
    def all_found(self) -> bool:
        return all(d.found for d in self.dependencies)

    @property
    def missing(self) -> List[Dependency]:
        return [d for d in self.dependencies if not d.found]

    @property
    def found_list(self) -> List[Dependency]:
        return [d for d in self.dependencies if d.found]


def _detect_distro() -> dict:
    info = {"id": "", "like": "", "name": "", "version": ""}
    try:
        with open("/etc/os-release", "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip('"').strip("'")
                if k == "ID":
                    info["id"] = v
                elif k == "ID_LIKE":
                    info["like"] = v
                elif k == "NAME":
                    info["name"] = v
                elif k == "VERSION_ID":
                    info["version"] = v
    except OSError:
        pass
    return info


def _is_debian_based(distro: dict) -> bool:
    did = distro.get("id", "")
    like = distro.get("like", "")
    return "debian" in did or "debian" in like or "ubuntu" in did or "ubuntu" in like


def _is_fedora_based(distro: dict) -> bool:
    did = distro.get("id", "")
    like = distro.get("like", "")
    return "fedora" in did or "fedora" in like or "rhel" in like


def _check_cmd(cmd: str) -> tuple[bool, str]:
    path = shutil.which(cmd)
    if path:
        return True, path
    return False, ""


def check_dependencies() -> DependencyReport:
    """Return a DependencyReport describing what is and isn't installed."""
    deps = [
        Dependency(
            name="PySide6 (Qt for Python)",
            purpose="The graphical interface itself",
            check_cmd="",  # checked via import, not a shell command
            apt_package="python3-pyside6",
            pip_package="PySide6",
        ),
        Dependency(
            name="ffmpeg",
            purpose="Decodes video streams for the live preview thumbnails",
            check_cmd="ffmpeg",
            apt_package="ffmpeg",
            pip_package="",
        ),
        Dependency(
            name="ffprobe",
            purpose="Probes network cameras during a scan",
            check_cmd="ffprobe",
            apt_package="ffmpeg",  # ships with ffmpeg
            pip_package="",
        ),
        Dependency(
            name="mpv",
            purpose="Plays picture-in-picture camera windows",
            check_cmd="mpv",
            apt_package="mpv",
            pip_package="",
        ),
    ]

    report = DependencyReport()

    for dep in deps:
        if dep.check_cmd:
            found, path = _check_cmd(dep.check_cmd)
            dep.found = found
            dep.path = path
        else:
            # PySide6 — check via import
            try:
                __import__(dep.pip_package)
                dep.found = True
                import importlib.util
                spec = importlib.util.find_spec(dep.pip_package)
                dep.path = spec.origin if spec else ""
            except ImportError:
                dep.found = False
        report.dependencies.append(dep)

    return report


def build_install_command(missing: List[Dependency]) -> Optional[str]:
    """Build a shell command to install the missing dependencies.

    Returns None if no installer is available.
    """
    if not missing:
        return None

    distro = _detect_distro()
    has_apt = shutil.which("apt-get") is not None
    has_dnf = shutil.which("dnf") is not None
    has_pip = shutil.which("pip3") is not None or shutil.which("pip") is not None

    apt_packages: List[str] = []
    pip_packages: List[str] = []

    for dep in missing:
        if has_apt and dep.apt_package:
            if dep.apt_package not in apt_packages:
                apt_packages.append(dep.apt_package)
        elif dep.pip_package and has_pip:
            if dep.pip_package not in pip_packages:
                pip_packages.append(dep.pip_package)
        elif dep.apt_package:
            if dep.apt_package not in apt_packages:
                apt_packages.append(dep.apt_package)

    parts: List[str] = []
    if apt_packages:
        pkgs = " ".join(apt_packages)
        parts.append(f"apt-get update && apt-get install -y {pkgs}")
    if pip_packages:
        pkgs = " ".join(pip_packages)
        parts.append(f"pip install {pkgs}")

    if not parts:
        return None

    return " && ".join(parts)


def run_install(command: str,
                progress: Optional[Callable[[str], None]] = None,
                finished: Optional[Callable[[bool, str], None]] = None) -> None:
    """Run an install command in a subprocess, forwarding output line by
    line to `progress` and the final result to `finished`.

    The command is run through `bash -c` so multi-part commands work.
    """
    def _run() -> None:
        try:
            proc = subprocess.Popen(
                ["bash", "-c", command],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                if progress:
                    progress(line.rstrip())
            proc.wait()
            ok = proc.returncode == 0
            if finished:
                finished(ok, "" if ok else f"exit code {proc.returncode}")
        except Exception as exc:  # noqa: BLE001
            if finished:
                finished(False, str(exc))

    import threading
    threading.Thread(target=_run, daemon=True).start()


def has_privilege_escalation() -> tuple[bool, str]:
    """Return (has_escalation, method).

    method is one of "pkexec", "sudo", "none".
    """
    if shutil.which("pkexec"):
        return True, "pkexec"
    if shutil.which("sudo"):
        return True, "sudo"
    return False, "none"


def build_privileged_command(command: str) -> Optional[str]:
    """Wrap a command in pkexec or sudo for privilege escalation."""
    has_esc, method = has_privilege_escalation()
    if not has_esc:
        return None
    if method == "pkexec":
        return f"pkexec bash -c {shell_quote(command)}"
    return f"sudo bash -c {shell_quote(command)}"


def shell_quote(s: str) -> str:
    """Single-quote a string for safe use in a shell command."""
    return "'" + s.replace("'", "'\"'\"'") + "'"
