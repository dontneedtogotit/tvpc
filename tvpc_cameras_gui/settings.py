"""Application settings dialog."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QVBoxLayout, QFormLayout, QSpinBox,
    QDoubleSpinBox, QCheckBox, QGroupBox, QHBoxLayout, QLabel, QPushButton,
    QTabWidget, QWidget, QLineEdit,
)

from . import config as cfg


SETTINGS_FILE = cfg.CONF_DIR / "settings.json"


def _defaults() -> dict[str, Any]:
    return {
        "health_interval": 30,
        "scan_timeout": 2.0,
        "scan_workers": 64,
        "preview_poll_ms": 1500,
        "reconnect_attempts": 3,
        "reconnect_delay_s": 2.0,
        "notifications": True,
        "default_user": "",
        "default_password": "",
        "default_layout": "2x2",
        "auto_scan_on_startup": False,
        "show_method_icons": True,
        "show_status_emoji": True,
    }


def load_settings() -> dict[str, Any]:
    try:
        if SETTINGS_FILE.exists():
            data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
            d = _defaults()
            d.update(data)
            return d
    except Exception:
        pass
    return _defaults()


def save_settings(settings: dict[str, Any]) -> None:
    cfg.CONF_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    tmp.replace(SETTINGS_FILE)


class SettingsDialog(QDialog):
    """Application settings with tabs."""

    def __init__(self, parent=None, settings: Optional[dict[str, Any]] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Settings")
        self.setMinimumWidth(480)
        self._settings = settings if settings is not None else load_settings()
        self._changed = False

        tabs = QTabWidget()
        self._build_scan_tab(tabs)
        self._build_preview_tab(tabs)
        self._build_health_tab(tabs)
        self._build_credentials_tab(tabs)
        self._build_ui_tab(tabs)

        btns = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel, parent=self)
        btns.accepted.connect(self._on_accept)
        btns.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(tabs)
        layout.addWidget(btns)

    def _build_scan_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._scan_timeout = QDoubleSpinBox()
        self._scan_timeout.setRange(0.5, 10.0)
        self._scan_timeout.setSingleStep(0.5)
        self._scan_timeout.setValue(float(self._settings.get("scan_timeout", 2.0)))
        form.addRow("Scan timeout (s):", self._scan_timeout)

        self._scan_workers = QSpinBox()
        self._scan_workers.setRange(8, 256)
        self._scan_workers.setValue(int(self._settings.get("scan_workers", 64)))
        form.addRow("Scan workers:", self._scan_workers)

        self._auto_scan = QCheckBox("Auto-scan on startup")
        self._auto_scan.setChecked(bool(self._settings.get("auto_scan_on_startup", False)))
        form.addRow("", self._auto_scan)

        note = QLabel(
            "These settings affect new scans only. "
            "Higher worker counts scan faster but use more bandwidth."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Scan")

    def _build_preview_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._preview_poll = QSpinBox()
        self._preview_poll.setRange(200, 5000)
        self._preview_poll.setSingleStep(100)
        self._preview_poll.setValue(int(self._settings.get("preview_poll_ms", 1500)))
        form.addRow("Preview refresh (ms):", self._preview_poll)

        self._reconnect_attempts = QSpinBox()
        self._reconnect_attempts.setRange(0, 10)
        self._reconnect_attempts.setValue(int(self._settings.get("reconnect_attempts", 3)))
        form.addRow("Reconnect attempts:", self._reconnect_attempts)

        self._reconnect_delay = QDoubleSpinBox()
        self._reconnect_delay.setRange(0.5, 10.0)
        self._reconnect_delay.setSingleStep(0.5)
        self._reconnect_delay.setValue(float(self._settings.get("reconnect_delay_s", 2.0)))
        form.addRow("Reconnect delay (s):", self._reconnect_delay)

        note = QLabel(
            "Lower refresh = more CPU. "
            "Reconnect attempts apply when a stream drops."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Preview")

    def _build_health_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._health_interval = QSpinBox()
        self._health_interval.setRange(5, 600)
        self._health_interval.setValue(int(self._settings.get("health_interval", 30)))
        form.addRow("Health check interval (s):", self._health_interval)

        self._notifications = QCheckBox("Show desktop notifications")
        self._notifications.setChecked(bool(self._settings.get("notifications", True)))
        form.addRow("", self._notifications)

        note = QLabel(
            "How often to ping cameras. "
            "Lower values detect outages faster but generate more traffic."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Health")

    def _build_credentials_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._def_user = QLineEdit(self._settings.get("default_user", ""))
        self._def_user.setPlaceholderText("Default username (optional)")
        form.addRow("Default username:", self._def_user)

        self._def_pass = QLineEdit(self._settings.get("default_password", ""))
        self._def_pass.setEchoMode(QLineEdit.Password)
        self._def_pass.setPlaceholderText("Default password (optional)")
        form.addRow("Default password:", self._def_pass)

        note = QLabel(
            "Pre-filled in scan and add dialogs. "
            "Leave blank if cameras have different credentials."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Credentials")

    def _build_ui_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._default_layout = QLineEdit(self._settings.get("default_layout", "2x2"))
        form.addRow("Default layout:", self._default_layout)

        self._show_method_icons = QCheckBox("Show method icons in scan results")
        self._show_method_icons.setChecked(bool(self._settings.get("show_method_icons", True)))
        form.addRow("", self._show_method_icons)

        self._show_status_emoji = QCheckBox("Show online/offline emoji in list")
        self._show_status_emoji.setChecked(bool(self._settings.get("show_status_emoji", True)))
        form.addRow("", self._show_status_emoji)

        note = QLabel(
            "Layout: 1x1, 2x2, 3x3, 4x4, or 1+3."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Interface")

    def _on_accept(self) -> None:
        self._settings["scan_timeout"] = self._scan_timeout.value()
        self._settings["scan_workers"] = self._scan_workers.value()
        self._settings["auto_scan_on_startup"] = self._auto_scan.isChecked()
        self._settings["preview_poll_ms"] = self._preview_poll.value()
        self._settings["reconnect_attempts"] = self._reconnect_attempts.value()
        self._settings["reconnect_delay_s"] = self._reconnect_delay.value()
        self._settings["health_interval"] = self._health_interval.value()
        self._settings["notifications"] = self._notifications.isChecked()
        self._settings["default_user"] = self._def_user.text().strip()
        self._settings["default_password"] = self._def_pass.text()
        self._settings["default_layout"] = self._default_layout.text().strip()
        self._settings["show_method_icons"] = self._show_method_icons.isChecked()
        self._settings["show_status_emoji"] = self._show_status_emoji.isChecked()
        save_settings(self._settings)
        self._changed = True
        self.accept()

    def changed(self) -> bool:
        return self._changed
