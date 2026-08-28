#!/usr/bin/env bash
# tvpc-hypr-menu — the launcher for the Hyprland TV session.
#
# Bound to the remote's menu button (bare Super) in hyprland.lua. Shows a
# short, curated list rather than every .desktop file on the system: a
# five-button remote is a bad way to scroll two hundred entries.
#
# Usage:
#   tvpc-hypr-menu          curated app list
#   tvpc-hypr-menu all      every installed application
#   tvpc-hypr-menu power    power / session menu
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
