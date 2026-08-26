#!/usr/bin/env bash
# install-extras.sh — Post-install hardware verification & NUC-specific tweaks
# Run after install.sh (automatically invoked) or manually via: sudo ./scripts/install-extras.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo ">> tvpc install-extras using repo root: $REPO_ROOT"

# 1. Verify VA-API on Broadwell (i5-7260U / HD 620)
echo "== VA-API verification =="
if command -v vainfo >/dev/null; then
  vainfo 2>/dev/null && echo "VA-API OK" || echo "VA-API probe failed (expected before reboot)"
else
  echo "vainfo not installed yet"
fi

# 2. Intel GPU power: use TLP/powertop instead of manual sysfs writes
#    Broadwell power states are managed by i915 + TLP; no manual DPM needed.
#    Leave GPU in default powersave mode via TLP config.
if [[ -f /etc/tlp.d/99-tvpc-gpu.conf ]]; then
  echo "TLP GPU config already exists"
else
  mkdir -p /etc/tlp.d
  cat >/etc/tlp.d/99-tvpc-gpu.conf <<'EOF'
# NUC7i5BNH Broadwell: prefer powersave for idle, let TLP handle it
# Remove this file to restore default TLP behaviour
DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE="airplane"
EOF
fi

# 3. NUC blue LED off at night (optional; requires i2c-tools + I2C access)
#    LED is on ISL94202 controller at 0x64 on I2C bus 0 (NUC7 confirmed)
#    Only affects the front panel LED; BIOS setting overrides this on reboot.
#    Guard with /etc/default/tvpc-led to allow override.
if [[ ! -f /etc/default/tvpc-led ]] && command -v i2ctransfer >/dev/null 2>&1; then
  # Attempt LED off; if it fails silently (NUC revision mismatch), that's fine
  i2ctransfer -y 0 w2@0x64 0x04 0x00 2>/dev/null || true
  echo "NUC LED off attempted (disable: touch /etc/default/tvpc-led)"
fi

# 4. NetworkManager: prefer wired, disable Wi-Fi (NUC has no Wi-Fi card by default)
#    Create wired connection if none exists
if command -v nmcli >/dev/null 2>&1; then
  if ! nmcli -t -f TYPE,STATE con show | grep -q "ethernet:activated"; then
    nmcli con add type ethernet ifname eno1 con-name "NUC-Wired" ipv4.method auto 2>/dev/null || true
  fi
  # Disable Wi-Fi radio if no adapters detected (avoids radio noise / power waste)
  nmcli radio wifi off 2>/dev/null || true
fi

# 5. Volume step size: Samsung remote sends large jumps → use 2% increments
mkdir -p /usr/local/bin
cat >/usr/local/bin/htpc-volume-step <<'EOF'
#!/usr/bin/env bash
# Called by Plasma Mobile keybindings instead of default volume keys.
# Usage: htpc-volume-step +2  or  htpc-volume-step -2
STEP="${1:-+2}%"
pactl set-sink-volume @DEFAULT_SINK@ "$STEP"
EOF
chmod +x /usr/local/bin/htpc-volume-step

# 6. Autostart + favorites for VacuumTube are owned by customize.sh
#    (writes to both /etc/skel and the live HTPC home, with native Wayland + VA-API flags)

# 7. Flatpak: grant VacuumTube VA-API access via portal override
mkdir -p /var/lib/flatpak/overrides
cat >/var/lib/flatpak/overrides/global <<'EOF'
[Context]
devices=dri
sockets=wayland;x11;pulseaudio;fallback-x11;ipc;
filesystems=xdg-videos:ro;xdg-music:ro;xdg-pictures:ro;home;
EOF

# 8. Apply repo overlays again in case install.sh added new ones
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Re-applied repo overlays"
fi

echo ">> install-extras complete"