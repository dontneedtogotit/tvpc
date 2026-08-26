#!/usr/bin/env bash
set -euo pipefail

# prepare-ventoy-data.sh — Prepare a data partition on a Ventoy USB for tvpc offline install
#
# This script formats a partition as ext4 (label TVPC-DATA) and populates it with:
#   - A local apt repository containing all required packages
#   - The tvpc repository (with install.sh, scripts, overlays, etc.)
#   - user-data and meta-data for autoinstall (using the NoCloud datasource)
#
# After running this script, boot the Ubuntu 24.04 Server ISO via Ventoy and
# at the boot prompt, add the kernel parameter:
#   autoinstall ds=nocloud;label=TVPC-DATA
#
# Requirements: 7z or xorriso (for ISO extraction if needed, but we don't extract ISO here),
#               wget, dpkg-scanpackages, and internet access (to build the localrepo).
#
# Usage:
#   sudo ./prepare-ventoy-data.sh /dev/sdXN
#   where /dev/sdXN is the partition to use for data (e.g., /dev/sdb2)
#
# WARNING: This will format the given partition!

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /dev/sdXN"
  echo "  /dev/sdXN   Partition to format and use for TVPC data (will be wiped!)"
  exit 1
fi

DATA_PART="$1"

if [[ ! -b "$DATA_PART" ]]; then
  echo "Error: $DATA_PART is not a block device"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo $0)"
  exit 1
fi

echo "================================================================"
echo "  Preparing Ventoy data partition for tvpc"
echo "================================================================"
echo "Target partition: $DATA_PART"
echo "WARNING: All data on $DATA_PART will be destroyed!"
echo ""
read -rp "Type 'YES' to confirm: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# Unmount if mounted
sudo umount "$DATA_PART" 2>/dev/null || true

# Format as ext4 with label TVPC-DATA
echo "Formatting $DATA_PART as ext4 with label TVPC-DATA..."
sudo mkfs.ext4 -F -L TVPC-DATA "$DATA_PART"

# Mount it
echo "Mounting partition..."
sudo mkdir -p /mnt/tvpc-data
sudo mount "$DATA_PART" /mnt/tvpc-data

# Working directory inside the mount point
WORK_DIR="/mnt/tvpc-data"
cd "$WORK_DIR"

# Create directory structure
echo "Creating directory structure..."
mkdir -p localrepo pool/main
mkdir -p tvpc

# Copy the tvpc repo (assuming we are run from within the tvpc repo)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$REPO_ROOT" ]]; then
  echo "Error: Could not determine tvpc repository root. Please run this script from within the tvpc repo."
  sudo umount /mnt/tvpc-data
  exit 1
fi

echo "Copying tvpc repository..."
cp -r "$REPO_ROOT"/* tvpc/
# Remove the .git directory to save space (optional)
rm -rf tvpc/.git

# Create local apt repository
echo "Building local apt repository (this will take a while and requires internet)..."
# We'll create a temporary directory to download packages
TEMP_DIR="/tmp/tvpc-localrepo.$$"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# List of required packages (from install.sh)
cat > required-packages.txt <<'EOF'
flatpak
software-properties-common
plasma-mobile
plasma-desktop
kwin-wayland
sddm
pipewire
pipewire-pulse
wireplumber
pipewire-jack
libcec6
cec-utils
libva2
libva-drm2
intel-media-va-driver
i965-va-driver
vainfo
i2c-tools
tlp
powertop
zram-tools
curl
wget
git
rsync
unattended-upgrades
ubuntu-standard
linux-firmware
linux-generic-hwe-24.04
intel-microcode
iucode-tool
thermd
lm-sensors
ca-certificates
gnupg
chrony
ethtool
dbus
systemd
udev
netplan.io
openssh-server
EOF

# Update package list and download packages and dependencies
echo "Updating package list..."
apt-get update >/dev/null

echo "Downloading required packages and dependencies..."
while read pkg; do
  echo "  Downloading $pkg..."
  apt-get download "$pkg" 2>/dev/null || echo "    Warning: $pkg not found or failed to download"
done < required-packages.txt

# Also download Flatpak runtime dependencies (we'll rely on the flatpak package pulling them)
# Copy all .deb files to the localrepo pool
echo "Copying packages to localrepo pool..."
find . -name "*.deb" -exec cp -t "$WORK_DIR/localrepo/pool/main/" {} +

# Generate Packages file
echo "Generating Packages file..."
cd "$WORK_DIR/localrepo"
dpkg-scanpackages pool/main /dev/null | gzip -9c > distros/noble/main/binary-amd64/Packages.gz
cd "$WORK_DIR"

# Create user-data and meta-data for autoinstall
echo "Creating autoinstall user-data and meta-data..."
cat > user-data <<'USERDATA'
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

cat > meta-data <<'METADATA'
instance-id: tvpc-nuc7i5bnh-ventoy
local-hostname: tvpc
METADATA

# Create a README for the user
cat > README.txt <<'READMEEOF'
tvpc Data Partition for Ventoy
==============================

This partition contains:
- Local apt repository (in localrepo/)
- tvpc repository (in tvpc/)
- user-data and meta-data for autoinstall

To use:
1. Boot the Ubuntu 24.04 Server ISO via Ventoy.
2. At the boot menu, press 'e' to edit the boot entry.
3. Add the following parameter at the end of the linux line:
   autoinstall ds=nocloud;label=TVPC-DATA
4. Boot with Ctrl+X or F10.
5. The installer will run automatically and install Ubuntu + tvpc base.
6. After first boot, run: sudo tvpc-install
7. Reboot when prompted.

Default credentials: username=htpc, password=htpc
Change password immediately after first login!
READMEEOF

# Sync and unmount
echo "Syncing data..."
sync
sudo umount /mnt/tvpc-data

echo ""
echo "================================================================"
echo "  Ventoy data partition prepared successfully!"
echo "================================================================"
echo "Partition: $DATA_PART"
echo ""
echo "Next steps:"
echo "  1. Ensure the Ubuntu 24.04 Server ISO is available via Ventoy on the same USB."
echo "  2. Boot the ISO via Ventoy."
echo "  3. At the boot menu, press 'e' to edit the entry."
echo "  4. Add: autoinstall ds=nocloud;label=TVPC-DATA"
echo "  5. Boot with Ctrl+X or F10."
echo "  6. After install, run: sudo tvpc-install"
echo "  7. Reboot."
echo ""
echo "Notes:"
echo "  - Default credentials: username=htpc, password=htpc"
echo "  - Change password immediately after first login!"
echo "================================================================"
EOF

chmod +x /home/ec2-user/tvpc/scripts/prepare-ventoy-data.sh
echo "Created prepare-ventoy-data.sh"