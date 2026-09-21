"""Network scan dialog: progress + results + add-to-config buttons."""
from __future__ import annotations

from typing import List, Optional, Tuple

from PySide6.QtCore import Qt, QThread, Signal, QObject
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QHBoxLayout, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QPushButton, QTextEdit, QVBoxLayout, QMessageBox,
    QCheckBox, QProgressBar, QGroupBox, QMenu,
)

from .config import Camera
from .scan import ScanWorker
from .discover import DiscoveredCamera
from .settings import load_settings
from .brand_help import show_brand_help, get_brand_template_url

_SETTINGS = load_settings()


_METHOD_ICONS = {
    "rtsp": "📹",
    "http": "🌐",
    "onvif": "🔌",
    "mdns": "📡",
    "arp": "🔗",
    "cloud": "☁️",
    "dvr": "📼",
    "ssdp": "📡",
    "usb": "🔌",
}


class _SingleProbeWorker(QObject):
    progress = Signal(str)
    result = Signal(object, object)  # (QListWidgetItem, DiscoveredCamera or None)
    finished = Signal()

    def __init__(
        self,
        targets: List[Tuple[QListWidgetItem, DiscoveredCamera]],
        user: str = "",
        password: str = "",
    ) -> None:
        super().__init__()
        self.targets = targets
        self.user = user
        self.password = password

    def run(self) -> None:
        from .discover import probe_ip_stream_url, quick_probe_all_ports
        for item, cam in self.targets:
            host = cam.host
            if not host:
                self.result.emit(item, None)
                continue
            self.progress.emit(f"Probing {host} on RTSP (554/6554) and ONVIF ports…")
            res = probe_ip_stream_url(host, user=self.user, password=self.password)
            if res:
                url, vendor, model = res
                cam.url = url
                cam.method = "rtsp"
                if vendor and vendor != "Unknown":
                    cam.vendor = vendor
                if model:
                    cam.model = model
                cam.note = "Verified active stream"
                self.result.emit(item, cam)
            else:
                cams = quick_probe_all_ports(host, user=self.user, password=self.password)
                active = next((c for c in cams if c.url), None)
                if active:
                    cam.url = active.url
                    cam.method = active.method
                    if active.vendor:
                        cam.vendor = active.vendor
                    if active.model:
                        cam.model = active.model
                    cam.note = active.note or "Verified active stream"
                    self.result.emit(item, cam)
                else:
                    self.result.emit(item, None)
        self.finished.emit()


def _result_text(cam: DiscoveredCamera) -> str:
    """One-line summary used in the QListWidget."""
    icon = _METHOD_ICONS.get(cam.method, "📷")
    bits: List[str] = []
    if not cam.url:
        bits.append("⚠️ [Needs Local ONVIF/RTSP]")
    if cam.is_dvr and cam.channel:
        dvr_name = cam.dvr_type or (f"{cam.vendor} DVR" if cam.vendor else "DVR")
        ch_label = f"Camera {cam.channel}" + (f"/{cam.total_channels}" if cam.total_channels else "")
        bits.append(f"{dvr_name} [{ch_label}]")
    elif cam.vendor or cam.model:
        bits.append(f"{cam.vendor} {cam.model}".strip())
    elif cam.method:
        bits.append(cam.method.upper())
    bits.append(cam.host or cam.url)
    if cam.mac:
        bits.append(f"[{cam.mac}]")
    if cam.note:
        bits.append(f"— {cam.note}")
    return f"{icon}  " + "  |  ".join(b for b in bits if b)


class ScanDialog(QDialog):
    """Runs a network scan, lists discovered cameras, lets the user add them."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Scan for cameras")
        self.setMinimumSize(860, 640)
        self.setStyleSheet(
            """
            QDialog, QWidget {
                background: #0b0f14;
                color: #e6e9ee;
                font-family: "Segoe UI", "Noto Sans", sans-serif;
            }
            QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox, QTextEdit {
                background: #11151b;
                color: #e6e9ee;
                border: 1px solid #1f2a36;
                border-radius: 8px;
                padding: 8px;
                font-size: 14px;
                min-height: 36px;
            }
            QLineEdit:focus, QComboBox:focus, QSpinBox:focus, QDoubleSpinBox:focus, QTextEdit:focus {
                border: 1px solid #4fc3f7;
            }
            QPushButton {
                background: #152233;
                color: #e6e9ee;
                border: 1px solid #22405e;
                border-radius: 8px;
                padding: 10px 16px;
                font-size: 14px;
                min-height: 40px;
                font-weight: 500;
            }
            QPushButton:hover {
                background: #1b2e45;
                border-color: #4fc3f7;
            }
            QPushButton:pressed {
                background: #0f1c2e;
            }
            QPushButton:focus {
                outline: 1px solid #4fc3f7;
            }
            QPushButton[text*="Start scan"], QPushButton[text*="➕"], QPushButton[text*="Add selected"] {
                background: #1261a0;
                color: #ffffff;
                border-color: #1976d2;
                font-weight: 600;
            }
            QPushButton[text*="Start scan"]:hover, QPushButton[text*="➕"]:hover, QPushButton[text*="Add selected"]:hover {
                background: #1580d4;
            }
            QProgressBar {
                background: #11151b;
                border: 1px solid #1f2a36;
                border-radius: 8px;
                text-align: center;
                min-height: 18px;
                color: #e6e9ee;
            }
            QProgressBar::chunk {
                background: #1261a0;
                border-radius: 8px;
            }
            QListWidget {
                background: #0f1318;
                border: 1px solid #1b2530;
                border-radius: 10px;
                padding: 10px;
                font-size: 14px;
                outline: none;
            }
            QListWidget::item {
                padding: 12px;
                border-radius: 8px;
                margin: 3px 0px;
            }
            QListWidget::item:selected {
                background: #12324d;
                color: #ffffff;
                border: 1px solid #4fc3f7;
            }
            QListWidget::item:focus {
                outline: 1px solid #4fc3f7;
            }
            QGroupBox {
                border: 1px solid #1b2530;
                border-radius: 10px;
                margin-top: 14px;
                padding-top: 20px;
                background: #0f1318;
            }
            QGroupBox::title {
                subcontrol-origin: margin;
                left: 14px;
                padding: 0 6px;
                color: #9aa6b2;
                font-size: 13px;
                font-weight: 600;
            }
            QTextEdit {
                background: #0a0d12;
                color: #cfe3f7;
                border: 1px solid #1b2530;
                border-radius: 8px;
                font-family: "SF Mono", "Consolas", monospace;
                font-size: 13px;
            }
            QCheckBox {
                spacing: 10px;
                font-size: 14px;
                padding: 4px 2px;
            }
            QCheckBox::indicator {
                width: 18px;
                height: 18px;
                border-radius: 4px;
                border: 1px solid #22405e;
                background: #0b0f14;
            }
            QCheckBox::indicator:checked {
                background: #1261a0;
                border-color: #1976d2;
            }
            QLabel {
                font-size: 14px;
            }
            QDialogButtonBox {
                background: transparent;
            }
            """
        )

        self._results: List[DiscoveredCamera] = []
        self._thread: Optional[QThread] = None
        self._worker: Optional[ScanWorker] = None
        self._probe_thread: Optional[QThread] = None
        self._probe_worker: Optional[_SingleProbeWorker] = None

        intro = QLabel(
            "This will scan your local network for IP security cameras. "
            "Make sure your cameras are powered on and connected to the "
            "same network as this computer.\n\n"
            "The scan checks for RTSP, ONVIF, HTTP, and mDNS-discoverable "
            "cameras across all your network interfaces."
        )
        intro.setWordWrap(True)

        # Credentials row.
        cred_row = QHBoxLayout()
        cred_row.addWidget(QLabel("Username:"))
        self._user = QLineEdit()
        self._user.setPlaceholderText("(optional — used for RTSP, HTTP, and ONVIF)")
        self._user.setText(_SETTINGS.get("default_user", ""))
        cred_row.addWidget(self._user)
        cred_row.addWidget(QLabel("Password:"))
        self._pass = QLineEdit()
        self._pass.setEchoMode(QLineEdit.Password)
        self._pass.setPlaceholderText("(optional)")
        self._pass.setText(_SETTINGS.get("default_password", ""))
        cred_row.addWidget(self._pass)

        # Range row.
        range_row = QHBoxLayout()
        range_row.addWidget(QLabel("Range:"))
        self._cidr = QLineEdit()
        self._cidr.setPlaceholderText("auto (every /24 on every active interface)")
        range_row.addWidget(self._cidr)
        self._enrich = QCheckBox("ONVIF GetDeviceInformation / GetProfiles")
        self._enrich.setChecked(True)
        range_row.addWidget(self._enrich)
        self._quick = QCheckBox("Quick scan (ARP + mDNS + ONVIF only)")
        self._quick.setChecked(False)
        self._quick.setToolTip(
            "Skips the TCP port sweep. Faster but may miss cameras "
            "that don't respond to mDNS or ONVIF."
        )
        range_row.addWidget(self._quick)

        # Advanced options group.
        self._adv_group = QGroupBox("Advanced network options")
        self._adv_group.setCheckable(True)
        self._adv_group.setChecked(False)
        adv_row = QHBoxLayout(self._adv_group)
        adv_row.addWidget(QLabel("mDNS timeout (s):"))
        self._mdns_timeout = QLineEdit("2.0")
        self._mdns_timeout.setFixedWidth(55)
        adv_row.addWidget(self._mdns_timeout)
        adv_row.addWidget(QLabel("Retries:"))
        self._mdns_retries = QLineEdit("1")
        self._mdns_retries.setFixedWidth(45)
        adv_row.addWidget(self._mdns_retries)
        adv_row.addWidget(QLabel("Exclude subnets:"))
        self._exclude_subnets = QLineEdit()
        self._exclude_subnets.setPlaceholderText("e.g. 10.0.0.0/8, 172.16.0.0/12")
        adv_row.addWidget(self._exclude_subnets)

        self._list = QListWidget()
        self._list.setSelectionMode(QListWidget.ExtendedSelection)
        self._list.setContextMenuPolicy(Qt.CustomContextMenu)
        self._list.customContextMenuRequested.connect(self._on_list_context_menu)
        self._list.itemSelectionChanged.connect(self._update_selection_states)
        self._list.itemDoubleClicked.connect(self._on_item_double_clicked)

        # Results filter and select buttons.
        filter_row = QHBoxLayout()
        self._filter_edit = QLineEdit()
        self._filter_edit.setPlaceholderText("🔍 Filter discovered cameras…")
        self._filter_edit.textChanged.connect(self._on_filter_changed)
        self._select_all_btn = QPushButton("Select all")
        self._select_all_btn.clicked.connect(self._select_all)
        self._deselect_all_btn = QPushButton("Deselect all")
        self._deselect_all_btn.clicked.connect(self._deselect_all)
        filter_row.addWidget(self._filter_edit, 1)
        filter_row.addWidget(self._select_all_btn)
        filter_row.addWidget(self._deselect_all_btn)

        self._log = QTextEdit()
        self._log.setReadOnly(True)
        self._log.setMinimumHeight(110)

        self._start_btn = QPushButton("🔍 Start scan")
        self._start_btn.clicked.connect(self._start)
        self._stop_btn = QPushButton("⏹ Stop")
        self._stop_btn.setEnabled(False)
        self._stop_btn.clicked.connect(self._stop)
        self._reprobe_btn = QPushButton("🔄 Re-probe selected")
        self._reprobe_btn.setToolTip("Quickly test selected camera(s) for active RTSP/ONVIF streams without re-scanning")
        self._reprobe_btn.setEnabled(False)
        self._reprobe_btn.clicked.connect(self._reprobe_selected)
        self._guide_btn = QPushButton("💡 Setup Guide")
        self._guide_btn.setToolTip("View brand-specific connection steps and RTSP activation guide")
        self._guide_btn.clicked.connect(self._open_brand_help)
        self._add_btn = QPushButton("➕ Add selected to config")
        self._add_btn.clicked.connect(self._add_selected)
        self._add_btn.setEnabled(False)
        self._add_all_btn = QPushButton("Add all")
        self._add_all_btn.clicked.connect(self._add_all)
        self._add_all_btn.setEnabled(False)

        top_btns = QHBoxLayout()
        top_btns.addWidget(self._start_btn)
        top_btns.addWidget(self._stop_btn)
        top_btns.addWidget(self._reprobe_btn)
        top_btns.addWidget(self._guide_btn)
        top_btns.addStretch(1)
        top_btns.addWidget(self._add_btn)
        top_btns.addWidget(self._add_all_btn)

        self._status = QLabel("Idle. Click 'Start scan' to search.")
        self._progress = QProgressBar()
        self._progress.setVisible(False)
        self._progress.setRange(0, 0)

        buttons = QDialogButtonBox(QDialogButtonBox.Close, parent=self)
        buttons.rejected.connect(self.reject)
        buttons.button(QDialogButtonBox.Close).setText("Close")

        layout = QVBoxLayout(self)
        layout.setSpacing(10)
        layout.setContentsMargins(14, 14, 14, 14)
        layout.addWidget(intro)
        layout.addLayout(cred_row)
        layout.addLayout(range_row)
        layout.addWidget(self._adv_group)
        layout.addLayout(top_btns)
        layout.addWidget(QLabel("Discovered cameras (Ctrl/Shift-click to multi-select, double-click for guide):"))
        layout.addLayout(filter_row)
        layout.addWidget(self._list, 1)
        layout.addWidget(QLabel("Scan Log:"))
        layout.addWidget(self._log)
        layout.addWidget(self._progress)
        layout.addWidget(self._status)
        layout.addWidget(buttons)

    def _on_item_double_clicked(self, item: QListWidgetItem) -> None:
        self._open_brand_help()

    def _open_brand_help(self) -> None:
        sel = self._list.selectedItems()
        brand_hint = ""
        host = ""
        if sel:
            cam: Optional[DiscoveredCamera] = sel[0].data(Qt.UserRole)
            if cam:
                brand_hint = cam.vendor or cam.model or cam.dvr_type
                host = cam.host
        show_brand_help(self, brand_hint=brand_hint, host=host)

    def _update_selection_states(self) -> None:
        sel = self._list.selectedItems()
        self._add_btn.setEnabled(len(sel) > 0)
        self._add_btn.setText(f"Add selected ({len(sel)}) to config" if sel else "Add selected to config")
        self._reprobe_btn.setEnabled(len(sel) > 0 and self._probe_thread is None)

    def _on_list_context_menu(self, pos) -> None:
        item = self._list.itemAt(pos)
        if item is None:
            return
        cam: Optional[DiscoveredCamera] = item.data(Qt.UserRole)
        if not cam:
            return
        self._list.setCurrentItem(item)
        menu = QMenu(self)
        menu.addAction("🔄 Re-probe / Test Camera", lambda: self._reprobe_items([item]))
        menu.addAction("💡 View Setup Guide", self._open_brand_help)
        menu.addSeparator()
        menu.addAction("✏️ Configure & Add Manually", lambda: self._manual_configure_item(item))
        menu.exec(self._list.viewport().mapToGlobal(pos))

    def _reprobe_selected(self) -> None:
        items = self._list.selectedItems()
        if not items:
            return
        self._reprobe_items(items)

    def _reprobe_items(self, items: List[QListWidgetItem]) -> None:
        if self._probe_thread is not None:
            QMessageBox.information(self, "Probing in progress", "A camera probe is already running. Please wait.")
            return
        targets = []
        for it in items:
            cam: Optional[DiscoveredCamera] = it.data(Qt.UserRole)
            if cam and cam.host:
                targets.append((it, cam))
        if not targets:
            return

        self._reprobe_btn.setEnabled(False)
        self._progress.setVisible(True)
        self._status.setText(f"Probing {len(targets)} camera(s) for local RTSP/ONVIF streams…")
        self._log.append(f"--- Starting targeted probe of {len(targets)} camera(s) ---")

        self._probe_thread = QThread(self)
        self._probe_worker = _SingleProbeWorker(
            targets,
            user=self._user.text().strip(),
            password=self._pass.text(),
        )
        self._probe_worker.moveToThread(self._probe_thread)
        self._probe_thread.started.connect(self._probe_worker.run)
        self._probe_worker.progress.connect(self._log.append)
        self._probe_worker.result.connect(self._on_reprobe_result)
        self._probe_worker.finished.connect(self._on_reprobe_finished)
        self._probe_worker.finished.connect(self._probe_thread.quit)
        self._probe_thread.finished.connect(self._cleanup_probe_thread)
        self._probe_thread.start()

    def _cleanup_probe_thread(self) -> None:
        self._probe_thread = None
        self._probe_worker = None
        self._progress.setVisible(False)
        self._update_selection_states()

    def _on_reprobe_result(self, item: QListWidgetItem, cam: Optional[DiscoveredCamera]) -> None:
        if cam and cam.url:
            item.setText(_result_text(cam))
            item.setData(Qt.UserRole, cam)
            item.setToolTip(cam.display())
            item.setForeground(QColor("#81c784"))
            self._log.append(f"✅ {cam.host}: Local RTSP/ONVIF verified! Stream URL: {cam.url}")
            self._status.setText(f"✅ Active stream detected on {cam.host}")
        elif cam:
            self._log.append(f"❌ {cam.host}: RTSP/ONVIF ports still closed or not responding.")
            self._status.setText(f"❌ {cam.host}: RTSP/ONVIF still disabled.")

    def _on_reprobe_finished(self) -> None:
        self._reprobe_btn.setEnabled(True)
        self._progress.setVisible(False)
        self._status.setText("Re-probe complete.")
        self._update_selection_states()

    def _manual_configure_item(self, item: QListWidgetItem) -> None:
        cam: Optional[DiscoveredCamera] = item.data(Qt.UserRole)
        if not cam:
            return
        from .edit_dialog import CameraEditDialog
        template_url, suggested_user = get_brand_template_url(
            cam.vendor or "", cam.host, self._user.text().strip(), self._pass.text()
        )
        base = (cam.vendor or "camera").strip().lower().replace(" ", "-")
        tag = cam.host.replace(".", "-") if cam.host else "cam"
        temp_cam = Camera(
            name=f"{base}-{tag}",
            url=cam.url or template_url,
            user=self._user.text().strip() or suggested_user,
            password=self._pass.text(),
            notes=cam.note or f"discovered via {cam.method}",
        )
        dlg = CameraEditDialog(self, camera=temp_cam)
        if dlg.exec() == QDialog.Accepted:
            saved_cam = dlg.get_camera()
            from . import config as cfg
            cams = cfg.load_cameras()
            if any(c.name == saved_cam.name for c in cams):
                QMessageBox.warning(self, "Duplicate", "A camera with that name already exists.")
                return
            cams.append(saved_cam)
            cfg.save_cameras(cams)
            QMessageBox.information(self, "Camera Added", f"Added '{saved_cam.name}' to configuration.")

    def _select_all(self) -> None:
        for i in range(self._list.count()):
            item = self._list.item(i)
            if not item.isHidden():
                item.setSelected(True)

    def _deselect_all(self) -> None:
        self._list.clearSelection()

    def _on_filter_changed(self, query: str) -> None:
        query = query.strip().lower()
        for i in range(self._list.count()):
            item = self._list.item(i)
            cam: Optional[DiscoveredCamera] = item.data(Qt.UserRole)
            if not query:
                item.setHidden(False)
            elif cam:
                match = (query in (cam.host or "").lower() or
                         query in (cam.url or "").lower() or
                         query in (cam.vendor or "").lower() or
                         query in (cam.model or "").lower() or
                         query in (cam.method or "").lower() or
                         query in (cam.note or "").lower() or
                         query in (cam.dvr_type or "").lower() or
                         (query == "dvr" and cam.is_dvr))
                item.setHidden(not match)
            else:
                item.setHidden(query not in item.text().lower())

    # --- scan lifecycle ----------------------------------------------------
    def _start(self) -> None:
        if self._thread is not None:
            return
        self._list.clear()
        self._results.clear()
        self._log.clear()
        self._update_selection_states()
        self._start_btn.setEnabled(False)
        self._stop_btn.setEnabled(True)
        self._add_all_btn.setEnabled(False)
        self._progress.setVisible(True)
        self._status.setText("Scanning…")
        self._status.setStyleSheet("color: #4fc3f7; font-weight: 600;")

        try:
            mdns_timeout = float(self._mdns_timeout.text().strip() or "2.0")
        except ValueError:
            mdns_timeout = 2.0
        try:
            mdns_retries = int(self._mdns_retries.text().strip() or "1")
        except ValueError:
            mdns_retries = 1
        exclude = [s.strip() for s in self._exclude_subnets.text().split(",") if s.strip()]

        self._thread = QThread(self)
        self._worker = ScanWorker(
            user=self._user.text(),
            password=self._pass.text(),
            cidr=self._cidr.text().strip() or None,
            do_onvif_enrich=self._enrich.isChecked(),
            quick=self._quick.isChecked(),
            mdns_timeout=mdns_timeout,
            mdns_retries=mdns_retries,
            exclude_subnets=exclude,
        )
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.progress.connect(self._on_progress)
        self._worker.found.connect(self._on_found)
        self._worker.failed.connect(self._on_failed)
        self._worker.finished.connect(self._on_finished)
        self._worker.finished.connect(self._thread.quit)
        self._thread.finished.connect(self._cleanup_thread)
        self._thread.start()

    def _stop(self) -> None:
        if self._worker is not None:
            self._worker.cancel()
            self._status.setText("Stopping…")

    def _cleanup_thread(self) -> None:
        self._thread = None
        self._worker = None

    # --- callbacks ---------------------------------------------------------
    def _on_progress(self, line: str) -> None:
        self._log.append(line)

    def _on_found(self, cam: DiscoveredCamera) -> None:
        self._results.append(cam)

        # If this is a cloud-only camera without a stream URL, optionally
        # backfill a brand-aware RTSP template so the user can add it directly.
        if (
            not cam.url
            and cam.method == "cloud"
            and bool(_SETTINGS.get("auto_add_cloud_templates", False))
        ):
            try:
                from .brand_help import get_brand_template_url
                template_url, _ = get_brand_template_url(
                    cam.vendor or "", cam.host or "", self._user.text().strip(), self._pass.text()
                )
                if template_url:
                    cam.url = template_url
                    cam.note = (
                        (cam.note or "")
                        + " | Template URL pre-filled; confirm in vendor app after enabling ONVIF/PC View."
                    )
            except Exception:
                pass

        item = QListWidgetItem(_result_text(cam))
        item.setData(Qt.UserRole, cam)
        if not cam.url:
            item.setForeground(QColor("#ffa726"))
            item.setToolTip(
                f"{cam.display()}\n\n"
                "⚠️ Local ONVIF/RTSP streaming is disabled on this camera.\n"
                "Enable ONVIF or PC View in the vendor app (e.g. Grid Connect, Tuya, Smart Life, Tapo), "
                "then click 'Re-probe selected' or double-click to view the Setup Guide."
            )
        else:
            item.setToolTip(cam.display())
        query = self._filter_edit.text().strip().lower()
        if query:
            match = (query in (cam.host or "").lower() or
                     query in (cam.url or "").lower() or
                     query in (cam.vendor or "").lower() or
                     query in (cam.model or "").lower() or
                     query in (cam.method or "").lower() or
                     query in (cam.note or "").lower())
            item.setHidden(not match)
        self._list.addItem(item)
        self._list.scrollToItem(item)
        self._add_all_btn.setEnabled(len(self._results) > 0)
        self._status.setText(f"Scanning… Discovered {len(self._results)} camera(s)")

    def _on_failed(self, msg: str) -> None:
        QMessageBox.warning(self, "Scan failed", msg)
        self._status.setText(msg)

    def _on_finished(self) -> None:
        self._start_btn.setEnabled(True)
        self._stop_btn.setEnabled(False)
        self._add_all_btn.setEnabled(len(self._results) > 0)
        self._progress.setVisible(False)
        if not self._results:
            self._status.setText(
                "No cameras found. Try Quick Scan, entering credentials, "
                "or checking ONVIF/RTSP is enabled in the vendor app."
            )
            self._status.setStyleSheet("color: #ffb74d; font-weight: 600;")
            self._guide_btn.setEnabled(True)
            self._guide_btn.setStyleSheet(
                "background: #1261a0; color: #ffffff; border: 1px solid #1976d2; font-weight: 600;"
            )
        else:
            self._status.setText(f"Done. Found {len(self._results)} camera(s).")
            self._status.setStyleSheet("color: #81c784; font-weight: 600;")
            self._guide_btn.setEnabled(False)
            self._guide_btn.setStyleSheet("")

    def _add_selected(self) -> None:
        items = self._list.selectedItems()
        if not items:
            QMessageBox.information(self, "No selection", "Select one or more cameras to add.")
            return
        self._add_items(items)

    def _add_all(self) -> None:
        items = [self._list.item(i) for i in range(self._list.count())]
        if not items:
            QMessageBox.information(self, "Nothing found", "No cameras to add.")
            return
        self._add_items(items)

    def _add_items(self, items) -> None:
        from . import config as cfg
        cams = cfg.load_cameras()
        existing = {c.name for c in cams}
        existing_urls = {c.url for c in cams}
        added = 0
        skipped_no_url = 0
        for item in items:
            res: DiscoveredCamera = item.data(Qt.UserRole)
            if not res.url:
                skipped_no_url += 1
                continue
            if res.url in existing_urls:
                continue
            if res.is_dvr and res.channel:
                base = (res.vendor.lower().replace(" ", "_") if res.vendor else "dvr") + "_dvr"
                tag = f"{res.host}-ch{res.channel}" if res.host else f"ch{res.channel}"
            elif res.method == "usb":
                base = res.vendor.lower().replace(" ", "_") if res.vendor else "usb"
                tag = res.url.replace("/dev/", "")
            else:
                base = res.vendor.lower().replace(" ", "_") if res.vendor else res.method
                tag = res.host or (res.url.split("//", 1)[-1].split("/", 1)[0]
                                    if "//" in res.url else res.url)
            name = f"{base}-{tag}" if base and tag else tag or res.url
            n = 2
            while name in existing:
                name = f"{base}-{tag}-{n}"
                n += 1
            note_bits = []
            if res.is_dvr and res.channel:
                note_bits.append(f"DVR Channel {res.channel}")
                if res.dvr_type:
                    note_bits.append(res.dvr_type)
            note_bits.append(f"discovered via {res.method}")
            if res.vendor: note_bits.append(f"vendor: {res.vendor}")
            if res.model: note_bits.append(f"model: {res.model}")
            if res.firmware: note_bits.append(f"firmware: {res.firmware}")
            cam_user = "" if res.method == "usb" else self._user.text().strip()
            cam_pass = "" if res.method == "usb" else self._pass.text()
            cams.append(Camera(
                name=name,
                url=res.url,
                user=cam_user,
                password=cam_pass,
                notes="; ".join(note_bits),
            ))
            existing.add(name)
            existing_urls.add(res.url)
            added += 1
        cfg.save_cameras(cams)
        if added and skipped_no_url:
            msg = QMessageBox(self)
            msg.setWindowTitle("Cameras Added")
            msg.setText(
                f"Added {added} camera(s) to the config.\n\n"
                f"{skipped_no_url} camera(s) do not have a local stream URL "
                f"(local ONVIF/RTSP is disabled in the camera firmware)."
            )
            msg.setInformativeText(
                "Would you like to view the Setup Guide or add RTSP templates for the skipped cameras?"
            )
            btn_guide = msg.addButton("💡 View Setup Guide", QMessageBox.ActionRole)
            btn_templates = msg.addButton("Add Templates", QMessageBox.AcceptRole)
            btn_done = msg.addButton("Done", QMessageBox.RejectRole)
            msg.setDefaultButton(btn_done)
            msg.exec()

            if msg.clickedButton() == btn_templates:
                for item in items:
                    res: DiscoveredCamera = item.data(Qt.UserRole)
                    if not res.url:
                        base = (res.vendor or "").strip().lower().replace(" ", "-") if res.vendor else "camera"
                        tag = res.host.replace(".", "-") if res.host else "cam"
                        name = f"{base}-{tag}" if base and tag else tag
                        n = 2
                        while name in existing:
                            name = f"{base}-{tag}-{n}"
                            n += 1
                        user_val = self._user.text().strip()
                        pass_val = self._pass.text()
                        template_url, suggested_user = get_brand_template_url(
                            res.vendor or "", res.host, user_val, pass_val
                        )
                        note_bits = [f"discovered via {res.method}"]
                        if res.vendor:
                            note_bits.append(f"vendor: {res.vendor}")
                        note_bits.append("requires ONVIF/RTSP enabled in vendor app")
                        cams.append(Camera(
                            name=name,
                            url=template_url,
                            user=user_val or suggested_user,
                            password=pass_val,
                            notes="; ".join(note_bits),
                        ))
                        existing.add(name)
                        added += 1
                cfg.save_cameras(cams)
                QMessageBox.information(self, "Added", f"Added remaining camera template(s) to the config.")
                self.accept()
            elif msg.clickedButton() == btn_guide:
                self._open_brand_help()
            else:
                self.accept()
            return
        elif added:
            QMessageBox.information(self, "Added", f"Added {added} camera(s) to the config.")
            self.accept()
        elif skipped_no_url:
            msg = QMessageBox(self)
            msg.setWindowTitle("Cloud-only Camera(s) Selected")
            msg.setText(
                f"Selected {skipped_no_url} camera(s) do not have a local stream URL "
                f"(local ONVIF/RTSP is disabled in the camera firmware).\n\n"
                f"To stream from these cameras, enable ONVIF or PC View in the vendor app "
                f"(e.g. Grid Connect, Tuya, Smart Life) and re-scan."
            )
            msg.setInformativeText(
                "If you have just enabled ONVIF in the vendor app, click 'Re-probe Camera(s)'.\n"
                "You can also view the Setup Guide or add RTSP templates."
            )
            btn_reprobe = msg.addButton("🔄 Re-probe Camera(s)", QMessageBox.ActionRole)
            btn_guide = msg.addButton("💡 View Setup Guide", QMessageBox.ActionRole)
            btn_templates = msg.addButton("Add Templates", QMessageBox.AcceptRole)
            msg.addButton(QMessageBox.Cancel)
            msg.setDefaultButton(btn_reprobe)
            msg.exec()

            if msg.clickedButton() == btn_reprobe:
                no_url_items = [it for it in items if not getattr(it.data(Qt.UserRole), "url", None)]
                self._reprobe_items(no_url_items)
                return
            elif msg.clickedButton() == btn_guide:
                self._open_brand_help()
                return
            elif msg.clickedButton() == btn_templates:
                for item in items:
                    res: DiscoveredCamera = item.data(Qt.UserRole)
                    if not res.url:
                        base = (res.vendor or "").strip().lower().replace(" ", "-") if res.vendor else "camera"
                        tag = res.host.replace(".", "-") if res.host else "cam"
                        name = f"{base}-{tag}" if base and tag else tag
                        n = 2
                        while name in existing:
                            name = f"{base}-{tag}-{n}"
                            n += 1
                        user_val = self._user.text().strip()
                        pass_val = self._pass.text()
                        template_url, suggested_user = get_brand_template_url(
                            res.vendor or "", res.host, user_val, pass_val
                        )
                        note_bits = [f"discovered via {res.method}"]
                        if res.vendor:
                            note_bits.append(f"vendor: {res.vendor}")
                        note_bits.append("requires ONVIF/RTSP enabled in vendor app")
                        cams.append(Camera(
                            name=name,
                            url=template_url,
                            user=user_val or suggested_user,
                            password=pass_val,
                            notes="; ".join(note_bits),
                        ))
                        existing.add(name)
                        added += 1
                cfg.save_cameras(cams)
                QMessageBox.information(self, "Added", f"Added {added} camera template(s) to the config.")
                self.accept()
            return
        else:
            QMessageBox.information(self, "Nothing to add", "No new cameras were added.")
            return

    def reject(self) -> None:  # noqa: D401
        if self._worker is not None:
            self._worker.cancel()
        super().reject()
