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
#
# Tuning the shell once it is running:
#   sudo ./scripts/tvpc-bigscreen.sh --ui-scale 10       shrink/grow the whole UI
#   sudo ./scripts/tvpc-bigscreen.sh --list-apps         apps the home screen shows
#   sudo ./scripts/tvpc-bigscreen.sh --hide firefox,vlc  drop apps from the home screen
#   sudo ./scripts/tvpc-bigscreen.sh --show firefox      put one back
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

MODE=install
ARG="${2:-}"
case "${1:-}" in
  --check)     MODE=check ;;
  --switch)    MODE=switch ;;
  --remove)    MODE=remove ;;
  --list-apps) MODE=listapps ;;
  --ui-scale)  MODE=uiscale ;;
  --hide)      MODE=hide ;;
  --show)      MODE=show ;;
  "")          ;;
  *) echo "Unknown option '$1' (try --help)" >&2; exit 1 ;;
esac

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

WAYLAND_SESSION=/usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop
X11_SESSION=/usr/share/xsessions/plasma-bigscreen-x11.desktop

# Runtime QML modules that plasma-bigscreen imports but does NOT declare in
# its Depends. On a desktop install these are already present as a side
# effect of everything else; on this server-based build they are not, and
# the shell starts and then dies with "error loading QML file".
#
# The list was derived from the imports in the v5.27.11 source (the version
# noble ships) rather than found one crash at a time:
#   grep -rhoE '^\s*import [A-Za-z0-9_.]+' --include='*.qml' .
BIGSCREEN_QML_DEPS=(
  kdeconnect                              # org.kde.kdeconnect            (8 imports)
  qml-module-qtgraphicaleffects           # QtGraphicalEffects           (17 imports)
  qml-module-org-kde-kquickcontrolsaddons # org.kde.kquickcontrolsaddons  (7)
  qml-module-org-kde-kcm                  # org.kde.kcm                   (7)
  qml-module-org-kde-kirigami2            # org.kde.kirigami             (60)
  qml-module-org-kde-kitemmodels          # org.kde.kitemmodels
  qml-module-org-kde-kcoreaddons          # org.kde.kcoreaddons
  qml-module-qtmultimedia                 # QtMultimedia
  qml-module-qtquick-virtualkeyboard      # QtQuick.VirtualKeyboard
  plasma-settings                         # org.kde.plasma.settings
  plasma-pa                               # org.kde.plasma.private.volume
)

ok()  { echo "  ok    $*"; }
bad() { echo "  MISS  $*"; }

# apt-cache policy piped into `grep -q` is a trap under `set -o pipefail`:
# grep exits the moment it matches, apt-cache dies on SIGPIPE, and pipefail
# promotes that failure to the whole pipeline — so the test reports "no
# candidate" precisely BECAUSE it found one. Capture the output instead.
apt_has_candidate() {
  local policy
  policy="$(apt-cache policy "$1" 2>/dev/null)" || return 1
  [[ $policy == *"Candidate:"* ]] || return 1
  [[ $policy != *"Candidate: (none)"* ]]
}

pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
  [[ $st == "install ok installed" ]]
}

# ---------------------------------------------------------------------------
# Tuning helpers
# ---------------------------------------------------------------------------
user_home() { getent passwd "$HTPC_USER" | cut -d: -f6; }

# Bigscreen filters the app list in ApplicationListModel::loadApplications():
# it takes every KService application, drops Terminal=true ones, drops
# anything with NoDisplay, and drops names listed in the "blacklist" key of
# applications-blacklistrc. That last one is undocumented but it is the
# supported way to take an app off the home screen.
BLACKLIST_RC() { echo "$(user_home)/.config/applications-blacklistrc"; }

read_blacklist() {
  local rc; rc="$(BLACKLIST_RC)"
  [[ -f $rc ]] || return 0
  sed -n 's/^blacklist=//p' "$rc" | tr ',' '\n' | sed '/^$/d'
}

write_blacklist() {   # entries on stdin, one per line
  local rc list; rc="$(BLACKLIST_RC)"
  list="$(sort -u | sed '/^$/d' | paste -sd, -)"
  install -d -o "$HTPC_USER" -g "$HTPC_USER" "$(dirname "$rc")"
  cat >"$rc" <<RC
[Applications]
blacklist=$list
RC
  chown "$HTPC_USER:$HTPC_USER" "$rc"
  echo "$list"
}

# Every application the home screen would show, as Bigscreen selects them.
list_apps() {
  local d f id name nodisp term type
  for d in /usr/share/applications /usr/local/share/applications \
           "$(user_home)/.local/share/applications" \
           /var/lib/flatpak/exports/share/applications; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do
      [[ -f $f ]] || continue
      type="$(sed -n 's/^Type=//p'      "$f" | head -1)"
      nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
      term="$(sed -n 's/^Terminal=//p'  "$f" | head -1)"
      [[ $type == Application ]]  || continue
      [[ $nodisp == true ]]       && continue
      [[ $term == true ]]         && continue
      name="$(sed -n 's/^Name=//p' "$f" | head -1)"
      id="$(basename "$f" .desktop)"
      printf '%s\t%s\n' "$id" "$name"
    done
  done | sort -u
}

if [[ $MODE == listapps ]]; then
  [[ -n "$(user_home)" ]] || { echo "User '$HTPC_USER' has no home directory" >&2; exit 1; }
  mapfile -t HIDDEN < <(read_blacklist)
  printf '%-45s %-30s %s\n' "ID (use this with --hide)" "NAME" "STATE"
  while IFS=$'\t' read -r id name; do
    state="shown"
    for h in ${HIDDEN+"${HIDDEN[@]}"}; do [[ $h == "$id" ]] && state="HIDDEN"; done
    printf '%-45s %-30s %s\n' "$id" "${name:0:29}" "$state"
  done < <(list_apps)
  exit 0
fi

if [[ $MODE == hide || $MODE == show ]]; then
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }
  [[ -n $ARG ]] || { echo "Usage: $0 --$MODE app1[,app2,...]  (ids from --list-apps)" >&2; exit 1; }
  mapfile -t CURRENT < <(read_blacklist)
  IFS=',' read -r -a WANT <<<"$ARG"
  if [[ $MODE == hide ]]; then
    NEW="$(printf '%s\n' ${CURRENT+"${CURRENT[@]}"} "${WANT[@]}" | write_blacklist)"
  else
    KEEP=()
    for c in ${CURRENT+"${CURRENT[@]}"}; do
      drop=0
      for w in "${WANT[@]}"; do [[ $c == "$w" ]] && drop=1; done
      [[ $drop -eq 0 ]] && KEEP+=("$c")
    done
    NEW="$(printf '%s\n' ${KEEP+"${KEEP[@]}"} | write_blacklist)"
  fi
  echo "Hidden from the home screen: ${NEW:-(none)}"
  echo "Log out and back in, or: sudo systemctl restart sddm"
  exit 0
fi

if [[ $MODE == uiscale ]]; then
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }
  [[ $ARG =~ ^[0-9]+$ ]] || { echo "Usage: $0 --ui-scale <point-size>   (Bigscreen: try 10)" >&2; exit 1; }
  HOME_DIR="$(user_home)"
  [[ -n $HOME_DIR ]] || { echo "User '$HTPC_USER' has no home directory" >&2; exit 1; }
  KG="$HOME_DIR/.config/kdeglobals"
  install -d -o "$HTPC_USER" -g "$HTPC_USER" "$HOME_DIR/.config"
  [[ -f $KG ]] || printf '[General]\n' >"$KG"
  # Every Kirigami margin and tile derives from Kirigami.Units.gridUnit,
  # which is font metrics — so the base font size scales the whole shell.
  sed -i \
    -e "s/^font=.*/font=Noto Sans,$ARG,-1,5,50,0,0,0,0,0/" \
    -e "s/^menuFont=.*/menuFont=Noto Sans,$ARG,-1,5,50,0,0,0,0,0/" \
    -e "s/^fixed=.*/fixed=Noto Sans Mono,$((ARG - 1)),-1,5,50,0,0,0,0,0/" \
    -e "s/^toolBarFont=.*/toolBarFont=Noto Sans,$((ARG - 1)),-1,5,50,0,0,0,0,0/" \
    -e "s/^smallestReadableFont=.*/smallestReadableFont=Noto Sans,$((ARG - 2)),-1,5,50,0,0,0,0,0/" \
    "$KG"
  grep -q '^font=' "$KG" || sed -i "/^\[General\]/a font=Noto Sans,$ARG,-1,5,50,0,0,0,0,0" "$KG"
  chown "$HTPC_USER:$HTPC_USER" "$KG"
  # Persist it so customize.sh does not put the old size back on its next run.
  if [[ -f /etc/default/tvpc ]]; then
    if grep -q '^TVPC_FONT_SIZE=' /etc/default/tvpc; then
      sed -i "s/^TVPC_FONT_SIZE=.*/TVPC_FONT_SIZE=$ARG/" /etc/default/tvpc
    else
      echo "TVPC_FONT_SIZE=$ARG" >>/etc/default/tvpc
    fi
  fi
  echo "Base font size -> $ARG (was scaling the whole Bigscreen UI)"
  echo "Recorded TVPC_FONT_SIZE=$ARG in /etc/default/tvpc"
  echo "Log out and back in, or: sudo systemctl restart sddm"
  exit 0
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  echo "== Plasma Bigscreen =="
  if pkg_installed plasma-bigscreen; then
    ok "plasma-bigscreen $(dpkg-query -W -f='${Version}' plasma-bigscreen 2>/dev/null)"
  else
    bad "plasma-bigscreen not installed"
  fi
  MISSING_QML=()
  for p in "${BIGSCREEN_QML_DEPS[@]}"; do
    pkg_installed "$p" || MISSING_QML+=("$p")
  done
  if [[ ${#MISSING_QML[@]} -eq 0 ]]; then
    ok "QML runtime modules present"
  else
    bad "missing QML modules: ${MISSING_QML[*]}"
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
if ! apt_has_candidate plasma-bigscreen; then
  echo "== Enabling the universe component =="
  if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y universe || true
  fi
  apt-get update
fi

if ! apt_has_candidate plasma-bigscreen; then
  # Show the diagnosis rather than asking for it. plasma-bigscreen lives in
  # the noble RELEASE pocket (noble/universe), not noble-updates, so having
  # universe on noble-updates alone is not enough — and that is exactly the
  # state add-apt-repository can leave behind when sources are split across
  # sources.list and a deb822 .sources file.
  echo >&2
  echo "!! No installable plasma-bigscreen." >&2
  echo >&2
  echo "   apt-cache policy says:" >&2
  apt-cache policy plasma-bigscreen 2>&1 | sed 's/^/     /' >&2
  echo >&2
  echo "   Enabled components (need 'universe' on the plain 'noble' suite," >&2
  echo "   not just noble-updates):" >&2
  {
    grep -rhs -E '^(deb|Components|Suites|URIs)' \
      /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
      | grep -v '^\s*#'
  } | sed 's/^/     /' >&2
  echo >&2
  echo "   If 'universe' is missing from the noble suite, add it:" >&2
  echo "     sudo sed -i 's/^Components: main restricted$/Components: main restricted universe multiverse/' \\" >&2
  echo "       /etc/apt/sources.list.d/ubuntu.sources" >&2
  echo "     sudo apt-get update" >&2
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

echo "== Installing the QML modules Bigscreen forgets to depend on =="
QML_HAVE=() QML_MISSING=()
for p in "${BIGSCREEN_QML_DEPS[@]}"; do
  if apt_has_candidate "$p"; then QML_HAVE+=("$p"); else QML_MISSING+=("$p"); fi
done
if [[ ${#QML_MISSING[@]} -gt 0 ]]; then
  echo "!! not available, skipping: ${QML_MISSING[*]}"
fi
if [[ ${#QML_HAVE[@]} -gt 0 ]]; then
  # Non-fatal: a missing QML module degrades a settings page, it does not
  # stop the shell coming up, and the session check below is what matters.
  apt-get install -y "${QML_HAVE[@]}" || echo "!! some QML modules failed to install"
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
