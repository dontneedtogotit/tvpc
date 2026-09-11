"""Live preview thumbnails via ffmpeg subprocesses.

A `PreviewWidget` owns a single ffmpeg process that keeps re-encoding a
fresh frame from an RTSP/HTTP stream into a small JPEG file on disk.
A `QTimer` polls the file and reloads it into a `QPixmap` when it changes.
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional

from PySide6.QtCore import Qt, QTimer, Signal, QSize
from PySide6.QtGui import QPixmap, QImage, QPainter, QColor, QFont
from PySide6.QtWidgets import QLabel, QWidget, QVBoxLayout, QSizePolicy

from .settings import load_settings

_SETTINGS = load_settings()


PLACEHOLDER_BG = QColor("#222")
PLACEHOLDER_FG = QColor("#888")
_ERROR_BG = QColor("#3a1010")
_ERROR_FG = QColor("#ff8a8a")
_ONLINE_FG = QColor("#4caf50")
_OFFLINE_FG = QColor("#f44336")


def _have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def build_ffmpeg_cmd(url: str, user: str, password: str, out_path: Path) -> list:
    from .v4l2 import is_v4l2, normalize_v4l2_device
    if is_v4l2(url):
        dev = normalize_v4l2_device(url)
        return [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "v4l2",
            "-i", dev,
            "-an",
            "-vf", "scale=320:-1",
            "-r", "1",
            "-q:v", "5",
            "-y",
            str(out_path),
        ]
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
    prefix = "rtsp://"
    rest = url[len(prefix):]
    if "@" in rest.split("/", 1)[0]:
        return url  # already has creds
    return f"{prefix}{user}:{password}@{rest}"


_LOADING_BG = QColor("#1a1a2e")
_LOADING_FG = QColor("#4fc3f7")
_RECONNECT_ATTEMPTS = 3
_RECONNECT_DELAY = 2.0


class PreviewWidget(QWidget):
    """A bordered label showing the latest frame from a stream.

    Emits `clicked` on mouse click, `double_clicked` on double click,
    `context_menu_requested` on right click, and `frame_ready` on each new frame.
    """
    clicked = Signal()
    double_clicked = Signal()
    context_menu_requested = Signal(object)
    frame_ready = Signal(str, object)  # (caption_base_text, QImage)

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._pixmap: Optional[QPixmap] = None
        self._online: Optional[bool] = None
        self._recording: bool = False
        self._motion_active: bool = False
        self._caption_base_text: str = ""
        self._label = QLabel("no signal", self)
        self._label.setAlignment(Qt.AlignCenter)
        self._label.setStyleSheet(
            f"background-color: {PLACEHOLDER_BG.name()};"
            f"color: {PLACEHOLDER_FG.name()};"
            "border: 1px solid #444; border-radius: 4px;"
        )
        self._label.setMinimumSize(QSize(320, 180))
        self._label.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self._label.setScaledContents(True)
        self._caption = QLabel("", self)
        self._caption.setStyleSheet("color: #ddd;")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(4)
        layout.addWidget(self._label, 1)
        layout.addWidget(self._caption)
        self.setMinimumWidth(320)
        self.setMinimumHeight(210)
        self._proc: Optional[subprocess.Popen] = None
        self._tmpdir: Optional[tempfile.TemporaryDirectory] = None
        self._jpeg_path: Optional[Path] = None
        self._current_url: str = ""
        self._current_user: str = ""
        self._current_password: str = ""
        self._reconnect_count: int = 0
        self._reconnect_timer = QTimer(self)
        self._reconnect_timer.setSingleShot(True)
        self._reconnect_timer.timeout.connect(self._on_reconnect)
        self._motion_timer = QTimer(self)
        self._motion_timer.setSingleShot(True)
        self._motion_timer.timeout.connect(lambda: self.set_motion(False))
        self._timer = QTimer(self)
        poll_ms = max(200, int(_SETTINGS.get("preview_poll_ms", 1500)))
        self._timer.setInterval(poll_ms)
        self._timer.timeout.connect(self._poll_frame)

        self._label.mousePressEvent = self._on_label_press  # type: ignore[assignment]
        self._label.mouseDoubleClickEvent = self._on_label_double_click  # type: ignore[assignment]

    def _on_label_press(self, event) -> None:
        if event.button() == Qt.LeftButton:
            self.clicked.emit()
        elif event.button() == Qt.RightButton:
            pos = event.globalPosition().toPoint() if hasattr(event, "globalPosition") else event.globalPos()
            self.context_menu_requested.emit(pos)

    def _on_label_double_click(self, event) -> None:
        if event.button() == Qt.LeftButton:
            self.double_clicked.emit()

    # --- public API ---------------------------------------------------------
    def start(self, url: str, user: str, password: str, caption: str = "") -> None:
        self.stop()
        self._current_url = url
        self._current_user = user
        self._current_password = password
        self._caption_base_text = caption or url
        self._caption.setText(self._caption_base_text)
        self._online = None
        self._reconnect_count = 0
        if not _have_ffmpeg():
            self._show_error("ffmpeg not installed")
            return
        if not url:
            self._show_placeholder()
            return
        self._show_loading()
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
        self._reconnect_timer.stop()
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
        self._online = None
        self._show_placeholder()

    def _on_reconnect(self) -> None:
        if self._reconnect_count < _RECONNECT_ATTEMPTS and self._current_url:
            self._reconnect_count += 1
            self._show_loading()
            try:
                self._tmpdir = tempfile.TemporaryDirectory(prefix="tvpc-thumb-")
                self._jpeg_path = Path(self._tmpdir.name) / "frame.jpg"
                cmd = build_ffmpeg_cmd(
                    self._current_url, self._current_user, self._current_password,
                    self._jpeg_path,
                )
                self._proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    stdin=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:  # noqa: BLE001
                self._show_error("reconnect failed")
                return
            self._timer.start()
            self._poll_frame()

    def set_recording(self, recording: bool) -> None:
        """Update whether this camera is actively recording."""
        self._recording = recording
        self._update_caption_style()

    def set_motion(self, active: bool = True) -> None:
        """Update whether motion is actively detected on this camera."""
        self._motion_active = active
        if active:
            self._motion_timer.start(4000)
            self._label.setStyleSheet(
                "border: 2px solid #ff9800; border-radius: 4px; background-color: #222;"
            )
        else:
            self._label.setStyleSheet(
                f"background-color: {PLACEHOLDER_BG.name()};"
                f"color: {PLACEHOLDER_FG.name()};"
                "border: 1px solid #444; border-radius: 4px;"
            )
        self._update_caption_style()
        if self._pixmap and not self._pixmap.isNull():
            if active:
                self._draw_motion_overlay_and_set()
            else:
                self._label.setPixmap(self._pixmap)

    def _draw_motion_overlay_and_set(self) -> None:
        if self._pixmap is None or self._pixmap.isNull():
            return
        overlay_pix = QPixmap(self._pixmap)
        painter = QPainter(overlay_pix)
        painter.setRenderHint(QPainter.Antialiasing)

        # Draw motion badge in top-right corner
        badge_w, badge_h = 96, 24
        x = overlay_pix.width() - badge_w - 8
        y = 8
        painter.setBrush(QColor(230, 81, 0, 220))
        painter.setPen(Qt.NoPen)
        painter.drawRoundedRect(x, y, badge_w, badge_h, 4, 4)

        painter.setPen(QColor("white"))
        font = painter.font()
        font.setPointSize(9)
        font.setBold(True)
        painter.setFont(font)
        painter.drawText(x, y, badge_w, badge_h, Qt.AlignCenter, "🚨 MOTION")
        painter.end()
        self._label.setPixmap(overlay_pix)

    def set_online_status(self, online: bool) -> None:
        """Update the online/offline indicator dot."""
        self._online = online
        self._update_caption_style()

    def snapshot(self, output_path: Optional[Path] = None) -> Optional[Path]:
        """Save the current frame to disk. Returns the path saved, or None."""
        if self._pixmap is None or self._pixmap.isNull():
            return None
        if output_path is None:
            from .config import RECORD_DIR
            ts = time.strftime("%Y%m%d_%H%M%S")
            output_path = RECORD_DIR / f"snapshot_{ts}.jpg"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        self._pixmap.save(str(output_path), "JPG")
        return output_path

    def is_active(self) -> bool:
        return self._proc is not None

    # --- internals ----------------------------------------------------------
    def _show_placeholder(self) -> None:
        pix = QPixmap(self._label.size())
        pix.fill(PLACEHOLDER_BG)
        self._render_text(pix, "no signal", PLACEHOLDER_FG)
        self._label.setPixmap(pix)

    def _show_loading(self) -> None:
        pix = QPixmap(self._label.size())
        pix.fill(_LOADING_BG)
        self._render_text(pix, "Connecting…", _LOADING_FG, "waiting for stream")
        self._label.setPixmap(pix)

    def _show_error(self, msg: str) -> None:
        pix = QPixmap(self._label.size())
        pix.fill(_ERROR_BG)
        self._render_text(pix, "Stream error", _ERROR_FG, msg[:60])
        self._label.setPixmap(pix)

    def _render_text(self, pix: QPixmap, text: str, color: QColor, sub: str = "") -> None:
        if pix.isNull():
            return
        painter = QPainter(pix)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setPen(color)
        font: QFont = painter.font()
        font.setPointSize(12)
        painter.setFont(font)
        rect = pix.rect()
        painter.drawText(rect, Qt.AlignCenter, text)
        if sub:
            font.setPointSize(9)
            painter.setFont(font)
            sub_rect = rect.adjusted(0, rect.height() // 2, 0, 0)
            painter.drawText(sub_rect, Qt.AlignHCenter | Qt.AlignTop, sub)
        painter.end()

    def _update_caption_style(self) -> None:
        tags = []
        if self._motion_active:
            tags.append("🚨 MOTION")
        if self._recording:
            tags.append("🔴 REC")
        tag_str = ("  " + " ".join(tags)) if tags else ""
        self._caption.setText(f"{self._caption_base_text}{tag_str}")
        if self._recording or self._motion_active:
            self._caption.setStyleSheet("color: #ff9800; font-weight: bold;" if self._motion_active else "color: #ff5252; font-weight: bold;")
        elif self._online is True:
            color = _ONLINE_FG.name()
            self._caption.setStyleSheet(f"color: {color}; font-weight: 500;")
        elif self._online is False:
            color = _OFFLINE_FG.name()
            self._caption.setStyleSheet(f"color: {color};")
        else:
            self._caption.setStyleSheet("color: #ddd;")

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
        self.frame_ready.emit(self._caption_base_text, img)
        self._pixmap = QPixmap.fromImage(img)
        if self._motion_active:
            self._draw_motion_overlay_and_set()
        else:
            self._label.setPixmap(self._pixmap)
        # If the ffmpeg process died, surface that and attempt reconnect.
        if self._proc is not None and self._proc.poll() is not None:
            err = b""
            try:
                err = self._proc.stderr.read(200) if self._proc.stderr else b""
            except Exception:  # noqa: BLE001
                pass
            msg = err.decode("utf-8", "replace").strip().splitlines()[-1] if err else "stream ended"
            self._proc = None
            self._show_error(msg or "stream ended")
            if self._reconnect_count < _RECONNECT_ATTEMPTS:
                self._reconnect_timer.start(int(_RECONNECT_DELAY * 1000))

    def closeEvent(self, event) -> None:  # noqa: N802
        self.stop()
        super().closeEvent(event)
