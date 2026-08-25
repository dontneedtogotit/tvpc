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

# 3. Custom Plasma Mobile config (large grid, no overview)
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
EOF

# 4. Apply repo overlays if any new ones were added
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a "$REPO_ROOT/overlays/" /
fi

echo ">> customize done. Log out/in to see changes."
