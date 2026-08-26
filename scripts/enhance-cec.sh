#!/usr/bin/env bash
# enhance-cec.sh - Enhanced CEC remote control for Plasma Mobile (Wayland)
#
# Listens for Samsung Anynet+ remote button presses over HDMI-CEC and maps them:
#   - Media keys  -> playerctl (MPRIS; controls VacuumTube/Firefox directly)
#   - Volume      -> pactl (PipeWire)
#   - Navigation  -> ydotool (works on Wayland; xdotool fallback for X11)
#
# Correct CEC <User Control Pressed> codes (HDMI CEC spec / libcec):
#   0x00 OK | 0x01 Up | 0x02 Down | 0x03 Left | 0x04 Right
#   0x09 Root menu -> Home | 0x0D Exit -> Back
#   0x20-0x29 Numbers 0-9
#   0x41 Vol+ | 0x42 Vol- | 0x43 Mute
#   0x44 Play | 0x45 Pause* | 0x46 Stop | 0x47 FF | 0x48 RW   (*0x45 is also
#   the KeyRelease opcode; we filter by full frame, not just the keycode)
#
# Usage: sudo ./enhance-cec.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

echo "[1/3] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cec-utils playerctl ydotool xdotool

HTPC_USER="${HTPC_USER:-htpc}"

# ydotool needs uinput access
if ! id -nG "$HTPC_USER" | grep -qw uinput 2>/dev/null; then
  groupadd -f uinput
  usermod -aG uinput "$HTPC_USER"
fi
# Persistent uinput permissions
cat >/etc/udev/rules.d/80-uinput.rules <<'EOF'
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
EOF
udevadm control --reload-rules || true
systemctl enable --now ydotoold || true

echo "[2/3] Installing CEC remote listener..."

install -m 0755 /dev/null /usr/local/bin/tvpc-cec-remote
cat >/usr/local/bin/tvpc-cec-remote <<'LISTENER'
#!/usr/bin/env bash
# tvpc-cec-remote - translate CEC keypresses into desktop actions
set -uo pipefail
LOG=/var/log/tvpc-cec-remote.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

is_wayland() { [[ -n "${WAYLAND_DISPLAY:-}" ]]; }

send_key() {
  local key="$1"
  if is_wayland && command -v ydotool >/dev/null; then
    ydotool key "$key"
  elif command -v xdotool >/dev/null; then
    DISPLAY=:0 xdotool key "$key" 2>/dev/null
  fi
}

handle() {
  local code="$1"
  case "$code" in
    # Media transport -> MPRIS (VacuumTube, browsers)
    44|45) playerctl play-pause 2>/dev/null || true ;;        # Play/Pause
    46)    playerctl stop      2>/dev/null || true ;;          # Stop
    47)    playerctl next      2>/dev/null || true ;;          # Fast fwd -> next
    48)    playerctl previous  2>/dev/null || true ;;          # Rewind   -> prev
    # Volume
    41) pactl set-sink-volume @DEFAULT_SINK@ +2% ;;
    42) pactl set-sink-volume @DEFAULT_SINK@ -2% ;;
    43) pactl set-sink-mute @DEFAULT_SINK@ toggle ;;
    # Navigation / menus (Wayland-safe via ydotool)
    00) send_key "28" ;;        # OK      -> Enter
    01) send_key "103" ;;       # Up
    02) send_key "108" ;;       # Down
    03) send_key "105" ;;       # Left
    04) send_key "106" ;;       # Right
    09) send_key "102" ;;       # Root menu -> Home (launches app grid)
    0d) send_key "1"  ;;        # Exit -> Esc (Back)
  esac
  log "key=$code handled"
}

log "listener started"
# Stream frames; keypress frames look like:  >> 4f:44:46  (src:opcode:keycode)
cec-client -d 1 2>/dev/null | while read -r line; do
  if [[ "$line" =~ ^\>\>[[:space:]][0-9a-fA-F]{2}:44:([0-9a-fA-F]{2}) ]]; then
    handle "$(printf '%d' "0x${BASH_REMATCH[1]}")"
  fi
done
LISTENER

cat >/etc/systemd/system/tvpc-cec-remote.service <<'UNIT'
[Unit]
Description=tvpc CEC remote control listener
After=multi-user.target graphical.target
Wants=graphical.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 8
ExecStart=/usr/local/bin/tvpc-cec-remote
Restart=always
RestartSec=5
User=htpc
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus

[Install]
WantedBy=graphical.target
UNIT

systemctl daemon-reload
systemctl enable --now tvpc-cec-remote.service

echo "[3/3] Done."
echo "  Logs:            journalctl -u tvpc-cec-remote -f"
echo "  Raw CEC traffic: echo 'log 1' | cec-client -s -d 1"
echo "  Adjust mappings: edit /usr/local/bin/tvpc-cec-remote"