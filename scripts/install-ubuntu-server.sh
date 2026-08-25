#!/usr/bin/env bash
set -euo pipefail

# install-ubuntu-server.sh — Create a bootable Ubuntu 24.04 Server USB
# with autoinstall config for Intel NUC7i5BNH.
#
# Usage:
#   ./scripts/install-ubuntu-server.sh /dev/sdX
#
# Where /dev/sdX is your USB drive (will be wiped).
#
# The resulting USB will automatically install Ubuntu 24.04 minimal +
# base HTPC tuning, then reboot into a fresh `htpc` user session.
# Run ./install.sh afterward (or copy it to the USB for auto-run).

ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
ISO_FILE="/tmp/ubuntu-24.04.2-live-server-amd64.iso"
AUTOINSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/autoinstall"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /dev/sdX   (the USB device path)"
  echo ""
  echo "Example:"
  echo "  lsblk                  # find your USB drive"
  echo "  $0 /dev/sdX"
  exit 1
fi

USB_DEV="$1"
if [[ ! -b "$USB_DEV" ]]; then
  echo "Error: $USB_DEV is not a block device"
  exit 1
fi

echo "USB device: $USB_DEV"
echo "WARNING: All data on $USB_DEV will be destroyed!"
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || exit 1

# Download ISO if not present
if [[ ! -f "$ISO_FILE" ]]; then
  echo "Downloading Ubuntu 24.04 Server ISO..."
  wget -q "$ISO_URL" -O "$ISO_FILE"
fi

# Write ISO + seed
echo "Creating bootable USB..."
sudo dd if="$ISO_FILE" of="$USB_DEV" bs=4M status=progress oflag=sync

# Mount the USB ESP and add autoinstall
echo "Adding autoinstall cloud-init config..."
mkdir -p /mnt/tmp-usb
sudo mount "${USB_DEV}1" /mnt/tmp-usb
sudo mkdir -p /mnt/tmp-usb/datasources/unified
sudo cp "$AUTOINSTALL_DIR/user-data" /mnt/tmp-usb/datasources/unified/user-data
sudo cp "$AUTOINSTALL_DIR/meta-data" /mnt/tmp-usb/datasources/unified/meta-data
sudo umount /mnt/tmp-usb
rmdir /mnt/tmp-usb

# Write repo to USB for post-install
echo "Copying tvpc repo to USB for post-install use..."
sudo mkdir -p "/mnt/tmp-usb2"
sudo mount "${USB_DEV}1" "/mnt/tmp-usb2"
sudo cp -r "$(dirname "${BASH_SOURCE[0]}")/.." "/mnt/tmp-usb2/tvpc-postinstall"
sudo umount "/mnt/tmp-usb2"
rmdir /mnt/tmp-usb2

echo "============================================"
echo " Bootable Ubuntu 24.04 Server USB with"
echo " auto-install config for Intel NUC7i5BNH"
echo " is ready: $USB_DEV"
echo ""
echo " Insert into the NUC, boot, and let it install."
echo " After install, SSH to tvpc.local (or find it via"
echo " the network) and run:"
echo "     scp -r /tvpc-postinstall htpc@tvpc.local:/home/htpc/tvpc"
echo "     ssh htpc@tvpc.local"
echo "     cd tvpc && sudo ./install.sh"
echo "============================================"