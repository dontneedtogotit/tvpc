#!/usr/bin/env bash
# tvpc-tweaks — a runnable "Tweaks" app for the tvpc HTPC.
#
# One place to do the couch-level adjustments: UI scaling, removing apps from
# the home screen, theme, display mode, TV sleep, autostart apps, and session
# switching. It is both:
#   * an interactive arrow-key menu (navigable with the CEC remote or over SSH)
#   * one-shot commands for headless / scripted use
#
# Interactive:
#   tvpc-tweaks                 launch the menu
# One-shot:
#   tvpc-tweaks scale 1.5      set global UI scale (live now, persisted for reboot)
#   tvpc-tweaks font 13        base font size (scales the whole Bigscreen UI)
#   tvpc-tweaks apps           list home-screen apps and their shown/hidden state
#   tvpc-tweaks hide firefox,vlc     remove apps from the home screen
#   tvpc-tweaks show firefox         put an app back on the home screen
#   tvpc-tweaks theme dark|light
#   tvpc-tweaks mode 1920x1080@60    (or: mode auto)
#   tvpc-tweaks idle on|off          stay awake / allow the TV to sleep
#   tvpc-tweaks autostart            manage autostart apps (interactive)
#   tvpc-tweaks session plasma ...   switch session (needs root)
#   tvpc-tweaks status
#   tvpc-tweaks install-launcher     put it on the home screen + /usr/local/bin
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS=/etc/default/tvpc
# shellcheck source=/dev/null
[[ -r $DEFAULTS ]] && . "$DEFAULTS"
TVPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

# ---------------------------------------------------------------------------
# Paths and small helpers
# ---------------------------------------------------------------------------
target_home() {
  if [[ $EUID -eq 0 ]]; then
    getent passwd "$TVPC_USER" | cut -d: -f6
  else
    echo "$HOME"
  fi
}

kglobals_path() { echo "$(target_home)/.config/kdeglobals"; }
blacklist_rc()  { echo "$(target_home)/.config/applications-blacklistrc"; }
applets_rc()    { echo "$(target_home)/.config/plasma-org.kde.plasma.desktop-appletsrc"; }
power_rc()      { echo "$(target_home)/.config/powermanagementprofilesrc"; }
autostart_dir() { echo "$(target_home)/.config/autostart"; }

is_root() { [[ $EUID -eq 0 ]]; }

# Persist a key in /etc/default/tvpc. Best-effort: needs root. Returns 0 if
# it wrote, 1 if it could not (caller should tell the user it won't survive a reboot).
set_default() {
  local k="$1" v="$2"
  if ! is_root; then return 1; fi
  if [[ -f $DEFAULTS ]] && grep -q "^$k=" "$DEFAULTS"; then
    sed -i "s|^$k=.*|$k=$v|" "$DEFAULTS"
  else
    mkdir -p "$(dirname "$DEFAULTS")"
    echo "$k=$v" >>"$DEFAULTS"
  fi
  return 0
}

# Set a [General] key in kdeglobals, creating the file if needed.
set_kg() {
  local key="$1" val="$2" kg; kg="$(kglobals_path)"
  mkdir -p "$(dirname "$kg")"
  [[ -f $kg ]] || printf '[General]\n' >"$kg"
  if grep -q "^$key=" "$kg"; then
    sed -i "s|^$key=.*|$key=$val|" "$kg"
  else
    sed -i "/^\[General\]/a $key=$val" "$kg"
  fi
  if is_root; then chown "$TVPC_USER:$TVPC_USER" "$kg" 2>/dev/null || true; fi
}

get_kg() {
  local key="$1" kg; kg="$(kglobals_path)"
  [[ -f $kg ]] || return 0
  sed -n "s/^$key=//p" "$kg" | head -1
}

need_root() {
  if ! is_root; then
    echo "This needs root — run: sudo tvpc-tweaks $*" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Home-screen app list / hide / show
# ---------------------------------------------------------------------------
# Bigscreen filters the home screen through applications-blacklistrc (the
# supported way to drop an app), and plain Plasma keeps its launcher favorites
# in plasma-org.kde.plasma.desktop-appletsrc. We drive both so the app
# disappears from whichever shell is active.
read_blacklist() {
  local rc; rc="$(blacklist_rc)"
  [[ -f $rc ]] || return 0
  sed -n 's/^blacklist=//p' "$rc" | tr ',' '\n' | sed '/^$/d'
}

write_blacklist() {   # entries on stdin, one per line
  local rc list; rc="$(blacklist_rc)"
  list="$(sort -u | sed '/^$/d' | paste -sd, -)"
  install -d -o "$TVPC_USER" -g "$TVPC_USER" "$(dirname "$rc")" 2>/dev/null || mkdir -p "$(dirname "$rc")"
  cat >"$rc" <<RC
[Applications]
blacklist=$list
RC
  if is_root; then chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true; fi
  echo "$list"
}

list_apps() {
  local d f id name nodisp term type home
  home="$(target_home)"
  for d in /usr/share/applications /usr/local/share/applications \
           "$home/.local/share/applications" \
           /var/lib/flatpak/exports/share/applications; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do
      [[ -f $f ]] || continue
      type="$(sed -n 's/^Type=//p'      "$f" | head -1)"
      nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
      term="$(sed -n 's/^Terminal=//p'  "$f" | head -1)"
      [[ $type == Application ]] || continue
      [[ $nodisp == true ]]      && continue
      [[ $term == true ]]        && continue
      name="$(sed -n 's/^Name=//p' "$f" | head -1)"
      id="$(basename "$f" .desktop)"
      printf '%s\t%s\n' "$id" "${name:-$id}"
    done
  done | sort -u
}

app_is_hidden() {
  local id="$1"
  while IFS= read -r h; do [[ $h == "$id" ]] && return 0; done < <(read_blacklist)
  return 1
}

hide_app() {
  local id="$1" rc; rc="$(applets_rc)"
  # Bigscreen home screen
  mapfile -t bl < <(read_blacklist)
  printf '%s\n' "${bl[@]}" "$id" | write_blacklist >/dev/null
  # Plain Plasma favorites
  if [[ -f $rc ]]; then
    sed -i -E "s/(favorites=.*)$id\.desktop,?/\1/; s/,,/,/g; s/(favorites=.*),\$/\1/" "$rc"
    if is_root; then chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true; fi
  fi
}

show_app() {
  local id="$1" rc; rc="$(applets_rc)"
  mapfile -t bl < <(read_blacklist)
  keep=()
  for c in "${bl[@]:-}"; do [[ -n $c && $c != "$id" ]] && keep+=("$c"); done
  printf '%s\n' "${keep[@]}" | write_blacklist >/dev/null
  if [[ -f $rc ]] && is_root; then chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------------
# Scaling / mode / theme / idle
# ---------------------------------------------------------------------------
output_id() {
  command -v kscreen-doctor >/dev/null 2>&1 || return 0
  kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}'
}

apply_scale_live() {
  local factor="$1" out; out="$(output_id)"
  [[ -n $out ]] || return 0
  kscreen-doctor "output.$out.scale.$factor" >/dev/null 2>&1 || true
}

apply_mode_live() {
  local mode="$1" out; out="$(output_id)"
  [[ -n $out ]] || return 0
  kscreen-doctor "output.$out.mode.$mode" >/dev/null 2>&1 || true
}

do_scale() {
  local factor="$1"
  case "$factor" in
    ''|.|*.*.*) echo "scale must look like 1.5 (got '$factor')" >&2; return 1 ;;
  esac
  apply_scale_live "$factor"
  if set_default TVPC_SCALE "$factor"; then
    echo "UI scale -> $factor (live now; persisted in $DEFAULTS)"
  else
    echo "UI scale -> $factor (live now; NOT persisted — run 'sudo tvpc-tweaks scale $factor' to survive reboot)"
  fi
}

do_font() {
  local arg="$1"
  [[ $arg =~ ^[0-9]+$ ]] || { echo "font size must be a number (e.g. 13)" >&2; return 1; }
  set_kg "font"              "Noto Sans,$arg,-1,5,50,0,0,0,0,0"
  set_kg "menuFont"          "Noto Sans,$arg,-1,5,50,0,0,0,0,0"
  set_kg "fixed"             "Noto Sans Mono,$((arg-1)),-1,5,50,0,0,0,0,0"
  set_kg "toolBarFont"       "Noto Sans,$((arg-1)),-1,5,50,0,0,0,0,0"
  set_kg "smallestReadableFont" "Noto Sans,$((arg-2)),-1,5,50,0,0,0,0,0"
  if set_default TVPC_FONT_SIZE "$arg"; then
    echo "Base font size -> $arg (scales the whole Kirigami/Bigscreen UI; persisted)"
  else
    echo "Base font size -> $arg (log out and back in; NOT persisted — 'sudo tvpc-tweaks font $arg')"
  fi
}

do_mode() {
  local mode="$1"
  if [[ $mode == auto ]]; then
    if set_default TVPC_MODE ""; then
      echo "Display mode -> auto (uses the TV's EDID; persisted)"
    else
      echo "Display mode -> auto (NOT persisted — run 'sudo tvpc-tweaks mode auto')"
    fi
    return 0
  fi
  apply_mode_live "$mode"
  if set_default TVPC_MODE "$mode"; then
    echo "Display mode -> $mode (live now; persisted)"
  else
    echo "Display mode -> $mode (live now; NOT persisted — 'sudo tvpc-tweaks mode $mode')"
  fi
}

do_theme() {
  local t="$1"
  case "$t" in
    dark)
      set_kg "ColorScheme" "Breeze Dark"
      set_kg "LookAndFeelPackage" "org.kde.breezedark.desktop"
      set_kg "widgetStyle" "Breeze"
      echo "Theme -> dark (log out and back in to apply)" ;;
    light)
      set_kg "ColorScheme" "Breeze"
      set_kg "LookAndFeelPackage" "org.kde.breeze.desktop"
      set_kg "widgetStyle" "Breeze"
      echo "Theme -> light (log out and back in to apply)" ;;
    *) echo "usage: tvpc-tweaks theme dark|light" >&2; return 1 ;;
  esac
}

do_idle() {
  local on="$1" rc; rc="$(power_rc)"
  install -d -o "$TVPC_USER" -g "$TVPC_USER" "$(dirname "$rc")" 2>/dev/null || mkdir -p "$(dirname "$rc")"
  if [[ $on == on ]]; then
    cat >"$rc" <<'EOF'
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
    echo "TV sleep -> off (stays awake; applies next session)"
  else
    cat >"$rc" <<'EOF'
[AC][DPMSControl]
idleTime=300
lockBeforeTurnOff=0

[AC][DimDisplay]
idleTime=300

[AC][SuspendSession]
idleTime=600
suspendType=1

[AC][HandleButtonEvents]
lidAction=0
powerButtonAction=1
EOF
    echo "TV sleep -> allowed after ~5 min idle (applies next session)"
  fi
  if is_root; then chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------------
# Autostart management
# ---------------------------------------------------------------------------
list_autostart() {
  local d; d="$(autostart_dir)"
  [[ -d $d ]] || return 0
  for f in "$d"/*.desktop; do
    [[ -f $f ]] || continue
    [[ $(sed -n 's/^NoDisplay=//p' "$f" | head -1) == true ]] && continue
    local name; name="$(sed -n 's/^Name=//p' "$f" | head -1)"
    printf '%s\t%s\n' "$(basename "$f" .desktop)" "${name:-$(basename "$f" .desktop)}"
  done | sort -u
}

autostart_add() {
  local id="$1" src d; d="$(autostart_dir)"
  for base in /usr/share/applications /usr/local/share/applications "$(target_home)/.local/share/applications"; do
    [[ -f "$base/$id.desktop" ]] && { src="$base/$id.desktop"; break; }
  done
  [[ -n ${src:-} ]] || { echo "no .desktop for '$id'" >&2; return 1; }
  mkdir -p "$d"
  cp "$src" "$d/$id.desktop"
  if is_root; then chown -R "$TVPC_USER:$TVPC_USER" "$d" 2>/dev/null || true; fi
  echo "Autostart + $id"
}

autostart_remove() {
  local id="$1" d; d="$(autostart_dir)"
  rm -f "$d/$id.desktop"
  echo "Autostart - $id"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
cmd_status() {
  local font theme mode
  font="$(get_kg font | cut -d, -f2)"
  theme="$(get_kg ColorScheme)"
  mode="${TVPC_MODE:-auto}"
  echo "== tvpc tweaks status =="
  echo "session : ${TVPC_SESSION:-unset}"
  echo "scale   : ${TVPC_SCALE:-1.5}  (TVPC_SCALE)"
  echo "font    : ${font:-unset}pt base"
  echo "theme   : ${theme:-unset}"
  echo "mode    : $mode"
  echo
  echo "hidden from home screen:"
  local hidden; hidden="$(read_blacklist | paste -sd, -)"
  echo "  ${hidden:- (none)}"
  echo
  echo "autostart:"
  local a; a="$(list_autostart | cut -f2 | paste -sd, -)"
  echo "  ${a:- (none)}"
}

# ---------------------------------------------------------------------------
# Interactive TUI (arrow keys / Enter; also works over the CEC remote)
# ---------------------------------------------------------------------------
ITEM_VAL=(); ITEM_LABEL=()
menu_reset() { ITEM_VAL=(); ITEM_LABEL=(); }
menu_add()   { ITEM_VAL+=("$1"); ITEM_LABEL+=("$2"); }

RESULT=""
read_key() {
  local k k2 k3
  IFS= read -rsn1 -t 1 k || { READKEY=cancel; return; }
  if [[ $k == $'\e' ]]; then
    IFS= read -rsn1 -t 0.01 k2; IFS= read -rsn1 -t 0.01 k3
    k="$k$k2$k3"
  fi
  READKEY="$k"
}

# select_list TITLE — uses ITEM_VAL / ITEM_LABEL, sets RESULT (empty = cancel)
select_list() {
  local title="$1"
  local n=${#ITEM_VAL[@]} sel=0 top=0 avail h
  h=$(tput lines 2>/dev/null || echo 24)
  avail=$((h - 5)); [[ $avail -lt 3 ]] && avail=3
  while true; do
    clear
    printf '\033[1;36m%s\033[0m\n' "$title"
    printf '\033[2m(up/down: move  ·  Enter: select  ·  q/Esc: back)\033[0m\n\n'
    local i
    for ((i=top; i<n && i<top+avail; i++)); do
      if (( i==sel )); then printf '  \033[1;32m> %s\033[0m\n' "${ITEM_LABEL[$i]}"
      else                 printf '    %s\n' "${ITEM_LABEL[$i]}"; fi
    done
    for ((i=n<top+avail?n:top+avail; i<top+avail; i++)); do echo; done
    read_key
    case "$READKEY" in
      $'\e[A') ((sel>0)) && ((sel--)); ((sel<top)) && top=$sel ;;
      $'\e[B') ((sel<n-1)) && ((sel++)); ((sel>=top+avail)) && top=$((sel-avail+1)) ;;
      "") RESULT="${ITEM_VAL[$sel]}"; return 0 ;;
      q|Q)    RESULT=""; return 1 ;;
      $'\e')  RESULT=""; return 1 ;;
      [0-9])  local d=$((10#$READKEY)); ((d<n)) && { sel=$d; RESULT="${ITEM_VAL[$sel]}"; return 0; } ;;
    esac
  done
}

pause_msg() {
  printf '\n\033[1;33m%s\033[0m\n' "$1"
  printf '\033[2m(press any key)\033[0m'
  read_key
}

tui_scale() {
  local cur="${TVPC_SCALE:-1.5}"
  menu_reset
  for f in 0.75 1 1.25 1.5 1.75 2; do
    local tag=""; [[ $f == "$cur" ]] && tag="  (current)"
    menu_add "$f" "$f ×$tag"
  done
  menu_add custom "Set a custom scale…"
  menu_add font   "Base font size (Bigscreen whole-UI scale)…"
  menu_add back   "Back"
  select_list "UI scaling"
  case "$RESULT" in
    custom)
      clear; printf 'Enter scale factor (e.g. 1.25): '; read -r v
      [[ -n $v ]] && do_scale "$v" ;;
    font)
      clear; printf 'Enter base font size in points (Bigscreen: try 10): '; read -r v
      [[ $v =~ ^[0-9]+$ ]] && do_font "$v" ;;
    back|"") return ;;
    *) do_scale "$RESULT" ;;
  esac
  pause_msg "Done."
}

tui_apps() {
  local -a AID ANAME AHID
  while IFS=$'\t' read -r id name; do
    AID+=("$id"); ANAME+=("$name")
    app_is_hidden "$id" && AHID+=(1) || AHID+=(0)
  done < <(list_apps)
  local n=${#AID[@]} sel=0 top=0 avail h
  h=$(tput lines 2>/dev/null || echo 24)
  avail=$((h - 5)); [[ $avail -lt 3 ]] && avail=3
  while true; do
    clear
    printf '\033[1;36mHome-screen apps\033[0m\n'
    printf '\033[2m(Enter: toggle shown/hidden  ·  q/Esc: back)\033[0m\n\n'
    for ((i=top; i<n && i<top+avail; i++)); do
      local mark
      if (( AHID[i] )); then mark="\033[1;31m[hidden]\033[0m"; else mark="\033[1;32m[shown ]\033[0m"; fi
      if (( i==sel )); then printf '  \033[1;32m>\033[0m %-40s %b\n' "${ANAME[$i]}" "$mark"
      else                 printf '    %-40s %b\n' "${ANAME[$i]}" "$mark"; fi
    done
    for ((i=n<top+avail?n:top+avail; i<top+avail; i++)); do echo; done
    read_key
    case "$READKEY" in
      $'\e[A') ((sel>0)) && ((sel--)); ((sel<top)) && top=$sel ;;
      $'\e[B') ((sel<n-1)) && ((sel++)); ((sel>=top+avail)) && top=$((sel-avail+1)) ;;
      "") if (( AHID[sel] )); then show_app "${AID[$sel]}"; AHID[$sel]=0; else hide_app "${AID[$sel]}"; AHID[$sel]=1; fi ;;
      q|Q|$'\e') return ;;
    esac
  done
}

tui_theme() {
  menu_reset
  menu_add dark  "Dark (Breeze Dark)"
  menu_add light "Light (Breeze)"
  menu_add back  "Back"
  select_list "Theme"
  case "$RESULT" in dark|light) do_theme "$RESULT" ;; esac
  pause_msg "Done."
}

tui_mode() {
  menu_reset
  menu_add auto "Auto (use the TV's EDID)"
  while IFS= read -r m; do [[ -n $m ]] && menu_add "$m" "$m"; done < <(list_modes)
  menu_add back "Back"
  select_list "Display mode"
  case "$RESULT" in back|"") return ;; *) do_mode "$RESULT" ;; esac
  pause_msg "Done."
}

list_modes() {
  command -v kscreen-doctor >/dev/null 2>&1 || return 0
  kscreen-doctor -o 2>/dev/null | grep -oE 'Mode [0-9]+: [0-9]+x[0-9]+@[0-9.]+' | sed -E 's/Mode [0-9]+: //'
}

tui_idle() {
  menu_reset
  menu_add on  "Stay awake (TV never sleeps)"
  menu_add off "Allow sleep after ~5 min idle"
  menu_add back "Back"
  select_list "TV sleep"
  case "$RESULT" in on|off) do_idle "$RESULT" ;; esac
  pause_msg "Done."
}

tui_autostart() {
  while true; do
    menu_reset
    while IFS=$'\t' read -r id name; do menu_add "rm:$id" "Remove: $name"; done < <(list_autostart)
    menu_add add  "＋ Add an app…"
    menu_add back "Back"
    select_list "Autostart apps"
    case "$RESULT" in
      back|"") return ;;
      add)
        menu_reset
        while IFS=$'\t' read -r id name; do menu_add "$id" "$name"; done < <(list_apps)
        menu_add cancel "Cancel"
        select_list "Add which app to autostart?"
        [[ $RESULT && $RESULT != cancel ]] && autostart_add "$RESULT" ;;
      rm:*) autostart_remove "${RESULT#rm:}" ;;
    esac
  done
  pause_msg "Done."
}

tui_session() {
  menu_reset
  for s in auto plasma plasma-mobile plasma-x11 kiosk bigscreen bigscreen-x11 hypr phosh; do menu_add "$s" "$s"; done
  menu_add back "Back"
  select_list "Switch session (needs root)"
  case "$RESULT" in back|"") return ;; *)
    if need_root "session $RESULT"; then
      local tool=""
      for cand in "$REPO_ROOT/scripts/tvpc-session.sh" /usr/local/bin/tvpc-session; do
        [[ -x $cand ]] && { tool="$cand"; break; }
      done
      if [[ -n $tool ]]; then "$tool" "$RESULT" && pause_msg "Switched. Restart the display manager: sudo systemctl restart sddm"
      else pause_msg "tvpc-session not found"; fi
    fi ;;
  esac
}

tui_main() {
  while true; do
    menu_reset
    menu_add scale     "UI scaling"
    menu_add apps      "Home-screen apps"
    menu_add theme     "Theme"
    menu_add mode      "Display mode"
    menu_add idle      "TV sleep"
    menu_add autostart "Autostart apps"
    menu_add session   "Session"
    menu_add status    "Show status"
    menu_add quit      "Exit"
    select_list "tvpc Tweaks"
    case "$RESULT" in
      scale)     tui_scale ;;
      apps)      tui_apps ;;
      theme)     tui_theme ;;
      mode)      tui_mode ;;
      idle)      tui_idle ;;
      autostart) tui_autostart ;;
      session)   tui_session ;;
      status)    clear; cmd_status; pause_msg "" ;;
      quit|"")   return ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Launcher install
# ---------------------------------------------------------------------------
install_launcher() {
  need_root "install-launcher" || return 1
  install -m 0755 "$REPO_ROOT/scripts/tvpc-tweaks.sh" /usr/local/bin/tvpc-tweaks
  mkdir -p /usr/share/applications
  cat >/usr/share/applications/tvpc-tweaks.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=TV Tweaks
GenericName=tvpc adjustments
Comment=UI scaling, home-screen apps, and other tvpc tweaks
Exec=/usr/local/bin/tvpc-tweaks
Terminal=true
Icon=preferences-system
Categories=Settings;
Keywords=tvpc;tweaks;scaling;home screen;
EOF
  echo "Installed /usr/local/bin/tvpc-tweaks and a TV Tweaks launcher (appears on the home screen)."
}

# ---------------------------------------------------------------------------
# Full home-screen preset
# ---------------------------------------------------------------------------
# Apps kept visible on the home screen; everything else is hidden. Only ids
# that are actually installed are kept, so this is safe on any box.
WHITELIST_IDS=(io.github.vacuumtube.VacuumTube org.mozilla.firefox tv.kodi.Kodi \
                org.kde.dolphin systemsettings tvpc-power tvpc-watch-youtube)

ensure_wallpaper() {
  local dest="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$dest")"
  python3 - "$dest" <<'PY'
import sys, struct, zlib
def png(path, rgb):
    w = h = 64
    raw = bytearray()
    for _ in range(h):
        raw.append(0)
        for _ in range(w):
            raw += bytes(rgb)
    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(raw))
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))
png(sys.argv[1], (16, 19, 26))
PY
  return 0
}

add_hero_tile() {
  local id=io.github.vacuumtube.VacuumTube found="" d
  for base in /usr/share/applications /usr/local/share/applications \
              /var/lib/flatpak/exports/share/applications; do
    [[ -f "$base/$id.desktop" ]] && { found="$base/$id.desktop"; break; }
  done
  [[ -n $found ]] || { echo "  (hero tile skipped: VacuumTube not installed)"; return 0; }
  d="$(target_home)/.local/share/applications"; mkdir -p "$d"
  cat >"$d/tvpc-watch-youtube.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Watch YouTube
Comment=Open YouTube in VacuumTube
Exec=$(grep -m1 '^Exec=' "$found" | sed 's/^Exec=//')
Terminal=false
Icon=video-television
Categories=Video;
EOF
  if is_root; then chown -R "$TVPC_USER:$TVPC_USER" "$d" 2>/dev/null || true; fi
  echo "  hero tile: Watch YouTube"
}

apply_wallpaper() {
  is_root && return 0   # the live wallpaper tool acts on the calling user's session
  local dest; dest="$(target_home)/.local/share/tvpc/wallpaper.png"
  ensure_wallpaper "$dest" || { echo "  (wallpaper skipped: python3 missing)"; return 0; }
  if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
    plasma-apply-wallpaperimage "$dest" >/dev/null 2>&1 && echo "  wallpaper set (dark)" \
      || echo "  (wallpaper tool present but did not apply)"
  else
    echo "  (wallpaper skipped: no plasma-apply-wallpaperimage — Bigscreen uses its own background)"
  fi
}

ensure_bigscreen_session() {
  local inst=/usr/share/wayland-sessions/plasma-bigscreen-wayland.desktop
  [[ -f $inst ]] || { echo "  (Bigscreen not installed — for the TV shell: sudo tvpc-bigscreen --switch)"; return 0; }
  if ! is_root; then
    echo "  (session left as-is; switching needs root: sudo tvpc-tweaks session bigscreen)"
    return 0
  fi
  local tool=""
  for cand in "$REPO_ROOT/scripts/tvpc-session.sh" /usr/local/bin/tvpc-session; do
    [[ -x $cand ]] && { tool="$cand"; break; }
  done
  [[ -n $tool ]] && { "$tool" bigscreen && echo "  session -> bigscreen (restart sddm to apply)"; }
}

# Point the CEC Home button at tvpc-allapps (set once; the listener reads it).
ensure_allapps() {
  if is_root; then
    set_default TVPC_ALLAPPS 1 && echo "  remote Home button now opens All Apps" \
      || echo "  (could not persist TVPC_ALLAPPS — run 'sudo tvpc-tweaks vacuum-only')"
  else
    echo "  All-apps launcher: run 'tvpc-allapps' (or 'sudo tvpc-tweaks vacuum-only' to bind the remote Home button)"
  fi
}

# VacuumTube-only home: one tile, everything else via the All Apps launcher.
vacuum_only() {
  local vid=io.github.vacuumtube.VacuumTube
  echo "== tvpc: VacuumTube-only home =="
  do_theme dark
  echo "-- curate: keep only VacuumTube --"
  if ! list_apps | cut -f1 | grep -qx "$vid"; then
    echo "  (VacuumTube not installed — cannot make it the only home tile; install it first)"
    return 1
  fi
  local id
  for id in $(list_apps | cut -f1); do
    [[ $id == "$vid" ]] && continue
    hide_app "$id"
  done
  echo "  home now shows only VacuumTube"
  echo "-- dark wallpaper --"; apply_wallpaper
  echo "-- all-apps launcher --"; ensure_allapps
  echo
  echo "Done. VacuumTube is the only home tile; every other app opens from 'tvpc-allapps'."
  echo "(On the default Plasma session the remote Home button already opens the full launcher too.)"
}

home_preset() {
  echo "== tvpc home-screen preset =="
  echo "-- dark theme --"; do_theme dark
  echo "-- hero tile --"; add_hero_tile
  echo "-- curate tiles (keep only a couch set) --"
  local present_whitelist=0 w id keepit=0
  for w in "${WHITELIST_IDS[@]}"; do
    if list_apps | cut -f1 | grep -qx "$w"; then present_whitelist=$((present_whitelist + 1)); fi
  done
  if [[ $present_whitelist -eq 0 ]]; then
    echo "  (no whitelisted apps installed yet — leaving the home screen unchanged)"
  else
    for id in $(list_apps | cut -f1); do
      keepit=0
      for w in "${WHITELIST_IDS[@]}"; do [[ $id == "$w" ]] && { keepit=1; break; }; done
      [[ $keepit -eq 0 ]] && hide_app "$id"
    done
  fi
  echo "  kept tiles:"
  for w in "${WHITELIST_IDS[@]}"; do
    if list_apps | cut -f1 | grep -qx "$w"; then echo "    - $w"; fi
  done
  echo "-- wallpaper --"; apply_wallpaper
  echo "-- session --"; ensure_bigscreen_session
  echo
  echo "Done. Log out and back in (or 'sudo systemctl restart sddm') to see it."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  scale)           shift; do_scale "${1:-}" ;;
  font)            shift; do_font "${1:-}" ;;
  apps)            list_apps | while IFS=$'\t' read -r id name; do
                     app_is_hidden "$id" && st="hidden" || st="shown"
                     printf '%-45s %-30s %s\n' "$id" "${name:0:29}" "$st"
                   done ;;
  hide)            shift
                   IFS=',' read -r -a ids <<<"$*"
                   for id in "${ids[@]}"; do hide_app "$id"; done
                   echo "Hidden: ${ids[*]}  (log out and back in)" ;;
  show)            shift
                   IFS=',' read -r -a ids <<<"$*"
                   for id in "${ids[@]}"; do show_app "$id"; done
                   echo "Shown again: ${ids[*]}  (log out and back in)" ;;
  theme)           shift; do_theme "${1:-}" ;;
  mode)            shift; do_mode "${1:-auto}" ;;
  idle)            shift; do_idle "${1:-on}" ;;
  autostart)       shift; tui_autostart ;;
  session)         shift; need_root "session $*" || exit 1
                   SESSION_TOOL=""
                   for cand in "$REPO_ROOT/scripts/tvpc-session.sh" /usr/local/bin/tvpc-session; do
                     [[ -x $cand ]] && { SESSION_TOOL="$cand"; break; }
                   done
                   [[ -n $SESSION_TOOL ]] && "$SESSION_TOOL" "${1:-auto}" || echo "tvpc-session not found" ;;
  status)          cmd_status ;;
  home-preset)     home_preset ;;
  vacuum-only)     vacuum_only ;;
  install-launcher) install_launcher ;;
  --help|-h|help)  usage; exit 0 ;;
  "")              if [[ -t 1 ]]; then tui_main; else usage; fi ;;
  *)               echo "Unknown command '$1' (try: tvpc-tweaks --help)" >&2; exit 1 ;;
esac
