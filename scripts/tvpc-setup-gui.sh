#!/usr/bin/env bash
# tvpc-setup-gui — a couch-friendly GUI for input / CEC / Anynet+ setup.
#
# Driven by kdialog so it works over the CEC remote (D-pad + Enter) as
# well as a mouse. Privileged actions use pkexec (or sudo as a fallback),
# and command output is shown in a dialog instead of disappearing into a
# terminal that the TV session does not have.
#
# Usage:
#   tvpc-setup-gui              # interactive GUI
#   tvpc-setup-gui --check      # report state, change nothing
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

# shellcheck source=/dev/null
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

have() { command -v "$1" >/dev/null 2>&1; }
require_gui() {
  if ! have kdialog; then
    printf 'tvpc-setup-gui needs kdialog (the Plasma dialog tool).\n' >&2
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
