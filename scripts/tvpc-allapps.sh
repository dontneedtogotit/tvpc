#!/usr/bin/env bash
# tvpc-allapps — a browseable list of every installed application.
#
# It reads .desktop files directly, so apps hidden from the home screen (via
# the blacklist) are still reachable here. Use it when the home shows only a
# couple of tiles but you need something else.
#   tvpc-allapps                 open the picker
# The picker is a GUI menu when possible (kdialog), a Wayland launcher
# (fuzzel/wofi) if present, or a console menu on a terminal.
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

# shellcheck source=/dev/null
[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
HTPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
HOME_DIR="$(getent passwd "$HTPC_USER" | cut -d: -f6 2>/dev/null || true)"

# id<TAB>name<TAB>desktop-path  — every Application, no blacklist filtering.
list_all() {
  local d f id name type nodisp
  for d in /usr/share/applications /usr/local/share/applications \
           "${HOME_DIR:+$HOME_DIR/.local/share/applications}" \
           /var/lib/flatpak/exports/share/applications; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do
      [[ -f $f ]] || continue
      type="$(sed -n 's/^Type=//p'      "$f" | head -1)"
      nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
      [[ $type == Application ]] || continue
      [[ $nodisp == true ]]      && continue
      id="$(basename "$f" .desktop)"
      name="$(sed -n 's/^Name=//p' "$f" | head -1)"
      printf '%s\t%s\t%s\n' "$id" "${name:-$id}" "$f"
    done
  done | sort -t$'\t' -k2,2 -u
}

pick_and_run() {
  local sel id
  if command -v kdialog >/dev/null 2>&1; then
    local args=()
    while IFS=$'\t' read -r id name _; do args+=("$id" "$name"); done < <(list_all)
    sel="$(kdialog --menu "All applications" "${args[@]}" 2>/dev/null)" || return 0
  elif command -v fuzzel >/dev/null 2>&1; then
    sel="$(list_all | cut -f2 | fuzzel --dmenu 2>/dev/null)" || return 0
    sel="$(list_all | awk -F'\t' -v n="$sel" '$2==n{print $1; exit}')"
  elif command -v wofi >/dev/null 2>&1; then
    sel="$(list_all | cut -f2 | wofi --dmenu 2>/dev/null)" || return 0
    sel="$(list_all | awk -F'\t' -v n="$sel" '$2==n{print $1; exit}')"
  elif [[ -t 0 ]]; then
    local -a names=() ids=()
    while IFS=$'\t' read -r id name _; do ids+=("$id"); names+=("$name"); done < <(list_all)
    [[ ${#ids[@]} -eq 0 ]] && return 0
    select _ in "${names[@]}"; do sel="${ids[$REPLY-1]}"; break; done
  else
    return 0
  fi
  [[ -z $sel ]] && return 0
  command -v kde-open5 >/dev/null 2>&1 && kde-open5 "application://$sel.desktop" >/dev/null 2>&1 && return 0
  command -v gtk-launch >/dev/null 2>&1 && gtk-launch "$sel" >/dev/null 2>&1 && return 0
  local path; path="$(list_all | awk -F'\t' -v id="$sel" '$1==id{print $3; exit}')"
  [[ -n $path ]] && nohup sh -c "$(sed -n 's/^Exec=//p' "$path" | head -1 | sed 's/%[fFuU]//g')" >/dev/null 2>&1 &
}

pick_and_run
