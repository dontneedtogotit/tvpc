#!/usr/bin/env bash
# enhance-cec.sh — drive the desktop from the Samsung Anynet+ remote over HDMI-CEC.
#
#   Media keys  -> playerctl (MPRIS: VacuumTube, browsers)
#   Volume      -> pactl (PipeWire)
#   Navigation  -> ydotool (Wayland; needs the ydotoold daemon)
#
# Usage: sudo ./scripts/enhance-cec.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

echo "[1/4] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
# ydotoold is packaged separately from ydotool on Ubuntu. The client alone
# cannot inject anything, which is why the remote did nothing before.
apt-get install -y cec-utils playerctl ydotool ydotoold

echo "[2/4] Setting up uinput access for ydotoold..."
modprobe uinput 2>/dev/null || true
install -d /etc/modules-load.d
echo uinput >/etc/modules-load.d/uinput.conf

groupadd -f uinput
id -nG "$HTPC_USER" | grep -qw uinput || usermod -aG uinput "$HTPC_USER"

cat >/etc/udev/rules.d/80-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --name-match=uinput 2>/dev/null || true

# Ubuntu ships no unit for ydotoold, so provide one. The socket is handed to
# the HTPC user, which is what the clients below connect to.
HTPC_UID="$(id -u "$HTPC_USER")"
HTPC_GID="$(id -g "$HTPC_USER")"
cat >/etc/systemd/system/ydotoold.service <<EOF
[Unit]
Description=ydotool daemon (virtual input device for the CEC remote)
After=multi-user.target

[Service]
Type=simple
RuntimeDirectory=ydotoold
RuntimeDirectoryMode=0755
ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotoold/socket --socket-own=$HTPC_UID:$HTPC_GID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "[3/4] Installing the CEC remote listener..."
cat >/usr/local/bin/tvpc-cec-remote <<'LISTENER'
#!/usr/bin/env bash
# tvpc-cec-remote — translate CEC key presses into desktop actions.
#
# CEC <User Control Pressed> codes (HDMI CEC spec / libcec):
#   0x00 OK | 0x01 Up | 0x02 Down | 0x03 Left | 0x04 Right
#   0x09 Root menu | 0x0D Exit
#   0x41 Vol+ | 0x42 Vol- | 0x43 Mute
#   0x44 Play | 0x45 Pause | 0x46 Stop | 0x47 FF | 0x48 RW
set -uo pipefail

export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/run/ydotoold/socket}"
log() { echo "$*"; }   # journald captures stdout

# ydotool 1.x requires keycode:pressed pairs — a bare "ydotool key 28" is a
# syntax error, which is why key presses silently did nothing before.
send_key() {
  local code="$1"
  if command -v ydotool >/dev/null 2>&1; then
    ydotool key "${code}:1" "${code}:0" 2>/dev/null && return 0
  fi
  command -v xdotool >/dev/null 2>&1 && DISPLAY=:0 xdotool key "$2" 2>/dev/null
}

handle() {
  case "$1" in
    # Media transport -> MPRIS
    44|45) playerctl play-pause 2>/dev/null || true ;;
    46)    playerctl stop       2>/dev/null || true ;;
    47)    playerctl next       2>/dev/null || true ;;
    48)    playerctl previous   2>/dev/null || true ;;
    # Volume
    41) pactl set-sink-volume @DEFAULT_SINK@ +2%     2>/dev/null || true ;;
    42) pactl set-sink-volume @DEFAULT_SINK@ -2%     2>/dev/null || true ;;
    43) pactl set-sink-mute   @DEFAULT_SINK@ toggle  2>/dev/null || true ;;
    # Navigation (Linux input event codes)
    00) send_key 28  Return ;;
    01) send_key 103 Up     ;;
    02) send_key 108 Down   ;;
    03) send_key 105 Left   ;;
    04) send_key 106 Right  ;;
    09) send_key 125 super  ;;   # Root menu -> Meta (app launcher)
    0d) send_key 1   Escape ;;   # Exit -> Back
    *)  return ;;
  esac
  log "key=0x$1 handled"
}

log "listener started (socket=$YDOTOOL_SOCKET)"
# -d 8 selects the TRAFFIC log level. The old code used -d 1 (errors only), so
# no frames were ever printed to match against. Frames look like:
#   TRAFFIC: [   1234]  >> 04:44:41
cec-client -d 8 2>/dev/null | while IFS= read -r line; do
  if [[ "$line" =~ \>\>[[:space:]]*[0-9a-fA-F]{2}:44:([0-9a-fA-F]{2}) ]]; then
    handle "$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")"
  fi
done
LISTENER
chmod 0755 /usr/local/bin/tvpc-cec-remote

cat >/etc/systemd/system/tvpc-cec-remote.service <<EOF
[Unit]
Description=tvpc CEC remote control listener
After=graphical.target ydotoold.service
Wants=ydotoold.service
PartOf=graphical.target

[Service]
Type=simple
# Let the session (and htpc-startup's CEC handshake) settle first: only one
# process at a time can hold the CEC adapter.
ExecStartPre=/bin/sleep 15
ExecStart=/usr/local/bin/tvpc-cec-remote
Restart=always
RestartSec=5
User=$HTPC_USER
Environment=XDG_RUNTIME_DIR=/run/user/$HTPC_UID
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$HTPC_UID/bus
Environment=YDOTOOL_SOCKET=/run/ydotoold/socket

[Install]
WantedBy=graphical.target
EOF

echo "[4/4] Enabling services..."
systemctl daemon-reload
systemctl enable --now ydotoold.service
systemctl enable tvpc-cec-remote.service
systemctl restart tvpc-cec-remote.service 2>/dev/null || true

echo "Done."
echo "  Listener log:    journalctl -u tvpc-cec-remote -f"
echo "  Daemon log:      journalctl -u ydotoold -f"
echo "  Raw CEC traffic: sudo systemctl stop tvpc-cec-remote && cec-client -d 8"
echo "  (stop the listener first — the CEC adapter takes one client at a time)"
