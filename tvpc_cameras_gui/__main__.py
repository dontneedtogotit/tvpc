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
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])

    # Apply optional config override before importing config module users.
    if args.config:
        from pathlib import Path
        import tvpc_cameras_gui.config as cfg
        cfg.CONF_FILE = Path(args.config).expanduser()

    try:
        from PySide6.QtWidgets import QApplication
    except ImportError:
        print("tvpc-cameras-gui: PySide6 is required. Install with:\n"
              "  sudo apt-get install python3-pyside6\n"
              "or\n"
              "  pip install PySide6", file=sys.stderr)
        return 1

    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName("tvpc-cameras-gui")

    from .main_window import MainWindow
    win = MainWindow()
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
