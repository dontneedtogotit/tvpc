#!/usr/bin/env bash
# tvpc-cameras-gui — launcher for the PySide6 GUI front-end
#
# Usage: tvpc-cameras-gui [--config PATH] [--skip-wizard]
#
# This is a thin wrapper: it just runs `python3 -m tvpc_cameras_gui`.
# The GUI reads the same cameras.conf that the bash tvpc-cameras script
# uses, so the two stay interchangeable.
#
# On first run, the GUI shows a setup wizard that checks for required
# dependencies (PySide6, ffmpeg, mpv) and offers to install any that are
# missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "$SCRIPT_DIR/tvpc-cameras.sh" ]]; then
    exec "$SCRIPT_DIR/tvpc-cameras.sh" gui "$@"
elif command -v tvpc-cameras >/dev/null 2>&1; then
    exec tvpc-cameras gui "$@"
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. sudo apt-get install python3" >&2
    exit 1
fi

if ! python3 -c "import tvpc_cameras_gui" 2>/dev/null; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [[ -d "$REPO_ROOT/tvpc_cameras_gui" ]]; then
        export PYTHONPATH="${REPO_ROOT}${PYTHONPATH:+:$PYTHONPATH}"
    fi
fi

exec python3 -m tvpc_cameras_gui "$@"
