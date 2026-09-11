#!/bin/sh
# Sourced by startplasma before the session comes up. environment.d only
# reaches systemd user units, so session-level variables belong here too.
export LIBVA_DRIVER_NAME=iHD
export YDOTOOL_SOCKET=/run/ydotoold/socket
# Enable client/server window decorations on Wayland so titlebar and Close X button appear
export QT_WAYLAND_DISABLE_WINDOWDECORATION=0
