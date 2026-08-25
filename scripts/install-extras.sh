#!/usr/bin/env bash
# install-extras.sh — Post-install hardware verification & NUC-specific tweaks
# Run after install.sh (automatically invoked) or manually via: sudo ./scripts/install-extras.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo ">> tvpc install-extras using repo root: $REPO_ROOT"

# 1. Verify VA-API on Broadwell (i5-7260U / HD 620)
echo "== VA-API verification =="
vainfo 2>/dev/null || echo "vainfo failed — driver may need reboot"

# 2. Set Intel GPU performance governor (persist across reboots)
#    powersave = best for idle; performance = better for 4K decode
#    We choose 'powersave' as default (idle ~6W); user can override
if [[ -d /sys/class/drm/card0/device ]]; then
  echo "powersave" > /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null || true
fi

# 3. NUC blue LED off at night (optional; requires i2c-tools + I2C access)
#    LED is on ISL94202 controller at 0x64 on I2C bus 0 (NUC7)
#    Comment out if your NUC revision differs.
if command -v i2ctransfer >/dev/null; then
  # LED off: write 0x00 to register 0x04
  i2ctransfer -y 0 w2@0x64 0x04 0x00 2>/dev/null || true
fi

# 4. NetworkManager: prefer wired, disable Wi-Fi if no antenna
#    (Create a connection profile if not present)
if ! nmcli -t -f TYPE con show | grep -q ethernet; then
  nmcli con add type ethernet ifname eno1 con-name "NUC-Wired" ipv4.method auto 2>/dev/null || true
fi
nmcli radio wifi off 2>/dev/null || true

# 5. Volume step size: Samsung remote sends large jumps → map to 2%
cat >/usr/local/bin/htpc-volume-step <<'EOF'
#!/usr/bin/env bash
# Called by Plasma Mobile keybindings instead of default volume keys
pactl set-sink-volume @DEFAULT_SINK@ "$1"
EOF
chmod +x /usr/local/bin/htpc-volume-step

# 6. Disable Plymouth (faster boot; uncomment in grub if desired)
#    Already done in install.sh via grub cmdline 'quiet splash' only.

# 7. Autostart VacuumTube (pinned to favorites handled by Plasma config)
#    Create .desktop entry for auto-launch on login (optional)
mkdir -p /home/htpc/.config/autostart
cat >/home/htpc/.config/autostart/vacuumtube.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=VacuumTube
Exec=flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --use-gl=egl
X-GNOME-Autostart-enabled=true
EOF
chown htpc:htpc /home/htpc/.config/autostart/vacuumtube.desktop

# 8. Apply repo overlays again in case install.sh added new ones
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a "$REPO_ROOT/overlays/" /
  echo "Re-applied repo overlays"
fi

echo ">> install-extras complete"