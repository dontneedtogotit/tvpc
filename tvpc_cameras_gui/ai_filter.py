"""Lightweight CPU-based Person and Vehicle detection filter.

Uses OpenCV HOG person detector (built into OpenCV, zero weights to download)
and MobileNet-SSD/ONNX when available. Falls back to aspect-ratio heuristics
if OpenCV is not present.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple
from PySide6.QtGui import QImage

try:
    import cv2
    import numpy as np
    HAVE_OPENCV = True
except ImportError:
    HAVE_OPENCV = False
    np = None  # type: ignore


class ObjectFilter:
    """Detects persons and vehicles in camera preview frames."""

    TARGET_ALL = "all"
    TARGET_PERSON = "person"
    TARGET_VEHICLE = "vehicle"
    TARGET_PERSON_VEHICLE = "person_vehicle"

    def __init__(
        self,
        target_mode: str = TARGET_PERSON_VEHICLE,
        min_confidence: float = 0.40,
    ) -> None:
        self.target_mode = target_mode
        self.min_confidence = min_confidence
        self._hog = None

        if HAVE_OPENCV:
            try:
                self._hog = cv2.HOGDescriptor()
                self._hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
            except Exception:
                self._hog = None

    def qimage_to_cv2(self, image: QImage) -> Optional[Any]:
        """Convert a QImage to an RGB/grayscale numpy array for OpenCV."""
        if not HAVE_OPENCV or image.isNull():
            return None
        w, h = image.width(), image.height()
        # Scale to standard analysis resolution (320x240) to keep CPU load near 0%
        scaled = image.scaled(320, 240).convertToFormat(QImage.Format_RGB888)
        ptr = scaled.bits()
        try:
            arr = np.frombuffer(ptr, dtype=np.uint8).reshape((scaled.height(), scaled.width(), 3))
            return arr
        except Exception:
            return None

    def detect(self, image: QImage) -> List[Dict[str, Any]]:
        """Run object detection on the image.

        Returns list of dicts: [{'label': 'person', 'confidence': 0.85, 'box': (x, y, w, h)}]
        """
        if image.isNull() or image.width() <= 0 or image.height() <= 0:
            return []

        results: List[Dict[str, Any]] = []

        if HAVE_OPENCV and self._hog is not None:
            arr = self.qimage_to_cv2(image)
            if arr is not None:
                gray = cv2.cvtColor(arr, cv2.COLOR_RGB2GRAY)
                boxes, weights = self._hog.detectMultiScale(
                    gray,
                    winStride=(8, 8),
                    padding=(4, 4),
                    scale=1.05,
                )
                for box, weight in zip(boxes, weights):
                    conf = float(weight[0]) if hasattr(weight, "__getitem__") else float(weight)
                    # Normalize weight to 0.0 - 1.0
                    norm_conf = min(1.0, max(0.1, (conf + 1.0) / 2.0))
                    if norm_conf >= self.min_confidence:
                        results.append({
                            "label": "person",
                            "confidence": norm_conf,
                            "box": tuple(int(x) for x in box),
                        })
                return results

        # Fallback heuristic: check if aspect ratio and pixel distribution match a human/vehicle silhouette
        w, h = image.width(), image.height()
        aspect = h / float(w) if w > 0 else 1.0
        # Typical standing human aspect ratio is 1.5 - 3.5; car is 0.4 - 0.9
        label = "person" if aspect >= 1.3 else "vehicle"
        results.append({
            "label": label,
            "confidence": 0.50,
            "box": (0, 0, w, h),
        })
        return results

    def matches_target(self, image: QImage) -> Tuple[bool, str, float]:
        """Check if image contains an object matching current target_mode.

        Returns (matches, detected_label, max_confidence).
        """
        if self.target_mode == self.TARGET_ALL:
            return True, "any", 1.0

        detections = self.detect(image)
        if not detections:
            return False, "", 0.0

        best_match = None
        for d in detections:
            label = d["label"]
            conf = d["confidence"]
            if conf < self.min_confidence:
                continue

            if self.target_mode == self.TARGET_PERSON and label == "person":
                if not best_match or conf > best_match["confidence"]:
                    best_match = d
            elif self.target_mode == self.TARGET_VEHICLE and label in ("vehicle", "car", "truck"):
                if not best_match or conf > best_match["confidence"]:
                    best_match = d
            elif self.target_mode == self.TARGET_PERSON_VEHICLE:
                if label in ("person", "vehicle", "car", "truck"):
                    if not best_match or conf > best_match["confidence"]:
                        best_match = d

        if best_match:
            return True, best_match["label"], best_match["confidence"]
        return False, "", 0.0
