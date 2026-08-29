#!/usr/bin/env bash
set -euo pipefail

# install.sh — Android-like HTPC setup for Ubuntu 24.04 (server base)
# Target: Intel NUC7i5BNH (Core i5-7260U "Kaby Lake", Iris Plus 640)
#         + 2013 Samsung ~80" TV over HDMI
# Repo: https://github.com/dontneedtogotit/tvpc
#
# Safe to re-run. Re-running on a machine that boots to a black screen will
# repair it; see also scripts/tvpc-repair.sh for the fix-only path.

LOG="/var/log/tvpc-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== tvpc installer started $(date) ==="

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo ./install.sh)"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
# Single place to change the session, user and TV scaling. Created once and
# then left alone, so your edits survive a re-run.
if [[ ! -f /etc/default/tvpc ]]; then
  cat >/etc/default/tvpc <<'EOF'
# tvpc appliance settings — sourced by the tvpc scripts.

# Login user for the TV session.
TVPC_USER=htpc

# Graphical session: auto | plasma | plasma-mobile | plasma-x11 | kiosk
#   auto          first of the above that is actually installed
#   plasma        Plasma Wayland desktop (default, tested on this hardware)
#   plasma-mobile KDE's touchscreen shell — needs TVPC_INSTALL_PLASMA_MOBILE=1
#                 and is hard to drive from a TV remote
#   kiosk         kwin_wayland + one app, the "nothing else works" fallback
TVPC_SESSION=auto

# Plasma global scale for couch viewing. 1 disables scaling.
TVPC_SCALE=1.5

# Force a display mode, e.g. 1920x1080@60. Empty = trust the TV's EDID.
TVPC_MODE=

# Set to 1 to also install Plasma Mobile (large download, optional).
TVPC_INSTALL_PLASMA_MOBILE=0

# Set to 1 on wired-only installs to power down the Wi-Fi radio.
TVPC_WIRED_ONLY=0
EOF
  echo "Wrote /etc/default/tvpc"
fi
# shellcheck source=/dev/null
. /etc/default/tvpc
HTPC_USER="${TVPC_USER:-htpc}"

# ---------------------------------------------------------------------------
# 2. Packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install what is available and report what is not, rather than aborting the
# whole run — a half-configured appliance is worse than a noisy log.
apt_install() {
  local want=("$@") have=() missing=()
  local p
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then echo "!! not available, skipping: ${missing[*]}"; fi
  if [[ ${#have[@]} -gt 0 ]]; then apt-get install -y "${have[@]}"; fi
}

# Display stack. plasma-workspace-wayland is what provides
# /usr/share/wayland-sessions/plasmawayland.desktop — without it there is no
# Wayland session to log in to at all.
apt_install \
  sddm sddm-theme-breeze \
  plasma-workspace plasma-workspace-wayland plasma-desktop kwin-wayland \
  plasma-nm plasma-pa powerdevil kscreen systemsettings kde-cli-tools \
  breeze breeze-icon-theme qtwayland5 \
  xwayland xserver-xorg-core xserver-xorg-input-libinput

# Audio (PipeWire; pulseaudio-utils supplies pactl)
apt_install pipewire pipewire-pulse pipewire-alsa wireplumber pulseaudio-utils

# Video decode. iHD is the right VA-API driver for Kaby Lake; i965 stays as a
# fallback. No GuC/HuC kernel flags are needed for decode on gen9.
apt_install intel-media-va-driver i965-va-driver mesa-va-drivers \
  libva2 libva-drm2 vainfo

# CEC + remote control. ydotoold is a SEPARATE package on Ubuntu: the ydotool
# package ships only the client, and the client is useless without the daemon.
apt_install cec-utils libcec6 playerctl ydotool ydotoold

# System
apt_install flatpak software-properties-common openssh-server network-manager \
  tlp powertop zram-tools i2c-tools unattended-upgrades \
  curl wget git rsync

# Plasma Mobile is opt-in: it is a touchscreen shell, it pulls in an on-screen
# keyboard, and on Ubuntu 24.04 its shell failing to start is the classic cause
# of a black screen with a cursor.
if [[ "${TVPC_INSTALL_PLASMA_MOBILE:-0}" == "1" || "${TVPC_SESSION:-auto}" == "plasma-mobile" ]]; then
  echo "== Installing Plasma Mobile (opt-in) =="
  apt_install plasma-mobile plasma-nano
fi

systemctl enable --now ssh 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Remove configuration that is known to break the display
# ---------------------------------------------------------------------------
# Earlier versions of this repo shipped these. They are the reason an install
# could come up as a black screen, so clear them out before anything else.
echo "== Clearing known-bad configuration from previous installs =="

# Xorg was told to use Driver "intel" (xserver-xorg-video-intel). That driver
# is not installed on Ubuntu 24.04 and is not even part of
# xserver-xorg-video-all any more, so Xorg exited with "no screens found" and
# SDDM had nothing to display. modesetting handles Kaby Lake correctly with no
# configuration at all.
rm -f /etc/X11/xorg.conf.d/20-intel.conf /etc/X11/xorg.conf

# This asked PipeWire to load a module that does not exist
# (libpipewire-module-alsa-sink), which stopped PipeWire from starting.
rm -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf
rm -f /etc/pipewire/pipewire-pulse.d/99-htpc.conf

# Ran pactl as root from a system unit, where there is no PipeWire to talk to.
if systemctl list-unit-files htpc-audio.service >/dev/null 2>&1; then
  systemctl disable --now htpc-audio.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/htpc-audio.service

# Superseded by /etc/sddm.conf.d/10-tvpc.conf, written only after the session
# file has been confirmed to exist.
rm -f /etc/sddm.conf.d/autologin.conf

systemctl daemon-reload

# ---------------------------------------------------------------------------
# 4. Flatpak + VacuumTube
# ---------------------------------------------------------------------------
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub io.github.vacuumtube.VacuumTube || \
  echo "!! VacuumTube install failed (no network?) — rerun: flatpak install flathub io.github.vacuumtube.VacuumTube"

# Optional media apps:
# flatpak install -y flathub com.github.iwalton3.jellyfin-media-player
# flatpak install -y flathub tv.plex.PlexHTPC

# ---------------------------------------------------------------------------
# 5. HTPC user
# ---------------------------------------------------------------------------
if ! id "$HTPC_USER" &>/dev/null; then
  useradd -m -G video,render,audio,plugdev,input -s /bin/bash "$HTPC_USER"
  echo "$HTPC_USER:htpc" | chpasswd
  echo "Created user $HTPC_USER (password: htpc — change it!)"
else
  usermod -aG video,render,audio,plugdev,input "$HTPC_USER"
fi

# ---------------------------------------------------------------------------
# 6. Overlays, then GRUB
# ---------------------------------------------------------------------------
# Overlays first: they contain /etc/default/grub.d/tvpc.cfg, so running
# update-grub before this (as the old script did) meant the kernel command line
# never actually changed.
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

# Strip the old parameters from any /etc/default/grub edited by a previous run.
if grep -q 'i915.enable_guc\|intel_iommu=igfx_off' /etc/default/grub 2>/dev/null; then
  sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' /etc/default/grub
  echo "Removed stale i915/IOMMU kernel parameters from /etc/default/grub"
fi
update-grub

# ---------------------------------------------------------------------------
# 7. Helper programs
# ---------------------------------------------------------------------------
install -m 0755 "$REPO_ROOT/scripts/cec-tv-poweron.sh"     /usr/local/bin/cec-tv-poweron.sh
install -m 0755 "$REPO_ROOT/scripts/tvpc-hdmi-audio.sh"    /usr/local/bin/tvpc-hdmi-audio
install -m 0755 "$REPO_ROOT/scripts/tvpc-doctor.sh"        /usr/local/bin/tvpc-doctor
install -m 0755 "$REPO_ROOT/scripts/tvpc-repair.sh"        /usr/local/bin/tvpc-repair
install -m 0755 "$REPO_ROOT/scripts/tvpc-session.sh"       /usr/local/bin/tvpc-session
install -m 0755 "$REPO_ROOT/scripts/tvpc-update.sh"        /usr/local/bin/tvpc-update
# The alternative TV shells are opt-in: install.sh only puts their
# installers on the box. Running one is a separate, deliberate step.
# Bigscreen is archive-native; Hyprland pulls from a PPA.
install -m 0755 "$REPO_ROOT/scripts/tvpc-bigscreen.sh"     /usr/local/bin/tvpc-bigscreen
install -m 0755 "$REPO_ROOT/scripts/tvpc-hyprland.sh"      /usr/local/bin/tvpc-hyprland
install -m 0755 "$REPO_ROOT/scripts/tvpc-tweaks.sh"        /usr/local/bin/tvpc-tweaks
install -m 0755 "$REPO_ROOT/scripts/tvpc-power.sh"          /usr/local/bin/tvpc-power
install -m 0755 "$REPO_ROOT/scripts/tvpc-allapps.sh"         /usr/local/bin/tvpc-allapps
# The All Apps launcher: every installed app in one browseable list (used when the
# home screen is curated down to a single tile).
cat >/usr/share/applications/tvpc-allapps.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=All Apps
Comment=Browse every installed application
Exec=/usr/local/bin/tvpc-allapps
Terminal=false
Icon=view-grid
Categories=Settings;
Keywords=tvpc;apps;
EOF
# The Power tile for the home screen: restart / shut down / log out.
cat >/usr/share/applications/tvpc-power.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Power
Comment=Restart, shut down, or log out
Exec=/usr/local/bin/tvpc-power
Terminal=false
Icon=system-shutdown
Categories=Settings;
Keywords=tvpc;power;
EOF
# The Tweaks app launcher (UI scaling, home-screen apps, etc.) — appears on the
# home screen / launcher so it can be opened with the remote.
mkdir -p /usr/share/applications
cat >/usr/share/applications/tvpc-tweaks.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=TV Tweaks
GenericName=tvpc adjustments
Comment=UI scaling, home-screen apps, and other tvpc tweaks
Exec=/usr/local/bin/tvpc-tweaks
Terminal=true
Icon=preferences-system
Categories=Settings;
Keywords=tvpc;tweaks;scaling;home screen;
EOF

# ---------------------------------------------------------------------------
# 8. Session + autologin
# ---------------------------------------------------------------------------
# This verifies the session's .desktop file exists before writing autologin,
# enables sddm, and switches the default systemd target to graphical.target
# (an Ubuntu Server base defaults to multi-user.target, where a display
# manager can be installed and enabled and still never start).
"$REPO_ROOT/scripts/tvpc-session.sh" "${TVPC_SESSION:-auto}"

# ---------------------------------------------------------------------------
# 9. Audio: HDMI selection inside the user session
# ---------------------------------------------------------------------------
systemctl --global enable tvpc-audio.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 10. CEC: power on the TV and claim the HDMI input at boot
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 11. Power, swap, indexers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 12. Maintenance
# ---------------------------------------------------------------------------
dpkg-reconfigure -f noninteractive unattended-upgrades || true

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
# The old unit pair was named flatpak-user-update and the timer was enabled
# without its service ever being installed.
systemctl disable --now flatpak-user-update.timer 2>/dev/null || true
rm -f /etc/systemd/system/flatpak-user-update.{timer,service}
rm -rf /etc/systemd/system/flatpak-user-update.timer.d
systemctl daemon-reload
systemctl enable --now flatpak-update.timer

systemctl restart systemd-logind 2>/dev/null || true

# ---------------------------------------------------------------------------
# 13. Extras
# ---------------------------------------------------------------------------
for extra in install-extras.sh enhance-cec.sh customize.sh; do
  if [[ -x "$REPO_ROOT/scripts/$extra" ]]; then
    echo "== Running $extra =="
    "$REPO_ROOT/scripts/$extra" || echo "!! $extra reported an error (continuing)"
  fi
done

# ---------------------------------------------------------------------------
# 14. Verify the machine can actually reach a desktop
# ---------------------------------------------------------------------------
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

# `ls a b c d` returns non-zero as soon as ONE path is missing, and the session
# file lives in exactly one of these four directories — so test them one by one.
session_installed() {
  local name="$1" d
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions \
           /usr/local/share/xsessions /usr/share/xsessions; do
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
  echo "$PROBLEMS check(s) failed — fix these before rebooting, or you will get a"
  echo "black screen again. Diagnose with:  sudo tvpc-repair --check"
  exit 1
fi

echo "All checks passed. Reboot:  sudo reboot"
echo
echo "After reboot you land on the Plasma desktop as '$HTPC_USER'."
echo "VacuumTube starts automatically; the app launcher has the rest."
echo "Default password is 'htpc' — change it with: passwd"
echo
echo "Keep it in shape:         sudo tvpc-update   (converge + update)"
echo "If anything looks wrong:  tvpc-doctor        (health check)"
echo "If the screen is black:   sudo tvpc-repair   (from a TTY or over SSH)"
