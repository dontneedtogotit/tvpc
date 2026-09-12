"""Bosch Security Alarm System Integration (Mode 2 TCP & SIA DC-09 IP Receiver).

Supports Bosch Solution (2000, 3000, 4000, 6000) and B-Series/G-Series panels.
Integrates alarm zone trips with TVPC camera feeds for instant TV popup alerts
and NVR event recording.
"""
from __future__ import annotations

import json
import re
import socket
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from PySide6.QtCore import QObject, Signal

from .config import CONF_DIR

BOSCH_CONF_FILE = CONF_DIR / "bosch.json"


@dataclass
class BoschConfig:
    enabled: bool = False
    protocol: str = "mode2"  # "mode2" or "sia"
    host: str = "192.168.1.50"
    port: int = 7700
    passcode: str = "1234"
    listen_port: int = 10002
    account_id: str = "0001"
    zone_mapping: Dict[str, str] = field(default_factory=dict)  # "1" -> "Front Door"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "enabled": self.enabled,
            "protocol": self.protocol,
            "host": self.host,
            "port": self.port,
            "passcode": self.passcode,
            "listen_port": self.listen_port,
            "account_id": self.account_id,
            "zone_mapping": self.zone_mapping,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> BoschConfig:
        return cls(
            enabled=bool(data.get("enabled", False)),
            protocol=str(data.get("protocol", "mode2")),
            host=str(data.get("host", "192.168.1.50")),
            port=int(data.get("port", 7700)),
            passcode=str(data.get("passcode", "1234")),
            listen_port=int(data.get("listen_port", 10002)),
            account_id=str(data.get("account_id", "0001")),
            zone_mapping=dict(data.get("zone_mapping", {})),
        )


def load_bosch_config() -> BoschConfig:
    if BOSCH_CONF_FILE.exists():
        try:
            data = json.loads(BOSCH_CONF_FILE.read_text(encoding="utf-8"))
            return BoschConfig.from_dict(data)
        except Exception:
            pass
    return BoschConfig()


def save_bosch_config(cfg: BoschConfig) -> None:
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    BOSCH_CONF_FILE.write_text(json.dumps(cfg.to_dict(), indent=2) + "\n", encoding="utf-8")


def parse_sia_packet(packet_str: str) -> Optional[Tuple[str, str, int]]:
    """Parse a SIA DC-09 message.

    Returns (account, event_code, zone_number) or None.
    Example payload: "[#0001|Nri1/BA002]" -> account="0001", code="BA", zone=2
    """
    # Standard SIA: [#ACCOUNT|Nri1/CODE001] or [#ACCOUNT|CODE001]
    m = re.search(r"\[#([0-9A-Fa-f]+)\|(?:[^/|]*/)?([A-Z]{2})(\d+)\]", packet_str)
    if m:
        account = m.group(1)
        code = m.group(2)
        zone = int(m.group(3))
        return (account, code, zone)

    return None


class BoschPanelClient(QObject):
    """Client and listener for Bosch Alarm Panels."""

    zone_triggered = Signal(int, str, str)  # (zone_num, event_type, linked_camera)
    status_changed = Signal(str)            # status text

    def __init__(self, config: Optional[BoschConfig] = None, parent: Optional[QObject] = None) -> None:
        super().__init__(parent)
        self.config = config or load_bosch_config()
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._sock: Optional[socket.socket] = None

    def start(self) -> None:
        """Start listening for panel events."""
        if not self.config.enabled:
            return
        self.stop()
        self._running = True
        if self.config.protocol == "sia":
            self._thread = threading.Thread(target=self._run_sia_receiver, daemon=True)
        else:
            self._thread = threading.Thread(target=self._run_mode2_client, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Stop background worker."""
        self._running = False
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
            self._thread = None
        self.status_changed.emit("Stopped")

    def _run_sia_receiver(self) -> None:
        """Listen on UDP/TCP port for incoming SIA DC-09 alarm packets from Bosch panel."""
        self.status_changed.emit(f"SIA Receiver listening on port {self.config.listen_port}")
        try:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._sock.bind(("0.0.0.0", self.config.listen_port))
            self._sock.settimeout(2.0)

            while self._running:
                try:
                    data, addr = self._sock.recvfrom(2048)
                    text = data.decode("ascii", errors="replace")
                    parsed = parse_sia_packet(text)
                    if parsed:
                        account, code, zone = parsed
                        linked_cam = self.config.zone_mapping.get(str(zone), "")
                        event_desc = f"Alarm ({code})"
                        self.zone_triggered.emit(zone, event_desc, linked_cam)

                        # Send SIA ACK response back to panel
                        ack = f"\"*ACK\"0000R0000L0000[#account]|".encode("ascii")
                        try:
                            self._sock.sendto(ack, addr)
                        except Exception:
                            pass
                except socket.timeout:
                    continue
                except OSError:
                    break
        except Exception as e:
            self.status_changed.emit(f"SIA Receiver Error: {e}")
        finally:
            self.status_changed.emit("SIA Receiver offline")

    def _run_mode2_client(self) -> None:
        """Connect directly to Bosch panel IP (B426/IP Plus) on TCP port 7700."""
        self.status_changed.emit(f"Connecting to Bosch Panel {self.config.host}:{self.config.port}…")
        while self._running:
            try:
                self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self._sock.settimeout(5.0)
                self._sock.connect((self.config.host, self.config.port))
                self.status_changed.emit("Connected to Bosch panel")

                # Basic Mode 2 handshake packet: Login command
                login_payload = bytearray([0x02, 0x06]) + self.config.passcode.encode("ascii") + bytearray([0x03])
                self._sock.sendall(login_payload)

                while self._running:
                    data = self._sock.recv(1024)
                    if not data:
                        break

                    # Check for zone alarm byte patterns (DLE/STX or 0x01 alarm flag)
                    if len(data) >= 3 and data[0] == 0x02:
                        cmd = data[1]
                        if cmd == 0x24:  # Zone status packet
                            # byte 2 is zone number, byte 3 is state (1 = Alarm)
                            zone_num = int(data[2])
                            state = int(data[3]) if len(data) > 3 else 0
                            if state == 0x01:
                                linked_cam = self.config.zone_mapping.get(str(zone_num), "")
                                self.zone_triggered.emit(zone_num, "Burglary Alarm", linked_cam)

                    time.sleep(0.1)

            except Exception as e:
                if self._running:
                    self.status_changed.emit(f"Disconnected ({e}), retrying in 10s…")
                    time.sleep(10.0)
            finally:
                if self._sock:
                    try:
                        self._sock.close()
                    except Exception:
                        pass
                    self._sock = None
