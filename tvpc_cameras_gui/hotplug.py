"""Hotplug and background zero-conf camera monitor."""
from __future__ import annotations

import ipaddress
import threading
import time
from typing import Dict, Optional, Set

from PySide6.QtCore import QObject, QTimer, Signal

from . import config as cfg
from . import discover as disc
from .v4l2 import list_v4l2_devices


class HotplugMonitor(QObject):
    """Monitors local USB/V4L2 devices and network changes for plug-and-play camera detection."""

    v4l2_plugged = Signal(dict)              # device info dict
    v4l2_unplugged = Signal(str)             # device path e.g. /dev/video0
    camera_discovered = Signal(object)       # DiscoveredCamera

    def __init__(
        self,
        parent: Optional[QObject] = None,
        check_interval_ms: int = 5000,
        enable_network_watch: bool = True,
    ) -> None:
        super().__init__(parent)
        self.check_interval_ms = check_interval_ms
        self.enable_network_watch = enable_network_watch

        self._known_v4l2: Set[str] = set()
        self._known_network_hosts: Set[str] = set()
        self._initial_scan_done = False
        self._is_probing_network = False

        # Seed known devices from current state
        initial_devices = list_v4l2_devices(capture_only=True)
        self._known_v4l2 = {d["device"] for d in initial_devices}

        # Seed network hosts from configured cameras
        for cam in cfg.load_cameras():
            if "://" in cam.url:
                try:
                    from urllib.parse import urlparse
                    h = urlparse(cam.url).hostname
                    if h:
                        self._known_network_hosts.add(h)
                except Exception:
                    pass

        self._timer = QTimer(self)
        self._timer.setInterval(self.check_interval_ms)
        self._timer.timeout.connect(self._on_tick)

    def start(self) -> None:
        self._timer.start()

    def stop(self) -> None:
        self._timer.stop()

    def _on_tick(self) -> None:
        # 1. Check local V4L2 devices
        current_devices = list_v4l2_devices(capture_only=True)
        current_dev_paths = {d["device"] for d in current_devices}

        # Find new USB devices
        for dev in current_devices:
            path = dev["device"]
            if path not in self._known_v4l2:
                self._known_v4l2.add(path)
                self.v4l2_plugged.emit(dev)

        # Find unplugged USB devices
        removed = self._known_v4l2 - current_dev_paths
        for path in removed:
            self._known_v4l2.remove(path)
            self.v4l2_unplugged.emit(path)

        # 2. Check network devices passively via ARP table
        if self.enable_network_watch and not self._is_probing_network:
            self._is_probing_network = True
            threading.Thread(target=self._scan_arp_changes, daemon=True).start()

    def _scan_arp_changes(self) -> None:
        try:
            arp_hosts = disc.arp_hosts()
            new_hosts = [h for h in arp_hosts if h not in self._known_network_hosts]

            for host in new_hosts:
                self._known_network_hosts.add(host)
                # Quick non-blocking probe on camera ports
                cams = disc.quick_probe_all_ports(host, timeout=1.0)
                for cam in cams:
                    if cam.url:
                        self.camera_discovered.emit(cam)
        except Exception:
            pass
        finally:
            self._is_probing_network = False
