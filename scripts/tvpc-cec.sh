#!/usr/bin/env bash
# tvpc-cec.sh — Unified HDMI-CEC management for tvpc
#
# Commands:
#   poweron       Power on the Samsung TV via CEC and switch to HDMI input
#   setup         Install and configure uinput, udev rules, ydotoold, and CEC remote listener
#   check         Report CEC adapter and service status
#   listen        Run the CEC remote control listener daemon
#
# Usage:
#   sudo ./scripts/tvpc-cec.sh poweron
#   sudo ./scripts/tvpc-cec.sh setup
#   ./scripts/tvpc-cec.sh check
#   ./scripts/tvpc-cec.sh listen
set -euo pipefail

# shellcheck source=/dev/null
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

CEC_BIN="/usr/bin/cec-client"
command -v "$CEC_BIN" >/dev/null 2>&1 || CEC_BIN="$(command -v cec-client 2>/dev/null || echo /usr/bin/cec-client)"

cmd_poweron() {
    if [[ ! -x "$CEC_BIN" ]] && ! command -v cec-client >/dev/null 2>&1; then
        echo "cec-client not found, skipping TV power-on"
        exit 0
    fi

    # Give CEC bus a moment to settle
    sleep 2

    # Power on the TV (logical address 0 = TV on the CEC bus)
    echo "on 0" | "$CEC_BIN" -s 2>/dev/null || echo "TV power-on command failed (CEC may be unavailable)"

    # Make the NUC the active source so the TV switches to HDMI1
    echo "as" | "$CEC_BIN" -s 2>/dev/null || true

    # Nudge Samsung: some 2013 models need a second wake to switch input
    sleep 1
    echo "as" | "$CEC_BIN" -s 2>/dev/null || true

    echo "CEC power-on + source switch complete."
}

cmd_check() {
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
    echo "  user groups: $(id | tr ',' '
' | grep -oE 'dialout|plugdev|tty|uinput' | tr '
' ',' || echo none)"
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
}

cmd_setup() {
    [[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0 setup)" >&2; exit 1; }

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

    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e $dev ]] || continue
        chgrp dialout "$dev" 2>/dev/null || true
        chmod 0660 "$dev" 2>/dev/null || true
    done

    if ! id -nG "$HTPC_USER" | grep -wq dialout; then
        echo "  (user $HTPC_USER was added to 'dialout' — re-login / reboot for it to take effect)"
    fi

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
set -uo pipefail

[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/run/ydotoold/socket}"
log() { echo "tvpc-cec-remote: $*" >&2; }

send_key() {
    local code="$1"
    if command -v ydotool >/dev/null 2>&1; then
        ydotool key "${code}:1" "${code}:0" 2>/dev/null && return 0
    fi
    command -v xdotool >/dev/null 2>&1 && DISPLAY=:0 xdotool key "$2" 2>/dev/null
}

handle() {
    case "$1" in
        44|45) playerctl play-pause 2>/dev/null || true ;;
        46)    playerctl stop       2>/dev/null || true ;;
        47)    playerctl next       2>/dev/null || true ;;
        48)    playerctl previous   2>/dev/null || true ;;
        41)    pactl set-sink-volume @DEFAULT_SINK@ +2%     2>/dev/null || true ;;
        42)    pactl set-sink-volume @DEFAULT_SINK@ -2%     2>/dev/null || true ;;
        43)    pactl set-sink-mute   @DEFAULT_SINK@ toggle  2>/dev/null || true ;;
        00)    send_key 28  Return ;;
        01)    send_key 103 Up     ;;
        02)    send_key 108 Down   ;;
        03)    send_key 105 Left   ;;
        04)    send_key 106 Right  ;;
        09)
            if [[ ${TVPC_ALLAPPS:-0} == 1 ]] && command -v tvpc-allapps >/dev/null 2>&1; then
                nohup tvpc-allapps >/dev/null 2>&1 &
            else
                send_key 125 super
            fi ;;
        0d)    send_key 1   Escape ;;
        72)    # Red button (A): Toggle primary camera PiP
            if command -v tvpc-cameras >/dev/null 2>&1; then
                tvpc-cameras toggle-pip 0 2>/dev/null || true
            elif [[ -x "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras.sh" ]]; then
                "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras.sh" toggle-pip 0 2>/dev/null || true
            fi ;;
        71)    # Blue button (D): Toggle 2x2 camera grid
            if command -v tvpc-cameras >/dev/null 2>&1; then
                tvpc-cameras toggle-grid 2>/dev/null || true
            elif [[ -x "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras.sh" ]]; then
                "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras.sh" toggle-grid 2>/dev/null || true
            fi ;;
        74)    # Yellow button (C): Cycle through camera feeds
            if command -v tvpc-cameras >/dev/null 2>&1; then
                tvpc-cameras cycle 2>/dev/null || true
            elif [[ -x "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras.sh" ]]; then
                "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras.sh" cycle 2>/dev/null || true
            fi ;;
        53)    # Tools button: Launch camera GUI
            if command -v tvpc-cameras-gui >/dev/null 2>&1; then
                nohup tvpc-cameras-gui >/dev/null 2>&1 &
            elif [[ -x "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras-gui.sh" ]]; then
                nohup "/home/$HTPC_USER/tvpc/scripts/tvpc-cameras-gui.sh" >/dev/null 2>&1 &
            fi ;;
        *)     return ;;
    esac
    log "key=0x$1 handled"
}

log "listener started (socket=$YDOTOOL_SOCKET)"
stdbuf -oL cec-client -d 8 2>&1 | while IFS= read -r line; do
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
}

cmd_listen() {
    exec /usr/local/bin/tvpc-cec-remote "$@"
}

usage() {
    echo "Usage: $0 {poweron|setup|check|listen}"
    echo
    echo "Commands:"
    echo "  poweron       Wake TV and switch HDMI input"
    echo "  setup         Configure uinput/dialout/ydotoold and install remote listener"
    echo "  check         Check CEC adapter and service status"
    echo "  listen        Run CEC remote key event listener"
    exit "${1:-1}"
}

case "${1:-}" in
    poweron)
        cmd_poweron
        ;;
    setup)
        cmd_setup
        ;;
    check|--check)
        cmd_check
        ;;
    listen)
        cmd_listen
        ;;
    -h|--help|help)
        usage 0
        ;;
    "")
        usage 1
        ;;
    *)
        echo "Unknown command: $1" >&2
        usage 1
        ;;
esac
