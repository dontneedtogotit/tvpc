#!/usr/bin/env bash
# tvpc-bigscreen.sh — install Plasma Bigscreen, KDE's TV shell.
#
# This is the low-risk TV shell for this box, and the one to reach for
# first. Everything comes from the Ubuntu universe archive at the same
# Plasma 5.27 version already installed, so nothing swaps a library out
# from under the running desktop — the failure mode that the Hyprland PPA
# route hit. No third-party archives are involved.
#
# It is also the only shell here that is already remote-shaped: big tiles,
# D-pad navigation, and it reads the plain arrow keys and Enter that the
# CEC listener already sends. No key remapping needed.
#
# Usage:
#   sudo ./scripts/tvpc-bigscreen.sh            install
#   sudo ./scripts/tvpc-bigscreen.sh --switch   install, then make it the session
#   sudo ./scripts/tvpc-bigscreen.sh --check    report state, change nothing
#   sudo ./scripts/tvpc-bigscreen.sh --remove   uninstall
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

MODE=install
case "${1:-}" in
  --check)  MODE=check ;;
  --switch) MODE=switch ;;
  --remove) MODE=remove ;;
  "")       ;;
  *) echo "Unknown option '$1' (try --help)" >&2; exit 1 ;;
esac

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

WAYLAND_SESSION=/usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop
X11_SESSION=/usr/share/xsessions/plasma-bigscreen-x11.desktop

ok()  { echo "  ok    $*"; }
bad() { echo "  MISS  $*"; }

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  echo "== Plasma Bigscreen =="
  if dpkg-query -W -f='${Status}' plasma-bigscreen 2>/dev/null | grep -q "^install ok installed$"; then
    ok "plasma-bigscreen $(dpkg-query -W -f='${Version}' plasma-bigscreen 2>/dev/null)"
  else
    bad "plasma-bigscreen not installed"
  fi
  if [[ -f $WAYLAND_SESSION ]]; then ok "Wayland session $WAYLAND_SESSION"; else bad "Wayland session $WAYLAND_SESSION"; fi
  if [[ -f $X11_SESSION     ]]; then ok "X11 session $X11_SESSION";         else bad "X11 session $X11_SESSION"; fi
  echo
  echo "Active session: ${TVPC_SESSION:-unset}"
  echo "  switch with:  sudo tvpc-session bigscreen       (Wayland)"
  echo "                sudo tvpc-session bigscreen-x11   (X11 fallback)"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --remove
# ---------------------------------------------------------------------------
if [[ $MODE == remove ]]; then
  case "${TVPC_SESSION:-}" in
    bigscreen|bigscreen-x11)
      echo "!! TVPC_SESSION is '$TVPC_SESSION'. Point it somewhere that exists first:"
      echo "     sudo tvpc-session plasma"
      exit 1 ;;
  esac
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y plasma-bigscreen || exit 1
  apt-get autoremove -y || true
  echo "Done. The Plasma session is untouched."
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

# plasma-bigscreen lives in universe. On a stock Ubuntu Server that is
# already enabled; on a trimmed sources list it may not be.
if ! apt-cache policy plasma-bigscreen 2>/dev/null | grep -q 'Candidate: [^(]'; then
  echo "== Enabling the universe component =="
  if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y universe || true
  fi
  apt-get update
fi

if ! apt-cache policy plasma-bigscreen 2>/dev/null | grep -q 'Candidate: [^(]'; then
  echo "!! No installable plasma-bigscreen for this release." >&2
  echo "   Check: apt-cache policy plasma-bigscreen" >&2
  exit 1
fi

echo "== Installing Plasma Bigscreen =="
# Exit status is checked, unlike the first cut of the Hyprland installer.
# Everything here is archive-native at the Plasma version already present,
# so a failure means something is genuinely wrong rather than an ABI clash.
if ! apt-get install -y plasma-bigscreen; then
  echo
  echo "!! apt could not install plasma-bigscreen (see the error above)." >&2
  echo "   Nothing was changed. The current session is untouched." >&2
  exit 1
fi

# The session files are the whole point: tvpc-session refuses to point
# autologin at a .desktop that is not on disk, so confirm them here rather
# than discovering it at the next boot.
MISSING=0
if [[ -f $WAYLAND_SESSION ]]; then ok "Wayland session installed"; else bad "$WAYLAND_SESSION"; MISSING=1; fi
if [[ -f $X11_SESSION     ]]; then ok "X11 session installed";     else bad "$X11_SESSION";     MISSING=1; fi
if [[ $MISSING -eq 1 ]]; then
  echo
  echo "!! plasma-bigscreen installed but its session files are not where" >&2
  echo "   expected. Not switching anything." >&2
  exit 1
fi

# Bigscreen needs the same "never blank the TV" treatment as Plasma. That
# lives in customize.sh, which seeds both /etc/skel and the live user, so
# just make sure it has been run rather than duplicating the settings.
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
if [[ -n $HOME_DIR && ! -f "$HOME_DIR/.config/powermanagementprofilesrc" ]]; then
  echo
  echo "!! $HTPC_USER has no powermanagementprofilesrc — the TV will blank"
  echo "   after a few minutes idle, which looks just like a boot failure."
  echo "   Fix with:  sudo ./scripts/customize.sh"
fi

if [[ $MODE == switch ]]; then
  echo
  echo "== Switching the session =="
  SESSION_TOOL=""
  for cand in "$(dirname "${BASH_SOURCE[0]}")/tvpc-session.sh" /usr/local/bin/tvpc-session; do
    [[ -x $cand ]] && { SESSION_TOOL="$cand"; break; }
  done
  if [[ -z $SESSION_TOOL ]]; then
    echo "!! tvpc-session not found; switch manually: sudo tvpc-session bigscreen" >&2
    exit 1
  fi
  "$SESSION_TOOL" bigscreen || exit 1
  echo
  echo "Restart the display manager to pick it up:"
  echo "  sudo systemctl restart sddm"
  exit 0
fi

cat <<NEXT

Installed. The running session has not been changed.

  Try it:    sudo tvpc-session bigscreen && sudo systemctl restart sddm
  X11 too:   sudo tvpc-session bigscreen-x11    (if Wayland misbehaves)
  Go back:   sudo tvpc-session plasma && sudo systemctl restart sddm

The CEC remote drives this one as-is: Bigscreen navigates on plain arrow
keys and Enter, which is exactly what the listener already sends.
NEXT
