#!/usr/bin/env bash
# install.sh — Unified HTPC installer and updater for Ubuntu 24.04
# Target: Intel NUC7i5BNH (Core i5-7260U "Kaby Lake", Iris Plus 640)
#         + 2013 Samsung ~80" TV over HDMI
# Repo: https://github.com/dontneedtogotit/tvpc
#
# Usage:
#   sudo ./install.sh                     Full system installation / setup
#   sudo ./install.sh --update            Converge system state + update packages
#   sudo ./install.sh --no-packages       Converge system state only (no apt/flatpak)
#   ./install.sh --check                  Report convergence state (read-only)
#   ./install.sh --list                   List convergence items and exit
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
MODE="install"
DO_PACKAGES=1
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update|-u)       MODE="update" ;;
    --check)           MODE="check" ;;
    --no-packages)     MODE="update"; DO_PACKAGES=0 ;;
    --list)            MODE="list" ;;
    --install)         MODE="install" ;;
    --customize)       MODE="customize" ;;
    --make-usb)        MODE="make-usb"; shift; EXTRA_ARGS+=("${1:-}") ;;
    --cached-iso)      EXTRA_ARGS+=("--cached-iso") ;;
    --prepare-ventoy)  MODE="prepare-ventoy"; shift; EXTRA_ARGS+=("${1:-}") ;;
    -h|--help|help)
      cat <<'EOF'
install.sh — Unified HTPC installer and updater for Ubuntu 24.04
Target: Intel NUC7i5BNH (Core i5-7260U "Kaby Lake", Iris Plus 640)
        + 2013 Samsung ~80" TV over HDMI
Repo: https://github.com/dontneedtogotit/tvpc

Usage:
  sudo ./install.sh                     Full system installation / setup
  sudo ./install.sh --update            Converge system state + update packages
  sudo ./install.sh --no-packages       Converge system state only (no apt/flatpak)
  ./install.sh --check                  Report convergence state (read-only)
  ./install.sh --list                   List convergence items and exit
  sudo ./install.sh --customize         Apply couch UI & theme tweaks
  sudo ./install.sh --make-usb /dev/sdX [--cached-iso]  Create offline USB installer
  sudo ./install.sh --prepare-ventoy /dev/sdXN          Prepare Ventoy data partition
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 1
      ;;
  esac
  shift
done

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-htpc}"

# ---------------------------------------------------------------------------
# Helper lists & State Items
# ---------------------------------------------------------------------------
MASTER_SCRIPT="scripts/tvpc.sh"
MASTER_BIN="/usr/local/bin/tvpc"

SYMLINKS=(
  tvpc-cec
  cec-tv-poweron.sh
  tvpc-cec-setup
  tvpc-hdmi-audio
  tvpc-doctor
  tvpc-repair
  tvpc-session
  tvpc-bigscreen
  tvpc-bigscreen-theme
  tvpc-hyprland
  tvpc-hypr-menu
  tvpc-hypr-autostart
  tvpc-controller
  tvpc-status
  tvpc-tweaks
  tvpc-cameras
  tvpc-cameras-gui
  tvpc-cameras-tile
  tvpc-power
  tvpc-allapps
  tvpc-setup-gui
  tvpc-update-gui
  tvpc-vacuumtube-scroll
  tvpc-update
)

PKG_DIR="tvpc_cameras_gui"
PKG_DST="/usr/local/lib/python3/dist-packages/tvpc_cameras_gui"

BAD_FILES=(
  /etc/X11/xorg.conf.d/20-intel.conf
  /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf
  /etc/pipewire/pipewire-pulse.d/99-htpc.conf
  /etc/systemd/system/htpc-audio.service
  /etc/sddm.conf.d/autologin.conf
  /etc/systemd/system/flatpak-user-update.timer
  /etc/systemd/system/flatpak-user-update.service
)

ITEMS=(
  "config|0|/etc/default/tvpc exists"
  "user|0|user '$HTPC_USER' exists, is in the right groups and can log in"
  "badfiles|0|configuration known to break the display is absent"
  "helpers|1|helper programs in /usr/local/bin match the repo"
  "cameras_gui|1|tvpc_cameras_gui Python package matches the repo"
  "overlays|1|files under overlays/ are applied to /"
  "kernel_cmdline|0|kernel command line has no splash or Broadwell-era flags"
  "graphical_target|0|default systemd target is graphical.target"
  "sddm|0|sddm is installed and enabled"
  "autologin|0|autologin points at a session that exists"
  "audio_unit|0|tvpc-audio user service is enabled"
  "cec_poweron|0|htpc-startup (TV power-on) is enabled"
  "cec_remote|0|CEC remote listener and ydotoold are enabled"
  "zram|0|zram swap is enabled"
  "tlp|0|TLP is enabled"
  "flatpak_timer|0|weekly flatpak update timer is enabled"
  "flathub|0|flathub remote is configured"
  "vacuumtube|0|VacuumTube is installed"
  "user_config|0|the TV user's Plasma config is seeded"
  "bigscreen|0|Plasma Bigscreen is installed with its session files"
  "curate_home|0|Bigscreen homescreen is curated to the 6 core apps"
  "hypr|1|Hyprland session files match the repo"
)

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Customize (UI & TV couch tweaks)
# ---------------------------------------------------------------------------
do_customize() {
# customize.sh — idempotent UI tweaks for couch use. Safe to re-run.
#   sudo ./scripts/customize.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
echo ">> tvpc customize using repo root: $REPO_ROOT (user: $HTPC_USER)"

SKEL=/etc/skel
mkdir -p "$SKEL/.config" "$SKEL/.config/autostart"

# --- Theme and 10-foot type -------------------------------------------------
# Scaling is applied at runtime by `tvpc-tweaks setup` (TVPC_SCALE); larger
# fonts are set here because they work regardless of scale and cannot take the
# display down if they are wrong.
# The base font size is the master UI scale for anything Kirigami-based:
# Kirigami.Units.gridUnit is derived from font metrics, so every margin and
# tile in the shell scales with it. 13 suits plain Plasma on a TV. Plasma
# Bigscreen is ALREADY a 10-foot UI sized around the 10pt default, so 13
# there scales it twice and the interface does not fit the screen — set
# TVPC_FONT_SIZE=10 (tvpc-bigscreen --ui-scale 10 does it for you).
#
# Auto-detect: if the active session is Bigscreen, use 10 regardless of
# TVPC_FONT_SIZE, because 13 breaks Bigscreen's layout.
ACTIVE_SESSION=""
[[ -r /etc/sddm.conf.d/10-tvpc.conf ]] && ACTIVE_SESSION="$(awk -F= '/^Session=/{print $2; exit}' /etc/sddm.conf.d/10-tvpc.conf 2>/dev/null)"
IS_BIGSCREEN=0
[[ $ACTIVE_SESSION == plasma-bigscreen* ]] && IS_BIGSCREEN=1
if [[ $IS_BIGSCREEN -eq 1 ]]; then
    FONT_SIZE="${TVPC_FONT_SIZE:-10}"
else
    FONT_SIZE="${TVPC_FONT_SIZE:-13}"
fi
cat >"$SKEL/.config/kdeglobals" <<EOF
[General]
ColorScheme=BreezeDark
Name=Breeze Dark
widgetStyle=Breeze
font=Noto Sans,$FONT_SIZE,-1,5,50,0,0,0,0,0
fixed=Noto Sans Mono,$((FONT_SIZE - 1)),-1,5,50,0,0,0,0,0
menuFont=Noto Sans,$FONT_SIZE,-1,5,50,0,0,0,0,0
smallestReadableFont=Noto Sans,$((FONT_SIZE - 2)),-1,5,50,0,0,0,0,0
toolBarFont=Noto Sans,$((FONT_SIZE - 1)),-1,5,50,0,0,0,0,0

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
EOF

# --- No lock screen on a TV -------------------------------------------------
cat >"$SKEL/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockGrace=0
LockOnResume=false
EOF

# --- Never blank or suspend -------------------------------------------------
# Without this the TV goes black after ~5 minutes idle, which looks exactly
# like the boot failure this build was suffering from. Large idle times rather
# than 0: powerdevil treats 0 as "immediately" for some actions.
cat >"$SKEL/.config/powermanagementprofilesrc" <<'EOF'
[AC][DPMSControl]
idleTime=86400
lockBeforeTurnOff=0

[AC][DimDisplay]
idleTime=86400

[AC][SuspendSession]
idleTime=86400
suspendType=0

[AC][HandleButtonEvents]
lidAction=0
powerButtonAction=1
EOF

# --- Turn off the desktop search stack --------------------------------------
cat >"$SKEL/.config/baloorc" <<'EOF'
[Basic Settings]
Indexing-Enabled=false
EOF
cat >"$SKEL/.config/krunnerrc" <<'EOF'
[General]
FreeFloating=false
EOF

# --- KWin: Alt+Tab switcher & window decorations with Close 'X' button -------
cat >"$SKEL/.config/kwinrc" <<'EOF'
[Windows]
BorderlessMaximizedWindows=false

[org.kde.kdecoration2]
BorderSize=Normal
ButtonsOnLeft=
ButtonsOnRight=X
CloseOnDoubleClickOnMenu=false
library=org.kde.breeze
theme=Breeze

[TabBox]
ActivitiesMode=1
ApplicationsMode=0
DesktopMode=0
HighlightWindows=true
LayoutName=thumbnail_grid
MultiScreenMode=0
OrderMinimizedMode=0
ShowDelay=false
ShowDesktop=true
SwitchingMode=0
EOF

# --- Shortcuts: Alt+Tab app switcher and Alt+F4 / window close --------------
cat >"$SKEL/.config/kglobalshortcutsrc" <<'EOF'
[kwin]
Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows
Walk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)
Walk Through Windows Alternative=none,,Walk Through Windows Alternative
Walk Through Windows Alternative (Reverse)=none,,Walk Through Windows Alternative (Reverse)
Window Close=Alt+F4,Alt+F4,Close Window
Show Desktop=Meta+D,Meta+D,Show Desktop
EOF

# --- KWin rules -------------------------------------------------------------
# The old rule tried to set the screen resolution here. KWin rules apply to
# windows, not outputs, so it could never have worked; the display mode is
# handled by `tvpc-tweaks setup` via kscreen-doctor. What is left is a real
# window rule: start VacuumTube fullscreen.
cat >"$SKEL/.config/kwinrulesrc" <<'EOF'
[General]
count=1
rules=tvpc-vacuumtube

[tvpc-vacuumtube]
Description=VacuumTube starts borderless maximized below top bar
wmclass=vacuumtube
wmclassmatch=2
wmclasscomplete=false
noborder=true
noborderrule=3
maximizehoriz=true
maximizehorizrule=3
maximizevert=true
maximizevertrule=3
fullscreen=false
fullscreenrule=3
EOF

# --- Autostart --------------------------------------------------------------
cat >"$SKEL/.config/autostart/tvpc-display-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=tvpc display setup
Comment=Apply TV scale/mode from /etc/default/tvpc
Exec=/usr/local/bin/tvpc-tweaks setup
X-KDE-autostart-phase=1
NoDisplay=true
EOF

cat >"$SKEL/.config/autostart/vacuumtube.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=VacuumTube
Comment=YouTube client with hardware video decode
Exec=flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --ozone-platform-hint=auto
X-KDE-autostart-phase=2
EOF

# --- Seed the live user, not just future ones -------------------------------
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6 || true)"
if [[ -n ${HOME_DIR:-} && -d $HOME_DIR ]]; then
  while IFS= read -r rel; do
    mkdir -p "$HOME_DIR/$(dirname "$rel")"
    cp "$SKEL/$rel" "$HOME_DIR/$rel"
  done < <(cd "$SKEL" && find .config -type f -printf '%p\n')
  chown -R "$HTPC_USER:$HTPC_USER" "$HOME_DIR/.config" 2>/dev/null || true
  [[ -d "$HOME_DIR/.local" ]] && chown -R "$HTPC_USER:$HTPC_USER" "$HOME_DIR/.local" 2>/dev/null || true
  echo "Seeded $HOME_DIR with tvpc config"
else
  echo "Home dir for $HTPC_USER not found; skel-only (applies on next user creation)"
fi

# Remove settings written by older versions of this script that pointed at
# keys Plasma does not read.
if [[ -n ${HOME_DIR:-} && -d $HOME_DIR ]]; then
  rm -f "$HOME_DIR/.config/plasma-desktop-appletsrc.tvpc-bak"
  if grep -q '^\[Screen Scales\]' "$HOME_DIR/.config/plasma-desktop-appletsrc" 2>/dev/null; then
    mv "$HOME_DIR/.config/plasma-desktop-appletsrc" \
       "$HOME_DIR/.config/plasma-desktop-appletsrc.tvpc-bak"
    echo "Moved aside a plasma-desktop-appletsrc containing the bogus [Screen Scales] block"
  fi
  rm -rf "$HOME_DIR/.local/share/plasma-mobile/favorites"
fi
rm -f "$SKEL/.config/plasma-desktop-appletsrc"
rm -rf "$SKEL/.local/share/plasma-mobile"

# --- Overlays ---------------------------------------------------------------
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

echo ">> customize done. Log out and back in to see the changes."
}

# ---------------------------------------------------------------------------
# Offline Media Creator (USB)
# ---------------------------------------------------------------------------
do_make_offline_usb() {
  set -- "${EXTRA_ARGS[@]}"
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
sudo tee /mnt/usb/README-OFFLINE.txt > /dev/null <<'READMEEOF'
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
}

# ---------------------------------------------------------------------------
# Ventoy Partition Preparer
# ---------------------------------------------------------------------------
do_prepare_ventoy() {
  set -- "${EXTRA_ARGS[@]}"
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
sddm
sddm-theme-breeze
plasma-workspace
plasma-workspace-wayland
plasma-desktop
kwin-wayland
plasma-nm
plasma-pa
powerdevil
kscreen
systemsettings
kde-cli-tools
breeze
breeze-icon-theme
qtwayland5
xwayland
xserver-xorg-core
xserver-xorg-input-libinput
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
pulseaudio-utils
libcec6
cec-utils
libva2
libva-drm2
intel-media-va-driver
i965-va-driver
mesa-va-drivers
vainfo
playerctl
ydotool
ydotoold
flatpak
software-properties-common
openssh-server
network-manager
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
}

if [[ "$MODE" == "customize" ]]; then
  do_customize
  exit 0
elif [[ "$MODE" == "make-usb" ]]; then
  do_make_offline_usb
  exit 0
elif [[ "$MODE" == "prepare-ventoy" ]]; then
  do_prepare_ventoy
  exit 0
fi

# Mode: List
# ---------------------------------------------------------------------------
if [[ $MODE == "list" ]]; then
  printf '%-18s %-10s %s
' ITEM NEEDS-REPO DESCRIPTION
  for entry in "${ITEMS[@]}"; do
    IFS='|' read -r id repo desc <<<"$entry"
    printf '%-18s %-10s %s
' "$id" "$([[ $repo == 1 ]] && echo yes || echo no)" "$desc"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Convergence checks and fixes
# ---------------------------------------------------------------------------
check_config() { [[ -f /etc/default/tvpc ]]; }
fix_config() {
  grep -q 'TVPC_SESSION' /etc/default/tvpc 2>/dev/null && return 0
  cat >/etc/default/tvpc <<'EOF'
TVPC_USER=htpc
TVPC_SESSION=auto
TVPC_SCALE=1.5
TVPC_MODE=
TVPC_INSTALL_PLASMA_MOBILE=0
TVPC_WIRED_ONLY=0
EOF
}

check_user() {
  id "$HTPC_USER" >/dev/null 2>&1 || return 1
  local g
  for g in video render audio input; do
    id -nG "$HTPC_USER" | grep -w "$g" >/dev/null || return 1
  done
  [[ "$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)" != 0 ]]
}
fix_user() {
  id "$HTPC_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$HTPC_USER" || return 1
  usermod -aG video,render,audio,plugdev,input "$HTPC_USER"
}

check_badfiles() {
  local f
  for f in "${BAD_FILES[@]}"; do [[ -e $f ]] && return 1; done
  return 0
}
fix_badfiles() {
  systemctl disable --now htpc-audio.service flatpak-user-update.timer 2>/dev/null || true
  rm -f "${BAD_FILES[@]}"
  rm -rf /etc/systemd/system/flatpak-user-update.timer.d
  systemctl daemon-reload
}

check_helpers() {
  local src="$REPO_ROOT/$MASTER_SCRIPT" dst="$MASTER_BIN"
  [[ -f $src ]] || return 1
  cmp -s "$src" "$dst" || return 1
  local sym
  for sym in "${SYMLINKS[@]}"; do
    [[ -L "/usr/local/bin/$sym" ]] || return 1
  done
}
fix_helpers() {
  install -D -m 0755 "$REPO_ROOT/$MASTER_SCRIPT" "$MASTER_BIN"
  local sym
  for sym in "${SYMLINKS[@]}"; do
    ln -sf tvpc "/usr/local/bin/$sym"
  done
}

check_cameras_gui() {
  [[ -d "$REPO_ROOT/$PKG_DIR" ]] || return 0
  [[ -d "$PKG_DST" ]] || return 1
  local f
  while IFS= read -r f; do
    cmp -s "$REPO_ROOT/$f" "$PKG_DST/${f#"$PKG_DIR/"}" || return 1
  done < <(find "$REPO_ROOT/$PKG_DIR" -type f -name "*.py")
  return 0
}
fix_cameras_gui() {
  [[ -d "$REPO_ROOT/$PKG_DIR" ]] || return 0
  install -d "$PKG_DST"
  cp -r "$REPO_ROOT/$PKG_DIR"/. "$PKG_DST"/
  find "$PKG_DST" -type f -name "*.py" -exec chmod 0644 {} +
}

when_bigscreen() { [[ "${TVPC_SESSION:-}" == bigscreen || "${TVPC_SESSION:-}" == bigscreen-x11 ]]; }
check_bigscreen() {
  dpkg-query -W -f='${Status}' plasma-bigscreen 2>/dev/null     | grep "^install ok installed$" >/dev/null || return 1
  [[ -f /usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop ]] || return 1
  [[ -f /usr/share/xsessions/plasma-bigscreen-x11.desktop ]] || return 1
}
fix_bigscreen() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y plasma-bigscreen
}

check_curate_home() {
  local home rc
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || return 1
  rc="$home/.config/applications-blacklistrc"
  [[ -f "$rc" ]] || return 1
  grep -q '^\[General\]' "$rc" || return 1
  grep -q '^blacklist=' "$rc" || return 1
  [[ -f /usr/share/applications/tvpc-setup.desktop ]] || return 1
  [[ -f /usr/share/applications/tvpc-cameras-gui.desktop ]] || return 1
  [[ -f /usr/share/applications/tvpc-update.desktop ]] || return 1
  [[ -f /usr/share/applications/tvpc-allapps.desktop ]] || return 1
}
fix_curate_home() {
  "$REPO_ROOT/scripts/tvpc.sh" tweaks curate
}


HYPR_CONFIGS=(
  "config/hypr/hyprland.lua:.config/hypr/hyprland.lua"
  "config/hypr/waybar/config.jsonc:.config/waybar/config.jsonc"
  "config/hypr/waybar/style.css:.config/waybar/style.css"
  "config/hypr/fuzzel.ini:.config/fuzzel/fuzzel.ini"
)
when_hypr() { [[ "${TVPC_SESSION:-}" == "hypr" ]]; }
check_hypr() {
  command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1 || return 1
  [[ -f /usr/share/wayland-sessions/tvpc-hypr.desktop ]] || return 1
  [[ -x /usr/local/bin/tvpc-hypr-session   ]] || return 1
  [[ -x /usr/local/bin/tvpc-hypr-menu      ]] || return 1
  [[ -x /usr/local/bin/tvpc-hypr-autostart ]] || return 1
  local home pair
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  [[ -n $home ]] || return 1
  for pair in "${HYPR_CONFIGS[@]}"; do
    cmp -s "$REPO_ROOT/${pair%%:*}" "$home/${pair##*:}" || return 1
  done
}
fix_hypr() {
  command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1 || {
    echo "Hyprland is not installed. Run: sudo ./scripts/tvpc-hyprland.sh" >&2
    return 1
  }
  local home pair src dst
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  for pair in "${HYPR_CONFIGS[@]}"; do
    src="$REPO_ROOT/${pair%%:*}"; dst="$home/${pair##*:}"
    if [[ -f $src ]]; then
      mkdir -p "$(dirname "$dst")"
      install -m 0644 "$src" "$dst"
      chown "$HTPC_USER:$HTPC_USER" "$dst"
    fi
  done
}

check_overlays() {
  [[ -d "$REPO_ROOT/overlays" ]] || return 0
  local f rel
  while IFS= read -r f; do
    rel="${f#"$REPO_ROOT/overlays/"}"
    [[ -e "/$rel" ]] || return 1
    cmp -s "$f" "/$rel" || return 1
  done < <(find "$REPO_ROOT/overlays" -type f)
  return 0
}
fix_overlays() {
  [[ -d "$REPO_ROOT/overlays" ]] || return 0
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
}

check_kernel_cmdline() {
  ! grep -q 'i915\.enable_guc\|intel_iommu=igfx_off\|splash' /etc/default/grub 2>/dev/null
}
fix_kernel_cmdline() {
  sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g'          -e 's/ *intel_iommu=igfx_off//g'          -e 's/ *splash//g' /etc/default/grub
  update-grub
}

check_graphical_target() { [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]]; }
fix_graphical_target() { systemctl set-default graphical.target; }

check_sddm() {
  command -v sddm >/dev/null 2>&1 || return 1
  systemctl is-enabled sddm >/dev/null 2>&1
}
fix_sddm() {
  dpkg-query -W -f='${Status}' sddm 2>/dev/null | grep "^install ok installed$" >/dev/null || {
    DEBIAN_FRONTEND=noninteractive apt-get install -y sddm sddm-theme-breeze
  }
  systemctl enable sddm
}

check_autologin() {
  [[ -f /etc/sddm.conf.d/10-tvpc.conf ]] || return 1
  local s
  s="$(awk -F= '/^Session=/{print $2}' /etc/sddm.conf.d/10-tvpc.conf 2>/dev/null || true)"
  [[ -n $s ]] || return 1
  local d
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions            /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$s" || -f "$d/$s.desktop" ]] && return 0
  done
  return 1
}
fix_autologin() {
  "$REPO_ROOT/scripts/tvpc.sh" session "${TVPC_SESSION:-auto}"
}

check_audio_unit() {
  systemctl --global is-enabled tvpc-audio.service >/dev/null 2>&1
}
fix_audio_unit() {
  systemctl --global enable tvpc-audio.service 2>/dev/null || true
}

check_cec_poweron() {
  systemctl is-enabled htpc-startup.service >/dev/null 2>&1
}
fix_cec_poweron() {
  systemctl enable htpc-startup.service
}

check_cec_remote() {
  systemctl is-enabled ydotoold.service >/dev/null 2>&1 || return 1
  systemctl is-enabled tvpc-cec-remote.service >/dev/null 2>&1
}
fix_cec_remote() {
  "$REPO_ROOT/scripts/tvpc.sh" cec setup >/dev/null 2>&1
}

check_zram() { systemctl is-enabled zramswap >/dev/null 2>&1; }
fix_zram() {
  dpkg-query -W -f='${Status}' zram-tools 2>/dev/null | grep "^install ok installed$" >/dev/null || {
    DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools
  }
  cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  systemctl enable --now zramswap 2>/dev/null || true
}

check_tlp() { systemctl is-enabled tlp.service >/dev/null 2>&1; }
fix_tlp() { systemctl enable --now tlp.service 2>/dev/null || true; }

check_flatpak_timer() { systemctl is-enabled flatpak-update.timer >/dev/null 2>&1; }
fix_flatpak_timer() {
  cat >/etc/systemd/system/flatpak-update.service <<'EOF'
[Unit]
Description=Update Flatpak applications
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --noninteractive --assumeyes
EOF
  cat >/etc/systemd/system/flatpak-update.timer <<'EOF'
[Unit]
Description=Weekly Flatpak update

[Timer]
OnCalendar=Sun 04:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now flatpak-update.timer
}

check_flathub() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak remotes 2>/dev/null | grep -q '^flathub'
}
fix_flathub() {
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

check_vacuumtube() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak info io.github.vacuumtube.VacuumTube >/dev/null 2>&1
}
fix_vacuumtube() {
  flatpak install -y flathub io.github.vacuumtube.VacuumTube
}

check_user_config() {
  local home
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  [[ -n $home && -d $home ]] || return 1
  for f in kdeglobals kscreenlockerrc powermanagementprofilesrc baloorc; do
    [[ -f "$home/.config/$f" ]] || return 1
  done
}
fix_user_config() {
  do_customize >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Mode: Check / Update
# ---------------------------------------------------------------------------
if [[ $MODE == "check" || $MODE == "update" ]]; then
  if [[ $MODE == "update" && $EUID -ne 0 ]]; then
    echo "Run as root (sudo ./install.sh --update)" >&2
    exit 1
  fi

  echo "=== tvpc $( [[ $MODE == check ]] && echo "state check" || echo "update" ) ==="
  N_OK=0 N_FIXED=0 N_FAILED=0 N_SKIPPED=0

  for entry in "${ITEMS[@]}"; do
    IFS='|' read -r id repo desc <<<"$entry"
    if declare -F "when_$id" >/dev/null; then
      if ! "when_$id"; then
        printf '  %-6s %-16s %s
' "SKIP" "$id" "$desc"
        N_SKIPPED=$((N_SKIPPED + 1))
        continue
      fi
    fi

    if "check_$id"; then
      printf '  %-6s %-16s %s
' "OK" "$id" "$desc"
      N_OK=$((N_OK + 1))
    else
      if [[ $MODE == check ]]; then
        printf '  %-6s %-16s %s
' "MISS" "$id" "$desc"
        N_FAILED=$((N_FAILED + 1))
      else
        if declare -F "fix_$id" >/dev/null; then
          printf '  fixing %s... ' "$id"
          if "fix_$id" >/dev/null 2>&1 && "check_$id"; then
            echo "OK"
            N_FIXED=$((N_FIXED + 1))
          else
            echo "FAILED"
            N_FAILED=$((N_FAILED + 1))
          fi
        else
          printf '  %-6s %-16s %s (manual fix needed)
' "MISS" "$id" "$desc"
          N_FAILED=$((N_FAILED + 1))
        fi
      fi
    fi
  done

  if [[ $MODE == "update" && $DO_PACKAGES -eq 1 ]]; then
    echo
    echo "== Updating packages (apt & flatpak) =="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    if command -v flatpak >/dev/null 2>&1; then
      flatpak update --noninteractive --assumeyes || true
    fi
  fi

  echo
  printf 'Summary: %d OK, %d fixed, %d failed, %d skipped
' "$N_OK" "$N_FIXED" "$N_FAILED" "$N_SKIPPED"
  [[ $N_FAILED -eq 0 ]] && exit 0 || exit 1
fi

# ---------------------------------------------------------------------------
# Mode: Full Installation
# ---------------------------------------------------------------------------
LOG="/var/log/tvpc-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== tvpc installer started $(date) ==="

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo ./install.sh)"
  exit 1
fi

install -d /etc/tvpc
printf '%s
' "$REPO_ROOT" >/etc/tvpc/repo.path

# 1. Configuration
if [[ ! -f /etc/default/tvpc ]]; then
  cat >/etc/default/tvpc <<'EOF'
# tvpc appliance settings — sourced by the tvpc scripts.
TVPC_USER=htpc
TVPC_SESSION=auto
TVPC_SCALE=1.5
TVPC_MODE=
TVPC_INSTALL_PLASMA_MOBILE=0
TVPC_WIRED_ONLY=0
EOF
  echo "Wrote /etc/default/tvpc"
fi
# shellcheck source=/dev/null
. /etc/default/tvpc
HTPC_USER="${TVPC_USER:-htpc}"

# 2. Packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

apt_install() {
  local want=("$@") have=() missing=()
  local p
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then echo "!! not available, skipping: ${missing[*]}"; fi
  if [[ ${#have[@]} -gt 0 ]]; then apt-get install -y "${have[@]}"; fi
}

apt_install   sddm sddm-theme-breeze   plasma-workspace plasma-workspace-wayland plasma-desktop kwin-wayland   plasma-nm plasma-pa powerdevil kscreen systemsettings kde-cli-tools   breeze breeze-icon-theme qtwayland5   xwayland xserver-xorg-core xserver-xorg-input-libinput

apt_install pipewire pipewire-pulse pipewire-alsa wireplumber pulseaudio-utils

apt_install intel-media-va-driver i965-va-driver mesa-va-drivers   libva2 libva-drm2 vainfo

apt_install cec-utils libcec6 playerctl ydotool ydotoold

apt_install chromium-browser flatpak software-properties-common openssh-server network-manager   tlp powertop zram-tools i2c-tools unattended-upgrades   curl wget git rsync pavucontrol vim htop

apt_install python3-pyside6 python3-requests ffmpeg mpv

if [[ "${TVPC_INSTALL_PLASMA_MOBILE:-0}" == "1" || "${TVPC_SESSION:-auto}" == "plasma-mobile" ]]; then
  echo "== Installing Plasma Mobile (opt-in) =="
  apt_install plasma-mobile plasma-nano
fi

systemctl enable --now ssh 2>/dev/null || true

# 3. Clear known-bad configuration
echo "== Clearing known-bad configuration from previous installs =="
rm -f "${BAD_FILES[@]}"
systemctl daemon-reload

# 4. Flatpak + VacuumTube
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub io.github.vacuumtube.VacuumTube ||   echo "!! VacuumTube install failed (no network?) — rerun: flatpak install flathub io.github.vacuumtube.VacuumTube"

# 5. HTPC user
if ! id "$HTPC_USER" &>/dev/null; then
  useradd -m -G video,render,audio,plugdev,input -s /bin/bash "$HTPC_USER"
  echo "$HTPC_USER:htpc" | chpasswd
  echo "Created user $HTPC_USER (password: htpc — change it!)"
else
  usermod -aG video,render,audio,plugdev,input "$HTPC_USER"
fi

# 6. Overlays, then GRUB
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

if grep -q 'i915.enable_guc\|intel_iommu=igfx_off' /etc/default/grub 2>/dev/null; then
  sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' /etc/default/grub
  echo "Removed stale i915/IOMMU kernel parameters from /etc/default/grub"
fi
update-grub

# 7. Helper programs and Desktop files
for pair in "${HELPERS[@]}"; do
  src="$REPO_ROOT/${pair%%:*}"; dst="${pair##*:}"
  [[ -f $src ]] && install -D -m 0755 "$src" "$dst"
done

# Python GUI package
if [[ -d "$REPO_ROOT/tvpc_cameras_gui" ]]; then
  install -d /usr/lib/python3/dist-packages
  cp -r "$REPO_ROOT/tvpc_cameras_gui" /usr/lib/python3/dist-packages/
  find /usr/lib/python3/dist-packages/tvpc_cameras_gui -type f -name "*.py" -exec chmod 0644 {} +
  install -d /usr/local/lib/python3/dist-packages
  cp -r "$REPO_ROOT/tvpc_cameras_gui" /usr/local/lib/python3/dist-packages/
  find /usr/local/lib/python3/dist-packages/tvpc_cameras_gui -type f -name "*.py" -exec chmod 0644 {} +
fi

# Desktop tiles
cat >/usr/share/applications/tvpc-power.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Power
Comment=Restart, shut down, or log out
Exec=/usr/local/bin/tvpc power
Terminal=false
Icon=system-shutdown
Categories=Settings;
Keywords=tvpc;power;
EOF

cat >/usr/share/applications/tvpc-setup.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Settings
Comment=Configure display, audio, remote, CEC, and TV settings
Exec=/usr/local/bin/tvpc gui setup
Terminal=false
Icon=preferences-system
Categories=Settings;
Keywords=tvpc;setup;settings;cec;audio;
EOF

cat >/usr/share/applications/tvpc-cameras-gui.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Security Cameras
Comment=View live CCTV security camera streams and recordings
Exec=/usr/local/bin/tvpc cameras gui
Terminal=false
Icon=camera-web
Categories=AudioVideo;Video;
Keywords=tvpc;cameras;cctv;nvr;security;
EOF

cat >/usr/share/applications/tvpc-update.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Update System
Comment=Check for and apply updates from Git, apt, and Flatpak
Exec=/usr/local/bin/tvpc gui update
Terminal=false
Icon=system-software-update
Categories=System;
Keywords=tvpc;update;git;upgrade;
EOF

cat >/usr/share/applications/tvpc-allapps.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=All Applications
Comment=Browse every installed application
Exec=/usr/local/bin/tvpc gui allapps
Terminal=false
Icon=view-grid
Categories=Utility;
Keywords=tvpc;apps;
EOF

cat >/usr/share/applications/tvpc-addapps.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Add Apps
Comment=Choose apps to show on the home screen
Exec=/usr/local/bin/tvpc tweaks addapps
Terminal=false
Icon=list-add
Categories=Settings;
Keywords=tvpc;apps;home;add;
EOF

# Curate Bigscreen home screen to the core tiles (VacuumTube, Settings, Cameras, All Apps, Chromium, Update, Add Apps)
"$REPO_ROOT/scripts/tvpc.sh" tweaks curate 2>/dev/null || true


# 8. Hardware, Power, and Audio Extras
mkdir -p /etc/tlp.d
cat >/etc/tlp.d/99-tvpc.conf <<'EOF'
TLP_DEFAULT_MODE=AC
TLP_PERSISTENT_DEFAULT=1
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
SOUND_POWER_SAVE_ON_AC=0
EOF

if command -v nmcli >/dev/null 2>&1; then
  if [[ "${TVPC_WIRED_ONLY:-0}" == "1" ]]; then
    nmcli radio wifi off 2>/dev/null || true
  else
    nmcli radio wifi on 2>/dev/null || true
  fi
fi

mkdir -p /usr/local/bin
cat >/usr/local/bin/htpc-volume-step <<'EOF'
#!/usr/bin/env bash
pactl set-sink-volume @DEFAULT_SINK@ "${1:-+2}%"
EOF
chmod 0755 /usr/local/bin/htpc-volume-step

mkdir -p /var/lib/flatpak/overrides
cat >/var/lib/flatpak/overrides/global <<'EOF'
[Context]
devices=dri
sockets=wayland;fallback-x11;pulseaudio;
filesystems=xdg-videos:ro;xdg-music:ro;xdg-pictures:ro;
EOF

# 9. Session + autologin
"$REPO_ROOT/scripts/tvpc.sh" session "${TVPC_SESSION:-auto}"

# 10. Audio: HDMI selection inside the user session
systemctl --global enable tvpc-audio.service 2>/dev/null || true

# 11. CEC: power on the TV and setup remote listener
cat >/etc/systemd/system/htpc-startup.service <<'EOF'
[Unit]
Description=Power on Samsung TV via CEC and switch input
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cec-tv-poweron.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable htpc-startup.service

"$REPO_ROOT/scripts/tvpc.sh" cec setup || echo "!! CEC setup reported non-critical warning (continuing)"

# 12. Power, swap, indexers
systemctl enable tlp.service 2>/dev/null || true
powertop --auto-tune >/dev/null 2>&1 || true

cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable --now zramswap 2>/dev/null || true

for unit in tracker-miner-fs-3.service tracker-store.service; do
  systemctl disable --now "$unit" 2>/dev/null || true
  systemctl mask "$unit" 2>/dev/null || true
done

# 13. Maintenance
dpkg-reconfigure -f noninteractive unattended-upgrades || true
fix_flatpak_timer

# 14. UI Customization
do_customize || echo "!! customize reported an error (continuing)"

# 15. Verification
echo
echo "=== Pre-reboot verification ==="
PROBLEMS=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  OK    $1"; else echo "  FAIL  $1"; PROBLEMS=$((PROBLEMS+1)); fi; }

check "sddm installed"                 "command -v sddm"
check "sddm enabled"                   "systemctl is-enabled sddm"
check "default target is graphical"    "[[ \$(systemctl get-default) == graphical.target ]]"
check "autologin config written"       "[[ -f /etc/sddm.conf.d/10-tvpc.conf ]]"
check "user $HTPC_USER exists"         "id $HTPC_USER"
check "no stale Xorg intel config"     "[[ ! -f /etc/X11/xorg.conf.d/20-intel.conf ]]"

session_installed() {
  local name="$1" d
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions            /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$name" ]] && return 0
  done
  return 1
}

SESSION_NAME="$(awk -F= '/^Session=/{print $2}' /etc/sddm.conf.d/10-tvpc.conf 2>/dev/null || true)"
if [[ -n $SESSION_NAME ]] && session_installed "$SESSION_NAME"; then
  echo "  OK    session file present ($SESSION_NAME)"
else
  echo "  FAIL  session file missing ($SESSION_NAME)"
  PROBLEMS=$((PROBLEMS+1))
fi

echo
echo "=== tvpc installer finished $(date) ==="
if [[ $PROBLEMS -gt 0 ]]; then
  echo "$PROBLEMS check(s) failed — fix these before rebooting."
  exit 1
fi

echo "All checks passed. Reboot:  sudo reboot"
echo "Keep it in shape:         sudo ./install.sh --update"
