#!/usr/bin/env bash
# tvpc-doctor.sh — read-only health check. Exits 0 if healthy, 1 if not.
set -u

FAIL=0
ok()   { echo "  OK    $1"; }
bad()  { echo "  FAIL  $1"; FAIL=1; }
warn() { echo "  WARN  $1"; }
hr()   { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
hr "Boot to desktop"
# The checks most likely to explain a black screen, in the order they bite.
TARGET="$(systemctl get-default 2>/dev/null)"
[[ $TARGET == graphical.target ]] \
  && ok "default target is graphical.target" \
  || bad "default target is $TARGET — the display manager never starts"

systemctl is-enabled sddm >/dev/null 2>&1 && ok "sddm enabled" || bad "sddm not enabled"
systemctl is-active  sddm >/dev/null 2>&1 && ok "sddm running" || warn "sddm not running"

SDDM_CONF=""
for c in /etc/sddm.conf.d/10-tvpc.conf /etc/sddm.conf.d/autologin.conf /etc/sddm.conf; do
  [[ -f $c ]] && grep -q '^Session=' "$c" 2>/dev/null && { SDDM_CONF="$c"; break; }
done
if [[ -n $SDDM_CONF ]]; then
  SESSION="$(awk -F= '/^Session=/{print $2; exit}' "$SDDM_CONF")"
  # One directory holds it; `ls` over all four fails on the three that do not.
  FOUND=""
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions \
           /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$SESSION" ]] && { FOUND=1; break; }
  done
  if [[ -n $FOUND ]]; then
    ok "autologin session $SESSION is installed"
  else
    bad "autologin points at $SESSION, which is not installed"
  fi
else
  bad "no autologin session configured"
fi

[[ -f /etc/X11/xorg.conf.d/20-intel.conf ]] \
  && bad "/etc/X11/xorg.conf.d/20-intel.conf present — Driver \"intel\" is not installable on 24.04" \
  || ok "no conflicting Xorg driver config"

grep -q splash /proc/cmdline 2>/dev/null \
  && warn "'splash' on the kernel command line hides boot failures behind plymouth" \
  || ok "no plymouth splash"

grep -qE 'i915\.enable_guc|intel_iommu=igfx_off' /proc/cmdline 2>/dev/null \
  && warn "Broadwell-era kernel parameters still set (this is Kaby Lake)" \
  || ok "kernel command line is clean"

hr "Display / Session"
if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
  ok "graphical session active (${WAYLAND_DISPLAY:-$DISPLAY})"
else
  warn "not run from inside the graphical session (fine over SSH)"
fi
loginctl list-sessions --no-legend 2>/dev/null | grep -q . \
  && ok "user session present" || bad "no user sessions"

# An expired password blocks the autologin and looks exactly like a boot
# failure — every other check here can pass while the TV stays black.
if [[ "$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)" == 0 ]]; then
  bad "password for $HTPC_USER is expired — PAM refuses the autologin"
  echo "      fix: sudo chage -d \$(date +%Y-%m-%d) $HTPC_USER"
else
  ok "password for $HTPC_USER is not expired"
fi
for c in /sys/class/drm/card*-HDMI-A-*/status; do
  [[ -e $c ]] || continue
  s="$(cat "$c")"
  [[ $s == connected ]] && ok "$(basename "$(dirname "$c")") connected" \
                        || warn "$(basename "$(dirname "$c")") $s"
done

hr "GPU / Video decode"
if vainfo >/dev/null 2>&1; then
  ok "VA-API initialised ($(vainfo 2>/dev/null | grep -c 'VAEntrypoint') entrypoints)"
else
  bad "vainfo failed — check LIBVA_DRIVER_NAME=iHD and the i915 driver"
fi

hr "Audio"
DEFAULT_SINK="$(pactl get-default-sink 2>/dev/null || true)"
[[ $DEFAULT_SINK == *hdmi* ]] \
  && ok "default sink is HDMI ($DEFAULT_SINK)" \
  || bad "default sink is not HDMI ('$DEFAULT_SINK')"
systemctl --user is-active pipewire >/dev/null 2>&1 && ok "pipewire running" || warn "pipewire not running for this user"
systemctl --user is-active tvpc-audio >/dev/null 2>&1 \
  && ok "tvpc-audio applied" \
  || warn "tvpc-audio not active (run: systemctl --user restart tvpc-audio)"
[[ -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf ]] \
  && bad "90-hdmi-pin.conf present — it loads a module that does not exist and stops PipeWire" \
  || ok "no bad PipeWire override"

hr "CEC / remote"
cec-client -l >/dev/null 2>&1 && ok "CEC adapter detected" || warn "no CEC adapter (or the listener holds it)"
systemctl is-active ydotoold >/dev/null 2>&1 \
  && ok "ydotoold running" \
  || warn "ydotoold not running — remote navigation keys will do nothing"
systemctl is-active tvpc-cec-remote >/dev/null 2>&1 \
  && ok "remote listener running" \
  || warn "tvpc-cec-remote not running (run scripts/enhance-cec.sh)"
systemctl is-active htpc-startup >/dev/null 2>&1 \
  && ok "htpc-startup (TV power-on) ran" \
  || warn "htpc-startup not active (TV will not auto power-on)"

hr "Network"
ip route get 1.1.1.1 >/dev/null 2>&1 && ok "default route exists" || bad "no network connectivity"
WIFI_DEV="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)"
if [[ -n $WIFI_DEV ]]; then
  nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -q "^$WIFI_DEV:connected" \
    && ok "Wi-Fi connected on $WIFI_DEV" || warn "Wi-Fi device $WIFI_DEV present but not connected"
else
  warn "no Wi-Fi interface visible (BIOS disabled, or firmware missing)"
fi

hr "SSH"
systemctl is-active ssh >/dev/null 2>&1 && ok "sshd running" || bad "sshd not running"

hr "Maintenance"
if systemctl is-enabled unattended-upgrades >/dev/null 2>&1 \
   || systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
  ok "unattended upgrades enabled"
else
  warn "automatic updates not confirmed"
fi
systemctl is-active zramswap >/dev/null 2>&1 && ok "zram swap active" || warn "zramswap not active"
systemctl is-enabled flatpak-update.timer >/dev/null 2>&1 \
  && ok "flatpak auto-update timer enabled" || warn "flatpak timer missing"

hr "Flatpaks"
if command -v flatpak >/dev/null; then
  flatpak list --app --columns=application 2>/dev/null | head -5 | sed 's/^/  /'
  flatpak remote-ls --updates 2>/dev/null | grep -q . \
    && warn "flatpak updates available (run: flatpak update)" \
    || ok "all flatpaks up to date"
else
  bad "flatpak not installed"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED — see above."
  echo "For a black screen specifically:  sudo tvpc-repair --check"
fi
exit $FAIL
