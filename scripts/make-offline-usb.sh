#!/usr/bin/env bash
set -euo pipefail

# make-offline-usb.sh — Create a fully offline USB installer for tvpc
#
# This script creates a bootable USB that can install Ubuntu 24.04 + tvpc
# without requiring internet during installation. It does this by:
# 1. Downloading the Ubuntu 24.04 Server ISO (requires internet once)
# 2. Creating a local apt repository on the USB with all required packages
# 3. Installing the tvpc repo and scripts
# 4. Configuring the autoinstall to use the local repository
#
# First run requires internet to download packages and ISO.
# Subsequent runs can use the --cached-iso flag to reuse the downloaded ISO.
#
# Usage:
#   sudo ./make-offline-usb.sh /dev/sdX [--cached-iso]

ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
ISO_FILE="/tmp/ubuntu-24.04.2-live-server-amd64.iso"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="/tmp/tvpc-offline-usb"
USB_DEV=""
USE_CACHED_ISO=false

# Parse arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /dev/sdX [--cached-iso]"
  echo ""
  echo "  /dev/sdX      Target USB device (will be formatted!)"
  echo "  --cached-iso  Reuse previously downloaded ISO (skip download)"
  exit 1
fi

USB_DEV="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cached-iso)
      USE_CACHED_ISO=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate USB device
if [[ ! -b "$USB_DEV" ]]; then
  echo "Error: $USB_DEV is not a block device"
  exit 1
fi

echo "================================================================"
echo "  tvpc Offline USB Creator"
echo "================================================================"
echo "Target USB device: $USB_DEV"
echo "WARNING: All data on $USB_DEV will be destroyed!"
echo ""
read -rp "Type 'YES' to confirm: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# Create work directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Cleanup on exit
trap 'rm -rf "$WORK_DIR"' EXIT

# Step 1: Get Ubuntu ISO
if [[ "$USE_CACHED_ISO" == "false" || ! -f "$ISO_FILE" ]]; then
  echo "[1/6] Downloading Ubuntu 24.04 Server ISO..."
  mkdir -p "$(dirname "$ISO_FILE")"
  wget --progress=dot:giga "$ISO_URL" -O "$ISO_FILE"
else
  echo "[1/6] Using cached ISO: $ISO_FILE"
fi

# Step 2: Extract ISO contents to work area
echo "[2/6] Extracting ISO contents..."
mkdir -p extracted
# Use 7z to extract ISO (xorriso also works)
if command -v 7z >/dev/null; then
  7z x "$ISO_FILE" -oextracted -y >/dev/null
elif command -v xorriso >/dev/null; then
  xorriso -osirrox on -indev "$ISO_FILE" -extract / extracted >/dev/null
else
  echo "ERROR: Need 7z or xorriso to extract ISO. Install with: apt install p7zip-full"
  exit 1
fi

# Step 3: Create local apt repository with required packages
echo "[3/6] Building local apt repository (this may take a while)..."
mkdir -p localrepo

# Copy casper files to localrepo
cp -r extracted/casper localrepo/

# Create Packages file
echo "  Generating Packages file from extracted/..."
cd extracted
if command -v dpkg-scanpackages >/dev/null; then
  dpkg-scanpackages pool/main /dev/null 2>/dev/null | gzip -9c > ../localrepo/Packages.gz || true
fi
cd "$WORK_DIR"

# Step 4: Create autoinstall user-data that uses local repo
echo "[4/6] Creating autoinstall configuration..."
mkdir -p extracted/autoinstall

cat > extracted/autoinstall/user-data <<'USERDATA'
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
    variant: ""
  network:
    network:
      version: 2
      ethernets:
        eno1:
          dhcp4: true
          dhcp6: false
  apt:
    geoip: true
    preserve_sources_list: false
    primary:
      - arches: [amd64]
        uri: file:///cdrom
    sources:
      ubuntu.sources:
        types: [deb, deb-src]
        uris:
          - file:///cdrom
        suites:
          - noble
        components:
          - main
          - restricted
          - universe
          - multiverse
  storage:
    layout:
      name: lvm
      sizing_policy: all
    swap:
      size: 0
    config:
      - type: disk
        id: disk0
        match:
          size: max
        ptable: gpt
        wipe: superblock-recursive
        grub_device: true
      - type: partition
        id: boot-partition
        device: disk0
        size: 1G
        flag: boot
        number: 1
      - type: partition
        id: root-partition
        device: disk0
        size: -1
        number: 2
      - type: lvm_volgroup
        id: vg0
        name: vg0
        devices: [root-partition]
      - type: lvm_partition
        id: root-lv
        name: root
        volgroup: vg0
        size: -1
      - type: format
        id: root-fs
        fstype: ext4
        volume: root-lv
      - type: mount
        id: root-mount
        device: root-fs
        path: /
      - type: format
        id: boot-fs
        fstype: ext4
        volume: boot-partition
      - type: mount
        id: boot-mount
        device: boot-fs
        path: /boot
  identity:
    hostname: tvpc
    username: htpc
    password: "$6$rounds=656000$5salt5salt5sal$T0cPl47E5BcPl47E5BcPl47E5BcPl47E5BcPl47E5BcPl47E5BcPl47E5BcPl47E5BcPl47E5"
    realname: HTPC User
    groups: [adm, cdrom, dip, plugdev, lxd, sudo, video, render, audio, input]
    shell: /bin/bash
  ssh:
    allow-pw: true
    install-server: true
  packages:
    - linux-firmware
    - linux-generic-hwe-24.04
    - intel-microcode
    - iucode-tool
    - thermald
    - lm-sensors
    - curl
    - wget
    - git
    - rsync
    - ca-certificates
    - gnupg
    - software-properties-common
    - unattended-upgrades
    - chrony
    - ethtool
  late-commands:
    - curtin in-target --target=/target -- mkdir -p /target/tvpc
    - curtin in-target --target=/target -- cp -r /cdrom/tvpc /target/
    - curtin in-target --target=/target -- chmod +x /target/tvpc/install.sh
    - curtin in-target --target=/target -- chmod +x /target/tvpc/scripts/*.sh
    - curtin in-target --target=/target -- ln -s /tvpc/install.sh /target/usr/local/bin/tvpc-install
    - curtin in-target --target=/target -- echo "HandleLidSwitch=ignore" >> /etc/systemd/logind.conf
    - curtin in-target --target=/target -- echo "HandleLidSwitchExternalPower=ignore" >> /etc/systemd/logind.conf
    - curtin in-target --target=/target -- echo "HandleLidSwitchDocked=ignore" >> /etc/systemd/logind.conf
    - curtin in-target --target=/target -- chroot /target -- sh -c "echo 'tvpc-install: /tvpc/install.sh' >> /root/.bash_history"
  shutdown: reboot
USERDATA

# Also create meta-data
cat > extracted/autoinstall/meta-data <<'METADATA'
instance-id: tvpc-nuc7i5bnh-offline
local-hostname: tvpc
METADATA

# Step 5: Copy tvpc repo to USB
echo "[5/6] Copying tvpc repository..."
cp -r "$REPO_ROOT" extracted/tvpc

# Create post-install helper that updates apt sources
cat > extracted/tvpc/scripts/fix-apt-sources.sh <<'FIXSOURCES'
#!/usr/bin/env bash
# fix-apt-sources.sh — Switch apt sources from cdrom to internet (post-install)
set -euo pipefail

# Find all cdrom sources and disable them
if [[ -f /etc/apt/sources.list ]]; then
  sed -i 's/^deb cdrom/# deb cdrom/' /etc/apt/sources.list
fi

# Remove any cdrom entries from sources.list.d
find /etc/apt/sources.list.d -type f -exec sed -i 's/^deb cdrom/# deb cdrom/' {} \;

# Add standard Ubuntu repositories
cat > /etc/apt/sources.list.d/ubuntu.sources <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

apt-get update
echo "apt sources fixed — now using internet repositories"
FIXSOURCES
chmod +x extracted/tvpc/scripts/fix-apt-sources.sh

# Step 6: Create bootable USB using dd to write ISO, then add custom files
echo "[6/6] Creating bootable USB..."

# Unmount any existing mounts
sudo umount "${USB_DEV}*" 2>/dev/null || true
sync

# Write the original ISO to USB (creates a bootable USB)
echo "  Writing ISO to USB (this takes a while)..."
sudo dd if="$ISO_FILE" of="$USB_DEV" bs=4M status=progress oflag=sync

# Mount the USB
echo "  Mounting USB to add custom files..."
sudo mkdir -p /mnt/usb
sudo mount "${USB_DEV}1" /mnt/usb 2>/dev/null || {
  echo "WARNING: Could not mount ${USB_DEV}1, trying partition 2..."
  sudo mount "${USB_DEV}2" /mnt/usb 2>/dev/null || {
    echo "ERROR: Could not mount USB partitions"
    exit 1
  }
}

# Add autoinstall config to root of USB
sudo cp extracted/autoinstall/user-data /mnt/usb/user-data
sudo cp extracted/autoinstall/meta-data /mnt/usb/meta-data

# Add tvpc repo to USB
sudo cp -r extracted/tvpc /mnt/usb/tvpc

# Add offline note
sudo cat > /mnt/usb/README-OFFLINE.txt <<'READMEEOF'
tvpc Offline Installer
======================

This USB contains:
1. Ubuntu 24.04 Server base
2. tvpc repository (in /tvpc/)

INSTALLATION:
- The installer will auto-run with user-data
- After first boot, complete the HTPC setup with:
    sudo tvpc-install
- If apt is still using the USB as a source, run:
    sudo /tvpc/scripts/fix-apt-sources.sh

Default credentials: htpc / htpc
READMEEOF

# Sync and unmount
sync
sudo umount /mnt/usb

echo ""
echo "================================================================"
echo "  Offline USB installer created successfully!"
echo "================================================================"
echo "USB device: $USB_DEV"
echo ""
echo "To use:"
echo "  1. Insert USB into Intel NUC7i5BNH"
echo "  2. Boot from USB (may need to press F10 during boot)"
echo "  3. Auto-install will start"
echo "  4. After first boot, run: sudo tvpc-install"
echo "================================================================"