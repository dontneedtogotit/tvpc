"""Virtual environment management for tvpc-cameras-gui.

Handles creation, activation, and dependency installation in a local venv.
"""
from __future__ import annotations

import os
import subprocess
import sys
import venv
from pathlib import Path
from typing import Optional


VENV_DIR_NAME = "tvpc-cameras-gui-venv"
VENV_BASE_DIR = Path.home() / ".local" / "share" / "tvpc"


def get_venv_path() -> Path:
    """Return the path to the virtual environment directory."""
    return VENV_BASE_DIR / VENV_DIR_NAME


def get_venv_python() -> Path:
    """Return the path to the venv's Python executable."""
    venv_path = get_venv_path()
    if sys.platform == "win32":
        return venv_path / "Scripts" / "python.exe"
    return venv_path / "bin" / "python"


def get_venv_pip() -> Path:
    """Return the path to the venv's pip executable."""
    venv_path = get_venv_path()
    if sys.platform == "win32":
        return venv_path / "Scripts" / "pip.exe"
    return venv_path / "bin" / "pip"


def venv_exists() -> bool:
    """Check if the virtual environment exists and is valid."""
    python_path = get_venv_python()
    return python_path.exists()


def create_venv(progress: Optional[callable] = None) -> bool:
    """Create a new virtual environment.

    Args:
        progress: Optional callback for progress updates (receives string messages)

    Returns:
        True if creation succeeded, False otherwise
    """
    venv_path = get_venv_path()

    try:
        venv_path.parent.mkdir(parents=True, exist_ok=True)

        if progress:
            progress(f"Creating virtual environment at {venv_path}...")

        builder = venv.EnvBuilder(with_pip=True, clear=True)
        builder.create(venv_path)

        if progress:
            progress("Virtual environment created successfully.")

        return True

    except Exception as e:
        if progress:
            progress(f"Failed to create virtual environment: {e}")
        return False


def ensure_venv(progress: Optional[callable] = None) -> bool:
    """Ensure the virtual environment exists, creating it if necessary.

    Args:
        progress: Optional callback for progress updates

    Returns:
        True if venv is ready, False otherwise
    """
    if venv_exists():
        return True

    return create_venv(progress)


def install_in_venv(packages: list[str],
                    progress: Optional[callable] = None) -> bool:
    """Install packages into the virtual environment using pip.

    Args:
        packages: List of package names to install
        progress: Optional callback for progress updates

    Returns:
        True if installation succeeded, False otherwise
    """
    pip_path = get_venv_pip()

    if not pip_path.exists():
        if progress:
            progress("Virtual environment pip not found. Creating venv first...")
        if not create_venv(progress):
            return False

    try:
        cmd = [str(pip_path), "install", "--quiet"] + packages

        if progress:
            progress(f"Installing packages: {', '.join(packages)}")

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,
        )

        if result.returncode == 0:
            if progress:
                progress("Packages installed successfully.")
            return True
        else:
            if progress:
                progress(f"Installation failed: {result.stderr}")
            return False

    except subprocess.TimeoutExpired:
        if progress:
            progress("Installation timed out after 5 minutes.")
        return False
    except Exception as e:
        if progress:
            progress(f"Installation error: {e}")
        return False


def run_in_venv(module: str, args: list[str] = None) -> int:
    """Run a Python module in the virtual environment.

    Args:
        module: Module to run (e.g., 'tvpc_cameras_gui')
        args: Additional arguments to pass to the module

    Returns:
        Exit code from the subprocess
    """
    python_path = get_venv_python()

    if not python_path.exists():
        raise RuntimeError(f"Virtual environment not found at {python_path}. "
                           "Run ensure_venv() first.")

    cmd = [str(python_path), "-m", module]
    if args:
        cmd.extend(args)

    os.execv(str(python_path), cmd)
    return 1


def is_running_in_venv() -> bool:
    """Check if the current process is running inside the virtual environment."""
    return Path(sys.prefix) == get_venv_path()


def get_venv_site_packages() -> Path:
    """Return the path to the venv's site-packages directory."""
    venv_path = get_venv_path()
    if sys.platform == "win32":
        return venv_path / "Lib" / "site-packages"
    return venv_path / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages"


def get_venv_info() -> dict:
    """Return information about the virtual environment."""
    return {
        "path": str(get_venv_path()),
        "python": str(get_venv_python()),
        "pip": str(get_venv_pip()),
        "exists": venv_exists(),
        "running_in_venv": is_running_in_venv(),
    }