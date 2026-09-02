"""Entry point: `python -m tvpc_cameras_gui`."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import List, Optional


def _parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="tvpc-cameras-gui",
        description="PySide6 GUI for tvpc IP security cameras.",
    )
    p.add_argument("--config", help="Override config file path (default: ~/.config/tvpc/cameras.conf)")
    p.add_argument("--skip-wizard", action="store_true", help="Skip the first-run wizard")
    return p.parse_args(argv)


def _ensure_pyside6() -> bool:
    """Make sure PySide6 is importable.

    If it's missing, try to install it via pip. Returns True if PySide6
    can be imported after this function returns.
    """
    try:
        import PySide6  # noqa: F401
        return True
    except ImportError:
        pass

    import subprocess
    print("PySide6 is not installed. Attempting to install via pip...", file=sys.stderr)
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "PySide6"])
        import PySide6  # noqa: F401
        return True
    except Exception as exc:  # noqa: BLE0001
        print(
            f"Could not install PySide6 automatically: {exc}\n"
            "Please install it manually:\n"
            "  pip install PySide6\n"
            "or on Ubuntu/Debian:\n"
            "  sudo apt-get install python3-pyside6",
            file=sys.stderr,
        )
        return False


def _ensure_venv() -> int:
    """Ensure we're running in the auto-created virtual environment.

    If not running in the venv, create it if needed, install dependencies,
    then re-exec ourselves using the venv's Python interpreter.

    Returns 0 if we should continue running in the current process,
    or -1 if we've re-execed into the venv and should not return.
    """
    from .venv_mgr import is_running_in_venv, ensure_venv, get_venv_python, install_in_venv

    # Already running in the venv — continue normally.
    if is_running_in_venv():
        return 0

    # Not in venv — set one up.
    venv_python = get_venv_python()
    if venv_python == Path(sys.executable):
        # We're already in the right place somehow.
        return 0

    print("tvpc-cameras-gui: setting up a virtual environment...", file=sys.stderr)

    # Create the venv if it doesn't exist.
    if not ensure_venv(progress=lambda msg: print(f"  {msg}", file=sys.stderr)):
        print("Failed to create virtual environment.", file=sys.stderr)
        return 0  # Fall back to system Python.

    # Install the runtime dependencies into the venv.
    deps = ["PySide6", "requests"]
    if not install_in_venv(deps, progress=lambda msg: print(f"  {msg}", file=sys.stderr)):
        print("Failed to install dependencies in virtual environment.", file=sys.stderr)
        return 0  # Fall back to system Python.

    # Re-exec ourselves in the venv.
    sys.stdout.flush()
    sys.stderr.flush()
    os.execv(str(venv_python), [str(venv_python), "-m", "tvpc_cameras_gui"] + sys.argv[1:])
    return -1  # Not reached — execv replaces the process.


def main(argv: Optional[List[str]] = None) -> int:
    # Step 0: Ensure we're running in the auto-created virtual environment.
    # This will create the venv, install deps, and re-exec us inside it.
    result = _ensure_venv()
    if result == -1:
        # We've been re-execed — don't run _ensure_venv again.
        pass
    elif result == 0:
        # Already in the venv — proceed normally.
        pass
    else:
        # venv creation failed, but we can still try to proceed.
        print(
            "Note: Running outside virtual environment; PySide6 may need to be installed manually.",
            file=sys.stderr,
        )

    args = _parse_args(argv if argv is not None else sys.argv[1:])

    # Apply optional config override before importing config module users.
    if args.config:
        from pathlib import Path
        from . import config as cfg
        cfg.CONF_FILE = Path(args.config).expanduser()

    # Step 1: make sure PySide6 is available.
    if not _ensure_pyside6():
        return 1

    # Now safe to import Qt.
    from PySide6.QtWidgets import QApplication
    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName("tvpc-cameras-gui")

    # Step 2: run the first-run wizard (unless skipped).
    default_user = ""
    default_pass = ""
    if not args.skip_wizard:
        from . import deps as deps_mod
        report = deps_mod.check_dependencies()
        if not report.all_found:
            from .wizard import run_first_run_wizard
            accepted, (default_user, default_pass) = run_first_run_wizard()
            if not accepted:
                return 0
            # Re-check after wizard.
            report = deps_mod.check_dependencies()
            if not report.all_found:
                from PySide6.QtWidgets import QMessageBox
                QMessageBox.critical(
                    None,
                    "Dependencies missing",
                    "Some required dependencies are still missing. "
                    "Please install them and try again.",
                )
                return 1

    # Step 3: show the main window.
    from .main_window import MainWindow
    win = MainWindow(default_user=default_user, default_pass=default_pass)
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
