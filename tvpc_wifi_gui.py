#!/usr/bin/env python3
"""tvpc_wifi_gui.py — Modern 10-foot Wi-Fi Settings GUI for tvpc.

Features:
- Live NetworkManager (nmcli) integration
- Dark glass Estuary / tvpc theme
- Large TV-friendly text, remote arrow-key navigation & mouse wheel support
- Connection status banner (SSID, IP, signal, interface)
- Wi-Fi radio on/off toggle
- Network scanning with signal bars & security indicators
- Clean password prompt dialog with show/hide toggle
- Disconnect & forget network support
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

# Attempt to import PySide6
try:
    from PySide6.QtCore import Qt, QThread, Signal, QTimer, QSize
    from PySide6.QtGui import QFont, QIcon, QColor, QPalette, QKeyEvent
    from PySide6.QtWidgets import (
        QApplication,
        QDialog,
        QFrame,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QListWidget,
        QListWidgetItem,
        QMessageBox,
        QPushButton,
        QScrollArea,
        QSizePolicy,
        QSpacerItem,
        QVBoxLayout,
        QWidget,
    )
    HAS_PYSIDE6 = True
except ImportError:
    HAS_PYSIDE6 = False


# -----------------------------------------------------------------------------
# NetworkManager Backend via nmcli
# -----------------------------------------------------------------------------
class NetworkBackend:
    @staticmethod
    def run_cmd(cmd: List[str], timeout: float = 12.0) -> Tuple[int, str, str]:
        try:
            res = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            return res.returncode, res.stdout, res.stderr
        except Exception as e:
            return -1, "", str(e)

    @classmethod
    def is_wifi_enabled(cls) -> bool:
        code, out, _ = cls.run_cmd(["nmcli", "radio", "wifi"])
        return code == 0 and "enabled" in out.lower()

    @classmethod
    def set_wifi_enabled(cls, enabled: bool) -> bool:
        state = "on" if enabled else "off"
        code, _, _ = cls.run_cmd(["nmcli", "radio", "wifi", state])
        return code == 0

    @classmethod
    def get_current_connection(cls) -> Dict[str, str]:
        status = {
            "connected": False,
            "ssid": "Not Connected",
            "device": "",
            "ip": "—",
            "signal": "0%",
            "security": "",
        }
        # Find active wifi device
        code, out, _ = cls.run_cmd(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "dev"])
        if code == 0:
            for line in out.strip().splitlines():
                parts = line.split(":")
                if len(parts) >= 4 and parts[1] == "wifi" and "connected" in parts[2]:
                    status["connected"] = True
                    status["device"] = parts[0]
                    status["ssid"] = parts[3]
                    break

        if status["connected"] and status["device"]:
            # Get IP and details
            c_code, c_out, _ = cls.run_cmd(["nmcli", "-t", "-f", "IP4.ADDRESS", "dev", "show", status["device"]])
            if c_code == 0:
                for line in c_out.strip().splitlines():
                    if line.startswith("IP4.ADDRESS"):
                        val = line.split(":", 1)[-1].strip()
                        status["ip"] = val.split("/")[0]
                        break

            # Get signal strength of current connected AP
            w_code, w_out, _ = cls.run_cmd(["nmcli", "-t", "-f", "SSID,IN-USE,SIGNAL,SECURITY", "dev", "wifi", "list"])
            if w_code == 0:
                for line in w_out.strip().splitlines():
                    p = line.split(":")
                    if len(p) >= 4 and p[1] == "*":
                        status["signal"] = f"{p[2]}%"
                        status["security"] = p[3] if len(p) > 3 else "WPA2"
                        break

        return status

    @classmethod
    def scan_networks(cls, rescan: bool = True) -> List[Dict[str, str]]:
        cmd = ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,BARS", "dev", "wifi", "list"]
        if rescan:
            cmd.extend(["--rescan", "yes"])
        code, out, _ = cls.run_cmd(cmd, timeout=10.0)
        if code != 0:
            return []

        networks: Dict[str, Dict[str, str]] = {}
        for line in out.strip().splitlines():
            # Handle potential escaping in SSID
            parts = line.split(":")
            if len(parts) < 4:
                continue
            in_use = parts[0] == "*"
            ssid = parts[1].strip()
            if not ssid or ssid == "--":
                continue

            try:
                signal_val = int(parts[2])
            except ValueError:
                signal_val = 0

            sec = parts[3].strip() if len(parts) > 3 else "Open"
            bars = parts[4].strip() if len(parts) > 4 else "▂▄▆█"

            # Deduplicate by SSID, preferring connected or strongest signal
            if ssid in networks:
                existing = networks[ssid]
                if in_use or signal_val > int(existing.get("signal_num", 0)):
                    networks[ssid] = {
                        "ssid": ssid,
                        "in_use": in_use,
                        "signal": f"{signal_val}%",
                        "signal_num": signal_val,
                        "security": sec if sec else "Open",
                        "bars": bars,
                    }
            else:
                networks[ssid] = {
                    "ssid": ssid,
                    "in_use": in_use,
                    "signal": f"{signal_val}%",
                    "signal_num": signal_val,
                    "security": sec if sec else "Open",
                    "bars": bars,
                }

        # Sort: connected first, then by signal strength descending
        results = list(networks.values())
        results.sort(key=lambda x: (1 if x["in_use"] else 0, x["signal_num"]), reverse=True)
        return results

    @classmethod
    def connect_network(cls, ssid: str, password: Optional[str] = None) -> Tuple[bool, str]:
        cmd = ["nmcli", "dev", "wifi", "connect", ssid]
        if password:
            cmd.extend(["password", password])
        code, out, err = cls.run_cmd(cmd, timeout=25.0)
        if code == 0:
            return True, "Successfully connected."
        msg = err.strip() or out.strip() or "Failed to connect to network."
        return False, msg

    @classmethod
    def disconnect_network(cls, device: Optional[str] = None) -> Tuple[bool, str]:
        curr = cls.get_current_connection()
        dev = device or curr.get("device")
        if not dev:
            return False, "No active Wi-Fi device found."
        code, out, err = cls.run_cmd(["nmcli", "dev", "disconnect", dev])
        if code == 0:
            return True, "Disconnected."
        return False, err.strip() or out.strip()

    @classmethod
    def forget_network(cls, ssid: str) -> Tuple[bool, str]:
        code, out, err = cls.run_cmd(["nmcli", "connection", "delete", ssid])
        if code == 0:
            return True, f"Forgot {ssid}."
        return False, err.strip() or out.strip()


# -----------------------------------------------------------------------------
# Background Scanner Thread
# -----------------------------------------------------------------------------
if HAS_PYSIDE6:
    class ScanWorker(QThread):
        scan_finished = Signal(list)
        status_updated = Signal(dict)

        def __init__(self, rescan: bool = True):
            super().__init__()
            self.rescan = rescan

        def run(self):
            status = NetworkBackend.get_current_connection()
            self.status_updated.emit(status)
            networks = NetworkBackend.scan_networks(rescan=self.rescan)
            self.scan_finished.emit(networks)

    class ConnectWorker(QThread):
        connect_finished = Signal(bool, str)

        def __init__(self, ssid: str, password: Optional[str] = None):
            super().__init__()
            self.ssid = ssid
            self.password = password

        def run(self):
            ok, msg = NetworkBackend.connect_network(self.ssid, self.password)
            self.connect_finished.emit(ok, msg)


# -----------------------------------------------------------------------------
# Password Dialog (Estuary TV Theme)
# -----------------------------------------------------------------------------
if HAS_PYSIDE6:
    class WifiPasswordDialog(QDialog):
        def __init__(self, ssid: str, security: str, parent=None):
            super().__init__(parent)
            self.ssid = ssid
            self.security = security
            self.password = ""
            self.init_ui()

        def init_ui(self):
            self.setWindowTitle(f"Connect to {self.ssid}")
            self.setModal(True)
            self.setMinimumWidth(540)
            self.setStyleSheet("""
                QDialog {
                    background-color: #0b1118;
                    border: 2px solid #00d2ff;
                    border-radius: 12px;
                }
                QLabel {
                    color: #f1f5f9;
                    font-family: 'Noto Sans', sans-serif;
                }
                QLineEdit {
                    background-color: #16222f;
                    border: 2px solid #334155;
                    border-radius: 8px;
                    padding: 10px 14px;
                    color: #ffffff;
                    font-size: 16px;
                }
                QLineEdit:focus {
                    border: 2px solid #00d2ff;
                    background-color: #1a2938;
                }
                QPushButton {
                    background-color: #1e293b;
                    color: #f8fafc;
                    border: 1px solid #334155;
                    border-radius: 8px;
                    padding: 10px 20px;
                    font-size: 15px;
                    font-weight: bold;
                }
                QPushButton:focus, QPushButton:hover {
                    background-color: #0284c7;
                    border: 2px solid #38bdf8;
                    color: #ffffff;
                }
                QPushButton#primaryBtn {
                    background-color: #008eb3;
                    border: 1px solid #00d2ff;
                }
                QPushButton#primaryBtn:focus, QPushButton#primaryBtn:hover {
                    background-color: #00d2ff;
                    color: #050b14;
                }
            """)

            layout = QVBoxLayout(self)
            layout.setContentsMargins(28, 28, 28, 28)
            layout.setSpacing(18)

            title = QLabel(f"🔒 {self.ssid}")
            title_font = QFont("Noto Sans", 18, QFont.Bold)
            title.setFont(title_font)
            layout.addWidget(title)

            subtitle = QLabel(f"Security: {self.security}. Enter password to connect:")
            subtitle.setStyleSheet("color: #94a3b8; font-size: 14px;")
            layout.addWidget(subtitle)

            self.pwd_input = QLineEdit()
            self.pwd_input.setPlaceholderText("Enter Wi-Fi Password")
            self.pwd_input.setEchoMode(QLineEdit.Password)
            layout.addWidget(self.pwd_input)

            # Show/Hide toggle button
            self.toggle_btn = QPushButton("👁 Show Password")
            self.toggle_btn.setCheckable(True)
            self.toggle_btn.setStyleSheet("font-size: 12px; padding: 6px 12px;")
            self.toggle_btn.clicked.connect(self._toggle_echo)
            layout.addWidget(self.toggle_btn, alignment=Qt.AlignLeft)

            btn_layout = QHBoxLayout()
            btn_layout.setSpacing(12)

            self.cancel_btn = QPushButton("Cancel (Esc)")
            self.cancel_btn.clicked.connect(self.reject)
            btn_layout.addWidget(self.cancel_btn)

            self.connect_btn = QPushButton("Connect (Enter)")
            self.connect_btn.setObjectName("primaryBtn")
            self.connect_btn.clicked.connect(self._on_connect)
            btn_layout.addWidget(self.connect_btn)

            layout.addLayout(btn_layout)
            self.pwd_input.returnPressed.connect(self._on_connect)
            self.pwd_input.setFocus()

        def _toggle_echo(self):
            if self.toggle_btn.isChecked():
                self.pwd_input.setEchoMode(QLineEdit.Normal)
                self.toggle_btn.setText("🔒 Hide Password")
            else:
                self.pwd_input.setEchoMode(QLineEdit.Password)
                self.toggle_btn.setText("👁 Show Password")

        def _on_connect(self):
            self.password = self.pwd_input.text()
            self.accept()

        def keyPressEvent(self, event: QKeyEvent):
            if event.key() == Qt.Key_Escape:
                self.reject()
            else:
                super().keyPressEvent(event)


# -----------------------------------------------------------------------------
# Main Wi-Fi Settings Window
# -----------------------------------------------------------------------------
if HAS_PYSIDE6:
    class WifiSettingsWindow(QWidget):
        def __init__(self):
            super().__init__()
            self.scan_worker: Optional[ScanWorker] = None
            self.connect_worker: Optional[ConnectWorker] = None
            self.current_networks: List[Dict[str, str]] = []
            self.init_ui()
            self.refresh_all(rescan=True)

        def init_ui(self):
            self.setWindowTitle("Wi-Fi & Network Settings")
            self.resize(1000, 720)
            self.setStyleSheet("""
                QWidget {
                    background-color: #060a0f;
                    color: #f1f5f9;
                    font-family: 'Noto Sans', sans-serif;
                }
                QFrame#statusCard {
                    background-color: #0e1724;
                    border: 1px solid #1e293b;
                    border-radius: 12px;
                    border-top: 2px solid #00d2ff;
                }
                QFrame#listContainer {
                    background-color: #0a111a;
                    border: 1px solid #1e293b;
                    border-radius: 12px;
                }
                QListWidget {
                    background-color: transparent;
                    border: none;
                    outline: none;
                }
                QListWidget::item {
                    background-color: #121d2b;
                    border: 1px solid #1e293b;
                    border-radius: 8px;
                    margin-bottom: 8px;
                    padding: 12px;
                }
                QListWidget::item:selected {
                    background-color: #0284c7;
                    border: 2px solid #38bdf8;
                }
                QListWidget::item:hover:!selected {
                    background-color: #1a2a3e;
                    border: 1px solid #38bdf8;
                }
                QPushButton {
                    background-color: #1e293b;
                    color: #f8fafc;
                    border: 1px solid #334155;
                    border-radius: 8px;
                    padding: 10px 18px;
                    font-size: 14px;
                    font-weight: bold;
                }
                QPushButton:focus, QPushButton:hover {
                    background-color: #0284c7;
                    border: 2px solid #38bdf8;
                    color: #ffffff;
                }
                QPushButton#actionBtn {
                    background-color: #008eb3;
                    border: 1px solid #00d2ff;
                }
                QPushButton#actionBtn:focus, QPushButton#actionBtn:hover {
                    background-color: #00d2ff;
                    color: #050b14;
                }
                QPushButton#dangerBtn {
                    background-color: #881337;
                    border: 1px solid #e11d48;
                }
                QPushButton#dangerBtn:focus, QPushButton#dangerBtn:hover {
                    background-color: #e11d48;
                    color: #ffffff;
                }
            """)

            main_layout = QVBoxLayout(self)
            main_layout.setContentsMargins(32, 28, 32, 28)
            main_layout.setSpacing(20)

            # Header Row
            header_layout = QHBoxLayout()
            header_title = QLabel("📶 Wi-Fi Settings")
            header_title.setFont(QFont("Noto Sans", 22, QFont.Bold))
            header_layout.addWidget(header_title)

            header_layout.addStretch()

            self.radio_btn = QPushButton("Wi-Fi Radio: ON")
            self.radio_btn.clicked.connect(self.toggle_wifi_radio)
            header_layout.addWidget(self.radio_btn)

            self.rescan_btn = QPushButton("🔄 Rescan Networks")
            self.rescan_btn.clicked.connect(lambda: self.refresh_all(rescan=True))
            header_layout.addWidget(self.rescan_btn)

            main_layout.addLayout(header_layout)

            # Status Banner Card
            self.status_card = QFrame()
            self.status_card.setObjectName("statusCard")
            status_layout = QVBoxLayout(self.status_card)
            status_layout.setContentsMargins(20, 16, 20, 16)
            status_layout.setSpacing(8)

            top_status_row = QHBoxLayout()
            self.status_badge = QLabel("CONNECTED")
            self.status_badge.setStyleSheet("background-color: #10b981; color: #022c22; font-weight: bold; padding: 4px 10px; border-radius: 6px; font-size: 12px;")
            top_status_row.addWidget(self.status_badge)

            self.current_ssid_label = QLabel("Loading...")
            self.current_ssid_label.setFont(QFont("Noto Sans", 17, QFont.Bold))
            top_status_row.addWidget(self.current_ssid_label)
            top_status_row.addStretch()

            self.disconnect_btn = QPushButton("Disconnect")
            self.disconnect_btn.setObjectName("dangerBtn")
            self.disconnect_btn.clicked.connect(self.disconnect_current)
            top_status_row.addWidget(self.disconnect_btn)

            status_layout.addLayout(top_status_row)

            # Details row (IP, Signal, Interface)
            details_row = QHBoxLayout()
            self.ip_label = QLabel("IP Address: —")
            self.ip_label.setStyleSheet("color: #94a3b8; font-size: 13px;")
            details_row.addWidget(self.ip_label)

            details_row.addWidget(QLabel("•", alignment=Qt.AlignCenter))

            self.signal_label = QLabel("Signal: —")
            self.signal_label.setStyleSheet("color: #94a3b8; font-size: 13px;")
            details_row.addWidget(self.signal_label)

            details_row.addWidget(QLabel("•", alignment=Qt.AlignCenter))

            self.dev_label = QLabel("Device: —")
            self.dev_label.setStyleSheet("color: #94a3b8; font-size: 13px;")
            details_row.addWidget(self.dev_label)

            details_row.addStretch()
            status_layout.addLayout(details_row)

            main_layout.addWidget(self.status_card)

            # Network List Container
            list_container = QFrame()
            list_container.setObjectName("listContainer")
            list_box = QVBoxLayout(list_container)
            list_box.setContentsMargins(16, 16, 16, 16)
            list_box.setSpacing(12)

            list_header = QHBoxLayout()
            list_title = QLabel("Available Wireless Networks")
            list_title.setFont(QFont("Noto Sans", 15, QFont.Bold))
            list_title.setStyleSheet("color: #38bdf8;")
            list_header.addWidget(list_title)

            list_header.addStretch()
            self.scan_status_label = QLabel("Ready")
            self.scan_status_label.setStyleSheet("color: #64748b; font-size: 13px;")
            list_header.addWidget(self.scan_status_label)

            list_box.addLayout(list_header)

            self.network_list = QListWidget()
            self.network_list.itemActivated.connect(self.on_item_activated)
            list_box.addWidget(self.network_list)

            main_layout.addWidget(list_container, stretch=1)

            # Bottom Controls & Remote Hints
            footer_layout = QHBoxLayout()
            hints_label = QLabel("🎮 Navigation: [↑/↓] Select Network    [Enter/OK] Connect    [Esc] Close")
            hints_label.setStyleSheet("color: #64748b; font-size: 13px; font-weight: bold;")
            footer_layout.addWidget(hints_label)

            footer_layout.addStretch()

            self.close_btn = QPushButton("Close (Esc)")
            self.close_btn.clicked.connect(self.close)
            footer_layout.addWidget(self.close_btn)

            main_layout.addLayout(footer_layout)

            # Auto periodic status check
            self.poll_timer = QTimer(self)
            self.poll_timer.setInterval(8000)
            self.poll_timer.timeout.connect(lambda: self.refresh_all(rescan=False))
            self.poll_timer.start()

        def keyPressEvent(self, event: QKeyEvent):
            if event.key() == Qt.Key_Escape:
                self.close()
            elif event.key() == Qt.Key_F5:
                self.refresh_all(rescan=True)
            else:
                super().keyPressEvent(event)

        def toggle_wifi_radio(self):
            currently_on = NetworkBackend.is_wifi_enabled()
            NetworkBackend.set_wifi_enabled(not currently_on)
            self.refresh_all(rescan=True)

        def disconnect_current(self):
            ok, msg = NetworkBackend.disconnect_network()
            if ok:
                self.refresh_all(rescan=False)
            else:
                QMessageBox.warning(self, "Disconnect", msg)

        def refresh_all(self, rescan: bool = True):
            wifi_on = NetworkBackend.is_wifi_enabled()
            self.radio_btn.setText(f"Wi-Fi Radio: {'ON' if wifi_on else 'OFF'}")
            if not wifi_on:
                self.status_badge.setText("RADIO DISABLED")
                self.status_badge.setStyleSheet("background-color: #475569; color: #cbd5e1; font-weight: bold; padding: 4px 10px; border-radius: 6px;")
                self.current_ssid_label.setText("Wi-Fi is turned off")
                self.ip_label.setText("IP: —")
                self.signal_label.setText("Signal: —")
                self.dev_label.setText("Device: —")
                self.disconnect_btn.setVisible(False)
                self.network_list.clear()
                self.scan_status_label.setText("Turn on Wi-Fi to scan")
                return

            self.disconnect_btn.setVisible(True)
            self.scan_status_label.setText("Scanning..." if rescan else "Updating...")
            self.rescan_btn.setEnabled(False)

            if self.scan_worker and self.scan_worker.isRunning():
                self.scan_worker.terminate()

            self.scan_worker = ScanWorker(rescan=rescan)
            self.scan_worker.status_updated.connect(self.update_status_ui)
            self.scan_worker.scan_finished.connect(self.populate_networks_ui)
            self.scan_worker.start()

        def update_status_ui(self, status: Dict[str, str]):
            connected = status.get("connected", False)
            if connected:
                self.status_badge.setText("CONNECTED")
                self.status_badge.setStyleSheet("background-color: #10b981; color: #022c22; font-weight: bold; padding: 4px 10px; border-radius: 6px;")
                self.current_ssid_label.setText(status.get("ssid", "Connected"))
                self.ip_label.setText(f"IP: {status.get('ip', '—')}")
                self.signal_label.setText(f"Signal: {status.get('signal', '—')}")
                self.dev_label.setText(f"Device: {status.get('device', '—')}")
                self.disconnect_btn.setEnabled(True)
            else:
                self.status_badge.setText("DISCONNECTED")
                self.status_badge.setStyleSheet("background-color: #e11d48; color: #fff; font-weight: bold; padding: 4px 10px; border-radius: 6px;")
                self.current_ssid_label.setText("Not Connected")
                self.ip_label.setText("IP: —")
                self.signal_label.setText("Signal: —")
                self.dev_label.setText(f"Device: {status.get('device', '—')}")
                self.disconnect_btn.setEnabled(False)

        def populate_networks_ui(self, networks: List[Dict[str, str]]):
            self.rescan_btn.setEnabled(True)
            self.scan_status_label.setText(f"{len(networks)} networks found")
            self.current_networks = networks
            self.network_list.clear()

            for net in networks:
                ssid = net["ssid"]
                signal = net["signal"]
                sec = net["security"]
                bars = net.get("bars", "▂▄▆█")
                in_use = net["in_use"]

                item = QListWidgetItem()
                item.setData(Qt.UserRole, net)

                # Custom widget for list item
                row_widget = QWidget()
                row_layout = QHBoxLayout(row_widget)
                row_layout.setContentsMargins(10, 8, 10, 8)
                row_layout.setSpacing(16)

                # Icon / Lock
                lock_icon = "🔒" if sec != "Open" else "🌐"
                icon_lbl = QLabel(f"{lock_icon} {bars}")
                icon_lbl.setStyleSheet("font-size: 15px; color: #38bdf8;")
                row_layout.addWidget(icon_lbl)

                # SSID Label
                ssid_lbl = QLabel(ssid)
                ssid_lbl.setFont(QFont("Noto Sans", 14, QFont.Bold if in_use else QFont.Normal))
                ssid_lbl.setStyleSheet("color: #38bdf8;" if in_use else "color: #f8fafc;")
                row_layout.addWidget(ssid_lbl, stretch=1)

                # Connected badge
                if in_use:
                    badge = QLabel("CONNECTED")
                    badge.setStyleSheet("background-color: #10b981; color: #022c22; font-weight: bold; padding: 2px 8px; border-radius: 4px; font-size: 11px;")
                    row_layout.addWidget(badge)

                # Security Type
                sec_lbl = QLabel(sec)
                sec_lbl.setStyleSheet("color: #64748b; font-size: 12px;")
                row_layout.addWidget(sec_lbl)

                # Signal Strength
                sig_lbl = QLabel(signal)
                sig_lbl.setStyleSheet("color: #94a3b8; font-size: 13px; font-weight: bold;")
                row_layout.addWidget(sig_lbl)

                item.setSizeHint(row_widget.sizeHint())
                self.network_list.addItem(item)
                self.network_list.setItemWidget(item, row_widget)

            if self.network_list.count() > 0:
                self.network_list.setCurrentRow(0)
                self.network_list.setFocus()

        def on_item_activated(self, item: QListWidgetItem):
            net = item.data(Qt.UserRole)
            if not net:
                return
            ssid = net["ssid"]
            sec = net["security"]
            in_use = net["in_use"]

            if in_use:
                reply = QMessageBox.question(
                    self,
                    f"Manage {ssid}",
                    f"You are currently connected to {ssid}.\n\nDo you want to disconnect?",
                    QMessageBox.Yes | QMessageBox.No,
                )
                if reply == QMessageBox.Yes:
                    self.disconnect_current()
                return

            password = None
            if sec != "Open":
                dialog = WifiPasswordDialog(ssid, sec, self)
                if dialog.exec() != QDialog.Accepted:
                    return
                password = dialog.password

            self.scan_status_label.setText(f"Connecting to {ssid}...")
            self.network_list.setEnabled(False)

            self.connect_worker = ConnectWorker(ssid, password)
            self.connect_worker.connect_finished.connect(self.on_connect_finished)
            self.connect_worker.start()

        def on_connect_finished(self, ok: bool, msg: str):
            self.network_list.setEnabled(True)
            if ok:
                self.scan_status_label.setText("Connected successfully!")
                self.refresh_all(rescan=False)
            else:
                self.scan_status_label.setText("Connection failed")
                QMessageBox.critical(self, "Connection Error", msg)


# -----------------------------------------------------------------------------
# Terminal / Zenity Fallback
# -----------------------------------------------------------------------------
def run_zenity_wifi_flow():
    """Zenity / CLI fallback when PySide6 is unavailable."""
    status = NetworkBackend.get_current_connection()
    status_str = f"Status: {'Connected to ' + status['ssid'] if status['connected'] else 'Not Connected'}\nIP: {status['ip']} | Signal: {status['signal']}"
    
    if shutil.which("zenity"):
        subprocess.run(["zenity", "--info", "--text", status_str, "--title", "tvpc Wi-Fi Settings"], check=False)
    else:
        print(f"\n--- tvpc Wi-Fi Settings ---\n{status_str}\n")


def main():
    if not HAS_PYSIDE6:
        print("Note: PySide6 not installed; falling back to dialog.", file=sys.stderr)
        run_zenity_wifi_flow()
        return 0

    os.environ.setdefault("QT_SCALE_FACTOR_ROUNDING_POLICY", "RoundPreferFloor")
    from PySide6.QtGui import QGuiApplication
    QGuiApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.RoundPreferFloor)

    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = WifiSettingsWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
