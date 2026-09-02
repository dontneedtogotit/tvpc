"""Entry point: `python -m tvpc_cameras_gui`."""
from __future__ import annotations

import argparse
import sys
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


def main(argv: Optional[List[str]] = None) -> int:
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
