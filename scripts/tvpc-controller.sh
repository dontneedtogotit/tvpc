#!/usr/bin/env bash
# tvpc-controller — pair and configure input devices for the TV couch.
#
# Plasma Bigscreen has first-class gamepad / remote / keyboard support via
# `plasma-bigscreen-inputhandler`, so any of these work without CEC:
#
#   gamepad     Bluetooth or USB gamepad (Xbox, PlayStation, generic)
#   kdeconnect  Phone-as-remote over Wi-Fi
#   flirc       USB IR receiver + any universal remote
#   keyboard    Any USB / Bluetooth keyboard already works (no setup)
#
# Usage:
#   sudo tvpc-controller status
#   sudo tvpc-controller pair-gamepad          (interactive)
#   sudo tvpc-controller pair-gamepad <MAC>     (non-interactive)
#   sudo tvpc-controller pair-kdeconnect
#   sudo tvpc-controller setup-flirc
#   sudo tvpc-controller help
#
# All subcommands work without root for Bluetooth scanning, but the script
# must be run as root to install packages and bring up the bluetooth service
# reliably. KDE Connect pairing itself happens in the user session.
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
