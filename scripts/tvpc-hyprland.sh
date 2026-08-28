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
  rm -f "$SESSION_DESKTOP"
  rm -f /usr/local/bin/tvpc-hypr-menu /usr/local/bin/tvpc-hypr-autostart /usr/local/bin/tvpc-hypr-session

  # ppa-purge is the right tool: it disables the PPA and puts every package
  # that came from it back to the Ubuntu version. Plain "apt purge" would
  # leave any upgraded shared libraries behind at their PPA versions.
  if apt-get install -y ppa-purge >/dev/null 2>&1 && command -v ppa-purge >/dev/null 2>&1; then
    echo "  reverting PPA packages with ppa-purge (this downgrades, and takes a minute)"
    ppa-purge -y "$PPA" || echo "  !! ppa-purge reported an error — check 'apt list --installed | grep ppa1'"
  else
    echo "  !! ppa-purge unavailable; falling back to a plain purge."
    echo "     Anything the PPA upgraded stays at its PPA version. Check:"
    echo "       apt list --installed | grep ppa1"
    apt-get purge -y hyprland xdg-desktop-portal-hyprland hyprpolkitagent 2>/dev/null || true
    add-apt-repository -y --remove "$PPA" 2>/dev/null || true
  fi
  rm -f "$PIN_FILE"
  apt-get update -qq 2>/dev/null || true
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
# The whole PPA sits at priority 100, NOT the default 500. That single
# number is what keeps a working Plasma box working:
#
#   * A package that exists only in the PPA (hyprland, hyprutils,
#     aquamarine, hyprlang...) still installs — nothing in the archive
#     competes with it.
#   * A package already installed from Ubuntu (libinput, libxkbcommon,
#     spdlog, wayland-protocols, and everything Plasma and SDDM link
#     against) is NOT silently upgraded to the PPA's build.
#
# If Hyprland genuinely needs a newer core library than noble ships, apt
# now reports an unmet dependency and installs nothing. That is the right
# failure: a clean "no" beats half-upgrading the libraries underneath a
# running desktop, which is how this box ended up at a black screen.
Package: *
Pin: release o=$PPA_ORIGIN
Pin-Priority: 100

# The audio stack is never taken from any PPA, at any priority.
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
# Returns apt-get's exit status. The earlier version threw it away, so a
# failed install looked identical to a successful one and the script kept
# running more transactions against the PPA.
apt_install() {
  local want=("$@") have=() missing=() p
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then echo "!! not available, skipping: ${missing[*]}"; fi
  if [[ ${#have[@]} -eq 0 ]]; then return 0; fi
  apt-get install -y "${have[@]}"
}

# Back out the PPA and the pin, leaving the box exactly as it was found.
# Called when Hyprland cannot be installed — there is no reason to leave a
# third-party archive configured on an appliance that is not using it.
abandon() {
  echo
  echo "!! $1"
  echo "   Removing the PPA again so nothing is left half-applied."
  add-apt-repository -y --remove "$PPA" >/dev/null 2>&1 || true
  rm -f "$PIN_FILE"
  apt-get update -qq 2>/dev/null || true
  echo
  echo "   Nothing was installed. The current session is untouched."
  echo "   If the desktop is already broken, revert any PPA packages with:"
  echo "     sudo apt-get install -y ppa-purge && sudo ppa-purge $PPA"
  exit 1
}

# Hyprland goes in FIRST and ALONE, and nothing else is attempted until it
# is confirmed present. The earlier version installed the bar, launcher and
# fonts before checking, so a failed Hyprland still dragged PPA builds of
# shared libraries onto a working Plasma system — all of the risk, none of
# the compositor.
if ! apt-cache policy hyprland 2>/dev/null | grep -q 'Candidate: [^(]'; then
  abandon "The PPA offers no installable 'hyprland' for this release."
fi

if ! apt_install hyprland; then
  abandon "apt could not install hyprland (see the error above)."
fi
if ! command -v Hyprland >/dev/null 2>&1 && ! command -v hyprland >/dev/null 2>&1; then
  abandon "hyprland reported success but no Hyprland binary is on PATH."
fi
ok "Hyprland: $( { Hyprland --version 2>/dev/null || hyprland --version 2>/dev/null; } | head -1)"

# Only now is it worth pulling in the rest. These are individually
# non-fatal: a missing font or portal is a blemish, not a black screen.
apt_install xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent || true
apt_install waybar fuzzel swaybg foot || true
apt_install fonts-noto-core fonts-noto-color-emoji fonts-font-awesome || true
apt_install wl-clipboard playerctl || true

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
