#!/usr/bin/env bash
# tvpc-power — power / session menu for the TV home screen.
#
# Opened from the "Power" home tile. Prefers a GUI dialog (kdialog), falls
# back to a console menu on a terminal, and does nothing if headless.
#   tvpc-power
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
