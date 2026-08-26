#!/usr/bin/env bash
# tvpc-doctor.sh - Health check for the tvpc HTPC
# Run anytime; safe, read-only. Exits 0 if healthy, 1 if any check failed.

set -u

FAIL=0
ok()   { echo "  OK    $1"; }
bad()  { echo "  FAIL  $1"; FAIL=1; }
warn() { echo "  WARN  $1"; }

hr() { echo; echo "== $1 =="; }

hr "Display / Session"
if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
  ok "graphical session active (${WAYLAND_DISPLAY:-$DISPLAY})"
else
  warn "not run from inside the graphical session (fine via SSH)"
fi
loginctl list-sessions --no-legend 2>/dev/null | grep -q . \
  && ok "user session present" || bad "no user sessions"

hr "GPU / Video decode"
if vainfo >/dev/null 2>&1; then
  ok "VA-API initialised ($(vainfo 2>/dev/null | grep -c 'VAEntrypoint') entrypoints)"
else
  bad "vainfo failed — GuC/HuC or driver problem (reboot may fix)"
fi
dmesg 2>/dev/null | grep -qi "guc.*loaded\|HuC" && ok "i915 GuC/HuC firmware loaded" || warn "GuC load not confirmed in dmesg"

hr "Audio"
DEFAULT_SINK=$(pactl get-default-sink 2>/dev/null || true)
if [[ "$DEFAULT_SINK" == *hdmi* ]]; then
  ok "default sink is HDMI ($DEFAULT_SINK)"
else
  bad "default sink is not HDMI ('$DEFAULT_SINK')"
fi
systemctl is-active pipewire >/dev/null 2>&1 && ok "pipewire running" || bad "pipewire not running"

hr "CEC"
cec-client -l >/dev/null 2>&1 && ok "CEC adapter detected" || bad "no CEC adapter found"
systemctl is-active tvpc-cec-remote >/dev/null 2>&1 && ok "remote listener running" \
  || warn "tvpc-cec-remote not installed/running (run scripts/enhance-cec.sh)"

hr "Network"
ip route get 1.1.1.1 >/dev/null 2>&1 && ok "default route exists" || bad "no network connectivity"
WIFI_DEV=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)
if [[ -n "$WIFI_DEV" ]]; then
  nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -q "^$WIFI_DEV:connected" \
    && ok "Wi-Fi connected on $WIFI_DEV" || warn "Wi-Fi device $WIFI_DEV present but not connected"
else
  warn "no Wi-Fi interface visible (BIOS disabled, or firmware missing)"
fi

hr "SSH"
systemctl is-active ssh >/dev/null 2>&1 && ok "sshd running" || bad "sshd not running"

hr "Maintenance"
systemctl is-active unattended-upgrades >/dev/null 2>&1 || systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1 \
  && ok "unattended upgrades enabled" || warn "automatic updates not confirmed"
systemctl is-active zramswap >/dev/null 2>&1 && ok "zram swap active" || warn "zramswap not active"
systemctl is-enabled flatpak-update.timer >/dev/null 2>&1 && ok "flatpak auto-update timer enabled" || warn "flatpak timer missing"

hr "Flatpaks"
if command -v flatpak >/dev/null; then
  flatpak list --app 2>/dev/null | head -5
  flatpak update --no-deps 2>/dev/null | grep -q "Nothing to do" && ok "all flatpaks up to date" || warn "updates available"
else
  bad "flatpak not installed"
fi

echo
[[ $FAIL -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED — see above"
exit $FAIL