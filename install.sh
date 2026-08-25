#!/usr/bin/env bash
set -euo pipefail

# tvpc-install.sh — One-shot Android-like HTPC setup for Ubuntu 24.04 minimal
# Target: Intel NUC7i5BNH + 2013 Samsung ~80" TV
# Repo: https://github.com/dontneedtogotit/tvpc  (clone here and run ./install.sh)

LOG="/var/log/tvpc-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== tvpc installer started $(date) ==="

# 0. Must be root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo ./install.sh)"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Base packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
  flatpak software-properties-common \
  plasma-mobile plasma-desktop kwin-wayland sddm \
  pipewire pipewire-pulse wireplumber pipewire-jack \
  libcec6 cec-utils libva2 libva-drm2 \
  intel-media-va-driver i965-va-driver vainfo \
  i2c-tools tlp powertop zram-tools \
  curl wget git rsync

# 2. Flatpak + Flathub
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 3. VacuumTube (YouTube client)
flatpak install -y flathub io.github.vacuumtube.VacuumTube

# 4. Optional media apps (uncomment what you want)
# flatpak install -y flathub com.github.vkrinic.flatflix
# flatpak install -y flathub com.github.iwalton3.jellyfin-media-player

# 5. Create HTPC user (added 'input' for remotes)
HTPC_USER="htpc"
if ! id "$HTPC_USER" &>/dev/null; then
  useradd -m -G video,render,audio,plugdev,input -s /bin/bash "$HTPC_USER"
  echo "$HTPC_USER:htpc" | chpasswd
  echo "Created user $HTPC_USER (password: htpc — change it!)"
fi

# 6. Auto-login into Plasma Mobile (Wayland)
mkdir -p /etc/sddm.conf.d
cat >/etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$HTPC_USER
Session=plasma-mobile.desktop

[Theme]
Current=breeze
EOF

# 7. Force HDMI audio on boot (Broadwell HDMI, stereo-extra for 2013 Samsung)
mkdir -p /etc/pipewire/pipewire-pulse.d
cat >/etc/pipewire/pipewire-pulse.d/99-htpc.conf <<'EOF'
# Force HDMI output (NUC7i5BNH Broadwell)
# 'hdmi-stereo-extra' uses LPCM that 2013 Samsung TVs accept reliably
# NOTE: This only sets the default sink name; actual card profile switching
# happens via htpc-audio.service (systemd) which runs after pipewire starts.
pulse.cmd = [
  { cmd = "set-default-sink"  args = "alsa_output.pci-0000_00_1f.3.hdmi-stereo-extra" }
]
EOF

# 8. Load i915 kernel module with GuC/HuC firmware for Broadwell HW decode
cat >/etc/modules-load.d/i915.conf <<'EOF'
i915
EOF
# Append kernel params robustly (handles empty/default lines, avoids duplicate params)
if ! grep -q "i915.enable_guc" /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_guc=2 intel_iommu=igfx_off"/' /etc/default/grub
fi
update-grub

# 9. CEC daemon for Samsung Anynet+ remote
systemctl enable --now cec-daemon 2>/dev/null || true

# 10. Power-on the Samsung TV + make NUC the active source at boot
install -m 0755 "$REPO_ROOT/scripts/cec-tv-poweron.sh" /usr/local/bin/cec-tv-poweron.sh
cat >/etc/systemd/system/htpc-startup.service <<'EOF'
[Unit]
Description=Power on Samsung TV via CEC and switch input
After=multi-user.target pipewire.service network-online.target cec-daemon.service
Requires=cec-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cec-tv-poweron.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
systemctl enable htpc-startup.service

# 11. TLP + powertop auto-tune for NUC idle power (~6W)
systemctl enable tlp.service
powertop --auto-tune || true

# 12. ZRAM swap (silent, fast; better than disk swap on NUC SSD)
cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable --now zramswap

# 13. Disable trackers / indexers (reduces SSD writes + CPU)
systemctl disable --now tracker-miner-fs-3.service 2>/dev/null || true
systemctl mask    tracker-miner-fs-3.service 2>/dev/null || true
systemctl disable --now tracker-store.service     2>/dev/null || true
systemctl mask    tracker-store.service     2>/dev/null || true

# 14. Auto-update Flatpaks weekly (timer + service)
mkdir -p /etc/systemd/system/flatpak-user-update.timer.d
cat >/etc/systemd/system/flatpak-user-update.timer <<'EOF'
[Unit]
Description=Weekly Flatpak auto-update timer for HTPC user

[Timer]
OnCalendar=Sun 04:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
cat >/etc/systemd/system/flatpak-user-update.service <<'EOF'
[Unit]
Description=Weekly Flatpak update for HTPC user

[Service]
Type=oneshot
ExecStart=flatpak update --user --noninteractive
EOF
systemctl enable flatpak-user-update.timer
systemctl enable flatpak-user-update.service

# 15. Boot-time lid/sleep hardening
sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/^#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sed -i 's/^#HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind

# 16. Unattended security upgrades
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# 17. Apply repo-local overrides (configs, desktop files, wallpapers, etc.)
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

# 18. Enable custom services from overlays
if [[ -d "$REPO_ROOT/overlays/etc/systemd/system" ]]; then
  for service in "$REPO_ROOT/overlays/etc/systemd/system/"*.service; do
    [[ -e "$service" ]] || continue
    name=$(basename "$service")
    cp "$service" "/etc/systemd/system/$name"
    systemctl enable "$name" 2>/dev/null || true
  done
  echo "Enabled systemd services from overlays"
fi

# 19. Run post-install extras (HW decode verification, NUC tuneables)
if [[ -x "$REPO_ROOT/scripts/install-extras.sh" ]]; then
  "$REPO_ROOT/scripts/install-extras.sh" || true
fi

# 20. Final message
echo "=== tvpc installer finished $(date) ==="
echo "Reboot now:  sudo reboot"
echo "After reboot you'll land on the Plasma Mobile home screen."
echo "VacuumTube is in the app drawer; pin it to favorites."
echo "Default user: htpc / htpc  (change password!)"
echo
echo "Quick checks after reboot:"
echo "  vainfo                          # verify Broadwell VA-API"
echo "  pactl list sinks               # confirm HDMI is default"
echo "  systemctl status htpc-startup   # CEC power-on"
echo "  systemctl status htpc-audio     # HDMI audio profile"