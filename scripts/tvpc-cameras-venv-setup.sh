#!/bin/bash
# tvpc-cameras-venv-setup.sh - Set up venv and install dependencies for tvpc-cameras-gui
# Run this on the TV PC to enable auto-venv functionality

set -euo pipefail

VENV_DIR="$HOME/.local/share/tvpc/tvpc-cameras-gui-venv"
PACKAGES="PySide6 requests"

echo "=== tvpc-cameras-gui venv setup ==="
echo ""

# Check if already in venv
CURRENT_PREFIX=$(python3 -c 'import sys; print(sys.prefix)')
if [[ "${VIRTUAL_ENV:-}" == "$VENV_DIR" ]] || [[ "$CURRENT_PREFIX" == "$VENV_DIR" ]]; then
    echo "Already running in the venv at: $VENV_DIR"
    echo ""
    echo "To use the GUI, run:"
    echo "  python3 -m tvpc_cameras_gui"
    exit 0
fi

# Create venv directory
echo "Creating venv directory..."
mkdir -p "$(dirname "$VENV_DIR")"

# Create venv
echo "Creating virtual environment..."
if command -v python3 &>/dev/null; then
    python3 -m venv "$VENV_DIR" --clear
else
    echo "ERROR: python3 not found"
    exit 1
fi

# Upgrade pip in venv
echo "Upgrading pip..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip

# Install packages
echo "Installing packages: $PACKAGES"
"$VENV_DIR/bin/pip" install --quiet $PACKAGES

echo ""
echo "=== Setup complete ==="
echo ""
echo "To run the camera GUI, use:"
echo "  $VENV_DIR/bin/python -m tvpc_cameras_gui"
echo ""
echo "Or activate the venv and run:"
echo "  source $VENV_DIR/bin/activate"
echo "  python -m tvpc_cameras_gui"
