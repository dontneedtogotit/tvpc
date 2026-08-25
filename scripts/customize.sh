#!/usr/bin/env bash
# tvpc customize.sh — Idempotent tweaks you can re-run safely.
# Run from the repo root:  ./scripts/customize.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo ">> tvpc customize using repo root: $REPO_ROOT"

apply() { cp "$1" "$2"; echo "  + $2"; }

# 1. Theme: Breeze dark + Material You accent
mkdir -p /etc/skel/.config
cat >/etc/skel/.config/kdeglobals <<'EOF'
[General]
ColorScheme=BreezeClassicDark
Name=Breeze Classic Dark
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

# 3. Custom Plasma Mobile config (large grid, no overview, 1080p UI scaling)
cat >/etc/skel/.config/plasma-org.kde.plasma.mobile.desktop-appletsrc <<'EOF'
[Containments][1]
activityId=
formfactor=2
immutability=1
lastScreen=0
location=0
plugin=org.kde.desktopcontainment

[Containments][2]
activityId=
formfactor=2
immutability=1
lastScreen=0
location=4
plugin=org.kde.plasma.mobile.homescreen

[Containments][2][Applets][3]
immutability=1
plugin=org.kde.plasma.appmenu

[Containments][2][Applets][4]
immutability=1
plugin=org.kde.plasma.taskpanel

[Containments][2][Applets][5]
immutability=1
plugin=org.kde.plasma.systemtray

[Containments][2][Applets][5][Configuration]
AppletsHidden=false
EOF

# 4. Plasma Mobile: set 1080p UI scale (text readable on 80" from couch)
cat >/etc/skel/.config/kcmoutputrc <<'EOF'
[Display_0]
Scale=1.2
Output=HDMI-1
EOF

# 5. Disable KRunner (not needed on HTPC)
cat >/etc/skel/.config/krunnerrc <<'EOF'
[General]
autoloadModules=false
EOF

# 6. VacuumTube pinned to favorites (plasma-mobile homescreen)
mkdir -p /etc/skel/.local/share/plasma-mobile/favorites
cat >/etc/skel/.local/share/plasma-mobile/favorites/applications.list <<'EOF'
io.github.vacuumtube.VacuumTube.desktop
org.kde.dolphin.desktop
org.kde.konsole.desktop
EOF

# 7. Autostart VacuumTube with HW decode flags
mkdir -p /etc/skel/.config/autostart
cat >/etc/skel/.config/autostart/vacuumtube.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=VacuumTube
Exec=flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --use-gl=egl
X-GNOME-Autostart-enabled=true
EOF

# 8. Apply repo overlays if any new ones were added
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

echo ">> customize done. Log out/in to see changes."