"""Unit tests for ObjectFilter (person & vehicle detection)."""
from __future__ import annotations

import unittest
from PySide6.QtGui import QColor, QImage
from PySide6.QtWidgets import QApplication

from tvpc_cameras_gui.ai_filter import ObjectFilter

app = QApplication.instance() or QApplication([])


class TestObjectFilter(unittest.TestCase):
    def setUp(self) -> None:
        self.filt = ObjectFilter(target_mode=ObjectFilter.TARGET_PERSON_VEHICLE, min_confidence=0.30)

    def test_null_image(self) -> None:
        img = QImage()
        detections = self.filt.detect(img)
        self.assertEqual(detections, [])
        match, _, _ = self.filt.matches_target(img)
        self.assertFalse(match)

    def test_matches_target_all(self) -> None:
        f = ObjectFilter(target_mode=ObjectFilter.TARGET_ALL)
        img = QImage(100, 100, QImage.Format_RGB32)
        img.fill(QColor(128, 128, 128))
        match, label, conf = f.matches_target(img)
        self.assertTrue(match)
        self.assertEqual(label, "any")
        self.assertEqual(conf, 1.0)

    def test_fallback_heuristic_detection(self) -> None:
        # Tall image -> aspect ratio >= 1.3 should label as person
        tall_img = QImage(100, 200, QImage.Format_RGB32)
        tall_img.fill(QColor(200, 200, 200))
        res_tall = self.filt.detect(tall_img)
        self.assertTrue(len(res_tall) > 0)
        self.assertEqual(res_tall[0]["label"], "person")

        # Wide image -> aspect ratio < 1.3 should label as vehicle
        wide_img = QImage(200, 100, QImage.Format_RGB32)
        wide_img.fill(QColor(200, 200, 200))
        res_wide = self.filt.detect(wide_img)
        self.assertTrue(len(res_wide) > 0)
        self.assertEqual(res_wide[0]["label"], "vehicle")

    def test_target_mode_filtering(self) -> None:
        tall_img = QImage(100, 200, QImage.Format_RGB32)
        tall_img.fill(QColor(200, 200, 200))

        # Person filter accepts tall image
        f_person = ObjectFilter(target_mode=ObjectFilter.TARGET_PERSON, min_confidence=0.30)
        matched, label, _ = f_person.matches_target(tall_img)
        self.assertTrue(matched)
        self.assertEqual(label, "person")

        # Vehicle filter rejects tall image
        f_vehicle = ObjectFilter(target_mode=ObjectFilter.TARGET_VEHICLE, min_confidence=0.30)
        matched, _, _ = f_vehicle.matches_target(tall_img)
        self.assertFalse(matched)


if __name__ == "__main__":
    unittest.main()
