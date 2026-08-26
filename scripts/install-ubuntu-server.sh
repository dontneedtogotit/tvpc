#!/usr/bin/env bash
set -euo pipefail

# install-ubuntu-server.sh — Create a bootable Ubuntu 24.04 Server USB
# with autoinstall config for Intel NUC7i5BNH.
#
# Requires: internet for ISO download. 7z or xorriso for ISO extraction.
#
# Usage:
#   sudo ./scripts/install-ubuntu-server.sh /dev/sdX
#
# After install: SSH to tvpc.local (htpc/htpc) then run tvpc-install.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTOINSTALL_DIR="$REPO_ROOT/autoinstall"
USB_DEV="${1:-}"
ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
ISO_FILE="/tmp/ubuntu-24.04.2-live-server-amd64.iso"
WORK_DIR="/tmp/tvpc-usb.$$"

usage() {
  echo "Usage: $0 /dev/sdX"
  echo ""
  echo "  /dev/sdX   USB device (will be wiped)"
  echo ""
  echo "Prerequisites: apt install p7zip-full xorriso wget"
  exit 1
}

if [[ -z "$USB_DEV" ]]; then
  usage
fi

if [[ ! -b "$USB_DEV" ]]; then
  echo "Error: $USB_DEV is not a block device"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo $0)"
  exit 1
fi

echo "=== tvpc USB installer ==="
echo "Target: $USB_DEV  (will be wiped!)"
read -rp "Type 'YES' to confirm: " C
[[ "$C" == "YES" ]] || { echo "Aborted."; exit 1; }

# Cleanup trap
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 1. Download ISO
if [[ ! -f "$ISO_FILE" ]]; then
  echo "[1/5] Downloading Ubuntu 24.04 Server ISO..."
  wget --progress=dot:giga "$ISO_URL" -O "$ISO_FILE"
else
  echo "[1/5] Using cached ISO: $ISO_FILE"
fi

# 2. Extract ISO
echo "[2/5] Extracting ISO..."
if command -v 7z >/dev/null; then
  7z x "$ISO_FILE" -o"$WORK_DIR/extracted" -y >/dev/null
elif command -v xorriso >/dev/null; then
  mkdir -p "$WORK_DIR/extracted"
  xorriso -osirrox on -indev "$ISO_FILE" -extract / "$WORK_DIR/extracted" >/dev/null
else
  echo "ERROR: Install p7zip-full or xorriso:  apt install p7zip-full"
  exit 1
fi

# 3. Copy autoinstall config
echo "[3/5] Adding autoinstall config..."
mkdir -p "$WORK_DIR/extracted/autoinstall"
cp "$AUTOINSTALL_DIR/user-data" "$WORK_DIR/extracted/autoinstall/user-data"
cp "$AUTOINSTALL_DIR/meta-data" "$WORK_DIR/extracted/autoinstall/meta-data"

# 4. Copy tvpc repo
echo "[4/5] Copying tvpc repo to USB..."
cp -r "$REPO_ROOT" "$WORK_DIR/extracted/tvpc"

# 5. Write to USB
echo "[5/5] Writing to USB..."
sudo umount "${USB_DEV}"* 2>/dev/null || true
sync
sudo dd if="$ISO_FILE" of="$USB_DEV" bs=4M status=progress oflag=sync
sync

# Mount and add custom files
sudo mkdir -p /mnt/usb
sudo mount "${USB_DEV}1" /mnt/usb 2>/dev/null || sudo mount "${USB_DEV}2" /mnt/usb
cp -r "$WORK_DIR/extracted/autoinstall" /mnt/usb/
cp -r "$WORK_DIR/extracted/tvpc" /mnt/usb/
cat > /mnt/usb/README.txt <<'EOF'
tvpc Installer
==============
tvpc repo is at /tvpc/
After install:  ssh htpc@tvpc.local  (password: htpc)
Then run:       cd /tvpc && sudo ./install.sh && sudo reboot
EOF
sync
sudo umount /mnt/usb

echo "=== Done! ==="
echo "Insert USB into NUC, boot from USB, let it install."
echo "After install: ssh htpc@tvpc.local  password: htpc"
echo "Then: cd tvpc && sudo ./install.sh && sudo reboot"