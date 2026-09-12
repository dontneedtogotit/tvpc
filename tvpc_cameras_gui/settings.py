"""Application settings dialog."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QVBoxLayout, QFormLayout, QSpinBox,
    QDoubleSpinBox, QCheckBox, QGroupBox, QHBoxLayout, QLabel, QPushButton,
    QTabWidget, QWidget, QLineEdit, QComboBox,
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
        "storage_quota_gb": 20.0,
        "retention_days": 14,
        "auto_cleanup": True,
        "background_discovery": True,
        "auto_add_discovered": False,
        "patrol_interval_s": 10,
        "motion_detection_enabled": True,
        "motion_sensitivity": 0.12,
        "motion_auto_snapshot": True,
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

        self._tabs = QTabWidget()
        self._build_scan_tab(self._tabs)
        self._build_preview_tab(self._tabs)
        self._build_storage_tab(self._tabs)
        self._build_motion_tab(self._tabs)
        self._build_hotplug_tab(self._tabs)
        self._build_bosch_tab(self._tabs)
        self._build_health_tab(self._tabs)
        self._build_credentials_tab(self._tabs)
        self._build_ui_tab(self._tabs)

        btns = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel, parent=self)
        btns.accepted.connect(self._on_accept)
        btns.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(self._tabs)
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

    def _build_storage_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        from .storage import StorageManager
        sm = StorageManager()
        info = sm.get_storage_info()

        status_lbl = QLabel(
            f"Recordings: {info['recording_count']} files ({info['recordings_display']})\n"
            f"Free disk space: {info['disk_free_display']} ({info['disk_free_percent']:.1f}% free)"
        )
        status_lbl.setStyleSheet("color: #4fc3f7; font-weight: 500;")
        form.addRow("Storage status:", status_lbl)

        self._storage_quota = QDoubleSpinBox()
        self._storage_quota.setRange(1.0, 1000.0)
        self._storage_quota.setSingleStep(5.0)
        self._storage_quota.setSuffix(" GB")
        self._storage_quota.setValue(float(self._settings.get("storage_quota_gb", 20.0)))
        form.addRow("Max recording storage:", self._storage_quota)

        self._retention_days = QSpinBox()
        self._retention_days.setRange(0, 365)
        self._retention_days.setSuffix(" days (0 = unlimited)")
        self._retention_days.setValue(int(self._settings.get("retention_days", 14)))
        form.addRow("Retention period:", self._retention_days)

        self._auto_cleanup = QCheckBox("Auto-cleanup oldest recordings when quota exceeded")
        self._auto_cleanup.setChecked(bool(self._settings.get("auto_cleanup", True)))
        form.addRow("", self._auto_cleanup)

        purge_btn = QPushButton("🧹 Prune Old Recordings Now")
        purge_btn.clicked.connect(self._prune_now)
        form.addRow("", purge_btn)

        tabs.addTab(w, "Storage")

    def _prune_now(self) -> None:
        from .storage import StorageManager
        sm = StorageManager()
        deleted, freed = sm.enforce_retention(
            max_storage_gb=self._storage_quota.value(),
            max_retention_days=self._retention_days.value(),
        )
        from .storage import format_bytes
        from PySide6.QtWidgets import QMessageBox
        QMessageBox.information(
            self, "Storage Pruned",
            f"Purged {len(deleted)} old recording file(s), freeing {format_bytes(freed)}."
        )

    def _build_motion_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._motion_enabled = QCheckBox("Enable live motion detection")
        self._motion_enabled.setChecked(bool(self._settings.get("motion_detection_enabled", True)))
        form.addRow("", self._motion_enabled)

        self._motion_sens = QDoubleSpinBox()
        self._motion_sens.setRange(0.02, 0.40)
        self._motion_sens.setSingleStep(0.02)
        self._motion_sens.setValue(float(self._settings.get("motion_sensitivity", 0.12)))
        form.addRow("Motion sensitivity threshold:", self._motion_sens)

        self._motion_snapshot = QCheckBox("Auto-save snapshot when motion detected")
        self._motion_snapshot.setChecked(bool(self._settings.get("motion_auto_snapshot", True)))
        form.addRow("", self._motion_snapshot)

        self._ai_filter_enabled = QCheckBox("Enable AI person & vehicle filtering")
        self._ai_filter_enabled.setChecked(bool(self._settings.get("ai_filter_enabled", False)))
        form.addRow("", self._ai_filter_enabled)

        self._ai_target_mode = QComboBox()
        self._ai_target_mode.addItems(["person_vehicle", "person", "vehicle", "all"])
        self._ai_target_mode.setCurrentText(str(self._settings.get("ai_target_mode", "person_vehicle")))
        form.addRow("AI detection target:", self._ai_target_mode)

        note = QLabel(
            "Lower threshold = higher sensitivity.\n"
            "AI filter suppresses false alerts from rain, tree shadows, and insects."
        )
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Motion")

    def _build_hotplug_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        self._bg_discovery = QCheckBox("Auto-discover cameras in background (Plug-and-Play)")
        self._bg_discovery.setChecked(bool(self._settings.get("background_discovery", True)))
        form.addRow("", self._bg_discovery)

        self._auto_add = QCheckBox("Auto-add newly discovered cameras without prompting")
        self._auto_add.setChecked(bool(self._settings.get("auto_add_discovered", False)))
        form.addRow("", self._auto_add)

        self._patrol_interval = QSpinBox()
        self._patrol_interval.setRange(3, 120)
        self._patrol_interval.setSuffix(" s")
        self._patrol_interval.setValue(int(self._settings.get("patrol_interval_s", 10)))
        form.addRow("Patrol carousel interval:", self._patrol_interval)

        self._popup_on_motion = QCheckBox("Auto-display TV PiP pop-up on motion or alarm")
        self._popup_on_motion.setChecked(bool(self._settings.get("popup_on_motion", True)))
        form.addRow("", self._popup_on_motion)

        self._popup_duration = QSpinBox()
        self._popup_duration.setRange(5, 60)
        self._popup_duration.setSuffix(" s")
        self._popup_duration.setValue(int(self._settings.get("popup_duration", 15)))
        form.addRow("TV pop-up display time:", self._popup_duration)

        self._popup_sound = QCheckBox("Play gentle audio chime on TV alert")
        self._popup_sound.setChecked(bool(self._settings.get("popup_sound", True)))
        form.addRow("", self._popup_sound)

        note = QLabel(
            "Detects newly plugged USB webcams and network cameras joining the LAN.\n"
            "TV pop-up displays a transient corner preview during doorbell or motion events."
        )
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Automation")

    def _build_bosch_tab(self, tabs: QTabWidget) -> None:
        w = QWidget()
        form = QFormLayout(w)

        from .bosch import load_bosch_config
        bcfg = load_bosch_config()

        self._bosch_enabled = QCheckBox("Enable Bosch Alarm System integration")
        self._bosch_enabled.setChecked(bcfg.enabled)
        form.addRow("", self._bosch_enabled)

        self._bosch_protocol = QComboBox()
        self._bosch_protocol.addItem("Direct Mode 2 TCP (Solution / B-Series)", "mode2")
        self._bosch_protocol.addItem("SIA DC-09 IP Receiver", "sia")
        idx = 1 if bcfg.protocol == "sia" else 0
        self._bosch_protocol.setCurrentIndex(idx)
        form.addRow("Integration Protocol:", self._bosch_protocol)

        self._bosch_host = QLineEdit(bcfg.host)
        self._bosch_host.setPlaceholderText("e.g. 192.168.1.50")
        form.addRow("Panel IP / Hostname:", self._bosch_host)

        self._bosch_port = QSpinBox()
        self._bosch_port.setRange(1, 65535)
        self._bosch_port.setValue(bcfg.port)
        form.addRow("Panel Port:", self._bosch_port)

        self._bosch_passcode = QLineEdit(bcfg.passcode)
        self._bosch_passcode.setEchoMode(QLineEdit.Password)
        form.addRow("Panel Passcode:", self._bosch_passcode)

        self._bosch_listen_port = QSpinBox()
        self._bosch_listen_port.setRange(1, 65535)
        self._bosch_listen_port.setValue(bcfg.listen_port)
        form.addRow("SIA Receiver Port:", self._bosch_listen_port)

        zone_str = ", ".join(f"{k}={v}" for k, v in bcfg.zone_mapping.items())
        self._bosch_zones = QLineEdit(zone_str)
        self._bosch_zones.setPlaceholderText("e.g. 1=Front Door, 2=Driveway, 3=Backyard")
        form.addRow("Zone -> Camera Mapping:", self._bosch_zones)

        note = QLabel(
            "Tripped alarm zones instantly trigger a TV pop-up and start an event recording\n"
            "for the linked camera feed."
        )
        note.setStyleSheet("color: #888;")
        form.addRow("", note)

        tabs.addTab(w, "Bosch Alarm")

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
        self._settings["storage_quota_gb"] = self._storage_quota.value()
        self._settings["retention_days"] = self._retention_days.value()
        self._settings["auto_cleanup"] = self._auto_cleanup.isChecked()
        self._settings["motion_detection_enabled"] = self._motion_enabled.isChecked()
        self._settings["motion_sensitivity"] = self._motion_sens.value()
        self._settings["motion_auto_snapshot"] = self._motion_snapshot.isChecked()
        self._settings["ai_filter_enabled"] = self._ai_filter_enabled.isChecked()
        self._settings["ai_target_mode"] = self._ai_target_mode.currentText()
        self._settings["background_discovery"] = self._bg_discovery.isChecked()
        self._settings["auto_add_discovered"] = self._auto_add.isChecked()
        self._settings["patrol_interval_s"] = self._patrol_interval.value()
        self._settings["popup_on_motion"] = self._popup_on_motion.isChecked()
        self._settings["popup_duration"] = self._popup_duration.value()
        self._settings["popup_sound"] = self._popup_sound.isChecked()
        save_settings(self._settings)

        # Save Bosch config
        from .bosch import BoschConfig, save_bosch_config
        zone_map = {}
        for part in self._bosch_zones.text().split(","):
            if "=" in part:
                z, c = part.split("=", 1)
                if z.strip():
                    zone_map[z.strip()] = c.strip()

        bcfg = BoschConfig(
            enabled=self._bosch_enabled.isChecked(),
            protocol=self._bosch_protocol.currentData() or "mode2",
            host=self._bosch_host.text().strip(),
            port=self._bosch_port.value(),
            passcode=self._bosch_passcode.text(),
            listen_port=self._bosch_listen_port.value(),
            zone_mapping=zone_map,
        )
        save_bosch_config(bcfg)

        self._changed = True
        self.accept()

    def changed(self) -> bool:
        return self._changed
