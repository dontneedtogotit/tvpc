#!/usr/bin/env bash
set -euo pipefail

# tvpc-install.sh — One-shot Android-like HTPC setup for Ubuntu 24.04 minimal
# Repo: https://github.com/<your-user>/tvpc  (clone here and run ./install.sh)

LOG="/var/log/tvpc-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== tvpc installer started $(date) ==="

# 0. Must be root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo ./install.sh)"
  exit 1
fi

# 1. Base packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
  flatpak software-properties-common \
  plasma-mobile plasma-desktop kwin-wayland sddm \
  pipewire pipewire-pulse wireplumber \
  libcec6 cec-utils \
  curl wget git

# 2. Flatpak + Flathub
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 3. VacuumTube (YouTube client)
flatpak install -y flathub io.github.vacuumtube.VacuumTube

# 4. Optional media apps (uncomment what you want)
# flatpak install -y flathub com.github.vkrinic.flatflix        # Netflix
# flatpak install -y flathub com.github.iwalton3.jellyfin-media-player  # Jellyfin

# 5. Create HTPC user
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
EOF

# 7. Force HDMI audio on boot (adjust card name if needed)
mkdir -p /etc/pipewire/pipewire-pulse.d
cat >/etc/pipewire/pipewire-pulse.d/99-htpc.conf <<'EOF'
pulse.cmd = [
  { cmd = "set-card-profile" args = "alsa_card.pci-0000_00_1f.3 output:hdmi-stereo" }
]
EOF

# 8. Enable CEC daemon for TV remote passthrough
systemctl enable --now cec-daemon 2>/dev/null || true

# 9. Disable sleep/hibernate on lid close (irrelevant for HTPC but safe)
sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind

# 10. Unattended security upgrades
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# 11. Apply repo-local overrides (configs, desktop files, wallpapers, etc.)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

# 12. Final message
echo "=== tvpc installer finished $(date) ==="
echo "Reboot now:  sudo reboot"
echo "After reboot you'll land on the Plasma Mobile home screen."
echo "VacuumTube is in the app drawer; pin it to favorites."
echo "Default user: htpc / htpc  (change password!)"
