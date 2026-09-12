#!/usr/bin/env bash
# install.sh — Unified HTPC installer and updater for Ubuntu 24.04
# Target: Intel NUC7i5BNH (Core i5-7260U "Kaby Lake", Iris Plus 640)
#         + 2013 Samsung ~80" TV over HDMI
# Repo: https://github.com/dontneedtogotit/tvpc
#
# Usage:
#   sudo ./install.sh                     Full system installation / setup
#   sudo ./install.sh --update            Converge system state + update packages
#   sudo ./install.sh --no-packages       Converge system state only (no apt/flatpak)
#   ./install.sh --check                  Report convergence state (read-only)
#   ./install.sh --list                   List convergence items and exit
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
MODE="install"
DO_PACKAGES=1

for arg in "$@"; do
  case "$arg" in
    --update|-u)    MODE="update" ;;
    --check)        MODE="check" ;;
    --no-packages)  MODE="update"; DO_PACKAGES=0 ;;
    --list)         MODE="list" ;;
    --install)      MODE="install" ;;
    -h|--help|help)
      awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-htpc}"

# ---------------------------------------------------------------------------
# Helper lists & State Items
# ---------------------------------------------------------------------------
HELPERS=(
  "scripts/tvpc-cec.sh:/usr/local/bin/tvpc-cec"
  "scripts/cec-tv-poweron.sh:/usr/local/bin/cec-tv-poweron.sh"
  "scripts/enhance-cec.sh:/usr/local/bin/tvpc-cec-setup"
  "scripts/tvpc-hdmi-audio.sh:/usr/local/bin/tvpc-hdmi-audio"
  "scripts/tvpc-doctor.sh:/usr/local/bin/tvpc-doctor"
  "scripts/tvpc-repair.sh:/usr/local/bin/tvpc-repair"
  "scripts/tvpc-session.sh:/usr/local/bin/tvpc-session"
  "scripts/tvpc-update.sh:/usr/local/bin/tvpc-update"
  "scripts/tvpc-bigscreen.sh:/usr/local/bin/tvpc-bigscreen"
  "scripts/tvpc-bigscreen-theme.sh:/usr/local/bin/tvpc-bigscreen-theme"
  "scripts/tvpc-hyprland.sh:/usr/local/bin/tvpc-hyprland"
  "scripts/tvpc-tweaks.sh:/usr/local/bin/tvpc-tweaks"
  "scripts/tvpc-controller.sh:/usr/local/bin/tvpc-controller"
  "scripts/tvpc-status.sh:/usr/local/bin/tvpc-status"
  "scripts/tvpc-cameras.sh:/usr/local/bin/tvpc-cameras"
  "scripts/tvpc-cameras-gui.sh:/usr/local/bin/tvpc-cameras-gui"
  "scripts/tvpc-power.sh:/usr/local/bin/tvpc-power"
  "scripts/tvpc-allapps.sh:/usr/local/bin/tvpc-allapps"
  "scripts/tvpc-setup-gui.sh:/usr/local/bin/tvpc-setup-gui"
  "scripts/tvpc-update-gui.sh:/usr/local/bin/tvpc-update-gui"
  "scripts/tvpc-vacuumtube-scroll.sh:/usr/local/bin/tvpc-vacuumtube-scroll"
)

PKG_DIR="tvpc_cameras_gui"
PKG_DST="/usr/local/lib/python3/dist-packages/tvpc_cameras_gui"

BAD_FILES=(
  /etc/X11/xorg.conf.d/20-intel.conf
  /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf
  /etc/pipewire/pipewire-pulse.d/99-htpc.conf
  /etc/systemd/system/htpc-audio.service
  /etc/sddm.conf.d/autologin.conf
  /etc/systemd/system/flatpak-user-update.timer
  /etc/systemd/system/flatpak-user-update.service
)

ITEMS=(
  "config|0|/etc/default/tvpc exists"
  "user|0|user '$HTPC_USER' exists, is in the right groups and can log in"
  "badfiles|0|configuration known to break the display is absent"
  "helpers|1|helper programs in /usr/local/bin match the repo"
  "cameras_gui|1|tvpc_cameras_gui Python package matches the repo"
  "overlays|1|files under overlays/ are applied to /"
  "kernel_cmdline|0|kernel command line has no splash or Broadwell-era flags"
  "graphical_target|0|default systemd target is graphical.target"
  "sddm|0|sddm is installed and enabled"
  "autologin|0|autologin points at a session that exists"
  "audio_unit|0|tvpc-audio user service is enabled"
  "cec_poweron|0|htpc-startup (TV power-on) is enabled"
  "cec_remote|0|CEC remote listener and ydotoold are enabled"
  "zram|0|zram swap is enabled"
  "tlp|0|TLP is enabled"
  "flatpak_timer|0|weekly flatpak update timer is enabled"
  "flathub|0|flathub remote is configured"
  "vacuumtube|0|VacuumTube is installed"
  "user_config|0|the TV user's Plasma config is seeded"
  "bigscreen|0|Plasma Bigscreen is installed with its session files"
  "hypr|1|Hyprland session files match the repo"
)

# ---------------------------------------------------------------------------
# Mode: List
# ---------------------------------------------------------------------------
if [[ $MODE == "list" ]]; then
  printf '%-18s %-10s %s
' ITEM NEEDS-REPO DESCRIPTION
  for entry in "${ITEMS[@]}"; do
    IFS='|' read -r id repo desc <<<"$entry"
    printf '%-18s %-10s %s
' "$id" "$([[ $repo == 1 ]] && echo yes || echo no)" "$desc"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Convergence checks and fixes
# ---------------------------------------------------------------------------
check_config() { [[ -f /etc/default/tvpc ]]; }
fix_config() {
  grep -q 'TVPC_SESSION' /etc/default/tvpc 2>/dev/null && return 0
  cat >/etc/default/tvpc <<'EOF'
TVPC_USER=htpc
TVPC_SESSION=auto
TVPC_SCALE=1.5
TVPC_MODE=
TVPC_INSTALL_PLASMA_MOBILE=0
TVPC_WIRED_ONLY=0
EOF
}

check_user() {
  id "$HTPC_USER" >/dev/null 2>&1 || return 1
  local g
  for g in video render audio input; do
    id -nG "$HTPC_USER" | grep -w "$g" >/dev/null || return 1
  done
  [[ "$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)" != 0 ]]
}
fix_user() {
  id "$HTPC_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$HTPC_USER" || return 1
  usermod -aG video,render,audio,plugdev,input "$HTPC_USER"
}

check_badfiles() {
  local f
  for f in "${BAD_FILES[@]}"; do [[ -e $f ]] && return 1; done
  return 0
}
fix_badfiles() {
  systemctl disable --now htpc-audio.service flatpak-user-update.timer 2>/dev/null || true
  rm -f "${BAD_FILES[@]}"
  rm -rf /etc/systemd/system/flatpak-user-update.timer.d
  systemctl daemon-reload
}

check_helpers() {
  local pair src dst
  for pair in "${HELPERS[@]}"; do
    src="$REPO_ROOT/${pair%%:*}"; dst="${pair##*:}"
    [[ -f $src ]] || continue
    cmp -s "$src" "$dst" || return 1
  done
}
fix_helpers() {
  local pair src dst
  for pair in "${HELPERS[@]}"; do
    src="$REPO_ROOT/${pair%%:*}"; dst="${pair##*:}"
    [[ -f $src ]] && install -D -m 0755 "$src" "$dst"
  done
}

check_cameras_gui() {
  [[ -d "$REPO_ROOT/$PKG_DIR" ]] || return 0
  [[ -d "$PKG_DST" ]] || return 1
  local f
  while IFS= read -r f; do
    cmp -s "$REPO_ROOT/$f" "$PKG_DST/${f#"$PKG_DIR/"}" || return 1
  done < <(find "$REPO_ROOT/$PKG_DIR" -type f -name "*.py")
  return 0
}
fix_cameras_gui() {
  [[ -d "$REPO_ROOT/$PKG_DIR" ]] || return 0
  install -d "$PKG_DST"
  cp -r "$REPO_ROOT/$PKG_DIR"/. "$PKG_DST"/
  find "$PKG_DST" -type f -name "*.py" -exec chmod 0644 {} +
}

when_bigscreen() { [[ "${TVPC_SESSION:-}" == bigscreen || "${TVPC_SESSION:-}" == bigscreen-x11 ]]; }
check_bigscreen() {
  dpkg-query -W -f='${Status}' plasma-bigscreen 2>/dev/null     | grep "^install ok installed$" >/dev/null || return 1
  [[ -f /usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop ]] || return 1
  [[ -f /usr/share/xsessions/plasma-bigscreen-x11.desktop ]] || return 1
}
fix_bigscreen() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y plasma-bigscreen
}

HYPR_CONFIGS=(
  "config/hypr/hyprland.lua:.config/hypr/hyprland.lua"
  "config/hypr/waybar/config.jsonc:.config/waybar/config.jsonc"
  "config/hypr/waybar/style.css:.config/waybar/style.css"
  "config/hypr/fuzzel.ini:.config/fuzzel/fuzzel.ini"
)
when_hypr() { [[ "${TVPC_SESSION:-}" == "hypr" ]]; }
check_hypr() {
  command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1 || return 1
  [[ -f /usr/share/wayland-sessions/tvpc-hypr.desktop ]] || return 1
  [[ -x /usr/local/bin/tvpc-hypr-session   ]] || return 1
  [[ -x /usr/local/bin/tvpc-hypr-menu      ]] || return 1
  [[ -x /usr/local/bin/tvpc-hypr-autostart ]] || return 1
  local home pair
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  [[ -n $home ]] || return 1
  for pair in "${HYPR_CONFIGS[@]}"; do
    cmp -s "$REPO_ROOT/${pair%%:*}" "$home/${pair##*:}" || return 1
  done
}
fix_hypr() {
  command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1 || {
    echo "Hyprland is not installed. Run: sudo ./scripts/tvpc-hyprland.sh" >&2
    return 1
  }
  local home pair src dst
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  for pair in "${HYPR_CONFIGS[@]}"; do
    src="$REPO_ROOT/${pair%%:*}"; dst="$home/${pair##*:}"
    if [[ -f $src ]]; then
      mkdir -p "$(dirname "$dst")"
      install -m 0644 "$src" "$dst"
      chown "$HTPC_USER:$HTPC_USER" "$dst"
    fi
  done
}

check_overlays() {
  [[ -d "$REPO_ROOT/overlays" ]] || return 0
  local f rel
  while IFS= read -r f; do
    rel="${f#"$REPO_ROOT/overlays/"}"
    [[ -e "/$rel" ]] || return 1
    cmp -s "$f" "/$rel" || return 1
  done < <(find "$REPO_ROOT/overlays" -type f)
  return 0
}
fix_overlays() {
  [[ -d "$REPO_ROOT/overlays" ]] || return 0
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
}

check_kernel_cmdline() {
  ! grep -q 'i915\.enable_guc\|intel_iommu=igfx_off\|splash' /etc/default/grub 2>/dev/null
}
fix_kernel_cmdline() {
  sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g'          -e 's/ *intel_iommu=igfx_off//g'          -e 's/ *splash//g' /etc/default/grub
  update-grub
}

check_graphical_target() { [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]]; }
fix_graphical_target() { systemctl set-default graphical.target; }

check_sddm() {
  command -v sddm >/dev/null 2>&1 || return 1
  systemctl is-enabled sddm >/dev/null 2>&1
}
fix_sddm() {
  dpkg-query -W -f='${Status}' sddm 2>/dev/null | grep "^install ok installed$" >/dev/null || {
    DEBIAN_FRONTEND=noninteractive apt-get install -y sddm sddm-theme-breeze
  }
  systemctl enable sddm
}

check_autologin() {
  [[ -f /etc/sddm.conf.d/10-tvpc.conf ]] || return 1
  local s
  s="$(awk -F= '/^Session=/{print $2}' /etc/sddm.conf.d/10-tvpc.conf 2>/dev/null || true)"
  [[ -n $s ]] || return 1
  local d
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions            /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$s" || -f "$d/$s.desktop" ]] && return 0
  done
  return 1
}
fix_autologin() {
  "$REPO_ROOT/scripts/tvpc-session.sh" "${TVPC_SESSION:-auto}"
}

check_audio_unit() {
  systemctl --global is-enabled tvpc-audio.service >/dev/null 2>&1
}
fix_audio_unit() {
  systemctl --global enable tvpc-audio.service 2>/dev/null || true
}

check_cec_poweron() {
  systemctl is-enabled htpc-startup.service >/dev/null 2>&1
}
fix_cec_poweron() {
  systemctl enable htpc-startup.service
}

check_cec_remote() {
  systemctl is-enabled ydotoold.service >/dev/null 2>&1 || return 1
  systemctl is-enabled tvpc-cec-remote.service >/dev/null 2>&1
}
fix_cec_remote() {
  "$REPO_ROOT/scripts/tvpc-cec.sh" setup >/dev/null 2>&1
}

check_zram() { systemctl is-enabled zramswap >/dev/null 2>&1; }
fix_zram() {
  dpkg-query -W -f='${Status}' zram-tools 2>/dev/null | grep "^install ok installed$" >/dev/null || {
    DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools
  }
  cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  systemctl enable --now zramswap 2>/dev/null || true
}

check_tlp() { systemctl is-enabled tlp.service >/dev/null 2>&1; }
fix_tlp() { systemctl enable --now tlp.service 2>/dev/null || true; }

check_flatpak_timer() { systemctl is-enabled flatpak-update.timer >/dev/null 2>&1; }
fix_flatpak_timer() {
  cat >/etc/systemd/system/flatpak-update.service <<'EOF'
[Unit]
Description=Update Flatpak applications
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --noninteractive --assumeyes
EOF
  cat >/etc/systemd/system/flatpak-update.timer <<'EOF'
[Unit]
Description=Weekly Flatpak update

[Timer]
OnCalendar=Sun 04:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now flatpak-update.timer
}

check_flathub() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak remotes 2>/dev/null | grep -q '^flathub'
}
fix_flathub() {
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

check_vacuumtube() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak info io.github.vacuumtube.VacuumTube >/dev/null 2>&1
}
fix_vacuumtube() {
  flatpak install -y flathub io.github.vacuumtube.VacuumTube
}

check_user_config() {
  local home
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  [[ -n $home && -d $home ]] || return 1
  for f in kdeglobals kscreenlockerrc powermanagementprofilesrc baloorc; do
    [[ -f "$home/.config/$f" ]] || return 1
  done
}
fix_user_config() {
  "$REPO_ROOT/scripts/customize.sh" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Mode: Check / Update
# ---------------------------------------------------------------------------
if [[ $MODE == "check" || $MODE == "update" ]]; then
  if [[ $MODE == "update" && $EUID -ne 0 ]]; then
    echo "Run as root (sudo ./install.sh --update)" >&2
    exit 1
  fi

  echo "=== tvpc $( [[ $MODE == check ]] && echo "state check" || echo "update" ) ==="
  N_OK=0 N_FIXED=0 N_FAILED=0 N_SKIPPED=0

  for entry in "${ITEMS[@]}"; do
    IFS='|' read -r id repo desc <<<"$entry"
    if declare -F "when_$id" >/dev/null; then
      if ! "when_$id"; then
        printf '  %-6s %-16s %s
' "SKIP" "$id" "$desc"
        N_SKIPPED=$((N_SKIPPED + 1))
        continue
      fi
    fi

    if "check_$id"; then
      printf '  %-6s %-16s %s
' "OK" "$id" "$desc"
      N_OK=$((N_OK + 1))
    else
      if [[ $MODE == check ]]; then
        printf '  %-6s %-16s %s
' "MISS" "$id" "$desc"
        N_FAILED=$((N_FAILED + 1))
      else
        if declare -F "fix_$id" >/dev/null; then
          printf '  fixing %s... ' "$id"
          if "fix_$id" >/dev/null 2>&1 && "check_$id"; then
            echo "OK"
            N_FIXED=$((N_FIXED + 1))
          else
            echo "FAILED"
            N_FAILED=$((N_FAILED + 1))
          fi
        else
          printf '  %-6s %-16s %s (manual fix needed)
' "MISS" "$id" "$desc"
          N_FAILED=$((N_FAILED + 1))
        fi
      fi
    fi
  done

  if [[ $MODE == "update" && $DO_PACKAGES -eq 1 ]]; then
    echo
    echo "== Updating packages (apt & flatpak) =="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    if command -v flatpak >/dev/null 2>&1; then
      flatpak update --noninteractive --assumeyes || true
    fi
  fi

  echo
  printf 'Summary: %d OK, %d fixed, %d failed, %d skipped
' "$N_OK" "$N_FIXED" "$N_FAILED" "$N_SKIPPED"
  [[ $N_FAILED -eq 0 ]] && exit 0 || exit 1
fi

# ---------------------------------------------------------------------------
# Mode: Full Installation
# ---------------------------------------------------------------------------
LOG="/var/log/tvpc-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== tvpc installer started $(date) ==="

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo ./install.sh)"
  exit 1
fi

install -d /etc/tvpc
printf '%s
' "$REPO_ROOT" >/etc/tvpc/repo.path

# 1. Configuration
if [[ ! -f /etc/default/tvpc ]]; then
  cat >/etc/default/tvpc <<'EOF'
# tvpc appliance settings — sourced by the tvpc scripts.
TVPC_USER=htpc
TVPC_SESSION=auto
TVPC_SCALE=1.5
TVPC_MODE=
TVPC_INSTALL_PLASMA_MOBILE=0
TVPC_WIRED_ONLY=0
EOF
  echo "Wrote /etc/default/tvpc"
fi
# shellcheck source=/dev/null
. /etc/default/tvpc
HTPC_USER="${TVPC_USER:-htpc}"

# 2. Packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

apt_install() {
  local want=("$@") have=() missing=()
  local p
  for p in "${want[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then echo "!! not available, skipping: ${missing[*]}"; fi
  if [[ ${#have[@]} -gt 0 ]]; then apt-get install -y "${have[@]}"; fi
}

apt_install   sddm sddm-theme-breeze   plasma-workspace plasma-workspace-wayland plasma-desktop kwin-wayland   plasma-nm plasma-pa powerdevil kscreen systemsettings kde-cli-tools   breeze breeze-icon-theme qtwayland5   xwayland xserver-xorg-core xserver-xorg-input-libinput

apt_install pipewire pipewire-pulse pipewire-alsa wireplumber pulseaudio-utils

apt_install intel-media-va-driver i965-va-driver mesa-va-drivers   libva2 libva-drm2 vainfo

apt_install cec-utils libcec6 playerctl ydotool ydotoold

apt_install flatpak software-properties-common openssh-server network-manager   tlp powertop zram-tools i2c-tools unattended-upgrades   curl wget git rsync pavucontrol vim htop

apt_install python3-pyside6 ffmpeg mpv

if [[ "${TVPC_INSTALL_PLASMA_MOBILE:-0}" == "1" || "${TVPC_SESSION:-auto}" == "plasma-mobile" ]]; then
  echo "== Installing Plasma Mobile (opt-in) =="
  apt_install plasma-mobile plasma-nano
fi

systemctl enable --now ssh 2>/dev/null || true

# 3. Clear known-bad configuration
echo "== Clearing known-bad configuration from previous installs =="
rm -f "${BAD_FILES[@]}"
systemctl daemon-reload

# 4. Flatpak + VacuumTube
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub io.github.vacuumtube.VacuumTube ||   echo "!! VacuumTube install failed (no network?) — rerun: flatpak install flathub io.github.vacuumtube.VacuumTube"

# 5. HTPC user
if ! id "$HTPC_USER" &>/dev/null; then
  useradd -m -G video,render,audio,plugdev,input -s /bin/bash "$HTPC_USER"
  echo "$HTPC_USER:htpc" | chpasswd
  echo "Created user $HTPC_USER (password: htpc — change it!)"
else
  usermod -aG video,render,audio,plugdev,input "$HTPC_USER"
fi

# 6. Overlays, then GRUB
if [[ -d "$REPO_ROOT/overlays" ]]; then
  rsync -a --no-perms "$REPO_ROOT/overlays/" /
  echo "Applied repo overlays from $REPO_ROOT/overlays"
fi

if grep -q 'i915.enable_guc\|intel_iommu=igfx_off' /etc/default/grub 2>/dev/null; then
  sed -i -e 's/ *i915\.enable_guc=[0-9-]*//g' -e 's/ *intel_iommu=igfx_off//g' /etc/default/grub
  echo "Removed stale i915/IOMMU kernel parameters from /etc/default/grub"
fi
update-grub

# 7. Helper programs and Desktop files
for pair in "${HELPERS[@]}"; do
  src="$REPO_ROOT/${pair%%:*}"; dst="${pair##*:}"
  [[ -f $src ]] && install -D -m 0755 "$src" "$dst"
done

# Python GUI package
if [[ -d "$REPO_ROOT/tvpc_cameras_gui" ]]; then
  install -d /usr/local/lib/python3/dist-packages
  cp -r "$REPO_ROOT/tvpc_cameras_gui" /usr/local/lib/python3/dist-packages/
  find /usr/local/lib/python3/dist-packages/tvpc_cameras_gui -type f -name "*.py" -exec chmod 0644 {} +
fi

# Desktop tiles
cat >/usr/share/applications/tvpc-power.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Power
Comment=Restart, shut down, or log out
Exec=/usr/local/bin/tvpc-power
Terminal=false
Icon=system-shutdown
Categories=Settings;
Keywords=tvpc;power;
EOF

cat >/usr/share/applications/tvpc-setup.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Setup
Comment=Gamepad, HDMI-CEC, Anynet+, and TV power-on
Exec=/usr/local/bin/tvpc-setup-gui
Terminal=false
Icon=preferences-system-network
Categories=Settings;
Keywords=tvpc;setup;gamepad;cec;anynet;bluetooth;
EOF

cat >/usr/share/applications/tvpc-update.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Update
Comment=Apply tvpc updates (repo, packages, flatpaks)
Exec=/usr/local/bin/tvpc-update-gui
Terminal=false
Icon=software-update-available
Categories=Settings;
Keywords=tvpc;update;upgrade;apt;flatpak;
EOF

cat >/usr/share/applications/tvpc-allapps.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=All Apps
Comment=Browse every installed application
Exec=/usr/local/bin/tvpc-allapps
Terminal=false
Icon=view-grid
Categories=Settings;
Keywords=tvpc;apps;
EOF

# 8. Hardware, Power, and Audio Extras
mkdir -p /etc/tlp.d
cat >/etc/tlp.d/99-tvpc.conf <<'EOF'
TLP_DEFAULT_MODE=AC
TLP_PERSISTENT_DEFAULT=1
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
SOUND_POWER_SAVE_ON_AC=0
EOF

if command -v nmcli >/dev/null 2>&1; then
  if [[ "${TVPC_WIRED_ONLY:-0}" == "1" ]]; then
    nmcli radio wifi off 2>/dev/null || true
  else
    nmcli radio wifi on 2>/dev/null || true
  fi
fi

mkdir -p /usr/local/bin
cat >/usr/local/bin/htpc-volume-step <<'EOF'
#!/usr/bin/env bash
pactl set-sink-volume @DEFAULT_SINK@ "${1:-+2}%"
EOF
chmod 0755 /usr/local/bin/htpc-volume-step

mkdir -p /var/lib/flatpak/overrides
cat >/var/lib/flatpak/overrides/global <<'EOF'
[Context]
devices=dri
sockets=wayland;fallback-x11;pulseaudio;
filesystems=xdg-videos:ro;xdg-music:ro;xdg-pictures:ro;
EOF

# 9. Session + autologin
"$REPO_ROOT/scripts/tvpc-session.sh" "${TVPC_SESSION:-auto}"

# 10. Audio: HDMI selection inside the user session
systemctl --global enable tvpc-audio.service 2>/dev/null || true

# 11. CEC: power on the TV and setup remote listener
cat >/etc/systemd/system/htpc-startup.service <<'EOF'
[Unit]
Description=Power on Samsung TV via CEC and switch input
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cec-tv-poweron.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable htpc-startup.service

"$REPO_ROOT/scripts/tvpc-cec.sh" setup || echo "!! CEC setup reported non-critical warning (continuing)"

# 12. Power, swap, indexers
systemctl enable tlp.service 2>/dev/null || true
powertop --auto-tune >/dev/null 2>&1 || true

cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable --now zramswap 2>/dev/null || true

for unit in tracker-miner-fs-3.service tracker-store.service; do
  systemctl disable --now "$unit" 2>/dev/null || true
  systemctl mask "$unit" 2>/dev/null || true
done

# 13. Maintenance
dpkg-reconfigure -f noninteractive unattended-upgrades || true
fix_flatpak_timer

# 14. UI Customization
"$REPO_ROOT/scripts/customize.sh" || echo "!! customize reported an error (continuing)"

# 15. Verification
echo
echo "=== Pre-reboot verification ==="
PROBLEMS=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  OK    $1"; else echo "  FAIL  $1"; PROBLEMS=$((PROBLEMS+1)); fi; }

check "sddm installed"                 "command -v sddm"
check "sddm enabled"                   "systemctl is-enabled sddm"
check "default target is graphical"    "[[ \$(systemctl get-default) == graphical.target ]]"
check "autologin config written"       "[[ -f /etc/sddm.conf.d/10-tvpc.conf ]]"
check "user $HTPC_USER exists"         "id $HTPC_USER"
check "no stale Xorg intel config"     "[[ ! -f /etc/X11/xorg.conf.d/20-intel.conf ]]"

session_installed() {
  local name="$1" d
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions            /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$name" ]] && return 0
  done
  return 1
}

SESSION_NAME="$(awk -F= '/^Session=/{print $2}' /etc/sddm.conf.d/10-tvpc.conf 2>/dev/null || true)"
if [[ -n $SESSION_NAME ]] && session_installed "$SESSION_NAME"; then
  echo "  OK    session file present ($SESSION_NAME)"
else
  echo "  FAIL  session file missing ($SESSION_NAME)"
  PROBLEMS=$((PROBLEMS+1))
fi

echo
echo "=== tvpc installer finished $(date) ==="
if [[ $PROBLEMS -gt 0 ]]; then
  echo "$PROBLEMS check(s) failed — fix these before rebooting."
  exit 1
fi

echo "All checks passed. Reboot:  sudo reboot"
echo "Keep it in shape:         sudo ./install.sh --update"
