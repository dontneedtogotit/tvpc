#!/usr/bin/env bash
# tvpc-session.sh — pick a graphical session that actually exists on this box
# and point SDDM autologin at it.
#
# The original setup wrote "Session=plasma-mobile.desktop" unconditionally. If
# that session is missing, or its shell dies on startup, SDDM has nothing to
# fall back to and you get a black screen with a cursor. Nothing here is
# written until the target session file has been confirmed on disk.
#
# Usage: sudo ./scripts/tvpc-session.sh [auto|plasma|plasma-mobile|plasma-x11|kiosk]
set -euo pipefail

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi

HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
WANT="${1:-${TVPC_SESSION:-auto}}"

WAYLAND_DIRS=(/usr/local/share/wayland-sessions /usr/share/wayland-sessions)
X11_DIRS=(/usr/local/share/xsessions /usr/share/xsessions)

# Preference order for "auto".
#
# Plasma Mobile is NOT first. On Ubuntu 24.04 it is Plasma 5.27 built for
# touchscreens: with no touch input and a CEC remote it is barely navigable,
# and when its shell (plasma-nano) fails to start, kwin_wayland stays up
# showing a black root window and a pointer — the exact reported symptom.
# Plain Plasma Wayland is the tested path on this hardware; ask for
# plasma-mobile explicitly if you want to try it.
AUTO_ORDER=(plasma plasma-mobile plasma-x11 kiosk)

session_file() {   # $1 = session id -> echoes "<desktop-file>|<wayland|x11>"
  case "$1" in
    plasma)        echo "plasmawayland.desktop|wayland" ;;
    plasma-mobile) echo "plasma-mobile.desktop|wayland" ;;
    plasma-x11)    echo "plasma.desktop|x11" ;;
    kiosk)         echo "tvpc-kiosk.desktop|wayland" ;;
    # Opt-in, not in AUTO_ORDER. Install the package first; the check below
    # refuses to point autologin at a session that is not on disk.
    #   bigscreen -> apt install plasma-bigscreen   (KDE's TV shell, remote-first)
    #   phosh     -> apt install phosh              (GNOME's phone shell)
    bigscreen)     echo "plasma-bigscreen-wayland.desktop|wayland" ;;
    bigscreen-x11) echo "plasma-bigscreen-x11.desktop|x11" ;;
    phosh)         echo "phosh.desktop|wayland" ;;
    *)             return 1 ;;
  esac
}

# Echoes the full path if the session's .desktop file is installed.
locate_session() {
  local spec file type dirs=()
  spec="$(session_file "$1")" || return 1
  file="${spec%%|*}"; type="${spec##*|}"
  if [[ $type == wayland ]]; then dirs=("${WAYLAND_DIRS[@]}"); else dirs=("${X11_DIRS[@]}"); fi
  local d
  for d in "${dirs[@]}"; do
    [[ -f "$d/$file" ]] && { echo "$d/$file"; return 0; }
  done
  return 1
}

# --- the kiosk fallback -----------------------------------------------------
# Last resort so a broken Plasma never means a blank TV: kwin_wayland plus one
# application, no shell, no panel. Enough to see that the machine is alive and
# to reach a terminal.
install_kiosk_session() {
  install -d /usr/local/bin /usr/share/wayland-sessions

  cat >/usr/local/bin/tvpc-kiosk-app <<'KIOSKAPP'
#!/usr/bin/env bash
# Single application for the tvpc kiosk session, most-wanted first.
if flatpak info io.github.vacuumtube.VacuumTube >/dev/null 2>&1; then
  exec flatpak run io.github.vacuumtube.VacuumTube \
       --enable-features=VaapiVideoDecoder --ozone-platform-hint=auto
fi
for term in konsole xterm x-terminal-emulator; do
  command -v "$term" >/dev/null 2>&1 && exec "$term"
done
# Nothing to run: hold the session open so the compositor does not exit into
# a blank screen, and say so on the console.
echo "tvpc kiosk: no application available (install VacuumTube or konsole)" >&2
exec sleep infinity
KIOSKAPP
  chmod 0755 /usr/local/bin/tvpc-kiosk-app

  cat >/usr/local/bin/tvpc-kiosk-session <<'KIOSKSESSION'
#!/usr/bin/env bash
exec kwin_wayland --xwayland --exit-with-session=/usr/local/bin/tvpc-kiosk-app
KIOSKSESSION
  chmod 0755 /usr/local/bin/tvpc-kiosk-session

  cat >/usr/share/wayland-sessions/tvpc-kiosk.desktop <<'KIOSKDESKTOP'
[Desktop Entry]
Name=tvpc kiosk (fallback)
Comment=kwin_wayland plus a single app — used when Plasma will not start
Exec=/usr/local/bin/tvpc-kiosk-session
TryExec=/usr/local/bin/tvpc-kiosk-session
Type=Application
DesktopNames=KDE
KIOSKDESKTOP
}

# --- resolve ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }

if command -v kwin_wayland >/dev/null 2>&1; then install_kiosk_session; fi

CHOSEN="" CHOSEN_PATH=""
if [[ $WANT == auto ]]; then
  for candidate in "${AUTO_ORDER[@]}"; do
    if CHOSEN_PATH="$(locate_session "$candidate")"; then CHOSEN="$candidate"; break; fi
  done
else
  session_file "$WANT" >/dev/null || {
    echo "Unknown session '$WANT'. Known: auto plasma plasma-mobile plasma-x11" >&2
    echo "                              kiosk bigscreen bigscreen-x11 phosh" >&2
    exit 1
  }
  if ! CHOSEN_PATH="$(locate_session "$WANT")"; then
    echo "Requested session '$WANT' is not installed on this system." >&2
    echo "Installed sessions:" >&2
    ls -1 "${WAYLAND_DIRS[@]}" "${X11_DIRS[@]}" 2>/dev/null | sed 's/^/  /' >&2 || true
    exit 1
  fi
  CHOSEN="$WANT"
fi

if [[ -z $CHOSEN ]]; then
  echo "No usable graphical session found. Nothing would start at boot." >&2
  echo "Install one:  sudo apt-get install plasma-workspace-wayland plasma-desktop" >&2
  exit 1
fi

SESSION_DESKTOP="$(basename "$CHOSEN_PATH")"
echo "Session: $CHOSEN  ($CHOSEN_PATH)"

# --- write SDDM autologin ---------------------------------------------------
id "$HTPC_USER" >/dev/null 2>&1 || { echo "User '$HTPC_USER' does not exist" >&2; exit 1; }

install -d /etc/sddm.conf.d
# Drop the old hand-written file so two configs cannot disagree.
rm -f /etc/sddm.conf.d/autologin.conf

cat >/etc/sddm.conf.d/10-tvpc.conf <<EOF
# Generated by tvpc-session.sh — re-run that script instead of editing.
[Autologin]
User=$HTPC_USER
Session=$SESSION_DESKTOP
Relogin=false

[Theme]
Current=breeze

[General]
# Plasma Mobile drags in maliit-keyboard; an on-screen keyboard popping up on
# a TV with no touchscreen is not helpful.
InputMethod=
EOF

# --- make sure something actually starts it ---------------------------------
# This is an Ubuntu Server base: its default target is multi-user.target, so a
# display manager can be installed, enabled and still never run.
if [[ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]]; then
  systemctl set-default graphical.target
  echo "Default systemd target -> graphical.target"
fi
echo "/usr/bin/sddm" >/etc/X11/default-display-manager 2>/dev/null || true
systemctl enable sddm.service >/dev/null 2>&1 || true

# Record the choice so a later re-run, and /etc/default/tvpc, agree.
if [[ -f /etc/default/tvpc && $WANT != auto ]]; then
  if grep -q '^TVPC_SESSION=' /etc/default/tvpc; then
    sed -i "s/^TVPC_SESSION=.*/TVPC_SESSION=$CHOSEN/" /etc/default/tvpc
  else
    echo "TVPC_SESSION=$CHOSEN" >>/etc/default/tvpc
  fi
  echo "Recorded TVPC_SESSION=$CHOSEN in /etc/default/tvpc"
fi

echo "Autologin: $HTPC_USER -> $SESSION_DESKTOP"
