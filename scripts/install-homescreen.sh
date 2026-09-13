#!/usr/bin/env bash
# ==============================================================================
# install-homescreen.sh — Install Kodi / LibreELEC Estuary Homescreen for Bigscreen
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

THEME="${1:-estuary}"

echo "=================================================================="
echo "  tvpc — Installing Kodi / LibreELEC Estuary Bigscreen Homescreen"
echo "=================================================================="

# 1. Deploy the homescreen plasmoid overlay and configure theme
if [[ -x "$SCRIPT_DIR/tvpc.sh" ]]; then
    "$SCRIPT_DIR/tvpc.sh" theme install
    "$SCRIPT_DIR/tvpc.sh" theme set "$THEME"
else
    echo "Error: $SCRIPT_DIR/tvpc.sh not found or not executable" >&2
    exit 1
fi

echo
echo "Homescreen successfully installed with theme: $THEME"
echo "To preview or change themes at any time, run:"
echo "  tvpc-bigscreen-theme list"
echo "  tvpc-bigscreen-theme set <theme-id>"
echo "=================================================================="
