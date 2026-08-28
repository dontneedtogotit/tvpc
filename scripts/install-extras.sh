#!/usr/bin/env bash
# install-extras.sh — hardware checks and NUC-specific tuning.
# Invoked by install.sh; also runnable on its own: sudo ./scripts/install-extras.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
echo ">> tvpc install-extras using repo root: $REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. Graphics
# ---------------------------------------------------------------------------
# NUC7i5BNH is a Core i5-7260U: Kaby Lake (gen9), Iris Plus Graphics 640.
# Earlier revisions of this repo called it Broadwell and tuned it accordingly.
echo "== GPU =="
if [[ -d /sys/class/drm ]]; then
  for card in /sys/class/drm/card*-HDMI-A-*; do
    [[ -e "$card/status" ]] || continue
    echo "  $(basename "$card"): $(cat "$card/status")"
  done
fi

echo "== VA-API =="
if command -v vainfo >/dev/null; then
  if LIBVA_DRIVER_NAME=iHD vainfo 2>/dev/null | grep VAEntrypoint >/dev/null; then
    echo "  VA-API OK via iHD"
  elif vainfo 2>/dev/null | grep VAEntrypoint >/dev/null; then
    echo "  VA-API OK via the default driver"
  else
    echo "  VA-API probe failed (expected before the first reboot)"
  fi
else
  echo "  vainfo not installed yet"
fi

# ---------------------------------------------------------------------------
# 2. Power
# ---------------------------------------------------------------------------
# This NUC runs on mains only, so TLP should always use its AC profile rather
# than deciding it is on battery. The previous file here set
# DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE="airplane", which is not a device name.
mkdir -p /etc/tlp.d
cat >/etc/tlp.d/99-tvpc.conf <<'EOF'
# tvpc: always-on HTPC, mains powered.
TLP_DEFAULT_MODE=AC
TLP_PERSISTENT_DEFAULT=1
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
# Runtime PM on the audio controller causes an audible click on the first
# sample after idle on Kaby Lake HDMI; keep it awake.
SOUND_POWER_SAVE_ON_AC=0
EOF

# ---------------------------------------------------------------------------
# 3. Network
# ---------------------------------------------------------------------------
# Leave Wi-Fi on by default: the NUC7i5BNH has an Intel Wireless-AC 8265 and
# plenty of these installs have no ethernet run to the TV.
if command -v nmcli >/dev/null 2>&1; then
  if [[ "${TVPC_WIRED_ONLY:-0}" == "1" ]]; then
    nmcli radio wifi off 2>/dev/null || true
    echo "  Wi-Fi radio off (TVPC_WIRED_ONLY=1)"
  else
    nmcli radio wifi on 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# 4. Volume stepping for the TV remote
# ---------------------------------------------------------------------------
mkdir -p /usr/local/bin
cat >/usr/local/bin/htpc-volume-step <<'EOF'
#!/usr/bin/env bash
# Small volume steps: the Samsung remote repeats fast and 5% jumps overshoot.
# Usage: htpc-volume-step +2   |   htpc-volume-step -2
pactl set-sink-volume @DEFAULT_SINK@ "${1:-+2}%"
EOF
chmod +x /usr/local/bin/htpc-volume-step

# ---------------------------------------------------------------------------
# 5. Flatpak permissions
# ---------------------------------------------------------------------------
# /dev/dri for VA-API decode. Media directories read-only rather than the whole
# home directory.
mkdir -p /var/lib/flatpak/overrides
cat >/var/lib/flatpak/overrides/global <<'EOF'
[Context]
devices=dri
sockets=wayland;fallback-x11;pulseaudio;
filesystems=xdg-videos:ro;xdg-music:ro;xdg-pictures:ro;
EOF

echo ">> install-extras complete"
