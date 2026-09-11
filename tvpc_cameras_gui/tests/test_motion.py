"""Unit tests for MotionDetector."""
from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from PySide6.QtGui import QColor, QImage
from PySide6.QtWidgets import QApplication

from tvpc_cameras_gui.motion import MotionDetector

# Ensure QApplication exists for QImage manipulation
app = QApplication.instance() or QApplication([])


class TestMotionDetector(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.record_dir = Path(self.temp_dir.name)
        self.detector = MotionDetector(
            sensitivity=0.10,
            cooldown_seconds=2.0,
            auto_snapshot=True,
            record_dir=self.record_dir,
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _create_solid_image(self, color: QColor) -> QImage:
        img = QImage(64, 64, QImage.Format_RGB32)
        img.fill(color)
        return img

    def test_null_image(self) -> None:
        img = QImage()
        self.assertFalse(self.detector.process_frame("Cam1", img))

    def test_first_frame_no_motion(self) -> None:
        img = self._create_solid_image(QColor(0, 0, 0))
        self.assertFalse(self.detector.process_frame("Cam1", img))

    def test_identical_frame_no_motion(self) -> None:
        img1 = self._create_solid_image(QColor(100, 100, 100))
        img2 = self._create_solid_image(QColor(100, 100, 100))
        self.detector.process_frame("Cam1", img1)
        self.assertFalse(self.detector.process_frame("Cam1", img2))

    def test_motion_triggered_and_snapshot_saved(self) -> None:
        black = self._create_solid_image(QColor(0, 0, 0))
        white = self._create_solid_image(QColor(255, 255, 255))

        signal_emitted = []
        self.detector.motion_detected.connect(lambda name, delta: signal_emitted.append((name, delta)))

        self.assertFalse(self.detector.process_frame("Front Door", black))
        triggered = self.detector.process_frame("Front Door", white)

        self.assertTrue(triggered)
        self.assertEqual(len(signal_emitted), 1)
        self.assertEqual(signal_emitted[0][0], "Front Door")
        self.assertGreater(signal_emitted[0][1], 0.5)

        # Check snapshot file saved
        snapshots = list(self.record_dir.glob("motion_Front_Door_*.jpg"))
        self.assertEqual(len(snapshots), 1)

    def test_cooldown_suppresses_rapid_triggers(self) -> None:
        black = self._create_solid_image(QColor(0, 0, 0))
        white = self._create_solid_image(QColor(255, 255, 255))

        self.detector.process_frame("Cam1", black)
        self.assertTrue(self.detector.process_frame("Cam1", white))

        # Immediately toggle back to black during cooldown -> should NOT trigger
        self.assertFalse(self.detector.process_frame("Cam1", black))

    def test_reset_camera(self) -> None:
        black = self._create_solid_image(QColor(0, 0, 0))
        self.detector.process_frame("Cam1", black)
        self.assertIn("Cam1", self.detector._camera_states)
        self.detector.reset_camera("Cam1")
        self.assertNotIn("Cam1", self.detector._camera_states)


if __name__ == "__main__":
    unittest.main()
