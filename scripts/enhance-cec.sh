#!/usr/bin/env bash
# enhance-cec.sh — drive the desktop from the Samsung Anynet+ remote over HDMI-CEC.
#
#   Media keys  -> playerctl (MPRIS: VacuumTube, browsers)
#   Volume      -> pactl (PipeWire)
#   Navigation  -> ydotool (Wayland; needs the ydotoold daemon)
#
# IMPORTANT: the Intel NUC7i5BNH has NO native CEC. HDMI-CEC only works with a
# Pulse-Eight USB-CEC adapter (or equivalent) plugged into the NUC's USB. If
# there is no adapter, cec-client finds nothing and the remote does nothing.
#
# Usage:
#   sudo ./scripts/enhance-cec.sh         install + enable
#   sudo ./scripts/enhance-cec.sh --check report adapter + service state
set -euo pipefail

if [[ "${1:-}" == "--check" ]]; then
    echo "== CEC adapter =="
    if command -v cec-client >/dev/null 2>&1; then
        cec-client -l 2>&1 | sed 's/^/  /' || echo "  cec-client present but no adapter listed"
    else
        echo "  cec-client NOT installed"
    fi
    echo
    echo "  /dev/cec* : $(ls /dev/cec* 2>/dev/null || echo none)"
    echo "  /dev/ttyACM* /dev/ttyUSB* : $(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || echo none)"
    echo "  USB CEC adapter (lsusb): $(lsusb 2>/dev/null | grep -iE 'cec|pulse' || echo none)"
    echo "  user groups: $(id | tr ',' '\n' | grep -oE 'dialout|plugdev|tty|uinput' | tr '\n' ',' || echo none)"
    echo
    echo "== Services =="
    for u in ydotoold tvpc-cec-remote; do
        if systemctl list-unit-files "$u.service" >/dev/null 2>&1; then
            echo "  $u: $(systemctl is-enabled "$u" 2>/dev/null) / $(systemctl is-active "$u" 2>/dev/null)"
        else
            echo "  $u: not installed"
        fi
    done
    echo
    echo "  Anynet+ must be ENABLED on the TV (Settings > General > External Device"
    echo "  Manager > Anynet+ (HDMI-CEC)). The NUC must be on the TV's HDMI input."
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

# --- 0. Verify a CEC adapter exists ----------------------------------------
# Without it the listener can never receive a key, and the remote will do
# nothing. Say so up front instead of installing a silently-dead service.
echo "[0/4] Checking for a CEC adapter..."
if ! command -v cec-client >/dev/null 2>&1; then
    echo "  !! cec-client (cec-utils) is not installed — install it first:"
    echo "     sudo apt-get install cec-utils"
    exit 1
fi
if ! cec-client -l 2>&1 | grep -qiE 'found|adapter|com port|/dev/'; then
    echo "  !! No CEC adapter detected (no /dev/cec*, no Pulse-Eight device)."
    echo "     The Intel NUC7i5BNH has no onboard CEC — you need a USB-CEC"
    echo "     adapter (Pulse-Eight or compatible) plugged into the NUC."
    echo "     The listener service will be installed but the remote will not"
    echo "     work until an adapter is present. Plug one in and re-run this."
    ls /dev/cec* 2>/dev/null || true
fi

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
id -nG "$HTPC_USER" | grep -w uinput >/dev/null || usermod -aG uinput "$HTPC_USER"

cat >/etc/udev/rules.d/80-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --name-match=uinput 2>/dev/null || true

# CEC adapter access. Pulse-Eight USB-CEC adapters present as /dev/ttyACMx;
# libCEC needs read+write. Add the user to dialout (the group that owns the
# device) and write a udev rule so future adapters get the right perms too.
groupadd -f dialout
id -nG "$HTPC_USER" | grep -w dialout >/dev/null || usermod -aG dialout "$HTPC_USER"
cat >/etc/udev/rules.d/99-cec-adapter.rules <<'EOF'
# Pulse-Eight USB-CEC adapter and similar tty-based CEC devices.
# Give the dialout group rw so libCEC (cec-client) can open it.
KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", MODE="0660", GROUP="dialout"
KERNEL=="ttyUSB[0-9]*", SUBSYSTEM=="tty", MODE="0660", GROUP="dialout", ATTRS{idVendor}=="1a44"
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=tty 2>/dev/null || true

# If a CEC adapter is already plugged in, fix its current mode so the listener
# can open it without a replug. If none is plugged in yet, this is a no-op.
for dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -e $dev ]] || continue
    chgrp dialout "$dev" 2>/dev/null || true
    chmod 0660 "$dev" 2>/dev/null || true
done

# Warn if the user is going to need a log out for the new dialout group.
if id -nG "$HTPC_USER" | grep -wq dialout; then
    :
else
    echo "  (user $HTPC_USER was added to 'dialout' — re-login / reboot for it to take effect)"
fi

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

# shellcheck source=/dev/null
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/run/ydotoold/socket}"
log() { echo "tvpc-cec-remote: $*" >&2; }   # journald captures stderr

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
        09)
            # Root menu / Home button. When the home is curated to a single tile
            # (tvpc-tweaks vacuum-only sets TVPC_ALLAPPS=1), this opens the All Apps
            # launcher instead of Meta, so hidden apps stay reachable from the couch.
            if [[ ${TVPC_ALLAPPS:-0} == 1 ]] && command -v tvpc-allapps >/dev/null 2>&1; then
                nohup tvpc-allapps >/dev/null 2>&1 &
            else
                send_key 125 super   # Root menu -> Meta (app launcher)
            fi ;;
        0d) send_key 1   Escape ;;   # Exit -> Back
        *)  return ;;
    esac
    log "key=0x$1 handled"
}

log "listener started (socket=$YDOTOOL_SOCKET)"
# -d 8 selects the TRAFFIC log level. The old code used -d 1 (errors only), so
# no frames were ever printed to match against. Frames look like:
#   TRAFFIC: [   1234]  >> 04:44:41
# stdbuf -oL keeps lines unbuffered so a key is acted on immediately and each
# raw frame is logged for debugging (visible via: journalctl -u tvpc-cec-remote).
stdbuf -oL cec-client -d 8 2>&1 | while IFS= read -r line; do
    # Log every TRAFFIC frame so we can see what the TV actually sends.
    if [[ "$line" == *TRAFFIC* ]]; then
        log "raw: $line"
    fi
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

