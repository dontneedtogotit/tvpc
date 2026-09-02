#!/usr/bin/env bash
# tvpc-cameras-gui — launcher for the PySide6 GUI front-end
#
# Usage: tvpc-cameras-gui [--config PATH]
#
# This is a thin wrapper: it just runs `python3 -m tvpc_cameras_gui`.
# The GUI reads the same cameras.conf that the bash tvpc-cameras script
# uses, so the two stay interchangeable.
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. sudo apt-get install python3" >&2
    exit 1
fi

exec python3 -m tvpc_cameras_gui "$@"
