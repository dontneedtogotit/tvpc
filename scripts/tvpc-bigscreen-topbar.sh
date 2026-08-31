#!/usr/bin/env bash
# tvpc-bigscreen-topbar — Enlarge the Plasma Bigscreen top bar (and the
# wifi / volume / shutdown indicators inside it).
#
# Bigscreen 5.27.x defines the top bar in the homescreen plasmoid as a single
# Item whose height comes from Kirigami.Units.iconSizes.medium. The indicator
# buttons (Wifi, Volume, Shutdown) sit inside a RowLayout and use
# `Layout.fillHeight: true` with `implicitWidth: height`, so making the bar
# taller also makes every indicator bigger for free. This script bumps that
# one line and keeps a backup so it can be reverted.
#
# Usage:
#   sudo ./scripts/tvpc-bigscreen-topbar.sh     patch (medium -> large, ~1.45x)
#   sudo ./scripts/tvpc-bigscreen-topbar.sh xl  patch (medium -> huge,   ~2.2x)
#   sudo ./scripts/tvpc-bigscreen-topbar.sh --revert
#
# After patching, log out and back in (or restart the Bigscreen session).
set -euo pipefail

MAIN_QML="/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen/contents/ui/main.qml"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0) — the file is owned by root." >&2; exit 1; }
[[ -f $MAIN_QML ]] || { echo "Not found: $MAIN_QML" >&2
                       echo "Is plasma-bigscreen installed and are you on the Bigscreen session?" >&2
                       exit 1; }

BAK="${MAIN_QML}.tvpc-bak"

case "${1:-}" in
    --revert)
        if [[ -f $BAK ]]; then
            cp -a "$BAK" "$MAIN_QML"
            echo "Reverted to original."
        else
            echo "No backup at $BAK — nothing to revert." >&2
            exit 1
        fi
        exit 0 ;;
    xl)   TARGET="huge"  ;;
    ""|normal) TARGET="large" ;;
    *)
        echo "Usage: $0 [xl|--revert]"; exit 1 ;;
esac

if [[ ! -f $BAK ]]; then
    cp -a "$MAIN_QML" "$BAK"
    echo "Backup -> $BAK"
fi

# The exact line on 5.27.11 is:
#   height: Kirigami.Units.iconSizes.medium + Kirigami.Units.smallSpacing * 2
# Replace only `iconSizes.medium` -> `iconSizes.<TARGET>`. Everything else
# (spacing, indicators, layout) is left alone, so the bar scales and the
# indicators fill the new height automatically.
if grep -q 'iconSizes\.medium + Kirigami\.Units\.smallSpacing \* 2' "$MAIN_QML"; then
    sed -i "s/iconSizes\.medium + Kirigami\.Units\.smallSpacing \* 2/iconSizes.${TARGET} + Kirigami.Units.smallSpacing * 2/" "$MAIN_QML"
    echo "Patched topBar.height: medium -> ${TARGET}"
elif grep -q "iconSizes\.${TARGET} + Kirigami\.Units\.smallSpacing" "$MAIN_QML"; then
    echo "Already patched to '${TARGET}'. (run with --revert to undo first)"
else
    echo "Could not find the expected top-bar height line." >&2
    echo "Look manually:  grep -n 'topBar\\|iconSizes' $MAIN_QML" >&2
    exit 1
fi

echo "Log out and back in (or restart the Bigscreen session) to see the change."
echo "Revert with:  sudo $0 --revert"
