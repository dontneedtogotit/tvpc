#!/usr/bin/env bash
# tvpc customize.sh — Idempotent tweaks you can re-run safely.
# Run from the repo root:  ./scripts/customize.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo ">> tvpc customize using repo root: $REPO_ROOT"

# 1. Theme: Breeze dark
mkdir -p /etc/skel/.config
cat >/etc/skel/.config/kdeglobals <<'EOF'
[General]
ColorScheme=BreezeDark
Name=Breeze Dark
widgetStyle=Breeze

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
EOF

# 2. Disable screen locking (HTPC = TV, no lockscreen)
mkdir -p /etc/skel/.config
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
#    Use Wayland-native scale factor via Plasma's config, not kcmoutputrc (X11 only)
cat >/etc/skel/.config/plasma-desktop-appletsrc <<'EOF'
[Screen Scales]
HDMI-1=1.2
EOF

# 5. Force 1920x1080@60 resolution via kwinrules (Wayland-compatible)
mkdir -p /etc/skel/.config
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

# 7. Autostart VacuumTube with HW decode (VA-API via PipeWire/VAAPI)
mkdir -p /etc/skel/.config/autostart
cat >/etc/skel/.config/autostart/vacuumtube.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=VacuumTube
Comment=YouTube client with hardware video decode
Exec=flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder
X-KDE-autostart-after=plasma-desktop
X-KDE-autostart-phase=1
EOF

# 8. Disable baloo file indexer (HTPC doesn't need search indexing)
cat >/etc/skel/.config/baloorc <<'EOF'
[Basic Settings]
Indexing-Enabled=false
EOF

# 9. Apply repo overlays if any new ones were added
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

echo ">> customize done. Log out/in to see changes."