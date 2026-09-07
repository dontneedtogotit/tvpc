"""Network scan dialog: progress + results + add-to-config buttons."""
from __future__ import annotations

from typing import List, Optional

from PySide6.QtCore import Qt, QThread
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QHBoxLayout, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QPushButton, QTextEdit, QVBoxLayout, QMessageBox,
    QCheckBox,
)

from .config import Camera
from .scan import ScanWorker
from .discover import DiscoveredCamera
from .settings import load_settings

_SETTINGS = load_settings()


_METHOD_ICONS = {
    "rtsp": "📹",
    "http": "🌐",
    "onvif": "🔌",
    "mdns": "📡",
    "arp": "🔗",
    "cloud": "☁️",
}


def _result_text(cam: DiscoveredCamera) -> str:
    """One-line summary used in the QListWidget."""
    icon = _METHOD_ICONS.get(cam.method, "📷")
    bits: List[str] = []
    if cam.vendor or cam.model:
        bits.append(f"{cam.vendor} {cam.model}".strip())
    elif cam.method:
        bits.append(cam.method.upper())
    bits.append(cam.host or cam.url)
    if cam.note:
        bits.append(f"— {cam.note}")
    return f"{icon}  " + "  |  ".join(b for b in bits if b)


class ScanDialog(QDialog):
    """Runs a network scan, lists discovered cameras, lets the user add them."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Scan for cameras")
        self.setMinimumSize(720, 540)

        self._results: List[DiscoveredCamera] = []
        self._thread: Optional[QThread] = None
        self._worker: Optional[ScanWorker] = None

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

        # Advanced options.
        adv_row = QHBoxLayout()
        adv_row.addWidget(QLabel("mDNS timeout (s):"))
        self._mdns_timeout = QLineEdit("2.0")
        self._mdns_timeout.setFixedWidth(40)
        adv_row.addWidget(self._mdns_timeout)
        adv_row.addWidget(QLabel("Retries:"))
        self._mdns_retries = QLineEdit("1")
        self._mdns_retries.setFixedWidth(30)
        adv_row.addWidget(self._mdns_retries)
        adv_row.addWidget(QLabel("Exclude subnets:"))
        self._exclude_subnets = QLineEdit()
        self._exclude_subnets.setPlaceholderText("e.g. 10.0.0.0/8, 172.16.0.0/12")
        adv_row.addWidget(self._exclude_subnets)
        adv_row.addStretch(1)

        self._list = QListWidget()
        self._list.setSelectionMode(QListWidget.ExtendedSelection)
        self._log = QTextEdit()
        self._log.setReadOnly(True)
        self._log.setFixedHeight(160)

        self._start_btn = QPushButton("Start scan")
        self._start_btn.clicked.connect(self._start)
        self._stop_btn = QPushButton("Stop")
        self._stop_btn.setEnabled(False)
        self._stop_btn.clicked.connect(self._stop)
        self._add_btn = QPushButton("Add selected to config")
        self._add_btn.clicked.connect(self._add_selected)
        self._add_all_btn = QPushButton("Add all")
        self._add_all_btn.clicked.connect(self._add_all)
        self._add_all_btn.setEnabled(False)

        top_btns = QHBoxLayout()
        top_btns.addWidget(self._start_btn)
        top_btns.addWidget(self._stop_btn)
        top_btns.addStretch(1)
        top_btns.addWidget(self._add_btn)
        top_btns.addWidget(self._add_all_btn)

        self._status = QLabel("Idle.")
        self._progress = QProgressBar()
        self._progress.setVisible(False)
        self._progress.setRange(0, 0)

        buttons = QDialogButtonBox(QDialogButtonBox.Close, parent=self)
        buttons.rejected.connect(self.reject)
        buttons.button(QDialogButtonBox.Close).setText("Close")

        layout = QVBoxLayout(self)
        layout.addWidget(intro)
        layout.addLayout(cred_row)
        layout.addLayout(range_row)
        layout.addLayout(top_btns)
        layout.addWidget(QLabel("Discovered cameras (Ctrl/Shift-click to multi-select):"))
        layout.addWidget(self._list, 1)
        layout.addWidget(QLabel("Log:"))
        layout.addWidget(self._log)
        layout.addWidget(self._progress)
        layout.addWidget(self._status)
        layout.addWidget(buttons)

    # --- scan lifecycle ----------------------------------------------------
    def _start(self) -> None:
        if self._thread is not None:
            return
        self._list.clear()
        self._results.clear()
        self._log.clear()
        self._start_btn.setEnabled(False)
        self._stop_btn.setEnabled(True)
        self._add_all_btn.setEnabled(False)
        self._progress.setVisible(True)
        self._status.setText("Scanning…")

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
        item = QListWidgetItem(_result_text(cam))
        item.setData(Qt.UserRole, cam)
        item.setToolTip(cam.display())
        self._list.addItem(item)

    def _on_failed(self, msg: str) -> None:
        QMessageBox.warning(self, "Scan failed", msg)
        self._status.setText(msg)

    def _on_finished(self) -> None:
        self._start_btn.setEnabled(True)
        self._stop_btn.setEnabled(False)
        self._add_all_btn.setEnabled(len(self._results) > 0)
        self._progress.setVisible(False)
        self._status.setText(f"Done. Found {len(self._results)} camera(s).")

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
            base = res.vendor.lower().replace(" ", "_") if res.vendor else res.method
            tag = res.host or (res.url.split("//", 1)[-1].split("/", 1)[0]
                                if "//" in res.url else res.url)
            name = f"{base}-{tag}" if base and tag else tag or res.url
            n = 2
            while name in existing:
                name = f"{base}-{tag}-{n}"
                n += 1
            note_bits = [f"discovered via {res.method}"]
            if res.vendor: note_bits.append(f"vendor: {res.vendor}")
            if res.model: note_bits.append(f"model: {res.model}")
            if res.firmware: note_bits.append(f"firmware: {res.firmware}")
            cams.append(Camera(
                name=name,
                url=res.url,
                user=self._user.text().strip(),
                password=self._pass.text(),
                notes="; ".join(note_bits),
            ))
            existing.add(name)
            existing_urls.add(res.url)
            added += 1
        cfg.save_cameras(cams)
        if added and skipped_no_url:
            QMessageBox.information(
                self, "Added",
                f"Added {added} camera(s) to the config.\n"
                f"Skipped {skipped_no_url} cloud-only entry(ies) — enable "
                f"ONVIF/RTSP in the vendor app and re-scan to get a URL.",
            )
        elif added:
            QMessageBox.information(self, "Added", f"Added {added} camera(s) to the config.")
        else:
            QMessageBox.information(
                self, "Nothing to add",
                "Selected entries are cloud-only (no URL). Enable "
                "ONVIF/RTSP in the vendor app and re-scan to get a URL.",
            )
        self.accept()

    def reject(self) -> None:  # noqa: D401
        if self._worker is not None:
            self._worker.cancel()
        super().reject()
