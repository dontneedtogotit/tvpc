#!/usr/bin/env bash
# tvpc-status — visual dashboard of what tvpc has, what's missing, and
# what's broken. Designed to be readable from a couch with a D-pad.
#
# Usage:
#   tvpc-status               show the GUI dashboard
#   tvpc-status --report      print a plain-text report and exit
#   tvpc-status --check ID    run one check, print one line, exit 0/1
#   tvpc-status help
#
# The GUI auto-picks the best available dialog tool:
#   kdialog  (Plasma native)  →  yad  (richest)  →  zenity  →  console
#
# Every check has a fix command you can run from the detail dialog.
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
