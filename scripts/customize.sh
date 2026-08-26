#!/usr/bin/env bash
# tvpc customize.sh — Idempotent tweaks you can re-run safely.
# Run from the repo root:  ./scripts/customize.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTPC_USER="${HTPC_USER:-htpc}"
echo ">> tvpc customize using repo root: $REPO_ROOT (user: $HTPC_USER)"

# --- Skel defaults (applied to any newly created user) ---
mkdir -p /etc/skel/.config

# 1. Theme: Breeze dark
cat >/etc/skel/.config/kdeglobals <<'EOF'
[General]
ColorScheme=BreezeDark
Name=Breeze Dark
widgetStyle=Breeze

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
EOF

# 2. Disable screen locking (HTPC = TV, no lockscreen)
cat >/etc/skel/.config/kscreenlockerrc <<'EOF'
[Daemon]
Autolock=false
LockGrace=0
EOF

# 3. Disable KRunner (not needed on HTPC)
cat >/etc/skel/.config/krunnerrc <<'EOF'
[General]
autoloadModules=false
EOF

# 4. Plasma Mobile UI scaling for 80" 1080p TV viewed from couch
cat >/etc/skel/.config/plasma-desktop-appletsrc <<'EOF'
[Screen Scales]
HDMI-1=1.2
EOF

# 5. Force 1920x1080@60 via kwinrules (Wayland-compatible)
cat >/etc/skel/.config/kwinrulesrc <<'EOF'
[General]
useUtility=false

[1]
description=Samsung 80 inch 1080p
fullscreen=false
geometry=true
maximize=apply
minimize=apply
monitor=HDMI-1
position=0,0
priority=1
refreshrate=60
resistlocation=false
screen=0
size=1920,1080
strictgeometry=false
types=4
zvalue=0
EOF

# 6. VacuumTube pinned to favorites (plasma-mobile homescreen)
mkdir -p /etc/skel/.local/share/plasma-mobile/favorites
cat >/etc/skel/.local/share/plasma-mobile/favorites/applications.list <<'EOF'
io.github.vacuumtube.VacuumTube.desktop
org.kde.dolphin.desktop
EOF

# 7. Autostart VacuumTube with native Wayland + VA-API HW decode
mkdir -p /etc/skel/.config/autostart
cat >/etc/skel/.config/autostart/vacuumtube.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=VacuumTube
Comment=YouTube client with hardware video decode
Exec=flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --ozone-platform=wayland --use-gl=egl
X-KDE-autostart-after=plasma-desktop
X-KDE-autostart-phase=1
EOF

# 8. Disable baloo file indexer (HTPC doesn't need search indexing)
cat >/etc/skel/.config/baloorc <<'EOF'
[Basic Settings]
Indexing-Enabled=false
EOF

# 9. Seed the existing HTPC user home (so tweaks apply now, not just to new users)
HOME_DIR=$(getent passwd "$HTPC_USER" | cut -d: -f6 || true)
if [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]]; then
  for f in .config/kdeglobals .config/kscreenlockerrc .config/krunnerrc \
           .config/plasma-desktop-appletsrc .config/kwinrulesrc \
           .config/baloorc .config/autostart/vacuumtube.desktop; do
    src="/etc/skel/$f"
    [[ -f "$src" ]] || continue
    mkdir -p "$HOME_DIR/$(dirname "$f")"
    cp "$src" "$HOME_DIR/$f"
  done
  mkdir -p "$HOME_DIR/.local/share/plasma-mobile/favorites"
  cp /etc/skel/.local/share/plasma-mobile/favorites/applications.list \
     "$HOME_DIR/.local/share/plasma-mobile/favorites/applications.list" 2>/dev/null || true
  chown -R "$HTPC_USER:$HTPC_USER" "$HOME_DIR/.config" "$HOME_DIR/.local" 2>/dev/null || true
  echo "Seeded $HOME_DIR with tvpc config"
else
  echo "Home dir for $HTPC_USER not found; skel-only (applies on next user creation)"
fi

# 10. Apply repo overlays if any new ones were added
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

echo ">> customize done. Log out/in to see changes."
