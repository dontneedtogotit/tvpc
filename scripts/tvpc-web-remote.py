#!/usr/bin/env python3
"""
tvpc-web-remote — Couch Web Remote for TVPC.
Provides a responsive mobile web interface allowing any phone on the LAN to:
  - Control TV navigation with a virtual D-Pad (Up, Down, Left, Right, OK, Back, Home, Menu)
  - Type full text / search queries from a mobile keyboard into the active TV window
  - Adjust Volume, Mute, and Power
  - Quick-launch apps (YouTube, Security Cameras, Kodi, Settings)
  - Set Sleep Timers (15m, 30m, 60m, 90m)
  - Toggle PipeWire Night Mode audio
  - Trigger live Camera Alert PiP popups via webhooks
"""

import http.server
import json
import os
import subprocess
import sys
import urllib.parse
from http import HTTPStatus

PORT = int(os.environ.get("TVPC_REMOTE_PORT", 8080))
CONF_DIR = os.path.expanduser("~/.config/tvpc")
os.makedirs(CONF_DIR, exist_ok=True)

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <title>TVPC Remote</title>
  <style>
    :root {
      --bg: #0b0e14;
      --card-bg: rgba(26, 32, 44, 0.75);
      --card-border: rgba(255, 255, 255, 0.08);
      --accent: #00d2ff;
      --accent-glow: rgba(0, 210, 255, 0.35);
      --text: #f0f4f8;
      --text-muted: #8a99ad;
      --btn-active: #00f2fe;
      --danger: #ff4757;
      --success: #2ed573;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body {
      background: radial-gradient(circle at top center, #151d2a 0%, var(--bg) 100%);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 16px;
      overflow-x: hidden;
      touch-action: manipulation;
    }
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      width: 100%;
      max-width: 420px;
      margin-bottom: 16px;
    }
    .brand { font-size: 20px; font-weight: 800; letter-spacing: 1px; color: var(--accent); }
    .brand span { color: var(--text); font-weight: 300; }
    .status-dot {
      width: 10px; height: 10px; border-radius: 50%; background: var(--success);
      box-shadow: 0 0 10px var(--success);
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border-radius: 20px;
      padding: 16px;
      width: 100%;
      max-width: 420px;
      margin-bottom: 14px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.37);
    }
    .card-title {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 1.5px;
      color: var(--text-muted);
      margin-bottom: 12px;
      font-weight: 700;
    }
    /* Keyboard typing box */
    .input-row {
      display: flex;
      gap: 8px;
    }
    input[type="text"] {
      flex: 1;
      background: rgba(0, 0, 0, 0.4);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      padding: 12px 14px;
      font-size: 15px;
      color: var(--text);
      outline: none;
      transition: border-color 0.2s;
    }
    input[type="text"]:focus {
      border-color: var(--accent);
      box-shadow: 0 0 8px var(--accent-glow);
    }
    .btn {
      background: rgba(255, 255, 255, 0.05);
      border: 1px solid var(--card-border);
      color: var(--text);
      border-radius: 14px;
      padding: 12px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.15s ease;
      user-select: none;
      -webkit-user-select: none;
    }
    .btn:active {
      transform: scale(0.96);
      background: rgba(0, 210, 255, 0.25);
      border-color: var(--accent);
    }
    .btn-accent {
      background: linear-gradient(135deg, #00d2ff 0%, #0072ff 100%);
      color: #fff;
      border: none;
    }
    /* D-Pad layout */
    .dpad-container {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      grid-template-rows: repeat(3, 70px);
      gap: 8px;
      max-width: 280px;
      margin: 8px auto;
    }
    .dpad-btn {
      font-size: 20px;
      border-radius: 18px;
    }
    .dpad-center {
      background: linear-gradient(135deg, rgba(0,210,255,0.2) 0%, rgba(0,114,255,0.3) 100%);
      font-weight: 800;
      font-size: 16px;
      border-color: rgba(0, 210, 255, 0.4);
    }
    /* Controls grid */
    .grid-4 {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 8px;
    }
    .grid-3 {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 8px;
    }
    .grid-2 {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 8px;
    }
    /* App launcher chips */
    .app-chip {
      padding: 10px;
      border-radius: 12px;
      text-align: center;
      font-size: 13px;
    }
    .toast {
      position: fixed;
      bottom: 24px;
      background: rgba(15, 23, 42, 0.95);
      border: 1px solid var(--accent);
      color: #fff;
      padding: 8px 18px;
      border-radius: 30px;
      font-size: 13px;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.25s ease;
      box-shadow: 0 4px 16px var(--accent-glow);
    }
    .toast.show { opacity: 1; }
  </style>
</head>
<body>
  <header>
    <div class="brand">TVPC <span>REMOTE</span></div>
    <div class="status-dot" title="Connected"></div>
  </header>

  <!-- Phone Keyboard Input -->
  <div class="card">
    <div class="card-title">Phone Keyboard Input</div>
    <div class="input-row">
      <input type="text" id="type-box" placeholder="Type here and press Send..." autocomplete="off">
      <button class="btn btn-accent" onclick="sendTypedText()">Send</button>
      <button class="btn" onclick="sendKey('backspace')">Del</button>
    </div>
  </div>

  <!-- Navigation D-Pad -->
  <div class="card">
    <div class="card-title">Navigation</div>
    <div class="dpad-container">
      <div></div>
      <button class="btn dpad-btn" onclick="sendKey('up')">▲</button>
      <div></div>
      <button class="btn dpad-btn" onclick="sendKey('left')">◀</button>
      <button class="btn dpad-btn dpad-center" onclick="sendKey('enter')">OK</button>
      <button class="btn dpad-btn" onclick="sendKey('right')">▶</button>
      <div></div>
      <button class="btn dpad-btn" onclick="sendKey('down')">▼</button>
      <div></div>
    </div>
    <div class="grid-4" style="margin-top: 10px;">
      <button class="btn" onclick="sendKey('back')">Back</button>
      <button class="btn" onclick="sendKey('home')">Home</button>
      <button class="btn" onclick="sendKey('menu')">Menu</button>
      <button class="btn" style="color: var(--danger);" onclick="sendKey('close')">Close</button>
    </div>
  </div>

  <!-- Volume & Playback -->
  <div class="card">
    <div class="card-title">Audio & Playback</div>
    <div class="grid-4">
      <button class="btn" onclick="sendKey('vol_down')">Vol -</button>
      <button class="btn" onclick="sendKey('mute')">Mute</button>
      <button class="btn" onclick="sendKey('vol_up')">Vol +</button>
      <button class="btn" onclick="sendKey('play_pause')">⏯ Play</button>
    </div>
  </div>

  <!-- Quick App Launchers -->
  <div class="card">
    <div class="card-title">Quick Launch</div>
    <div class="grid-4">
      <button class="btn app-chip" onclick="launchApp('youtube')">YouTube</button>
      <button class="btn app-chip" onclick="launchApp('cameras')">Cameras</button>
      <button class="btn app-chip" onclick="launchApp('kodi')">Kodi</button>
      <button class="btn app-chip" onclick="launchApp('settings')">Settings</button>
    </div>
  </div>

  <!-- TV Features: Night Mode, Camera Alert & Sleep Timer -->
  <div class="card">
    <div class="card-title">TV Tools & Timers</div>
    <div class="grid-2" style="margin-bottom: 10px;">
      <button class="btn" onclick="toggleNightMode()">🌙 Night Mode</button>
      <button class="btn" onclick="triggerCameraAlert()">📹 Cam Alert</button>
    </div>
    <div class="grid-4">
      <button class="btn" onclick="setSleep(15)">15m</button>
      <button class="btn" onclick="setSleep(30)">30m</button>
      <button class="btn" onclick="setSleep(60)">60m</button>
      <button class="btn" style="color: var(--danger);" onclick="setSleep(0)">Off</button>
    </div>
  </div>

  <div id="toast" class="toast">Command sent</div>

  <script>
    function showToast(msg) {
      const t = document.getElementById('toast');
      t.textContent = msg;
      t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 1400);
    }

    async function apiPost(endpoint, data = {}) {
      try {
        const res = await fetch(endpoint, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(data)
        });
        return await res.json();
      } catch (e) {
        console.error(e);
      }
    }

    function sendKey(key) {
      apiPost('/api/key', { key });
      showToast(key.toUpperCase());
    }

    function sendTypedText() {
      const box = document.getElementById('type-box');
      const text = box.value;
      if (!text) return;
      apiPost('/api/type', { text });
      box.value = '';
      showToast('Sent text to TV');
    }

    document.getElementById('type-box').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') sendTypedText();
    });

    function launchApp(app) {
      apiPost('/api/launch', { app });
      showToast('Launching ' + app);
    }

    async function toggleNightMode() {
      const res = await apiPost('/api/night-mode', { action: 'toggle' });
      showToast('Night Mode: ' + (res.status || 'Toggled'));
    }

    function triggerCameraAlert() {
      apiPost('/api/alert', { camera: '0', duration: 10 });
      showToast('Camera PiP triggered (10s)');
    }

    function setSleep(mins) {
      if (mins === 0) {
        apiPost('/api/sleep', { action: 'cancel' });
        showToast('Sleep timer cancelled');
      } else {
        apiPost('/api/sleep', { minutes: mins });
        showToast('Sleep timer: ' + mins + 'm');
      }
    }
  </script>
</body>
</html>
"""

def send_ydotool_key(code):
    """Dispatch key press using ydotool or fall back to xdotool."""
    socket = os.environ.get("YDOTOOL_SOCKET", "/run/ydotoold/socket")
    try:
        if os.path.exists(socket) or subprocess.run(["which", "ydotool"], capture_output=True).returncode == 0:
            cmd = ["ydotool", "key", f"{code}:1", f"{code}:0"]
            subprocess.run(cmd, env={**os.environ, "YDOTOOL_SOCKET": socket}, check=False, timeout=1)
            return
    except Exception:
        pass
    try:
        subprocess.run(["xdotool", "key", str(code)], check=False, timeout=1)
    except Exception:
        pass

def type_text(text):
    """Type a string into the active window."""
    socket = os.environ.get("YDOTOOL_SOCKET", "/run/ydotoold/socket")
    try:
        cmd = ["ydotool", "type", text]
        subprocess.run(cmd, env={**os.environ, "YDOTOOL_SOCKET": socket}, check=False, timeout=2)
        return
    except Exception:
        pass
    try:
        subprocess.run(["xdotool", "type", text], check=False, timeout=2)
    except Exception:
        pass

KEY_MAP = {
    "up": 103,
    "down": 108,
    "left": 105,
    "right": 106,
    "enter": 28,
    "back": 1,        # Escape
    "home": 125,      # Super
    "menu": 125,
    "backspace": 14,
    "vol_up": 115,
    "vol_down": 114,
    "mute": 113,
    "play_pause": 164,
}

class RemoteRequestHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/" or parsed.path == "/index.html":
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode("utf-8"))
        elif parsed.path == "/api/status":
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "app": "tvpc-web-remote"}).encode("utf-8"))
        else:
            self.send_response(HTTPStatus.NOT_FOUND)
            self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
        try:
            data = json.loads(body)
        except Exception:
            data = {}

        resp = {"success": True}

        if parsed.path == "/api/key":
            key = data.get("key", "").lower()
            if key == "close":
                subprocess.run(
                    ["qdbus", "org.kde.kglobalaccel", "/component/kwin", "invokeShortcut", "Window Close"],
                    check=False, timeout=1
                )
            elif key in KEY_MAP:
                send_ydotool_key(KEY_MAP[key])
            resp["key"] = key

        elif parsed.path == "/api/type":
            text = data.get("text", "")
            if text:
                type_text(text)
            resp["typed"] = len(text)

        elif parsed.path == "/api/launch":
            app = data.get("app", "").lower()
            if app == "youtube":
                subprocess.Popen(["flatpak", "run", "io.github.vacuumtube.VacuumTube"])
            elif app == "cameras":
                subprocess.Popen(["tvpc-cameras-gui"])
            elif app == "kodi":
                subprocess.Popen(["kodi"])
            elif app == "settings":
                subprocess.Popen(["tvpc-setup"])
            resp["launched"] = app

        elif parsed.path == "/api/night-mode":
            action = data.get("action", "toggle")
            res = subprocess.run(["tvpc", "audio", "night-mode", action], capture_output=True, text=True)
            resp["status"] = res.stdout.strip()

        elif parsed.path == "/api/alert":
            cam = str(data.get("camera", "0"))
            dur = str(data.get("duration", "10"))
            subprocess.Popen(["tvpc", "cameras", "alert", cam, dur])
            resp["alert"] = cam

        elif parsed.path == "/api/sleep":
            mins = data.get("minutes")
            act = data.get("action")
            if act == "cancel" or mins == 0:
                subprocess.run(["tvpc", "sleep-timer", "cancel"], check=False)
                resp["sleep"] = "cancelled"
            elif mins:
                subprocess.Popen(["tvpc", "sleep-timer", str(mins)])
                resp["sleep"] = f"{mins}m"

        else:
            self.send_response(HTTPStatus.NOT_FOUND)
            self.end_headers()
            return

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(resp).encode("utf-8"))

def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), RemoteRequestHandler)
    print(f"tvpc-web-remote listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
