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


def _has_pyside6() -> bool:
    try:
        import PySide6  # noqa: F401
        return True
    except ImportError:
        return False


def _ensure_pyside6() -> bool:
    """Make sure PySide6 is importable."""
    if _has_pyside6():
        return True

    print(
        "PySide6 is not installed.\n"
        "Please install it:\n"
        "  sudo apt-get install python3-pyside6 python3-requests\n"
        "or: pip install PySide6 requests",
        file=sys.stderr,
    )
    return False


def _ensure_venv() -> int:
    """Ensure we're running in the auto-created virtual environment if needed.

    If PySide6 is already available in the current environment, returns 0 immediately.
    Otherwise creates/uses a local venv with PySide6 and re-execs into it.
    """
    if _has_pyside6():
        return 0

    from .venv_mgr import is_running_in_venv, ensure_venv, get_venv_python, install_in_venv

    # Already running in the venv — continue normally.
    if is_running_in_venv():
        return 0

    # Not in venv — set one up.
    venv_python = get_venv_python()
    if venv_python == Path(sys.executable):
        return 0

    print("tvpc-cameras-gui: PySide6 missing from system; setting up virtual environment...", file=sys.stderr)

    # Create the venv if it doesn't exist.
    if not ensure_venv(progress=lambda msg: print(f"  {msg}", file=sys.stderr)):
        print("Failed to create virtual environment.", file=sys.stderr)
        return 0  # Fall back to system Python.

    # Install the runtime dependencies into the venv.
    deps = ["PySide6", "requests"]
    if not install_in_venv(deps, progress=lambda msg: print(f"  {msg}", file=sys.stderr)):
        print("Failed to install dependencies in virtual environment.", file=sys.stderr)
        return 0  # Fall back to system Python.

    # Re-exec ourselves in the venv, preserving PYTHONPATH so tvpc_cameras_gui is found.
    pkg_parent = str(Path(__file__).resolve().parent.parent)
    env = dict(os.environ)
    curr_pp = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = f"{pkg_parent}:{curr_pp}" if curr_pp else pkg_parent
    sys.stdout.flush()
    sys.stderr.flush()
    os.execve(str(venv_python), [str(venv_python), "-m", "tvpc_cameras_gui"] + sys.argv[1:], env)
    return -1


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

    app.setStyleSheet(
        "QMainWindow, QDialog { background-color: #18181b; color: #f4f4f5; }"
        "QWidget { color: #f4f4f5; font-family: 'Segoe UI', 'Ubuntu', 'Cantarell', sans-serif; font-size: 13px; }"
        "QToolBar { background-color: #202024; border-bottom: 1px solid #2e2e34; spacing: 6px; padding: 6px; }"
        "QToolBar QToolButton { background-color: transparent; color: #f4f4f5; padding: 6px 10px; border-radius: 6px; font-weight: 500; }"
        "QToolBar QToolButton:hover { background-color: #2e2e34; }"
        "QToolBar QToolButton:pressed { background-color: #3b82f6; color: white; }"
        "QToolBar::separator { background-color: #383842; width: 1px; margin: 4px 6px; }"
        "QStatusBar { background-color: #202024; color: #a1a1aa; border-top: 1px solid #2e2e34; padding: 4px; }"
        "QListWidget { background-color: #202024; color: #f4f4f5; border: 1px solid #2e2e34; border-radius: 8px; outline: none; padding: 4px; }"
        "QListWidget::item { padding: 8px 10px; border-radius: 6px; margin: 2px 0; }"
        "QListWidget::item:hover { background-color: #2a2a30; }"
        "QListWidget::item:selected { background-color: #2563eb; color: #ffffff; }"
        "QPushButton { background-color: #27272a; color: #f4f4f5; border: 1px solid #3f3f46; padding: 6px 14px; border-radius: 6px; font-weight: 500; }"
        "QPushButton:hover { background-color: #3f3f46; border-color: #52525b; }"
        "QPushButton:pressed { background-color: #1d4ed8; color: white; border-color: #2563eb; }"
        "QPushButton:disabled { background-color: #1f1f23; color: #71717a; border-color: #27272a; }"
        "QLineEdit, QTextEdit { background-color: #202024; color: #f4f4f5; border: 1px solid #3f3f46; padding: 6px 10px; border-radius: 6px; selection-background-color: #2563eb; }"
        "QLineEdit:focus, QTextEdit:focus { border: 1px solid #38bdf8; }"
        "QComboBox { background-color: #27272a; color: #f4f4f5; border: 1px solid #3f3f46; padding: 6px 10px; border-radius: 6px; }"
        "QComboBox:focus { border: 1px solid #38bdf8; }"
        "QComboBox QAbstractItemView { background-color: #202024; color: #f4f4f5; border: 1px solid #3f3f46; selection-background-color: #2563eb; outline: none; border-radius: 6px; }"
        "QLabel { color: #f4f4f5; }"
        "QGroupBox { color: #f4f4f5; border: 1px solid #3f3f46; border-radius: 8px; margin-top: 12px; padding: 12px; font-weight: 600; }"
        "QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 6px; }"
        "QCheckBox { color: #f4f4f5; spacing: 8px; }"
        "QCheckBox::indicator { width: 16px; height: 16px; border-radius: 4px; border: 1px solid #52525b; background-color: #202024; }"
        "QCheckBox::indicator:checked { background-color: #2563eb; border-color: #3b82f6; image: none; }"
        "QProgressBar { background-color: #202024; border: 1px solid #3f3f46; border-radius: 6px; text-align: center; color: #f4f4f5; height: 16px; }"
        "QProgressBar::chunk { background-color: #2563eb; border-radius: 5px; }"
        "QMenu { background-color: #202024; color: #f4f4f5; border: 1px solid #3f3f46; border-radius: 8px; padding: 4px; }"
        "QMenu::item { padding: 6px 20px; border-radius: 4px; }"
        "QMenu::item:selected { background-color: #2563eb; color: white; }"
        "QMenu::separator { background-color: #3f3f46; height: 1px; margin: 4px 6px; }"
        "QTabWidget::pane { border: 1px solid #3f3f46; border-radius: 6px; background-color: #202024; }"
        "QTabBar::tab { background-color: #27272a; color: #a1a1aa; padding: 8px 16px; border-top-left-radius: 6px; border-top-right-radius: 6px; margin-right: 2px; }"
        "QTabBar::tab:selected { background-color: #202024; color: #ffffff; font-weight: 600; }"
        "QTabBar::tab:hover:!selected { background-color: #333338; color: #f4f4f5; }"
        "QScrollBar:vertical { background-color: #18181b; width: 10px; margin: 0; border-radius: 5px; }"
        "QScrollBar::handle:vertical { background-color: #3f3f46; min-height: 20px; border-radius: 5px; }"
        "QScrollBar::handle:vertical:hover { background-color: #52525b; }"
        "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }"
    )

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

    from .settings import load_settings
    settings = load_settings()
    if not default_user:
        default_user = settings.get("default_user", "")
    if not default_pass:
        default_pass = settings.get("default_password", "")

    # Step 3: show the main window.
    from .main_window import MainWindow
    win = MainWindow(default_user=default_user, default_pass=default_pass)
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
