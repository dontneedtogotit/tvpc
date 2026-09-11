"""Pan-Tilt-Zoom (PTZ) controller and dialog for security cameras."""
from __future__ import annotations

import base64
import hashlib
import os
import threading
import time
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urlparse
import urllib.request
import urllib.error

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QFont, QIcon
from PySide6.QtWidgets import (
    QDialog, QGridLayout, QHBoxLayout, QLabel, QPushButton,
    QSlider, QVBoxLayout, QWidget, QGroupBox, QMessageBox,
)

from .config import Camera


def _create_wsse_header(user: str, password: str) -> str:
    """Generate ONVIF WS-Security UsernameToken header with PasswordDigest."""
    if not user:
        return ""
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    nonce_bytes = os.urandom(16)
    nonce_b64 = base64.b64encode(nonce_bytes).decode("ascii")

    sha = hashlib.sha1()
    sha.update(nonce_bytes)
    sha.update(created.encode("utf-8"))
    sha.update(password.encode("utf-8"))
    digest_b64 = base64.b64encode(sha.digest()).decode("ascii")

    return f"""<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
                   xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <wsse:UsernameToken>
            <wsse:Username>{user}</wsse:Username>
            <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest_b64}</wsse:Password>
            <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{nonce_b64}</wsse:Nonce>
            <wsu:Created>{created}</wsu:Created>
        </wsse:UsernameToken>
    </wsse:Security>"""


class PtzClient:
    """Sends PTZ commands to a camera using ONVIF SOAP or HTTP vendor APIs."""

    def __init__(self, camera: Camera) -> None:
        self.camera = camera
        self.host = ""
        self.port = 80
        if "://" in camera.url:
            parsed = urlparse(camera.url)
            self.host = parsed.hostname or ""
            self.port = parsed.port or 554
            if self.port in (554, 8554, 10554, 6554):
                self.port = 80

    def send_move(self, pan: float = 0.0, tilt: float = 0.0, zoom: float = 0.0) -> None:
        """Send a continuous or step move command in a background thread."""
        t = threading.Thread(target=self._do_move, args=(pan, tilt, zoom), daemon=True)
        t.start()

    def send_stop(self) -> None:
        """Send a stop command in a background thread."""
        t = threading.Thread(target=self._do_stop, daemon=True)
        t.start()

    def _do_move(self, pan: float, tilt: float, zoom: float) -> None:
        if not self.host:
            return

        ports_to_try = [self.port] if self.port not in (554, 8554) else []
        for p in (80, 8080, 5000, 8000, 8899):
            if p not in ports_to_try:
                ports_to_try.append(p)

        security_header = _create_wsse_header(self.camera.user, self.camera.password)
        soap_body = f"""<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
               xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"
               xmlns:tt="http://www.onvif.org/ver10/schema">
    <soap:Header>
        {security_header}
    </soap:Header>
    <soap:Body>
        <tptz:ContinuousMove>
            <tptz:ProfileToken>Profile_1</tptz:ProfileToken>
            <tptz:Velocity>
                <tt:PanTilt x="{pan:.2f}" y="{tilt:.2f}"/>
                <tt:Zoom x="{zoom:.2f}"/>
            </tptz:Velocity>
        </tptz:ContinuousMove>
    </soap:Body>
</soap:Envelope>"""

        for port in ports_to_try:
            url = f"http://{self.host}:{port}/onvif/ptz_service"
            req = urllib.request.Request(
                url,
                data=soap_body.encode("utf-8"),
                headers={
                    "Content-Type": "application/soap+xml; charset=utf-8; action=\"http://www.onvif.org/ver20/ptz/wsdl/ContinuousMove\"",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=1.5):
                    return
            except Exception:
                pass

        dahua_code = ""
        if tilt > 0: dahua_code = "Up"
        elif tilt < 0: dahua_code = "Down"
        elif pan > 0: dahua_code = "Right"
        elif pan < 0: dahua_code = "Left"
        elif zoom > 0: dahua_code = "ZoomIn"
        elif zoom < 0: dahua_code = "ZoomOut"

        if dahua_code:
            for port in (80, 8080):
                dahua_url = f"http://{self.host}:{port}/cgi-bin/ptz.cgi?action=start&channel=0&code={dahua_code}&arg1=0&arg2=4&arg3=0"
                req = urllib.request.Request(dahua_url)
                if self.camera.user and self.camera.password:
                    auth = base64.b64encode(f"{self.camera.user}:{self.camera.password}".encode()).decode()
                    req.add_header("Authorization", f"Basic {auth}")
                try:
                    with urllib.request.urlopen(req, timeout=1.0):
                        return
                except Exception:
                    pass

    def _do_stop(self) -> None:
        if not self.host:
            return

        security_header = _create_wsse_header(self.camera.user, self.camera.password)
        soap_body = f"""<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
               xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
    <soap:Header>
        {security_header}
    </soap:Header>
    <soap:Body>
        <tptz:Stop>
            <tptz:ProfileToken>Profile_1</tptz:ProfileToken>
            <tptz:PanTilt>true</tptz:PanTilt>
            <tptz:Zoom>true</tptz:Zoom>
        </tptz:Stop>
    </soap:Body>
</soap:Envelope>"""

        for port in (self.port, 80, 8080, 5000, 8000):
            url = f"http://{self.host}:{port}/onvif/ptz_service"
            req = urllib.request.Request(
                url,
                data=soap_body.encode("utf-8"),
                headers={
                    "Content-Type": "application/soap+xml; charset=utf-8; action=\"http://www.onvif.org/ver20/ptz/wsdl/Stop\"",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=1.0):
                    return
            except Exception:
                pass

        for port in (80, 8080):
            dahua_url = f"http://{self.host}:{port}/cgi-bin/ptz.cgi?action=stop&channel=0&code=Up"
            req = urllib.request.Request(dahua_url)
            if self.camera.user and self.camera.password:
                auth = base64.b64encode(f"{self.camera.user}:{self.camera.password}".encode()).decode()
                req.add_header("Authorization", f"Basic {auth}")
            try:
                with urllib.request.urlopen(req, timeout=1.0):
                    return
            except Exception:
                pass


class PtzDialog(QDialog):
    """Interactive PTZ D-pad controller dialog."""

    def __init__(self, parent=None, camera: Optional[Camera] = None) -> None:
        super().__init__(parent)
        self.camera = camera
        self.client = PtzClient(camera) if camera else None

        title = f"PTZ Controls — {camera.name}" if camera else "PTZ Controls"
        self.setWindowTitle(title)
        self.setFixedSize(360, 420)

        layout = QVBoxLayout(self)

        info = QLabel(f"Camera: <b>{camera.name if camera else 'None'}</b>")
        info.setAlignment(Qt.AlignCenter)
        layout.addWidget(info)

        # D-Pad Group
        dpad_group = QGroupBox("Directional Controls")
        dpad_layout = QGridLayout(dpad_group)

        self._btn_up = self._create_dir_btn("▲\nUp", pan=0.0, tilt=1.0)
        self._btn_down = self._create_dir_btn("▼\nDown", pan=0.0, tilt=-1.0)
        self._btn_left = self._create_dir_btn("◀ Left", pan=-1.0, tilt=0.0)
        self._btn_right = self._create_dir_btn("Right ▶", pan=1.0, tilt=0.0)
        self._btn_stop = QPushButton("⏹\nSTOP")
        self._btn_stop.setFixedSize(80, 60)
        self._btn_stop.setStyleSheet("background: #c62828; color: white; font-weight: bold; border-radius: 6px;")
        self._btn_stop.clicked.connect(self._on_stop)

        dpad_layout.addWidget(self._btn_up, 0, 1)
        dpad_layout.addWidget(self._btn_left, 1, 0)
        dpad_layout.addWidget(self._btn_stop, 1, 1)
        dpad_layout.addWidget(self._btn_right, 1, 2)
        dpad_layout.addWidget(self._btn_down, 2, 1)
        layout.addWidget(dpad_group)

        # Zoom controls
        zoom_group = QGroupBox("Zoom")
        zoom_layout = QHBoxLayout(zoom_group)
        self._btn_zoom_in = QPushButton("🔍➕ Zoom In")
        self._btn_zoom_in.setStyleSheet("padding: 8px; font-weight: bold;")
        self._btn_zoom_in.pressed.connect(lambda: self._on_move(0.0, 0.0, 1.0))
        self._btn_zoom_in.released.connect(self._on_stop)

        self._btn_zoom_out = QPushButton("🔍➖ Zoom Out")
        self._btn_zoom_out.setStyleSheet("padding: 8px; font-weight: bold;")
        self._btn_zoom_out.pressed.connect(lambda: self._on_move(0.0, 0.0, -1.0))
        self._btn_zoom_out.released.connect(self._on_stop)

        zoom_layout.addWidget(self._btn_zoom_in)
        zoom_layout.addWidget(self._btn_zoom_out)
        layout.addWidget(zoom_group)

        # Speed slider
        speed_row = QHBoxLayout()
        speed_row.addWidget(QLabel("Speed:"))
        self._speed_slider = QSlider(Qt.Horizontal)
        self._speed_slider.setRange(1, 5)
        self._speed_slider.setValue(3)
        speed_row.addWidget(self._speed_slider)
        layout.addLayout(speed_row)

        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.accept)
        layout.addWidget(close_btn)

    def _create_dir_btn(self, label: str, pan: float, tilt: float) -> QPushButton:
        btn = QPushButton(label)
        btn.setFixedSize(80, 60)
        btn.setStyleSheet("font-size: 13px; font-weight: bold; padding: 6px; border-radius: 6px;")
        btn.pressed.connect(lambda: self._on_move(pan, tilt, 0.0))
        btn.released.connect(self._on_stop)
        return btn

    def _on_move(self, pan: float, tilt: float, zoom: float) -> None:
        if not self.client:
            return
        speed_factor = self._speed_slider.value() / 5.0
        self.client.send_move(pan * speed_factor, tilt * speed_factor, zoom * speed_factor)

    def _on_stop(self) -> None:
        if self.client:
            self.client.send_stop()
