"""Add/Edit camera dialog."""
from __future__ import annotations

from typing import Optional
from urllib.parse import urlparse

from PySide6.QtCore import Qt, QThread, Signal, QObject
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QFormLayout, QLineEdit, QTextEdit,
    QVBoxLayout, QHBoxLayout, QLabel, QCheckBox, QComboBox,
    QPushButton, QMessageBox, QApplication,
)

from .config import Camera
from .settings import load_settings
from .brand_help import show_brand_help
from .v4l2 import is_v4l2, normalize_v4l2_device, query_v4l2_device

_SETTINGS = load_settings()

CAMERA_PRESETS = [
    ("Preset URL templates (select brand)…", ""),
    ("Local USB Webcam / Capture Card (/dev/video0)", "/dev/video0"),
    ("Local USB Webcam (/dev/video1)", "/dev/video1"),
    ("Hikvision / Annke (Main Stream)", "rtsp://{IP}:554/Streaming/Channels/101"),
    ("Hikvision / Annke (Sub Stream)", "rtsp://{IP}:554/Streaming/Channels/102"),
    ("Dahua / Amcrest (Main Stream)", "rtsp://{IP}:554/cam/realmonitor?channel=1&subtype=0"),
    ("Dahua / Amcrest (Sub Stream)", "rtsp://{IP}:554/cam/realmonitor?channel=1&subtype=1"),
    ("Reolink (Main Stream)", "rtsp://{IP}:554/h264Preview_01_main"),
    ("Reolink (Sub Stream)", "rtsp://{IP}:554/h264Preview_01_sub"),
    ("TP-Link Tapo (Main Stream)", "rtsp://{IP}:554/stream1"),
    ("TP-Link Tapo (Sub Stream)", "rtsp://{IP}:554/stream2"),
    ("Axis Communications", "rtsp://{IP}:554/axis-media/media.amp"),
    ("Foscam", "rtsp://{IP}:554/videoMain"),
    ("Generic RTSP (Port 554)", "rtsp://{IP}:554/live"),
    ("Generic RTSP (Port 8554)", "rtsp://{IP}:8554/live"),
    ("Tuya / Orion / Grid Connect (Main Stream)", "rtsp://{IP}:554/live/ch0"),
    ("Tuya / Orion / Grid Connect (Port 6554)", "rtsp://{IP}:6554/stream_0"),
    ("Generic MJPEG HTTP", "http://{IP}:80/video.mjpg"),
]


class _ProbeWorker(QObject):
    finished = Signal(bool)

    def __init__(self, url: str, user: str, password: str, timeout: float = 4.0):
        super().__init__()
        self.url = url
        self.user = user
        self.password = password
        self.timeout = timeout

    def run(self) -> None:
        if is_v4l2(self.url):
            info = query_v4l2_device(normalize_v4l2_device(self.url))
            self.finished.emit(bool(info and info.get("is_capture")))
            return
        from .health import _probe_url
        ok = _probe_url(self.url, user=self.user, password=self.password, timeout=self.timeout)
        self.finished.emit(ok)


class _AutoDetectWorker(QObject):
    finished = Signal(object)

    def __init__(self, target: str, user: str, password: str):
        super().__init__()
        self.target = target
        self.user = user
        self.password = password

    def run(self) -> None:
        from .discover import probe_ip_stream_url
        res = probe_ip_stream_url(self.target, user=self.user, password=self.password)
        self.finished.emit(res)


class CameraEditDialog(QDialog):
    """Form dialog for creating or editing a Camera."""

    def __init__(self, parent=None, camera: Optional[Camera] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Edit camera" if camera else "Add camera")
        self.setMinimumWidth(520)

        self._probe_thread: Optional[QThread] = None
        self._probe_worker: Optional[_ProbeWorker] = None

        self._name = QLineEdit(self)
        self._name.setPlaceholderText("e.g. Front Door")

        self._preset_combo = QComboBox(self)
        for label, _ in CAMERA_PRESETS:
            self._preset_combo.addItem(label)
        self._preset_combo.currentIndexChanged.connect(self._on_preset_selected)

        preset_row = QHBoxLayout()
        preset_row.addWidget(self._preset_combo, 1)
        self._guide_btn = QPushButton("💡 Brand Guide")
        self._guide_btn.setToolTip("Open step-by-step connection guide for your camera brand")
        self._guide_btn.clicked.connect(self._on_brand_guide)
        preset_row.addWidget(self._guide_btn)

        self._url = QLineEdit(self)
        self._url.setPlaceholderText("rtsp://192.168.1.42/Streaming/Channels/101 or /dev/video0")
        self._autodetect_btn = QPushButton("⚡ Auto-Detect")
        self._autodetect_btn.setToolTip("Automatically probe IP address for active RTSP / HTTP video streams")
        self._autodetect_btn.clicked.connect(self._on_autodetect)

        url_row = QHBoxLayout()
        url_row.addWidget(self._url, 1)
        url_row.addWidget(self._autodetect_btn)

        self._user = QLineEdit(self)
        self._user.setPlaceholderText("(optional)")
        if camera is None:
            self._user.setText(_SETTINGS.get("default_user", ""))
        self._pass = QLineEdit(self)
        self._pass.setEchoMode(QLineEdit.Password)
        self._pass.setPlaceholderText("(optional)")
        if camera is None:
            self._pass.setText(_SETTINGS.get("default_password", ""))
        self._show_pass = QCheckBox("Show password", self)
        self._show_pass.toggled.connect(
            lambda on: self._pass.setEchoMode(QLineEdit.Normal if on else QLineEdit.Password)
        )
        self._group = QLineEdit(self)
        self._group.setPlaceholderText("e.g. Backyard, Garage (optional)")
        self._profile = QComboBox(self)
        self._profile.addItems(["main", "sub"])
        self._audio = QCheckBox("Play audio in PiP windows", self)
        self._audio.setChecked(True)
        self._enabled = QCheckBox("Camera enabled", self)
        self._enabled.setChecked(True)
        self._notes = QTextEdit(self)
        self._notes.setFixedHeight(50)
        self._notes.setPlaceholderText("Optional notes")

        self._test_result = QLabel("")
        self._test_result.setStyleSheet("color: #888;")
        self._test_result.setWordWrap(True)
        self._test_btn = QPushButton("🔗 Test connection")
        self._test_btn.clicked.connect(self._test_connection)
        self._test_btn.setEnabled(False)
        self._url.textChanged.connect(lambda: self._test_btn.setEnabled(bool(self._url.text().strip())))

        self._autodetect_thread: Optional[QThread] = None
        self._autodetect_worker: Optional[_AutoDetectWorker] = None

        if camera is not None:
            self._name.setText(camera.name)
            self._url.setText(camera.url)
            self._user.setText(camera.user)
            self._pass.setText(camera.password)
            self._group.setText(camera.group)
            self._profile.setCurrentText(camera.profile if camera.profile in ("main", "sub") else "main")
            self._audio.setChecked(camera.audio)
            self._enabled.setChecked(camera.enabled)
            self._notes.setPlainText(camera.notes)
            self._test_btn.setEnabled(bool(camera.url.strip()))

        form = QFormLayout()
        form.addRow("Name *", self._name)
        form.addRow("Preset", preset_row)
        form.addRow("Stream URL *", url_row)
        form.addRow("Username", self._user)
        form.addRow("Password", self._pass)
        form.addRow("", self._show_pass)
        form.addRow("Group", self._group)
        form.addRow("Profile", self._profile)
        form.addRow("", self._audio)
        form.addRow("", self._enabled)
        form.addRow("Notes", self._notes)

        hint = QLabel(
            "URL examples:\n"
            "  rtsp://192.168.1.42/Streaming/Channels/101\n"
            "  rtsp://user:pass@192.168.1.42/live/main\n"
            "  http://192.168.1.42/video.mjpg\n"
            "  /dev/video0"
        )
        hint.setStyleSheet("color: #888;")

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel, parent=self)
        buttons.button(QDialogButtonBox.Ok).setText("💾 Save")
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(self._test_btn)
        layout.addWidget(self._test_result)
        layout.addWidget(hint)
        layout.addWidget(buttons)

    def _on_preset_selected(self, index: int) -> None:
        if index <= 0 or index >= len(CAMERA_PRESETS):
            return
        _, template = CAMERA_PRESETS[index]
        current_url = self._url.text().strip()
        host = "192.168.1.100"
        if "://" in current_url:
            p = urlparse(current_url)
            if p.hostname:
                host = p.hostname
        self._url.setText(template.replace("{IP}", host))

    def _on_brand_guide(self) -> None:
        host = ""
        current_url = self._url.text().strip()
        if "://" in current_url:
            p = urlparse(current_url)
            if p.hostname:
                host = p.hostname
        hint = ""
        preset_text = self._preset_combo.currentText()
        if self._preset_combo.currentIndex() > 0:
            hint = preset_text.split("(")[0].strip()
        if not hint:
            hint = self._name.text().strip() or self._notes.toPlainText().strip()
        show_brand_help(self, brand_hint=hint, host=host)

    def _on_autodetect(self) -> None:
        target = self._url.text().strip()
        if not target:
            target = self._name.text().strip()
        if not target:
            self._test_result.setText("Enter an IP address or hostname in the URL box to auto-detect.")
            self._test_result.setStyleSheet("color: #f44336;")
            return

        self._autodetect_btn.setEnabled(False)
        self._autodetect_btn.setText("⚡ Scanning…")
        self._test_result.setText(f"⏳ Auto-detecting stream URLs for '{target}'…")
        self._test_result.setStyleSheet("color: #4fc3f7;")

        self._autodetect_thread = QThread(self)
        self._autodetect_worker = _AutoDetectWorker(target, self._user.text().strip(), self._pass.text())
        self._autodetect_worker.moveToThread(self._autodetect_thread)
        self._autodetect_thread.started.connect(self._autodetect_worker.run)
        self._autodetect_worker.finished.connect(self._on_autodetect_finished)
        self._autodetect_worker.finished.connect(self._autodetect_thread.quit)
        self._autodetect_thread.start()

    def _on_autodetect_finished(self, stream_url: Optional[str]) -> None:
        self._autodetect_btn.setEnabled(True)
        self._autodetect_btn.setText("⚡ Auto-Detect")
        if stream_url:
            self._url.setText(stream_url)
            self._test_result.setText(f"✅ Stream auto-detected: {stream_url}")
            self._test_result.setStyleSheet("color: #4caf50; font-weight: bold;")
        else:
            self._test_result.setText("❌ No active stream discovered. Check IP/credentials or choose a preset.")
            self._test_result.setStyleSheet("color: #f44336;")

    def _test_connection(self) -> None:
        url = self._url.text().strip()
        user = self._user.text().strip()
        password = self._pass.text()
        if not url:
            self._test_result.setText("Enter a URL first.")
            self._test_result.setStyleSheet("color: #f44336;")
            return
        self._test_result.setText("⏳ Probing camera connection…")
        self._test_result.setStyleSheet("color: #4fc3f7;")
        self._test_btn.setEnabled(False)

        self._probe_thread = QThread(self)
        self._probe_worker = _ProbeWorker(url, user, password, timeout=4.0)
        self._probe_worker.moveToThread(self._probe_thread)
        self._probe_thread.started.connect(self._probe_worker.run)
        self._probe_worker.finished.connect(self._on_probe_finished)
        self._probe_worker.finished.connect(self._probe_thread.quit)
        self._probe_thread.start()

    def _on_probe_finished(self, ok: bool) -> None:
        self._test_btn.setEnabled(True)
        if ok:
            self._test_result.setText("✅ Connection successful — camera is reachable.")
            self._test_result.setStyleSheet("color: #4caf50; font-weight: bold;")
        else:
            self._test_result.setText("❌ Connection failed — check URL, credentials, and network.")
            self._test_result.setStyleSheet("color: #f44336; font-weight: bold;")

    def _on_accept(self) -> None:
        if not self._name.text().strip() or not self._url.text().strip():
            QMessageBox.warning(self, "Missing fields", "Name and URL are required.")
            return
        url = self._url.text().strip()
        if not (url.startswith("rtsp://") or url.startswith("http://") or url.startswith("https://") or is_v4l2(url)):
            QMessageBox.warning(
                self, "Invalid URL",
                "URL must start with rtsp://, http://, https://, or be a local device (/dev/video0)."
            )
            return
        self.accept()

    def get_camera(self) -> Camera:
        return Camera(
            name=self._name.text().strip(),
            url=self._url.text().strip(),
            user=self._user.text().strip(),
            password=self._pass.text(),
            notes=self._notes.toPlainText().strip(),
            group=self._group.text().strip(),
            profile=self._profile.currentText(),
            audio=self._audio.isChecked(),
            enabled=self._enabled.isChecked(),
        )
