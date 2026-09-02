"""Main application window."""
from __future__ import annotations

import shutil
from pathlib import Path
from typing import List, Optional

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QListWidget,
    QListWidgetItem, QPushButton, QToolBar, QStatusBar, QMessageBox,
    QGridLayout, QSizePolicy, QFrame,
)

from . import config as cfg
from .config import Camera
from .edit_dialog import CameraEditDialog
from .pip import PipManager
from .preview import PreviewWidget
from .scan_dialog import ScanDialog


class EmptyStateWidget(QWidget):
    """Shown when no cameras are configured."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)

        title = QLabel("No cameras yet")
        title.setStyleSheet("font-size: 18px; font-weight: bold;")
        title.setAlignment(Qt.AlignCenter)

        body = QLabel(
            "You can add cameras in two ways:\n\n"
            "  1. Scan your network — the app will look for cameras "
            "automatically.\n"
            "  2. Add a camera manually if you know its stream URL "
            "(rtsp:// or http://).\n\n"
            "Click <b>Scan network</b> to get started."
        )
        body.setWordWrap(True)
        body.setAlignment(Qt.AlignCenter)
        body.setStyleSheet("color: #555;")

        scan_btn = QPushButton("🔍  Scan network for cameras")
        scan_btn.setStyleSheet("padding: 10px 20px; font-size: 14px;")
        scan_btn.clicked.connect(lambda: self.parent()._action_scan())  # type: ignore[attr-defined]

        add_btn = QPushButton("➕  Add camera manually")
        add_btn.setStyleSheet("padding: 8px 16px;")
        add_btn.clicked.connect(lambda: self.parent()._action_add())  # type: ignore[attr-defined]

        btn_row = QHBoxLayout()
        btn_row.addStretch(1)
        btn_row.addWidget(scan_btn)
        btn_row.addWidget(add_btn)
        btn_row.addStretch(1)

        layout = QVBoxLayout(self)
        layout.addStretch(1)
        layout.addWidget(title)
        layout.addSpacing(12)
        layout.addWidget(body)
        layout.addSpacing(24)
        layout.addLayout(btn_row)
        layout.addStretch(1)


class MainWindow(QMainWindow):
    """Grid of live preview thumbnails + camera list, with toolbar actions."""

    def __init__(self, default_user: str = "", default_pass: str = "") -> None:
        super().__init__()
        self.setWindowTitle("tvpc Cameras")
        self.resize(1280, 760)

        self._default_user = default_user
        self._default_pass = default_pass
        self._pip = PipManager()
        self._previews: List[PreviewWidget] = []
        self._selected_index: int = -1

        self._build_toolbar()
        self._build_central()
        self.setStatusBar(QStatusBar(self))
        self._set_status_ready()

        # Periodically reap dead mpv processes so the count stays accurate.
        self._reap_timer = QTimer(self)
        self._reap_timer.setInterval(5000)
        self._reap_timer.timeout.connect(self._pip.reap)
        self._reap_timer.start()

        self.reload()

    # --- UI construction ---------------------------------------------------
    def _build_toolbar(self) -> None:
        tb = QToolBar("Main", self)
        tb.setMovable(False)
        self.addToolBar(tb)

        act_add = QAction("➕  Add", self)
        act_add.setShortcut(QKeySequence.New)
        act_add.triggered.connect(self._action_add)
        tb.addAction(act_add)

        act_edit = QAction("✏️  Edit", self)
        act_edit.triggered.connect(self._action_edit)
        tb.addAction(act_edit)

        act_remove = QAction("🗑  Remove", self)
        act_remove.setShortcut(QKeySequence.Delete)
        act_remove.triggered.connect(self._action_remove)
        tb.addAction(act_remove)

        tb.addSeparator()

        act_scan = QAction("🔍  Scan network", self)
        act_scan.triggered.connect(self._action_scan)
        tb.addAction(act_scan)

        act_open = QAction("📺  Open PiP", self)
        act_open.triggered.connect(self._action_open_pip)
        tb.addAction(act_open)

        act_grid = QAction("▦  Open 2×2 grid", self)
        act_grid.triggered.connect(self._action_open_grid)
        tb.addAction(act_grid)

        act_close_pip = QAction("✕  Close PiP windows", self)
        act_close_pip.triggered.connect(self._action_close_pip)
        tb.addAction(act_close_pip)

        tb.addSeparator()

        act_reload = QAction("⟳  Reload", self)
        act_reload.setShortcut(QKeySequence.Refresh)
        act_reload.triggered.connect(self.reload)
        tb.addAction(act_reload)

    def _build_central(self) -> None:
        central = QWidget(self)
        outer = QHBoxLayout(central)
        outer.setContentsMargins(8, 8, 8, 8)
        outer.setSpacing(8)

        # Left: list of cameras.
        left = QWidget(central)
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.addWidget(QLabel("<b>Cameras</b>"))
        self._list = QListWidget(left)
        self._list.itemSelectionChanged.connect(self._on_select)
        self._list.itemDoubleClicked.connect(lambda _i: self._action_edit())
        left_layout.addWidget(self._list, 1)

        list_btns = QHBoxLayout()
        for text, slot in (
            ("➕ Add", self._action_add),
            ("✏️ Edit", self._action_edit),
            ("🗑 Remove", self._action_remove),
        ):
            b = QPushButton(text, left)
            b.clicked.connect(slot)
            list_btns.addWidget(b)
        left_layout.addLayout(list_btns)

        outer.addWidget(left, 1)

        # Right: preview grid (or empty state).
        right = QWidget(central)
        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(0, 0, 0, 0)
        right_layout.addWidget(QLabel("<b>Live previews</b>"))
        self._grid_wrap = QWidget(right)
        self._grid = QGridLayout(self._grid_wrap)
        self._grid.setContentsMargins(0, 0, 0, 0)
        self._grid.setSpacing(8)
        right_layout.addWidget(self._grid_wrap, 1)

        # Empty state overlay.
        self._empty_state = EmptyStateWidget(right)
        self._empty_state.setVisible(False)
        right_layout.addWidget(self._empty_state)

        # Buttons under the grid.
        grid_btns = QHBoxLayout()
        for text, slot in (
            ("📺 Open selected in PiP", self._action_open_pip),
            ("▦ Open all in 2×2 grid", self._action_open_grid),
        ):
            b = QPushButton(text, right)
            b.clicked.connect(slot)
            grid_btns.addWidget(b)
        right_layout.addLayout(grid_btns)

        outer.addWidget(right, 3)

        self.setCentralWidget(central)

    # --- data loading ------------------------------------------------------
    def reload(self) -> None:
        cams = cfg.load_cameras()
        self._list.clear()
        for cam in cams:
            item = QListWidgetItem(cam.display())
            self._list.addItem(item)
        self._rebuild_previews(cams)

        # Show empty state if no cameras.
        has_cams = len(cams) > 0
        self._empty_state.setVisible(not has_cams)
        self._grid_wrap.setVisible(has_cams)

        self._set_status_ready(f"Loaded {len(cams)} camera(s) from {cfg.config_path()}")

    def _rebuild_previews(self, cams: List[Camera]) -> None:
        # Stop and remove existing previews.
        for prev in self._previews:
            prev.stop()
            prev.setParent(None)
            prev.deleteLater()
        self._previews.clear()
        for i in reversed(range(self._grid.count())):
            item = self._grid.itemAt(i)
            if item is not None:
                w = item.widget()
                if w is not None:
                    w.setParent(None)

        for idx, cam in enumerate(cams[:4]):
            prev = PreviewWidget(self._grid_wrap)
            prev.clicked.connect(lambda i=idx: self._select_index(i))
            self._grid.addWidget(prev, idx // 2, idx % 2)
            self._previews.append(prev)
            prev.start(cam.url, cam.user, cam.password, caption=cam.name)

    # --- selection ---------------------------------------------------------
    def _on_select(self) -> None:
        row = self._list.currentRow()
        self._select_index(row)

    def _select_index(self, idx: int) -> None:
        self._selected_index = idx
        cams = cfg.load_cameras()
        if 0 <= idx < len(cams):
            self._list.setCurrentRow(idx)

    def _selected_camera(self) -> Optional[tuple[int, Camera]]:
        cams = cfg.load_cameras()
        idx = self._selected_index if self._selected_index >= 0 else self._list.currentRow()
        if 0 <= idx < len(cams):
            return idx, cams[idx]
        return None

    # --- actions -----------------------------------------------------------
    def _action_add(self) -> None:
        dlg = CameraEditDialog(self)
        # Pre-fill with default credentials if set.
        if self._default_user:
            dlg._user.setText(self._default_user)
        if self._default_pass:
            dlg._pass.setText(self._default_pass)
        if dlg.exec() == dlg.Accepted:
            cam = dlg.get_camera()
            cams = cfg.load_cameras()
            if any(c.url == cam.url for c in cams):
                QMessageBox.warning(self, "Duplicate",
                                    "A camera with that URL already exists.")
                return
            cams.append(cam)
            cfg.save_cameras(cams)
            self.reload()

    def _action_edit(self) -> None:
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        idx, cam = sel
        dlg = CameraEditDialog(self, camera=cam)
        if dlg.exec() == dlg.Accepted:
            cfg.update_camera(idx, dlg.get_camera())
            self.reload()

    def _action_remove(self) -> None:
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        idx, cam = sel
        ok = QMessageBox.question(
            self, "Remove camera",
            f"Remove '{cam.name}'?",
        )
        if ok == QMessageBox.Yes:
            cfg.remove_camera(idx)
            self._selected_index = -1
            self.reload()

    def _action_scan(self) -> None:
        dlg = ScanDialog(self)
        # Pre-fill with default credentials if set.
        if self._default_user:
            dlg._user.setText(self._default_user)
        if self._default_pass:
            dlg._pass.setText(self._default_pass)
        if dlg.exec() == dlg.Accepted:
            self.reload()

    def _action_open_pip(self) -> None:
        if not self._pip.is_available():
            QMessageBox.warning(self, "mpv missing",
                                "mpv is not installed. Run: sudo apt-get install mpv")
            return
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        _, cam = sel
        result = self._pip.open_one(cam)
        if result is None:
            QMessageBox.warning(self, "Failed", "Could not launch mpv.")
        else:
            self._set_status_ready(f"Opened {cam.name} in PiP (pid {result.proc.pid})")

    def _action_open_grid(self) -> None:
        if not self._pip.is_available():
            QMessageBox.warning(self, "mpv missing",
                                "mpv is not installed. Run: sudo apt-get install mpv")
            return
        cams = cfg.load_cameras()[:4]
        if not cams:
            QMessageBox.information(self, "No cameras", "Add at least one camera first.")
            return
        opened = self._pip.open_grid(cams)
        self._set_status_ready(f"Opened {opened} PiP window(s) in 2×2 grid")

    def _action_close_pip(self) -> None:
        self._pip.close_all()
        self._set_status_ready("Closed all PiP windows.")

    # --- status ------------------------------------------------------------
    def _set_status_ready(self, msg: str = "") -> None:
        cams = cfg.load_cameras()
        self.statusBar().showMessage(
            msg or f"{len(cams)} camera(s)  |  config: {cfg.config_path()}"
        )

    # --- shutdown ----------------------------------------------------------
    def closeEvent(self, event) -> None:  # noqa: N802
        for prev in self._previews:
            prev.stop()
        self._pip.close_all()
        super().closeEvent(event)
