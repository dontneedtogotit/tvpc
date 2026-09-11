"""Lightweight visual motion detector for live camera previews."""
from __future__ import annotations

import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional, Tuple

from PySide6.QtCore import QObject, Signal
from PySide6.QtGui import QImage

from .config import RECORD_DIR


class MotionDetector(QObject):
    """Detects frame differences between consecutive camera preview frames."""

    motion_detected = Signal(str, float)  # (camera_name, delta_score)

    def __init__(
        self,
        sensitivity: float = 0.12,  # 0.05 to 0.30 (lower = more sensitive)
        cooldown_seconds: float = 5.0,
        auto_snapshot: bool = True,
        record_dir: Optional[Path] = None,
    ) -> None:
        super().__init__()
        self.sensitivity = sensitivity
        self.cooldown_seconds = cooldown_seconds
        self.auto_snapshot = auto_snapshot
        self.record_dir = record_dir or RECORD_DIR

        # camera_name -> (last_sample_grid, last_trigger_time)
        self._camera_states: Dict[str, Tuple[list[int], float]] = {}

    def reset_camera(self, camera_name: str) -> None:
        self._camera_states.pop(camera_name, None)

    def clear(self) -> None:
        self._camera_states.clear()

    def process_frame(self, camera_name: str, image: QImage) -> bool:
        """Process a new preview frame for a camera.

        Returns True if motion was triggered on this frame.
        """
        if image.isNull() or image.width() <= 0 or image.height() <= 0:
            return False

        # Downsample to a 32x18 grayscale thumbnail for rapid comparison
        thumb = image.scaled(32, 18).convertToFormat(QImage.Format_Grayscale8)
        w = thumb.width()
        h = thumb.height()
        total_pixels = w * h
        if total_pixels <= 0:
            return False

        # Extract raw grayscale luminance values
        bits = thumb.bits()
        try:
            raw_bytes = bytes(bits)[:total_pixels]
            grid = list(raw_bytes)
        except Exception:
            return False

        now = time.time()
        prev_state = self._camera_states.get(camera_name)

        if prev_state is None:
            self._camera_states[camera_name] = (grid, 0.0)
            return False

        prev_grid, last_trigger = prev_state
        if len(prev_grid) != len(grid):
            self._camera_states[camera_name] = (grid, last_trigger)
            return False

        # Compute mean absolute difference normalized to 0.0 - 1.0
        diff_sum = sum(abs(g - p) for g, p in zip(grid, prev_grid))
        delta = diff_sum / (total_pixels * 255.0)

        # Update reference frame
        self._camera_states[camera_name] = (grid, last_trigger)

        # Check threshold and cooldown
        if delta >= self.sensitivity and (now - last_trigger) >= self.cooldown_seconds:
            self._camera_states[camera_name] = (grid, now)

            if self.auto_snapshot:
                self._save_motion_snapshot(camera_name, image)

            self.motion_detected.emit(camera_name, delta)
            return True

        return False

    def _save_motion_snapshot(self, camera_name: str, image: QImage) -> Optional[Path]:
        """Save the motion frame to disk as a timestamped JPEG."""
        try:
            self.record_dir.mkdir(parents=True, exist_ok=True)
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            safe_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in camera_name)
            out_file = self.record_dir / f"motion_{safe_name}_{ts}.jpg"
            image.save(str(out_file), "JPEG", 85)
            return out_file
        except Exception:
            return None
