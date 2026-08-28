#!/usr/bin/env bash
# customize.sh — idempotent UI tweaks for couch use. Safe to re-run.
#   sudo ./scripts/customize.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
echo ">> tvpc customize using repo root: $REPO_ROOT (user: $HTPC_USER)"

SKEL=/etc/skel
mkdir -p "$SKEL/.config" "$SKEL/.config/autostart"

# --- Theme and 10-foot type -------------------------------------------------
# Scaling is applied at runtime by tvpc-display-setup (TVPC_SCALE); larger
# fonts are set here because they work regardless of scale and cannot take the
# display down if they are wrong.
# The base font size is the master UI scale for anything Kirigami-based:
# Kirigami.Units.gridUnit is derived from font metrics, so every margin and
# tile in the shell scales with it. 13 suits plain Plasma on a TV. Plasma
# Bigscreen is ALREADY a 10-foot UI sized around the 10pt default, so 13
# there scales it twice and the interface does not fit the screen — set
# TVPC_FONT_SIZE=10 (tvpc-bigscreen --ui-scale 10 does it for you).
FONT_SIZE="${TVPC_FONT_SIZE:-13}"
cat >"$SKEL/.config/kdeglobals" <<EOF
[General]
ColorScheme=BreezeDark
Name=Breeze Dark
widgetStyle=Breeze
font=Noto Sans,$FONT_SIZE,-1,5,50,0,0,0,0,0
fixed=Noto Sans Mono,$((FONT_SIZE - 1)),-1,5,50,0,0,0,0,0
menuFont=Noto Sans,$FONT_SIZE,-1,5,50,0,0,0,0,0
smallestReadableFont=Noto Sans,$((FONT_SIZE - 2)),-1,5,50,0,0,0,0,0
toolBarFont=Noto Sans,$((FONT_SIZE - 1)),-1,5,50,0,0,0,0,0

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
EOF

# --- No lock screen on a TV -------------------------------------------------
cat >"$SKEL/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockGrace=0
LockOnResume=false
EOF

# --- Never blank or suspend -------------------------------------------------
# Without this the TV goes black after ~5 minutes idle, which looks exactly
# like the boot failure this build was suffering from. Large idle times rather
# than 0: powerdevil treats 0 as "immediately" for some actions.
cat >"$SKEL/.config/powermanagementprofilesrc" <<'EOF'
[AC][DPMSControl]
idleTime=86400
lockBeforeTurnOff=0

[AC][DimDisplay]
idleTime=86400

[AC][SuspendSession]
idleTime=86400
suspendType=0

[AC][HandleButtonEvents]
lidAction=0
powerButtonAction=1
EOF

# --- Turn off the desktop search stack --------------------------------------
cat >"$SKEL/.config/baloorc" <<'EOF'
[Basic Settings]
Indexing-Enabled=false
EOF
cat >"$SKEL/.config/krunnerrc" <<'EOF'
[General]
FreeFloating=false
EOF

# --- KWin rules -------------------------------------------------------------
# The old rule tried to set the screen resolution here. KWin rules apply to
# windows, not outputs, so it could never have worked; the display mode is
# handled by tvpc-display-setup via kscreen-doctor. What is left is a real
# window rule: start VacuumTube fullscreen.
cat >"$SKEL/.config/kwinrulesrc" <<'EOF'
[General]
count=1
rules=tvpc-vacuumtube

[tvpc-vacuumtube]
Description=VacuumTube starts fullscreen on the TV
wmclass=vacuumtube
wmclassmatch=2
wmclasscomplete=false
fullscreen=true
fullscreenrule=3
EOF

# --- Autostart --------------------------------------------------------------
cat >"$SKEL/.config/autostart/tvpc-display-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=tvpc display setup
Comment=Apply TV scale/mode from /etc/default/tvpc
Exec=/usr/local/bin/tvpc-display-setup
X-KDE-autostart-phase=1
NoDisplay=true
EOF

cat >"$SKEL/.config/autostart/vacuumtube.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=VacuumTube
Comment=YouTube client with hardware video decode
Exec=flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --ozone-platform-hint=auto
X-KDE-autostart-phase=2
EOF

# --- Seed the live user, not just future ones -------------------------------
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6 || true)"
if [[ -n ${HOME_DIR:-} && -d $HOME_DIR ]]; then
  while IFS= read -r rel; do
    mkdir -p "$HOME_DIR/$(dirname "$rel")"
    cp "$SKEL/$rel" "$HOME_DIR/$rel"
  done < <(cd "$SKEL" && find .config -type f -printf '%p\n')
  chown -R "$HTPC_USER:$HTPC_USER" "$HOME_DIR/.config" 2>/dev/null || true
  [[ -d "$HOME_DIR/.local" ]] && chown -R "$HTPC_USER:$HTPC_USER" "$HOME_DIR/.local" 2>/dev/null || true
  echo "Seeded $HOME_DIR with tvpc config"
else
  echo "Home dir for $HTPC_USER not found; skel-only (applies on next user creation)"
fi

# Remove settings written by older versions of this script that pointed at
# keys Plasma does not read.
if [[ -n ${HOME_DIR:-} && -d $HOME_DIR ]]; then
  rm -f "$HOME_DIR/.config/plasma-desktop-appletsrc.tvpc-bak"
  if grep -q '^\[Screen Scales\]' "$HOME_DIR/.config/plasma-desktop-appletsrc" 2>/dev/null; then
    mv "$HOME_DIR/.config/plasma-desktop-appletsrc" \
       "$HOME_DIR/.config/plasma-desktop-appletsrc.tvpc-bak"
    echo "Moved aside a plasma-desktop-appletsrc containing the bogus [Screen Scales] block"
  fi
  rm -rf "$HOME_DIR/.local/share/plasma-mobile/favorites"
fi
rm -f "$SKEL/.config/plasma-desktop-appletsrc"
rm -rf "$SKEL/.local/share/plasma-mobile"

# --- Overlays ---------------------------------------------------------------
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

echo ">> customize done. Log out and back in to see the changes."
