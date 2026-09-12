#!/usr/bin/env bash
# tvpc — Unified HTPC Appliance Manager for Ubuntu 24.04
# Consolidates all runtime management, hardware controls, and TV interfaces:
#   cec, audio, session, bigscreen, theme, cameras, hyprland,
#   controller, doctor, repair, status, tweaks, gui
set -o pipefail

# ---------------------------------------------------------------------------
# Global Environment & Common Helpers
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
REAL_USER="${SUDO_USER:-${USER:-$HTPC_USER}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || true)"
[[ -z $REAL_HOME ]] && REAL_HOME="$HOME"

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ $EUID -eq 0 ]]; }
require_root() {
  is_root || { echo "Please run as root: sudo $(basename "$0") $*" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Module: CEC
# ---------------------------------------------------------------------------
subcmd_cec() {
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

}

# ---------------------------------------------------------------------------
# Module: Audio
# ---------------------------------------------------------------------------
subcmd_audio() {
set -uo pipefail

log() { echo "tvpc-hdmi-audio: $*"; }

# PipeWire may still be starting when the session comes up.
for _ in $(seq 1 30); do
  pactl info >/dev/null 2>&1 && break
  sleep 1
done
if ! pactl info >/dev/null 2>&1; then
  log "PipeWire/pulse not responding after 30s — giving up"
  exit 1
fi

# card <TAB> profile <TAB> available
mapfile -t CANDIDATES < <(pactl list cards 2>/dev/null | awk '
  /^Card #/                       { name=""; inprof=0 }
  /^[[:space:]]*Name:[[:space:]]/ { name=$2 }
  /^[[:space:]]*Profiles:/        { inprof=1; next }
  /^[[:space:]]*Active Profile:/  { inprof=0 }
  inprof && $1 ~ /^output:hdmi-stereo/ {
    prof=$1; sub(/:$/, "", prof)
    avail = (index($0, "available: no") > 0) ? "no" : "yes"
    print name "\t" prof "\t" avail
  }')

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  log "no HDMI stereo profile found — is the TV on and the cable in?"
  pactl list cards short 2>/dev/null | sed 's/^/  card: /'
  exit 1
fi

# Prefer a profile ALSA says is plugged in; otherwise take the first.
PICK=""
for row in "${CANDIDATES[@]}"; do
  [[ $row == *$'\t'yes ]] && { PICK="$row"; break; }
done
[[ -n $PICK ]] || { PICK="${CANDIDATES[0]}"; log "no HDMI port reports as connected; trying anyway"; }

CARD="${PICK%%$'\t'*}"
PROFILE="$(cut -f2 <<<"$PICK")"

log "card=$CARD profile=$PROFILE"
pactl set-card-profile "$CARD" "$PROFILE" || { log "failed to set profile"; exit 1; }

# The sink only exists once the profile is active.
SINK=""
for _ in $(seq 1 10); do
  SINK="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /hdmi/ {print $2; exit}')"
  [[ -n $SINK ]] && break
  sleep 1
done
if [[ -z $SINK ]]; then
  log "profile set but no HDMI sink appeared"
  exit 1
fi

pactl set-default-sink "$SINK"
pactl set-sink-mute "$SINK" 0 2>/dev/null || true
log "default sink -> $SINK"

}

# ---------------------------------------------------------------------------
# Module: Session
# ---------------------------------------------------------------------------
subcmd_session() {
set -euo pipefail

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi

HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
WANT="${1:-${TVPC_SESSION:-auto}}"

WAYLAND_DIRS=(/usr/local/share/wayland-sessions /usr/share/wayland-sessions)
X11_DIRS=(/usr/local/share/xsessions /usr/share/xsessions)

# Preference order for "auto".
#
# Plasma Mobile is NOT first. On Ubuntu 24.04 it is Plasma 5.27 built for
# touchscreens: with no touch input and a CEC remote it is barely navigable,
# and when its shell (plasma-nano) fails to start, kwin_wayland stays up
# showing a black root window and a pointer — the exact reported symptom.
# Plain Plasma Wayland is the tested path on this hardware; ask for
# plasma-mobile explicitly if you want to try it.
AUTO_ORDER=(plasma plasma-mobile plasma-x11 kiosk)

session_file() {   # $1 = session id -> echoes "<desktop-file>|<wayland|x11>"
  case "$1" in
    plasma)        echo "plasmawayland.desktop|wayland" ;;
    plasma-mobile) echo "plasma-mobile.desktop|wayland" ;;
    plasma-x11)    echo "plasma.desktop|x11" ;;
    kiosk)         echo "tvpc-kiosk.desktop|wayland" ;;
    # Opt-in, not in AUTO_ORDER. Install the session first; the check below
    # refuses to point autologin at a session that is not on disk.
    #   hypr      -> sudo ./scripts/tvpc-hyprland.sh  (Hyprland, TV-tuned)
    #   bigscreen -> apt install plasma-bigscreen     (KDE's TV shell, remote-first)
    #   phosh     -> apt install phosh                (GNOME's phone shell)
    hypr)          echo "tvpc-hypr.desktop|wayland" ;;
    bigscreen)     echo "plasma-bigscreen-wayland.desktop|wayland" ;;
    bigscreen-x11) echo "plasma-bigscreen-x11.desktop|x11" ;;
    phosh)         echo "phosh.desktop|wayland" ;;
    *)             return 1 ;;
  esac
}

# Echoes the full path if the session's .desktop file is installed.
locate_session() {
  local spec file type dirs=()
  spec="$(session_file "$1")" || return 1
  file="${spec%%|*}"; type="${spec##*|}"
  if [[ $type == wayland ]]; then dirs=("${WAYLAND_DIRS[@]}"); else dirs=("${X11_DIRS[@]}"); fi
  local d
  for d in "${dirs[@]}"; do
    [[ -f "$d/$file" ]] && { echo "$d/$file"; return 0; }
  done
  return 1
}

# --- the kiosk fallback -----------------------------------------------------
# Last resort so a broken Plasma never means a blank TV: kwin_wayland plus one
# application, no shell, no panel. Enough to see that the machine is alive and
# to reach a terminal.
install_kiosk_session() {
  install -d /usr/local/bin /usr/share/wayland-sessions

  cat >/usr/local/bin/tvpc-kiosk-app <<'KIOSKAPP'
#!/usr/bin/env bash
# Single application for the tvpc kiosk session, most-wanted first.
if flatpak info io.github.vacuumtube.VacuumTube >/dev/null 2>&1; then
  exec flatpak run io.github.vacuumtube.VacuumTube \
       --enable-features=VaapiVideoDecoder --ozone-platform-hint=auto
fi
for term in konsole xterm x-terminal-emulator; do
  command -v "$term" >/dev/null 2>&1 && exec "$term"
done
# Nothing to run: hold the session open so the compositor does not exit into
# a blank screen, and say so on the console.
echo "tvpc kiosk: no application available (install VacuumTube or konsole)" >&2
exec sleep infinity
KIOSKAPP
  chmod 0755 /usr/local/bin/tvpc-kiosk-app

  cat >/usr/local/bin/tvpc-kiosk-session <<'KIOSKSESSION'
#!/usr/bin/env bash
exec kwin_wayland --xwayland --exit-with-session=/usr/local/bin/tvpc-kiosk-app
KIOSKSESSION
  chmod 0755 /usr/local/bin/tvpc-kiosk-session

  cat >/usr/share/wayland-sessions/tvpc-kiosk.desktop <<'KIOSKDESKTOP'
[Desktop Entry]
Name=tvpc kiosk (fallback)
Comment=kwin_wayland plus a single app — used when Plasma will not start
Exec=/usr/local/bin/tvpc-kiosk-session
TryExec=/usr/local/bin/tvpc-kiosk-session
Type=Application
DesktopNames=KDE
KIOSKDESKTOP
}

# --- resolve ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }

if command -v kwin_wayland >/dev/null 2>&1; then install_kiosk_session; fi

CHOSEN="" CHOSEN_PATH=""
if [[ $WANT == auto ]]; then
  for candidate in "${AUTO_ORDER[@]}"; do
    if CHOSEN_PATH="$(locate_session "$candidate")"; then CHOSEN="$candidate"; break; fi
  done
else
  session_file "$WANT" >/dev/null || {
    echo "Unknown session '$WANT'. Known: auto plasma plasma-mobile plasma-x11" >&2
    echo "                              kiosk hypr bigscreen bigscreen-x11 phosh" >&2
    exit 1
  }
  if ! CHOSEN_PATH="$(locate_session "$WANT")"; then
    echo "Requested session '$WANT' is not installed on this system." >&2
    echo "Installed sessions:" >&2
    ls -1 "${WAYLAND_DIRS[@]}" "${X11_DIRS[@]}" 2>/dev/null | sed 's/^/  /' >&2 || true
    exit 1
  fi
  CHOSEN="$WANT"
fi

if [[ -z $CHOSEN ]]; then
  echo "No usable graphical session found. Nothing would start at boot." >&2
  echo "Install one:  sudo apt-get install plasma-workspace-wayland plasma-desktop" >&2
  exit 1
fi

SESSION_DESKTOP="$(basename "$CHOSEN_PATH")"
echo "Session: $CHOSEN  ($CHOSEN_PATH)"

# --- write SDDM autologin ---------------------------------------------------
id "$HTPC_USER" >/dev/null 2>&1 || { echo "User '$HTPC_USER' does not exist" >&2; exit 1; }

install -d /etc/sddm.conf.d
# Drop the old hand-written file so two configs cannot disagree.
rm -f /etc/sddm.conf.d/autologin.conf

cat >/etc/sddm.conf.d/10-tvpc.conf <<EOF
# Generated by tvpc-session.sh — re-run that script instead of editing.
[Autologin]
User=$HTPC_USER
Session=$SESSION_DESKTOP
Relogin=false

[Theme]
Current=breeze

[General]
# Plasma Mobile drags in maliit-keyboard; an on-screen keyboard popping up on
# a TV with no touchscreen is not helpful.
InputMethod=
EOF

# --- make sure something actually starts it ---------------------------------
# This is an Ubuntu Server base: its default target is multi-user.target, so a
# display manager can be installed, enabled and still never run.
if [[ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]]; then
  systemctl set-default graphical.target
  echo "Default systemd target -> graphical.target"
fi
echo "/usr/bin/sddm" >/etc/X11/default-display-manager 2>/dev/null || true
systemctl enable sddm.service >/dev/null 2>&1 || true

# Record the choice so a later re-run, and /etc/default/tvpc, agree.
if [[ -f /etc/default/tvpc && $WANT != auto ]]; then
  if grep -q '^TVPC_SESSION=' /etc/default/tvpc; then
    sed -i "s/^TVPC_SESSION=.*/TVPC_SESSION=$CHOSEN/" /etc/default/tvpc
  else
    echo "TVPC_SESSION=$CHOSEN" >>/etc/default/tvpc
  fi
  echo "Recorded TVPC_SESSION=$CHOSEN in /etc/default/tvpc"
fi

echo "Autologin: $HTPC_USER -> $SESSION_DESKTOP"

}

# ---------------------------------------------------------------------------
# Module: Bigscreen
# ---------------------------------------------------------------------------
subcmd_bigscreen() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

MODE=install
ARG="${2:-}"
case "${1:-}" in
  --check)     MODE=check ;;
  --switch)    MODE=switch ;;
  --remove)    MODE=remove ;;
  --list-apps) MODE=listapps ;;
  --ui-scale)  MODE=uiscale ;;
  --topbar)    MODE=topbar ;;
  --theme)     MODE=theme ;;
  --hide)      MODE=hide ;;
  --show)      MODE=show ;;
  "")          ;;
  *) echo "Unknown option '$1' (try --help)" >&2; exit 1 ;;
esac

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

WAYLAND_SESSION=/usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop
X11_SESSION=/usr/share/xsessions/plasma-bigscreen-x11.desktop

# Runtime QML modules that plasma-bigscreen imports but does NOT declare in
# its Depends. On a desktop install these are already present as a side
# effect of everything else; on this server-based build they are not, and
# the shell starts and then dies with "error loading QML file".
#
# The list was derived from the imports in the v5.27.11 source (the version
# noble ships) rather than found one crash at a time:
#   grep -rhoE '^\s*import [A-Za-z0-9_.]+' --include='*.qml' .
BIGSCREEN_QML_DEPS=(
  kdeconnect                              # org.kde.kdeconnect            (8 imports)
  qml-module-qtgraphicaleffects           # QtGraphicalEffects           (17 imports)
  qml-module-org-kde-kquickcontrolsaddons # org.kde.kquickcontrolsaddons  (7)
  qml-module-org-kde-kcm                  # org.kde.kcm                   (7)
  qml-module-org-kde-kirigami2            # org.kde.kirigami             (60)
  qml-module-org-kde-kitemmodels          # org.kde.kitemmodels
  qml-module-org-kde-kcoreaddons          # org.kde.kcoreaddons
  qml-module-qtmultimedia                 # QtMultimedia
  qml-module-qtquick-virtualkeyboard      # QtQuick.VirtualKeyboard
  plasma-settings                         # org.kde.plasma.settings
  plasma-pa                               # org.kde.plasma.private.volume
)

ok()  { echo "  ok    $*"; }
bad() { echo "  MISS  $*"; }

# apt-cache policy piped into `grep -q` is a trap under `set -o pipefail`:
# grep exits the moment it matches, apt-cache dies on SIGPIPE, and pipefail
# promotes that failure to the whole pipeline — so the test reports "no
# candidate" precisely BECAUSE it found one. Capture the output instead.
apt_has_candidate() {
  local policy
  policy="$(apt-cache policy "$1" 2>/dev/null)" || return 1
  [[ $policy == *"Candidate:"* ]] || return 1
  [[ $policy != *"Candidate: (none)"* ]]
}

pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
  [[ $st == "install ok installed" ]]
}

# ---------------------------------------------------------------------------
# Tuning helpers
# ---------------------------------------------------------------------------
user_home() { getent passwd "$HTPC_USER" | cut -d: -f6; }

# Bigscreen filters the app list in ApplicationListModel::loadApplications():
# it takes every KService application, drops Terminal=true ones, drops
# anything with NoDisplay, and drops names listed in the "blacklist" key of
# applications-blacklistrc. That last one is undocumented but it is the
# supported way to take an app off the home screen.
BLACKLIST_RC() { echo "$(user_home)/.config/applications-blacklistrc"; }

read_blacklist() {
  local rc; rc="$(BLACKLIST_RC)"
  [[ -f $rc ]] || return 0
  sed -n 's/^blacklist=//p' "$rc" | tr ',' '\n' | sed '/^$/d'
}

write_blacklist() {   # entries on stdin, one per line
  local rc list; rc="$(BLACKLIST_RC)"
  list="$(sort -u | sed '/^$/d' | paste -sd, -)"
  install -d -o "$HTPC_USER" -g "$HTPC_USER" "$(dirname "$rc")"
  cat >"$rc" <<RC
[Applications]
blacklist=$list
RC
  chown "$HTPC_USER:$HTPC_USER" "$rc"
  echo "$list"
}

# Every application the home screen would show, as Bigscreen selects them.
list_apps() {
  local d f id name nodisp term type
  for d in /usr/share/applications /usr/local/share/applications \
           "$(user_home)/.local/share/applications" \
           /var/lib/flatpak/exports/share/applications; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do
      [[ -f $f ]] || continue
      type="$(sed -n 's/^Type=//p'      "$f" | head -1)"
      nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
      term="$(sed -n 's/^Terminal=//p'  "$f" | head -1)"
      [[ $type == Application ]]  || continue
      [[ $nodisp == true ]]       && continue
      [[ $term == true ]]         && continue
      name="$(sed -n 's/^Name=//p' "$f" | head -1)"
      id="$(basename "$f" .desktop)"
      printf '%s\t%s\n' "$id" "$name"
    done
  done | sort -u
}

if [[ $MODE == listapps ]]; then
  [[ -n "$(user_home)" ]] || { echo "User '$HTPC_USER' has no home directory" >&2; exit 1; }
  mapfile -t HIDDEN < <(read_blacklist)
  printf '%-45s %-30s %s\n' "ID (use this with --hide)" "NAME" "STATE"
  while IFS=$'\t' read -r id name; do
    state="shown"
    for h in ${HIDDEN+"${HIDDEN[@]}"}; do [[ $h == "$id" ]] && state="HIDDEN"; done
    printf '%-45s %-30s %s\n' "$id" "${name:0:29}" "$state"
  done < <(list_apps)
  exit 0
fi

if [[ $MODE == hide || $MODE == show ]]; then
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }
  [[ -n $ARG ]] || { echo "Usage: $0 --$MODE app1[,app2,...]  (ids from --list-apps)" >&2; exit 1; }
  mapfile -t CURRENT < <(read_blacklist)
  IFS=',' read -r -a WANT <<<"$ARG"
  if [[ $MODE == hide ]]; then
    NEW="$(printf '%s\n' ${CURRENT+"${CURRENT[@]}"} "${WANT[@]}" | write_blacklist)"
  else
    KEEP=()
    for c in ${CURRENT+"${CURRENT[@]}"}; do
      drop=0
      for w in "${WANT[@]}"; do [[ $c == "$w" ]] && drop=1; done
      [[ $drop -eq 0 ]] && KEEP+=("$c")
    done
    NEW="$(printf '%s\n' ${KEEP+"${KEEP[@]}"} | write_blacklist)"
  fi
  echo "Hidden from the home screen: ${NEW:-(none)}"
  echo "Log out and back in, or: sudo systemctl restart sddm"
  exit 0
fi

if [[ $MODE == uiscale ]]; then
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }
  [[ $ARG =~ ^[0-9]+$ ]] || { echo "Usage: $0 --ui-scale <point-size>   (Bigscreen: try 10)" >&2; exit 1; }
  HOME_DIR="$(user_home)"
  [[ -n $HOME_DIR ]] || { echo "User '$HTPC_USER' has no home directory" >&2; exit 1; }
  KG="$HOME_DIR/.config/kdeglobals"
  install -d -o "$HTPC_USER" -g "$HTPC_USER" "$HOME_DIR/.config"
  [[ -f $KG ]] || printf '[General]\n' >"$KG"
  # Every Kirigami margin and tile derives from Kirigami.Units.gridUnit,
  # which is font metrics — so the base font size scales the whole shell.
  sed -i \
    -e "s/^font=.*/font=Noto Sans,$ARG,-1,5,50,0,0,0,0,0/" \
    -e "s/^menuFont=.*/menuFont=Noto Sans,$ARG,-1,5,50,0,0,0,0,0/" \
    -e "s/^fixed=.*/fixed=Noto Sans Mono,$((ARG - 1)),-1,5,50,0,0,0,0,0/" \
    -e "s/^toolBarFont=.*/toolBarFont=Noto Sans,$((ARG - 1)),-1,5,50,0,0,0,0,0/" \
    -e "s/^smallestReadableFont=.*/smallestReadableFont=Noto Sans,$((ARG - 2)),-1,5,50,0,0,0,0,0/" \
    "$KG"
  grep -q '^font=' "$KG" || sed -i "/^\[General\]/a font=Noto Sans,$ARG,-1,5,50,0,0,0,0,0" "$KG"
  chown "$HTPC_USER:$HTPC_USER" "$KG"
  # Persist it so customize.sh does not put the old size back on its next run.
  if [[ -f /etc/default/tvpc ]]; then
    if grep -q '^TVPC_FONT_SIZE=' /etc/default/tvpc; then
      sed -i "s/^TVPC_FONT_SIZE=.*/TVPC_FONT_SIZE=$ARG/" /etc/default/tvpc
    else
      echo "TVPC_FONT_SIZE=$ARG" >>/etc/default/tvpc
    fi
  fi
  echo "Base font size -> $ARG (was scaling the whole Bigscreen UI)"
  echo "Recorded TVPC_FONT_SIZE=$ARG in /etc/default/tvpc"
  echo "Log out and back in, or: sudo systemctl restart sddm"
  exit 0
fi

if [[ $MODE == theme ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  THEME_TOOL=""
  if command -v subcmd_theme >/dev/null 2>&1; then subcmd_theme set "$t"; return; fi
  for cand in "$SCRIPT_DIR/tvpc.sh" /usr/local/bin/tvpc-bigscreen-theme /usr/local/bin/tvpc; do
    [[ -x $cand ]] && { THEME_TOOL="$cand"; break; }
  done
  if [[ -z $THEME_TOOL ]]; then
    echo "tvpc-bigscreen-theme tool not found" >&2; exit 1
  fi
  if [[ -n $ARG ]]; then
    "$THEME_TOOL" set "$ARG"
  else
    "$THEME_TOOL" list
  fi
  exit 0
fi

if [[ $MODE == topbar ]]; then
  MAIN_QML="/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen/contents/ui/main.qml"
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0 --topbar ...) — the file is owned by root." >&2; exit 1; }
  [[ -f $MAIN_QML ]] || { echo "Not found: $MAIN_QML" >&2; echo "Is plasma-bigscreen installed?" >&2; exit 1; }
  BAK="${MAIN_QML}.tvpc-bak"

  case "${ARG:-large}" in
    --revert|revert)
      if [[ -f $BAK ]]; then
        cp -a "$BAK" "$MAIN_QML"
        echo "Reverted top bar to original."
      else
        echo "No backup at $BAK — nothing to revert." >&2
        exit 1
      fi
      exit 0 ;;
    xl|huge)   TARGET="huge"  ;;
    ""|normal|large) TARGET="large" ;;
    *) echo "Usage: $0 --topbar [large|huge|revert]" >&2; exit 1 ;;
  esac

  if [[ ! -f $BAK ]]; then
    cp -a "$MAIN_QML" "$BAK"
    echo "Backup -> $BAK"
  fi

  if grep -q 'iconSizes\.medium + Kirigami\.Units\.smallSpacing \* 2' "$MAIN_QML"; then
    sed -i "s/iconSizes\.medium + Kirigami\.Units\.smallSpacing \* 2/iconSizes.${TARGET} + Kirigami.Units.smallSpacing * 2/" "$MAIN_QML"
    echo "Patched topBar.height: medium -> ${TARGET}"
  elif grep -q "iconSizes\.${TARGET} + Kirigami\.Units\.smallSpacing" "$MAIN_QML"; then
    echo "Already patched to '${TARGET}'. (run with revert to undo first)"
  else
    echo "Could not find the expected top-bar height line." >&2
    exit 1
  fi
  echo "Log out and back in (or restart the Bigscreen session) to see the change."
  exit 0
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  echo "== Plasma Bigscreen =="
  if pkg_installed plasma-bigscreen; then
    ok "plasma-bigscreen $(dpkg-query -W -f='${Version}' plasma-bigscreen 2>/dev/null)"
  else
    bad "plasma-bigscreen not installed"
  fi
  MISSING_QML=()
  for p in "${BIGSCREEN_QML_DEPS[@]}"; do
    pkg_installed "$p" || MISSING_QML+=("$p")
  done
  if [[ ${#MISSING_QML[@]} -eq 0 ]]; then
    ok "QML runtime modules present"
  else
    bad "missing QML modules: ${MISSING_QML[*]}"
  fi
  if [[ -f $WAYLAND_SESSION ]]; then ok "Wayland session $WAYLAND_SESSION"; else bad "Wayland session $WAYLAND_SESSION"; fi
  if [[ -f $X11_SESSION     ]]; then ok "X11 session $X11_SESSION";         else bad "X11 session $X11_SESSION"; fi
  echo
  echo "Active session: ${TVPC_SESSION:-unset}"
  echo "  switch with:  sudo tvpc-session bigscreen       (Wayland)"
  echo "                sudo tvpc-session bigscreen-x11   (X11 fallback)"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --remove
# ---------------------------------------------------------------------------
if [[ $MODE == remove ]]; then
  case "${TVPC_SESSION:-}" in
    bigscreen|bigscreen-x11)
      echo "!! TVPC_SESSION is '$TVPC_SESSION'. Point it somewhere that exists first:"
      echo "     sudo tvpc-session plasma"
      exit 1 ;;
  esac
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y plasma-bigscreen || exit 1
  apt-get autoremove -y || true
  echo "Done. The Plasma session is untouched."
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

# plasma-bigscreen lives in universe. On a stock Ubuntu Server that is
# already enabled; on a trimmed sources list it may not be.
if ! apt_has_candidate plasma-bigscreen; then
  echo "== Enabling the universe component =="
  if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y universe || true
  fi
  apt-get update
fi

if ! apt_has_candidate plasma-bigscreen; then
  # Show the diagnosis rather than asking for it. plasma-bigscreen lives in
  # the noble RELEASE pocket (noble/universe), not noble-updates, so having
  # universe on noble-updates alone is not enough — and that is exactly the
  # state add-apt-repository can leave behind when sources are split across
  # sources.list and a deb822 .sources file.
  echo >&2
  echo "!! No installable plasma-bigscreen." >&2
  echo >&2
  echo "   apt-cache policy says:" >&2
  apt-cache policy plasma-bigscreen 2>&1 | sed 's/^/     /' >&2
  echo >&2
  echo "   Enabled components (need 'universe' on the plain 'noble' suite," >&2
  echo "   not just noble-updates):" >&2
  {
    grep -rhs -E '^(deb|Components|Suites|URIs)' \
      /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
      | grep -v '^\s*#'
  } | sed 's/^/     /' >&2
  echo >&2
  echo "   If 'universe' is missing from the noble suite, add it:" >&2
  echo "     sudo sed -i 's/^Components: main restricted$/Components: main restricted universe multiverse/' \\" >&2
  echo "       /etc/apt/sources.list.d/ubuntu.sources" >&2
  echo "     sudo apt-get update" >&2
  exit 1
fi

echo "== Installing Plasma Bigscreen =="
# Exit status is checked, unlike the first cut of the Hyprland installer.
# Everything here is archive-native at the Plasma version already present,
# so a failure means something is genuinely wrong rather than an ABI clash.
if ! apt-get install -y plasma-bigscreen; then
  echo
  echo "!! apt could not install plasma-bigscreen (see the error above)." >&2
  echo "   Nothing was changed. The current session is untouched." >&2
  exit 1
fi

echo "== Installing the QML modules Bigscreen forgets to depend on =="
QML_HAVE=() QML_MISSING=()
for p in "${BIGSCREEN_QML_DEPS[@]}"; do
  if apt_has_candidate "$p"; then QML_HAVE+=("$p"); else QML_MISSING+=("$p"); fi
done
if [[ ${#QML_MISSING[@]} -gt 0 ]]; then
  echo "!! not available, skipping: ${QML_MISSING[*]}"
fi
if [[ ${#QML_HAVE[@]} -gt 0 ]]; then
  # Non-fatal: a missing QML module degrades a settings page, it does not
  # stop the shell coming up, and the session check below is what matters.
  apt-get install -y "${QML_HAVE[@]}" || echo "!! some QML modules failed to install"
fi

# The session files are the whole point: tvpc-session refuses to point
# autologin at a .desktop that is not on disk, so confirm them here rather
# than discovering it at the next boot.
MISSING=0
if [[ -f $WAYLAND_SESSION ]]; then ok "Wayland session installed"; else bad "$WAYLAND_SESSION"; MISSING=1; fi
if [[ -f $X11_SESSION     ]]; then ok "X11 session installed";     else bad "$X11_SESSION";     MISSING=1; fi
if [[ $MISSING -eq 1 ]]; then
  echo
  echo "!! plasma-bigscreen installed but its session files are not where" >&2
  echo "   expected. Not switching anything." >&2
  exit 1
fi

echo "== Applying modern Bigscreen homescreen and theme =="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_TOOL=""
if command -v subcmd_theme >/dev/null 2>&1; then subcmd_theme set "$t"; return; fi
  for cand in "$SCRIPT_DIR/tvpc.sh" /usr/local/bin/tvpc-bigscreen-theme /usr/local/bin/tvpc; do
  [[ -x $cand ]] && { THEME_TOOL="$cand"; break; }
done
if [[ -n $THEME_TOOL ]]; then
  "$THEME_TOOL" install || echo "!! could not install modern homescreen overlay"
  "$THEME_TOOL" set "${TVPC_BIGSCREEN_THEME:-midnight}" || true
fi

# Bigscreen needs the same "never blank the TV" treatment as Plasma. That
# lives in customize.sh, which seeds both /etc/skel and the live user, so
# just make sure it has been run rather than duplicating the settings.
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
if [[ -n $HOME_DIR && ! -f "$HOME_DIR/.config/powermanagementprofilesrc" ]]; then
  echo
  echo "!! $HTPC_USER has no powermanagementprofilesrc — the TV will blank"
  echo "   after a few minutes idle, which looks just like a boot failure."
  echo "   Fix with:  sudo ./scripts/customize.sh"
fi

if [[ $MODE == switch ]]; then
  echo
  echo "== Switching the session =="
  SESSION_TOOL=""
  if command -v subcmd_session >/dev/null 2>&1; then subcmd_session "$@"; return; fi
  for cand in "$SCRIPT_DIR/tvpc.sh" /usr/local/bin/tvpc-session /usr/local/bin/tvpc; do
    [[ -x $cand ]] && { SESSION_TOOL="$cand"; break; }
  done
  if [[ -z $SESSION_TOOL ]]; then
    echo "!! tvpc-session not found; switch manually: sudo tvpc-session bigscreen" >&2
    exit 1
  fi
  "$SESSION_TOOL" bigscreen || exit 1
  echo
  echo "Restart the display manager to pick it up:"
  echo "  sudo systemctl restart sddm"
  exit 0
fi

cat <<NEXT

Installed. The running session has not been changed.

  Try it:    sudo tvpc-session bigscreen && sudo systemctl restart sddm
  X11 too:   sudo tvpc-session bigscreen-x11    (if Wayland misbehaves)
  Go back:   sudo tvpc-session plasma && sudo systemctl restart sddm

The CEC remote drives this one as-is: Bigscreen navigates on plain arrow
keys and Enter, which is exactly what the listener already sends.
NEXT

}

# ---------------------------------------------------------------------------
# Module: Bigscreen Themes
# ---------------------------------------------------------------------------
subcmd_theme() {
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS_CONF="/etc/tvpc/bigscreen-theme.json"
SYS_DEFAULT="/etc/default/tvpc"
SYS_PLASMOID_DIR="/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"
SYS_BACKUP_DIR="/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen.tvpc-orig"
OVERLAY_SRC="$REPO_ROOT/overlays/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"

if [[ -r "$SYS_DEFAULT" ]]; then
    # shellcheck source=/dev/null
    . "$SYS_DEFAULT"
fi
TVPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

get_user_home() {
    if [[ $EUID -eq 0 ]]; then
        local h; h="$(getent passwd "$TVPC_USER" | cut -d: -f6 || true)"
        if [[ -n "$h" && -d "$h" ]]; then
            echo "$h"
        else
            echo "${HOME:-/home/$TVPC_USER}"
        fi
    else
        echo "${HOME:-/home/$USER}"
    fi
}

USER_CONF="$(get_user_home)/.config/tvpc/bigscreen-theme.json"
USER_PLASMOID_DIR="$(get_user_home)/.local/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"

THEMES=(
    "midnight:Midnight Glass:Deep obsidian & frosted navy with vibrant sky-blue glow (Default)"
    "oled:OLED Stealth:Pure pitch black with high-contrast monochrome & silver accents"
    "cyberpunk:Cyberpunk Neon:Dark violet glass with electric magenta & neon cyan accents"
    "sunset:Sunset Amber:Dark charcoal glass with warm amber & radiant sunset glow"
    "emerald:Emerald Pine:Deep forest glass with lush mint & emerald accents"
)

get_active_theme() {
    local t=""
    if [[ -f "$USER_CONF" ]]; then
        t="$(grep -o '"theme": *"[^"]*"' "$USER_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    fi
    if [[ -z "$t" && -f "$SYS_CONF" ]]; then
        t="$(grep -o '"theme": *"[^"]*"' "$SYS_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    fi
    if [[ -z "$t" && -n "${TVPC_BIGSCREEN_THEME:-}" ]]; then
        t="$TVPC_BIGSCREEN_THEME"
    fi
    echo "${t:-midnight}"
}

cmd_list() {
    local active; active="$(get_active_theme)"
    echo "============================================================"
    echo "  Plasma Bigscreen Modern Themes"
    echo "============================================================"
    printf "%-12s %-18s %-6s %s\n" "ID" "NAME" "STATE" "DESCRIPTION"
    printf "%-12s %-18s %-6s %s\n" "------------" "------------------" "------" "----------------------------------------"
    for item in "${THEMES[@]}"; do
        IFS=":" read -r id name desc <<<"$item"
        local mark="      "
        if [[ "$id" == "$active" ]]; then
            mark="[ACTIVE]"
        fi
        printf "%-12s %-18s %-6s %s\n" "$id" "$name" "$mark" "$desc"
    done
    echo
    echo "Switch theme with:  tvpc-bigscreen-theme set <id>"
}

cmd_set() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "Usage: tvpc-bigscreen-theme set <theme-id>" >&2
        echo "Valid themes: midnight, oled, cyberpunk, sunset, emerald" >&2
        exit 1
    fi

    local valid=0
    for item in "${THEMES[@]}"; do
        IFS=":" read -r id name desc <<<"$item"
        if [[ "$id" == "$target" ]]; then
            valid=1
            break
        fi
    done

    if [[ $valid -eq 0 ]]; then
        echo "Error: Unknown theme '$target'." >&2
        echo "Available themes: midnight, oled, cyberpunk, sunset, emerald" >&2
        exit 1
    fi

    # Write configuration
    local json="{\n  \"theme\": \"$target\",\n  \"updated_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"\n}\n"

    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$(dirname "$SYS_CONF")"
        printf "%b" "$json" >"$SYS_CONF"
        chmod 0644 "$SYS_CONF"
        
        # Also persist in /etc/default/tvpc
        if [[ -f "$SYS_DEFAULT" ]]; then
            if grep -q '^TVPC_BIGSCREEN_THEME=' "$SYS_DEFAULT"; then
                sed -i "s/^TVPC_BIGSCREEN_THEME=.*/TVPC_BIGSCREEN_THEME=$target/" "$SYS_DEFAULT"
            else
                echo "TVPC_BIGSCREEN_THEME=$target" >>"$SYS_DEFAULT"
            fi
        fi

        # Seed user config as well
        local uh; uh="$(get_user_home)"
        if [[ -d "$uh" ]]; then
            mkdir -p "$uh/.config/tvpc"
            printf "%b" "$json" >"$uh/.config/tvpc/bigscreen-theme.json"
            chown -R "$TVPC_USER:$TVPC_USER" "$uh/.config/tvpc" 2>/dev/null || true
        fi
    else
        mkdir -p "$(dirname "$USER_CONF")"
        printf "%b" "$json" >"$USER_CONF"
    fi

    echo "Theme successfully set to: $target ($name)"
    if pgrep -x plasma-bigscreen >/dev/null 2>&1 || pgrep -x plasmashell >/dev/null 2>&1; then
        echo "Restart display session or restart Bigscreen to view theme changes."
    fi
}

apply_window_controls() {
    local target_dir="$1"
    mkdir -p "$target_dir"
    
    local kwinrc="$target_dir/kwinrc"
    if [[ ! -f "$kwinrc" ]]; then
        cat >"$kwinrc" <<'EOF'
[Windows]
BorderlessMaximizedWindows=false

[org.kde.kdecoration2]
BorderSize=Normal
ButtonsOnLeft=
ButtonsOnRight=X
CloseOnDoubleClickOnMenu=false
library=org.kde.breeze
theme=Breeze

[TabBox]
ActivitiesMode=1
ApplicationsMode=0
DesktopMode=0
HighlightWindows=true
LayoutName=thumbnail_grid
MultiScreenMode=0
OrderMinimizedMode=0
ShowDelay=false
ShowDesktop=true
SwitchingMode=0
EOF
    else
        if grep -q '^\[Windows\]' "$kwinrc"; then
            sed -i '/^\[Windows\]/a BorderlessMaximizedWindows=false' "$kwinrc"
        else
            printf '\n[Windows]\nBorderlessMaximizedWindows=false\n' >>"$kwinrc"
        fi
        if grep -q '^\[org\.kde\.kdecoration2\]' "$kwinrc"; then
            sed -i 's/^ButtonsOnRight=.*/ButtonsOnRight=X/' "$kwinrc"
        else
            printf '\n[org.kde.kdecoration2]\nButtonsOnRight=X\nlibrary=org.kde.breeze\ntheme=Breeze\n' >>"$kwinrc"
        fi
        if ! grep -q '^\[TabBox\]' "$kwinrc"; then
            cat >>"$kwinrc" <<'EOF'

[TabBox]
ActivitiesMode=1
ApplicationsMode=0
DesktopMode=0
HighlightWindows=true
LayoutName=thumbnail_grid
MultiScreenMode=0
OrderMinimizedMode=0
ShowDelay=false
ShowDesktop=true
SwitchingMode=0
EOF
        fi
    fi

    local kg="$target_dir/kglobalshortcutsrc"
    if [[ ! -f "$kg" ]]; then
        cat >"$kg" <<'EOF'
[kwin]
Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows
Walk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)
Walk Through Windows Alternative=none,,Walk Through Windows Alternative
Walk Through Windows Alternative (Reverse)=none,,Walk Through Windows Alternative (Reverse)
Window Close=Alt+F4,Alt+F4,Close Window
Show Desktop=Meta+D,Meta+D,Show Desktop
EOF
    else
        if ! grep -q 'Walk Through Windows=' "$kg"; then
            if grep -q '^\[kwin\]' "$kg"; then
                sed -i '/^\[kwin\]/a Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows\nWalk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)\nWindow Close=Alt+F4,Alt+F4,Close Window' "$kg"
            else
                cat >>"$kg" <<'EOF'

[kwin]
Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows
Walk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)
Window Close=Alt+F4,Alt+F4,Close Window
EOF
            fi
        fi
    fi
}

cmd_install() {
    if [[ ! -d "$OVERLAY_SRC" ]]; then
        echo "Error: Source overlay directory not found at $OVERLAY_SRC" >&2
        exit 1
    fi

    if [[ $EUID -eq 0 ]]; then
        echo "== Installing Modern Bigscreen Homescreen (System-Wide) =="
        if [[ -d "$SYS_PLASMOID_DIR" && ! -d "$SYS_BACKUP_DIR" ]]; then
            echo "Backing up upstream Bigscreen homescreen -> $SYS_BACKUP_DIR"
            cp -a "$SYS_PLASMOID_DIR" "$SYS_BACKUP_DIR"
        fi

        mkdir -p "$SYS_PLASMOID_DIR"
        cp -a "$OVERLAY_SRC/." "$SYS_PLASMOID_DIR/"
        echo "Successfully deployed modern homescreen to $SYS_PLASMOID_DIR"

        apply_window_controls "/etc/skel/.config"
        local uh; uh="$(get_user_home)"
        if [[ -d "$uh" ]]; then
            apply_window_controls "$uh/.config"
            chown -R "$TVPC_USER:$TVPC_USER" "$uh/.config" 2>/dev/null || true
        fi
        echo "Configured Alt+Tab app switcher and Close X button in kwinrc/kglobalshortcutsrc"
    else
        echo "== Installing Modern Bigscreen Homescreen (User Override) =="
        mkdir -p "$USER_PLASMOID_DIR"
        cp -a "$OVERLAY_SRC/." "$USER_PLASMOID_DIR/"
        echo "Successfully deployed modern homescreen to $USER_PLASMOID_DIR"
        apply_window_controls "$(get_user_home)/.config"
        echo "Configured user Alt+Tab app switcher and Close X button"
        echo "(Tip: Run with sudo to install system-wide across all users)"
    fi
}

cmd_revert() {
    if [[ $EUID -eq 0 ]]; then
        if [[ -d "$SYS_BACKUP_DIR" ]]; then
            echo "Restoring original upstream Bigscreen homescreen from $SYS_BACKUP_DIR..."
            rm -rf "$SYS_PLASMOID_DIR"
            cp -a "$SYS_BACKUP_DIR" "$SYS_PLASMOID_DIR"
            rm -rf "$SYS_BACKUP_DIR"
            echo "Reverted system Bigscreen homescreen to upstream stock."
        else
            echo "No backup found at $SYS_BACKUP_DIR. Nothing to revert system-wide."
        fi
    fi

    if [[ -d "$USER_PLASMOID_DIR" ]]; then
        echo "Removing user override at $USER_PLASMOID_DIR..."
        rm -rf "$USER_PLASMOID_DIR"
        echo "Removed user override."
    fi
    echo "Revert complete."
}

cmd_status() {
    local active; active="$(get_active_theme)"
    echo "== Plasma Bigscreen Theme Status =="
    echo "Active Theme       : $active"
    echo "Config (System)    : $( [[ -f "$SYS_CONF" ]] && echo "Present ($SYS_CONF)" || echo "None" )"
    echo "Config (User)      : $( [[ -f "$USER_CONF" ]] && echo "Present ($USER_CONF)" || echo "None" )"
    echo "System Plasmoid    : $( [[ -f "$SYS_PLASMOID_DIR/contents/ui/Theme.qml" ]] && echo "MODERNIZED" || echo "Upstream / Stock" )"
    echo "System Backup      : $( [[ -d "$SYS_BACKUP_DIR" ]] && echo "Available ($SYS_BACKUP_DIR)" || echo "None" )"
    echo "User Plasmoid      : $( [[ -f "$USER_PLASMOID_DIR/contents/ui/Theme.qml" ]] && echo "Installed" || echo "Not Installed" )"
}

cmd_preview() {
    local t="${1:-$(get_active_theme)}"
    echo "== Theme Preview: $t =="
    case "$t" in
        midnight)
            echo "  Background: #0a0e17 (Obsidian Navy)"
            echo "  Surface   : rgba(22, 31, 48, 0.65) (Frosted Glass)"
            echo "  Accent    : #0ea5e9 / #38bdf8 (Sky Cyan Glow)"
            echo "  Text      : #f8fafc (Crisp Slate White)"
            ;;
        oled)
            echo "  Background: #000000 (Pure Black)"
            echo "  Surface   : rgba(18, 18, 18, 0.85) (Deep Smoke)"
            echo "  Accent    : #ffffff (Silver / Diamond Focus)"
            echo "  Text      : #ffffff (True White)"
            ;;
        cyberpunk)
            echo "  Background: #090514 (Deep Violet)"
            echo "  Surface   : rgba(28, 15, 48, 0.72) (Neon Glass)"
            echo "  Accent    : #f43f5e / #06b6d4 (Magenta / Cyan Glow)"
            echo "  Text      : #fdf4ff (Neon Lavender)"
            ;;
        sunset)
            echo "  Background: #140c0a (Dark Charcoal)"
            echo "  Surface   : rgba(38, 22, 18, 0.72) (Warm Amber Glass)"
            echo "  Accent    : #f59e0b / #f97316 (Golden Amber & Sunset Orange)"
            echo "  Text      : #fff7ed (Warm Ivory)"
            ;;
        emerald)
            echo "  Background: #06140f (Deep Forest)"
            echo "  Surface   : rgba(13, 38, 28, 0.72) (Emerald Frosted Glass)"
            echo "  Accent    : #10b981 / #34d399 (Vibrant Emerald & Mint)"
            echo "  Text      : #ecfdf5 (Cool Mint White)"
            ;;
        *)
            echo "Unknown theme '$t'"
            ;;
    esac
}

case "${1:-}" in
    list)
        cmd_list ;;
    set)
        shift; cmd_set "${1:-}" ;;
    install)
        cmd_install ;;
    revert)
        cmd_revert ;;
    status)
        cmd_status ;;
    preview)
        shift; cmd_preview "${1:-}" ;;
    --help|-h|"")
        sed -n '2,11p' "$0" | sed 's/^# \?//'
        ;;
    *)
        echo "Unknown option '$1' (try --help)" >&2
        exit 1
        ;;
esac

}

# ---------------------------------------------------------------------------
# Module: Cameras
# ---------------------------------------------------------------------------
subcmd_cameras() {
set -euo pipefail

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tvpc"
CONF_FILE="$CONF_DIR/cameras.conf"
PIP_W=480
PIP_H=270
PIP_MARGIN=24

have() { command -v "$1" >/dev/null 2>&1; }

# --- Config ---------------------------------------------------------------
ensure_conf() { mkdir -p "$CONF_DIR"; [[ -f $CONF_FILE ]] || : >"$CONF_FILE"; }

read_cameras() {
    ensure_conf
    local i=0 line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == \#* || -z $line ]] && continue
        echo "$i|$line"
        i=$((i + 1))
    done <"$CONF_FILE"
}

write_cameras() {
    # stdin: lines of "NAME|URL|USER|PASS|NOTES"
    ensure_conf
    tee "$CONF_FILE" >/dev/null
}

get_camera() {
    local id="$1"
    read_cameras | awk -F'|' -v want="$id" '$1==want {for(i=2;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|"); print ""; exit}'
}

# --- Discovery ------------------------------------------------------------
local_subnet() {
    # Print the /24 base for the default route's interface, e.g. 192.168.1
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {split($(i+1),a,"."); print a[1]"."a[2]"."a[3]; exit}}'
}

# Try a URL with ffprobe; returns 0 if it looks like a media stream.
probe_url() {
    local url="$1" user="${2:-}" pass="${3:-}"
    have ffprobe || return 1
    local args=(-v error -show_streams -of default=nw=1)
    if [[ -n $user ]]; then
        FFREPORT= ffmpeg_password="" \
        ffprobe -loglevel error -rtsp_transport tcp -i "$url" \
            -user "$user" -password "$pass" \
            -show_entries stream=codec_name -of csv=p=0 2>/dev/null \
            && return 0
    else
        timeout 5 ffprobe -v error -rtsp_transport tcp -i "$url" \
            -show_entries stream=codec_name -of csv=p=0 2>/dev/null \
            && return 0
    fi
    return 1
}

# Quick TCP port check.
tcp_open() {
    local host="$1" port="$2"
    timeout 1 bash -c ">/dev/tcp/$host/$port" 2>/dev/null
}

# Common RTSP stream paths to try
RTSP_PATHS=(
    "/Streaming/Channels/101"      # Hikvision main
    "/Streaming/Channels/1"        # Hikvision alt
    "/Streaming/Channels/102"      # Hikvision sub
    "/cam/realmonitor"             # Dahua
    "/onvif/Streaming/Channels/101"
    "/onvif/Streaming/Channels/1"
    "/live/main"                   # generic
    "/live/sub"                    # generic sub
    "/live/0/main"                 # Reolink
    "/h264Preview_01_main"         # Axis-like
    "/11"                          # Reolink alt
    "/stream1"                     # generic
    "/stream2"
    "/av0_0"                      # some Chinese cams
    "/video"                       # some MJPEG-over-RTSP
    "/"                            # root
)

scan_rtsp() {
    local subnet="$1" cred="$2"   # cred like "user:pass" or empty
    log "Probing $subnet.0/24 on TCP 554 (RTSP) — up to 30 s..."
    local host p ip
    for ip in $(seq 1 254); do
        host="$subnet.$ip"
        if tcp_open "$host" 554; then
            printf '  \033[1;33mRTSP\033[0m  %s  (port 554 open)\n' "$host"
            # Try common paths. If any works, this is a real camera.
            local path
            for path in "${RTSP_PATHS[@]}"; do
                local url="rtsp://$host$path"
                if probe_url "$url" $cred; then
                    printf '    \033[1;32mLIVE\033[0m  %s\n' "$url"
                    # Check if this is a DVR with multiple connected cameras
                    local dvr_ch
                    if [[ "$path" == *"/Streaming/Channels/101"* ]]; then
                        for dvr_ch in $(seq 2 16); do
                            local dvr_url="rtsp://$host/Streaming/Channels/${dvr_ch}01"
                            if probe_url "$dvr_url" $cred; then
                                printf '    \033[1;35mDVR-CH%d\033[0m  %s\n' "$dvr_ch" "$dvr_url"
                            else
                                break
                            fi
                        done
                    elif [[ "$path" == *"/cam/realmonitor"* ]]; then
                        for dvr_ch in $(seq 2 16); do
                            local dvr_url="rtsp://$host/cam/realmonitor?channel=${dvr_ch}&subtype=0"
                            if probe_url "$dvr_url" $cred; then
                                printf '    \033[1;35mDVR-CH%d\033[0m  %s\n' "$dvr_ch" "$dvr_url"
                            else
                                break
                            fi
                        done
                    elif [[ "$path" == *"/h264Preview_01_main"* ]]; then
                        for dvr_ch in $(seq 2 16); do
                            local dvr_url=$(printf "rtsp://$host/h264Preview_%02d_main" "$dvr_ch")
                            if probe_url "$dvr_url" $cred; then
                                printf '    \033[1;35mDVR-CH%d\033[0m  %s\n' "$dvr_ch" "$dvr_url"
                            else
                                break
                            fi
                        done
                    fi
                    return 0
                fi
            done
        fi
    done
    return 1
}

# ONVIF WS-Discovery: send a UDP probe to 239.255.255.250:3702 and collect
# XAddrs from ProbeMatches. Uses python3 (always present) — no extra deps.
onvif_probe() {
    have python3 || return 1
    python3 - "$subnet" <<'PY' 2>/dev/null
import socket, struct, time, re, sys, uuid

msg = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<Envelope xmlns:dn="http://www.onvif.org/ver10/network/wsdl"'
    ' xmlns="http://www.w3.org/2003/05/soap-envelope">'
    '<Header>'
    '<wsa:MessageID xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
    'uuid:' + str(uuid.uuid4()) +
    '</wsa:MessageID>'
    '<wsa:To xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
    'urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'
    '<wsa:Action xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
    'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'
    '</Header>'
    '<Body>'
    '<Probe xmlns="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
    '<Types>dn:NetworkVideoTransmitter</Types>'
    '</Probe>'
    '</Body>'
    '</Envelope>'
).encode('utf-8')

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(socket.gethostbyname(socket.gethostname())))
s.settimeout(2.0)
s.sendto(msg, ("239.255.255.250", 3702))
end = time.time() + 3
while time.time() < end:
    try:
        data, addr = s.recvfrom(8192)
    except socket.timeout:
        break
    text = data.decode('utf-8', 'ignore')
    for m in re.finditer(r'XAddrs>([^<]+)</', text):
        print(m.group(1).strip())
PY
}

cmd_scan() {
    local subnet; subnet="$(local_subnet)"
    if [[ -z $subnet ]]; then
        echo "No IPv4 default route found. Connect to a network first." >&2
        return 1
    fi
    log "Scanning $subnet.0/24"

    # Local USB / V4L2 probe
    log "  (0) Local USB / V4L2 webcams"
    local found_usb=0
    for v4l in /dev/video*; do
        if [[ -e "$v4l" ]]; then
            local card_name
            card_name=$(cat "/sys/class/video4linux/${v4l#/dev/}/name" 2>/dev/null || echo "USB Device")
            printf '  USB     %-14s %s\n' "$v4l" "$card_name"
            found_usb=1
        fi
    done
    [[ $found_usb -eq 0 ]] && echo "  (no local video devices)"

    # RTSP sweep (background, capped by per-host timeout)
    local found=()
    log "  (1) RTSP probe (TCP 554) — this takes ~30 s"
    local out
    out=$(scan_rtsp_quick "$subnet")
    [[ -n $out ]] && echo "$out"

    log "  (2) ONVIF WS-Discovery multicast"
    local onvif
    onvif=$(onvif_probe 2>/dev/null || true)
    if [[ -n $onvif ]]; then
        echo "$onvif" | grep -oE 'http://[^/]+' | sort -u | sed 's/^/  ONVIF   /'
    else
        echo "  (no ONVIF responses)"
    fi

    log "Done. Use 'tvpc-cameras add NAME URL' to add what you found,"
    log "or 'tvpc-cameras menu' for a GUI."
}

# A faster RTSP sweep that only reports which IPs have port 554 open.
scan_rtsp_quick() {
    local subnet="$1"
    local ip
    for ip in $(seq 1 254); do
        if tcp_open "$subnet.$ip" 554; then
            printf 'RTSP   %s\n' "$subnet.$ip"
        fi
    done
}

# --- List / add / remove --------------------------------------------------
cmd_list() {
    echo "== Cameras ($CONF_FILE) =="
    printf '  %-4s %-20s %s\n' "ID" "Name" "URL"
    local line
    while IFS= read -r line; do
        IFS='|' read -r id name url user pass notes <<<"$line"
        printf '  %-4s %-20s %s\n' "$id" "$name" "$url"
    done < <(read_cameras)
}

cmd_add() {
    local name="${1:-}" url="${2:-}" user="${3:-}" pass="${4:-}" notes="${5:-}"
    if [[ -z $name || -z $url ]]; then
        echo "Usage: tvpc-cameras add NAME URL [USER [PASS [NOTES]]]" >&2
        return 1
    fi
    ensure_conf
    printf '%s|%s|%s|%s|%s\n' "$name" "$url" "$user" "$pass" "$notes" >>"$CONF_FILE"
    log "Added '$name' ($url)"
}

cmd_remove() {
    local id="${1:-}"
    [[ -z $id ]] && { echo "Usage: tvpc-cameras remove ID" >&2; return 1; }
    local tmp; tmp="$(mktemp)"
    local n=0
    while IFS= read -r line; do
        if [[ $n -ne $id ]]; then echo "$line"; fi
        n=$((n + 1))
    done <"$CONF_FILE" >"$tmp"
    mv "$tmp" "$CONF_FILE"
    log "Removed ID $id"
}

# --- Playback (PiP) -------------------------------------------------------
play() {
    local url="$1" name="$2" x="$3" y="$4" w="$5" h="$6"
    if ! have mpv; then
        echo "mpv is not installed. sudo apt-get install mpv" >&2
        return 1
    fi
    local extra_args=(--rtsp-transport=tcp)
    if [[ "$url" == /dev/video* || "$url" == av://v4l2:* || "$url" == v4l2://* ]]; then
        extra_args=()
        if [[ "$url" == /dev/video* ]]; then
            url="av://v4l2:$url"
        elif [[ "$url" == v4l2://* ]]; then
            url="av://v4l2:${url#v4l2://}"
        fi
    fi
    mpv --no-terminal --quiet \
        --title="tvpc-cameras: $name" \
        --geometry="${w}x${h}+${x}+${y}" \
        --border=no --title-bar=no \
        --no-osc --no-input-terminal --no-input-cursor \
        --keep-open=always \
        --ontop --on-top-level=system \
        "${extra_args[@]}" \
        --hwdec=auto-safe \
        --force-window=immediate \
        "$url" &
}

# Compute a (x, y) for PiP #N out of N total, in a grid.
pip_pos() {
    local n="$1" total="$2" w="$3" h="$4"
    local screen_w screen_h
    screen_w=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}' | cut -dx -f1)
    screen_h=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}' | cut -dx -f2)
    screen_w=${screen_w:-1920}; screen_h=${screen_h:-1080}
    local cols
    case "$total" in
        1) cols=1 ;;
        2|3|4) cols=2 ;;
        *) cols=3 ;;
    esac
    local row=$(( n / cols )) col=$(( n % cols ))
    local x=$(( screen_w - w - PIP_MARGIN - col * (w + PIP_MARGIN) ))
    local y=$(( screen_h - h - PIP_MARGIN - row * (h + PIP_MARGIN) ))
    printf '%d %d\n' "$x" "$y"
}

cmd_view() {
    local id="${1:-}"
    [[ -z $id ]] && { echo "Usage: tvpc-cameras view ID" >&2; return 1; }
    local line; line="$(get_camera "$id")"
    [[ -z $line ]] && { echo "No camera with ID $id" >&2; return 1; }
    IFS='|' read -r name url user pass notes <<<"$line"
    local cred_args=()
    local extra_args=(--rtsp-transport=tcp)
    if [[ "$url" == /dev/video* || "$url" == av://v4l2:* || "$url" == v4l2://* ]]; then
        extra_args=()
        if [[ "$url" == /dev/video* ]]; then
            url="av://v4l2:$url"
        elif [[ "$url" == v4l2://* ]]; then
            url="av://v4l2:${url#v4l2://}"
        fi
    else
        if [[ -n $user ]]; then cred_args=(--user "$user" --password "$pass"); fi
    fi
    mpv --no-terminal --quiet \
        --title="tvpc-cameras: $name" \
        --geometry="${PIP_W}x${PIP_H}+0+0" \
        --border=no --title-bar=no \
        --no-osc --no-input-terminal --no-input-cursor \
        --keep-open=always \
        --ontop --on-top-level=system \
        "${extra_args[@]}" --hwdec=auto-safe \
        --force-window=immediate \
        "${cred_args[@]}" "$url" &
    log "Opened $name in a PiP window (PID $!)"
}

cmd_grid() {
    have mpv || { echo "mpv not installed. sudo apt-get install mpv" >&2; return 1; }
    local n=0
    while IFS= read -r line; do
        IFS='|' read -r name url user pass notes <<<"$line"
        local x y; read -r x y < <(pip_pos "$n" "4" "$PIP_W" "$PIP_H")
        play "$url" "$name" "$x" "$y" "$PIP_W" "$PIP_H"
        n=$((n + 1))
        [[ $n -ge 4 ]] && break
    done < <(read_cameras | awk -F'|' '{$1=""; print substr($0,2)}')
    log "Opened $n camera(s) in a 2x2 grid"
}

# --- GUI ------------------------------------------------------------------
cmd_menu() {
    have kdialog || { cmd_list; return 0; }
    while true; do
        local items
        items=$(read_cameras | awk -F'|' '{
            printf "%d|%s|%s\n", $1, $2, $3
        }')
        local lines=()
        local i
        while IFS='|' read -r id name url; do
            lines+=("$id" "▶ $name  ($url)")
        done <<<"$items"
        lines+=("scan" "🔍 Scan the network")
        lines+=("add"  "➕ Add camera manually")
        lines+=("grid" "▦ Open all as 2x2 grid")

        local choice
        choice=$(kdialog --menu "tvpc-cameras" \
            "Choose a camera to open, or an action" "${lines[@]}" 2>/dev/null) || return 0

        case "$choice" in
            scan) cmd_scan ;;
            add)
                local n u
                n=$(kdialog --inputbox "Camera name:" "front_door" 2>/dev/null) || continue
                u=$(kdialog --inputbox "Stream URL (rtsp:// or http://):" "rtsp://" 2>/dev/null) || continue
                cmd_add "$n" "$u"
                ;;
            grid) cmd_grid ;;
            "")   return 0 ;;
            *)    cmd_view "$choice" ;;
        esac
    done
}

# --- Help -----------------------------------------------------------------
cmd_help() {
    sed -n '2,20p' "$0" | sed 's/^# *//'
}

# --- Quick Toggle / Cycle (CEC Hotkeys) -----------------------------------
cmd_toggle_pip() {
    local id="${1:-0}"
    if pgrep -f "title=tvpc-cameras:" >/dev/null 2>&1; then
        pkill -f "title=tvpc-cameras:" || true
        log "Closed active camera PiP"
    else
        cmd_view "$id"
    fi
}

cmd_toggle_grid() {
    if pgrep -f "title=tvpc-cameras:" >/dev/null 2>&1; then
        pkill -f "title=tvpc-cameras:" || true
        log "Closed camera grid"
    else
        cmd_grid
    fi
}

cmd_cycle() {
    local total
    total=$(read_cameras | wc -l)
    [[ $total -eq 0 ]] && return 0

    local current_id=0
    local state_file="${XDG_RUNTIME_DIR:-/tmp}/tvpc_cameras_cycle_state"
    if [[ -f "$state_file" ]]; then
        current_id=$(cat "$state_file" 2>/dev/null || echo 0)
    fi
    local next_id=$(( (current_id + 1) % total ))
    echo "$next_id" >"$state_file"

    pkill -f "title=tvpc-cameras:" || true
    cmd_view "$next_id"
}

cmd_tile() {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tvpc"
    local tile_image="$cache_dir/cameras_tile.jpg"
    local desktop_entry="${XDG_DATA_HOME:-$HOME/.local/share}/applications/tvpc-cameras-live.desktop"

    mkdir -p "$cache_dir" "$(dirname "$desktop_entry")"

    if [[ -f "$CONF_FILE" ]]; then
        local first_url="" first_user="" first_pass=""
        while IFS='|' read -r name url user pass notes rest; do
            [[ $name == \#* || -z $url ]] && continue
            first_url="$url"
            first_user="$user"
            first_pass="$pass"
            break
        done <"$CONF_FILE"

        if [[ -n "$first_url" ]]; then
            local ffmpeg_args=(-y -hide_banner -loglevel error)
            if [[ "$first_url" == /dev/video* ]]; then
                ffmpeg_args+=(-f v4l2 -i "$first_url" -frames:v 1 -q:v 3 "$tile_image")
            elif [[ "$first_url" == rtsp://* ]]; then
                local target_url="$first_url"
                if [[ -n "$first_user" && "$first_url" != *"@"* ]]; then
                    target_url="rtsp://${first_user}:${first_pass}@${first_url#rtsp://}"
                fi
                ffmpeg_args+=(-rtsp_transport tcp -i "$target_url" -frames:v 1 -q:v 3 "$tile_image")
            else
                ffmpeg_args+=(-i "$first_url" -frames:v 1 -q:v 3 "$tile_image")
            fi
            timeout 5 ffmpeg "${ffmpeg_args[@]}" >/dev/null 2>&1 || true
        fi
    fi

    local icon_path="$tile_image"
    [[ -f "$tile_image" ]] || icon_path="camera-web"

    cat >"$desktop_entry" <<EOF
[Desktop Entry]
Type=Application
Name=Security Cameras
GenericName=Live Camera Feed
Comment=View live CCTV security camera streams and recordings
Exec=/usr/local/bin/tvpc-cameras-gui
Icon=$icon_path
Terminal=false
Categories=AudioVideo;Video;
Keywords=camera;cctv;security;rtsp;nvr;surveillance;
EOF
    echo "Updated live camera tile: $desktop_entry"
}

cmd_gui() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found. sudo apt-get install python3" >&2
        exit 1
    fi
    local script_dir repo_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    if ! python3 -c "import tvpc_cameras_gui" 2>/dev/null; then
        if [[ -d "$repo_root/tvpc_cameras_gui" ]]; then
            export PYTHONPATH="${repo_root}${PYTHONPATH:+:$PYTHONPATH}"
        fi
    fi
    exec python3 -m tvpc_cameras_gui "$@"
}

# --- Dispatch -------------------------------------------------------------
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
case "${1:-}" in
    scan)     cmd_scan ;;
    list)     cmd_list ;;
    add)      shift; cmd_add "$@" ;;
    remove|rm) shift; cmd_remove "$@" ;;
    view|play) shift; cmd_view "$@" ;;
    grid)     cmd_grid ;;
    toggle-pip|toggle) shift; cmd_toggle_pip "$@" ;;
    toggle-grid) shift; cmd_toggle_grid "$@" ;;
    cycle)    shift; cmd_cycle "$@" ;;
    tile)     shift; cmd_tile "$@" ;;
    menu)     cmd_menu ;;
    gui)      shift; cmd_gui "$@" ;;
    config)   echo "$CONF_FILE" ;;
    help|--help|-h) cmd_help ;;
    "")
        if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
            cmd_gui "$@"
        else
            cmd_menu
        fi
        ;;
    *) echo "Unknown command: $1 (try: tvpc-cameras help)"; exit 1 ;;
esac

}

# ---------------------------------------------------------------------------
# Module: Hyprland
# ---------------------------------------------------------------------------
hypr_menu() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi

# The menu button is a toggle: if a launcher is already up, this press is
# the user asking to dismiss it. Without this, pressing Menu twice stacks a
# second launcher on top of the first.
if pkill -x fuzzel 2>/dev/null || pkill -x wofi 2>/dev/null; then
  exit 0
fi

# fuzzel is the launcher, but never let a missing binary leave the menu
# button doing nothing at all.
menu() {   # reads labels on stdin, echoes the chosen one
  if command -v fuzzel >/dev/null 2>&1; then
    fuzzel --dmenu --prompt "$1  "
  elif command -v wofi >/dev/null 2>&1; then
    wofi --dmenu --prompt "$1"
  else
    return 1
  fi
}

have()      { command -v "$1" >/dev/null 2>&1; }
have_flat() { flatpak info "$1" >/dev/null 2>&1; }

# --- power / session menu ---------------------------------------------------
if [[ "${1:-}" == "power" ]]; then
  choice="$(printf '%s\n' "Cancel" "Reboot" "Power off" "Restart shell" "Log out" | menu "Power")" || exit 0
  case "$choice" in
    "Reboot")        systemctl reboot ;;
    "Power off")     systemctl poweroff ;;
    "Restart shell") hyprctl reload ;;
    "Log out")       hyprctl dispatch exit ;;
    *)               : ;;
  esac
  exit 0
fi

# --- every installed app ----------------------------------------------------
if [[ "${1:-}" == "all" ]]; then
  if have fuzzel; then exec fuzzel; fi
  if have wofi;   then exec wofi --show drun; fi
  echo "tvpc-hypr-menu: no launcher installed (apt install fuzzel)" >&2
  exit 1
fi

# --- curated list -----------------------------------------------------------
# Built from what is actually present, so the menu never offers something
# that will not start.
declare -a LABELS=() CMDS=()
add() { LABELS+=("$1"); CMDS+=("$2"); }

if have_flat io.github.vacuumtube.VacuumTube; then
  add "YouTube" "flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --ozone-platform-hint=auto"
fi
if have_flat org.mozilla.firefox; then
  add "Firefox" "flatpak run org.mozilla.firefox"
elif have firefox; then
  add "Firefox" "firefox"
fi
if have_flat tv.kodi.Kodi; then
  add "Kodi" "flatpak run tv.kodi.Kodi"
elif have kodi; then
  add "Kodi" "kodi"
fi
have foot     && add "Terminal" "foot"
have pavucontrol && add "Audio settings" "pavucontrol"
have nm-connection-editor && add "Wi-Fi" "nm-connection-editor"

add "All apps…" "@all"
add "Power"     "@power"

if [[ ${#LABELS[@]} -eq 0 ]]; then
  echo "tvpc-hypr-menu: nothing to offer" >&2
  exit 1
fi

choice="$(printf '%s\n' "${LABELS[@]}" | menu "Apps")" || exit 0
[[ -n "$choice" ]] || exit 0

for i in "${!LABELS[@]}"; do
  if [[ "${LABELS[$i]}" == "$choice" ]]; then
    case "${CMDS[$i]}" in
      "@all")   exec "$0" all ;;
      "@power") exec "$0" power ;;
      *)        setsid -f sh -c "${CMDS[$i]}" >/dev/null 2>&1; exit 0 ;;
    esac
  fi
done
exit 0

}

hypr_autostart() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi

# A television is not a laptop: never blank, never suspend. hypridle is
# deliberately not installed, but a stray systemd idle action would still
# bite, so make the intent explicit here too.
systemctl --user mask hypridle.service >/dev/null 2>&1 || true

# Hand the session environment to the user bus, so services started later
# (the CEC listener's playerctl calls, portals, flatpak apps) can find the
# compositor instead of guessing.
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE \
    >/dev/null 2>&1 || true
fi
systemctl --user import-environment \
  WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE \
  >/dev/null 2>&1 || true

if [[ -n "${TVPC_AUTOSTART_APP:-}" ]]; then
  setsid -f sh -c "$TVPC_AUTOSTART_APP" >/dev/null 2>&1 || true
fi

}

hypr_setup() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

MODE=install
case "${1:-}" in
  --check)  MODE=check ;;
  --force)  MODE=force ;;
  --remove) MODE=remove ;;
  "")       ;;
  *) echo "Unknown option '$1' (try --help)" >&2; exit 1 ;;
esac

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PPA="ppa:cppiber/hyprland"
PPA_ORIGIN="LP-PPA-cppiber-hyprland"
PIN_FILE="/etc/apt/preferences.d/90-tvpc-hyprland"
SESSION_DESKTOP="/usr/share/wayland-sessions/tvpc-hypr.desktop"

# See the note in tvpc-bigscreen.sh: `cmd | grep -q` under pipefail reports
# failure when grep matches early and the producer dies on SIGPIPE. That is
# especially bad for bare `apt-cache policy`, whose output is megabytes.
apt_has_candidate() {
  local policy
  policy="$(apt-cache policy "$1" 2>/dev/null)" || return 1
  [[ $policy == *"Candidate:"* ]] || return 1
  [[ $policy != *"Candidate: (none)"* ]]
}

ppa_configured() {
  local policy
  policy="$(apt-cache policy 2>/dev/null)" || return 1
  [[ $policy == *"$PPA_ORIGIN"* ]]
}

ok()   { echo "  ok    $*"; }
bad()  { echo "  MISS  $*"; }
info() { echo "== $* =="; }

# Config sources in the repo, and where they land in the user's home.
CONFIGS=(
  "config/hypr/hyprland.lua:.config/hypr/hyprland.lua"
  "config/hypr/waybar/config.jsonc:.config/waybar/config.jsonc"
  "config/hypr/waybar/style.css:.config/waybar/style.css"
  "config/hypr/fuzzel.ini:.config/fuzzel/fuzzel.ini"
)

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  info "Hyprland session"
  if ppa_configured; then ok "PPA configured"; else bad "PPA not configured"; fi
  if [[ -f $PIN_FILE ]]; then ok "apt pin present ($PIN_FILE)"; else bad "apt pin missing"; fi
  if command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1; then
    ok "Hyprland installed: $( { Hyprland --version 2>/dev/null || hyprland --version 2>/dev/null; } | head -1)"
  else
    bad "Hyprland not installed"
  fi
  for b in waybar fuzzel swaybg foot; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b"; else bad "$b"; fi
  done
  for b in tvpc-hypr-menu tvpc-hypr-autostart tvpc-hypr-session; do
    if [[ -x "/usr/local/bin/$b" ]]; then ok "/usr/local/bin/$b"; else bad "/usr/local/bin/$b"; fi
  done
  if [[ -f $SESSION_DESKTOP ]]; then ok "session file $SESSION_DESKTOP"; else bad "session file $SESSION_DESKTOP"; fi
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  if [[ -z $home ]]; then
    bad "user '$HTPC_USER' does not exist — no configs to check"
  else
    for pair in "${CONFIGS[@]}"; do
      dst="$home/${pair##*:}"
      if [[ -f $dst ]]; then ok "config $dst"; else bad "config $dst"; fi
    done
  fi
  echo
  echo "Active session: ${TVPC_SESSION:-unset}   (switch with: sudo tvpc-session hypr)"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }
id "$HTPC_USER" >/dev/null 2>&1 || { echo "User '$HTPC_USER' does not exist" >&2; exit 1; }
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6)"

# ---------------------------------------------------------------------------
# --remove
# ---------------------------------------------------------------------------
if [[ $MODE == remove ]]; then
  info "Removing the Hyprland session"
  if [[ "${TVPC_SESSION:-}" == "hypr" ]]; then
    echo "!! TVPC_SESSION is still 'hypr'. Point it somewhere that exists first:"
    echo "     sudo tvpc-session plasma"
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  rm -f "$SESSION_DESKTOP"
  rm -f /usr/local/bin/tvpc-hypr-menu /usr/local/bin/tvpc-hypr-autostart /usr/local/bin/tvpc-hypr-session

  # ppa-purge is the right tool: it disables the PPA and puts every package
  # that came from it back to the Ubuntu version. Plain "apt purge" would
  # leave any upgraded shared libraries behind at their PPA versions.
  if apt-get install -y ppa-purge >/dev/null 2>&1 && command -v ppa-purge >/dev/null 2>&1; then
    echo "  reverting PPA packages with ppa-purge (this downgrades, and takes a minute)"
    ppa-purge -y "$PPA" || echo "  !! ppa-purge reported an error — check 'apt list --installed | grep ppa1'"
  else
    echo "  !! ppa-purge unavailable; falling back to a plain purge."
    echo "     Anything the PPA upgraded stays at its PPA version. Check:"
    echo "       apt list --installed | grep ppa1"
    apt-get purge -y hyprland xdg-desktop-portal-hyprland hyprpolkitagent 2>/dev/null || true
    add-apt-repository -y --remove "$PPA" 2>/dev/null || true
  fi
  rm -f "$PIN_FILE"
  apt-get update -qq 2>/dev/null || true
  echo "Done. The Plasma session and $HOME_DIR/.config/hypr were left alone."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. PPA + pin
# ---------------------------------------------------------------------------
info "Adding the Hyprland PPA"
export DEBIAN_FRONTEND=noninteractive

# The pin goes down BEFORE the first update/install, so the audio stack is
# never eligible to be replaced, not even for a moment.
cat >"$PIN_FILE" <<PIN
# Written by tvpc-hyprland.sh.
#
# The whole PPA sits at priority 100, NOT the default 500. That single
# number is what keeps a working Plasma box working:
#
#   * A package that exists only in the PPA (hyprland, hyprutils,
#     aquamarine, hyprlang...) still installs — nothing in the archive
#     competes with it.
#   * A package already installed from Ubuntu (libinput, libxkbcommon,
#     spdlog, wayland-protocols, and everything Plasma and SDDM link
#     against) is NOT silently upgraded to the PPA's build.
#
# If Hyprland genuinely needs a newer core library than noble ships, apt
# now reports an unmet dependency and installs nothing. That is the right
# failure: a clean "no" beats half-upgrading the libraries underneath a
# running desktop, which is how this box ended up at a black screen.
Package: *
Pin: release o=$PPA_ORIGIN
Pin-Priority: 100

# The audio stack is never taken from any PPA, at any priority.
Package: pipewire pipewire-* libpipewire-* libspa-* wireplumber wireplumber-*
Pin: release o=$PPA_ORIGIN
Pin-Priority: -1

Package: pipewire pipewire-* libpipewire-* libspa-* wireplumber wireplumber-*
Pin: origin "ppa.launchpadcontent.net"
Pin-Priority: -1
PIN
ok "pin written to $PIN_FILE"

if ppa_configured; then
  ok "PPA already configured"
else
  command -v add-apt-repository >/dev/null 2>&1 || apt-get install -y software-properties-common
  add-apt-repository -y "$PPA"
fi
apt-get update

# ---------------------------------------------------------------------------
# 2. Packages
# ---------------------------------------------------------------------------
info "Installing packages"
# Returns apt-get's exit status. The earlier version threw it away, so a
# failed install looked identical to a successful one and the script kept
# running more transactions against the PPA.
apt_install() {
  local want=("$@") have=() missing=() p
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then echo "!! not available, skipping: ${missing[*]}"; fi
  if [[ ${#have[@]} -eq 0 ]]; then return 0; fi
  apt-get install -y "${have[@]}"
}

# Back out the PPA and the pin, leaving the box exactly as it was found.
# Called when Hyprland cannot be installed — there is no reason to leave a
# third-party archive configured on an appliance that is not using it.
abandon() {
  echo
  echo "!! $1"
  echo "   Removing the PPA again so nothing is left half-applied."
  add-apt-repository -y --remove "$PPA" >/dev/null 2>&1 || true
  rm -f "$PIN_FILE"
  apt-get update -qq 2>/dev/null || true
  echo
  echo "   Nothing was installed. The current session is untouched."
  echo "   If the desktop is already broken, revert any PPA packages with:"
  echo "     sudo apt-get install -y ppa-purge && sudo ppa-purge $PPA"
  exit 1
}

# Hyprland goes in FIRST and ALONE, and nothing else is attempted until it
# is confirmed present. The earlier version installed the bar, launcher and
# fonts before checking, so a failed Hyprland still dragged PPA builds of
# shared libraries onto a working Plasma system — all of the risk, none of
# the compositor.
if ! apt_has_candidate hyprland; then
  abandon "The PPA offers no installable 'hyprland' for this release."
fi

if ! apt_install hyprland; then
  abandon "apt could not install hyprland (see the error above)."
fi
if ! command -v Hyprland >/dev/null 2>&1 && ! command -v hyprland >/dev/null 2>&1; then
  abandon "hyprland reported success but no Hyprland binary is on PATH."
fi
ok "Hyprland: $( { Hyprland --version 2>/dev/null || hyprland --version 2>/dev/null; } | head -1)"

# Only now is it worth pulling in the rest. These are individually
# non-fatal: a missing font or portal is a blemish, not a black screen.
apt_install xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent || true
apt_install waybar fuzzel swaybg foot || true
apt_install fonts-noto-core fonts-noto-color-emoji fonts-font-awesome || true
apt_install wl-clipboard playerctl || true

# ---------------------------------------------------------------------------
# 3. Helpers and the session entry
# ---------------------------------------------------------------------------
info "Installing helpers"
install -d /usr/local/bin /usr/share/wayland-sessions
ln -sf tvpc /usr/local/bin/tvpc-hypr-menu
ln -sf tvpc /usr/local/bin/tvpc-hypr-autostart
ok "tvpc-hypr-menu, tvpc-hypr-autostart"

# The session is launched through a wrapper rather than Hyprland directly:
# it exports /etc/default/tvpc so the Lua config can read TVPC_SCALE and
# friends, and it keeps a log, which is the difference between "the TV is
# black" and "here is why the TV is black".
cat >/usr/local/bin/tvpc-hypr-session <<'WRAP'
#!/usr/bin/env bash
# Launch Hyprland for the tvpc TV session. Generated by tvpc-hyprland.sh.
set -u

# Export everything in /etc/default/tvpc so hyprland.lua can read TVPC_MODE,
# TVPC_SCALE and TVPC_OVERSCAN through os.getenv().
set -a
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
set +a

export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11
export XCURSOR_SIZE="${XCURSOR_SIZE:-48}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tvpc"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/hyprland.log"
# Keep one previous boot for comparison, then start clean.
[[ -f $LOG ]] && mv -f "$LOG" "$LOG.1"

BIN=""
for cand in Hyprland hyprland; do
  command -v "$cand" >/dev/null 2>&1 && { BIN="$cand"; break; }
done
if [[ -z $BIN ]]; then
  echo "tvpc: Hyprland is not installed" | tee -a "$LOG" >&2
  exit 1
fi

exec "$BIN" >>"$LOG" 2>&1
WRAP
chmod 0755 /usr/local/bin/tvpc-hypr-session
ok "tvpc-hypr-session"

cat >"$SESSION_DESKTOP" <<'DESK'
[Desktop Entry]
Name=tvpc (Hyprland)
Comment=Hyprland shell tuned for a TV and a CEC remote
Exec=/usr/local/bin/tvpc-hypr-session
TryExec=/usr/local/bin/tvpc-hypr-session
Type=Application
DesktopNames=Hyprland
DESK
ok "session file $SESSION_DESKTOP"

# ---------------------------------------------------------------------------
# 4. Seed the configs
# ---------------------------------------------------------------------------
info "Installing configuration for $HTPC_USER"
for pair in "${CONFIGS[@]}"; do
  src="$REPO_ROOT/${pair%%:*}"
  dst="$HOME_DIR/${pair##*:}"
  [[ -f $src ]] || { echo "!! missing in repo: $src"; continue; }
  install -d -o "$HTPC_USER" -g "$HTPC_USER" "$(dirname "$dst")"
  if [[ -f $dst ]] && ! cmp -s "$src" "$dst"; then
    if [[ $MODE == force ]]; then
      cp -a "$dst" "$dst.bak"
      install -o "$HTPC_USER" -g "$HTPC_USER" -m 0644 "$src" "$dst"
      ok "$dst (replaced, previous kept as $dst.bak)"
    else
      echo "  keep  $dst differs from the repo — left alone (--force to replace)"
    fi
  else
    install -o "$HTPC_USER" -g "$HTPC_USER" -m 0644 "$src" "$dst"
    ok "$dst"
  fi
done

# ---------------------------------------------------------------------------
# 5. What to do next
# ---------------------------------------------------------------------------
cat <<NEXT

Installed. The running session has not been changed.

  Try it:      sudo tvpc-session hypr && sudo systemctl restart sddm
  Go back:     sudo tvpc-session plasma && sudo systemctl restart sddm
  If it fails: $HOME_DIR/.local/state/tvpc/hyprland.log
               sudo tvpc-repair --check

On the remote: the menu button opens the launcher. Arrows, OK and Back are
left to whatever app is on screen, so YouTube still navigates normally.
NEXT

}

subcmd_hyprland() {
  local sub="${1:-}"
  case "$sub" in
    menu)
      shift
      hypr_menu "$@"
      ;;
    autostart)
      shift
      hypr_autostart "$@"
      ;;
    *)
      hypr_setup "$@"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Module: Controller & Gamepad
# ---------------------------------------------------------------------------
subcmd_controller() {
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mOK\033[0m   %s\n' "$*"; }
warn() { printf '   \033[1;33mWARN\033[0m %s\n' "$*" >&2; }
fail() { printf '   \033[1;31mFAIL\033[0m %s\n' "$*" >&2; }
note() { printf '        %s\n' "$*"; }
hr()   { printf '\n\033[1;34m%s\033[0m\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || { fail "Please run as root: sudo $(basename "$0") $*"; exit 1; }
}

HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
# If invoked via sudo, the actual human is $SUDO_USER; their home owns the
# per-user bluetooth/kdeconnect config we may need to read.
REAL_USER="${SUDO_USER:-$HTPC_USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
[[ -z $REAL_HOME ]] && REAL_HOME="$HOME"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

bluetooth_blocked() {
    rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: yes'
}

ensure_bluetooth_up() {
    if ! have bluetoothctl; then
        log "Installing bluetooth stack..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y bluez bluez-tools rfkill
    fi
    if bluetooth_blocked; then
        warn "Bluetooth is soft-blocked. Unblocking."
        rfkill unblock bluetooth
    fi
    if ! systemctl is-active bluetooth.service >/dev/null 2>&1; then
        log "Starting bluetooth.service"
        systemctl enable --now bluetooth.service
    fi
    # Give the adapter a moment to appear
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        bluetoothctl show >/dev/null 2>&1 && break
        sleep 1
    done
    if ! bluetoothctl show >/dev/null 2>&1; then
        fail "No Bluetooth adapter found (or no permissions)."
        return 1
    fi
    ok "Bluetooth adapter is up"
}

list_paired_gamepads() {
    bluetoothctl devices Paired 2>/dev/null \
        | awk '{print $2}' \
        | while read -r mac; do
            info=$(bluetoothctl info "$mac" 2>/dev/null)
            [[ -z $info ]] && continue
            is_input_device "$info" && echo "$mac"
        done
}

# Heuristic: given a "device info" block, is this an input device we care about?
is_input_device() {
    local info="$1"
    local hits=0
    local pattern
    for pattern in 'Xbox' 'Wireless Controller' 'DUALSHOCK' 'DualSense' \
                   'Pro Controller' 'Gamepad' '8BitDo' 'ipega' \
                   'SteelSeries' 'Razer' 'Logitech' 'HORI' \
                   'Controller' 'Joystick' 'HID'; do
        if [[ $info == *"$pattern"* ]]; then hits=$((hits+1)); fi
    done
    [[ $hits -ge 1 ]]
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
cmd_status() {
    hr
    log "Input device status"
    hr

    echo
    echo "Bluetooth adapter:"
    if have bluetoothctl && bluetoothctl show >/dev/null 2>&1; then
        local addr; addr=$(bluetoothctl show 2>/dev/null | awk -F': ' '/Controller/{print $2; exit}')
        local name; name=$(bluetoothctl show 2>/dev/null | awk -F': ' '/Name:/{print $2; exit}')
        ok "$name ($addr)"
        if bluetooth_blocked; then warn "  (soft-blocked — will be unblocked automatically)"; fi
    else
        fail "  no bluetooth adapter or bluez not installed"
        return 0
    fi

    echo
    echo "Paired Bluetooth devices:"
    if bluetoothctl devices Paired 2>/dev/null | grep -q .; then
        bluetoothctl devices Paired 2>/dev/null | sed 's/^/  /'
        echo
        echo "Gamepad candidates:"
        local m; m=$(list_paired_gamepads | head -1)
        if [[ -n $m ]]; then ok "  $m (looks like a gamepad)"
        else note "  no obvious gamepad paired"; fi
    else
        note "  (none yet)"
    fi

    echo
    echo "USB input devices:"
    if have lsusb; then
        lsusb 2>/dev/null | awk '/Human Interface Device|Gamepad|Controller|Xbox|DUALSHOCK|Flirc/' \
            | sed 's/^/  /' || true
        if ! lsusb 2>/dev/null | grep -qiE 'Human Interface Device|Gamepad|Controller|Xbox|DUALSHOCK|Flirc'; then
            note "  (no gamepad / Flirc / keyboard recognised)"
        fi
    else
        note "  (lsusb not installed)"
    fi

    echo
    echo "KDE Connect:"
    if have kdeconnect-cli; then
        if pgrep -x kdeconnectd >/dev/null 2>&1; then ok "  kdeconnectd running"
        else warn "  kdeconnectd not running — start it: systemctl --user start kdeconnectd"; fi
        local paired; paired=$(sudo -u "$REAL_USER" -H bash -c 'kdeconnect-cli --list-available --list-only 2>/dev/null' | sed 's/^/  /')
        if [[ -n $paired ]]; then echo "  paired devices:"; echo "$paired"
        else note "  no devices paired. Run: sudo tvpc-controller pair-kdeconnect"; fi
    else
        warn "  kdeconnect-cli not installed"
    fi

    echo
    echo "plasma-bigscreen-inputhandler:"
    if pgrep -fa plasma-bigscreen-inputhandler >/dev/null 2>&1; then
        ok "  running"
    else
        note "  not running (starts automatically when Bigscreen is the session)"
    fi

    echo
    echo "Gamepad kernel modules (for older / wired Xbox adapters):"
    local m
    for m in xpad xone ff-memless joydev evdev; do
        if lsmod 2>/dev/null | grep -q "^$m"; then ok "  $m"
        else note "  $m not loaded (usually fine for modern BT/USB HID)"; fi
    done

    echo
}

# ---------------------------------------------------------------------------
# Gamepad pairing
# ---------------------------------------------------------------------------
cmd_pair_gamepad() {
    require_root pair-gamepad
    hr
    log "Pairing a Bluetooth gamepad"
    hr

    ensure_bluetooth_up

    local target_mac="${1:-}"

    # --- Fast path: a MAC was provided --------------------------------------
    if [[ -n $target_mac ]]; then
        log "Pairing $target_mac"
        bluetoothctl pair   "$target_mac" || warn "pair failed (may already be paired)"
        bluetoothctl trust  "$target_mac" || true
        bluetoothctl connect "$target_mac" || true
        sleep 2
        if bluetoothctl info "$target_mac" 2>/dev/null | grep -q 'Connected: yes'; then
            ok "Connected to $target_mac"
        else
            warn "Pair/connect reported success but bluetoothctl does not see it connected."
            note "Hold the pairing button on the controller and try again."
        fi
        return 0
    fi

    # --- Interactive: scan and pick -----------------------------------------
    log "Scanning for nearby Bluetooth devices (15 s)..."
    note "Put the controller in pairing mode:"
    note "  - Xbox: hold the small pairing button on the top until the LED flashes fast"
    note "  - PS4/PS5: hold Share + PS button (or the pairing button on the bottom)"
    note "  - 8BitDo: hold Start + B for ~3 s"
    local found=()
    local line
    while IFS= read -r line; do
        # Line format: [NEW] Device AA:BB:CC:DD:EE:FF Name
        [[ $line != *Device* ]] && continue
        local mac=${line##*Device }
        mac=${mac%% *}
        local name=${line##* }
        found+=("$mac|$name")
        printf '  \033[1;33mFOUND\033[0m %s  %s\n' "$mac" "$name"
    done < <(bluetoothctl --timeout 15 scan on 2>/dev/null || true)

    if [[ ${#found[@]} -eq 0 ]]; then
        fail "No new devices seen. Move the controller closer and retry."
        return 1
    fi

    # Prefer devices that look like gamepads
    local pick=""
    for entry in "${found[@]}"; do
        local mac=${entry%%|*}; local name=${entry#*|}
        if is_input_device "$name"; then pick="$entry"; break; fi
    done
    [[ -z $pick ]] && pick="${found[0]}"

    local mac=${pick%%|*}; local name=${pick#*|}
    log "Pairing: $name ($mac)"
    bluetoothctl pair   "$mac" || warn "pair failed (may already be paired)"
    bluetoothctl trust  "$mac" || true
    bluetoothctl connect "$mac" || true
    sleep 2

    if bluetoothctl info "$mac" 2>/dev/null | grep -q 'Connected: yes'; then
        ok "$name is connected"
        note "Bigscreen's input handler will pick it up automatically."
    else
        warn "$name did not connect. Try again, or: bluetoothctl connect $mac"
    fi
}

# ---------------------------------------------------------------------------
# KDE Connect
# ---------------------------------------------------------------------------
cmd_pair_kdeconnect() {
    require_root pair-kdeconnect
    hr
    log "Pairing a phone via KDE Connect"
    hr

    if ! have kdeconnect-cli; then
        log "Installing kdeconnect..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y kdeconnect
    fi

    # kdeconnectd is a per-user daemon. Start it for the real user.
    log "Starting kdeconnectd for $REAL_USER"
    if have loginctl; then loginctl enable-linger "$REAL_USER" 2>/dev/null || true; fi
    sudo -u "$REAL_USER" -H bash -c 'systemctl --user enable --now kdeconnectd' \
        || sudo -u "$REAL_USER" -H bash -c 'kdeconnectd &'
    sleep 2

    if ! pgrep -u "$REAL_USER" -x kdeconnectd >/dev/null 2>&1; then
        # Fallback: start it directly
        sudo -u "$REAL_USER" -H nohup kdeconnectd >/dev/null 2>&1 &
        sleep 2
    fi

    local id
    id=$(sudo -u "$REAL_USER" -H kdeconnect-cli --id 2>/dev/null | tr -d '\r\n[:space:]')
    if [[ -z $id ]]; then
        fail "kdeconnectd did not report an ID. Try again in a few seconds."
        return 1
    fi
    ok "This device's ID: $id"

    echo
    log "On your phone:"
    note "1. Install 'KDE Connect' from the Play Store / F-Droid / iOS App Store."
    note "2. Make sure phone and TV are on the SAME Wi-Fi network."
    note "3. Open KDE Connect on the phone; the TV should appear within a few seconds."
    note "4. Tap 'Request pairing'."
    note "5. Accept the pairing prompt on the TV (or run the command below)."
    echo
    note "Once the phone shows the device as 'reachable', accept the pair here:"
    echo "    sudo -u $REAL_USER kdeconnect-cli --pair --device <phone-id>"
    echo
    note "To send a test ping:"
    echo "    sudo -u $REAL_USER kdeconnect-cli --ping --device <phone-id>"
}

# ---------------------------------------------------------------------------
# Flirc
# ---------------------------------------------------------------------------
cmd_setup_flirc() {
    require_root setup-flirc
    hr
    log "Setting up a Flirc USB IR receiver"
    hr

    if ! lsusb 2>/dev/null | grep -iq 'flirc'; then
        fail "No Flirc device found on USB. Plug it in and re-run."
        return 1
    fi
    ok "Flirc detected on USB"

    if ! have flirc_util; then
        # flirc_util is in the upstream deb; Ubuntu usually doesn't have it.
        # We can talk to Flirc via its HID protocol if needed, but the cleanest
        # is to point the user to the Flirc configuration software.
        warn "flirc_util not installed."
        note "Download Flirc's config app from https://flirc.tv/ and run it"
        note "on any machine to program the Flirc with a 'Keyboard' profile,"
        note "then plug the Flirc into the NUC. After that, any remote just works."
        return 0
    fi

    log "Programming Flirc with the default 'Navigation' profile..."
    flirc_util record delete 2>/dev/null || true

    local keys=(
        'Up'    'Down' 'Left' 'Right'
        'Enter' 'Escape'
        'MediaPlayPause' 'MediaStop' 'MediaNext' 'MediaPrevious'
        'VolumeUp' 'VolumeDown' 'VolumeMute'
    )
    local k
    for k in "${keys[@]}"; do
        printf '   Press a button on your remote for [%s] (5s timeout)...\n' "$k"
        if flirc_util record "$k" 2>/dev/null; then
            ok "  recorded $k"
        else
            warn "  $k: no input within 5 s, skipping"
        fi
    done

    log "Flirc layout saved."
    note "You can re-run this script with a key list to customize mappings."
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
cmd_help() {
    cat <<EOF
tvpc-controller — input device setup for Plasma Bigscreen

Usage: sudo tvpc-controller <command>

Commands:
  status            Show what's paired / connected right now
  pair-gamepad      Pair a Bluetooth gamepad (Xbox, PS, 8BitDo, ...)
  pair-gamepad MAC  Pair a specific MAC address (non-interactive)
  pair-kdeconnect   Pair your phone as a remote over Wi-Fi
  setup-flirc       Program a Flirc USB IR receiver
  help              This message

Most of these work for ANY controller / input device — you don't need CEC.
The plasma-bigscreen-inputhandler picks up gamepads and keyboards
automatically once they're paired.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
    status)          require_root status; cmd_status ;;
    pair-gamepad)    shift; cmd_pair_gamepad "${1:-}" ;;
    pair-kdeconnect) cmd_pair_kdeconnect ;;
    setup-flirc)     cmd_setup_flirc ;;
    help|--help|-h)  cmd_help ;;
    *)               fail "Unknown command: $1"; cmd_help; exit 1 ;;
esac

}

# ---------------------------------------------------------------------------
# Module: Doctor Health Check
# ---------------------------------------------------------------------------
subcmd_doctor() {
set -u

FAIL=0
ok()   { echo "  OK    $1"; }
bad()  { echo "  FAIL  $1"; FAIL=1; }
warn() { echo "  WARN  $1"; }
hr()   { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
hr "Boot to desktop"
# The checks most likely to explain a black screen, in the order they bite.
TARGET="$(systemctl get-default 2>/dev/null)"
[[ $TARGET == graphical.target ]] \
  && ok "default target is graphical.target" \
  || bad "default target is $TARGET — the display manager never starts"

systemctl is-enabled sddm >/dev/null 2>&1 && ok "sddm enabled" || bad "sddm not enabled"
systemctl is-active  sddm >/dev/null 2>&1 && ok "sddm running" || warn "sddm not running"

SDDM_CONF=""
for c in /etc/sddm.conf.d/10-tvpc.conf /etc/sddm.conf.d/autologin.conf /etc/sddm.conf; do
  [[ -f $c ]] && grep -q '^Session=' "$c" 2>/dev/null && { SDDM_CONF="$c"; break; }
done
if [[ -n $SDDM_CONF ]]; then
  SESSION="$(awk -F= '/^Session=/{print $2; exit}' "$SDDM_CONF")"
  # One directory holds it; `ls` over all four fails on the three that do not.
  FOUND=""
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions \
           /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$SESSION" ]] && { FOUND=1; break; }
  done
  if [[ -n $FOUND ]]; then
    ok "autologin session $SESSION is installed"
  else
    bad "autologin points at $SESSION, which is not installed"
  fi
else
  bad "no autologin session configured"
fi

[[ -f /etc/X11/xorg.conf.d/20-intel.conf ]] \
  && bad "/etc/X11/xorg.conf.d/20-intel.conf present — Driver \"intel\" is not installable on 24.04" \
  || ok "no conflicting Xorg driver config"

grep -q splash /proc/cmdline 2>/dev/null \
  && warn "'splash' on the kernel command line hides boot failures behind plymouth" \
  || ok "no plymouth splash"

grep -qE 'i915\.enable_guc|intel_iommu=igfx_off' /proc/cmdline 2>/dev/null \
  && warn "Broadwell-era kernel parameters still set (this is Kaby Lake)" \
  || ok "kernel command line is clean"

hr "Display / Session"
if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
  ok "graphical session active (${WAYLAND_DISPLAY:-$DISPLAY})"
else
  warn "not run from inside the graphical session (fine over SSH)"
fi
loginctl list-sessions --no-legend 2>/dev/null | grep -q . \
  && ok "user session present" || bad "no user sessions"

# An expired password blocks the autologin and looks exactly like a boot
# failure — every other check here can pass while the TV stays black.
if [[ "$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)" == 0 ]]; then
  bad "password for $HTPC_USER is expired — PAM refuses the autologin"
  echo "      fix: sudo chage -d \$(date +%Y-%m-%d) $HTPC_USER"
else
  ok "password for $HTPC_USER is not expired"
fi
for c in /sys/class/drm/card*-HDMI-A-*/status; do
  [[ -e $c ]] || continue
  s="$(cat "$c")"
  [[ $s == connected ]] && ok "$(basename "$(dirname "$c")") connected" \
                        || warn "$(basename "$(dirname "$c")") $s"
done

hr "GPU / Video decode"
if vainfo >/dev/null 2>&1; then
  ok "VA-API initialised ($(vainfo 2>/dev/null | grep -c 'VAEntrypoint') entrypoints)"
else
  bad "vainfo failed — check LIBVA_DRIVER_NAME=iHD and the i915 driver"
fi

hr "Audio"
DEFAULT_SINK="$(pactl get-default-sink 2>/dev/null || true)"
[[ $DEFAULT_SINK == *hdmi* ]] \
  && ok "default sink is HDMI ($DEFAULT_SINK)" \
  || bad "default sink is not HDMI ('$DEFAULT_SINK')"
systemctl --user is-active pipewire >/dev/null 2>&1 && ok "pipewire running" || warn "pipewire not running for this user"
systemctl --user is-active tvpc-audio >/dev/null 2>&1 \
  && ok "tvpc-audio applied" \
  || warn "tvpc-audio not active (run: systemctl --user restart tvpc-audio)"
[[ -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf ]] \
  && bad "90-hdmi-pin.conf present — it loads a module that does not exist and stops PipeWire" \
  || ok "no bad PipeWire override"

hr "CEC / remote"
cec-client -l >/dev/null 2>&1 && ok "CEC adapter detected" || warn "no CEC adapter (or the listener holds it)"
systemctl is-active ydotoold >/dev/null 2>&1 \
  && ok "ydotoold running" \
  || warn "ydotoold not running — remote navigation keys will do nothing"
systemctl is-active tvpc-cec-remote >/dev/null 2>&1 \
  && ok "remote listener running" \
  || warn "tvpc-cec-remote not running (run scripts/enhance-cec.sh)"
systemctl is-active htpc-startup >/dev/null 2>&1 \
  && ok "htpc-startup (TV power-on) ran" \
  || warn "htpc-startup not active (TV will not auto power-on)"

hr "Network"
ip route get 1.1.1.1 >/dev/null 2>&1 && ok "default route exists" || bad "no network connectivity"
WIFI_DEV="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)"
if [[ -n $WIFI_DEV ]]; then
  nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -q "^$WIFI_DEV:connected" \
    && ok "Wi-Fi connected on $WIFI_DEV" || warn "Wi-Fi device $WIFI_DEV present but not connected"
else
  warn "no Wi-Fi interface visible (BIOS disabled, or firmware missing)"
fi

hr "SSH"
systemctl is-active ssh >/dev/null 2>&1 && ok "sshd running" || bad "sshd not running"

hr "Maintenance"
if systemctl is-enabled unattended-upgrades >/dev/null 2>&1 \
   || systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
  ok "unattended upgrades enabled"
else
  warn "automatic updates not confirmed"
fi
systemctl is-active zramswap >/dev/null 2>&1 && ok "zram swap active" || warn "zramswap not active"
systemctl is-enabled flatpak-update.timer >/dev/null 2>&1 \
  && ok "flatpak auto-update timer enabled" || warn "flatpak timer missing"

hr "Flatpaks"
if command -v flatpak >/dev/null; then
  flatpak list --app --columns=application 2>/dev/null | head -5 | sed 's/^/  /'
  flatpak remote-ls --updates 2>/dev/null | grep -q . \
    && warn "flatpak updates available (run: flatpak update)" \
    || ok "all flatpaks up to date"
else
  bad "flatpak not installed"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED — see above."
  echo "For a black screen specifically:  sudo tvpc-repair --check"
fi
exit $FAIL

}

# ---------------------------------------------------------------------------
# Module: Repair Engine
# ---------------------------------------------------------------------------
subcmd_repair() {
set -uo pipefail

MODE="${1:-repair}"
case "$MODE" in
  -h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
    exit 0 ;;
esac
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# Works both from a repo checkout and from the copy installed in /usr/local/bin,
# whose REPO_ROOT is /usr/local and has no scripts/ directory.
SESSION_TOOL=""
if command -v subcmd_session >/dev/null 2>&1; then SESSION_TOOL="subcmd_session"; break; fi
for cand in "$REPO_ROOT/scripts/tvpc.sh" /usr/local/bin/tvpc-session /usr/local/bin/tvpc; do
  [[ -x $cand ]] && { SESSION_TOOL="$cand"; break; }
done
CHANGED=0
ISSUES=0

say()  { echo "$*"; }
note() { echo "  --  $*"; }
ok()   { echo "  OK  $*"; }
bad()  { echo "  !!  $*"; ISSUES=$((ISSUES+1)); }
did()  { echo "  ->  $*"; CHANGED=$((CHANGED+1)); }

dry() { [[ $MODE == --check ]]; }

# ---------------------------------------------------------------------------
if [[ $MODE == --logs ]]; then
  say "=== kernel: display ==="
  journalctl -b -k --no-pager 2>/dev/null | grep -iE 'i915|drm|guc|huc' | tail -30
  say
  say "=== sddm ==="
  journalctl -b -u sddm --no-pager 2>/dev/null | tail -40
  say
  say "=== session (kwin / plasmashell / startplasma) ==="
  journalctl -b --no-pager 2>/dev/null | grep -iE 'kwin|plasmashell|startplasma|plasma_session' | tail -40
  say
  say "=== Xorg ==="
  for f in /var/log/Xorg.0.log /home/*/.local/share/sddm/xorg-session.log /var/lib/sddm/.local/share/sddm/*.log; do
    [[ -f $f ]] && { say "--- $f"; grep -E '\(EE\)|\(WW\)' "$f" 2>/dev/null | tail -15; }
  done
  say
  say "=== installed sessions ==="
  ls -1 /usr/share/wayland-sessions /usr/local/share/wayland-sessions \
        /usr/share/xsessions /usr/local/share/xsessions 2>/dev/null
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo $0 ${MODE#repair})" >&2
  exit 1
fi

dry && say "=== tvpc repair — CHECK ONLY, nothing will be changed ===" \
    || say "=== tvpc repair ==="

[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-htpc}"

# --- 1. Xorg config naming a missing driver ---------------------------------
say
say "[1] Xorg configuration"
if [[ -f /etc/X11/xorg.conf.d/20-intel.conf ]]; then
  bad "/etc/X11/xorg.conf.d/20-intel.conf requests Driver \"intel\""
  note "xserver-xorg-video-intel is not installed and is no longer part of"
  note "xserver-xorg-video-all on 24.04, so Xorg exits before SDDM can draw."
  if ! dry; then
    mv /etc/X11/xorg.conf.d/20-intel.conf /root/20-intel.conf.disabled
    did "moved aside to /root/20-intel.conf.disabled (modesetting takes over)"
  fi
else
  ok "no conflicting Xorg device config"
fi

# --- 2. PipeWire config that stops PipeWire starting ------------------------
say
say "[2] PipeWire configuration"
if [[ -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf ]]; then
  bad "90-hdmi-pin.conf loads libpipewire-module-alsa-sink, which does not exist"
  if ! dry; then
    rm -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf
    did "removed (audio is selected by tvpc-hdmi-audio instead)"
  fi
else
  ok "no bad PipeWire module override"
fi

# --- 3. Kernel command line -------------------------------------------------
say
say "[3] Kernel command line"
CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
if grep -q 'splash' <<<"$CMDLINE"; then
  bad "'splash' is set — plymouth hides both the boot log and any failure"
  if ! dry; then
    sed -i 's/ *\bsplash\b//g' /etc/default/grub
    did "removed 'splash' from /etc/default/grub"
  fi
else
  ok "no plymouth splash"
fi
if grep -q 'i915.enable_guc\|intel_iommu=igfx_off' <<<"$CMDLINE"; then
  bad "GuC/IOMMU parameters set — these were chosen for Broadwell; this is Kaby Lake"
  if ! dry; then
    sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' /etc/default/grub
    for f in /etc/default/grub.d/*.cfg; do
      [[ -f $f ]] && sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' "$f"
    done
    did "stripped them from /etc/default/grub and /etc/default/grub.d"
  fi
else
  ok "no leftover Broadwell-era kernel parameters"
fi

# --- 4. Display manager actually runs ---------------------------------------
say
say "[4] Display manager"
if ! command -v sddm >/dev/null 2>&1; then
  bad "sddm is not installed"
  if ! dry; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y sddm && did "installed sddm"
  fi
else
  ok "sddm installed"
fi

TARGET="$(systemctl get-default 2>/dev/null)"
if [[ $TARGET != graphical.target ]]; then
  bad "default systemd target is $TARGET — sddm is never reached"
  note "an Ubuntu Server base defaults to multi-user.target"
  if ! dry; then
    systemctl set-default graphical.target && did "default target -> graphical.target"
  fi
else
  ok "default target is graphical.target"
fi

if systemctl is-enabled sddm >/dev/null 2>&1; then
  ok "sddm enabled"
else
  bad "sddm is not enabled"
  if ! dry; then
    systemctl enable sddm && did "enabled sddm"
  fi
fi

# --- 5. The session it is trying to start -----------------------------------
say
say "[5] Autologin session"
CONF=""
for c in /etc/sddm.conf.d/10-tvpc.conf /etc/sddm.conf.d/autologin.conf /etc/sddm.conf; do
  [[ -f $c ]] && grep -q '^Session=' "$c" 2>/dev/null && { CONF="$c"; break; }
done

if [[ -z $CONF ]]; then
  bad "no autologin session configured"
else
  WANT_SESSION="$(awk -F= '/^Session=/{print $2; exit}' "$CONF")"
  FOUND=""
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions \
           /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$WANT_SESSION" ]] && { FOUND="$d/$WANT_SESSION"; break; }
  done
  if [[ -n $FOUND ]]; then
    ok "$CONF -> $WANT_SESSION (present)"
    if [[ $WANT_SESSION == plasma-mobile.desktop ]]; then
      note "Plasma Mobile is a touchscreen shell; when its shell fails you get"
      note "kwin_wayland on a black root window with a pointer — the symptom"
      note "you are debugging. Switching to the Plasma desktop session."
      ISSUES=$((ISSUES+1))
      FOUND=""
    fi
  else
    bad "$CONF points at $WANT_SESSION, which is not installed"
  fi

  if [[ -z $FOUND ]] && ! dry; then
    if [[ -n $SESSION_TOOL ]]; then
      if "$SESSION_TOOL" plasma 2>/dev/null || "$SESSION_TOOL" auto; then
        did "re-pointed autologin at a session that exists"
      else
        note "could not find any installed session to point at"
      fi
    else
      note "tvpc-session.sh not found next to this script or in /usr/local/bin"
      note "run:  sudo apt-get install plasma-workspace-wayland plasma-desktop"
    fi
  fi
fi

if [[ ! -d /usr/share/wayland-sessions ]] || ! ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1; then
  bad "no Wayland sessions installed at all"
  if ! dry; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y plasma-workspace-wayland plasma-desktop \
      && did "installed the Plasma Wayland session"
  fi
fi

# --- 6. The user it logs in as ----------------------------------------------
say
say "[6] Login user"
if id "$HTPC_USER" >/dev/null 2>&1; then
  ok "user $HTPC_USER exists"
  if [[ -d "/home/$HTPC_USER" ]]; then
    BADOWN="$(find "/home/$HTPC_USER/.config" ! -user "$HTPC_USER" -print -quit 2>/dev/null || true)"
    if [[ -n $BADOWN ]]; then
      bad "parts of /home/$HTPC_USER/.config are not owned by $HTPC_USER"
      note "Plasma refuses to start when it cannot write its own config"
      if ! dry; then
        chown -R "$HTPC_USER:$HTPC_USER" "/home/$HTPC_USER/.config" "/home/$HTPC_USER/.local" 2>/dev/null
        did "fixed ownership"
      fi
    else
      ok "config ownership is correct"
    fi
  fi
  # An expired password blocks autologin outright. PAM answers SDDM with
  # "you are required to change your password immediately", SDDM has no way
  # to run an interactive password change from an autologin, and the screen
  # stays black — with every other check on this page reporting OK.
  #
  # sp_lstchg (field 3 of /etc/shadow) == 0 means "must change at next
  # login". That is what `chage -d 0` sets, which an old version of
  # tvpc-postboot.sh used to run.
  LSTCHG="$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)"
  if [[ $LSTCHG == 0 ]]; then
    bad "password for $HTPC_USER is expired — PAM will refuse the autologin"
    note "this looks exactly like a boot failure: SDDM starts, PAM says the"
    note "password must be changed, and nothing ever appears on the TV"
    if ! dry; then
      chage -d "$(date +%Y-%m-%d)" "$HTPC_USER" && did "cleared the forced password change"
    fi
  else
    ok "password for $HTPC_USER is not expired"
  fi

  # A maximum age will re-expire it later, turning this into a box that
  # boots fine for N days and then goes black for no visible reason.
  MAXDAYS="$(awk -F: -v u="$HTPC_USER" '$1 == u { print $5 }' /etc/shadow 2>/dev/null)"
  if [[ -n $MAXDAYS && $MAXDAYS =~ ^[0-9]+$ && $MAXDAYS -lt 3650 ]]; then
    bad "password for $HTPC_USER expires every $MAXDAYS days — it will black-screen again"
    if ! dry; then
      chage -M -1 "$HTPC_USER" && did "removed the password expiry interval"
    fi
  fi
else
  bad "user $HTPC_USER does not exist — autologin cannot succeed"
fi

# --- finish -----------------------------------------------------------------
if ! dry && [[ $CHANGED -gt 0 ]]; then
  update-grub >/dev/null 2>&1 && did "regenerated GRUB config"
  systemctl daemon-reload
fi

say
if dry; then
  say "=== $ISSUES issue(s) found. Re-run without --check to fix them. ==="
  say "For the underlying errors:  sudo $0 --logs"
  [[ $ISSUES -eq 0 ]] && exit 0 || exit 1
fi

if [[ $CHANGED -eq 0 ]]; then
  say "=== Nothing needed changing. ==="
  say "The black screen is coming from somewhere else — collect evidence with:"
  say "  sudo $0 --logs"
  exit 0
fi

say "=== $CHANGED change(s) applied. Reboot: sudo reboot ==="
say "If it is still black afterwards, run:  sudo $0 --logs"

}

# ---------------------------------------------------------------------------
# Module: Status Dashboard
# ---------------------------------------------------------------------------
subcmd_status() {
set -euo pipefail

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

REAL_USER="${SUDO_USER:-${USER:-}}"
REAL_HOME="${HOME:-}"
if [[ -n $SUDO_USER ]]; then REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"; fi
[[ -z $REAL_HOME && -n $REAL_USER ]] && REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -z $REAL_HOME ]] && REAL_HOME="$HOME"

# --- Status codes ----------------------------------------------------------
S_OK=0
S_WARN=1
S_FAIL=2
S_INFO=3

label_for() {
    case "$1" in
        0) printf 'OK  ' ;;
        1) printf 'WARN' ;;
        2) printf 'FAIL' ;;
        *) printf 'INFO' ;;
    esac
}

# --- Each check appends:  id|status|title|detail|fix_cmd|fix_label --------
CHECKS=()

add_check() {
    local id="$1" status="$2" title="$3" detail="$4" fix_cmd="${5:-}" fix_label="${6:-}"
    CHECKS+=("$id|$status|$title|$detail|$fix_cmd|$fix_label")
}

# Run a check function (writes to CHECKS via add_check).
run_all_checks() {
    CHECKS=()
    check_session
    check_cec
    check_display
    check_audio
    check_input
    check_bigscreen
    check_vacuumtube
    check_network
    check_sddm
    check_storage
    check_updates
}

# ---------------------------------------------------------------------------
# Individual checks
# Each prints nothing on stdout; populates CHECKS via add_check.
# ---------------------------------------------------------------------------

check_session() {
    local title="Desktop session"
    local detail sess
    if [[ -r /etc/sddm.conf.d/10-tvpc.conf ]]; then
        sess=$(awk -F= '/^Session=/{print $2; exit}' /etc/sddm.conf.d/10-tvpc.conf 2>/dev/null)
    fi
    sess="${sess:-unset}"
    if [[ -z $sess || $sess == "unset" ]]; then
        add_check "session" "$S_FAIL" "$title" \
            "No autologin session is configured." \
            "sudo tvpc-session plasma" "Set a session"
    elif [[ -f /usr/share/wayland-sessions/$sess ]] || [[ -f /usr/share/xsessions/$sess ]] || \
         [[ -f /usr/local/share/wayland-sessions/$sess ]] || [[ -f /usr/local/share/xsessions/$sess ]]; then
        add_check "session" "$S_OK" "$title" "Autologin session: $sess"
    else
        add_check "session" "$S_FAIL" "$title" \
            "Configured session '$sess' is not installed on this box." \
            "sudo apt-get install plasma-workspace-wayland plasma-desktop" \
            "Install Plasma"
    fi
}

check_cec() {
    local title="CEC remote (Anynet+)"
    local detail=""
    local fix="" fix_label=""
    if ! have cec-client; then
        add_check "cec" "$S_FAIL" "$title" "cec-client (cec-utils) not installed." \
            "sudo apt-get install cec-utils" "Install cec-utils"
        return
    fi
    local list; list=$(cec-client -l 2>&1 || true)
    if echo "$list" | grep -qE 'Found devices|com port|/dev/tty|/dev/cec'; then
        local active
        active=$(systemctl is-active tvpc-cec-remote 2>/dev/null || echo "inactive")
        if [[ $active == "active" ]]; then
            add_check "cec" "$S_OK" "$title" "Adapter found, listener active."
        else
            add_check "cec" "$S_WARN" "$title" \
                "Adapter found but tvpc-cec-remote is $active." \
                "sudo systemctl restart tvpc-cec-remote" "Restart listener"
        fi
    else
        add_check "cec" "$S_FAIL" "$title" \
            "No CEC adapter detected. NUC7i5BNH has no native CEC — you need a USB-CEC adapter (Pulse-Eight) OR use a gamepad/KDE Connect/Flirc instead." \
            "sudo tvpc-controller pair-gamepad" "Pair a gamepad"
    fi
}

check_display() {
    local title="Display setup"
    if ! have kscreen-doctor; then
        add_check "display" "$S_WARN" "$title" "kscreen-doctor not installed." \
            "sudo apt-get install kscreen" "Install kscreen"
        return
    fi
    local out; out=$(kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}')
    if [[ -z $out ]]; then
        add_check "display" "$S_WARN" "$title" \
            "No enabled output reported (no monitor / wrong input?)." ""
        return
    fi
    local scale="${TVPC_SCALE:-1.5}"
    local mode="${TVPC_MODE:-auto}"
    add_check "display" "$S_OK" "$title" \
        "Output $out | scale $scale | mode $mode"
}

check_audio() {
    local title="Audio (HDMI)"
    if ! have pactl; then
        add_check "audio" "$S_WARN" "$title" "pactl not installed." \
            "sudo apt-get install pipewire pulseaudio-utils" "Install audio"
        return
    fi
    local sink; sink=$(pactl get-default-sink 2>/dev/null || echo "")
    if [[ -z $sink ]]; then
        add_check "audio" "$S_WARN" "$title" \
            "No default sink. PipeWire may still be starting." \
            "sudo systemctl --user restart pipewire" "Restart PipeWire"
    elif [[ $sink == *hdmi* ]]; then
        add_check "audio" "$S_OK" "$title" "Default sink is HDMI ($sink)"
    else
        add_check "audio" "$S_WARN" "$title" \
            "Default sink is '$sink' (not HDMI)." \
            "sudo tvpc-hdmi-audio" "Pick HDMI output"
    fi
}

check_input() {
    local title="Input devices"
    local bt="no"
    local kc="no"
    local gp="no"
    if have bluetoothctl && bluetoothctl show >/dev/null 2>&1; then
        if bluetoothctl devices Paired 2>/dev/null | grep -q .; then bt="yes"; fi
    fi
    if have kdeconnect-cli && pgrep -u "${REAL_USER:-root}" -x kdeconnectd >/dev/null 2>&1; then
        kc="yes"
    fi
    if lsusb 2>/dev/null | grep -qiE 'Xbox|DUALSHOCK|Gamepad|Controller|8BitDo'; then gp="yes"; fi
    if [[ $bt == "no" && $kc == "no" && $gp == "no" ]]; then
        add_check "input" "$S_FAIL" "$title" \
            "No gamepad, phone, or Bluetooth input paired." \
            "sudo tvpc-controller pair-gamepad" "Pair something"
    else
        add_check "input" "$S_OK" "$title" \
            "BT paired: $bt | KDE Connect: $kc | Gamepad on USB: $gp"
    fi
}

check_bigscreen() {
    local title="Plasma Bigscreen"
    if ! have plasmashell; then
        add_check "bigscreen" "$S_FAIL" "$title" "plasmashell not installed." \
            "sudo apt-get install plasma-desktop" "Install Plasma"
        return
    fi
    local session="no"
    if [[ -r /etc/sddm.conf.d/10-tvpc.conf ]]; then
        grep -q 'Session=plasma-bigscreen' /etc/sddm.conf.d/10-tvpc.conf && session="yes"
    fi
    local topbar=""
    if [[ -f /usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen/contents/ui/main.qml.tvpc-bak ]]; then
        topbar=" (top-bar patched)"
    fi
    if [[ $session == "yes" ]]; then
        add_check "bigscreen" "$S_OK" "$title" "Bigscreen is the active session$topbar"
    else
        add_check "bigscreen" "$S_OK" "$title" "Plasma is installed; not currently the active session."
    fi
}

check_vacuumtube() {
    local title="VacuumTube (YouTube)"
    if ! have flatpak; then
        add_check "vacuumtube" "$S_WARN" "$title" "flatpak not installed." \
            "sudo apt-get install flatpak" "Install flatpak"
        return
    fi
    if flatpak list 2>/dev/null | grep -qi 'vacuumtube'; then
        local hook="no"
        local uh="$REAL_HOME"
        [[ -z $uh ]] && uh="$HOME"
        local app_dir
        app_dir=$(find "$uh/.local/share/flatpak/app" /var/lib/flatpak/app -maxdepth 5 -type d -name active -path '*VacuumTube*' 2>/dev/null | head -1)
        if [[ -n $app_dir && -f $app_dir/files/index.js.tvpc-bak ]]; then hook="yes"; fi
        if [[ $hook == "yes" ]]; then
            add_check "vacuumtube" "$S_OK" "$title" "Installed, hover-horizontal-scroll patch applied."
        else
            add_check "vacuumtube" "$S_OK" "$title" "Installed (scroll patch not yet applied)."
        fi
    else
        add_check "vacuumtube" "$S_FAIL" "$title" "Not installed." \
            "flatpak install flathub rocks.shy.VacuumTube" "Install"
    fi
}

check_network() {
    local title="Network"
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
        local gw; gw=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
        add_check "network" "$S_OK" "$title" "Connected (gateway ${gw:-?})"
    else
        add_check "network" "$S_FAIL" "$title" "No default route." \
            "sudo nmcli device wifi connect '<SSID>' password '<pw>'" \
            "Connect Wi-Fi"
    fi
}

check_sddm() {
    local title="Display manager (sddm)"
    if ! have systemctl; then
        add_check "sddm" "$S_INFO" "$title" "systemctl not available."
        return
    fi
    if ! systemctl is-enabled sddm >/dev/null 2>&1; then
        add_check "sddm" "$S_FAIL" "$title" "sddm is not enabled." \
            "sudo systemctl set-default graphical.target && sudo systemctl enable sddm" \
            "Enable sddm"
    elif ! systemctl is-active sddm >/dev/null 2>&1; then
        add_check "sddm" "$S_WARN" "$title" "sddm enabled but not running." \
            "sudo systemctl start sddm" "Start sddm"
    else
        add_check "sddm" "$S_OK" "$title" "sddm is enabled and running."
    fi
}

check_storage() {
    local title="Storage & swap"
    local detail=""
    local warn=0
    local root_use; root_use=$(df -P / | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ -n $root_use && $root_use -gt 90 ]]; then
        detail+="Root ${root_use}% full. "
        warn=1
    fi
    if systemctl is-active zramswap >/dev/null 2>&1; then
        detail+="zram: active. "
    else
        detail+="zram: inactive. "
        warn=1
    fi
    if [[ $warn -eq 0 ]]; then
        add_check "storage" "$S_OK" "$title" "${detail% }"
    else
        add_check "storage" "$S_WARN" "$title" "${detail% }"
    fi
}

check_updates() {
    local title="Updates"
    if ! have apt; then
        add_check "updates" "$S_INFO" "$title" "apt not present."
        return
    fi
    local upg=0
    apt list --upgradable 2>/dev/null | grep -v '^Listing' | grep -qc . && upg=1
    local fu=0
    if have flatpak; then
        flatpak remote-ls --updates 2>/dev/null | grep -qc . && fu=1
    fi
    if [[ $upg -eq 0 && $fu -eq 0 ]]; then
        add_check "updates" "$S_OK" "$title" "Everything is up to date."
    else
        add_check "updates" "$S_INFO" "$title" \
            "apt updates: $upg | flatpak updates: $fu" \
            "sudo apt update && sudo apt upgrade" "Update apt"
    fi
}

# ---------------------------------------------------------------------------
# Output formats
# ---------------------------------------------------------------------------

# --- Plain text report (used by --report and by the console fallback) -----
print_report() {
    run_all_checks
    local n=${#CHECKS[@]} i
    echo "== tvpc status =="
    for ((i=0; i<n; i++)); do
        IFS='|' read -r id status title detail fix_cmd fix_label <<<"${CHECKS[$i]}"
        printf '  [%s] %-12s  %s\n' "$(label_for "$status")" "$title" "$detail"
        if [[ -n $fix_cmd && $status -ne 0 ]]; then
            printf '         fix: %s\n' "$fix_cmd"
        fi
    done
}

# --- --check <id>: print one line, exit 0 if OK, 1 if WARN, 2 if FAIL ------
run_single() {
    local target="$1"
    run_all_checks
    local i
    for ((i=0; i<${#CHECKS[@]}; i++)); do
        IFS='|' read -r id status title detail fix_cmd fix_label <<<"${CHECKS[$i]}"
        if [[ $id == "$target" ]]; then
            printf '%-4s %-12s %s\n' "$(label_for "$status")" "$title" "$detail"
            exit "$status"
        fi
    done
    echo "no such check: $target" >&2
    exit 1
}

# --- GUI: pick the best available dialog tool ----------------------------
pick_gui_tool() {
    if have kdialog; then echo kdialog
    elif have yad;    then echo yad
    elif have zenity; then echo zenity
    else echo none
    fi
}

# --- kdialog GUI ---------------------------------------------------------
gui_kdialog() {
    # Build the menu items
    local items_args=()
    local n=${#CHECKS[@]} i
    for ((i=0; i<n; i++)); do
        IFS='|' read -r id status title detail fix_cmd fix_label <<<"${CHECKS[$i]}"
        items_args+=("$id" "$(label_for "$status")  $title")
    done

    while true; do
        local choice
        choice=$(kdialog --menu "tvpc — system status" \
            "Pick a component to see details" "${items_args[@]}" 2>/dev/null) || return 0
        [[ -z $choice ]] && return 0

        # Find the chosen check
        for ((i=0; i<n; i++)); do
            IFS='|' read -r id status title detail fix_cmd fix_label <<<"${CHECKS[$i]}"
            if [[ $id == "$choice" ]]; then
                local btns=("OK")
                local msg="$title

$detail

"
                if [[ -n $fix_cmd ]]; then
                    msg+="Suggested fix:
  $fix_cmd
"
                    btns=("Run fix" "OK")
                fi
                local btn
                btn=$(kdialog --warning=yesno "$msg" --title "$title" 2>/dev/null) || true
                if [[ $btn == "Run fix" || $btn == "yes" ]]; then
                    if [[ -n $fix_cmd ]]; then
                        kdialog --passivepopup "Running: $fix_cmd" 3 2>/dev/null || true
                        bash -c "$fix_cmd" || true
                    fi
                fi
                break
            fi
        done
    done
}

# --- yad GUI (richer: status icons + detail pane) ------------------------
gui_yad() {
    local n=${#CHECKS[@]} i
    local list_data=()
    for ((i=0; i<n; i++)); do
        IFS='|' read -r id status title detail fix_cmd fix_label <<<"${CHECKS[$i]}"
        local mark
        case "$status" in
            0) mark="✓" ;;
            1) mark="⚠" ;;
            2) mark="✗" ;;
            *) mark="·" ;;
        esac
        list_data+=("$mark" "$title" "$detail" "$id")
    done

    yad --list \
        --title="tvpc — system status" \
        --width=900 --height=600 \
        --button="Run fix:gtk-execute" \
        --button="Refresh:gtk-refresh" \
        --button="Close:gtk-close" \
        --columns=3 \
        --column=@r \
        --column="Component" \
        --column="Detail" \
        --column=ID:HD \
        "${list_data[@]}" 2>/dev/null || true
}

# --- zenity fallback -----------------------------------------------------
gui_zenity() {
    local text
    text=$(print_report)
    zenity --text-info --title="tvpc — system status" \
        --width=700 --height=600 \
        --filename=<(echo "$text") 2>/dev/null || true
}

# --- Console fallback (no GUI) -------------------------------------------
gui_console() {
    print_report
    echo
    read -rp 'Enter a check ID for details (or Enter to quit): ' sel
    [[ -z $sel ]] && return
    for entry in "${CHECKS[@]}"; do
        IFS='|' read -r id status title detail fix_cmd fix_label <<<"$entry"
        if [[ $id == "$sel" ]]; then
            echo
            echo "$title"
            echo "  $detail"
            [[ -n $fix_cmd ]] && echo "  fix: $fix_cmd"
            return
        fi
    done
    echo "no such check: $sel"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-gui}" in
    --report|report) print_report ;;
    --check)         run_single "${2:-}" ;;
    gui|"")          gui_$(pick_gui_tool) ;;
    help|--help|-h)
        cat <<EOF
tvpc-status — visual dashboard

Usage:
  tvpc-status               open the GUI dashboard
  tvpc-status --report      plain-text report
  tvpc-status --check ID    run one check, print one line, exit 0/1/2
  tvpc-status help

GUI tool auto-pick: kdialog (Plasma) → yad → zenity → console.
Run as your normal user. The dialog will prompt for root when a fix
needs it.
EOF
        ;;
    *) echo "Unknown argument: $1 (try: tvpc-status help)"; exit 1 ;;
esac

}

# ---------------------------------------------------------------------------
# Module: Tweaks & VacuumTube Scroll
# ---------------------------------------------------------------------------
vacuumtube_scroll() {
set -euo pipefail

APP_ID=rocks.shy.VacuumTube
PRELOAD_DIR_REL=".var/app/${APP_ID}/config/${APP_ID}"
HOOK_NAME="tvpc-hover-scroll.js"
MARKER_START="/* >>> tvpc hover-horizontal-scroll >>> */"
MARKER_END="/* <<< tvpc hover-horizontal-scroll <<< */"

HOOK_JS='/* tvpc hover-horizontal-scroll for VacuumTube.
 * Run from the Electron preload context. Vertical wheel over a
 * horizontally-scrollable element becomes horizontal scroll. */
(function () {
    var SKIP = { INPUT: 1, TEXTAREA: 1, SELECT: 1 };
    function scrollerOf(el) {
        var n = el;
        while (n && n !== document && n !== document.documentElement) {
            if (n.scrollWidth > n.clientWidth + 4) return n;
            n = n.parentNode;
        }
        return null;
    }
    function onWheel(e) {
        if (e.ctrlKey) return; // pinch-zoom
        var t = e.target;
        if (t && t.nodeName && SKIP[t.nodeName]) return;
        if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
        var sc = scrollerOf(t);
        if (!sc || sc.scrollWidth <= sc.clientWidth + 1) return;
        sc.scrollLeft += e.deltaY;
        e.preventDefault();
        e.stopPropagation();
    }
    window.addEventListener("wheel", onWheel, { passive: false, capture: true });
})();'

resolve_user_home() {
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then echo "/home/$SUDO_USER"
    elif [[ $EUID -eq 0 && -n ${HOME:-} ]]; then echo "$HOME"
    else echo "$HOME"; fi
}

detect_app_dir() {
    local uh; uh="$(resolve_user_home)"
    for prefix in "$uh/.local/share/flatpak/app" "/var/lib/flatpak/app"; do
        local d="$prefix/$APP_ID/x86_64/stable/active"
        [[ -d $d/files ]] && { echo "$d"; return 0; }
    done
    return 1
}

get_main_file() {
    local files="$1" pkg
    pkg="$files/package.json"
    [[ -f $pkg ]] || { echo "index.js"; return; }
    grep -m1 '"main"' "$pkg" | sed -E 's/.*"main"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | tr -d '[:space:]' | grep -v '^$' || echo "index.js"
}

# Resolve a preload value from a `preload: <expr>` line in the main file.
# Handles `path.join(__dirname, 'x.js')`, `'x.js'`, `"x.js"`, and bare tokens.
resolve_existing_preload() {
    local main="$1" main_dir
    local line; line=$(grep -m1 -E '^[[:space:]]*preload[[:space:]]*:' "$main" || true)
    [[ -z $line ]] && return 1
    local expr=${line#*preload:}
    expr="${expr%,}"   # drop trailing comma
    expr="$(echo "$expr" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    main_dir="$(dirname "$main")"
    case "$expr" in
        path.join*)
            local args=${expr#path.join(}; args=${args%)};
            local tail; tail=$(echo "$args" | tr ',' '\n' | tail -1 | sed -E "s/^[[:space:]]*['\"]//; s/['\"][[:space:]]*$//")
            [[ "$tail" = /* ]] && echo "$tail" || echo "$main_dir/$tail"
            ;;
        \'*\'|\"*\")
            local s=${expr#\'}; s=${s%\'}; s=${s#\"}; s=${s%\"}
            [[ "$s" = /* ]] && echo "$s" || echo "$main_dir/$s"
            ;;
        *)
            [[ "$expr" = /* ]] && echo "$expr" || echo "$main_dir/$expr"
            ;;
    esac
}

write_file() { # write_file <path> <owner> <mode> [sudo]
    local p="$1" owner="$2" mode="$3" use_sudo="${4:-}"
    if [[ -n $use_sudo ]]; then
        echo "$HOOK_JS" | sudo tee "$p" >/dev/null
        sudo chown "$owner" "$p"
        sudo chmod "$mode" "$p"
    else
        printf '%s\n' "$HOOK_JS" >"$p"
        chown "$owner" "$p" 2>/dev/null || true
        chmod "$mode" "$p"
    fi
}

# ----- subcommands -----
do_status() {
    local app_dir; app_dir="$(detect_app_dir)" || { echo "VacuumTube flatpak not installed."; return 1; }
    local files="$app_dir/files"
    local main; main="$(get_main_file "$files")"
    local main_path="$files/$main"
    echo "Flatpak active dir: $app_dir"
    echo "Main file:          $main_path"
    local existing; existing="$(resolve_existing_preload "$main_path" 2>/dev/null || true)"
    if [[ -n $existing ]]; then
        echo "Existing preload:   $existing"
        if [[ -f $existing ]] && grep -qF "$MARKER_START" "$existing"; then
            echo "tvpc hook:          APPLIED in $existing"
        else
            echo "tvpc hook:          not applied (preload has no tvpc block)"
        fi
    else
        echo "Existing preload:   (none declared in $main)"
        local uh; uh="$(resolve_user_home)"
        local our="$uh/$PRELOAD_DIR_REL/$HOOK_NAME"
        if [[ -f $our ]]; then
            echo "Standalone preload: $our (present)"
            if grep -qF "preload" "$main_path" 2>/dev/null; then
                echo "tvpc hook:          standalone preload in place"
            else
                echo "tvpc hook:          preload file present but index.js not patched?"
            fi
        else
            echo "tvpc hook:          not applied"
        fi
    fi
}

do_apply() {
    local app_dir; app_dir="$(detect_app_dir)" || { echo "VacuumTube flatpak not found." >&2; exit 1; }
    local files="$app_dir/files"
    local main; main="$(get_main_file "$files")"
    local main_path="$files/$main"
    [[ -f $main_path ]] || { echo "Main file not found: $main_path" >&2; exit 1; }

    local uh; uh="$(resolve_user_home)"
    local user="tv"
    [[ -n ${SUDO_USER:-} ]] && user="$SUDO_USER"
    [[ $EUID -ne 0 && -n ${USER:-} ]] && user="$USER"

    # Backup the main file
    local bak="${main_path}.tvpc-bak"
    [[ -f $bak ]] || { cp -a "$main_path" "$bak"; echo "Backup -> $bak"; }

    local existing; existing="$(resolve_existing_preload "$main_path" 2>/dev/null || true)"

    if [[ -n $existing && -f $existing ]]; then
        # ----- Path A: append to the existing preload -----
        if grep -qF "$MARKER_START" "$existing"; then
            echo "Hook already present in $existing"
            return 0
        fi
        if [[ -w $existing ]]; then
            {
                printf '\n%s\n' "$MARKER_START"
                printf '%s\n' "$HOOK_JS"
                printf '%s\n' "$MARKER_END"
            } >>"$existing"
            echo "Appended hook -> $existing (no index.js change)"
        else
            # Try via sudo (system flatpak): chmod, append, leave writable for future updates
            {
                printf '\n%s\n' "$MARKER_START"
                printf '%s\n' "$HOOK_JS"
                printf '%s\n' "$MARKER_END"
            } | sudo tee -a "$existing" >/dev/null
            echo "Appended hook -> $existing (via sudo)"
        fi
    else
        # ----- Path B: standalone preload in user config + patch index.js -----
        local dest="$uh/$PRELOAD_DIR_REL/$HOOK_NAME"
        mkdir -p "$(dirname "$dest")"
        if [[ -w $(dirname "$dest") ]]; then
            printf '%s\n' "$HOOK_JS" >"$dest"
            chown "$user" "$dest" 2>/dev/null || true
            chmod 0644 "$dest"
        else
            sudo mkdir -p "$(dirname "$dest")"
            sudo chown "$user" "$(dirname "$dest")" 2>/dev/null || true
            printf '%s\n' "$HOOK_JS" | sudo tee "$dest" >/dev/null
            sudo chown "$user" "$dest"
            sudo chmod 0644 "$dest"
        fi
        echo "Wrote standalone preload -> $dest"

        # Patch main_path: set webPreferences.preload to dest
        local esc; esc=$(printf '%s' "$dest" | sed "s/'/'\\\\''/g")
        if grep -qE '^[[:space:]]*preload[[:space:]]*:' "$main_path"; then
            # Replace existing preload value
            if [[ -w $main_path ]]; then
                sed -i -E "s|^[[:space:]]*preload[[:space:]]*:[[:space:]]*.*$|    preload: '${esc}',|" "$main_path"
            else
                sudo sed -i -E "s|^[[:space:]]*preload[[:space:]]*:[[:space:]]*.*$|    preload: '${esc}',|" "$main_path"
            fi
            echo "Replaced existing preload value in $main"
        elif grep -qE '^[[:space:]]*webPreferences[[:space:]]*:' "$main_path"; then
            # Inject preload: after webPreferences: {
            if [[ -w $main_path ]]; then
                sed -i -E "/^[[:space:]]*webPreferences[[:space:]]*:[[:space:]]*\{/a\\    preload: '${esc}'," "$main_path"
            else
                sudo sed -i -E "/^[[:space:]]*webPreferences[[:space:]]*:[[:space:]]*\{/a\\    preload: '${esc}'," "$main_path"
            fi
            echo "Injected preload into webPreferences in $main"
        else
            # No webPreferences at all — add one after `new BrowserWindow({`
            if [[ -w $main_path ]]; then
                sed -i -E "/new[[:space:]]+BrowserWindow[[:space:]]*\([[:space:]]*\{/a\\    webPreferences: { preload: '${esc}' }," "$main_path"
            else
                sudo sed -i -E "/new[[:space:]]+BrowserWindow[[:space:]]*\([[:space:]]*\{/a\\    webPreferences: { preload: '${esc}' }," "$main_path"
            fi
            echo "Added webPreferences with preload in $main"
        fi
    fi

    echo
    echo "Done. Restart VacuumTube (close + reopen) to load the preload."
    echo "Re-run this script after 'flatpak update' to re-apply."
}

do_revert() {
    local app_dir; app_dir="$(detect_app_dir 2>/dev/null || true)"
    if [[ -z $app_dir ]]; then echo "VacuumTube flatpak not found."; return 0; fi
    local files="$app_dir/files"
    local main; main="$(get_main_file "$files")"
    local main_path="$files/$main"
    local bak="${main_path}.tvpc-bak"

    # Always try to remove the hook block from the existing preload
    local existing; existing="$(resolve_existing_preload "$main_path" 2>/dev/null || true)"
    if [[ -n $existing && -f $existing && -r $existing ]]; then
        if grep -qF "$MARKER_START" "$existing"; then
            local tmp; tmp="$(mktemp)"
            awk -v start="$MARKER_START" -v end="$MARKER_END" '
                $0==start {skip=1; next}
                $0==end   {skip=0; next}
                !skip     {print}
            ' "$existing" >"$tmp"
            if [[ -w $existing ]]; then
                cp "$tmp" "$existing"
            else
                sudo cp "$tmp" "$existing"
            fi
            rm -f "$tmp"
            echo "Removed hook block from $existing"
        fi
    fi

    # Restore index.js backup if it exists
    if [[ -f $bak ]]; then
        if [[ -w $main_path ]] || $EUID -eq 0; then
            cp -a "$bak" "$main_path"
            echo "Restored $main from backup"
        else
            sudo cp -a "$bak" "$main_path"
            echo "Restored $main from backup (via sudo)"
        fi
        rm -f "$bak"
    fi

    # Remove standalone preload if present
    local uh; uh="$(resolve_user_home)"
    local dest="$uh/$PRELOAD_DIR_REL/$HOOK_NAME"
    if [[ -f $dest ]]; then
        rm -f "$dest"
        echo "Removed standalone preload $dest"
    fi

    echo "Reverted."
}

case "${1:-apply}" in
    apply)   do_apply ;;
    status)  do_status ;;
    revert)  do_revert ;;
    *)       echo "Usage: $0 {apply|status|revert}"; exit 1 ;;
esac

}

subcmd_tweaks() {
  if [[ "${1:-}" == "vacuumtube-scroll" ]]; then
    shift
    vacuumtube_scroll "$@"
    return
  fi
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS=/etc/default/tvpc
TVPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
CEC_MAP="${TVPC_CEC_MAP:-/etc/tvpc/cec-map.conf}"
CEC_MACROS=/etc/tvpc/cec-macros.conf
CEC_CODES=(00 01 02 03 04 09 0d 41 42 43 44 45 46 47 48)
CEC_NAMES=(OK Up Down Left Right "Home/Root" Exit Vol+ Vol- Mute Play Pause Stop Next)
EQ_CONF=/etc/pipewire/pipewire.conf.d/99-tvpc-eq.conf
EQ_PRESETS=(flat warm balanced bright punchy)
EQ_BANDS_DEFAULT=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
TVPC_PLUGIN_IDS=()
TVPC_PLUGIN_LABELS=()

if [[ -f $DEFAULTS ]]; then
    . "$DEFAULTS"
fi

target_home() {
    if [[ $EUID -eq 0 ]]; then
        getent passwd "$TVPC_USER" | cut -d: -f6
    else
        echo "$HOME"
    fi
}

kglobals_path() { echo "$(target_home)/.config/kdeglobals"; }
blacklist_rc() { echo "$(target_home)/.config/applications-blacklistrc"; }
applets_rc() { echo "$(target_home)/.config/plasma-org.kde.plasma.desktop-appletsrc"; }
power_rc() { echo "$(target_home)/.config/powermanagementprofilesrc"; }
autostart_dir() { echo "$(target_home)/.config/autostart"; }

is_root() { [[ $EUID -eq 0 ]]; }

set_default() {
    local k="$1" v="$2"
    if ! is_root; then return 1; fi
    if [[ -f $DEFAULTS ]] && grep -q "^$k=" "$DEFAULTS"; then
        sed -i "s|^$k=.*|$k=$v|" "$DEFAULTS"
    else
        mkdir -p "$(dirname "$DEFAULTS")"
        echo "$k=$v" >>"$DEFAULTS"
    fi
}

kde_set() {
    local section="$1" key="$2" val="$3" kg
    kg="$(kglobals_path)"
    mkdir -p "$(dirname "$kg")"
    if [[ ! -f $kg ]]; then
        printf '[General]\n' >"$kg"
    fi
    local tmp; tmp="$(mktemp)"
    local insec=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "[$section]" ]]; then
            insec=1
        fi
        if [[ $insec -eq 1 ]] && [[ $line == "$key="* ]]; then
            echo "$key=$val"
            insec=2
            continue
        fi
        echo "$line"
    done <"$kg" >"$tmp"
    if [[ $insec -lt 2 ]]; then
        awk -v sec="[$section]" -v kv="$key=$val" '
            {print}
            $0==sec && !done {print kv; done=1}
        ' "$kg" >"$tmp"
    fi
    mv "$tmp" "$kg"
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$kg" 2>/dev/null || true
    fi
}

get_kg() {
    local key="$1" kg
    kg="$(kglobals_path)"
    if [[ -f $kg ]]; then
        grep "^$key=" "$kg" | head -1 | sed 's/^[^=]*=//'
    fi
}

list_apps() {
    local d f type nodisp term name id home
    home="$(target_home)"
    for d in /usr/share/applications /usr/local/share/applications \
             "$home/.local/share/applications" \
             /var/lib/flatpak/exports/share/applications; do
        [[ -d $d ]] || continue
        for f in "$d"/*.desktop; do
            [[ -f $f ]] || continue
            type="$(sed -n 's/^Type=//p' "$f" | head -1)"
            nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
            term="$(sed -n 's/^Terminal=//p' "$f" | head -1)"
            [[ $type == Application ]] || continue
            [[ $nodisp == true ]] && continue
            [[ $term == true ]] && continue
            name="$(sed -n 's/^Name=//p' "$f" | head -1)"
            id="$(basename "$f" .desktop)"
            printf '%s\t%s\n' "$id" "${name:-$id}"
        done
    done | sort -u
}

read_blacklist() {
    local rc; rc="$(blacklist_rc)"
    if [[ -f $rc ]]; then
        sed -n 's/^blacklist=//p' "$rc" | tr ',' '\n' | sed '/^$/d'
    fi
}

app_is_hidden() {
    local id="$1"
    local bl; bl="$(read_blacklist)"
    echo "$bl" | grep -qx "$id"
}

write_blacklist() {
    local rc list; rc="$(blacklist_rc)"
    list="$(sort -u | sed '/^$/d' | paste -sd, -)"
    mkdir -p "$(dirname "$rc")"
    cat >"$rc" <<RC
[Applications]
blacklist=$list

[General]
blacklist=$list
RC
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true
        mkdir -p /etc/skel/.config
        cp "$rc" /etc/skel/.config/applications-blacklistrc 2>/dev/null || true
    fi
    echo "$list"
}

hide_app() {
    local id="$1" rc bl
    rc="$(blacklist_rc)"
    mapfile -t bl < <(read_blacklist)
    printf '%s\n' "${bl[@]:-}" "$id" | write_blacklist >/dev/null
    local appletrc; appletrc="$(applets_rc)"
    if [[ -f $appletrc ]]; then
        sed -i -E "s/(favorites=.*)$id\.desktop,?/\1/; s/,,/,/g; s/(favorites=.*),\$/\1/" "$appletrc"
        if is_root; then
            chown "$TVPC_USER:$TVPC_USER" "$appletrc" 2>/dev/null || true
        fi
    fi
}

show_app() {
    local id="$1" bl keep
    mapfile -t bl < <(read_blacklist)
    keep=()
    for c in "${bl[@]:-}"; do
        if [[ -n "$c" && "$c" != "$id" ]]; then
            keep+=("$c")
        fi
    done
    printf '%s\n' "${keep[@]}" | write_blacklist >/dev/null
    if is_root; then
        local appletrc; appletrc="$(applets_rc)"
        if [[ -f $appletrc ]]; then
            chown "$TVPC_USER:$TVPC_USER" "$appletrc" 2>/dev/null || true
        fi
    fi
}

output_id() {
    command -v kscreen-doctor >/dev/null 2>&1 || return 1
    kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}'
}

apply_scale_live() {
    local factor="$1" out
    out="$(output_id)"
    [[ -n $out ]] || return 0
    kscreen-doctor "output.$out.scale.$factor" >/dev/null 2>&1 || true
}

apply_mode_live() {
    local mode="$1" out
    out="$(output_id)"
    [[ -n $out ]] || return 0
    kscreen-doctor "output.$out.mode.$mode" >/dev/null 2>&1 || true
}

do_scale() {
    local factor="$1"
    if [[ -z $factor || ! $factor =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "scale must be a number like 1.5 (got '$factor')" >&2
        return 1
    fi
    apply_scale_live "$factor"
    if set_default TVPC_SCALE "$factor"; then
        echo "UI scale -> $factor (live now; persisted in $DEFAULTS)"
    else
        echo "UI scale -> $factor (live now; NOT persisted — run 'sudo tvpc-tweaks scale $factor' to survive reboot)"
    fi
}

do_font() {
    local arg="$1"
    case "$arg" in
        ''|*[!0-9]*)
            echo "font size must be a number (e.g. 13)" >&2
            return 1
            ;;
    esac
    kde_set "General" "font" "Noto Sans,$arg,-1,5,50,0,0,0,0,0"
    kde_set "General" "menuFont" "Noto Sans,$arg,-1,5,50,0,0,0,0,0"
    kde_set "General" "fixed" "Noto Sans Mono,$((arg-1)),-1,5,50,0,0,0,0,0"
    kde_set "General" "toolBarFont" "Noto Sans,$((arg-1)),-1,5,50,0,0,0,0,0"
    kde_set "General" "smallestReadableFont" "Noto Sans,$((arg-2)),-1,5,50,0,0,0,0,0"
    if set_default TVPC_FONT_SIZE "$arg"; then
        echo "Base font size -> $arg (scales the whole Kirigami/Bigscreen UI; persisted)"
    else
        echo "Base font size -> $arg (log out and back in; NOT persisted — 'sudo tvpc-tweaks font $arg')"
    fi
}

do_theme() {
    local t="$1"
    case "$t" in
        dark)
            kde_set "General" "ColorScheme" "Breeze Dark"
            kde_set "General" "LookAndFeelPackage" "org.kde.breezedark.desktop"
            kde_set "General" "widgetStyle" "Breeze"
            echo "Theme -> dark (log out and back in to apply)"
            ;;
        light)
            kde_set "General" "ColorScheme" "Breeze"
            kde_set "General" "LookAndFeelPackage" "org.kde.breeze.desktop"
            kde_set "General" "widgetStyle" "Breeze"
            echo "Theme -> light (log out and back in to apply)"
            ;;
        midnight|oled|cyberpunk|sunset|emerald)
            local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            local tt=""
            if command -v subcmd_theme >/dev/null 2>&1; then subcmd_theme set "$t"; return; fi
            for cand in "$script_dir/tvpc.sh" /usr/local/bin/tvpc-bigscreen-theme /usr/local/bin/tvpc; do
                [[ -x $cand ]] && { tt="$cand"; break; }
            done
            if [[ -n $tt ]]; then
                "$tt" set "$t"
            else
                echo "Theme -> $t (tvpc-bigscreen-theme not found)"
            fi
            ;;
        *)
            echo "usage: tvpc-tweaks theme dark|light|midnight|oled|cyberpunk|sunset|emerald" >&2
            return 1
            ;;
    esac
}

do_mode() {
    local mode="$1"
    if [[ $mode == auto ]]; then
        if set_default TVPC_MODE ""; then
            echo "Display mode -> auto (uses the TV's EDID; persisted)"
        else
            echo "Display mode -> auto (NOT persisted — run 'sudo tvpc-tweaks mode auto')"
        fi
        return 0
    fi
    apply_mode_live "$mode"
    if set_default TVPC_MODE "$mode"; then
        echo "Display mode -> $mode (live now; persisted)"
    else
        echo "Display mode -> $mode (live now; NOT persisted — 'sudo tvpc-tweaks mode $mode')"
    fi
}

do_idle() {
    local on="$1" rc
    rc="$(power_rc)"
    mkdir -p "$(dirname "$rc")"
    if [[ $on == on ]]; then
        cat >"$rc" <<'EOF'
[AC][DPMSControl]
idleTime=86400
lockBeforeTurnOff=0

[AC][DimDisplay]
idleTime=86400

[AC][SuspendSession]
idleTime=86400
suspendType=0

[AC][HandleButtonEvents]
lidAction=0
powerButtonAction=1
EOF
        echo "TV sleep -> off (stays awake; applies next session)"
    else
        cat >"$rc" <<'EOF'
[AC][DPMSControl]
idleTime=300
lockBeforeTurnOff=0

[AC][DimDisplay]
idleTime=300

[AC][SuspendSession]
idleTime=600
suspendType=1

[AC][HandleButtonEvents]
lidAction=0
powerButtonAction=1
EOF
        echo "TV sleep -> allowed after ~5 min idle (applies next session)"
    fi
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true
    fi
}

ensure_wallpaper() {
    local dest="$1"
    command -v python3 >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$dest")"
    python3 - "$dest" <<'PY'
import sys, struct, zlib

def png(path, top_rgb, bot_rgb, w=1920, h=1080):
    """Write a solid-color PNG. A 64px image stretched across an 80" TV
    is a single visible pixel; this is big enough to look right at any
    resolution the compositor picks."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter byte
        # Subtle vertical gradient: slightly lighter at the centre.
        t = y / (h - 1)
        # Ease the gradient so the bottom stays near-black.
        eased = t * t
        r = int(top_rgb[0] + (bot_rgb[0] - top_rgb[0]) * eased)
        g = int(top_rgb[1] + (bot_rgb[1] - top_rgb[1]) * eased)
        b = int(top_rgb[2] + (bot_rgb[2] - top_rgb[2]) * eased)
        for _ in range(w):
            raw += bytes((r, g, b))

    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(raw))
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))

# Dark slate with a barely-visible vertical gradient.
png(sys.argv[1], (22, 26, 33), (10, 12, 16))
PY
    return 0
}

apply_wallpaper() {
    is_root && return 0
    local dest="$(target_home)/.local/share/tvpc/wallpaper.png"
    ensure_wallpaper "$dest" 2>/dev/null || return 0
    if [[ -x /usr/bin/plasma-apply-wallpaperimage ]]; then
        plasma-apply-wallpaperimage "$dest" >/dev/null 2>&1 && echo "  wallpaper set (dark)" \
            || echo "  (wallpaper tool present but did not apply)"
    else
        echo "  (wallpaper skipped: no plasma-apply-wallpaperimage)"
    fi
}

switch_session() {
    local target="${1:-auto}"
    local tool
    if command -v subcmd_session >/dev/null 2>&1; then subcmd_session "$@"; return; fi
    for cand in "$REPO_ROOT/scripts/tvpc.sh" /usr/local/bin/tvpc-session /usr/local/bin/tvpc; do
        if [[ -x $cand ]]; then
            tool="$cand"
            break
        fi
    done
    if [[ -z $tool ]]; then
        echo "!! tvpc-session not found; try manually: sudo tvpc-session $target" >&2
        return 1
    fi
    "$tool" "$target"
}

need_root() {
    if is_root; then
        return 0
    fi
    echo "Need root for: $1 (run with sudo)" >&2
    return 1
}

list_autostart() {
    local dir d f id name
    dir="$(autostart_dir)"
    for d in /usr/share/applications "$dir"; do
        for f in "$d"/*.desktop; do
            [[ -f $f ]] || continue
            grep -q '^Hidden=true' "$f" && continue
            grep -q '^X-GNOME-Autostart-enabled=false' "$f" && continue
            name="$(sed -n 's/^Name=//p' "$f" | head -1)"
            id="$(basename "$f" .desktop)"
            printf '%s\t%s\n' "$id" "${name:-$id}"
        done
    done | sort -u
}

autostart_add() {
    local id="$1" desktop_file
    local app_dir="/usr/share/applications"
    for d in /usr/share/applications /usr/local/share/applications; do
        if [[ -f "$d/$id.desktop" ]]; then
            desktop_file="$d/$id.desktop"
            break
        fi
    done
    if [[ -z $desktop_file ]]; then
        echo "App $id.desktop not found" >&2
        return 1
    fi
    local dest; dest="$(autostart_dir)/$id.desktop"
    mkdir -p "$(dirname "$dest")"
    if [[ -f $dest ]]; then
        echo "Already autostarted: $id"
        return 0
    fi
    cp "$desktop_file" "$dest"
    sed -i '/^Exec=/s/$/ \&/' "$dest" 2>/dev/null || true
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$dest" 2>/dev/null || true
    fi
    echo "Added to autostart: $id"
}

autostart_remove() {
    local id="$1" dest
    dest="$(autostart_dir)/$id.desktop"
    if [[ -f $dest ]]; then
        rm -f "$dest"
        echo "Removed from autostart: $id"
    else
        echo "Not in autostart: $id"
    fi
}

detect_edid() {
    local out; out="$(output_id)"
    if [[ -n $out ]]; then
        echo "Output device: $out"
    fi
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local edid_raw; edid_raw=$(kscreen-doctor -o 2>/dev/null | grep -i edid | head -1)
        if [[ -n $edid_raw ]]; then
            echo "EDID info: $edid_raw"
        fi
    fi
    echo "Suggested modes:"
    if command -v cvt >/dev/null 2>&1; then
        echo "  1920x1080@60: cvt 1920 1080 60"
    elif command -v gtf >/dev/null 2>&1; then
        echo "  1920x1080@60: gtf 1920 1080 60"
    else
        echo "  Install cvt or gtf for mode calculation"
    fi
}

cmd_status() {
    local scale font theme mode
    scale="${TVPC_SCALE:-1.5}"
    font="$(get_kg font | cut -d, -f2)"
    theme="$(get_kg ColorScheme)"
    mode="${TVPC_MODE:-auto}"
    echo "== tvpc tweaks status =="
    echo "session  : ${TVPC_SESSION:-unset}"
    echo "scale    : $scale"
    echo "font     : ${font:-unset}pt base"
    echo "theme    : $theme"
    echo "mode     : $mode"
    echo
    echo "hidden from home screen:"
    local hidden; hidden="$(read_blacklist | paste -sd, -)"
    echo "  ${hidden:- (none)}"
    echo
    echo "autostart:"
    local a; a="$(list_autostart | cut -f2 | paste -sd, -)"
    echo "  ${a:- (none)}"
}

usage() {
    cat <<'EOF'
tvpc-tweaks -- TV box customization tool

Usage: tvpc-tweaks <command> [args]

Commands:
  scale <factor>   Set UI scale (e.g. 1.5)
  font <size>      Set base font size in points
  apps             List apps (shown/hidden from home)
  hide <app,ids>   Hide apps from home screen
  show <app,ids>   Show hidden apps on home screen
  theme <dark|light>  Set color theme
  mode <mode|auto> Set display mode (e.g. 1920x1080@60 or auto)
  idle <on|off>    Allow TV sleep or stay awake
  density <level>  UI density (comfortable/normal/compact)
  hdr <on|off>     Toggle HDR output (live)
  edid             Detect EDID and suggest modes
  setup            Apply TVPC_SCALE/TVPC_MODE live (autostart)
  audio <status|volume up/down N|mute|profile NAME>  HDMI audio control
  autostart        Manage autostart apps (interactive)
  session <name>   Switch desktop session (needs root)
  status           Show current configuration
  cec              Edit CEC key mappings (needs root)
  install-launcher Install home-screen launcher
  vacuum-only      Home: only VacuumTube + All Apps
  home-preset      Full home (dark theme + VacuumTube hero + Power + Setup + Update + All Apps)
  addapps          Pick apps to add back to the home screen
  --help, -h       Show this help

Run without arguments for interactive TUI.
EOF
}

vacuum_only() {
    echo "Setting vacuum-only home (only VacuumTube + All Apps visible)..."
    # Make sure VacuumTube and All Apps are shown, everything else hidden.
    show_app "vacuumtube" 2>/dev/null || true
    show_app "tvpc-allapps" 2>/dev/null || true
    while IFS=$'\t' read -r id name; do
        [[ $id == "vacuumtube" || $id == "tvpc-allapps" ]] && continue
        hide_app "$id" 2>/dev/null || true
    done < <(list_apps)
    install_home_tiles
    install_addapps_tile
    echo "Home vacuum-only: VacuumTube + All Apps."
}

home_preset() {
    echo "Applying full home-screen preset (VacuumTube + Settings + Cameras + All Apps + Chromium + Update)..."
    do_theme "dark"
    local keep="vacuumtube io.github.vacuumtube.VacuumTube YouTube tvpc-setup tvpc-cameras tvpc-cameras-gui tvpc-allapps chromium chromium-browser org.chromium.Chromium tvpc-update tvpc-power"
    local id
    while IFS=$'\t' read -r id name; do
        local keepit=0
        for k in $keep; do
            [[ $id == "$k" ]] && keepit=1
        done
        [[ $keepit -eq 0 ]] && hide_app "$id" 2>/dev/null || true
    done < <(list_apps)

    for k in $keep; do
        show_app "$k" 2>/dev/null || true
    done
    install_home_tiles
    install_addapps_tile
    apply_wallpaper
    echo "Home preset applied. Log out and back in to see changes."
}

install_launcher() {
    local kdegk; kdegk="$(kglobals_path)"
    if [[ -f $kdegk ]]; then
        if ! grep -q "tvpc-tweaks.desktop" "$kdegk" 2>/dev/null; then
            echo "Could not add to favorites"
        fi
    fi
    if is_root; then
        mkdir -p /usr/share/applications
        cat >/usr/share/applications/tvpc-tweaks.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=TV Tweaks
GenericName=tvpc adjustments
Comment=UI scaling, home-screen apps, and other tvpc tweaks
Exec=/usr/local/bin/tvpc-tweaks
Terminal=true
Icon=preferences-system
Categories=Settings;
Keywords=tvpc;tweaks;scaling;home screen;
EOF
        echo "Installed tvpc-tweaks launcher to /usr/share/applications/"
    else
        echo "Need root to install launcher system-wide"
    fi
}

# Install the home-screen tile launchers (Power + Setup + Update + All Apps).
# Called by home_preset, curate_home, and vacuum_only so the tiles
# exist regardless of which curation mode the user picks.
install_home_tiles() {
    local dirs=()
    if is_root; then
        dirs+=("/usr/share/applications")
    fi
    dirs+=("$(target_home)/.local/share/applications")
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
        cat >"$d/tvpc-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Settings
Comment=Configure display, audio, remote, CEC, and TV settings
Exec=/usr/local/bin/tvpc gui setup
Icon=preferences-system
Terminal=false
Categories=Settings;
Keywords=tvpc;setup;settings;cec;audio;
EOF
        cat >"$d/tvpc-cameras-gui.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Security Cameras
Comment=View live CCTV security camera streams and recordings
Exec=/usr/local/bin/tvpc cameras gui
Icon=camera-web
Terminal=false
Categories=AudioVideo;Video;
Keywords=tvpc;cameras;cctv;nvr;security;
EOF
        cat >"$d/tvpc-update.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Update System
Comment=Check for and apply updates from Git, apt, and Flatpak
Exec=/usr/local/bin/tvpc gui update
Icon=system-software-update
Terminal=false
Categories=System;
Keywords=tvpc;update;git;upgrade;
EOF
        cat >"$d/tvpc-allapps.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=All Applications
Comment=Browse every installed application
Exec=/usr/local/bin/tvpc gui allapps
Icon=view-grid
Terminal=false
Categories=Utility;
Keywords=tvpc;apps;
EOF
        cat >"$d/tvpc-power.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Power
Comment=Restart, shut down, or log out
Exec=/usr/local/bin/tvpc gui power
Terminal=false
Icon=system-shutdown
Categories=Settings;
Keywords=tvpc;power;shutdown;reboot;
EOF
    done
    if is_root; then
        chown -R "$TVPC_USER:$TVPC_USER" "$(target_home)/.local/share/applications" 2>/dev/null || true
    fi
    echo "Home tiles installed (Settings + Cameras + All Apps + Update + Power)."
}

# Install the "Add Apps" tile that opens a picker to un-hide apps on the home.
install_addapps_tile() {
    if ! is_root; then return 0; fi
    mkdir -p /usr/share/applications
    cat >/usr/share/applications/tvpc-addapps.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Add Apps
Comment=Choose apps to show on the home screen
Exec=/usr/local/bin/tvpc tweaks addapps
Terminal=false
Icon=list-add
Categories=Settings;
Keywords=tvpc;apps;home;
EOF
    chown "$TVPC_USER:$TVPC_USER" /usr/share/applications/tvpc-addapps.desktop 2>/dev/null || true
}

# Home: VacuumTube + Settings + Cameras + All Apps + Chromium + Update. Everything else hidden.
curate_home() {
    local keep="vacuumtube io.github.vacuumtube.VacuumTube YouTube tvpc-setup tvpc-cameras tvpc-cameras-gui tvpc-allapps chromium chromium-browser org.chromium.Chromium tvpc-update"
    local id
    while IFS=$'\t' read -r id name; do
        local keepit=0
        for k in $keep; do
            [[ $id == "$k" ]] && keepit=1
        done
        [[ $keepit -eq 0 ]] && hide_app "$id" 2>/dev/null || true
    done < <(list_apps)
    # Make sure the keepers are actually shown (not blacklisted).
    for k in $keep; do
        show_app "$k" 2>/dev/null || true
    done
    install_home_tiles
    install_addapps_tile
    echo "Home curated: VacuumTube, Settings, Security Cameras, All Apps, Chromium, Update."
    echo "Run 'tvpc tweaks addapps' (or the Add Apps tile) to put others back."
    reload_shell
}

# Soft-refresh the running shell so home-screen changes appear without logout.
reload_shell() {
    if pgrep -x plasmashell >/dev/null 2>&1; then
        killall plasmashell 2>/dev/null
        nohup plasmashell >/dev/null 2>&1 &
        echo "(refreshed plasmashell)"
    elif pgrep -x plasma-bigscreen >/dev/null 2>&1; then
        echo "(log out and back in to refresh the Bigscreen home)"
    else
        echo "(log out and back in to see the new home screen)"
    fi
}

# Picker that un-hides chosen apps (adds them to the home screen).
cmd_addapps() {
    local ids=() names=() sel=() i out
    while IFS=$'\t' read -r id name; do
        ids+=("$id"); names+=("$name")
    done < <(list_apps)
    if command -v kdialog >/dev/null 2>&1; then
        local args=()
        for i in "${!ids[@]}"; do
            args+=("${ids[$i]}" "${names[$i]}" "off")
        done
        out="$(kdialog --checklist "Add apps to the home screen" "${args[@]}" 2>/dev/null)" || return 0
        # kdialog returns | - separated, each item single-quoted.
        IFS='|' read -ra sel <<<"$out"
    elif [[ -t 0 ]]; then
        echo "Select apps to ADD to the home (space toggles, Enter confirms):"
        PS3="Add: "
        select i in "${names[@]}" "Done"; do
            [[ $i == Done ]] && break
            for n in "${!names[@]}"; do
                [[ ${names[$n]} == "$i" ]] && sel+=("${ids[$n]}")
            done
        done
    else
        echo "Add Apps needs a GUI (kdialog) or a terminal; run it from the session." >&2
        return 1
    fi
    local added=()
    for id in "${sel[@]}"; do
        id="$(echo "$id" | tr -d "'\"")"
        [[ -n $id ]] && { show_app "$id" 2>/dev/null || true; added+=("$id"); }
    done
    echo "Added to home: ${added[*]:-none}"
    reload_shell
}

cmd_edid() {
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local out; out="$(output_id)"
        if [[ -n $out ]]; then
            echo "Connected output: $out"
        fi
    fi
    detect_edid
}

cmd_hdr() {
    local state="${1:-on}"
    command -v kscreen-doctor >/dev/null 2>&1 || {
        echo "kscreen-doctor missing"
        return 1
    }
    local out; out="$(output_id)"
    if [[ -z $out ]]; then
        echo "no output"
        return 1
    fi
    if kscreen-doctor "output.$out.hdr.$state" >/dev/null 2>&1; then
        echo "HDR -> $state"
        echo "  (requires restart to apply fully)"
    else
        echo "HDR not supported by this display/driver"
        return 1
    fi
}

cmd_density() {
    local level="$1"
    case "$level" in
        comfortable|normal|compact) ;;
        *)
            echo "usage: tvpc-tweaks density comfortable|normal|compact"
            return 1
            ;;
    esac
    case "$level" in
        comfortable)
            kde_set "General" "font" "Noto Sans,15,-1,5,50,0,0,0,0,0"
            kde_set "General" "menuFont" "Noto Sans,15,-1,5,50,0,0,0,0,0"
            kde_set "General" "fixed" "Noto Sans Mono,14,-1,5,50,0,0,0,0,0"
            kde_set "General" "toolBarFont" "Noto Sans,14,-1,5,50,0,0,0,0,0"
            kde_set "General" "smallestReadableFont" "Noto Sans,13,-1,5,50,0,0,0,0,0"
            kde_set "Icons" "Size" "48"
            ;;
        normal)
            kde_set "General" "font" "Noto Sans,13,-1,5,50,0,0,0,0,0"
            kde_set "General" "menuFont" "Noto Sans,13,-1,5,50,0,0,0,0,0"
            kde_set "General" "fixed" "Noto Sans Mono,12,-1,5,50,0,0,0,0,0"
            kde_set "General" "toolBarFont" "Noto Sans,12,-1,5,50,0,0,0,0,0"
            kde_set "General" "smallestReadableFont" "Noto Sans,11,-1,5,50,0,0,0,0,0"
            kde_set "Icons" "Size" "32"
            ;;
        compact)
            kde_set "General" "font" "Noto Sans,11,-1,5,50,0,0,0,0,0"
            kde_set "General" "menuFont" "Noto Sans,11,-1,5,50,0,0,0,0,0"
            kde_set "General" "fixed" "Noto Sans Mono,10,-1,5,50,0,0,0,0,0"
            kde_set "General" "toolBarFont" "Noto Sans,10,-1,5,50,0,0,0,0,0"
            kde_set "General" "smallestReadableFont" "Noto Sans,9,-1,5,50,0,0,0,0,0"
            kde_set "Icons" "Size" "24"
            ;;
    esac
    echo "UI density -> $level (font=$(get_kg font | cut -d, -f2), icons=$(get_kg 'Icons' 'Size'))"
}

# tvpc-display-setup inlined: apply TVPC_SCALE/TVPC_MODE from /etc/default/tvpc
cmd_setup() {
    command -v kscreen-doctor >/dev/null 2>&1 || {
        echo "kscreen-doctor missing; skipping display setup"
        return 0
    }
    for _ in $(seq 1 15); do
        kscreen-doctor -o >/dev/null 2>&1 && break
        sleep 2
    done
    local out; out="$(output_id)"
    if [[ -z $out ]]; then
        echo "no enabled output reported; skipping"
        return 0
    fi
    local mode="${TVPC_MODE:-}"
    if [[ -n $mode ]]; then
        kscreen-doctor "output.$out.mode.$mode" \
            && echo "mode -> $mode on $out" \
            || echo "could not set mode $mode (see: kscreen-doctor -o)"
    fi
    local scale="${TVPC_SCALE:-1.5}"
    if [[ $scale != "1" && $scale != "1.0" ]]; then
        kscreen-doctor "output.$out.scale.$scale" \
            && echo "scale -> $scale on $out" \
            || echo "could not set scale $scale"
    fi
}

# Audio management (inlined from tvpc-audio-manager.sh)
cmd_audio() {
    local sub="${2:-status}"
    case "$sub" in
        status)
            echo "=== Audio Status ==="
            echo "Default sink: $(pactl get-default-sink 2>/dev/null || true)"
            echo
            echo "Available sinks:"
            pactl list short sinks 2>/dev/null
            echo
            echo "Current volume: $(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk '{print $5}' | tr -d '%')%"
            echo "Mute: $(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')"
            ;;
        volume)
            local level="$3"
            if [[ -z $level ]]; then
                echo "Current volume: $(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk '{print $5}' | tr -d '%')%"
            elif [[ $level == "up" ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ +5%
                echo "Volume increased by 5%"
            elif [[ $level == "down" ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ -5%
                echo "Volume decreased by 5%"
            elif [[ $level =~ ^[0-9]+$ ]] && [[ $level -ge 0 ]] && [[ $level -le 100 ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ "${level}%"
                echo "Volume set to ${level}%"
            else
                echo "Error: Volume must be 0-100 or up/down" >&2
                return 1
            fi
            ;;
        mute)
            pactl set-sink-mute @DEFAULT_SINK@ toggle
            local m; m="$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')"
            if [[ $m == "yes" ]]; then
                echo "Audio muted"
            else
                echo "Audio unmuted"
            fi
            ;;
        profile)
            local prof="$3"
            if [[ -z $prof ]]; then
                echo "Available profiles:"
                pactl list cards 2>/dev/null | sed -n '/Profiles:/,/^ *$/p'
                return 0
            fi
            local card; card="$(pactl list short cards 2>/dev/null | head -1 | awk '{print $2}')"
            if [[ -n $card ]] && pactl set-card-profile "$card" "$prof" 2>/dev/null; then
                echo "Profile set to $prof"
            else
                echo "Failed to set profile: $prof" >&2
                return 1
            fi
            ;;
        *)
            echo "Usage: tvpc-tweaks audio status|volume|mute|profile" >&2
            return 1
            ;;
    esac
}

cmd_eq() {
    local preset="${1:-off}"
    if [[ $preset == off ]]; then
        rm -f "$EQ_CONF" 2>/dev/null || true
        echo "EQ disabled"
        return 0
    fi
    local found=0
    for p in "${EQ_PRESETS[@]}"; do
        if [[ $p == "$preset" ]]; then
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "Unknown preset: $preset"
        echo "Available: ${EQ_PRESETS[*]} off"
        return 1
    fi
    local bands="${EQ_BANDS_DEFAULT[*]}"
    local eqs
    eqs=$(IFS=:; echo "$bands")
    mkdir -p "$(dirname "$EQ_CONF")"
    cat >"$EQ_CONF" <<EOF
context.modules = [
  { factory = "filter-chain"
    args = {
      node.description = "tvpc EQ"
      media.name = "tvpc EQ"
      filter.graph = {
        nodes = [ { type = ladspa
                    plugin = mbeq_1901
                    label = mbeq
                    control = { $eqs } } ]
        inputs = [ "in_1" "in_2" ];
        outputs = [ "out_1" "out_2" ];
        links = [ { in = "in_1", out = "out_1" }
                  { in = "in_2", out = "out_2" } ]
      }
      capture.props = { node.name = "tvpc.eq.source" }
      playback.props = { node.name = "tvpc.eq.sink" node.target = "auto" }
    }
  }
]
EOF
    echo "EQ -> $preset (requires swh-plugins; restart pipewire to apply)"
}

install_cec() {
    local cec_script="/usr/local/bin/tvpc-cec-listener.sh"
    if [[ ! -f "$cec_script" ]]; then
        cat >"$cec_script" <<'CECEOF'
#!/usr/bin/env bash
# tvpc-cec-listener - CEC remote handler
set -o pipefail
[ -f /etc/tvpc/cec-map.conf ] || exit 0
while IFS= read -r line; do
    [[ $line == \#* ]] && continue
    [[ -z $line" ]] && continue
    code=$(echo "$line" | awk '{print $1}')
    action=$(echo "$line" | awk '{print $2}')
    [[ -z $code" ]] && continue
    case "$action" in
        key:*)
            keycode="${action#key:}"
            [ -n "$keycode" ] && echo "key $keycode" &
            ;;
        mpris:*)
            cmd="${action#mpris:}"
            playerctl "$cmd" 2>/dev/null &
            ;;
        pactl:*)
            args="${action#pactl:}"
            pactl "$args" 2>/dev/null &
            ;;
        app:*)
            appid="${action#app:}"
            flatpak run "$appid" 2>/dev/null &
            ;;
        macro:*)
            macroname="${action#macro:}"
            [[ -f /etc/tvpc/cec-macros.conf ]] && \
                grep "^$macroname " /etc/tvpc/cec-macros.conf | \
                awk '{for(i=2;i<=NF;i++) print $i}' | \
                while read -r m; do
                    case "$m" in
                        key:*) echo "key ${m#key:}" & ;;
                        mpris:*) playerctl "${m#mpris:}" 2>/dev/null & ;;
                        pactl:*) pactl "${m#pactl:}" 2>/dev/null & ;;
                        cmd:*) eval "${m#cmd:}" & ;;
                    esac
                done
            ;;
        mouse)
            echo "toggle-mouse" &
            ;;
        cmd:*)
            eval "${action#cmd:}" &
            ;;
    esac
done < /etc/tvpc/cec-map.conf
CECEOF
        chmod +x "$cec_script"
    fi
}

cec_apps() {
    local id name
    while IFS=$'\t' read -r id name; do
        [[ -n $id ]] && printf '%s\t%s\n' "$id" "$name"
    done < <(list_apps)
}

cec_action_for() {
    local code="$1" line
    [[ -f $CEC_MAP ]] || { echo "none"; return 0; }
    line="$(grep -E "^${code} " "$CEC_MAP" 2>/dev/null | head -1 || true)"
    if [[ -n $line ]]; then
        printf '%s\n' "${line#* }"
    else
        echo "none"
    fi
}

cec_list() {
    local i
    for ((i=0; i<${#CEC_CODES[@]}; i++)); do
        printf '%s\t%s\t%s\n' "${CEC_CODES[$i]}" "${CEC_NAMES[$i]}" "$(cec_action_for "${CEC_CODES[$i]}")"
    done
}

cec_get() {
    local code="${1:-}"
    case "$code" in
        [0-9a-fA-F][0-9a-fA-F]) ;;
        *) echo "usage: tvpc-tweaks cec-get CODE" >&2; return 1 ;;
    esac
    cec_action_for "$code"
}

cec_set() {
    local code="${1:-}" action="${2:-}" value
    need_root "cec-set" || return 1
    case "$code" in
        [0-9a-fA-F][0-9a-fA-F]) ;;
        *) echo "CEC key code must be two hexadecimal digits" >&2; return 1 ;;
    esac
    case "$action" in
        none) ;;
        key:*)
            value="${action#key:}"
            [[ $value =~ ^[0-9]+$ ]] || { echo "key actions need a numeric Linux keycode" >&2; return 1; }
            ;;
        mpris:play-pause|mpris:stop|mpris:next|mpris:previous) ;;
        pactl:+2%|pactl:-2%|pactl:toggle) ;;
        app:*)
            value="${action#app:}"
            [[ -n $value && $value != *[[:space:]]* && $value != *$'\n'* && $value != *$'\r'* ]] || {
                echo "app actions need one desktop application id" >&2
                return 1
            }
            ;;
        cmd:*)
            value="${action#cmd:}"
            [[ -n $value && $value != *$'\n'* && $value != *$'\r'* ]] || {
                echo "command actions need a non-empty single-line command" >&2
                return 1
            }
            ;;
        *) echo "unsupported CEC action: $action" >&2; return 1 ;;
    esac
    write_cec_map "$code" "$action"
    systemctl restart tvpc-cec-remote 2>/dev/null || true
    echo "CEC key 0x$code -> $action"
}

tui_cec() {
    need_root "cec" || return 1
    install_cec
    mkdir -p "$(dirname "$CEC_MAP")"
    if [[ ! -f $CEC_MAP ]]; then
        cat >"$CEC_MAP" <<'EOF'
00 key:28
01 key:103
02 key:108
03 key:105
04 key:106
09 key:125
0d key:1
41 pactl:+2%
42 pactl:-2%
43 pactl:toggle
44 mpris:play-pause
45 mpris:next
46 mpris:stop
47 mpris:previous
EOF
    fi
    while true; do
        menu_reset
        local i act
        for ((i=0; i<${#CEC_CODES[@]}; i++)); do
            act="$(cec_action_for "${CEC_CODES[$i]}")"
            menu_add "${CEC_CODES[$i]}" "${CEC_NAMES[$i]} -> $act"
        done
        menu_add back "Back"
        select_list "CEC remote keys"
        if [[ $RESULT == back || -z $RESULT ]]; then
            break
        fi
        cec_edit_key "$RESULT"
        systemctl restart tvpc-cec-remote 2>/dev/null || true
        echo "CEC map updated; listener restarted."
    done
}

cec_edit_key() {
    local code="$1"
    menu_reset
    menu_add key "Key press (linux keycode)"
    menu_add mpris "Media (playerctl)"
    menu_add pactl "Volume"
    menu_add app "Launch app"
    menu_add cmd "Shell command"
    menu_add none "Disabled"
    menu_add cancel "Cancel"
    select_list "Action for key 0x$code"
    case "$RESULT" in
        cancel|"") return ;;
        key)
            clear
            printf 'Linux keycode (e.g. 28=Enter 125=Super 103=Up): '
            read -r v
            if [[ -n "$v" ]]; then
                write_cec_map "$code" "key:$v"
            fi
            ;;
        mpris)
            menu_reset
            for m in play-pause stop next previous; do
                menu_add "$m" "$m"
            done
            menu_add cancel "Cancel"
            select_list "Media action"
            if [[ -n "$RESULT" && $RESULT != cancel ]]; then
                write_cec_map "$code" "mpris:$RESULT"
            fi
            ;;
        pactl)
            menu_reset
            for v in "+2%" "-2%" "toggle"; do
                menu_add "$v" "$v"
            done
            menu_add cancel "Cancel"
            select_list "Volume"
            if [[ -n "$RESULT" && $RESULT != cancel ]]; then
                write_cec_map "$code" "pactl:$RESULT"
            fi
            ;;
        app)
            menu_reset
            while IFS=$'\t' read -r id name; do
                menu_add "$id" "$name"
            done < <(list_apps)
            menu_add cancel "Cancel"
            select_list "App to launch"
            if [[ -n "$RESULT" && $RESULT != cancel ]]; then
                write_cec_map "$code" "app:$RESULT"
            fi
            ;;
        cmd)
            clear
            printf 'Shell command: '
            read -r v
            if [[ -n "$v" ]]; then
                write_cec_map "$code" "cmd:$v"
            fi
            ;;
        none)
            write_cec_map "$code" "none"
            ;;
    esac
}

write_cec_map() {
    local code="$1" act="$2"
    mkdir -p "$(dirname "$CEC_MAP")"
    if [[ ! -f $CEC_MAP ]]; then
        touch "$CEC_MAP"
    fi
    local tmp; tmp="$(mktemp)"
    local found=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$code "* ]]; then
            echo "$code $act"
            found=1
        else
            echo "$line"
        fi
    done <"$CEC_MAP" >"$tmp"
    if [[ $found -eq 0 ]]; then
        echo "$code $act" >>"$tmp"
    fi
    mv "$tmp" "$CEC_MAP"
}

add_network_tiles() {
    local tile_dir; tile_dir="$(target_home)/.local/share/applications"
    mkdir -p "$tile_dir"
    cat >"$tile_dir/tvpc-wifi.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Wi-Fi
Comment=Network settings
Exec=kcmshell5 kcm_networkmanagement
Terminal=false
Icon=network-wireless
Categories=Settings;Network;
EOF
    cat >"$tile_dir/tvpc-bluetooth.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Bluetooth
Comment=Bluetooth settings
Exec=kcmshell5 bluetooth
Terminal=false
Icon=bluetooth
Categories=Settings;Network;
EOF
    if is_root; then
        chown -R "$TVPC_USER:$TVPC_USER" "$tile_dir" 2>/dev/null || true
    fi
    echo "Added Wi-Fi and Bluetooth tiles (visible in All Apps/home when not curated)."
}

item_val=()
item_label=()
result=""
readkey=""

menu_reset() {
    item_val=()
    item_label=()
}

menu_add() {
    item_val+=("$1")
    item_label+=("$2")
}

read_key() {
    local k k2 k3
    IFS= read -rsn1 -t 1 k || { readkey="cancel"; return; }
    if [[ $k == $'\e' ]]; then
        IFS= read -rsn1 -t 0.01 k2
        IFS= read -rsn1 -t 0.01 k3
        k="$k$k2$k3"
    fi
    readkey="$k"
}

pause_msg() {
    printf '\n\033[1;33m%s\033[0m\n' "$1"
    printf '\033[2m(press any key)\033[0m'
    read_key
}

select_list() {
    local title="$1"
    local n=${#item_val[@]}
    local sel=0
    local top=0
    local avail
    local h
    h=$(tput lines 2>/dev/null || echo 24)
    avail=$((h - 5))
    [[ $avail -lt 3 ]] && avail=3
    while true; do
        clear
        printf '\033[1;36m%s\033[0m\n' "$title"
        printf '\033[2m(up/down: move  ·  Enter: select  ·  q/Esc: back)\033[0m\n\n'
        local i
        for ((i=top; i<n && i<top+avail; i++)); do
            if [[ $i -eq $sel ]]; then
                printf '  \033[1;32m> %s\033[0m\n' "${item_label[$i]}"
            else
                printf '    %s\n' "${item_label[$i]}"
            fi
        done
        for ((i=n<top+avail?n:top+avail; i<top+avail; i++)); do
            echo
        done
        read_key
        case "$readkey" in
            $'\e[A')
                [[ $sel -gt 0 ]] && sel=$((sel - 1))
                [[ $sel -lt $top ]] && top=$sel
                ;;
            $'\e[B')
                [[ $sel -lt $((n - 1)) ]] && sel=$((sel + 1))
                [[ $sel -ge $((top + avail)) ]] && top=$((sel - $avail + 1))
                ;;
            "")
                result="${item_val[$sel]}"
                return 0
                ;;
            q|Q|$'\e')
                result=""
                return 1
                ;;
            [0-9])
                local d=$((10#$readkey))
                if [[ $d -lt $n ]]; then
                    sel=$d
                    result="${item_val[$sel]}"
                    return 0
                fi
                ;;
        esac
    done
}

tui_scale() {
    local cur="${TVPC_SCALE:-1.5}"
    menu_reset
    local f
    for f in 0.75 1 1.25 1.5 1.75 2; do
        local tag=""
        if [[ $f == "$cur" ]]; then
            tag="  (current)"
        fi
        menu_add "$f" "$f ×$tag"
    done
    menu_add custom "Set a custom scale…"
    menu_add font "Base font size (Bigscreen whole-UI scale)…"
    menu_add back "Back"
    select_list "UI scaling"
    case "$result" in
        custom)
            clear
            printf 'Enter scale factor (e.g. 1.25): '
            read -r v
            if [[ -n "$v" ]]; then
                do_scale "$v"
            fi
            ;;
        font)
            clear
            printf 'Enter base font size in points (Bigscreen: try 10): '
            read -r v
            if [[ $v =~ ^[0-9]+$ ]]; then
                do_font "$v"
            fi
            ;;
        back|"")
            return
            ;;
        *)
            do_scale "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_apps() {
    local -a AID ANAME AHID
    local id name
    while IFS=$'\t' read -r id name; do
        AID+=("$id")
        ANAME+=("$name")
        if app_is_hidden "$id"; then
            AHID+=(1)
        else
            AHID+=(0)
        fi
    done < <(list_apps)
    local n=${#AID[@]}
    local sel=0
    local top=0
    local avail
    local h
    h=$(tput lines 2>/dev/null || echo 24)
    avail=$((h - 5))
    [[ $avail -lt 3 ]] && avail=3
    while true; do
        clear
        printf '\033[1;36mHome-screen apps\033[0m\n'
        printf '\033[2m(Enter: toggle shown/hidden  ·  q/Esc: back)\033[0m\n\n'
        local i
        for ((i=top; i<n && i<top+avail; i++)); do
            local mark
            if [[ ${AHID[$i]} -eq 1 ]]; then
                mark="\033[1;31m[hidden]\033[0m"
            else
                mark="\033[1;32m[shown ]\033[0m"
            fi
            if [[ $i -eq $sel ]]; then
                printf '  \033[1;32m>\033[0m %-40s %b\n' "${ANAME[$i]}" "$mark"
            else
                printf '    %-40s %b\n' "${ANAME[$i]}" "$mark"
            fi
        done
        for ((i=n<top+avail?n:top+avail; i<top+avail; i++)); do
            echo
        done
        read_key
        case "$readkey" in
            $'\e[A')
                [[ $sel -gt 0 ]] && sel=$((sel - 1))
                [[ $sel -lt $top ]] && top=$sel
                ;;
            $'\e[B')
                [[ $sel -lt $((n - 1)) ]] && sel=$((sel + 1))
                [[ $sel -ge $((top + avail)) ]] && top=$((sel - $avail + 1))
                ;;
            "")
                if [[ ${AHID[$sel]} -eq 1 ]]; then
                    show_app "${AID[$sel]}"
                    AHID[$sel]=0
                else
                    hide_app "${AID[$sel]}"
                    AHID[$sel]=1
                fi
                ;;
            q|Q|$'\e')
                return
                ;;
        esac
    done
}

tui_theme() {
    menu_reset
    menu_add dark "Dark (Breeze Dark)"
    menu_add light "Light (Breeze)"
    menu_add midnight "Bigscreen: Midnight Glass (Default)"
    menu_add oled "Bigscreen: OLED Stealth"
    menu_add cyberpunk "Bigscreen: Cyberpunk Neon"
    menu_add sunset "Bigscreen: Sunset Amber"
    menu_add emerald "Bigscreen: Emerald Pine"
    menu_add back "Back"
    select_list "Theme"
    case "$result" in
        dark|light|midnight|oled|cyberpunk|sunset|emerald)
            do_theme "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_mode() {
    menu_reset
    menu_add auto "Auto (use the TV's EDID)"
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local m
        while IFS= read -r m; do
            if [[ -n "$m" ]]; then
                menu_add "$m" "$m"
            fi
        done < <(kscreen-doctor -o 2>/dev/null | grep -oE 'Mode [0-9]+: [0-9]+x[0-9]+@[0-9.]+' | sed -E 's/Mode [0-9]+: //')
    fi
    menu_add back "Back"
    select_list "Display mode"
    case "$result" in
        back|"") return ;;
        *)
            do_mode "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_idle() {
    menu_reset
    menu_add on "Stay awake (TV never sleeps)"
    menu_add off "Allow sleep after ~5 min idle"
    menu_add back "Back"
    select_list "TV sleep"
    case "$result" in
        on|off)
            do_idle "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_density() {
    menu_reset
    menu_add comfortable "Comfortable (larger text & icons)"
    menu_add normal "Normal (default)"
    menu_add compact "Compact (smaller)"
    menu_add back "Back"
    select_list "UI density"
    case "$result" in
        comfortable|normal|compact)
            cmd_density "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_autostart() {
    while true; do
        menu_reset
        local id name
        while IFS=$'\t' read -r id name; do
            menu_add "rm:$id" "Remove: $name"
        done < <(list_autostart)
        menu_add add "＋ Add an app…"
        menu_add back "Back"
        select_list "Autostart apps"
        case "$result" in
            back|"")
                return
                ;;
            add)
                menu_reset
                while IFS=$'\t' read -r id name; do
                    menu_add "$id" "$name"
                done < <(list_apps)
                menu_add cancel "Cancel"
                select_list "Add which app to autostart?"
                if [[ -n "$result" && $result != cancel ]]; then
                    autostart_add "$result"
                fi
                ;;
            rm:*)
                autostart_remove "${result#rm:}"
                ;;
        esac
    done
    pause_msg "Done."
}

tui_session() {
    menu_reset
    local s
    for s in auto plasma plasma-mobile plasma-x11 kiosk bigscreen bigscreen-x11 hypr phosh; do
        menu_add "$s" "$s"
    done
    menu_add back "Back"
    select_list "Switch session (needs root)"
    case "$result" in
        back|"") return ;;
        *)
            if need_root "session $result"; then
                switch_session "$result"
                pause_msg "Switched. Restart the display manager to pick it up: sudo systemctl restart sddm"
            fi
            ;;
    esac
}

tui_status() {
    cmd_status
    pause_msg ""
}

tui_main() {
    while true; do
        menu_reset
        menu_add scale "UI scaling"
        menu_add apps "Home-screen apps"
        menu_add theme "Theme"
        menu_add mode "Display mode"
        menu_add idle "TV sleep"
        menu_add autostart "Autostart apps"
        menu_add session "Session"
        menu_add status "Show status"
        menu_add edid "EDID / display detection"
        menu_add hdr "HDR toggle"
        menu_add density "UI density"
        menu_add audio "Audio (HDMI / volume)"
        menu_add cec "CEC key mappings"
        menu_add quit "Exit"
        select_list "tvpc Tweaks"
        case "$result" in
            scale)     tui_scale ;;
            apps)      tui_apps ;;
            theme)     tui_theme ;;
            mode)      tui_mode ;;
            idle)      tui_idle ;;
            autostart) tui_autostart ;;
            session)   tui_session ;;
            status)    tui_status ;;
            edid)
                clear
                cmd_edid
                pause_msg ""
                ;;
            hdr)
                clear
                cmd_hdr on
                pause_msg ""
                ;;
            density)   tui_density ;;
            audio)
                clear
                cmd_audio status
                pause_msg ""
                ;;
            cec)       tui_cec ;;
            quit|"")   return ;;
        esac
    done
}

load_plugins() {
    local d f
    for d in /usr/local/share/tvpc-tweaks/plugins.d "$HOME/.config/tvpc-tweaks/plugins.d"; do
        [[ -d $d ]] || continue
        for f in "$d"/*.sh; do
            [[ -f $f ]] && . "$f"
        done
    done
}

plugin_manager() {
    while true; do
        menu_reset
        local i
        for ((i=0; i<${#TVPC_PLUGIN_IDS[@]}; i++)); do
            menu_add "plugin:${TVPC_PLUGIN_IDS[$i]}" "${TVPC_PLUGIN_LABELS[$i]}"
        done
        menu_add back "Back"
        select_list "Plugins"
        case "$result" in
            back|"")
                return
                ;;
            plugin:*)
                local id="${result#plugin:}"
                tvpc_plugin_"$id"
                pause_msg "Plugin completed."
                ;;
        esac
    done
}

cmd_wifi() {
    if [[ -t 0 ]]; then
        kcmshell5 kcm_networkmanagement 2>/dev/null || echo "kcm_networkmanagement not available"
    else
        echo "Run from a TTY or GUI" >&2
    fi
}

cmd_bluetooth() {
    if [[ -t 0 ]]; then
        kcmshell5 bluetooth 2>/dev/null || echo "bluetooth module not available"
    else
        echo "Run from a TTY or GUI" >&2
    fi
}

case "${1:-}" in
    scale)
        shift
        do_scale "${1:-}"
        ;;
    font)
        shift
        do_font "${1:-}"
        ;;
    apps)
        while IFS=$'\t' read -r id name; do
            if app_is_hidden "$id"; then
                st="hidden"
            else
                st="shown"
            fi
            printf '%-45s %-30s %s\n' "$id" "${name:0:29}" "$st"
        done < <(list_apps)
        ;;
    hide)
        shift
        need_root "hide $*" || exit 1
        IFS=',' read -ra ids <<<"$*"
        for id in "${ids[@]}"; do
            hide_app "$id"
        done
        echo "Hidden: ${ids[*]}  (log out and back in)"
        ;;
    show)
        shift
        need_root "show $*" || exit 1
        IFS=',' read -ra ids <<<"$*"
        for id in "${ids[@]}"; do
            show_app "$id"
        done
        echo "Shown again: ${ids[*]}  (log out and back in)"
        ;;
    theme)
        shift
        do_theme "${1:-}"
        ;;
    mode)
        shift
        do_mode "${1:-auto}"
        ;;
    idle)
        shift
        do_idle "${1:-on}"
        ;;
    density)
        shift
        cmd_density "${1:-normal}"
        ;;
    hdr)
        shift
        cmd_hdr "${1:-on}"
        ;;
    eq)
        shift
        cmd_eq "${1:-off}"
        ;;
    edid)
        cmd_edid
        ;;
    autostart)
        tui_autostart
        ;;
    session)
        shift
        need_root "session $*" || exit 1
        switch_session "${1:-auto}"
        ;;
    status)
        cmd_status
        ;;
    cec|cec-map)
        need_root "cec" || exit 1
        tui_cec
        ;;
    cec-list)
        cec_list
        ;;
    cec-apps)
        cec_apps
        ;;
    cec-get)
        shift
        cec_get "${1:-}"
        ;;
    cec-set)
        shift
        cec_set "$@"
        ;;
    install-launcher)
        install_launcher
        ;;
    vacuum-only)
        vacuum_only
        ;;
    home)
        home_preset
        ;;
    addapps)
        cmd_addapps
        ;;
    network-tiles)
        add_network_tiles
        ;;
    setup)
        cmd_setup
        ;;
    audio)
        cmd_audio "$@"
        ;;
    --help|-h|help)
        usage
        exit 0
        ;;
    "")
        if [[ -t 1 ]]; then
            load_plugins
            tui_main
        else
            usage
        fi
        ;;
    *)
        echo "Unknown command '$1' (try: tvpc-tweaks --help)" >&2
        exit 1
        ;;
esac
}

# ---------------------------------------------------------------------------
# Module: GUI Dialogs & Launchers
# ---------------------------------------------------------------------------
gui_setup() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

# shellcheck source=/dev/null
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have kdialog && have zenity; then
  kdialog() {
    local text="" title="tvpc" file=""
    case "${1:-}" in
      --msgbox|--sorry)
        text="${2:-}"; title="${4:-tvpc setup}"
        zenity --info --text="$text" --title="$title" 2>/dev/null || true
        ;;
      --error)
        text="${2:-}"; title="${4:-tvpc setup}"
        zenity --error --text="$text" --title="$title" 2>/dev/null || true
        ;;
      --warningyesno|--warningcontinuecancel)
        text="${2:-}"; title="${4:-tvpc setup}"
        if zenity --question --text="$text" --title="$title" 2>/dev/null; then
          printf 'yes\n'
          return 0
        else
          return 1
        fi
        ;;
      --textbox)
        file="${2:-}"; title="${6:-tvpc setup}"
        zenity --text-info --filename="$file" --title="$title" --width=850 --height=600 2>/dev/null || true
        ;;
      --menu)
        title="${2:-tvpc menu}"; shift 2
        local pairs=()
        while [[ $# -ge 2 ]]; do
          pairs+=("$1" "$2")
          shift 2
        done
        zenity --list --column="Tag" --column="Item" "${pairs[@]}" --title="$title" --hide-column=1 --print-column=1 2>/dev/null
        ;;
      *)
        zenity "$@"
        ;;
    esac
  }
fi

require_gui() {
  if ! have kdialog && ! have zenity; then
    printf 'tvpc-setup-gui needs kdialog or zenity.\n' >&2
    return 1
  fi
}

show_text() {
  local title="$1" text="$2" tmp rc
  tmp="$(mktemp)"
  printf '%s\n' "$text" >"$tmp"
  kdialog --textbox "$tmp" 900 700 --title "$title" 2>/dev/null
  rc=$?
  rm -f "$tmp"
  if [[ $rc -ne 0 ]]; then
    kdialog --msgbox "$text" --title "$title"
  fi
}

TVPC_CONTROLLER="$(command -v tvpc-controller 2>/dev/null || true)"
TVPC_CEC_SETUP="$(command -v tvpc-cec-setup 2>/dev/null || true)"
TVPC_TWEAKS="$(command -v tvpc-tweaks 2>/dev/null || true)"

run_privileged() {
  if have pkexec; then
    pkexec "$@"
  elif have sudo; then
    sudo -- "$@"
  else
    kdialog --sorry "A privileged helper is required, but neither pkexec nor sudo is available." \
      --title "tvpc setup"
    return 1
  fi
}

show_privileged_output() {
  local title="$1" output
  shift
  if output="$(run_privileged "$@" 2>&1)"; then
    show_text "$title" "$output"
  else
    show_text "$title failed" "$output"
  fi
}

# --- Gamepad / input ---------------------------------------------------------
menu_gamepad() {
  while true; do
    local choice
    choice=$(kdialog --menu "Input devices — gamepad, phone, or remote" \
      "status"     "Show what is paired / connected right now" \
      "pair-bt"    "Pair a Bluetooth gamepad (Xbox, PS, 8BitDo, …)" \
      "pair-kde"   "Pair your phone as a remote over Wi-Fi (KDE Connect)" \
      "back"       "Back to the main menu" 2>/dev/null) || return 0
    case "$choice" in
      status)  show_privileged_output "Input device status" "$TVPC_CONTROLLER" status ;;
      pair-bt) show_privileged_output "Pair Bluetooth gamepad" "$TVPC_CONTROLLER" pair-gamepad ;;
      pair-kde) show_privileged_output "Pair KDE Connect phone" "$TVPC_CONTROLLER" pair-kdeconnect ;;
      back|"") return ;;
    esac
  done
}

cec_action_menu() {
  local code="$1" current="$2" choice value
  local -a args
  while true; do
    choice=$(kdialog --menu "Action for CEC key 0x$code (current: $current)" \
      "key"   "Linux keycode" \
      "mpris" "Media control (play/pause, stop, next, previous)" \
      "pactl" "Volume control" \
      "app"   "Launch an application" \
      "cmd"   "Run a shell command" \
      "none"  "Disable this button" \
      "cancel" "Cancel" 2>/dev/null) || return 1
    case "$choice" in
      key)
        value="$(kdialog --inputbox "Linux keycode for CEC key 0x$code" 500 200 "${current#key:}" 2>/dev/null)" || continue
        if [[ ! $value =~ ^[0-9]+$ ]]; then
          kdialog --sorry "Enter a numeric Linux keycode, for example 28 for Enter." --title "CEC key mapping"
          continue
        fi
        printf 'key:%s\n' "$value"
        return 0
        ;;
      mpris)
        choice=$(kdialog --menu "Media action for CEC key 0x$code" \
          "play-pause" "Play / pause" \
          "stop" "Stop" \
          "next" "Next" \
          "previous" "Previous" \
          "cancel" "Cancel" 2>/dev/null) || continue
        [[ $choice == cancel ]] && continue
        printf 'mpris:%s\n' "$choice"
        return 0
        ;;
      pactl)
        choice=$(kdialog --menu "Volume action for CEC key 0x$code" \
          "+2%" "Volume up" \
          "-2%" "Volume down" \
          "toggle" "Mute toggle" \
          "cancel" "Cancel" 2>/dev/null) || continue
        [[ $choice == cancel ]] && continue
        printf 'pactl:%s\n' "$choice"
        return 0
        ;;
      app)
        args=()
        while IFS=$'\t' read -r value name _; do
          [[ -n $value ]] && args+=("$value" "$name")
        done < <("$TVPC_TWEAKS" cec-apps 2>/dev/null)
        if [[ ${#args[@]} -eq 0 ]]; then
          kdialog --sorry "No applications are available to map." --title "CEC key mapping"
          continue
        fi
        choice=$(kdialog --menu "Application for CEC key 0x$code" "${args[@]}" 2>/dev/null) || continue
        printf 'app:%s\n' "$choice"
        return 0
        ;;
      cmd)
        value="$(kdialog --inputbox "Shell command for CEC key 0x$code" 700 240 "${current#cmd:}" 2>/dev/null)" || continue
        if [[ -z $value || $value == *$'\n'* || $value == *$'\r'* ]]; then
          kdialog --sorry "Enter one non-empty command line." --title "CEC key mapping"
          continue
        fi
        printf 'cmd:%s\n' "$value"
        return 0
        ;;
      none) printf 'none\n'; return 0 ;;
      cancel|"") return 1 ;;
      *) continue ;;
    esac
  done
}

cec_editor() {
  local -a rows args
  local row code name current action
  while true; do
    rows=()
    mapfile -t rows < <("$TVPC_TWEAKS" cec-list 2>/dev/null)
    if [[ ${#rows[@]} -eq 0 ]]; then
      show_text "CEC key mapping" "The CEC mapping helper did not return any buttons."
      return 0
    fi
    args=()
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r code name current <<<"$row"
      [[ -n $code ]] && args+=("$code" "$name — $current")
    done
    code="$(kdialog --menu "CEC remote buttons — choose one to edit" "${args[@]}" 2>/dev/null)" || return 0
    current="$("$TVPC_TWEAKS" cec-get "$code" 2>/dev/null || printf 'none')"
    action="$(cec_action_menu "$code" "$current")" || continue
    show_privileged_output "CEC key mapping" "$TVPC_TWEAKS" cec-set "$code" "$action"
    kdialog --msgbox "CEC mapping updated for key 0x$code." --title "CEC key mapping"
  done
}

# --- HDMI-CEC / Anynet+ -------------------------------------------------------
menu_cec() {
  while true; do
    local choice
    choice=$(kdialog --menu "HDMI-CEC / Anynet+ (Samsung remote)" \
      "check"   "Check for a CEC adapter and report service state" \
      "install" "Install + enable the CEC remote listener" \
      "keys"    "Edit remote-button mappings" \
      "back"    "Back to the main menu" 2>/dev/null) || return 0
    case "$choice" in
      check)   show_privileged_output "CEC / Anynet+ check" "$TVPC_CEC_SETUP" --check ;;
      install) show_privileged_output "CEC / Anynet+ setup" "$TVPC_CEC_SETUP" ;;
      keys)    cec_editor ;;
      back|"") return ;;
    esac
  done
}

# --- TV power-on --------------------------------------------------------------
menu_power() {
  while true; do
    local choice
    choice=$(kdialog --menu "TV power-on at boot" \
      "status" "Is the CEC power-on service enabled?" \
      "enable" "Enable: power on the TV + switch HDMI input at boot" \
      "disable" "Disable the power-on service" \
      "back"   "Back to the main menu" 2>/dev/null) || return 0
    case "$choice" in
      status)
        if systemctl is-enabled htpc-startup.service >/dev/null 2>&1; then
          kdialog --msgbox "htpc-startup is enabled — the TV will power on and switch to the NUC's HDMI input at boot."
        else
          kdialog --msgbox "htpc-startup is NOT enabled — the TV will not power on automatically."
        fi ;;
      enable)
        if run_privileged systemctl enable htpc-startup.service; then
          kdialog --msgbox "Enabled. The TV will power on at boot."
        fi ;;
      disable)
        if run_privileged systemctl disable htpc-startup.service; then
          kdialog --msgbox "Disabled."
        fi ;;
      back|"") return ;;
    esac
  done
}

# --- Main menu ----------------------------------------------------------------
main_menu() {
  while true; do
    local choice
    choice=$(kdialog --menu "tvpc setup — pick what you want to configure" \
      "gamepad" "Gamepad / phone remote" \
      "cec"     "HDMI-CEC / Anynet+ (Samsung remote)" \
      "power"   "TV power-on at boot" \
      "quit"    "Exit" 2>/dev/null) || return 0
    case "$choice" in
      gamepad) menu_gamepad ;;
      cec)     menu_cec ;;
      power)   menu_power ;;
      quit|"") return ;;
    esac
  done
}

check_report() {
  local output=""
  if [[ -n $TVPC_CONTROLLER ]]; then
    output+="Input devices\n$(run_privileged "$TVPC_CONTROLLER" status 2>&1)\n\n"
  else
    output+="Input devices\n  tvpc-controller is not installed.\n\n"
  fi
  if [[ -n $TVPC_CEC_SETUP ]]; then
    output+="HDMI-CEC / Anynet+\n$(run_privileged "$TVPC_CEC_SETUP" --check 2>&1)\n"
  else
    output+="HDMI-CEC / Anynet+\n  tvpc-cec-setup is not installed.\n"
  fi
  show_text "tvpc setup — current state" "$output"
}

# ---------------------------------------------------------------------------
require_gui || exit 1
if [[ -z $TVPC_CONTROLLER || -z $TVPC_CEC_SETUP || -z $TVPC_TWEAKS ]]; then
  kdialog --sorry "One or more tvpc helper programs are missing. Run the tvpc installer or update first." \
    --title "tvpc setup"
  exit 1
fi

case "${1:-gui}" in
  --check|check) check_report ;;
  gui|"")        main_menu ;;
  *)
    kdialog --sorry "Unknown argument: $1" --title "tvpc setup"
    exit 1
    ;;
esac

}

gui_update() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have kdialog && have zenity; then
  kdialog() {
    local text="" title="tvpc" file=""
    case "${1:-}" in
      --msgbox|--sorry)
        text="${2:-}"; title="${4:-tvpc update}"
        zenity --info --text="$text" --title="$title" 2>/dev/null || true
        ;;
      --error)
        text="${2:-}"; title="${4:-tvpc update}"
        zenity --error --text="$text" --title="$title" 2>/dev/null || true
        ;;
      --warningyesno|--warningcontinuecancel)
        text="${2:-}"; title="${4:-tvpc update}"
        if zenity --question --text="$text" --title="$title" 2>/dev/null; then
          printf 'yes\n'
          return 0
        else
          return 1
        fi
        ;;
      --textbox)
        file="${2:-}"; title="${6:-tvpc update}"
        zenity --text-info --filename="$file" --title="$title" --width=850 --height=600 2>/dev/null || true
        ;;
      --menu)
        title="${2:-tvpc menu}"; shift 2
        local pairs=()
        while [[ $# -ge 2 ]]; do
          pairs+=("$1" "$2")
          shift 2
        done
        zenity --list --column="Tag" --column="Item" "${pairs[@]}" --title="$title" --hide-column=1 --print-column=1 2>/dev/null
        ;;
      *)
        zenity "$@"
        ;;
    esac
  }
fi

require_gui() {
  if ! have kdialog && ! have zenity; then
    printf 'tvpc-update-gui needs kdialog or zenity.\n' >&2
    return 1
  fi
}

show_text() {
  local title="$1" text="$2" tmp rc
  tmp="$(mktemp)"
  printf '%s\n' "$text" >"$tmp"
  kdialog --textbox "$tmp" 900 700 --title "$title" 2>/dev/null
  rc=$?
  rm -f "$tmp"
  if [[ $rc -ne 0 ]]; then
    kdialog --msgbox "$text" --title "$title"
  fi
}

run_privileged() {
  if have pkexec; then
    pkexec "$@"
  elif have sudo; then
    sudo -- "$@"
  else
    kdialog --sorry "A privileged helper is required, but neither pkexec nor sudo is available." \
      --title "tvpc update"
    return 1
  fi
}

# Resolve an installed copy without trusting its /usr/local/bin parent. The
# installer records the source checkout in /etc/tvpc/repo.path; an explicit
# TVPC_REPO_ROOT is useful for tests and controlled deployments.
resolve_repo_root() {
  local candidate source_path marker

  REPO_ROOT=""
  REPO_STATE="unavailable"
  REPO_DETAIL="no tvpc repository was found"

  if [[ -n ${TVPC_REPO_ROOT:-} ]]; then
    candidate="$TVPC_REPO_ROOT"
  elif [[ -r /etc/tvpc/repo.path ]]; then
    IFS= read -r candidate < /etc/tvpc/repo.path
  else
    source_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    candidate="$(cd "$(dirname "$source_path")/../.." 2>/dev/null && pwd || true)"
  fi

  for p in "$candidate" "$HOME/tvpc" "/home/$HTPC_USER/tvpc" "/tvpc"; do
    if [[ -n $p && -f "$p/install.sh" && -d "$p/scripts" ]]; then
      candidate="$p"
      break
    fi
  done

  if [[ -n $candidate && -f "$candidate/install.sh" && -d "$candidate/scripts" ]]; then
    if git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      REPO_ROOT="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$candidate")"
      REPO_STATE="found"
      REPO_DETAIL="repository: $REPO_ROOT"
      return 0
    fi
    REPO_DETAIL="invalid repository: $candidate"
  elif [[ -n $candidate ]]; then
    REPO_DETAIL="invalid repository path: $candidate"
  fi
  return 1
}

git_plan() {
  local status branch upstream output
  GIT_STATE="unavailable"
  GIT_AHEAD=0
  GIT_BEHIND=0
  GIT_UPSTREAM=""
  GIT_DETAIL="repository checks are unavailable"

  if [[ $REPO_STATE != found ]]; then
    GIT_DETAIL="$REPO_DETAIL"
    return 0
  fi

  if ! status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all 2>&1)"; then
    GIT_STATE="error"
    GIT_DETAIL="could not read the git worktree"
    return 0
  fi
  if [[ -n $status ]]; then
    GIT_STATE="blocked-dirty"
    GIT_DETAIL="dirty worktree; save or revert local changes before updating"
    return 0
  fi

  branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -z $branch || $branch == HEAD ]]; then
    GIT_STATE="no-upstream"
    GIT_DETAIL="detached HEAD; no safe upstream branch is configured"
    return 0
  fi

  if ! upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
    GIT_STATE="no-upstream"
    GIT_DETAIL="branch '$branch' has no upstream"
    return 0
  fi
  GIT_UPSTREAM="$upstream"

  if ! output="$(git -C "$REPO_ROOT" fetch --quiet 2>&1)"; then
    GIT_STATE="error"
    GIT_DETAIL="git fetch failed${output:+: $output}"
    return 0
  fi

  if ! GIT_BEHIND="$(git -C "$REPO_ROOT" rev-list --count "HEAD..$upstream" 2>/dev/null)"; then
    GIT_STATE="error"
    GIT_DETAIL="could not compare with upstream $upstream"
    return 0
  fi
  if ! GIT_AHEAD="$(git -C "$REPO_ROOT" rev-list --count "$upstream..HEAD" 2>/dev/null)"; then
    GIT_STATE="error"
    GIT_DETAIL="could not compare with upstream $upstream"
    return 0
  fi

  if [[ $GIT_AHEAD -gt 0 && $GIT_BEHIND -gt 0 ]]; then
    GIT_STATE="diverged"
    GIT_DETAIL="$GIT_AHEAD local and $GIT_BEHIND remote commit(s)"
  elif [[ $GIT_AHEAD -gt 0 ]]; then
    GIT_STATE="local-ahead"
    GIT_DETAIL="$GIT_AHEAD local commit(s) are not on $upstream"
  elif [[ $GIT_BEHIND -gt 0 ]]; then
    GIT_STATE="behind"
    GIT_DETAIL="$GIT_BEHIND new commit(s) on $upstream"
  else
    GIT_STATE="up-to-date"
    GIT_DETAIL="repository is up to date"
  fi
}

check_apt() {
  local output line
  APT_COUNT=0
  APT_STATE="unavailable"
  APT_DETAIL="apt is not installed"

  if ! have apt; then
    return 0
  fi
  if ! output="$(apt list --upgradable 2>&1)"; then
    APT_STATE="error"
    APT_DETAIL="apt could not list upgrades: $output"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z $line || $line == "Listing..."* ]] && continue
    APT_COUNT=$((APT_COUNT + 1))
  done <<<"$output"
  APT_STATE="available"
  APT_DETAIL="$APT_COUNT package update(s) available"
}

flatpak_updates_for() {
  local installation="$1" output line count=0
  if ! output="$(flatpak remote-ls --updates --columns=application "--$installation" 2>&1)"; then
    if flatpak remotes "--$installation" 2>/dev/null | grep -q .; then
      return 2
    fi
    printf '0\n'
    return 0
  fi
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    count=$((count + 1))
  done <<<"$output"
  printf '%s\n' "$count"
}

check_flatpak() {
  local user_count system_count user_output system_output user_result system_result
  FLATPAK_USER_COUNT=0
  FLATPAK_SYSTEM_COUNT=0
  FLATPAK_COUNT=0
  FLATPAK_STATE="unavailable"
  FLATPAK_DETAIL="Flatpak is not installed"

  if ! have flatpak; then
    return 0
  fi

  if user_output="$(flatpak_updates_for user)"; then
    user_count="$user_output"
    user_result=0
  else
    user_result=$?
  fi
  if system_output="$(flatpak_updates_for system)"; then
    system_count="$system_output"
    system_result=0
  else
    system_result=$?
  fi

  if [[ $user_result -ne 0 || $system_result -ne 0 ]]; then
    FLATPAK_STATE="error"
    FLATPAK_DETAIL="Flatpak could not inspect one or more installations"
    return 0
  fi

  FLATPAK_USER_COUNT="${user_count:-0}"
  FLATPAK_SYSTEM_COUNT="${system_count:-0}"
  FLATPAK_COUNT=$((FLATPAK_USER_COUNT + FLATPAK_SYSTEM_COUNT))
  FLATPAK_STATE="available"
  FLATPAK_DETAIL="$FLATPAK_COUNT Flatpak update(s) available"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

acquire_lock() {
  local lock_file="${TVPC_UPDATE_LOCK_FILE:-/tmp/tvpc-update-gui.lock}"
  if ! have flock; then
    return 0
  fi
  exec 9>"$lock_file" || {
    kdialog --sorry "Could not open the updater lock file: $lock_file" --title "tvpc update"
    return 1
  }
  if ! flock -n 9; then
    kdialog --sorry "Another tvpc updater is already running." --title "tvpc update"
    return 1
  fi
}

apply_git() {
  git_plan
  if [[ $GIT_STATE != behind ]]; then
    kdialog --sorry "Repository preflight changed: $GIT_DETAIL." --title "tvpc update"
    return 1
  fi
  if ! git -C "$REPO_ROOT" pull --ff-only; then
    return 1
  fi
  if [[ -x "$REPO_ROOT/install.sh" ]]; then
    run_privileged "$REPO_ROOT/install.sh" --no-packages
  elif [[ -x "$REPO_ROOT/scripts/tvpc.sh" ]]; then
    run_privileged "$REPO_ROOT/scripts/tvpc.sh" update --no-packages
  fi
}

apply_apt() {
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
}

apply_flatpak() {
  local failed=0
  if [[ $FLATPAK_USER_COUNT -gt 0 ]] && ! flatpak update --user --noninteractive --assumeyes; then
    failed=1
  fi
  if [[ $FLATPAK_SYSTEM_COUNT -gt 0 ]] && ! run_privileged flatpak update --system --noninteractive --assumeyes; then
    failed=1
  fi
  return "$failed"
}

reboot_required() {
  local marker running newest path
  local -a markers kernels sorted

  markers=("${TVPC_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}" /run/reboot-required /var/run/reboot-required.pkgs)
  for marker in "${markers[@]}"; do
    [[ -e $marker ]] && return 0
  done

  running="$(uname -r 2>/dev/null || true)"
  shopt -s nullglob
  kernels=("${TVPC_BOOT_DIR:-/boot}"/vmlinuz-*)
  shopt -u nullglob
  if [[ ${#kernels[@]} -eq 0 || -z $running ]]; then
    return 1
  fi
  mapfile -t sorted < <(printf '%s\n' "${kernels[@]}" | sort -V)
  newest="${sorted[${#sorted[@]} - 1]##*/vmlinuz-}"
  [[ -n $newest && $newest != "$running" ]]
}

request_reboot() {
  if run_privileged systemctl reboot; then
    return 0
  fi
  kdialog --sorry "The reboot command was denied or failed." --title "tvpc update"
  return 1
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

plan_text() {
  local repo_state="${1:-}" apt_state="${2:-}" flatpak_state="${3:-}"
  printf 'Repository: %s (%s)\n' "$repo_state" "$GIT_DETAIL"
  printf 'Packages: %s (%s)\n' "$apt_state" "$APT_DETAIL"
  printf 'Flatpaks: %s (%s)\n' "$flatpak_state" "$FLATPAK_DETAIL"
}

gui_report() {
  local repo_state
  resolve_repo_root || true
  git_plan
  check_apt
  check_flatpak

  case "$GIT_STATE" in
    behind) repo_state="update available" ;;
    up-to-date) repo_state="up to date" ;;
    blocked-dirty|local-ahead|diverged|no-upstream|error) repo_state="blocked" ;;
    *) repo_state="unavailable" ;;
  esac
  show_text "tvpc update check" "$(plan_text "$repo_state" "$APT_STATE" "$FLATPAK_STATE")"
}

gui_apply() {
  local repo_state apt_state flatpak_state msg btn before_reboot after_reboot reboot_answer
  local blocked=0

  resolve_repo_root || true
  git_plan
  check_apt
  check_flatpak

  case "$GIT_STATE" in
    blocked-dirty|local-ahead|diverged|no-upstream|error) blocked=1 ;;
  esac
  [[ $APT_STATE == error || $FLATPAK_STATE == error ]] && blocked=1

  if [[ $blocked -eq 1 ]]; then
    show_text "tvpc update blocked" "$(plan_text "blocked" "$APT_STATE" "$FLATPAK_STATE")"
    return 1
  fi

  if [[ $GIT_STATE == up-to-date && $APT_COUNT -eq 0 && $FLATPAK_COUNT -eq 0 ]]; then
    if [[ $REPO_STATE == found ]]; then
      kdialog --msgbox "Everything is up to date." --title "tvpc update"
    else
      show_text "tvpc update" "No package updates are available. The tvpc repository is unavailable."
    fi
    return 0
  fi

  case "$GIT_STATE" in
    behind) repo_state="$GIT_DETAIL" ;;
    *) repo_state="no repository update" ;;
  esac
  apt_state="$APT_DETAIL"
  flatpak_state="$FLATPAK_DETAIL"
  msg="Updates are available:

$repo_state
$apt_state
$flatpak_state

Apply them now?"
  btn="$(kdialog --warningcontinuecancel "$msg" --title "tvpc update" 2>/dev/null)" || return 0
  [[ $btn == "continue" ]] || return 0

  acquire_lock || return 1
  before_reboot=0
  reboot_required && before_reboot=1

  if [[ $GIT_STATE == behind ]] && ! apply_git; then
    kdialog --sorry "Repository update failed; package updates were not started." --title "tvpc update"
    return 1
  fi
  if [[ $APT_COUNT -gt 0 ]] && ! apply_apt; then
    kdialog --sorry "Package update failed; Flatpak updates were not started." --title "tvpc update"
    return 1
  fi
  if [[ $FLATPAK_COUNT -gt 0 ]] && ! apply_flatpak; then
    kdialog --sorry "Flatpak update failed." --title "tvpc update"
    return 1
  fi

  after_reboot=0
  reboot_required && after_reboot=1
  if [[ $after_reboot -eq 0 ]]; then
    kdialog --msgbox "Updates applied. No reboot is needed." --title "tvpc update"
    return 0
  fi

  if [[ $before_reboot -eq 1 ]]; then
    msg="Updates applied. A reboot was already required before this run."
  else
    msg="Updates applied. A reboot is now required for them to take effect."
  fi
  reboot_answer="$(kdialog --warningyesno "$msg

Reboot now?" --title "tvpc update" 2>/dev/null)" || return 0
  [[ $reboot_answer == "yes" ]] && request_reboot || true
}

# ---------------------------------------------------------------------------
require_gui || exit 1
case "${1:-gui}" in
  --check|check) gui_report ;;
  gui|"")        gui_apply ;;
  *)
    kdialog --sorry "Unknown argument: $1" --title "tvpc update"
    exit 1
    ;;
esac

}

gui_power() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

pick() {
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --menu "TV power" \
      reboot   "Reboot" \
      poweroff "Power off" \
      restart  "Restart shell" \
      logout   "Log out" \
      cancel   "Cancel" 2>/dev/null || echo cancel
  elif [[ -t 0 ]]; then
    local c; PS3="Choose: "
    select c in Reboot "Power off" "Restart shell" "Log out" Cancel; do
      echo "$c"; break
    done
  else
    echo Cancel
  fi
}

case "$(pick)" in
  reboot)   systemctl reboot ;;
  poweroff) systemctl poweroff ;;
  restart)
    if command -v plasmashell >/dev/null 2>&1; then
      killall plasmashell 2>/dev/null; nohup plasmashell >/dev/null 2>&1 &
    else
      pkill -x kwin_wayland 2>/dev/null; nohup kwin_wayland --replace >/dev/null 2>&1 &
    fi ;;
  logout)
    loginctl terminate-user "$(id -un)" 2>/dev/null \
      || qdbus org.kde.ksmserver /KSMServer org.kde.KSMServerInterface.logout 0 0 0 2>/dev/null \
      || true ;;
  *) : ;;
esac

}

gui_allapps() {
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

# shellcheck source=/dev/null
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6 2>/dev/null || true)"

# id<TAB>name<TAB>desktop-path  — every Application, no blacklist filtering.
list_all() {
  local d f id name type nodisp
  for d in /usr/share/applications /usr/local/share/applications \
           "${HOME_DIR:+$HOME_DIR/.local/share/applications}" \
           /var/lib/flatpak/exports/share/applications; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do
      [[ -f $f ]] || continue
      type="$(sed -n 's/^Type=//p'      "$f" | head -1)"
      nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
      [[ $type == Application ]] || continue
      [[ $nodisp == true ]]      && continue
      id="$(basename "$f" .desktop)"
      name="$(sed -n 's/^Name=//p' "$f" | head -1)"
      printf '%s\t%s\t%s\n' "$id" "${name:-$id}" "$f"
    done
  done | sort -t$'\t' -k2,2 -u
}

pick_and_run() {
  local sel id
  if command -v kdialog >/dev/null 2>&1; then
    local args=()
    while IFS=$'\t' read -r id name _; do args+=("$id" "$name"); done < <(list_all)
    sel="$(kdialog --menu "All applications" "${args[@]}" 2>/dev/null)" || return 0
  elif command -v fuzzel >/dev/null 2>&1; then
    sel="$(list_all | cut -f2 | fuzzel --dmenu 2>/dev/null)" || return 0
    sel="$(list_all | awk -F'\t' -v n="$sel" '$2==n{print $1; exit}')"
  elif command -v wofi >/dev/null 2>&1; then
    sel="$(list_all | cut -f2 | wofi --dmenu 2>/dev/null)" || return 0
    sel="$(list_all | awk -F'\t' -v n="$sel" '$2==n{print $1; exit}')"
  elif [[ -t 0 ]]; then
    local -a names=() ids=()
    while IFS=$'\t' read -r id name _; do ids+=("$id"); names+=("$name"); done < <(list_all)
    [[ ${#ids[@]} -eq 0 ]] && return 0
    select _ in "${names[@]}"; do sel="${ids[$REPLY-1]}"; break; done
  else
    return 0
  fi
  [[ -z $sel ]] && return 0
  command -v kde-open5 >/dev/null 2>&1 && kde-open5 "application://$sel.desktop" >/dev/null 2>&1 && return 0
  command -v gtk-launch >/dev/null 2>&1 && gtk-launch "$sel" >/dev/null 2>&1 && return 0
  local path; path="$(list_all | awk -F'\t' -v id="$sel" '$1==id{print $3; exit}')"
  [[ -n $path ]] && nohup sh -c "$(sed -n 's/^Exec=//p' "$path" | head -1 | sed 's/%[fFuU]//g')" >/dev/null 2>&1 &
}

pick_and_run

}

subcmd_gui() {
  local dialog="${1:-}"
  case "$dialog" in
    setup)
      shift
      gui_setup "$@"
      ;;
    update)
      shift
      gui_update "$@"
      ;;
    power)
      shift
      gui_power "$@"
      ;;
    allapps)
      shift
      gui_allapps "$@"
      ;;
    tweaks|"")
      subcmd_tweaks ""
      ;;
    *)
      echo "Unknown GUI dialog: $dialog (expected: setup, update, power, allapps, tweaks)" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main Multi-call Symlink & Subcommand Dispatcher
# ---------------------------------------------------------------------------
show_help() {
  cat <<'EOF'
tvpc — Unified HTPC Appliance Manager for Ubuntu 24.04
Usage:
  tvpc <command> [arguments...]

Commands:
  cec          HDMI-CEC management (poweron, setup, check, listen)
  audio        HDMI PipeWire/ALSA audio sink routing & status
  session      Session manager (auto, plasma, hypr, kiosk)
  bigscreen    Plasma Bigscreen setup, UI scaling, topbar, app hiding
  theme        Bigscreen themes (list, status, set, preview, install, revert)
  cameras      Security camera suite (list, stream, snap, record, gui, tile, pip, grid)
  hyprland     Hyprland TV session installer, menu, autostart
  controller   Gamepad, Bluetooth, and remote controller pairing & status
  doctor       Appliance hardware and configuration diagnostic checks
  repair       System recovery & boot repair tool (--check, --logs, repair)
  status       Couch dashboard and system status monitor
  tweaks       System tweaks & customisation (cec-list, cec-get, cec-set, scale, ...)
  gui          Interactive TV dialogs (setup, update, power, allapps, tweaks)

Symlink / Legacy command shortcuts:
  tvpc-cec, tvpc-hdmi-audio, tvpc-session, tvpc-bigscreen, tvpc-bigscreen-theme,
  tvpc-cameras, tvpc-cameras-gui, tvpc-cameras-tile, tvpc-hyprland, tvpc-hypr-menu,
  tvpc-hypr-autostart, tvpc-controller, tvpc-doctor, tvpc-repair, tvpc-status,
  tvpc-tweaks, tvpc-power, tvpc-setup-gui, tvpc-update-gui, tvpc-allapps,
  tvpc-vacuumtube-scroll, cec-tv-poweron.sh, tvpc-cec-setup, tvpc-update
EOF
}

INVOKED_AS="$(basename "$0")"

case "$INVOKED_AS" in
  tvpc-cec)
    subcmd_cec "$@"
    ;;
  cec-tv-poweron.sh)
    if [[ $# -eq 0 ]]; then
      subcmd_cec poweron
    else
      subcmd_cec poweron "$@"
    fi
    ;;
  tvpc-cec-setup)
    if [[ $# -eq 0 ]]; then
      subcmd_cec setup
    else
      subcmd_cec setup "$@"
    fi
    ;;
  tvpc-hdmi-audio)
    subcmd_audio "$@"
    ;;
  tvpc-session)
    subcmd_session "$@"
    ;;
  tvpc-bigscreen)
    subcmd_bigscreen "$@"
    ;;
  tvpc-bigscreen-theme)
    subcmd_theme "$@"
    ;;
  tvpc-cameras)
    subcmd_cameras "$@"
    ;;
  tvpc-cameras-gui)
    subcmd_cameras gui "$@"
    ;;
  tvpc-cameras-tile)
    subcmd_cameras tile "$@"
    ;;
  tvpc-hyprland)
    subcmd_hyprland "$@"
    ;;
  tvpc-hypr-menu)
    subcmd_hyprland menu "$@"
    ;;
  tvpc-hypr-autostart)
    subcmd_hyprland autostart "$@"
    ;;
  tvpc-controller)
    subcmd_controller "$@"
    ;;
  tvpc-doctor)
    subcmd_doctor "$@"
    ;;
  tvpc-repair)
    subcmd_repair "$@"
    ;;
  tvpc-status)
    subcmd_status "$@"
    ;;
  tvpc-tweaks)
    subcmd_tweaks "$@"
    ;;
  tvpc-vacuumtube-scroll)
    subcmd_tweaks vacuumtube-scroll "$@"
    ;;
  tvpc-power)
    subcmd_gui power "$@"
    ;;
  tvpc-allapps)
    subcmd_gui allapps "$@"
    ;;
  tvpc-setup-gui)
    subcmd_gui setup "$@"
    ;;
  tvpc-update-gui)
    subcmd_gui update "$@"
    ;;
  tvpc-update)
    exec "$REPO_ROOT/install.sh" --update "$@"
    ;;
  *)
    CMD="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$CMD" in
      cec)              subcmd_cec "$@" ;;
      audio)            subcmd_audio "$@" ;;
      session)          subcmd_session "$@" ;;
      bigscreen)        subcmd_bigscreen "$@" ;;
      theme)            subcmd_theme "$@" ;;
      cameras|camera)   subcmd_cameras "$@" ;;
      hyprland|hypr)    subcmd_hyprland "$@" ;;
      controller|input) subcmd_controller "$@" ;;
      doctor)           subcmd_doctor "$@" ;;
      repair)           subcmd_repair "$@" ;;
      status)           subcmd_status "$@" ;;
      tweaks)           subcmd_tweaks "$@" ;;
      gui)              subcmd_gui "$@" ;;
      update)           exec "$REPO_ROOT/install.sh" --update "$@" ;;
      help|--help|-h)   show_help; exit 0 ;;
      "")               show_help; exit 0 ;;
      *)
        echo "Unknown command '$CMD'. Run 'tvpc help' for available commands." >&2
        exit 1
        ;;
    esac
    ;;
esac
