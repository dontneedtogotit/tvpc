"""Live preview thumbnails via ffmpeg subprocesses.

A `PreviewWidget` owns a single ffmpeg process that keeps re-encoding a
fresh frame from an RTSP/HTTP stream into a small JPEG file on disk.
A `QTimer` polls the file and reloads it into a `QPixmap` when it changes.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional

from PySide6.QtCore import Qt, QTimer, Signal, QSize
from PySide6.QtGui import QPixmap, QImage, QPainter, QColor, QFont
from PySide6.QtWidgets import QLabel, QWidget, QVBoxLayout, QSizePolicy


PLACEHOLDER_BG = QColor("#222")
PLACEHOLDER_FG = QColor("#888")
_ERROR_BG = QColor("#3a1010")
_ERROR_FG = QColor("#ff8a8a")


def _have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def build_ffmpeg_cmd(url: str, user: str, password: str, out_path: Path) -> list:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-rtsp_transport", "tcp",
        "-stimeout", "3000000",  # 3s connect timeout (microseconds)
        "-i", _inject_credentials(url, user, password),
        "-an",
        "-vf", "scale=320:-1",
        "-r", "1",
        "-q:v", "5",
        "-y",
        str(out_path),
    ]
    return cmd


def _inject_credentials(url: str, user: str, password: str) -> str:
    """For rtsp://, embed user:pass in the URL itself; otherwise pass through."""
    if not user or not url.startswith("rtsp://"):
        return url
    # rtsp://host/path  ->  rtsp://user:pass@host/path
    prefix = "rtsp://"
    rest = url[len(prefix):]
    if "@" in rest.split("/", 1)[0]:
        return url  # already has creds
    return f"{prefix}{user}:{password}@{rest}"


class PreviewWidget(QWidget):
    """A bordered label showing the latest frame from a stream.

    Emits `clicked` on mouse press so the main window can wire selection.
    """
    clicked = Signal()

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._pixmap: Optional[QPixmap] = None
        self._label = QLabel("no signal", self)
        self._label.setAlignment(Qt.AlignCenter)
        self._label.setStyleSheet(
            f"background-color: {PLACEHOLDER_BG.name()};"
            f"color: {PLACEHOLDER_FG.name()};"
            "border: 1px solid #444;"
        )
        self._label.setMinimumSize(QSize(320, 180))
        self._label.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self._label.setScaledContents(True)
        self._caption = QLabel("", self)
        self._caption.setStyleSheet("color: #ddd;")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)
        layout.addWidget(self._label, 1)
        layout.addWidget(self._caption)
        self.setMinimumWidth(320)
        self.setMinimumHeight(210)
        self._proc: Optional[subprocess.Popen] = None
        self._tmpdir: Optional[tempfile.TemporaryDirectory] = None
        self._jpeg_path: Optional[Path] = None
        self._current_url: str = ""
        self._timer = QTimer(self)
        self._timer.setInterval(1500)
        self._timer.timeout.connect(self._poll_frame)
        self._label.mousePressEvent = self._on_press  # type: ignore[assignment]

    def _on_press(self, _event) -> None:
        self.clicked.emit()

    # --- public API ---------------------------------------------------------
    def start(self, url: str, user: str, password: str, caption: str = "") -> None:
        self.stop()
        self._current_url = url
        self._caption.setText(caption or url)
        if not _have_ffmpeg():
            self._show_error("ffmpeg not installed")
            return
        if not url:
            self._show_placeholder()
            return
        try:
            self._tmpdir = tempfile.TemporaryDirectory(prefix="tvpc-thumb-")
            self._jpeg_path = Path(self._tmpdir.name) / "frame.jpg"
            cmd = build_ffmpeg_cmd(url, user, password, self._jpeg_path)
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception as exc:  # noqa: BLE001
            self._show_error(f"failed to start ffmpeg: {exc}")
            return
        self._timer.start()
        self._poll_frame()

    def stop(self) -> None:
        self._timer.stop()
        if self._proc is not None:
            try:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=1.5)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
            except Exception:  # noqa: BLE001
                pass
            self._proc = None
        if self._tmpdir is not None:
            try:
                self._tmpdir.cleanup()
            except Exception:  # noqa: BLE001
                pass
            self._tmpdir = None
            self._jpeg_path = None
        self._pixmap = None
        self._show_placeholder()

    def is_active(self) -> bool:
        return self._proc is not None

    # --- internals ----------------------------------------------------------
    def _show_placeholder(self) -> None:
        pix = QPixmap(self._label.size())
        pix.fill(PLACEHOLDER_BG)
        self._render_text(pix, "no signal", PLACEHOLDER_FG)
        self._label.setPixmap(pix)

    def _show_error(self, msg: str) -> None:
        pix = QPixmap(self._label.size())
        pix.fill(_ERROR_BG)
        self._render_text(pix, msg, _ERROR_FG)
        self._label.setPixmap(pix)

    def _render_text(self, pix: QPixmap, text: str, color: QColor) -> None:
        if pix.isNull():
            return
        painter = QPainter(pix)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setPen(color)
        font: QFont = painter.font()
        font.setPointSize(12)
        painter.setFont(font)
        painter.drawText(pix.rect(), Qt.AlignCenter, text)
        painter.end()

    def _poll_frame(self) -> None:
        if self._jpeg_path is None or not self._jpeg_path.exists():
            return
        try:
            mtime = self._jpeg_path.stat().st_mtime
        except FileNotFoundError:
            return
        if self._pixmap is not None and getattr(self, "_last_mtime", None) == mtime:
            return
        self._last_mtime = mtime
        img = QImage(str(self._jpeg_path))
        if img.isNull():
            return
        self._pixmap = QPixmap.fromImage(img)
        self._label.setPixmap(self._pixmap)
        # If the ffmpeg process died, surface that.
        if self._proc is not None and self._proc.poll() is not None:
            err = b""
            try:
                err = self._proc.stderr.read(200) if self._proc.stderr else b""
            except Exception:  # noqa: BLE001
                pass
            msg = err.decode("utf-8", "replace").strip().splitlines()[-1] if err else "stream ended"
            self._proc = None
            self._show_error(msg or "stream ended")

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop()
        super().closeEvent(event)
