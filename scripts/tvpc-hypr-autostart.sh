#!/usr/bin/env bash
# tvpc-hypr-autostart — things the Hyprland TV session starts once, at login.
#
# Kept out of hyprland.lua so it can be changed without risking a config
# parse error on a box whose only display is a television.
#
# Set TVPC_AUTOSTART_APP in /etc/default/tvpc to launch something straight
# away, e.g. TVPC_AUTOSTART_APP="flatpak run io.github.vacuumtube.VacuumTube".
# Left unset, the session comes up at the launcher.
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
