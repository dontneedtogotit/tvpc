#!/usr/bin/env bash
# tvpc-update.sh — bring the machine to the state this repo intends, and say
# what was already there and what was not.
#
#   sudo ./scripts/tvpc-update.sh --check    report only, change nothing
#   sudo ./scripts/tvpc-update.sh            converge, then update packages
#   sudo ./scripts/tvpc-update.sh --no-packages   converge only, no apt/flatpak
#   ./scripts/tvpc-update.sh --list          list the state items and exit
#
# How this differs from its neighbours:
#   tvpc-doctor  is the machine working right now?      (read-only, no repo)
#   tvpc-repair  it boots to a black screen, fix that   (targeted, no repo)
#   tvpc-update  is the machine where the repo says?    (converges, needs repo)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
HAVE_REPO=0
[[ -f "$REPO_ROOT/install.sh" && -d "$REPO_ROOT/overlays" ]] && HAVE_REPO=1

MODE=converge
DO_PACKAGES=1
for arg in "$@"; do
  case "$arg" in
    --check)       MODE=check ;;
    --no-packages) DO_PACKAGES=0 ;;
    --list)        MODE=list ;;
    -h|--help)     awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-htpc}"

N_OK=0 N_FIXED=0 N_FAILED=0 N_SKIPPED=0
NEEDS_REBOOT=0

# ---------------------------------------------------------------------------
# State items: id | needs-repo | description
# Each has a check_<id>; a fix_<id> is optional (without one it is report-only).
# ---------------------------------------------------------------------------
ITEMS=(
  "config|0|/etc/default/tvpc exists"
  "user|0|user '$HTPC_USER' exists, is in the right groups and can log in"
  "badfiles|0|configuration known to break the display is absent"
  "helpers|1|helper programs in /usr/local/bin match the repo"
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

if [[ $MODE == list ]]; then
  printf '%-18s %-10s %s\n' ITEM NEEDS-REPO DESCRIPTION
  for entry in "${ITEMS[@]}"; do
    IFS='|' read -r id repo desc <<<"$entry"
    printf '%-18s %-10s %s\n' "$id" "$([[ $repo == 1 ]] && echo yes || echo no)" "$desc"
  done
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0 $*)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Checks and fixes
# ---------------------------------------------------------------------------
check_config() { [[ -f /etc/default/tvpc ]]; }
fix_config() {
  if [[ $HAVE_REPO -eq 1 ]]; then
    # install.sh owns the canonical contents; it creates the file if missing.
    grep -q 'TVPC_SESSION' /etc/default/tvpc 2>/dev/null && return 0
  fi
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
  # Being in the right groups is no use if PAM will not let the account log
  # in. sp_lstchg == 0 means "must change password at next login", which
  # blocks autologin and shows up as a black screen.
  [[ "$(awk -F: -v u="$HTPC_USER" '$1 == u { print $3 }' /etc/shadow 2>/dev/null)" != 0 ]]
}
fix_user() {
  id "$HTPC_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$HTPC_USER" || return 1
  usermod -aG video,render,audio,plugdev,input "$HTPC_USER"
}

BAD_FILES=(
  /etc/X11/xorg.conf.d/20-intel.conf
  /etc/pipewire/pipewire.conf.d/90-hdmi-pin.conf
  /etc/pipewire/pipewire-pulse.d/99-htpc.conf
  /etc/systemd/system/htpc-audio.service
  /etc/sddm.conf.d/autologin.conf
  /etc/systemd/system/flatpak-user-update.timer
  /etc/systemd/system/flatpak-user-update.service
)
check_badfiles() {
  local f
  for f in "${BAD_FILES[@]}"; do [[ -e $f ]] && return 1; done
  return 0
}
fix_badfiles() {
  systemctl disable --now htpc-audio.service flatpak-user-update.timer 2>/dev/null
  rm -f "${BAD_FILES[@]}"
  rm -rf /etc/systemd/system/flatpak-user-update.timer.d
  systemctl daemon-reload
}

HELPERS=(
  "scripts/cec-tv-poweron.sh:/usr/local/bin/cec-tv-poweron.sh"
  "scripts/tvpc-controller.sh:/usr/local/bin/tvpc-controller"
  "scripts/tvpc-status.sh:/usr/local/bin/tvpc-status"
  "scripts/tvpc-cameras.sh:/usr/local/bin/tvpc-cameras"
  "scripts/tvpc-bigscreen-topbar.sh:/usr/local/bin/tvpc-bigscreen-topbar"
  "scripts/tvpc-hdmi-audio.sh:/usr/local/bin/tvpc-hdmi-audio"
  "scripts/tvpc-doctor.sh:/usr/local/bin/tvpc-doctor"
  "scripts/tvpc-repair.sh:/usr/local/bin/tvpc-repair"
  "scripts/tvpc-session.sh:/usr/local/bin/tvpc-session"
  "scripts/tvpc-update.sh:/usr/local/bin/tvpc-update"
  "scripts/tvpc-hyprland.sh:/usr/local/bin/tvpc-hyprland"
  "scripts/tvpc-bigscreen.sh:/usr/local/bin/tvpc-bigscreen"
)
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

# --- Plasma Bigscreen -------------------------------------------------------
# Archive-native, so unlike the Hyprland item this one is safe to fix
# automatically: nothing here comes from outside Ubuntu.
when_bigscreen() { [[ "${TVPC_SESSION:-}" == bigscreen || "${TVPC_SESSION:-}" == bigscreen-x11 ]]; }
check_bigscreen() {
  dpkg-query -W -f='${Status}' plasma-bigscreen 2>/dev/null \
    | grep "^install ok installed$" >/dev/null || return 1
  [[ -f /usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop ]] || return 1
  [[ -f /usr/share/xsessions/plasma-bigscreen-x11.desktop ]] || return 1
}
fix_bigscreen() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y plasma-bigscreen
}

# --- Hyprland session -------------------------------------------------------
# Only meaningful once the box has actually been switched to it; on a Plasma
# box this reports SKIP instead of nagging about a shell nobody asked for.
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
  # Deliberately does NOT add the PPA or run apt: a routine converge should
  # not reach out to a third-party archive on its own. If the compositor is
  # missing, this reports the failure and tvpc-hyprland.sh is the fix.
  command -v Hyprland >/dev/null 2>&1 || command -v hyprland >/dev/null 2>&1 || {
    echo "Hyprland is not installed — run: sudo tvpc-hyprland" >&2
    return 1
  }
  local home pair src dst
  home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  install -m 0755 "$REPO_ROOT/scripts/tvpc-hypr-menu.sh"      /usr/local/bin/tvpc-hypr-menu
  install -m 0755 "$REPO_ROOT/scripts/tvpc-hypr-autostart.sh" /usr/local/bin/tvpc-hypr-autostart
  for pair in "${HYPR_CONFIGS[@]}"; do
    src="$REPO_ROOT/${pair%%:*}"; dst="$home/${pair##*:}"
    install -d -o "$HTPC_USER" -g "$HTPC_USER" "$(dirname "$dst")"
    install -o "$HTPC_USER" -g "$HTPC_USER" -m 0644 "$src" "$dst"
  done
}

check_overlays() {
  local src rel
  while IFS= read -r src; do
    rel="${src#"$REPO_ROOT"/overlays}"
    cmp -s "$src" "$rel" || return 1
  done < <(find "$REPO_ROOT/overlays" -type f)
}
fix_overlays() {
  rsync -a --no-perms "$REPO_ROOT/overlays/" / && systemctl daemon-reload
}

check_kernel_cmdline() {
  grep -qE '\bsplash\b|i915\.enable_guc|intel_iommu=igfx_off' /proc/cmdline && return 1
  # Also catch a config that would reintroduce them on the next kernel update.
  grep -qhE '^GRUB_CMDLINE_LINUX_DEFAULT=.*(\bsplash\b|i915\.enable_guc|intel_iommu=igfx_off)' \
    /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null && return 1
  return 0
}
fix_kernel_cmdline() {
  local f
  for f in /etc/default/grub /etc/default/grub.d/*.cfg; do
    [[ -f $f ]] || continue
    sed -i -e 's/ *\bsplash\b//g' -e 's/ *i915\.enable_guc=[0-9-]*//g' \
           -e 's/ *intel_iommu=igfx_off//g' "$f"
  done
  update-grub >/dev/null 2>&1 || return 1
  NEEDS_REBOOT=1
}

check_graphical_target() { [[ "$(systemctl get-default)" == graphical.target ]]; }
fix_graphical_target()   { systemctl set-default graphical.target >/dev/null; NEEDS_REBOOT=1; }

check_sddm() { command -v sddm >/dev/null 2>&1 && systemctl is-enabled sddm >/dev/null 2>&1; }
fix_sddm() {
  command -v sddm >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y sddm || return 1
  systemctl enable sddm >/dev/null 2>&1
}

session_installed() {
  local name="$1" d
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions \
           /usr/local/share/xsessions /usr/share/xsessions; do
    [[ -f "$d/$name" ]] && return 0
  done
  return 1
}
check_autologin() {
  [[ -f /etc/sddm.conf.d/10-tvpc.conf ]] || return 1
  local s; s="$(awk -F= '/^Session=/{print $2; exit}' /etc/sddm.conf.d/10-tvpc.conf)"
  [[ -n $s ]] && session_installed "$s"
}
fix_autologin() {
  local tool=""
  for cand in "$REPO_ROOT/scripts/tvpc-session.sh" /usr/local/bin/tvpc-session; do
    [[ -x $cand ]] && { tool="$cand"; break; }
  done
  [[ -n $tool ]] || return 1
  "$tool" "${TVPC_SESSION:-auto}" >/dev/null
}

check_audio_unit() { [[ -L /etc/systemd/user/default.target.wants/tvpc-audio.service ]]; }
fix_audio_unit() {
  [[ -f /etc/systemd/user/tvpc-audio.service ]] || return 1
  systemctl --global enable tvpc-audio.service >/dev/null 2>&1
}

check_cec_poweron() { systemctl is-enabled htpc-startup.service >/dev/null 2>&1; }
fix_cec_poweron()   { systemctl enable htpc-startup.service >/dev/null 2>&1; }

check_cec_remote() {
  systemctl is-enabled ydotoold >/dev/null 2>&1 \
    && systemctl is-enabled tvpc-cec-remote >/dev/null 2>&1
}
fix_cec_remote() {
  [[ -x "$REPO_ROOT/scripts/enhance-cec.sh" ]] || return 1
  "$REPO_ROOT/scripts/enhance-cec.sh" >/dev/null 2>&1
}

check_zram()          { systemctl is-enabled zramswap >/dev/null 2>&1; }
fix_zram()            { systemctl enable --now zramswap >/dev/null 2>&1; }
check_tlp()           { systemctl is-enabled tlp >/dev/null 2>&1; }
fix_tlp()             { systemctl enable tlp >/dev/null 2>&1; }
check_flatpak_timer() { systemctl is-enabled flatpak-update.timer >/dev/null 2>&1; }
fix_flatpak_timer()   { systemctl enable --now flatpak-update.timer >/dev/null 2>&1; }

check_flathub() { flatpak remotes 2>/dev/null | grep flathub >/dev/null; }
fix_flathub()   { flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; }

check_vacuumtube() { flatpak info io.github.vacuumtube.VacuumTube >/dev/null 2>&1; }
fix_vacuumtube()   { flatpak install -y flathub io.github.vacuumtube.VacuumTube >/dev/null 2>&1; }

check_user_config() {
  local home; home="$(getent passwd "$HTPC_USER" | cut -d: -f6)"
  [[ -n $home ]] || return 1
  # powermanagementprofilesrc is the marker: it is what stops the TV blanking.
  [[ -f "$home/.config/powermanagementprofilesrc" ]]
}
fix_user_config() {
  [[ -x "$REPO_ROOT/scripts/customize.sh" ]] || return 1
  "$REPO_ROOT/scripts/customize.sh" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  echo "=== tvpc update — CHECK ONLY, nothing will be changed ==="
else
  echo "=== tvpc update ==="
fi
[[ $HAVE_REPO -eq 0 ]] && echo "(not running from a repo checkout — repo-backed items will be skipped)"
echo

for entry in "${ITEMS[@]}"; do
  IFS='|' read -r id needs_repo desc <<<"$entry"

  if [[ $needs_repo == 1 && $HAVE_REPO -eq 0 ]]; then
    printf '  SKIP   %s\n' "$desc"
    N_SKIPPED=$((N_SKIPPED+1))
    continue
  fi

  # An item may declare when_<id> to say it only applies in some
  # configurations. Without one, every item always applies.
  if declare -F "when_$id" >/dev/null && ! "when_$id" >/dev/null 2>&1; then
    printf '  SKIP   %s (not applicable)\n' "$desc"
    N_SKIPPED=$((N_SKIPPED+1))
    continue
  fi

  if "check_$id" >/dev/null 2>&1; then
    printf '  OK     %s\n' "$desc"
    N_OK=$((N_OK+1))
    continue
  fi

  if [[ $MODE == check ]]; then
    printf '  TODO   %s\n' "$desc"
    N_FAILED=$((N_FAILED+1))
    continue
  fi

  if ! declare -F "fix_$id" >/dev/null; then
    printf '  TODO   %s (no automatic fix)\n' "$desc"
    N_FAILED=$((N_FAILED+1))
    continue
  fi

  if "fix_$id" >/dev/null 2>&1 && "check_$id" >/dev/null 2>&1; then
    printf '  FIXED  %s\n' "$desc"
    N_FIXED=$((N_FIXED+1))
  else
    printf '  FAILED %s\n' "$desc"
    N_FAILED=$((N_FAILED+1))
  fi
done

# ---------------------------------------------------------------------------
# Package updates
# ---------------------------------------------------------------------------
if [[ $MODE == converge && $DO_PACKAGES -eq 1 ]]; then
  echo
  echo "== Updating packages =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get upgrade -y -qq || echo "  apt update/upgrade reported an error"
  if command -v flatpak >/dev/null 2>&1; then
    flatpak update --noninteractive --assumeyes >/dev/null 2>&1 || echo "  flatpak update reported an error"
    echo "  flatpaks up to date"
  fi
  # A new kernel means a new initramfs and command line; say so rather than
  # letting a stale cmdline surprise you weeks later.
  [[ -f /var/run/reboot-required ]] && NEEDS_REBOOT=1
fi

# ---------------------------------------------------------------------------
echo
echo "=== $N_OK already correct, $N_FIXED fixed, $N_FAILED outstanding, $N_SKIPPED skipped ==="
if [[ $N_FAILED -gt 0 ]]; then
  echo "Still outstanding — see above. For a black screen specifically:"
  echo "  sudo tvpc-repair --check"
fi
if [[ $NEEDS_REBOOT -eq 1 ]]; then
  echo "A reboot is needed for the changes to take effect:  sudo reboot"
fi
[[ $N_FAILED -eq 0 ]] && exit 0 || exit 1
