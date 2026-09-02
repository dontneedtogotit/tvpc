"""Add/Edit camera dialog."""
from __future__ import annotations

from typing import Optional

from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QFormLayout, QLineEdit, QTextEdit,
    QVBoxLayout, QLabel, QCheckBox,
)

from .config import Camera


class CameraEditDialog(QDialog):
    """Form dialog for creating or editing a Camera."""

    def __init__(self, parent=None, camera: Optional[Camera] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Edit camera" if camera else "Add camera")
        self.setMinimumWidth(420)

        self._name = QLineEdit(self)
        self._url = QLineEdit(self)
        self._user = QLineEdit(self)
        self._pass = QLineEdit(self)
        self._pass.setEchoMode(QLineEdit.Password)
        self._show_pass = QCheckBox("Show password", self)
        self._show_pass.toggled.connect(
            lambda on: self._pass.setEchoMode(QLineEdit.Normal if on else QLineEdit.Password)
        )
        self._notes = QTextEdit(self)
        self._notes.setFixedHeight(70)
        self._notes.setPlaceholderText("Optional notes (location, model, etc.)")

        if camera is not None:
            self._name.setText(camera.name)
            self._url.setText(camera.url)
            self._user.setText(camera.user)
            self._pass.setText(camera.password)
            self._notes.setPlainText(camera.notes)

        form = QFormLayout()
        form.addRow("Name *", self._name)
        form.addRow("Stream URL *", self._url)
        form.addRow("Username", self._user)
        form.addRow("Password", self._pass)
        form.addRow("", self._show_pass)
        form.addRow("Notes", self._notes)

        hint = QLabel(
            "URL examples:\n"
            "  rtsp://192.168.1.42/Streaming/Channels/101\n"
            "  rtsp://user:pass@192.168.1.42/live/main\n"
            "  http://192.168.1.42/video.mjpg"
        )
        hint.setStyleSheet("color: #888;")

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel, parent=self)
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(hint)
        layout.addWidget(buttons)

    def _on_accept(self) -> None:
        if not self._name.text().strip() or not self._url.text().strip():
            from PySide6.QtWidgets import QMessageBox
            QMessageBox.warning(self, "Missing fields", "Name and URL are required.")
            return
        self.accept()

    def get_camera(self) -> Camera:
        return Camera(
            name=self._name.text().strip(),
            url=self._url.text().strip(),
            user=self._user.text().strip(),
            password=self._pass.text(),
            notes=self._notes.toPlainText().strip(),
        )
