#!/usr/bin/env bash
# tvpc-repair.sh — fix a tvpc box that boots to a black screen.
#
# Run it from a TTY (Ctrl+Alt+F3) or over SSH:
#     sudo ./scripts/tvpc-repair.sh            repair
#     sudo ./scripts/tvpc-repair.sh --check    report only, change nothing
#     sudo ./scripts/tvpc-repair.sh --logs     dump the logs that explain it
#
# It repairs the five things that produce a black screen on this build:
#   1. /etc/X11/xorg.conf.d/20-intel.conf naming a driver Ubuntu 24.04 does not
#      ship, so Xorg exits with "no screens found"
#   2. SDDM autologin pointing at a session .desktop file that is not installed
#   3. Plasma Mobile's shell dying and leaving kwin_wayland on a black root
#      window with a pointer
#   4. default.target still multi-user.target, so sddm never starts
#   5. "splash" hiding all of the above behind plymouth
set -uo pipefail

MODE="${1:-repair}"
case "$MODE" in
  -h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
    exit 0 ;;
esac
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# Works both from a repo checkout and from the copy installed in /usr/local/bin,
# whose REPO_ROOT is /usr/local and has no scripts/ directory.
SESSION_TOOL=""
for cand in "$REPO_ROOT/scripts/tvpc-session.sh" /usr/local/bin/tvpc-session; do
  [[ -x $cand ]] && { SESSION_TOOL="$cand"; break; }
done
CHANGED=0
ISSUES=0

say()  { echo "$*"; }
note() { echo "  --  $*"; }
ok()   { echo "  OK  $*"; }
bad()  { echo "  !!  $*"; ISSUES=$((ISSUES+1)); }
did()  { echo "  ->  $*"; CHANGED=$((CHANGED+1)); }

dry() { [[ $MODE == --check ]]; }

# ---------------------------------------------------------------------------
if [[ $MODE == --logs ]]; then
  say "=== kernel: display ==="
  journalctl -b -k --no-pager 2>/dev/null | grep -iE 'i915|drm|guc|huc' | tail -30
  say
  say "=== sddm ==="
  journalctl -b -u sddm --no-pager 2>/dev/null | tail -40
  say
  say "=== session (kwin / plasmashell / startplasma) ==="
  journalctl -b --no-pager 2>/dev/null | grep -iE 'kwin|plasmashell|startplasma|plasma_session' | tail -40
  say
  say "=== Xorg ==="
  for f in /var/log/Xorg.0.log /home/*/.local/share/sddm/xorg-session.log /var/lib/sddm/.local/share/sddm/*.log; do
    [[ -f $f ]] && { say "--- $f"; grep -E '\(EE\)|\(WW\)' "$f" 2>/dev/null | tail -15; }
  done
  say
  say "=== installed sessions ==="
  ls -1 /usr/share/wayland-sessions /usr/local/share/wayland-sessions \
        /usr/share/xsessions /usr/local/share/xsessions 2>/dev/null
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo $0 ${MODE#repair})" >&2
  exit 1
fi

dry && say "=== tvpc repair — CHECK ONLY, nothing will be changed ===" \
    || say "=== tvpc repair ==="

[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-htpc}"

# --- 1. Xorg config naming a missing driver ---------------------------------
say
say "[1] Xorg configuration"
if [[ -f /etc/X11/xorg.conf.d/20-intel.conf ]]; then
  bad "/etc/X11/xorg.conf.d/20-intel.conf requests Driver \"intel\""
  note "xserver-xorg-video-intel is not installed and is no longer part of"
  note "xserver-xorg-video-all on 24.04, so Xorg exits before SDDM can draw."
  if ! dry; then
    mv /etc/X11/xorg.conf.d/20-intel.conf /root/20-intel.conf.disabled
    did "moved aside to /root/20-intel.conf.disabled (modesetting takes over)"
  fi
else
  ok "no conflicting Xorg device config"
fi

# --- 2. PipeWire config that stops PipeWire starting ------------------------
say
say "[2] PipeWire configuration"
if [[ -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf ]]; then
  bad "90-hdmi-pin.conf loads libpipewire-module-alsa-sink, which does not exist"
  if ! dry; then
    rm -f /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf
    did "removed (audio is selected by tvpc-hdmi-audio instead)"
  fi
else
  ok "no bad PipeWire module override"
fi

# --- 3. Kernel command line -------------------------------------------------
say
say "[3] Kernel command line"
CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
if grep -q 'splash' <<<"$CMDLINE"; then
  bad "'splash' is set — plymouth hides both the boot log and any failure"
  if ! dry; then
    sed -i 's/ *\bsplash\b//g' /etc/default/grub
    did "removed 'splash' from /etc/default/grub"
  fi
else
  ok "no plymouth splash"
fi
if grep -q 'i915.enable_guc\|intel_iommu=igfx_off' <<<"$CMDLINE"; then
  bad "GuC/IOMMU parameters set — these were chosen for Broadwell; this is Kaby Lake"
  if ! dry; then
    sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' /etc/default/grub
    for f in /etc/default/grub.d/*.cfg; do
      [[ -f $f ]] && sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' "$f"
    done
    did "stripped them from /etc/default/grub and /etc/default/grub.d"
  fi
else
  ok "no leftover Broadwell-era kernel parameters"
fi

# --- 4. Display manager actually runs ---------------------------------------
say
say "[4] Display manager"
if ! command -v sddm >/dev/null 2>&1; then
  bad "sddm is not installed"
  if ! dry; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y sddm && did "installed sddm"
  fi
else
  ok "sddm installed"
fi

TARGET="$(systemctl get-default 2>/dev/null)"
if [[ $TARGET != graphical.target ]]; then
  bad "default systemd target is $TARGET — sddm is never reached"
  note "an Ubuntu Server base defaults to multi-user.target"
  if ! dry; then
    systemctl set-default graphical.target && did "default target -> graphical.target"
  fi
else
  ok "default target is graphical.target"
fi

if systemctl is-enabled sddm >/dev/null 2>&1; then
  ok "sddm enabled"
else
  bad "sddm is not enabled"
  if ! dry; then
    systemctl enable sddm && did "enabled sddm"
  fi
fi

# --- 5. The session it is trying to start -----------------------------------
say
say "[5] Autologin session"
CONF=""
for c in /etc/sddm.conf.d/10-tvpc.conf /etc/sddm.conf.d/autologin.conf /etc/sddm.conf; do
  [[ -f $c ]] && grep -q '^Session=' "$c" 2>/dev/null && { CONF="$c"; break; }
done

if [[ -z $CONF ]]; then
  bad "no autologin session configured"
else
  WANT_SESSION="$(awk -F= '/^Session=/{print $2; exit}' "$CONF")"
  FOUND=""
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions \
           /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$WANT_SESSION" ]] && { FOUND="$d/$WANT_SESSION"; break; }
  done
  if [[ -n $FOUND ]]; then
    ok "$CONF -> $WANT_SESSION (present)"
    if [[ $WANT_SESSION == plasma-mobile.desktop ]]; then
      note "Plasma Mobile is a touchscreen shell; when its shell fails you get"
      note "kwin_wayland on a black root window with a pointer — the symptom"
      note "you are debugging. Switching to the Plasma desktop session."
      ISSUES=$((ISSUES+1))
      FOUND=""
    fi
  else
    bad "$CONF points at $WANT_SESSION, which is not installed"
  fi

  if [[ -z $FOUND ]] && ! dry; then
    if [[ -n $SESSION_TOOL ]]; then
      if "$SESSION_TOOL" plasma 2>/dev/null || "$SESSION_TOOL" auto; then
        did "re-pointed autologin at a session that exists"
      else
        note "could not find any installed session to point at"
      fi
    else
      note "tvpc-session.sh not found next to this script or in /usr/local/bin"
      note "run:  sudo apt-get install plasma-workspace-wayland plasma-desktop"
    fi
  fi
fi

if [[ ! -d /usr/share/wayland-sessions ]] || ! ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1; then
  bad "no Wayland sessions installed at all"
  if ! dry; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y plasma-workspace-wayland plasma-desktop \
      && did "installed the Plasma Wayland session"
  fi
fi

# --- 6. The user it logs in as ----------------------------------------------
say
say "[6] Login user"
if id "$HTPC_USER" >/dev/null 2>&1; then
  ok "user $HTPC_USER exists"
  if [[ -d "/home/$HTPC_USER" ]]; then
    BADOWN="$(find "/home/$HTPC_USER/.config" ! -user "$HTPC_USER" -print -quit 2>/dev/null || true)"
    if [[ -n $BADOWN ]]; then
      bad "parts of /home/$HTPC_USER/.config are not owned by $HTPC_USER"
      note "Plasma refuses to start when it cannot write its own config"
      if ! dry; then
        chown -R "$HTPC_USER:$HTPC_USER" "/home/$HTPC_USER/.config" "/home/$HTPC_USER/.local" 2>/dev/null
        did "fixed ownership"
      fi
    else
      ok "config ownership is correct"
    fi
  fi
  # An expired password blocks autologin outright. PAM answers SDDM with
  # "you are required to change your password immediately", SDDM has no way
  # to run an interactive password change from an autologin, and the screen
  # stays black — with every other check on this page reporting OK.
  #
  # sp_lstchg (field 3 of /etc/shadow) == 0 means "must change at next
  # login". That is what `chage -d 0` sets, which an old version of
  # tvpc-postboot.sh used to run.
  LSTCHG="$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)"
  if [[ $LSTCHG == 0 ]]; then
    bad "password for $HTPC_USER is expired — PAM will refuse the autologin"
    note "this looks exactly like a boot failure: SDDM starts, PAM says the"
    note "password must be changed, and nothing ever appears on the TV"
    if ! dry; then
      chage -d "$(date +%Y-%m-%d)" "$HTPC_USER" && did "cleared the forced password change"
    fi
  else
    ok "password for $HTPC_USER is not expired"
  fi

  # A maximum age will re-expire it later, turning this into a box that
  # boots fine for N days and then goes black for no visible reason.
  MAXDAYS="$(awk -F: -v u="$HTPC_USER" '$1 == u { print $5 }' /etc/shadow 2>/dev/null)"
  if [[ -n $MAXDAYS && $MAXDAYS =~ ^[0-9]+$ && $MAXDAYS -lt 3650 ]]; then
    bad "password for $HTPC_USER expires every $MAXDAYS days — it will black-screen again"
    if ! dry; then
      chage -M -1 "$HTPC_USER" && did "removed the password expiry interval"
    fi
  fi
else
  bad "user $HTPC_USER does not exist — autologin cannot succeed"
fi

# --- finish -----------------------------------------------------------------
if ! dry && [[ $CHANGED -gt 0 ]]; then
  update-grub >/dev/null 2>&1 && did "regenerated GRUB config"
  systemctl daemon-reload
fi

say
if dry; then
  say "=== $ISSUES issue(s) found. Re-run without --check to fix them. ==="
  say "For the underlying errors:  sudo $0 --logs"
  [[ $ISSUES -eq 0 ]] && exit 0 || exit 1
fi

if [[ $CHANGED -eq 0 ]]; then
  say "=== Nothing needed changing. ==="
  say "The black screen is coming from somewhere else — collect evidence with:"
  say "  sudo $0 --logs"
  exit 0
fi

say "=== $CHANGED change(s) applied. Reboot: sudo reboot ==="
say "If it is still black afterwards, run:  sudo $0 --logs"
