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
    QGridLayout, QSizePolicy, QComboBox, QMenu, QFileDialog,
)

from . import config as cfg
from .config import Camera
from .edit_dialog import CameraEditDialog
from .pip import PipManager
from .preview import PreviewWidget
from .scan_dialog import ScanDialog
from .recording import RecordingManager
from .notifications import send as notify, send_camera_online, send_camera_offline
from .health import start_health_monitor


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
        self._recording = RecordingManager()
        self._previews: List[PreviewWidget] = []
        self._selected_index: int = -1
        self._current_layout = "2x2"
        self._health_thread = None
        self._health_worker = None
        self._camera_status: dict[str, bool] = {}

        self._build_toolbar()
        self._build_central()
        self.setStatusBar(QStatusBar(self))
        self._set_status_ready()

        # Periodically reap dead mpv processes so the count stays accurate.
        self._reap_timer = QTimer(self)
        self._reap_timer.setInterval(500)
        self._reap_timer.timeout.connect(self._on_reap)
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
        act_open.setShortcut("P")
        act_open.triggered.connect(self._action_open_pip)
        tb.addAction(act_open)

        act_fullscreen = QAction("⛶  Fullscreen", self)
        act_fullscreen.setShortcut("F")
        act_fullscreen.triggered.connect(self._action_fullscreen)
        tb.addAction(act_fullscreen)

        act_grid = QAction("▦  Grid", self)
        act_grid.setShortcut("G")
        act_grid.triggered.connect(self._action_cycle_grid)
        tb.addAction(act_grid)

        act_record = QAction("⏺  Record", self)
        act_record.setShortcut("R")
        act_record.triggered.connect(self._action_toggle_record)
        tb.addAction(act_record)

        act_snapshot = QAction("📷  Snapshot", self)
        act_snapshot.setShortcut("S")
        act_snapshot.triggered.connect(self._action_snapshot)
        tb.addAction(act_snapshot)

        act_close_pip = QAction("✕  Close PiP windows", self)
        act_close_pip.setShortcut("Escape")
        act_close_pip.triggered.connect(self._action_close_pip)

        tb.addSeparator()

        act_history = QAction("🎞  Recordings", self)
        act_history.triggered.connect(self._action_show_history)
        tb.addAction(act_history)

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

        # Left: list of cameras with group filter.
        left = QWidget(central)
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 0, 0)

        list_header = QHBoxLayout()
        list_header.addWidget(QLabel("<b>Cameras</b>"))
        list_header.addStretch(1)
        self._group_filter = QComboBox()
        self._group_filter.addItem("All groups")
        self._group_filter.currentTextChanged.connect(self._on_group_filter_changed)
        list_header.addWidget(self._group_filter)
        left_layout.addLayout(list_header)

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

        preview_header = QHBoxLayout()
        preview_header.addWidget(QLabel("<b>Live previews</b>"))
        preview_header.addStretch(1)
        self._layout_label = QLabel("2×2")
        preview_header.addWidget(QLabel("Layout:"))
        preview_header.addWidget(self._layout_label)
        right_layout.addLayout(preview_header)

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
            ("⛶ Fullscreen", self._action_fullscreen),
            ("⏺ Record", self._action_toggle_record),
            ("📷 Snapshot", self._action_snapshot),
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
        self._rebuild_group_filter(cams)

        # Show empty state if no cameras.
        has_cams = len(cams) > 0
        self._empty_state.setVisible(not has_cams)
        self._grid_wrap.setVisible(has_cams)

        self._set_status_ready(f"Loaded {len(cams)} camera(s) from {cfg.config_path()}")

        # Restart health monitor with new camera list.
        self._start_health_monitor(cams)

    def _rebuild_group_filter(self, cams: List[Camera]) -> None:
        current = self._group_filter.currentText()
        self._group_filter.blockSignals(True)
        self._group_filter.clear()
        self._group_filter.addItem("All groups")
        groups = sorted({c.group for c in cams if c.group})
        for g in groups:
            self._group_filter.addItem(g)
        idx = self._group_filter.findText(current)
        if idx >= 0:
            self._group_filter.setCurrentIndex(idx)
        self._group_filter.blockSignals(False)

    def _on_group_filter_changed(self, text: str) -> None:
        cams = cfg.load_cameras()
        if text == "All groups":
            filtered = cams
        else:
            filtered = [c for c in cams if c.group == text]
        self._list.clear()
        for cam in filtered:
            item = QListWidgetItem(cam.display())
            self._list.addItem(item)
        self._rebuild_previews(filtered)

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

        # Determine grid size from layout.
        layout_cols = {"1x1": 1, "2x2": 2, "3x3": 3, "4x4": 4, "1+3": 2}
        cols = layout_cols.get(self._current_layout, 2)
        max_cams = cols * cols if self._current_layout != "1+3" else 4

        for idx, cam in enumerate(cams[:max_cams]):
            prev = PreviewWidget(self._grid_wrap)
            prev.clicked.connect(lambda i=idx: self._select_index(i))
            # Restore online status if known.
            if cam.name in self._camera_status:
                prev.set_online_status(self._camera_status[cam.name])
            self._grid.addWidget(prev, idx // cols, idx % cols)
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

    def _visible_cameras(self) -> List[Camera]:
        """Return the cameras currently shown in the preview grid."""
        cams = cfg.load_cameras()
        layout_cols = {"1x1": 1, "2x2": 2, "3x3": 3, "4x4": 4, "1+3": 2}
        cols = layout_cols.get(self._current_layout, 2)
        max_cams = cols * cols if self._current_layout != "1+3" else 4
        return cams[:max_cams]

    # --- health monitoring -------------------------------------------------
    def _start_health_monitor(self, cams: List[Camera]) -> None:
        if self._health_thread is not None:
            if self._health_worker is not None:
                self._health_worker.cancel()
            self._health_thread.quit()
            self._health_thread.wait(1000)
            self._health_thread = None
            self._health_worker = None

        if not cams:
            return

        self._health_thread, self._health_worker = start_health_monitor(
            self, cams, interval=30.0,
            on_status_change=self._on_health_status_changed,
        )

    def _on_health_status_changed(self, name: str, online: bool, url: str) -> None:
        self._camera_status[name] = online
        # Update preview widget if visible.
        for prev in self._previews:
            if prev._caption.text() == name:
                prev.set_online_status(online)
        # Notify on transitions.
        if not online:
            send_camera_offline(name)
        elif name in self._camera_status and not self._camera_status.get(name):
            send_camera_online(name)

    # --- actions -----------------------------------------------------------
    def _action_add(self) -> None:
        dlg = CameraEditDialog(self)
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
        result = self._pip.open_one(cam, fullscreen=False)
        if result is None:
            QMessageBox.warning(self, "Failed", "Could not launch mpv.")
        else:
            self._set_status_ready(f"Opened {cam.name} in PiP (pid {result.proc.pid})")

    def _action_fullscreen(self) -> None:
        if not self._pip.is_available():
            QMessageBox.warning(self, "mpv missing",
                                "mpv is not installed. Run: sudo apt-get install mpv")
            return
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        _, cam = sel
        result = self._pip.open_one(cam, fullscreen=True)
        if result is None:
            QMessageBox.warning(self, "Failed", "Could not launch mpv.")
        else:
            self._set_status_ready(f"Opened {cam.name} fullscreen (pid {result.proc.pid})")

    def _action_cycle_grid(self) -> None:
        layouts = ["1x1", "2x2", "3x3", "4x4", "1+3"]
        idx = layouts.index(self._current_layout) if self._current_layout in layouts else 0
        self._current_layout = layouts[(idx + 1) % len(layouts)]
        self._layout_label.setText(self._current_layout.replace("x", "×"))
        self._rebuild_previews(self._visible_cameras())
        self._set_status_ready(f"Layout: {self._current_layout}")

    def _action_open_grid(self) -> None:
        if not self._pip.is_available():
            QMessageBox.warning(self, "mpv missing",
                                "mpv is not installed. Run: sudo apt-get install mpv")
            return
        cams = cfg.load_cameras()
        if not cams:
            QMessageBox.information(self, "No cameras", "Add at least one camera first.")
            return
        layout_cols = {"1x1": 1, "2x2": 2, "3x3": 3, "4x4": 4, "1+3": 2}
        cols = layout_cols.get(self._current_layout, 2)
        opened = self._pip.open_grid(cams, cols=cols)
        self._set_status_ready(f"Opened {opened} PiP window(s) in {self._current_layout} grid")

    def _action_toggle_record(self) -> None:
        if not self._recording.is_available():
            QMessageBox.warning(self, "ffmpeg missing",
                                "ffmpeg is not installed. Run: sudo apt-get install ffmpeg")
            return
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        _, cam = sel
        rec = self._recording.toggle(cam)
        if rec:
            notify("Recording started", f"Recording {cam.name} to disk.")
            self._set_status_ready(f"⏺ Recording {cam.name} ({rec.file_path.name})")
        else:
            notify("Recording stopped", f"Saved recording of {cam.name}.")
            self._set_status_ready(f"Stopped recording {cam.name}")

    def _action_snapshot(self) -> None:
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        _, cam = sel
        # Find the matching preview widget.
        for prev in self._previews:
            if prev._caption.text() == cam.name:
                path = prev.snapshot()
                if path:
                    self._set_status_ready(f"📷 Saved snapshot: {path.name}")
                else:
                    QMessageBox.warning(self, "Failed", "No frame available to save.")
                return
        QMessageBox.information(self, "Not visible", "Camera is not in the current preview grid.")

    def _action_close_pip(self) -> None:
        self._pip.close_all()
        self._set_status_ready("Closed all PiP windows.")

    def _action_show_history(self) -> None:
        from .recording_history import RecordingHistoryDialog
        dlg = RecordingHistoryDialog(self)
        dlg.exec()

    # --- periodic reap -----------------------------------------------------
    def _on_reap(self) -> None:
        self._pip.reap()
        # Update recording indicator in status bar.
        active = self._recording.active_recordings()
        if active:
            names = ", ".join(r.camera.name for r in active)
            dur = active[0].display_duration
            self.statusBar().showMessage(f"⏺ Recording: {names} ({dur})  |  {self._recording.disk_usage()} used")

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
        self._recording.stop_all()
        if self._health_worker is not None:
            self._health_worker.cancel()
        if self._health_thread is not None:
            self._health_thread.quit()
            self._health_thread.wait(2000)
        super().closeEvent(event)
