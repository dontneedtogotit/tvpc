#!/usr/bin/env bash
# tvpc-display-setup-extras — EDID detection, HDR toggle, UI density
#
# One-shot commands accessible via tvpc-tweaks:
#   tvpc-tweaks edid            detect connected display and set preferred mode/scale
#   tvpc-tweaks hdr on|off      toggle HDR (requires kscreen-doctor)
#   tvpc-tweaks density comfortable|normal|compact   UI density
#
# These rely on Plasma's kscreen-doctor for HDR; other features are best-effort.
set -uo pipefail

# Reusable helpers from tvpc-tweaks.sh (copied here to avoid sourcing)
target_home() {
  if [[ $EUID -eq 0 ]]; then
    getent passwd "${TVPC_USER:-${HTPC_USER:-htpc}}" | cut -d: -f6
  else
    echo "$HOME"
  fi
}

kglobals_path() { echo "$(target_home)/.config/kdeglobals"; }

# Read/write kdeglobals key under any section
kde_set() {
  local section="$1" key="$2" val="$3" kg="$(kglobals_path)"
  mkdir -p "$(dirname "$kg")"
  [[ -f $kg ]] || printf '[General]\n' >"$kg"
  local tmp; tmp="$(mktemp)"
  local insec=0
  while IFS= read -r line; do
    if [[ $line == "[$section]" ]]; then insec=1; fi
    if (( insec )) && [[ $line == "$key="* ]]; then
      echo "$key=$val"
      insec=2
      continue
    fi
    echo "$line"
  done <"$kg" >"$tmp"
  if (( insec < 2 )); then
    awk -v sec="[$section]" -v kv="$key=$val" '
      {print}
      $0==sec && !done {print kv; done=1}
    ' "$kg" >"$tmp"
  fi
  mv "$tmp" "$kg"
  if [[ $EUID -eq 0 ]]; then
    chown "${TVPC_USER:-htpc}:${TVPC_USER:-htpc}" "$kg" 2>/dev/null || true
  fi
}

display_icon_size() {
  local kg="$(kglobals_path)"
  if [[ -f $kg ]]; then
    if grep -q '^\[Icons\]' "$kg"; then
      if grep -q '^Size=' "$kg"; then
        sed -i "/^\[Icons\]/,/^$/ s/^Size=.*/Size=/" "$kg"
      else
        sed -i "/^\[Icons\]/a Size=" "$kg"
      fi
    else
      printf '\n[Icons]\nSize=' >>"$kg"
    fi
    chown "${TVPC_USER:-htpc}:${TVPC_USER:-htpc}" "$kg" 2>/dev/null || true
    cat "$kg" | grep -A1 '^\[Icons\]'
  fi
}

# UI density presets
apply_density() {
  local level="$1"
  case "$level" in
    comfortable)
      kde_set General font "Noto Sans,15,-1,5,50,0,0,0,0,0"
      kde_set General menuFont "Noto Sans,15,-1,5,50,0,0,0,0,0"
      kde_set General fixed "Noto Sans Mono,14,-1,5,50,0,0,0,0,0"
      kde_set General toolBarFont "Noto Sans,14,-1,5,50,0,0,0,0,0"
      kde_set General smallestReadableFont "Noto Sans,13,-1,5,50,0,0,0,0,0"
      kde_set Icons Size 48
      ;;
    normal)
      kde_set General font "Noto Sans,13,-1,5,50,0,0,0,0,0"
      kde_set General menuFont "Noto Sans,13,-1,5,50,0,0,0,0,0"
      kde_set General fixed "Noto Sans Mono,12,-1,5,50,0,0,0,0,0"
      kde_set General toolBarFont "Noto Sans,12,-1,5,50,0,0,0,0,0"
      kde_set General smallestReadableFont "Noto Sans,11,-1,5,50,0,0,0,0,0"
      kde_set Icons Size 32
      ;;
    compact)
      kde_set General font "Noto Sans,11,-1,5,50,0,0,0,0,0"
      kde_set General menuFont "Noto Sans,11,-1,5,50,0,0,0,0,0"
      kde_set General fixed "Noto Sans Mono,10,-1,5,50,0,0,0,0,0"
      kde_set General toolBarFont "Noto Sans,10,-1,5,50,0,0,0,0,0"
      kde_set General smallestReadableFont "Noto Sans,9,-1,5,50,0,0,0,0,0"
      kde_set Icons Size 24
      ;;
  esac
  echo "UI density -> $level"
}

# EDID detection via edid-decode if available
read_edid() {
  local edid; for p in /sys/class/drm/*/edid; do
    [[ -r $p ]] || continue
    if [[ $(stat -c%s "$p" 2>/dev/null || echo 0) -gt 0 ]]; then
      edid="$p"
      break
    fi
  done
  echo "$edid"
}

cmd_edid() {
  local edid; edid="$(read_edid)"
  if [[ -z $edid ]]; then
    echo "No EDID found (no display connected)"
    return 1
  fi
  echo "EDID: $edid"
  local info; command -v edid-decode >/dev/null 2>&1 && info="$(edid-decode "$edid" 2>/dev/null)" || info=""
  local vendor="$(echo "$info" | sed -n 's/.*Manufacturer: \([A-Z][A-Z][A-Z]\).*/\1/p')"
  local model="$(echo "$info" | sed -n 's/.*Model name: //p' | head -1)"
  echo "Display: ${vendor:-?} ${model:-?}"
  local mode; mode="$(echo "$info" | awk '/^[0-9]+x[0-9]+.*[0-9]+ Hz/ {print $1"@"$NF; exit}')"
  if [[ -n $mode ]]; then
    echo "Preferred mode: $mode"
    # Apply mode (live, persist)
    command -v kscreen-doctor >/dev/null 2>&1 || { echo "kscreen-doctor missing; skipping mode" >&2; return 1; }
    local out; out="$(kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}')"
    if [[ -n $out ]]; then
      kscreen-doctor "output.$out.mode.$mode" >/dev/null 2>&1 && echo "Applied mode $mode" || echo "Could not apply mode $mode"
    fi
  fi
  # Set density based on typical TV (1.5) unless 4K
  local scale=1.5
  if [[ "$mode" == 3840x* ]]; then
    scale=1.25
  fi
  command -v kscreen-doctor >/dev/null 2>&1 && kscreen-doctor "output.$out.scale.$scale" >/dev/null 2>&1 && echo "Applied scale $scale"
  echo "Consider: tvpc-tweaks density comfortable|normal|compact"
}

cmd_hdr() {
  local state="${1:-on}"
  command -v kscreen-doctor >/dev/null 2>&1 || { echo "kscreen-doctor missing"; return 1; }
  local out; out="$(kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}')"
  if [[ -z $out ]]; then
    echo "No enabled output"
    return 1
  fi
  if kscreen-doctor "output.$out.hdr.$state" >/dev/null 2>&1; then
    echo "HDR -> $state"
    echo "  (requires restart to apply fully)"
  else
    echo "HDR not supported by this display/driver"
    return 1
  fi
}

cmd_density() {
  if [[ $# -lt 1 ]]; then
    echo "usage: $0 density comfortable|normal|compact"
    return 1
  fi
  apply_density "$1"
}

case "${1:-}" in
  edid) cmd_edid ;;
  hdr)  cmd_hdr "${2:-on}" ;;
  density) cmd_density "${2:-}" ;;
  *) echo "Usage: $0 edid|hdr on|off|density comfortable|normal|compact"; exit 1 ;;
esac
