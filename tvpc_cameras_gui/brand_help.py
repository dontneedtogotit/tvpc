"""Brand & Model Setup Guide and Knowledge Base for IP Cameras.

Provides step-by-step instructions for enabling RTSP/ONVIF in vendor apps,
default credentials, RTSP stream URL templates, and troubleshooting quirks.
"""
from __future__ import annotations

import re
from typing import Dict, List, Optional

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication, QComboBox, QDialog, QDialogButtonBox, QGroupBox,
    QHBoxLayout, QLabel, QLineEdit, QMessageBox, QPushButton,
    QScrollArea, QTextBrowser, QVBoxLayout, QWidget,
)


# ---------------------------------------------------------------------------
# Brand Guides Catalog
# ---------------------------------------------------------------------------
BRAND_GUIDES: Dict[str, dict] = {
    "Tuya / Orion / Grid Connect": {
        "aliases": ["tuya", "orion", "grid connect", "smart life", "b-link", "bilian"],
        "summary": "Australian & international smart cameras (Orion, Mirabella Genio, Mercator, Arlec, Smart Life, Tuya). By default, cameras only stream to the cloud. Local RTSP/ONVIF must be toggled on in the mobile app.",
        "steps": [
            "Open the <b>Grid Connect</b>, <b>Tuya</b>, or <b>Smart Life</b> app on your phone.",
            "Select the camera and tap the <b>'...'</b> or <b>pencil/gear</b> icon in the top-right corner to open Settings.",
            "Scroll down to find <b>'PC View'</b>, <b>'ONVIF'</b>, or <b>'Local Streaming'</b> (often under <i>Advanced Settings</i> or <i>Device Information</i>).",
            "Toggle <b>ONVIF / PC View</b> to <b>ON</b>.",
            "Set a <b>local password</b> (minimum 6 characters). Note: the default username is usually <code>admin</code>.",
            "Return to <b>tvpc-cameras-gui</b> and click <b>Start scan</b> — the camera will now be detected with its live RTSP stream URL.",
        ],
        "urls": [
            ("Main Stream (Port 554)", "rtsp://{USER}:{PASS}@{IP}:554/live/ch0"),
            ("Sub Stream (Port 554)", "rtsp://{USER}:{PASS}@{IP}:554/live/ch1"),
            ("Main Stream (Port 6554)", "rtsp://{USER}:{PASS}@{IP}:6554/stream_0"),
            ("Sub Stream (Port 6554)", "rtsp://{USER}:{PASS}@{IP}:6554/stream_1"),
            ("Alternative Path", "rtsp://{USER}:{PASS}@{IP}:554/onvif1"),
        ],
        "credentials": "Username is almost always <b>admin</b>. Password is the ONVIF/PC View password you configured in the mobile app (NOT your cloud account password).",
        "ports": "RTSP: 554 or 6554 • ONVIF: 5000 or 8080 or 80 • Tuya LAN API: 6668",
        "quirks": "If port 6668 is open but RTSP fails, PC View is disabled. Some battery-powered Tuya doorbells/cameras do not support continuous RTSP to preserve battery.",
    },

    "TP-Link Tapo": {
        "aliases": ["tapo", "tp-link", "tplink"],
        "summary": "Popular TP-Link Tapo C100, C200, C310, C500, TC60 series cameras. Supports ONVIF and RTSP, but requires a dedicated local 'Camera Account'.",
        "steps": [
            "Open the <b>Tapo</b> app on your smartphone.",
            "Select your camera and tap the <b>gear icon</b> (Camera Settings) in the top-right.",
            "Tap <b>Advanced Settings</b> > <b>Camera Account</b>.",
            "Create a dedicated <b>Username</b> and <b>Password</b> specifically for local streaming.",
            "Save the account. Use these exact credentials in <b>tvpc-cameras-gui</b>.",
            "Re-scan or add the camera directly using the Tapo preset.",
        ],
        "urls": [
            ("Main Stream (High Quality)", "rtsp://{USER}:{PASS}@{IP}:554/stream1"),
            ("Sub Stream (Low Quality)", "rtsp://{USER}:{PASS}@{IP}:554/stream2"),
        ],
        "credentials": "Must use the <b>Camera Account</b> created in Advanced Settings (NOT your TP-Link cloud email/password).",
        "ports": "RTSP: 554 • ONVIF: 2020 • HTTP: 80 / 443",
        "quirks": "Tapo cameras only allow up to 2 simultaneous RTSP streams. If another client (like NVR or Home Assistant) is watching, you may encounter connection errors.",
    },

    "Reolink": {
        "aliases": ["reolink"],
        "summary": "Reolink PoE and Wi-Fi cameras (RLC series, E1 series, Duo, TrackMix). Newer firmware disables RTSP and ONVIF by default for security.",
        "steps": [
            "Open the <b>Reolink Client</b> on PC/Mac or navigate to <code>http://{IP}</code> in a web browser.",
            "Click <b>Settings</b> (gear icon) > <b>Network</b> > <b>Advanced</b>.",
            "Click <b>Server Settings</b> (or <b>Port Settings / Network Service</b>).",
            "Ensure <b>RTSP</b> (Port 554), <b>ONVIF</b> (Port 8000), and <b>HTTP/HTTPS</b> are all toggled <b>ON</b>.",
            "Save your settings.",
            "In <b>tvpc-cameras-gui</b>, scan using your camera administrator username and password.",
        ],
        "urls": [
            ("Main Stream (H.264/H.265)", "rtsp://{USER}:{PASS}@{IP}:554/h264Preview_01_main"),
            ("Sub Stream (H.264)", "rtsp://{USER}:{PASS}@{IP}:554/h264Preview_01_sub"),
            ("Newer Models (Clear)", "rtsp://{USER}:{PASS}@{IP}:554/Preview_01_main"),
            ("Newer Models (Fluent)", "rtsp://{USER}:{PASS}@{IP}:554/Preview_01_sub"),
        ],
        "credentials": "Username: <code>admin</code>. Password: set during initial camera activation.",
        "ports": "RTSP: 554 • ONVIF: 8000 • HTTP: 80 • HTTPS: 443",
        "quirks": "Reolink battery/solar cameras (Argus series) do not support continuous RTSP/ONVIF streams. Reolink E1 (base model) does not have RTSP; E1 Pro and E1 Zoom do.",
    },

    "Hikvision / Annke": {
        "aliases": ["hikvision", "annke", "hilook"],
        "summary": "Hikvision, Annke, and HiLook IP cameras & NVRs. Full ONVIF & RTSP support, but requires enabling ONVIF and creating an ONVIF user.",
        "steps": [
            "Navigate to the camera web interface at <code>http://{IP}</code> in a web browser.",
            "Log in as <code>admin</code> and go to <b>Configuration</b> > <b>Network</b> > <b>Advanced Settings</b> > <b>Integration Protocol</b>.",
            "Check the box for <b>Enable ONVIF</b>.",
            "Click <b>Add</b> to create an ONVIF user account (e.g. user: <code>admin</code>, user type: <code>Media User</code> or <code>Administrator</code>).",
            "Click <b>Save</b>.",
            "In <b>tvpc-cameras-gui</b>, scan or enter the RTSP URL.",
        ],
        "urls": [
            ("Main Stream (Channel 1)", "rtsp://{USER}:{PASS}@{IP}:554/Streaming/Channels/101"),
            ("Sub Stream (Channel 1)", "rtsp://{USER}:{PASS}@{IP}:554/Streaming/Channels/102"),
            ("Alternative Path", "rtsp://{USER}:{PASS}@{IP}:554/h264/ch1/main/av_stream"),
        ],
        "credentials": "Username: <code>admin</code> (or ONVIF user created in web UI). Password: created during device activation.",
        "ports": "RTSP: 554 • HTTP: 80 • Server Port: 8000 • ONVIF: 80 or 8000",
        "quirks": "If streams drop with authentication errors, ensure 'Digest/Basic' authentication is selected in Integration Protocol settings.",
    },

    "Dahua / Amcrest / Imou": {
        "aliases": ["dahua", "amcrest", "imou", "lechange"],
        "summary": "Dahua, Amcrest, and Imou IP cameras. Supports RTSP out of the box with standard channel & subtype parameters.",
        "steps": [
            "For <b>Dahua / Amcrest</b>: RTSP is enabled by default on port 554 using the admin account created during setup.",
            "For <b>Imou</b>: Open the Imou Life app > Camera Settings > Device Information / Label to find the <b>Safety Code</b> (device password).",
            "To adjust stream settings, open <code>http://{IP}</code> in a browser, log in, and check <b>Settings</b> > <b>Camera</b> > <b>Video</b>.",
            "Ensure substream encoding is set to H.264 for widest compatibility with preview widgets.",
            "Scan or add the stream URL in <b>tvpc-cameras-gui</b>.",
        ],
        "urls": [
            ("Main Stream (Channel 1)", "rtsp://{USER}:{PASS}@{IP}:554/cam/realmonitor?channel=1&subtype=0"),
            ("Sub Stream (Channel 1)", "rtsp://{USER}:{PASS}@{IP}:554/cam/realmonitor?channel=1&subtype=1"),
            ("Alternative Path", "rtsp://{USER}:{PASS}@{IP}:554/live"),
        ],
        "credentials": "Username: <code>admin</code>. Password: your device password, or the 6-character Safety Code printed on the Imou camera sticker.",
        "ports": "RTSP: 554 • HTTP: 80 • TCP Control: 37777",
        "quirks": "Imou cameras require username <code>admin</code> and the password printed on the QR-code label as 'Safety Code'.",
    },

    "Ezviz": {
        "aliases": ["ezviz"],
        "summary": "Consumer brand by Hikvision. RTSP is built-in on port 554, but uses the device Verification Code as the password.",
        "steps": [
            "Locate the <b>6-capital-letter Verification Code</b> printed on the sticker underneath your Ezviz camera.",
            "(You can also find or reset it in the <b>Ezviz app</b>: Device Settings > Device Information).",
            "In the Ezviz app, go to Device Settings > <b>Image Encryption</b> and turn it <b>OFF</b> (RTSP cannot stream encrypted video).",
            "In <b>tvpc-cameras-gui</b>, use username <code>admin</code> and the 6-letter verification code as the password.",
            "Add the camera using the standard Hikvision/Ezviz RTSP URL.",
        ],
        "urls": [
            ("Main Stream", "rtsp://admin:{PASS}@{IP}:554/h264/ch1/main/av_stream"),
            ("Alternative Stream", "rtsp://admin:{PASS}@{IP}:554/Streaming/Channels/101"),
        ],
        "credentials": "Username: <code>admin</code>. Password: <b>6-letter Verification Code</b> (e.g. <code>ABCDEF</code>) from the camera sticker.",
        "ports": "RTSP: 554 • HTTP: 80",
        "quirks": "You MUST turn off 'Image Encryption' in the Ezviz mobile app, otherwise the RTSP stream will display a black screen or fail to decode.",
    },

    "Wyze": {
        "aliases": ["wyze"],
        "summary": "Wyze Cam v2, v3, Pan, OG, v4. Stock Wyze cameras stream exclusively to the cloud and do not offer RTSP out of the box.",
        "steps": [
            "<b>Option 1 (Recommended - No flashing)</b>: Run <b>docker-wyze-bridge</b> on any local machine (PC, Raspberry Pi, server). It connects to your Wyze account and hosts standard local RTSP streams for all your Wyze cameras.",
            "<b>Option 2</b>: For Wyze Cam v2, v3, or Pan v1, install the official Wyze RTSP firmware or <b>wz_mini_hacks</b> / <b>Thingino</b> from GitHub onto a microSD card.",
            "Once running, your Wyze camera will have a standard local RTSP URL.",
            "In <b>tvpc-cameras-gui</b>, enter the RTSP URL provided by the bridge or custom firmware.",
        ],
        "urls": [
            ("Via docker-wyze-bridge", "rtsp://{BRIDGE_IP}:8554/{camera-slug}"),
            ("Via Wyze RTSP Firmware", "rtsp://{USER}:{PASS}@{IP}:554/live"),
        ],
        "credentials": "Set in docker-wyze-bridge configuration or created when flashing custom RTSP firmware.",
        "ports": "docker-wyze-bridge: 8554 • Wyze RTSP firmware: 554",
        "quirks": "Stock firmware has no local port open. If you have Wyze cameras, running docker-wyze-bridge in a background Docker container is the easiest zero-modification solution.",
    },

    "Eufy (Anker)": {
        "aliases": ["eufy", "anker"],
        "summary": "Eufy Indoor Cams, Outdoor Cams, and HomeBase cameras. Includes native RTSP / NAS streaming.",
        "steps": [
            "Open the <b>Eufy Security</b> app on your phone.",
            "Select your camera and tap the <b>gear icon</b> (Settings).",
            "Tap <b>General</b> (or <b>Storage</b>) > <b>NAS(RTSP)</b>.",
            "Follow the prompt to set a local username and password.",
            "Choose your streaming mode (<b>Continuous</b> or <b>Motion</b>).",
            "The app will display the generated RTSP stream URL.",
            "Enter this URL in <b>tvpc-cameras-gui</b>.",
        ],
        "urls": [
            ("Main Stream (1080p/2K)", "rtsp://{USER}:{PASS}@{IP}:554/live0"),
            ("Sub Stream", "rtsp://{USER}:{PASS}@{IP}:554/live1"),
        ],
        "credentials": "The username and password you typed into the Eufy Security app under NAS(RTSP).",
        "ports": "RTSP: 554",
        "quirks": "Battery cameras only stream when awake or on motion. Wired indoor/outdoor Eufy cameras support continuous 24/7 RTSP streaming.",
    },

    "Axis Communications": {
        "aliases": ["axis"],
        "summary": "Enterprise Axis network cameras. Excellent standard RTSP, ONVIF, and MJPEG support.",
        "steps": [
            "Open <code>http://{IP}</code> in your browser.",
            "Log in with your administrator credentials.",
            "Ensure the ONVIF user service or root user has media access permissions.",
            "Scan or add the camera in <b>tvpc-cameras-gui</b>.",
        ],
        "urls": [
            ("RTSP Stream (H.264/H.265)", "rtsp://{USER}:{PASS}@{IP}:554/axis-media/media.amp"),
            ("MJPEG Stream", "http://{IP}:80/axis-cgi/mjpg/video.cgi"),
        ],
        "credentials": "Username: <code>root</code> or user created in System > Users.",
        "ports": "RTSP: 554 • HTTP: 80 • HTTPS: 443",
        "quirks": "Supports both RTSP and low-latency MJPEG over HTTP.",
    },

    "Foscam": {
        "aliases": ["foscam"],
        "summary": "Foscam HD and 4K IP cameras. Standard ONVIF and RTSP streaming.",
        "steps": [
            "Open the camera web UI or Foscam VMS.",
            "Under <b>Network</b> > <b>ONVIF</b>, verify ONVIF is enabled.",
            "Check port settings (Foscam often uses port 88 for HTTP and 554 or 88 for RTSP).",
            "In <b>tvpc-cameras-gui</b>, scan or enter the stream URL.",
        ],
        "urls": [
            ("Main Stream", "rtsp://{USER}:{PASS}@{IP}:554/videoMain"),
            ("Sub Stream", "rtsp://{USER}:{PASS}@{IP}:554/videoSub"),
        ],
        "credentials": "Username: <code>admin</code> (or your web UI username).",
        "ports": "RTSP: 554 • HTTP: 88 or 80 • ONVIF: 888",
        "quirks": "Default HTTP port is often 88 instead of 80.",
    },

    "Generic ONVIF / Xiongmai (XM)": {
        "aliases": ["generic", "onvif", "xiongmai", "xm", "hisilicon", "vstarcam", "dvr", "nvr"],
        "summary": "Generic ONVIF cameras, Xiongmai (XM/XMEye), HiSilicon OEM boards, and standalone NVRs/DVRs.",
        "steps": [
            "Most generic cameras have ONVIF enabled by default on port 80, 8899, 5000, or 34567.",
            "Check if the camera has a web page at <code>http://{IP}</code> or <code>http://{IP}:8899</code>.",
            "In <b>tvpc-cameras-gui</b>, run a scan. The ONVIF WS-Discovery engine will auto-detect compatible profiles.",
            "If credentials are required, default is often <code>admin</code> with a blank password or <code>123456</code>.",
        ],
        "urls": [
            ("Standard Generic RTSP", "rtsp://{USER}:{PASS}@{IP}:554/live/ch0"),
            ("XM / NetSurveillance", "rtsp://{USER}:{PASS}@{IP}:554/onvif1"),
            ("HiSilicon Clone", "rtsp://{USER}:{PASS}@{IP}:554/ch0_0.h264"),
            ("Alternative Port 8554", "rtsp://{USER}:{PASS}@{IP}:8554/live"),
        ],
        "credentials": "Default: username <code>admin</code>, password empty or <code>123456</code>, <code>admin</code>, <code>888888</code>.",
        "ports": "RTSP: 554 / 8554 • ONVIF: 8899 / 80 / 5000 • XM NetSurveillance: 34567",
        "quirks": "Many cheap IP cameras only support H.264 video; disabling H.265 in the camera's web UI often improves preview reliability.",
    },
}


def find_brand_guide(search_text: str) -> Optional[str]:
    """Find the best matching brand key in BRAND_GUIDES for a given text."""
    if not search_text:
        return None
    lower = search_text.strip().lower()
    for brand_key, data in BRAND_GUIDES.items():
        if brand_key.lower() == lower:
            return brand_key
        for alias in data.get("aliases", []):
            if re.search(rf"\b{re.escape(alias)}\b", lower) or alias in lower:
                return brand_key
    return None


# ---------------------------------------------------------------------------
# Brand Help Dialog
# ---------------------------------------------------------------------------
class BrandHelpDialog(QDialog):
    """Interactive Brand & Model Setup Guide Dialog."""

    def __init__(self, parent=None, initial_brand: Optional[str] = None,
                 camera_host: Optional[str] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Camera Brand & Model Setup Guide")
        self.resize(740, 620)
        self.setMinimumSize(640, 480)

        self._camera_host = camera_host or ""
        self._matched_brand = find_brand_guide(initial_brand or "") or initial_brand

        self._build_ui()

    def _build_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setSpacing(10)

        # Header
        header = QLabel("💡 Camera Brand Setup & Connection Guide")
        header.setStyleSheet("font-size: 18px; font-weight: bold; color: #4fc3f7; margin-bottom: 2px;")
        sub = QLabel("Select your camera brand below for step-by-step instructions on enabling RTSP/ONVIF in vendor apps.")
        sub.setStyleSheet("color: #aaaaaa; margin-bottom: 6px;")
        sub.setWordWrap(True)
        layout.addWidget(header)
        layout.addWidget(sub)

        # Brand Selector Row
        picker_row = QHBoxLayout()
        picker_row.addWidget(QLabel("<b>Camera Brand:</b>"))

        self._brand_combo = QComboBox()
        for brand in sorted(BRAND_GUIDES.keys()):
            self._brand_combo.addItem(brand)

        # Select initial brand if matched
        if self._matched_brand and self._matched_brand in BRAND_GUIDES:
            idx = self._brand_combo.findText(self._matched_brand)
            if idx >= 0:
                self._brand_combo.setCurrentIndex(idx)

        self._brand_combo.currentIndexChanged.connect(self._on_brand_changed)
        picker_row.addWidget(self._brand_combo, 1)

        layout.addLayout(picker_row)

        # Content Area (Scrollable)
        self._content_browser = QTextBrowser()
        self._content_browser.setOpenExternalLinks(True)
        self._content_browser.setStyleSheet(
            "QTextBrowser { background-color: #222222; border: 1px solid #3a3a3a; border-radius: 4px; padding: 12px; font-size: 13px; line-height: 1.5; }"
        )
        layout.addWidget(self._content_browser, 1)

        # URL Templates Group
        self._url_group = QGroupBox("Stream URL Templates")
        url_layout = QVBoxLayout(self._url_group)
        self._url_combo = QComboBox()
        self._url_edit = QLineEdit()
        self._url_edit.setReadOnly(True)

        url_btns = QHBoxLayout()
        self._copy_btn = QPushButton("📋 Copy URL")
        self._copy_btn.clicked.connect(self._copy_url)
        url_btns.addWidget(self._url_combo, 1)
        url_btns.addWidget(self._copy_btn)

        url_layout.addLayout(url_btns)
        url_layout.addWidget(self._url_edit)
        self._url_combo.currentIndexChanged.connect(self._on_url_combo_changed)

        layout.addWidget(self._url_group)

        # Dialog buttons
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

        # Load initial brand
        self._on_brand_changed()

    def _on_brand_changed(self) -> None:
        brand = self._brand_combo.currentText()
        data = BRAND_GUIDES.get(brand, {})
        if not data:
            return

        ip = self._camera_host or "{IP}"

        html = f"""
        <h2 style="color: #4fc3f7; margin-top: 0;">{brand}</h2>
        <p style="color: #cccccc;">{data.get('summary', '')}</p>
        
        <h3 style="color: #81c784; border-bottom: 1px solid #444; padding-bottom: 4px;">📲 How to Enable RTSP / Local Streaming</h3>
        <ol style="color: #e0e0e0; padding-left: 20px;">
        """
        for step in data.get("steps", []):
            html += f"<li style='margin-bottom: 6px;'>{step}</li>"
        html += "</ol>"

        html += f"""
        <h3 style="color: #81c784; border-bottom: 1px solid #444; padding-bottom: 4px; margin-top: 16px;">🔑 Credentials & Ports</h3>
        <p><b>Credentials:</b> {data.get('credentials', '')}</p>
        <p><b>Network Ports:</b> <code>{data.get('ports', '')}</code></p>
        """

        if data.get("quirks"):
            html += f"""
            <div style="background-color: #2e2818; border-left: 4px solid #ffb74d; padding: 8px 12px; margin-top: 14px; border-radius: 3px;">
                <b style="color: #ffb74d;">⚠️ Important Quirk:</b>
                <span style="color: #e0e0e0;"> {data.get('quirks', '')}</span>
            </div>
            """

        self._content_browser.setHtml(html)

        # Update URLs combo
        self._url_combo.clear()
        urls = data.get("urls", [])
        for name, tmpl in urls:
            rendered = tmpl.replace("{IP}", ip)
            self._url_combo.addItem(name, rendered)

        if urls:
            self._on_url_combo_changed()

    def _on_url_combo_changed(self) -> None:
        url = self._url_combo.currentData() or ""
        self._url_edit.setText(url)

    def _copy_url(self) -> None:
        url = self._url_edit.text().strip()
        if url:
            QApplication.clipboard().setText(url)
            QMessageBox.information(self, "Copied", f"Copied RTSP URL to clipboard:\n{url}")

    def get_selected_url(self) -> str:
        return self._url_edit.text().strip()


def show_brand_help(parent=None, brand_hint: Optional[str] = None, host: Optional[str] = None) -> None:
    """Convenience helper to show the BrandHelpDialog."""
    dlg = BrandHelpDialog(parent=parent, initial_brand=brand_hint, camera_host=host)
    dlg.exec()
