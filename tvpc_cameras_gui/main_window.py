"""Main application window."""
from __future__ import annotations

import shutil
from pathlib import Path
from typing import List, Optional

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QListWidget,
    QListWidgetItem, QPushButton, QToolBar, QStatusBar, QMessageBox,
    QGridLayout, QSizePolicy, QComboBox, QMenu, QFileDialog,
    QDialog, QDialogButtonBox, QFormLayout, QLineEdit, QTextEdit,
    QCheckBox, QGroupBox, QSplitter, QFrame, QSpinBox, QDoubleSpinBox,
)

from . import config as cfg
from .config import Camera
from .discover import DiscoveredCamera
from .edit_dialog import CameraEditDialog
from .pip import PipManager
from .preview import PreviewWidget
from .scan_dialog import ScanDialog
from .recording import RecordingManager
from .notifications import send as notify, send_camera_online, send_camera_offline
from .health import start_health_monitor
from .settings import SettingsDialog, load_settings, save_settings
from .brand_help import show_brand_help
from .hotplug import HotplugMonitor
from .motion import MotionDetector
from .storage import StorageManager
from .ptz import PtzDialog
from .v4l2 import is_v4l2, normalize_v4l2_device
from .ai_filter import ObjectFilter
from .popup import SmartPopupManager
from .bosch import BoschPanelClient, load_bosch_config


class EmptyStateWidget(QWidget):
    scan_requested = Signal()
    add_requested = Signal()
    readd_requested = Signal()

    def __init__(self, parent=None) -> None:
        super().__init__(parent)

        title = QLabel("No cameras yet")
        title.setStyleSheet("font-size: 22px; font-weight: bold; color: #4fc3f7;")
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
        body.setStyleSheet("color: #aaa; font-size: 13px;")

        scan_btn = QPushButton("🔍  Scan network for cameras")
        scan_btn.setStyleSheet(
            "padding: 12px 24px; font-size: 14px; "
            "background: #2a6ebb; border: none; color: white; border-radius: 6px;"
        )
        scan_btn.clicked.connect(self.scan_requested)

        add_btn = QPushButton("➕  Add camera manually")
        add_btn.setStyleSheet("padding: 10px 18px; border-radius: 6px;")
        add_btn.clicked.connect(self.add_requested)

        self._readd_btn = QPushButton("↩  Re-add from last scan")
        self._readd_btn.setStyleSheet("padding: 10px 18px; border-radius: 6px;")
        self._readd_btn.clicked.connect(self.readd_requested)
        self._readd_btn.setVisible(False)

        btn_row = QHBoxLayout()
        btn_row.addStretch(1)
        btn_row.addWidget(scan_btn)
        btn_row.addSpacing(12)
        btn_row.addWidget(add_btn)
        btn_row.addSpacing(12)
        btn_row.addWidget(self._readd_btn)
        btn_row.addStretch(1)

        layout = QVBoxLayout(self)
        layout.addStretch(1)
        layout.addWidget(title)
        layout.addSpacing(16)
        layout.addWidget(body)
        layout.addSpacing(32)
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
        self._storage = StorageManager()
        self._previews: List[PreviewWidget] = []
        self._selected_index: int = -1
        self._current_layout = cfg.load_layout()
        self._health_thread = None
        self._health_worker = None
        self._camera_status: dict[str, bool] = {}
        self._last_scan_results: List[DiscoveredCamera] = []
        self._settings = load_settings()

        # Smart TV PiP Pop-up manager
        self._popup_mgr = SmartPopupManager(
            self,
            duration_seconds=float(self._settings.get("popup_duration", 15.0)),
            cooldown_seconds=float(self._settings.get("popup_cooldown", 20.0)),
            sound_enabled=bool(self._settings.get("popup_sound", True)),
        )

        # AI Object Filter for Motion Detection
        ai_enabled = bool(self._settings.get("ai_filter_enabled", False))
        ai_target = str(self._settings.get("ai_target_mode", ObjectFilter.TARGET_PERSON_VEHICLE))
        self._ai_filter = ObjectFilter(target_mode=ai_target) if ai_enabled else None

        # Motion detector
        self._motion = MotionDetector(
            sensitivity=float(self._settings.get("motion_sensitivity", 0.12)),
            auto_snapshot=bool(self._settings.get("motion_auto_snapshot", True)),
            ai_filter=self._ai_filter,
        )
        self._motion.motion_detected.connect(self._on_motion_detected)

        # Bosch Security Alarm Client
        self._bosch = BoschPanelClient(load_bosch_config(), parent=self)
        self._bosch.zone_triggered.connect(self._on_bosch_zone_triggered)
        if self._bosch.config.enabled:
            self._bosch.start()

        # Hotplug & background discovery monitor
        self._pending_discovered: Optional[DiscoveredCamera] = None
        self._hotplug = HotplugMonitor(
            self,
            enable_network_watch=bool(self._settings.get("background_discovery", True)),
        )
        self._hotplug.v4l2_plugged.connect(self._on_v4l2_plugged)
        self._hotplug.v4l2_unplugged.connect(self._on_v4l2_unplugged)
        self._hotplug.camera_discovered.connect(self._on_network_camera_discovered)
        self._hotplug.start()

        # Patrol carousel timer for TV / HTPC monitoring
        self._patrol_active = False
        self._patrol_timer = QTimer(self)
        self._patrol_timer.timeout.connect(self._on_patrol_tick)

        self._build_toolbar()
        self._build_central()
        self.setStatusBar(QStatusBar(self))
        self._set_status_ready()

        # Periodically reap dead mpv processes and manage storage quotas
        self._reap_counter = 0
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

        act_guide = QAction("💡 Camera Setup Guide", self)
        act_guide.setToolTip("Open brand-specific setup instructions for cameras")
        act_guide.triggered.connect(self._action_brand_guide)
        tb.addAction(act_guide)

        act_open = QAction("📺  Open PiP", self)
        act_open.setShortcut("P")
        act_open.triggered.connect(self._action_open_pip)
        tb.addAction(act_open)

        act_fullscreen = QAction("⛶  Fullscreen", self)
        act_fullscreen.setShortcut("F")
        act_fullscreen.triggered.connect(self._action_fullscreen)
        tb.addAction(act_fullscreen)

        act_ptz = QAction("🎮  PTZ", self)
        act_ptz.setShortcut("T")
        act_ptz.setToolTip("Pan-Tilt-Zoom directional controls")
        act_ptz.triggered.connect(self._action_ptz)
        tb.addAction(act_ptz)

        act_patrol = QAction("🔄  Patrol", self)
        act_patrol.setShortcut("Shift+P")
        act_patrol.setToolTip("Toggle automatic surveillance carousel (cycles cameras for TV view)")
        act_patrol.triggered.connect(self._action_toggle_patrol)
        tb.addAction(act_patrol)

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

        act_shortcuts = QAction("⌨  Shortcuts", self)
        act_shortcuts.triggered.connect(self._action_show_shortcuts)
        tb.addAction(act_shortcuts)

        act_settings = QAction("⚙  Settings", self)
        act_settings.triggered.connect(self._action_open_settings)
        tb.addAction(act_settings)

        act_export = QAction("📤 Export config", self)
        act_export.triggered.connect(self._action_export_config)
        tb.addAction(act_export)

        act_import = QAction("📥 Import config", self)
        act_import.triggered.connect(self._action_import_config)
        tb.addAction(act_import)

        act_toggle = QAction("👁 Toggle enable", self)
        act_toggle.setShortcut("E")
        act_toggle.triggered.connect(self._action_toggle_enable)
        tb.addAction(act_toggle)

        tb.addSeparator()

        act_reload = QAction("⟳  Reload", self)
        act_reload.setShortcut(QKeySequence.Refresh)
        act_reload.triggered.connect(self.reload)
        tb.addAction(act_reload)

    def _build_central(self) -> None:
        central = QWidget(self)
        main_vbox = QVBoxLayout(central)
        main_vbox.setContentsMargins(8, 8, 8, 8)
        main_vbox.setSpacing(6)

        # Hotplug banner for newly detected cameras
        self._banner = QFrame(central)
        self._banner.setStyleSheet(
            "background: #1b3a57; border: 1px solid #2a6ebb; border-radius: 6px; padding: 4px 10px;"
        )
        banner_layout = QHBoxLayout(self._banner)
        banner_layout.setContentsMargins(4, 4, 4, 4)
        self._banner_icon = QLabel("✨", self._banner)
        self._banner_text = QLabel("", self._banner)
        self._banner_text.setStyleSheet("color: white; font-weight: bold;")
        self._banner_add_btn = QPushButton("➕ Add Camera", self._banner)
        self._banner_add_btn.setStyleSheet(
            "background: #2a6ebb; color: white; padding: 4px 12px; font-weight: bold; border-radius: 4px;"
        )
        self._banner_add_btn.clicked.connect(self._on_banner_add_clicked)
        self._banner_dismiss_btn = QPushButton("✕", self._banner)
        self._banner_dismiss_btn.setFixedWidth(28)
        self._banner_dismiss_btn.clicked.connect(lambda: self._banner.setVisible(False))
        banner_layout.addWidget(self._banner_icon)
        banner_layout.addWidget(self._banner_text, 1)
        banner_layout.addWidget(self._banner_add_btn)
        banner_layout.addWidget(self._banner_dismiss_btn)
        self._banner.setVisible(False)
        main_vbox.addWidget(self._banner)

        content_row = QWidget(central)
        outer = QHBoxLayout(content_row)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(8)
        main_vbox.addWidget(content_row, 1)

        # Left: list of cameras with group filter and search.
        left = QWidget(content_row)
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

        # Sortable column headers.
        sort_row = QHBoxLayout()
        sort_row.setContentsMargins(0, 0, 0, 0)
        for label, slot in (
            ("Name", lambda: self._sort_by("name")),
            ("Group", lambda: self._sort_by("group")),
            ("Status", lambda: self._sort_by("status")),
        ):
            btn = QPushButton(label)
            btn.setStyleSheet("padding: 2px 8px; font-size: 11px; background: transparent; border: none; text-decoration: underline;")
            btn.clicked.connect(slot)
            sort_row.addWidget(btn)
        sort_row.addStretch(1)
        left_layout.addLayout(sort_row)

        self._search = QLineEdit()
        self._search.setPlaceholderText("🔍  Search cameras…")
        self._search.textChanged.connect(self._on_search_changed)
        left_layout.addWidget(self._search)

        self._list = QListWidget(left)
        self._list.setContextMenuPolicy(Qt.CustomContextMenu)
        self._list.customContextMenuRequested.connect(self._on_list_context_menu)
        self._list.itemSelectionChanged.connect(self._on_select)
        self._list.itemDoubleClicked.connect(lambda _i: self._action_edit())
        self._list.setSortingEnabled(False)
        left_layout.addWidget(self._list, 1)

        # Details panel below the list.
        self._details = QGroupBox("Camera details")
        self._details.setVisible(False)
        details_layout = QFormLayout()
        self._detail_name = QLabel("")
        self._detail_url = QLabel("")
        self._detail_url.setWordWrap(True)
        self._detail_url.setStyleSheet("color: #4fc3f7;")
        self._detail_vendor = QLabel("")
        self._detail_group = QLabel("")
        self._detail_profile = QLabel("")
        self._detail_notes = QLabel("")
        self._detail_notes.setWordWrap(True)
        details_layout.addRow("Name:", self._detail_name)
        details_layout.addRow("URL:", self._detail_url)
        details_layout.addRow("Vendor:", self._detail_vendor)
        details_layout.addRow("Group:", self._detail_group)
        details_layout.addRow("Profile:", self._detail_profile)
        details_layout.addRow("Notes:", self._detail_notes)
        self._details.setLayout(details_layout)
        left_layout.addWidget(self._details, 0)

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
        right = QWidget(content_row)
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
        self._empty_state.scan_requested.connect(self._action_scan)
        self._empty_state.add_requested.connect(self._action_add)
        self._empty_state.readd_requested.connect(self._action_readd_last_scan)
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
            item.setData(Qt.UserRole, cam)
            online = self._camera_status.get(cam.name)
            if online is not None:
                icon_text = "🟢" if online else "🔴"
                item.setText(f"{icon_text}  {cam.display()}")
            if not cam.enabled:
                item.setForeground(Qt.gray)
                item.setText("🚫  " + cam.display())
            self._list.addItem(item)
        self._rebuild_previews([c for c in cams if c.enabled])
        self._rebuild_group_filter(cams)

        has_cams = len(cams) > 0
        self._empty_state.setVisible(not has_cams)
        if hasattr(self, '_empty_state') and hasattr(self._empty_state, '_readd_btn'):
            self._empty_state._readd_btn.setVisible(not has_cams and len(self._last_scan_results) > 0)
        self._grid_wrap.setVisible(has_cams)

        self._set_status_ready(f"Loaded {len(cams)} camera(s) from {cfg.config_path()}")

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
        self._apply_list_filter(filtered)

    def _on_search_changed(self, text: str) -> None:
        cams = cfg.load_cameras()
        group = self._group_filter.currentText()
        if group != "All groups":
            cams = [c for c in cams if c.group == group]
        if text.strip():
            lower = text.strip().lower()
            cams = [c for c in cams if lower in c.name.lower() or lower in c.url.lower()]
        self._apply_list_filter(cams)

    def _sort_by(self, key: str) -> None:
        cams = cfg.load_cameras()
        rev = getattr(self, f"_sort_rev_{key}", False)
        setattr(self, f"_sort_rev_{key}", not rev)
        rev = not rev
        if key == "name":
            cams.sort(key=lambda c: c.name.lower(), reverse=rev)
        elif key == "group":
            cams.sort(key=lambda c: c.group.lower(), reverse=rev)
        elif key == "status":
            def status_key(c):
                st = self._camera_status.get(c.name)
                if st is True:
                    return 0 if not rev else 2
                if st is False:
                    return 1 if not rev else 1
                return 2 if not rev else 0
            cams.sort(key=status_key)
        self._apply_list_filter(cams)

    def _apply_list_filter(self, cams: List[Camera]) -> None:
        self._list.clear()
        for cam in cams:
            item = QListWidgetItem(cam.display())
            item.setData(Qt.UserRole, cam)
            online = self._camera_status.get(cam.name)
            if online is not None:
                icon_text = "🟢" if online else "🔴"
                item.setText(f"{icon_text}  {cam.display()}")
            if not cam.enabled:
                item.setForeground(Qt.gray)
                item.setText("🚫  " + cam.display())
            self._list.addItem(item)
        self._rebuild_previews([c for c in cams if c.enabled])

    def _on_list_context_menu(self, pos) -> None:
        item = self._list.itemAt(pos)
        if item is None:
            return
        self._list.setCurrentItem(item)
        menu = QMenu(self)
        menu.addAction("✏️ Edit", self._action_edit)
        menu.addAction("📺 Open in PiP", self._action_open_pip)
        menu.addAction("⛶ Fullscreen", self._action_fullscreen)
        menu.addAction("⏺ Record", self._action_toggle_record)
        menu.addAction("📷 Snapshot", self._action_snapshot)
        menu.addSeparator()
        menu.addAction("👁 Toggle enable/disable", self._action_toggle_enable)
        menu.addSeparator()
        menu.addAction("🗑 Remove", self._action_remove)
        menu.exec(self._list.viewport().mapToGlobal(pos))

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

        layout_cols = {"1x1": 1, "2x2": 2, "3x3": 3, "4x4": 4, "1+3": 2}
        cols = layout_cols.get(self._current_layout, 2)
        max_cams = cols * cols if self._current_layout != "1+3" else 4

        for idx, cam in enumerate(cams[:max_cams]):
            prev = PreviewWidget(self._grid_wrap)
            prev.clicked.connect(lambda i=idx: self._select_index(i))
            prev.double_clicked.connect(lambda i=idx: self._on_preview_double_clicked(i))
            prev.context_menu_requested.connect(lambda pos, i=idx: self._on_preview_context_menu(pos, i))
            prev.frame_ready.connect(self._on_preview_frame_ready)
            if hasattr(prev, '_cached_vendor'):
                prev._cached_vendor = cam.notes
            # Restore online status if known.
            if cam.name in self._camera_status:
                prev.set_online_status(self._camera_status[cam.name])
            if self._recording.is_recording(cam):
                prev.set_recording(True)
            self._grid.addWidget(prev, idx // cols, idx % cols)
            self._previews.append(prev)
            prev.start(cam.url, cam.user, cam.password, caption=cam.name)

    def _on_preview_double_clicked(self, idx: int) -> None:
        self._select_index(idx)
        self._action_open_pip()

    def _on_preview_context_menu(self, pos, idx: int) -> None:
        self._select_index(idx)
        menu = QMenu(self)
        menu.addAction("📺 Open in PiP", self._action_open_pip)
        menu.addAction("⛶ Fullscreen", self._action_fullscreen)
        menu.addAction("🎮 PTZ Controls", self._action_ptz)
        menu.addAction("⏺ Record", self._action_toggle_record)
        menu.addAction("📷 Snapshot", self._action_snapshot)
        menu.addSeparator()
        menu.addAction("✏️ Edit", self._action_edit)
        menu.addAction("👁 Toggle enable/disable", self._action_toggle_enable)
        menu.addSeparator()
        menu.addAction("🗑 Remove", self._action_remove)
        menu.exec(pos)

    # --- selection ---------------------------------------------------------
    def _on_select(self) -> None:
        row = self._list.currentRow()
        self._select_index(row)

    def _select_index(self, idx: int) -> None:
        self._selected_index = idx
        cams = cfg.load_cameras()
        if 0 <= idx < len(cams):
            self._list.setCurrentRow(idx)
            cam = cams[idx]
            self._details.setVisible(True)
            self._detail_name.setText(cam.name)
            self._detail_url.setText(cam.url)
            vendor_text = cam.notes.split("vendor:")[-1].split(";")[0].strip() if "vendor:" in cam.notes else ""
            if not vendor_text:
                for prev in self._previews:
                    if prev._caption.text() == cam.name:
                        vendor_text = getattr(prev, "_cached_vendor", "")
                        break
            self._detail_vendor.setText(vendor_text or "—")
            self._detail_group.setText(cam.group or "—")
            self._detail_profile.setText(cam.profile or "—")
            self._detail_notes.setText(cam.notes or "—")
        else:
            self._details.setVisible(False)

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

        interval = float(self._settings.get("health_interval", 30.0))
        self._health_thread, self._health_worker = start_health_monitor(
            self, cams, interval=interval,
            on_status_change=self._on_health_status_changed,
        )

    def _on_health_status_changed(self, name: str, online: bool, url: str) -> None:
        prev = self._camera_status.get(name)
        self._camera_status[name] = online
        for prev_widget in self._previews:
            if prev_widget._caption.text() == name:
                prev_widget.set_online_status(online)
        for i in range(self._list.count()):
            item = self._list.item(i)
            text = item.text()
            if name in text:
                icon_text = "🟢" if online else "🔴"
                base = text.lstrip("🟢🔴 ")
                item.setText(f"{icon_text}  {base}")
        if not online:
            send_camera_offline(name)
        elif prev is False:
            send_camera_online(name)

    # --- actions -----------------------------------------------------------
    def _action_add(self) -> None:
        dlg = CameraEditDialog(self)
        if self._default_user:
            dlg._user.setText(self._default_user)
        if self._default_pass:
            dlg._pass.setText(self._default_pass)
        if dlg.exec() == QDialog.Accepted:
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
        if dlg.exec() == QDialog.Accepted:
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
        if dlg.exec() == QDialog.Accepted:
            self._last_scan_results = dlg._results
            self.reload()

    def _action_brand_guide(self) -> None:
        sel = self._selected_camera()
        brand_hint = ""
        host = ""
        if sel:
            _, cam = sel
            brand_hint = cam.name + " " + cam.notes
            from urllib.parse import urlparse
            if "://" in cam.url:
                host = urlparse(cam.url).hostname or ""
        show_brand_help(self, brand_hint=brand_hint, host=host)

    def _action_readd_last_scan(self) -> None:
        if not self._last_scan_results:
            QMessageBox.information(self, "No scan results", "No previous scan results available.")
            return
        from . import config as cfg
        cams = cfg.load_cameras()
        existing_urls = {c.url for c in cams}
        added = 0
        for res in self._last_scan_results:
            if not res.url or res.url in existing_urls:
                continue
            base = res.vendor.lower().replace(" ", "_") if res.vendor else res.method
            tag = res.host or (res.url.split("//", 1)[-1].split("/", 1)[0]
                                if "//" in res.url else res.url)
            name = f"{base}-{tag}" if base and tag else tag or res.url
            n = 2
            existing_names = {c.name for c in cams}
            while name in existing_names:
                name = f"{base}-{tag}-{n}"
                n += 1
            note_bits = [f"discovered via {res.method}"]
            if res.vendor: note_bits.append(f"vendor: {res.vendor}")
            if res.model: note_bits.append(f"model: {res.model}")
            if res.firmware: note_bits.append(f"firmware: {res.firmware}")
            cams.append(Camera(
                name=name, url=res.url,
                user=self._default_user, password=self._default_pass,
                notes="; ".join(note_bits),
            ))
            existing_urls.add(res.url)
            added += 1
        cfg.save_cameras(cams)
        QMessageBox.information(self, "Added", f"Added {added} camera(s) from last scan.")
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
        cfg.save_layout(self._current_layout)
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
        is_rec = rec is not None
        for prev in self._previews:
            if getattr(prev, "_caption_base_text", "") == cam.name or prev._caption.text().startswith(cam.name):
                prev.set_recording(is_rec)
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

    def _action_show_shortcuts(self) -> None:
        dlg = QDialog(self)
        dlg.setWindowTitle("Keyboard shortcuts")
        dlg.setMinimumWidth(400)
        layout = QFormLayout(dlg)
        shortcuts = [
            ("Ctrl+N / A", "Add camera"),
            ("Ctrl+E", "Edit selected camera"),
            ("Delete", "Remove selected camera"),
            ("Ctrl+Shift+S", "Scan network"),
            ("P", "Open selected in PiP"),
            ("F", "Fullscreen selected"),
            ("G", "Cycle grid layout"),
            ("R", "Toggle recording"),
            ("S", "Snapshot selected"),
            ("E", "Toggle enable/disable selected"),
            ("Esc", "Close all PiP windows"),
            ("F5 / Ctrl+R", "Reload"),
            ("T", "Pan-Tilt-Zoom (PTZ) directional controls"),
            ("Shift+P", "Toggle patrol carousel (surveillance TV mode)"),
            ("1 - 9", "Select camera 1 to 9 directly (TV remote)"),
            ("Enter", "Fullscreen selected camera"),
            ("M", "Toggle mute / audio on selected camera"),
            ("Arrows", "Navigate preview grid (D-pad)"),
        ]
        for key, desc in shortcuts:
            layout.addRow(QLabel(f"<b>{key}</b>"), QLabel(desc))
        btns = QDialogButtonBox(QDialogButtonBox.Close, parent=dlg)
        btns.rejected.connect(dlg.reject)
        layout.addRow(btns)
        dlg.exec()

    def _action_export_config(self) -> None:
        path, _ = QFileDialog.getSaveFileName(
            self, "Export cameras.conf", str(cfg.config_path()),
            "Config files (*.conf);;All files (*.*)",
        )
        if not path:
            return
        try:
            import shutil
            shutil.copy2(str(cfg.config_path()), path)
            QMessageBox.information(self, "Exported", f"Config exported to:\n{path}")
        except OSError as e:
            QMessageBox.warning(self, "Error", f"Could not export: {e}")

    def _action_open_settings(self) -> None:
        dlg = SettingsDialog(self, settings=self._settings)
        if dlg.exec() == QDialog.Accepted and dlg.changed():
            self._settings = load_settings()
            self._default_user = self._settings.get("default_user", "")
            self._default_pass = self._settings.get("default_password", "")
            layout = self._settings.get("default_layout", "2x2")
            if layout != self._current_layout:
                self._current_layout = layout
                self._layout_label.setText(layout.replace("x", "×"))
                self._rebuild_previews(self._visible_cameras())
            cams = cfg.load_cameras()
            self._start_health_monitor(cams)
            self._set_status_ready("Settings saved")

    def _action_import_config(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Import cameras.conf", str(Path.home()),
            "Config files (*.conf);;All files (*.*)",
        )
        if not path:
            return
        ok = QMessageBox.question(
            self, "Import",
            f"This will replace the current camera config with:\n{path}\n\nContinue?",
        )
        if ok != QMessageBox.Yes:
            return
        try:
            import shutil
            shutil.copy2(path, str(cfg.config_path()))
            self.reload()
            QMessageBox.information(self, "Imported", "Config imported successfully.")
        except OSError as e:
            QMessageBox.warning(self, "Error", f"Could not import: {e}")

    def _action_toggle_enable(self) -> None:
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        idx, cam = sel
        cams = cfg.load_cameras()
        if 0 <= idx < len(cams):
            cams[idx].enabled = not cams[idx].enabled
            cfg.save_cameras(cams)
            state = "enabled" if cams[idx].enabled else "disabled"
            self._set_status_ready(f"{cam.name} {state}")
            self.reload()

    # --- PTZ & Patrol ------------------------------------------------------
    def _action_ptz(self) -> None:
        sel = self._selected_camera()
        if not sel:
            QMessageBox.information(self, "No selection", "Select a camera first.")
            return
        _, cam = sel
        dlg = PtzDialog(self, camera=cam)
        dlg.exec()

    def _action_toggle_patrol(self) -> None:
        self._patrol_active = not self._patrol_active
        if self._patrol_active:
            interval = int(self._settings.get("patrol_interval_s", 10))
            self._patrol_timer.start(interval * 1000)
            self._set_status_ready(f"🔄 Patrol carousel ACTIVE ({interval}s interval)")
        else:
            self._patrol_timer.stop()
            self._set_status_ready("Patrol carousel stopped.")

    def _on_patrol_tick(self) -> None:
        cams = [c for c in cfg.load_cameras() if c.enabled]
        if not cams:
            return
        next_idx = (self._selected_index + 1) % len(cams)
        self._select_index(next_idx)
        self._set_status_ready(f"🔄 Patrol: {cams[next_idx].name} ({next_idx + 1}/{len(cams)})")

    def _action_toggle_mute(self) -> None:
        sel = self._selected_camera()
        if not sel:
            return
        idx, cam = sel
        cams = cfg.load_cameras()
        if 0 <= idx < len(cams):
            cams[idx].audio = not cams[idx].audio
            cfg.save_cameras(cams)
            state = "Audio ON" if cams[idx].audio else "Muted"
            self._set_status_ready(f"{cam.name}: {state}")
            self.reload()

    # --- Motion Detection --------------------------------------------------
    def _on_preview_frame_ready(self, cam_name: str, img) -> None:
        if self._settings.get("motion_detection_enabled", True):
            self._motion.process_frame(cam_name, img)

    def _on_motion_detected(self, cam_name: str, delta: float) -> None:
        for prev in self._previews:
            base_name = getattr(prev, "_caption_base_text", "")
            if base_name == cam_name:
                prev.set_motion(True)
        self._set_status_ready(f"🚨 Motion detected on {cam_name} (activity score {delta:.2f})")
        if self._settings.get("notifications", True):
            notify("Motion Detected", f"Activity detected on camera '{cam_name}'")

        if self._settings.get("popup_on_motion", True):
            cams = {c.name: c for c in cfg.load_cameras()}
            cam = cams.get(cam_name)
            if cam:
                self._popup_mgr.trigger_popup(cam)

    def _on_bosch_zone_triggered(self, zone_num: int, event_desc: str, linked_camera: str) -> None:
        self._set_status_ready(f"🚨 Bosch Alarm: Zone {zone_num} ({event_desc}) tripped!")
        if self._settings.get("notifications", True):
            notify("Bosch Alarm Triggered", f"Zone {zone_num}: {event_desc} (Camera: {linked_camera})")

        cams = {c.name: c for c in cfg.load_cameras()}
        cam = cams.get(linked_camera)
        if cam:
            self._popup_mgr.trigger_popup(cam, force=True)
            self._recording.start_recording(cam)

    # --- Hotplug & Background Discovery -----------------------------------
    def _on_v4l2_plugged(self, dev: dict) -> None:
        dev_path = dev.get("device", "/dev/video0")
        name = dev.get("name", "USB Webcam")
        cam = Camera(
            name=name,
            url=dev_path,
            notes="plug-and-play USB camera",
        )
        if self._settings.get("auto_add_discovered", False):
            cams = cfg.load_cameras()
            if not any(c.url == dev_path for c in cams):
                cams.append(cam)
                cfg.save_cameras(cams)
                self.reload()
                self._set_status_ready(f"✨ Auto-added USB camera: {name}")
                return
        self._pending_discovered_camera = cam
        self._banner_text.setText(f"USB Camera Connected: <b>{name}</b> ({dev_path})")
        self._banner.setVisible(True)

    def _on_v4l2_unplugged(self, dev_path: str) -> None:
        self._set_status_ready(f"USB Camera disconnected ({dev_path})")

    def _on_network_camera_discovered(self, cam: DiscoveredCamera) -> None:
        cams = cfg.load_cameras()
        if any(c.url == cam.url for c in cams):
            return
        tag = cam.vendor or cam.model or "Camera"
        camera_obj = Camera(
            name=f"{tag}-{cam.host}",
            url=cam.url,
            user=self._default_user,
            password=self._default_pass,
            notes=f"auto-discovered {cam.method}",
        )
        if self._settings.get("auto_add_discovered", False):
            cams.append(camera_obj)
            cfg.save_cameras(cams)
            self.reload()
            self._set_status_ready(f"✨ Auto-added network camera: {camera_obj.name}")
            return
        self._pending_discovered_camera = camera_obj
        self._banner_text.setText(f"New Camera Discovered: <b>{camera_obj.name}</b> ({cam.url})")
        self._banner.setVisible(True)

    def _on_banner_add_clicked(self) -> None:
        self._banner.setVisible(False)
        cam = getattr(self, "_pending_discovered_camera", None)
        if not cam:
            return
        cams = cfg.load_cameras()
        if not any(c.url == cam.url for c in cams):
            cams.append(cam)
            cfg.save_cameras(cams)
            self.reload()
            self._set_status_ready(f"Added camera: {cam.name}")

    # --- Keyboard / Remote Navigation --------------------------------------
    def keyPressEvent(self, event) -> None:
        key = event.key()
        # Number keys 1-9 directly select camera
        if Qt.Key_1 <= key <= Qt.Key_9:
            idx = key - Qt.Key_1
            cams = cfg.load_cameras()
            if idx < len(cams):
                self._select_index(idx)
                self._set_status_ready(f"Selected camera {idx + 1}: {cams[idx].name}")
            return
        elif key in (Qt.Key_Return, Qt.Key_Enter):
            self._action_fullscreen()
            return
        elif key == Qt.Key_M:
            self._action_toggle_mute()
            return
        elif key == Qt.Key_T:
            self._action_ptz()
            return
        elif key in (Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down):
            self._navigate_grid(key)
            return
        super().keyPressEvent(event)

    def _navigate_grid(self, key: int) -> None:
        cams = cfg.load_cameras()
        if not cams:
            return
        cur = self._selected_index if self._selected_index >= 0 else 0
        layout_cols = {"1x1": 1, "2x2": 2, "3x3": 3, "4x4": 4, "1+3": 2}
        cols = layout_cols.get(self._current_layout, 2)
        if key == Qt.Key_Left:
            next_idx = max(0, cur - 1)
        elif key == Qt.Key_Right:
            next_idx = min(len(cams) - 1, cur + 1)
        elif key == Qt.Key_Up:
            next_idx = max(0, cur - cols)
        elif key == Qt.Key_Down:
            next_idx = min(len(cams) - 1, cur + cols)
        else:
            return
        self._select_index(next_idx)

    # --- periodic reap -----------------------------------------------------
    def _on_reap(self) -> None:
        self._pip.reap()
        active = self._recording.active_recordings()
        active_names = {r.camera.name for r in active}
        for prev in self._previews:
            base_name = getattr(prev, "_caption_base_text", "")
            if base_name:
                prev.set_recording(base_name in active_names)

        # Periodic storage maintenance if enabled (every ~30s)
        self._reap_counter = getattr(self, "_reap_counter", 0) + 1
        if self._reap_counter % 60 == 0:
            if self._settings.get("auto_cleanup", True):
                try:
                    max_gb = float(self._settings.get("storage_quota_gb", 20.0))
                    ret_days = int(self._settings.get("retention_days", 14))
                    self._storage.enforce_retention(max_storage_gb=max_gb, max_retention_days=ret_days)
                except Exception:
                    pass

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
        if hasattr(self, "_patrol_timer"):
            self._patrol_timer.stop()
        if hasattr(self, "_hotplug"):
            self._hotplug.stop()
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
