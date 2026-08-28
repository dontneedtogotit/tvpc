#!/usr/bin/env bash
# tvpc-hyprland.sh — install the Hyprland TV shell alongside the Plasma one.
#
# Hyprland is not in the Ubuntu 24.04 archive at all; it arrives via the
# cppiber PPA, which tracks upstream closely. That PPA also carries newer
# pipewire, libinput and wayland-protocols. The pin written below lets it
# supply Hyprland and its genuine dependencies while keeping the audio
# stack on Ubuntu's own packages — replacing PipeWire is how a working TV
# box stops having sound.
#
# Nothing here switches the running session. Install, then opt in:
#     sudo tvpc-session hypr        # use it
#     sudo tvpc-session plasma      # go back
#
# Usage:
#   sudo ./scripts/tvpc-hyprland.sh            install / update
#   sudo ./scripts/tvpc-hyprland.sh --check    report state, change nothing
#   sudo ./scripts/tvpc-hyprland.sh --force    also overwrite edited configs
#   sudo ./scripts/tvpc-hyprland.sh --remove   uninstall and drop the PPA
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

MODE=install
case "${1:-}" in
  --check)  MODE=check ;;
  --force)  MODE=force ;;
  --remove) MODE=remove ;;
  "")       ;;
  *) echo "Unknown option '$1' (try --help)" >&2; exit 1 ;;
esac

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PPA="ppa:cppiber/hyprland"
PPA_ORIGIN="LP-PPA-cppiber-hyprland"
PIN_FILE="/etc/apt/preferences.d/90-tvpc-hyprland"
SESSION_DESKTOP="/usr/share/wayland-sessions/tvpc-hypr.desktop"

ok()   { echo "  ok    $*"; }
bad()  { echo "  MISS  $*"; }
info() { echo "== $* =="; }

# Config sources in the repo, and where they land in the user's home.
CONFIGS=(
  "config/hypr/hyprland.lua:.config/hypr/hyprland.lua"
  "config/hypr/waybar/config.jsonc:.config/waybar/config.jsonc"
  "config/hypr/waybar/style.css:.config/waybar/style.css"
  "config/hypr/fuzzel.ini:.config/fuzzel/fuzzel.ini"
)

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  info "Hyprland session"
  if apt-cache policy 2>/dev/null | grep -q "$PPA_ORIGIN"; then ok "PPA configured"; else bad "PPA not configured"; fi
  if [[ -f $PIN_FILE ]]; then ok "apt pin present ($PIN_FILE)"; else bad "apt pin missing"; fi
  if command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1; then
    ok "Hyprland installed: $( { Hyprland --version 2>/dev/null || hyprland --version 2>/dev/null; } | head -1)"
  else
    bad "Hyprland not installed"
  fi
  for b in waybar fuzzel swaybg foot; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b"; else bad "$b"; fi
  done
  for b in tvpc-hypr-menu tvpc-hypr-autostart tvpc-hypr-session; do
    if [[ -x "/usr/local/bin/$b" ]]; then ok "/usr/local/bin/$b"; else bad "/usr/local/bin/$b"; fi
  done
  if [[ -f $SESSION_DESKTOP ]]; then ok "session file $SESSION_DESKTOP"; else bad "session file $SESSION_DESKTOP"; fi
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  if [[ -z $home ]]; then
    bad "user '$HTPC_USER' does not exist — no configs to check"
  else
    for pair in "${CONFIGS[@]}"; do
      dst="$home/${pair##*:}"
      if [[ -f $dst ]]; then ok "config $dst"; else bad "config $dst"; fi
    done
  fi
  echo
  echo "Active session: ${TVPC_SESSION:-unset}   (switch with: sudo tvpc-session hypr)"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)" >&2; exit 1; }
id "$HTPC_USER" >/dev/null 2>&1 || { echo "User '$HTPC_USER' does not exist" >&2; exit 1; }
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6)"

# ---------------------------------------------------------------------------
# --remove
# ---------------------------------------------------------------------------
if [[ $MODE == remove ]]; then
  info "Removing the Hyprland session"
  if [[ "${TVPC_SESSION:-}" == "hypr" ]]; then
    echo "!! TVPC_SESSION is still 'hypr'. Point it somewhere that exists first:"
    echo "     sudo tvpc-session plasma"
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y hyprland xdg-desktop-portal-hyprland hyprpolkitagent 2>/dev/null || true
  rm -f "$SESSION_DESKTOP" "$PIN_FILE"
  rm -f /usr/local/bin/tvpc-hypr-menu /usr/local/bin/tvpc-hypr-autostart /usr/local/bin/tvpc-hypr-session
  add-apt-repository -y --remove "$PPA" 2>/dev/null || true
  apt-get update 2>/dev/null || true
  echo "Done. The Plasma session and $HOME_DIR/.config/hypr were left alone."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. PPA + pin
# ---------------------------------------------------------------------------
info "Adding the Hyprland PPA"
export DEBIAN_FRONTEND=noninteractive

# The pin goes down BEFORE the first update/install, so the audio stack is
# never eligible to be replaced, not even for a moment.
cat >"$PIN_FILE" <<PIN
# Written by tvpc-hyprland.sh.
#
# The Hyprland PPA also ships pipewire/wireplumber builds. This box's audio
# is HDMI-only and already working on Ubuntu's packages; silently moving it
# to a PPA build is a needless way to lose sound. Everything else from the
# PPA is allowed at normal priority, including the newer libinput and
# wayland-protocols that Hyprland genuinely requires.
Package: pipewire pipewire-* libpipewire-* libspa-* wireplumber wireplumber-*
Pin: release o=$PPA_ORIGIN
Pin-Priority: -1

Package: pipewire pipewire-* libpipewire-* libspa-* wireplumber wireplumber-*
Pin: origin "ppa.launchpadcontent.net"
Pin-Priority: -1
PIN
ok "pin written to $PIN_FILE"

if apt-cache policy 2>/dev/null | grep -q "$PPA_ORIGIN"; then
  ok "PPA already configured"
else
  command -v add-apt-repository >/dev/null 2>&1 || apt-get install -y software-properties-common
  add-apt-repository -y "$PPA"
fi
apt-get update

# ---------------------------------------------------------------------------
# 2. Packages
# ---------------------------------------------------------------------------
info "Installing packages"
apt_install() {
  local want=("$@") have=() missing=() p
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then echo "!! not available, skipping: ${missing[*]}"; fi
  if [[ ${#have[@]} -gt 0 ]]; then apt-get install -y "${have[@]}"; fi
}

# Compositor and portals.
apt_install hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent
# Shell pieces: bar, launcher, background, terminal.
apt_install waybar fuzzel swaybg foot
# Fonts the bar and launcher ask for, plus the glyphs used by the modules.
apt_install fonts-noto-core fonts-noto-color-emoji fonts-font-awesome
# Volume control from the bar and the keybinds.
apt_install wireplumber pipewire-bin wl-clipboard playerctl

if ! command -v Hyprland >/dev/null 2>&1 && ! command -v hyprland >/dev/null 2>&1; then
  echo
  echo "!! Hyprland did not install. Nothing else here will help until it does."
  echo "   Check:  apt-cache policy hyprland"
  exit 1
fi
ok "Hyprland: $( { Hyprland --version 2>/dev/null || hyprland --version 2>/dev/null; } | head -1)"

# ---------------------------------------------------------------------------
# 3. Helpers and the session entry
# ---------------------------------------------------------------------------
info "Installing helpers"
install -d /usr/local/bin /usr/share/wayland-sessions
install -m 0755 "$REPO_ROOT/scripts/tvpc-hypr-menu.sh"      /usr/local/bin/tvpc-hypr-menu
install -m 0755 "$REPO_ROOT/scripts/tvpc-hypr-autostart.sh" /usr/local/bin/tvpc-hypr-autostart
ok "tvpc-hypr-menu, tvpc-hypr-autostart"

# The session is launched through a wrapper rather than Hyprland directly:
# it exports /etc/default/tvpc so the Lua config can read TVPC_SCALE and
# friends, and it keeps a log, which is the difference between "the TV is
# black" and "here is why the TV is black".
cat >/usr/local/bin/tvpc-hypr-session <<'WRAP'
#!/usr/bin/env bash
# Launch Hyprland for the tvpc TV session. Generated by tvpc-hyprland.sh.
set -u

# Export everything in /etc/default/tvpc so hyprland.lua can read TVPC_MODE,
# TVPC_SCALE and TVPC_OVERSCAN through os.getenv().
set -a
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
set +a

export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11
export XCURSOR_SIZE="${XCURSOR_SIZE:-48}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tvpc"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/hyprland.log"
# Keep one previous boot for comparison, then start clean.
[[ -f $LOG ]] && mv -f "$LOG" "$LOG.1"

BIN=""
for cand in Hyprland hyprland; do
  command -v "$cand" >/dev/null 2>&1 && { BIN="$cand"; break; }
done
if [[ -z $BIN ]]; then
  echo "tvpc: Hyprland is not installed" | tee -a "$LOG" >&2
  exit 1
fi

exec "$BIN" >>"$LOG" 2>&1
WRAP
chmod 0755 /usr/local/bin/tvpc-hypr-session
ok "tvpc-hypr-session"

cat >"$SESSION_DESKTOP" <<'DESK'
[Desktop Entry]
Name=tvpc (Hyprland)
Comment=Hyprland shell tuned for a TV and a CEC remote
Exec=/usr/local/bin/tvpc-hypr-session
TryExec=/usr/local/bin/tvpc-hypr-session
Type=Application
DesktopNames=Hyprland
DESK
ok "session file $SESSION_DESKTOP"

# ---------------------------------------------------------------------------
# 4. Seed the configs
# ---------------------------------------------------------------------------
info "Installing configuration for $HTPC_USER"
for pair in "${CONFIGS[@]}"; do
  src="$REPO_ROOT/${pair%%:*}"
  dst="$HOME_DIR/${pair##*:}"
  [[ -f $src ]] || { echo "!! missing in repo: $src"; continue; }
  install -d -o "$HTPC_USER" -g "$HTPC_USER" "$(dirname "$dst")"
  if [[ -f $dst ]] && ! cmp -s "$src" "$dst"; then
    if [[ $MODE == force ]]; then
      cp -a "$dst" "$dst.bak"
      install -o "$HTPC_USER" -g "$HTPC_USER" -m 0644 "$src" "$dst"
      ok "$dst (replaced, previous kept as $dst.bak)"
    else
      echo "  keep  $dst differs from the repo — left alone (--force to replace)"
    fi
  else
    install -o "$HTPC_USER" -g "$HTPC_USER" -m 0644 "$src" "$dst"
    ok "$dst"
  fi
done

# ---------------------------------------------------------------------------
# 5. What to do next
# ---------------------------------------------------------------------------
cat <<NEXT

Installed. The running session has not been changed.

  Try it:      sudo tvpc-session hypr && sudo systemctl restart sddm
  Go back:     sudo tvpc-session plasma && sudo systemctl restart sddm
  If it fails: $HOME_DIR/.local/state/tvpc/hyprland.log
               sudo tvpc-repair --check

On the remote: the menu button opens the launcher. Arrows, OK and Back are
left to whatever app is on screen, so YouTube still navigates normally.
NEXT
