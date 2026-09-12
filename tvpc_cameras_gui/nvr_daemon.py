"""Headless 24/7 NVR Background Daemon for TVPC.

Monitors cameras, performs scheduled retention enforcement, listens for
Bosch alarm zone triggers, runs motion/person detection, and displays
transient TV popups over HDMI output.
"""
from __future__ import annotations

import argparse
import signal
import sys
import time
from typing import Dict, Optional

from PySide6.QtCore import QCoreApplication, QTimer

from . import config as cfg
from .bosch import BoschPanelClient, load_bosch_config
from .motion import MotionDetector
from .ai_filter import ObjectFilter
from .popup import SmartPopupManager
from .recording import RecordingManager
from .settings import load_settings
from .storage import StorageManager


class NvrDaemon:
    """Headless 24/7 NVR daemon coordinator."""

    def __init__(self) -> None:
        self.settings = load_settings()
        self.storage = StorageManager()
        self.recording_mgr = RecordingManager()
        self.popup_mgr = SmartPopupManager(
            duration_seconds=float(self.settings.get("popup_duration", 15.0)),
            cooldown_seconds=float(self.settings.get("popup_cooldown", 20.0)),
            sound_enabled=bool(self.settings.get("popup_sound", True)),
        )

        ai_enabled = bool(self.settings.get("ai_filter_enabled", False))
        ai_target = str(self.settings.get("ai_target_mode", ObjectFilter.TARGET_PERSON_VEHICLE))
        self.ai_filter = ObjectFilter(target_mode=ai_target) if ai_enabled else None

        self.motion_detector = MotionDetector(
            sensitivity=float(self.settings.get("motion_sensitivity", 0.12)),
            cooldown_seconds=float(self.settings.get("motion_cooldown", 10.0)),
            auto_snapshot=bool(self.settings.get("motion_auto_snapshot", True)),
            ai_filter=self.ai_filter,
        )

        self.bosch_client = BoschPanelClient(load_bosch_config())

        # Wire signals
        self.motion_detector.motion_detected.connect(self._on_motion_detected)
        self.bosch_client.zone_triggered.connect(self._on_bosch_zone)

        # Retention check timer (every 15 minutes)
        self.retention_timer = QTimer()
        self.retention_timer.setInterval(15 * 60 * 1000)
        self.retention_timer.timeout.connect(self._on_retention_check)

    def start(self) -> None:
        """Start daemon components."""
        print("[NVR Daemon] Starting background services...")
        self.retention_timer.start()
        self._on_retention_check()

        # Start Bosch listener if configured
        if self.bosch_client.config.enabled:
            print(f"[NVR Daemon] Starting Bosch listener ({self.bosch_client.config.protocol})...")
            self.bosch_client.start()

    def stop(self) -> None:
        """Clean shutdown."""
        print("[NVR Daemon] Stopping services...")
        self.retention_timer.stop()
        self.bosch_client.stop()
        self.popup_mgr.close_popup()

    def _on_retention_check(self) -> None:
        max_storage_gb = float(self.settings.get("max_storage_gb", 20.0))
        max_retention_days = int(self.settings.get("max_retention_days", 14))
        min_free_space_gb = float(self.settings.get("min_free_space_gb", 5.0))

        deleted, freed = self.storage.enforce_retention(
            max_storage_gb=max_storage_gb,
            max_retention_days=max_retention_days,
            min_free_space_gb=min_free_space_gb,
        )
        if deleted:
            print(f"[NVR Daemon] Purged {len(deleted)} old recordings ({freed} bytes freed)")

    def _on_motion_detected(self, camera_name: str, delta: float) -> None:
        print(f"[NVR Daemon] Motion detected on '{camera_name}' (delta: {delta:.2f})")
        cams = {c.name: c for c in cfg.load_cameras()}
        cam = cams.get(camera_name)
        if cam and self.settings.get("popup_on_motion", True):
            self.popup_mgr.trigger_popup(cam)

    def _on_bosch_zone(self, zone_num: int, event_desc: str, linked_camera: str) -> None:
        print(f"[NVR Daemon] Bosch Alarm Zone {zone_num} tripped: {event_desc} -> Camera: {linked_camera}")
        cams = {c.name: c for c in cfg.load_cameras()}
        cam = cams.get(linked_camera)
        if cam:
            # Force instant TV popup on alarm
            self.popup_mgr.trigger_popup(cam, force=True)
            # Trigger high-priority recording clip
            self.recording_mgr.start_recording(cam)


def main() -> int:
    app = QCoreApplication.instance() or QCoreApplication(sys.argv)
    daemon = NvrDaemon()
    daemon.start()

    def _sig_handler(_signum, _frame):
        daemon.stop()
        app.quit()

    signal.signal(signal.SIGINT, _sig_handler)
    signal.signal(signal.SIGTERM, _sig_handler)

    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
