#!/usr/bin/env bash
# tvpc-tweaks -- Comprehensive TV box customization tool
# One unified application for all TVPC adjustments:
#   UI scaling, home screen curation, display settings, remote control,
#   audio, power management, and system tweaks.

set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS=/etc/default/tvpc
TVPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"
CEC_MAP=/etc/tvpc/cec-map.conf
CEC_MACROS=/etc/tvpc/cec-macros.conf
EQ_CONF=/etc/pipewire/pipewire.conf.d/99-tvpc-eq.conf
EQ_PRESETS=(flat warm balanced bright punchy)
EQ_BANDS_DEFAULT=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
TVPC_PLUGIN_IDS=()
TVPC_PLUGIN_LABELS=()

if [[ -f $DEFAULTS ]]; then
    . "$DEFAULTS"
fi

target_home() {
    if [[ $EUID -eq 0 ]]; then
        getent passwd "$TVPC_USER" | cut -d: -f6
    else
        echo "$HOME"
    fi
}

kglobals_path() { echo "$(target_home)/.config/kdeglobals"; }
blacklist_rc() { echo "$(target_home)/.config/applications-blacklistrc"; }
applets_rc() { echo "$(target_home)/.config/plasma-org.kde.plasma.desktop-appletsrc"; }
power_rc() { echo "$(target_home)/.config/powermanagementprofilesrc"; }
autostart_dir() { echo "$(target_home)/.config/autostart"; }

is_root() { [[ $EUID -eq 0 ]]; }

set_default() {
    local k="$1" v="$2"
    if ! is_root; then return 1; fi
    if [[ -f $DEFAULTS ]] && grep -q "^$k=" "$DEFAULTS"; then
        sed -i "s|^$k=.*|$k=$v|" "$DEFAULTS"
    else
        mkdir -p "$(dirname "$DEFAULTS")"
        echo "$k=$v" >>"$DEFAULTS"
    fi
}

kde_set() {
    local section="$1" key="$2" val="$3" kg
    kg="$(kglobals_path)"
    mkdir -p "$(dirname "$kg")"
    if [[ ! -f $kg ]]; then
        printf '[General]\n' >"$kg"
    fi
    local tmp; tmp="$(mktemp)"
    local insec=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "[$section]" ]]; then
            insec=1
        fi
        if [[ $insec -eq 1 ]] && [[ $line == "$key="* ]]; then
            echo "$key=$val"
            insec=2
            continue
        fi
        echo "$line"
    done <"$kg" >"$tmp"
    if [[ $insec -lt 2 ]]; then
        awk -v sec="[$section]" -v kv="$key=$val" '
            {print}
            $0==sec && !done {print kv; done=1}
        ' "$kg" >"$tmp"
    fi
    mv "$tmp" "$kg"
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$kg" 2>/dev/null || true
    fi
}

get_kg() {
    local key="$1" kg
    kg="$(kglobals_path)"
    if [[ -f $kg ]]; then
        grep "^$key=" "$kg" | head -1 | sed 's/^[^=]*=//'
    fi
}

list_apps() {
    local d f type nodisp term name id home
    home="$(target_home)"
    for d in /usr/share/applications /usr/local/share/applications \
             "$home/.local/share/applications" \
             /var/lib/flatpak/exports/share/applications; do
        [[ -d $d ]] || continue
        for f in "$d"/*.desktop; do
            [[ -f $f ]] || continue
            type="$(sed -n 's/^Type=//p' "$f" | head -1)"
            nodisp="$(sed -n 's/^NoDisplay=//p' "$f" | head -1)"
            term="$(sed -n 's/^Terminal=//p' "$f" | head -1)"
            [[ $type == Application ]] || continue
            [[ $nodisp == true ]] && continue
            [[ $term == true ]] && continue
            name="$(sed -n 's/^Name=//p' "$f" | head -1)"
            id="$(basename "$f" .desktop)"
            printf '%s\t%s\n' "$id" "${name:-$id}"
        done
    done | sort -u
}

read_blacklist() {
    local rc; rc="$(blacklist_rc)"
    if [[ -f $rc ]]; then
        sed -n 's/^blacklist=//p' "$rc" | tr ',' '\n' | sed '/^$/d'
    fi
}

app_is_hidden() {
    local id="$1"
    local bl; bl="$(read_blacklist)"
    echo "$bl" | grep -qx "$id"
}

write_blacklist() {
    local rc list; rc="$(blacklist_rc)"
    list="$(sort -u | sed '/^$/d' | paste -sd, -)"
    mkdir -p "$(dirname "$rc")"
    cat >"$rc" <<RC
[Applications]
blacklist=$list
RC
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true
    fi
    echo "$list"
}

hide_app() {
    local id="$1" rc bl
    rc="$(blacklist_rc)"
    mapfile -t bl < <(read_blacklist)
    printf '%s\n' "${bl[@]:-}" "$id" | write_blacklist >/dev/null
    local appletrc; appletrc="$(applets_rc)"
    if [[ -f $appletrc ]]; then
        sed -i -E "s/(favorites=.*)$id\.desktop,?/\1/; s/,,/,/g; s/(favorites=.*),\$/\1/" "$appletrc"
        if is_root; then
            chown "$TVPC_USER:$TVPC_USER" "$appletrc" 2>/dev/null || true
        fi
    fi
}

show_app() {
    local id="$1" bl keep
    mapfile -t bl < <(read_blacklist)
    keep=()
    for c in "${bl[@]:-}"; do
        if [[ -n "$c" && "$c" != "$id" ]]; then
            keep+=("$c")
        fi
    done
    printf '%s\n' "${keep[@]}" | write_blacklist >/dev/null
    if is_root; then
        local appletrc; appletrc="$(applets_rc)"
        if [[ -f $appletrc ]]; then
            chown "$TVPC_USER:$TVPC_USER" "$appletrc" 2>/dev/null || true
        fi
    fi
}

output_id() {
    command -v kscreen-doctor >/dev/null 2>&1 || return 1
    kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}'
}

apply_scale_live() {
    local factor="$1" out
    out="$(output_id)"
    [[ -n $out ]] || return 0
    kscreen-doctor "output.$out.scale.$factor" >/dev/null 2>&1 || true
}

apply_mode_live() {
    local mode="$1" out
    out="$(output_id)"
    [[ -n $out ]] || return 0
    kscreen-doctor "output.$out.mode.$mode" >/dev/null 2>&1 || true
}

do_scale() {
    local factor="$1"
    case "$factor" in
        ''|.*.*\.*) 
            echo "scale must be a number like 1.5 (got '$factor')" >&2
            return 1
            ;;
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
    case "$arg" in
        ''|*[!0-9]*)
            echo "font size must be a number (e.g. 13)" >&2
            return 1
            ;;
    esac
    kde_set "General" "font" "Noto Sans,$arg,-1,5,50,0,0,0,0,0"
    kde_set "General" "menuFont" "Noto Sans,$arg,-1,5,50,0,0,0,0,0"
    kde_set "General" "fixed" "Noto Sans Mono,$((arg-1)),-1,5,50,0,0,0,0,0"
    kde_set "General" "toolBarFont" "Noto Sans,$((arg-1)),-1,5,50,0,0,0,0,0"
    kde_set "General" "smallestReadableFont" "Noto Sans,$((arg-2)),-1,5,50,0,0,0,0,0"
    if set_default TVPC_FONT_SIZE "$arg"; then
        echo "Base font size -> $arg (scales the whole Kirigami/Bigscreen UI; persisted)"
    else
        echo "Base font size -> $arg (log out and back in; NOT persisted — 'sudo tvpc-tweaks font $arg')"
    fi
}

do_theme() {
    local t="$1"
    case "$t" in
        dark)
            kde_set "General" "ColorScheme" "Breeze Dark"
            kde_set "General" "LookAndFeelPackage" "org.kde.breezedark.desktop"
            kde_set "General" "widgetStyle" "Breeze"
            echo "Theme -> dark (log out and back in to apply)"
            ;;
        light)
            kde_set "General" "ColorScheme" "Breeze"
            kde_set "General" "LookAndFeelPackage" "org.kde.breeze.desktop"
            kde_set "General" "widgetStyle" "Breeze"
            echo "Theme -> light (log out and back in to apply)"
            ;;
        *)
            echo "usage: tvpc-tweaks theme dark|light" >&2
            return 1
            ;;
    esac
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

do_idle() {
    local on="$1" rc
    rc="$(power_rc)"
    mkdir -p "$(dirname "$rc")"
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
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$rc" 2>/dev/null || true
    fi
}

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

apply_wallpaper() {
    is_root && return 0
    local dest="$(target_home)/.local/share/tvpc/wallpaper.png"
    ensure_wallpaper "$dest" 2>/dev/null || return 0
    if [[ -x /usr/bin/plasma-apply-wallpaperimage ]]; then
        plasma-apply-wallpaperimage "$dest" >/dev/null 2>&1 && echo "  wallpaper set (dark)" \
            || echo "  (wallpaper tool present but did not apply)"
    else
        echo "  (wallpaper skipped: no plasma-apply-wallpaperimage)"
    fi
}

switch_session() {
    local target="${1:-auto}"
    local tool
    for cand in "$REPO_ROOT/scripts/tvpc-session.sh" /usr/local/bin/tvpc-session; do
        if [[ -x $cand ]]; then
            tool="$cand"
            break
        fi
    done
    if [[ -z $tool ]]; then
        echo "!! tvpc-session not found; try manually: sudo tvpc-session $target" >&2
        return 1
    fi
    "$tool" "$target"
}

need_root() {
    if is_root; then
        return 0
    fi
    echo "Need root for: $1 (run with sudo)" >&2
    return 1
}

list_autostart() {
    local dir d f id name
    dir="$(autostart_dir)"
    for d in /usr/share/applications "$dir"; do
        for f in "$d"/*.desktop; do
            [[ -f $f ]] || continue
            grep -q '^Hidden=true' "$f" && continue
            grep -q '^X-GNOME-Autostart-enabled=false' "$f" && continue
            name="$(sed -n 's/^Name=//p' "$f" | head -1)"
            id="$(basename "$f" .desktop)"
            printf '%s\t%s\n' "$id" "${name:-$id}"
        done
    done | sort -u
}

autostart_add() {
    local id="$1" desktop_file
    local app_dir="/usr/share/applications"
    for d in /usr/share/applications /usr/local/share/applications; do
        if [[ -f "$d/$id.desktop" ]]; then
            desktop_file="$d/$id.desktop"
            break
        fi
    done
    if [[ -z $desktop_file ]]; then
        echo "App $id.desktop not found" >&2
        return 1
    fi
    local dest; dest="$(autostart_dir)/$id.desktop"
    mkdir -p "$(dirname "$dest")"
    if [[ -f $dest ]]; then
        echo "Already autostarted: $id"
        return 0
    fi
    cp "$desktop_file" "$dest"
    sed -i '/^Exec=/s/$/ \&/' "$dest" 2>/dev/null || true
    if is_root; then
        chown "$TVPC_USER:$TVPC_USER" "$dest" 2>/dev/null || true
    fi
    echo "Added to autostart: $id"
}

autostart_remove() {
    local id="$1" dest
    dest="$(autostart_dir)/$id.desktop"
    if [[ -f $dest ]]; then
        rm -f "$dest"
        echo "Removed from autostart: $id"
    else
        echo "Not in autostart: $id"
    fi
}

detect_edid() {
    local out; out="$(output_id)"
    if [[ -n $out ]]; then
        echo "Output device: $out"
    fi
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local edid_raw; edid_raw=$(kscreen-doctor -o 2>/dev/null | grep -i edid | head -1)
        if [[ -n $edid_raw ]]; then
            echo "EDID info: $edid_raw"
        fi
    fi
    echo "Suggested modes:"
    if command -v cvt >/dev/null 2>&1; then
        echo "  1920x1080@60: cvt 1920 1080 60"
    elif command -v gtf >/dev/null 2>&1; then
        echo "  1920x1080@60: gtf 1920 1080 60"
    else
        echo "  Install cvt or gtf for mode calculation"
    fi
}

cmd_status() {
    local scale font theme mode
    scale="${TVPC_SCALE:-1.5}"
    font="$(get_kg font | cut -d, -f2)"
    theme="$(get_kg ColorScheme)"
    mode="${TVPC_MODE:-auto}"
    echo "== tvpc tweaks status =="
    echo "session  : ${TVPC_SESSION:-unset}"
    echo "scale    : $scale"
    echo "font     : ${font:-unset}pt base"
    echo "theme    : $theme"
    echo "mode     : $mode"
    echo
    echo "hidden from home screen:"
    local hidden; hidden="$(read_blacklist | paste -sd, -)"
    echo "  ${hidden:- (none)}"
    echo
    echo "autostart:"
    local a; a="$(list_autostart | cut -f2 | paste -sd, -)"
    echo "  ${a:- (none)}"
}

usage() {
    cat <<'EOF'
tvpc-tweaks -- TV box customization tool

Usage: tvpc-tweaks <command> [args]

Commands:
  scale <factor>   Set UI scale (e.g. 1.5)
  font <size>      Set base font size in points
  apps             List apps (shown/hidden from home)
  hide <app,ids>   Hide apps from home screen
  show <app,ids>   Show hidden apps on home screen
  theme <dark|light>  Set color theme
  mode <mode|auto> Set display mode (e.g. 1920x1080@60 or auto)
  idle <on|off>    Allow TV sleep or stay awake
  density <level>  UI density (comfortable/normal/compact)
  hdr <on|off>     Toggle HDR output (live)
  edid             Detect EDID and suggest modes
  setup            Apply TVPC_SCALE/TVPC_MODE live (autostart)
  audio <status|volume up/down N|mute|profile NAME>  HDMI audio control
  autostart        Manage autostart apps (interactive)
  session <name>   Switch desktop session (needs root)
  status           Show current configuration
  cec              Edit CEC key mappings (needs root)
  install-launcher Install home-screen launcher
  vacuum-only      Home: only VacuumTube + All Apps
  home-preset      Full curated home (dark theme + hero + Power + curated tiles)
  --help, -h       Show this help

Run without arguments for interactive TUI.
EOF
}

vacuum_only() {
    echo "Setting vacuum-only home (only VacuumTube + All Apps visible)..."
    hide_app "vacuumtube" 2>/dev/null || true
    local hidden; hidden="$(read_blacklist)"
    local to_show
    to_show=$(echo "$hidden" | tr ',' '\n' | grep -v '^vacuumtube$' | grep -v '^$' | paste -sd, -)
    if [[ -n $to_show ]]; then
        for id in $(echo "$to_show" | tr ',' ' '); do
            [[ $id != "vacuumtube" ]] && show_app "$id" 2>/dev/null || true
        done
    fi
    echo "Home screen now shows only VacuumTube and All Apps launcher."
}

home_preset() {
    echo "Applying full home-screen preset (dark theme + curated apps + Power tile)..."
    do_theme "dark"
    local curated="vacuumtube,systemsettings,firefox,org.kde.plasma-browser-integration"
    hide_app "systemsettings" 2>/dev/null || true
    local black
    black="$(echo "$curated" | tr ',' '\n' | sort -u)"
    for id in $black; do
        hide_app "$id" 2>/dev/null || true
    done
    if is_root; then
        local launcher_d="/usr/share/applications"
        local app_dir="$(autostart_dir)"
        if [[ -d "$app_dir" ]]; then
            local allapps_src="$REPO_ROOT/scripts/tvpc-allapps.sh"
            if [[ -f $allapps_src ]]; then
                cat >"$launcher_d/tvpc-allapps.desktop" <<'EOF'
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
            fi
        fi
        local power_d="/usr/share/applications"
        cat >"$power_d/tvpc-power.desktop" <<'EOF'
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
        cat >"$power_d/tvpc-tweaks.desktop" <<'EOF'
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
        echo "Launcher installed."
    fi
    apply_wallpaper
    echo "Home preset applied. Log out and back in to see changes."
}

install_launcher() {
    local kdegk; kdegk="$(kglobals_path)"
    if [[ -f $kdegk ]]; then
        if ! grep -q "tvpc-tweaks.desktop" "$kdegk" 2>/dev/null; then
            echo "Could not add to favorites"
        fi
    fi
    if is_root; then
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
        echo "Installed tvpc-tweaks launcher to /usr/share/applications/"
    else
        echo "Need root to install launcher system-wide"
    fi
}

cmd_edid() {
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local out; out="$(output_id)"
        if [[ -n $out ]]; then
            echo "Connected output: $out"
        fi
    fi
    detect_edid
}

cmd_hdr() {
    local state="${1:-on}"
    command -v kscreen-doctor >/dev/null 2>&1 || {
        echo "kscreen-doctor missing"
        return 1
    }
    local out; out="$(output_id)"
    if [[ -z $out ]]; then
        echo "no output"
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
    local level="$1"
    case "$level" in
        comfortable|normal|compact) ;;
        *)
            echo "usage: tvpc-tweaks density comfortable|normal/compact"
            return 1
            ;;
    esac
    case "$level" in
        comfortable)
            kde_set "General" "font" "Noto Sans,15,-1,5,50,0,0,0,0,0"
            kde_set "General" "menuFont" "Noto Sans,15,-1,5,50,0,0,0,0,0"
            kde_set "General" "fixed" "Noto Sans Mono,14,-1,5,50,0,0,0,0,0"
            kde_set "General" "toolBarFont" "Noto Sans,14,-1,5,50,0,0,0,0,0"
            kde_set "General" "smallestReadableFont" "Noto Sans,13,-1,5,50,0,0,0,0,0"
            kde_set "Icons" "Size" "48"
            ;;
        normal)
            kde_set "General" "font" "Noto Sans,13,-1,5,50,0,0,0,0,0"
            kde_set "General" "menuFont" "Noto Sans,13,-1,5,50,0,0,0,0,0"
            kde_set "General" "fixed" "Noto Sans Mono,12,-1,5,50,0,0,0,0,0"
            kde_set "General" "toolBarFont" "Noto Sans,12,-1,5,50,0,0,0,0,0"
            kde_set "General" "smallestReadableFont" "Noto Sans,11,-1,5,50,0,0,0,0,0"
            kde_set "Icons" "Size" "32"
            ;;
        compact)
            kde_set "General" "font" "Noto Sans,11,-1,5,50,0,0,0,0,0"
            kde_set "General" "menuFont" "Noto Sans,11,-1,5,50,0,0,0,0,0"
            kde_set "General" "fixed" "Noto Sans Mono,10,-1,5,50,0,0,0,0,0"
            kde_set "General" "toolBarFont" "Noto Sans,10,-1,5,50,0,0,0,0,0"
            kde_set "General" "smallestReadableFont" "Noto Sans,9,-1,5,50,0,0,0,0,0"
            kde_set "Icons" "Size" "24"
            ;;
    esac
    echo "UI density -> $level (font=$(get_kg font | cut -d, -f2), icons=$(get_kg 'Icons' 'Size'))"
}

# tvpc-display-setup inlined: apply TVPC_SCALE/TVPC_MODE from /etc/default/tvpc
cmd_setup() {
    command -v kscreen-doctor >/dev/null 2>&1 || {
        echo "kscreen-doctor missing; skipping display setup"
        return 0
    }
    for _ in $(seq 1 15); do
        kscreen-doctor -o >/dev/null 2>&1 && break
        sleep 2
    done
    local out; out="$(output_id)"
    if [[ -z $out ]]; then
        echo "no enabled output reported; skipping"
        return 0
    fi
    local mode="${TVPC_MODE:-}"
    if [[ -n $mode ]]; then
        kscreen-doctor "output.$out.mode.$mode" \
            && echo "mode -> $mode on $out" \
            || echo "could not set mode $mode (see: kscreen-doctor -o)"
    fi
    local scale="${TVPC_SCALE:-1.5}"
    if [[ $scale != "1" && $scale != "1.0" ]]; then
        kscreen-doctor "output.$out.scale.$scale" \
            && echo "scale -> $scale on $out" \
            || echo "could not set scale $scale"
    fi
}

# Audio management (inlined from tvpc-audio-manager.sh)
cmd_audio() {
    local sub="${2:-status}"
    case "$sub" in
        status)
            echo "=== Audio Status ==="
            echo "Default sink: $(pactl get-default-sink 2>/dev/null || true)"
            echo
            echo "Available sinks:"
            pactl list short sinks 2>/dev/null
            echo
            echo "Current volume: $(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk '{print $5}' | tr -d '%')%"
            echo "Mute: $(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')"
            ;;
        volume)
            local level="$3"
            if [[ -z $level ]]; then
                echo "Current volume: $(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk '{print $5}' | tr -d '%')%"
            elif [[ $level == "up" ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ +5%
                echo "Volume increased by 5%"
            elif [[ $level == "down" ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ -5%
                echo "Volume decreased by 5%"
            elif [[ $level =~ ^[0-9]+$ ]] && [[ $level -ge 0 ]] && [[ $level -le 100 ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ "${level}%"
                echo "Volume set to ${level}%"
            else
                echo "Error: Volume must be 0-100 or up/down" >&2
                return 1
            fi
            ;;
        mute)
            pactl set-sink-mute @DEFAULT_SINK@ toggle
            local m; m="$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')"
            if [[ $m == "yes" ]]; then
                echo "Audio muted"
            else
                echo "Audio unmuted"
            fi
            ;;
        profile)
            local prof="$3"
            if [[ -z $prof ]]; then
                echo "Available profiles:"
                pactl list cards 2>/dev/null | sed -n '/Profiles:/,/^ *$/p'
                return 0
            fi
            local card; card="$(pactl list short cards 2>/dev/null | head -1 | awk '{print $2}')"
            if [[ -n $card ]] && pactl set-card-profile "$card" "$prof" 2>/dev/null; then
                echo "Profile set to $prof"
            else
                echo "Failed to set profile: $prof" >&2
                return 1
            fi
            ;;
        *)
            echo "Usage: tvpc-tweaks audio status|volume|mute|profile" >&2
            return 1
            ;;
    esac
}

cmd_eq() {
    local preset="${1:-off}"
    if [[ $preset == off ]]; then
        rm -f "$EQ_CONF" 2>/dev/null || true
        echo "EQ disabled"
        return 0
    fi
    local found=0
    for p in "${EQ_PRESETS[@]}"; do
        if [[ $p == "$preset" ]]; then
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "Unknown preset: $preset"
        echo "Available: ${EQ_PRESETS[*]} off"
        return 1
    fi
    local bands="${EQ_BANDS_DEFAULT[*]}"
    local eqs
    eqs=$(IFS=:; echo "$bands")
    mkdir -p "$(dirname "$EQ_CONF")"
    cat >"$EQ_CONF" <<EOF
context.modules = [
  { factory = "filter-chain"
    args = {
      node.description = "tvpc EQ"
      media.name = "tvpc EQ"
      filter.graph = {
        nodes = [ { type = ladspa
                    plugin = mbeq_1901
                    label = mbeq
                    control = { $eqs } } ]
        inputs = [ "in_1" "in_2" ];
        outputs = [ "out_1" "out_2" ];
        links = [ { in = "in_1", out = "out_1" }
                  { in = "in_2", out = "out_2" } ]
      }
      capture.props = { node.name = "tvpc.eq.source" }
      playback.props = { node.name = "tvpc.eq.sink" node.target = "auto" }
    }
  }
]
EOF
    echo "EQ -> $preset (requires swh-plugins; restart pipewire to apply)"
}

install_cec() {
    local cec_script="/usr/local/bin/tvpc-cec-listener.sh"
    if [[ ! -f "$cec_script" ]]; then
        cat >"$cec_script" <<'CECEOF'
#!/usr/bin/env bash
# tvpc-cec-listener - CEC remote handler
set -o pipefail
[ -f /etc/tvpc/cec-map.conf ] || exit 0
while IFS= read -r line; do
    [[ $line == \#* ]] && continue
    [[ -z $line" ]] && continue
    code=$(echo "$line" | awk '{print $1}')
    action=$(echo "$line" | awk '{print $2}')
    [[ -z $code" ]] && continue
    case "$action" in
        key:*)
            keycode="${action#key:}"
            [ -n "$keycode" ] && echo "key $keycode" &
            ;;
        mpris:*)
            cmd="${action#mpris:}"
            playerctl "$cmd" 2>/dev/null &
            ;;
        pactl:*)
            args="${action#pactl:}"
            pactl "$args" 2>/dev/null &
            ;;
        app:*)
            appid="${action#app:}"
            flatpak run "$appid" 2>/dev/null &
            ;;
        macro:*)
            macroname="${action#macro:}"
            [[ -f /etc/tvpc/cec-macros.conf ]] && \
                grep "^$macroname " /etc/tvpc/cec-macros.conf | \
                awk '{for(i=2;i<=NF;i++) print $i}' | \
                while read -r m; do
                    case "$m" in
                        key:*) echo "key ${m#key:}" & ;;
                        mpris:*) playerctl "${m#mpris:}" 2>/dev/null & ;;
                        pactl:*) pactl "${m#pactl:}" 2>/dev/null & ;;
                        cmd:*) eval "${m#cmd:}" & ;;
                    esac
                done
            ;;
        mouse)
            echo "toggle-mouse" &
            ;;
        cmd:*)
            eval "${action#cmd:}" &
            ;;
    esac
done < /etc/tvpc/cec-map.conf
CECEOF
        chmod +x "$cec_script"
    fi
}

tui_cec() {
    need_root "cec" || return 1
    install_cec
    local codes=(00 01 02 03 04 09 0d 41 42 43 44 45 46 47 48)
    local names=(OK Up Down Left Right "Home/Root" Exit Vol+ Vol- Mute Play Pause Stop Next)
    mkdir -p "$(dirname "$CEC_MAP")"
    if [[ ! -f $CEC_MAP ]]; then
        cat >"$CEC_MAP" <<'EOF'
00 key:28
01 key:103
02 key:108
03 key:105
04 key:106
09 key:125
0d key:1
41 pactl:+2%
42 pactl:-2%
43 pactl:toggle
44 mpris:play-pause
45 mpris:next
46 mpris:stop
47 mpris:previous
EOF
    fi
    while true; do
        menu_reset
        local i
        for ((i=0; i<${#codes[@]}; i++)); do
            local act
            act=$(grep "^${codes[$i]} " "$CEC_MAP" 2>/dev/null | awk '{print $2}' | head -1)
            [[ -z "$act" ]] && act="none"
            menu_add "${codes[$i]}" "${names[$i]} -> $act"
        done
        menu_add back "Back"
        select_list "CEC remote keys"
        if [[ $RESULT == back || -z $RESULT ]]; then
            break
        fi
        cec_edit_key "$RESULT"
        systemctl restart tvpc-cec-remote 2>/dev/null || true
        echo "CEC map updated; listener restarted."
    done
}

cec_edit_key() {
    local code="$1"
    menu_reset
    menu_add key "Key press (linux keycode)"
    menu_add mpris "Media (playerctl)"
    menu_add pactl "Volume"
    menu_add app "Launch app"
    menu_add cmd "Shell command"
    menu_add none "Disabled"
    menu_add cancel "Cancel"
    select_list "Action for key 0x$code"
    case "$RESULT" in
        cancel|"") return ;;
        key)
            clear
            printf 'Linux keycode (e.g. 28=Enter 125=Super 103=Up): '
            read -r v
            if [[ -n "$v" ]]; then
                write_cec_map "$code" "key:$v"
            fi
            ;;
        mpris)
            menu_reset
            for m in play-pause stop next previous; do
                menu_add "$m" "$m"
            done
            menu_add cancel "Cancel"
            select_list "Media action"
            if [[ -n "$RESULT" && $RESULT != cancel ]]; then
                write_cec_map "$code" "mpris:$RESULT"
            fi
            ;;
        pactl)
            menu_reset
            for v in "+2%" "-2%" "toggle"; do
                menu_add "$v" "$v"
            done
            menu_add cancel "Cancel"
            select_list "Volume"
            if [[ -n "$RESULT" && $RESULT != cancel ]]; then
                write_cec_map "$code" "pactl:$RESULT"
            fi
            ;;
        app)
            menu_reset
            while IFS=$'\t' read -r id name; do
                menu_add "$id" "$name"
            done < <(list_apps)
            menu_add cancel "Cancel"
            select_list "App to launch"
            if [[ -n "$RESULT" && $RESULT != cancel ]]; then
                write_cec_map "$code" "app:$RESULT"
            fi
            ;;
        cmd)
            clear
            printf 'Shell command: '
            read -r v
            if [[ -n "$v" ]]; then
                write_cec_map "$code" "cmd:$v"
            fi
            ;;
        none)
            write_cec_map "$code" "none"
            ;;
    esac
}

write_cec_map() {
    local code="$1" act="$2"
    mkdir -p "$(dirname "$CEC_MAP")"
    if [[ ! -f $CEC_MAP ]]; then
        touch "$CEC_MAP"
    fi
    local tmp; tmp="$(mktemp)"
    local found=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$code "* ]]; then
            echo "$code $act"
            found=1
        else
            echo "$line"
        fi
    done <"$CEC_MAP" >"$tmp"
    if [[ $found -eq 0 ]]; then
        echo "$code $act" >>"$tmp"
    fi
    mv "$tmp" "$CEC_MAP"
}

add_network_tiles() {
    local tile_dir="$HOME/.local/share/applications"
    mkdir -p "$tile_dir"
    cat >"$tile_dir/tvpc-wifi.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Wi-Fi
Comment=Network settings
Exec=kcmshell5 kcm_networkmanagement
Terminal=false
Icon=network-wireless
Categories=Settings;Network;
EOF
    cat >"$tile_dir/tvpc-bluetooth.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Bluetooth
Comment=Bluetooth settings
Exec=kcmshell5 bluetooth
Terminal=false
Icon=bluetooth
Categories=Settings;Network;
EOF
    if is_root; then
        chown -R "$TVPC_USER:$TVPC_USER" "$tile_dir" 2>/dev/null || true
    fi
    echo "Added Wi-Fi and Bluetooth tiles (visible in All Apps/home when not curated)."
}

item_val=()
item_label=()
result=""
readkey=""

menu_reset() {
    item_val=()
    item_label=()
}

menu_add() {
    item_val+=("$1")
    item_label+=("$2")
}

read_key() {
    local k k2 k3
    IFS= read -rsn1 -t 1 k || { readkey="cancel"; return; }
    if [[ $k == $'\e' ]]; then
        IFS= read -rsn1 -t 0.01 k2
        IFS= read -rsn1 -t 0.01 k3
        k="$k$k2$k3"
    fi
    readkey="$k"
}

pause_msg() {
    printf '\n\033[1;33m%s\033[0m\n' "$1"
    printf '\033[2m(press any key)\033[0m'
    read_key
}

select_list() {
    local title="$1"
    local n=${#item_val[@]}
    local sel=0
    local top=0
    local avail
    local h
    h=$(tput lines 2>/dev/null || echo 24)
    avail=$((h - 5))
    [[ $avail -lt 3 ]] && avail=3
    while true; do
        clear
        printf '\033[1;36m%s\033[0m\n' "$title"
        printf '\033[2m(up/down: move  ·  Enter: select  ·  q/Esc: back)\033[0m\n\n'
        local i
        for ((i=top; i<n && i<top+avail; i++)); do
            if [[ $i -eq $sel ]]; then
                printf '  \033[1;32m> %s\033[0m\n' "${item_label[$i]}"
            else
                printf '    %s\n' "${item_label[$i]}"
            fi
        done
        for ((i=n<top+avail?n:top+avail; i<top+avail; i++)); do
            echo
        done
        read_key
        case "$readkey" in
            $'\e[A')
                [[ $sel -gt 0 ]] && sel=$((sel - 1))
                [[ $sel -lt $top ]] && top=$sel
                ;;
            $'\e[B')
                [[ $sel -lt $((n - 1)) ]] && sel=$((sel + 1))
                [[ $sel -ge $((top + avail)) ]] && top=$((sel - $avail + 1))
                ;;
            "")
                result="${item_val[$sel]}"
                return 0
                ;;
            q|Q|$'\e')
                result=""
                return 1
                ;;
            [0-9])
                local d=$((10#$readkey))
                if [[ $d -lt $n ]]; then
                    sel=$d
                    result="${item_val[$sel]}"
                    return 0
                fi
                ;;
        esac
    done
}

tui_scale() {
    local cur="${TVPC_SCALE:-1.5}"
    menu_reset
    local f
    for f in 0.75 1 1.25 1.5 1.75 2; do
        local tag=""
        if [[ $f == "$cur" ]]; then
            tag="  (current)"
        fi
        menu_add "$f" "$f ×$tag"
    done
    menu_add custom "Set a custom scale…"
    menu_add font "Base font size (Bigscreen whole-UI scale)…"
    menu_add back "Back"
    select_list "UI scaling"
    case "$result" in
        custom)
            clear
            printf 'Enter scale factor (e.g. 1.25): '
            read -r v
            if [[ -n "$v" ]]; then
                do_scale "$v"
            fi
            ;;
        font)
            clear
            printf 'Enter base font size in points (Bigscreen: try 10): '
            read -r v
            if [[ $v =~ ^[0-9]+$ ]]; then
                do_font "$v"
            fi
            ;;
        back|"")
            return
            ;;
        *)
            do_scale "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_apps() {
    local -a AID ANAME AHID
    local id name
    while IFS=$'\t' read -r id name; do
        AID+=("$id")
        ANAME+=("$name")
        if app_is_hidden "$id"; then
            AHID+=(1)
        else
            AHID+=(0)
        fi
    done < <(list_apps)
    local n=${#AID[@]}
    local sel=0
    local top=0
    local avail
    local h
    h=$(tput lines 2>/dev/null || echo 24)
    avail=$((h - 5))
    [[ $avail -lt 3 ]] && avail=3
    while true; do
        clear
        printf '\033[1;36mHome-screen apps\033[0m\n'
        printf '\033[2m(Enter: toggle shown/hidden  ·  q/Esc: back)\033[0m\n\n'
        local i
        for ((i=top; i<n && i<top+avail; i++)); do
            local mark
            if [[ ${AHID[$i]} -eq 1 ]]; then
                mark="\033[1;31m[hidden]\033[0m"
            else
                mark="\033[1;32m[shown ]\033[0m"
            fi
            if [[ $i -eq $sel ]]; then
                printf '  \033[1;32m>\033[0m %-40s %b\n' "${ANAME[$i]}" "$mark"
            else
                printf '    %-40s %b\n' "${ANAME[$i]}" "$mark"
            fi
        done
        for ((i=n<top+avail?n:top+avail; i<top+avail; i++)); do
            echo
        done
        read_key
        case "$readkey" in
            $'\e[A')
                [[ $sel -gt 0 ]] && sel=$((sel - 1))
                [[ $sel -lt $top ]] && top=$sel
                ;;
            $'\e[B')
                [[ $sel -lt $((n - 1)) ]] && sel=$((sel + 1))
                [[ $sel -ge $((top + avail)) ]] && top=$((sel - $avail + 1))
                ;;
            "")
                if [[ ${AHID[$sel]} -eq 1 ]]; then
                    show_app "${AID[$sel]}"
                    AHID[$sel]=0
                else
                    hide_app "${AID[$sel]}"
                    AHID[$sel]=1
                fi
                ;;
            q|Q|$'\e')
                return
                ;;
        esac
    done
}

tui_theme() {
    menu_reset
    menu_add dark "Dark (Breeze Dark)"
    menu_add light "Light (Breeze)"
    menu_add back "Back"
    select_list "Theme"
    case "$result" in
        dark|light)
            do_theme "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_mode() {
    menu_reset
    menu_add auto "Auto (use the TV's EDID)"
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local m
        while IFS= read -r m; do
            if [[ -n "$m" ]]; then
                menu_add "$m" "$m"
            fi
        done < <(kscreen-doctor -o 2>/dev/null | grep -oE 'Mode [0-9]+: [0-9]+x[0-9]+@[0-9.]+' | sed -E 's/Mode [0-9]+: //')
    fi
    menu_add back "Back"
    select_list "Display mode"
    case "$result" in
        back|"") return ;;
        *)
            do_mode "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_idle() {
    menu_reset
    menu_add on "Stay awake (TV never sleeps)"
    menu_add off "Allow sleep after ~5 min idle"
    menu_add back "Back"
    select_list "TV sleep"
    case "$result" in
        on|off)
            do_idle "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_density() {
    menu_reset
    menu_add comfortable "Comfortable (larger text & icons)"
    menu_add normal "Normal (default)"
    menu_add compact "Compact (smaller)"
    menu_add back "Back"
    select_list "UI density"
    case "$result" in
        comfortable|normal|compact)
            cmd_density "$result"
            ;;
    esac
    pause_msg "Done."
}

tui_autostart() {
    while true; do
        menu_reset
        local id name
        while IFS=$'\t' read -r id name; do
            menu_add "rm:$id" "Remove: $name"
        done < <(list_autostart)
        menu_add add "＋ Add an app…"
        menu_add back "Back"
        select_list "Autostart apps"
        case "$result" in
            back|"")
                return
                ;;
            add)
                menu_reset
                while IFS=$'\t' read -r id name; do
                    menu_add "$id" "$name"
                done < <(list_apps)
                menu_add cancel "Cancel"
                select_list "Add which app to autostart?"
                if [[ -n "$result" && $result != cancel ]]; then
                    autostart_add "$result"
                fi
                ;;
            rm:*)
                autostart_remove "${result#rm:}"
                ;;
        esac
    done
    pause_msg "Done."
}

tui_session() {
    menu_reset
    local s
    for s in auto plasma plasma-mobile plasma-x11 kiosk bigscreen bigscreen-x11 hypr phosh; do
        menu_add "$s" "$s"
    done
    menu_add back "Back"
    select_list "Switch session (needs root)"
    case "$result" in
        back|"") return ;;
        *)
            if need_root "session $result"; then
                switch_session "$result"
                pause_msg "Switched. Restart the display manager to pick it up: sudo systemctl restart sddm"
            fi
            ;;
    esac
}

tui_status() {
    cmd_status
    pause_msg ""
}

tui_main() {
    while true; do
        menu_reset
        menu_add scale "UI scaling"
        menu_add apps "Home-screen apps"
        menu_add theme "Theme"
        menu_add mode "Display mode"
        menu_add idle "TV sleep"
        menu_add autostart "Autostart apps"
        menu_add session "Session"
        menu_add status "Show status"
        menu_add edid "EDID / display detection"
        menu_add hdr "HDR toggle"
        menu_add density "UI density"
        menu_add audio "Audio (HDMI / volume)"
        menu_add cec "CEC key mappings"
        menu_add quit "Exit"
        select_list "tvpc Tweaks"
        case "$result" in
            scale)     tui_scale ;;
            apps)      tui_apps ;;
            theme)     tui_theme ;;
            mode)      tui_mode ;;
            idle)      tui_idle ;;
            autostart) tui_autostart ;;
            session)   tui_session ;;
            status)    tui_status ;;
            edid)
                clear
                cmd_edid
                pause_msg ""
                ;;
            hdr)
                clear
                cmd_hdr on
                pause_msg ""
                ;;
            density)   tui_density ;;
            audio)
                clear
                cmd_audio status
                pause_msg ""
                ;;
            cec)       tui_cec ;;
            quit|"")   return ;;
        esac
    done
}

load_plugins() {
    local d f
    for d in /usr/local/share/tvpc-tweaks/plugins.d "$HOME/.config/tvpc-tweaks/plugins.d"; do
        [[ -d $d ]] || continue
        for f in "$d"/*.sh; do
            [[ -f $f ]] && . "$f"
        done
    done
}

plugin_manager() {
    while true; do
        menu_reset
        local i
        for ((i=0; i<${#TVPC_PLUGIN_IDS[@]}; i++)); do
            menu_add "plugin:${TVPC_PLUGIN_IDS[$i]}" "${TVPC_PLUGIN_LABELS[$i]}"
        done
        menu_add back "Back"
        select_list "Plugins"
        case "$result" in
            back|"")
                return
                ;;
            plugin:*)
                local id="${result#plugin:}"
                tvpc_plugin_"$id"
                pause_msg "Plugin completed."
                ;;
        esac
    done
}

cmd_wifi() {
    if [[ -t 0 ]]; then
        kcmshell5 kcm_networkmanagement 2>/dev/null || echo "kcm_networkmanagement not available"
    else
        echo "Run from a TTY or GUI" >&2
    fi
}

cmd_bluetooth() {
    if [[ -t 0 ]]; then
        kcmshell5 bluetooth 2>/dev/null || echo "bluetooth module not available"
    else
        echo "Run from a TTY or GUI" >&2
    fi
}

case "${1:-}" in
    scale)
        shift
        do_scale "${1:-}"
        ;;
    font)
        shift
        do_font "${1:-}"
        ;;
    apps)
        while IFS=$'\t' read -r id name; do
            if app_is_hidden "$id"; then
                st="hidden"
            else
                st="shown"
            fi
            printf '%-45s %-30s %s\n' "$id" "${name:0:29}" "$st"
        done < <(list_apps)
        ;;
    hide)
        shift
        need_root "hide $*" || exit 1
        IFS=',' read -ra ids <<<"$*"
        for id in "${ids[@]}"; do
            hide_app "$id"
        done
        echo "Hidden: ${ids[*]}  (log out and back in)"
        ;;
    show)
        shift
        need_root "show $*" || exit 1
        IFS=',' read -ra ids <<<"$*"
        for id in "${ids[@]}"; do
            show_app "$id"
        done
        echo "Shown again: ${ids[*]}  (log out and back in)"
        ;;
    theme)
        shift
        do_theme "${1:-}"
        ;;
    mode)
        shift
        do_mode "${1:-auto}"
        ;;
    idle)
        shift
        do_idle "${1:-on}"
        ;;
    density)
        shift
        cmd_density "${1:-normal}"
        ;;
    hdr)
        shift
        cmd_hdr "${1:-on}"
        ;;
    eq)
        shift
        cmd_eq "${1:-off}"
        ;;
    edid)
        cmd_edid
        ;;
    autostart)
        tui_autostart
        ;;
    session)
        shift
        need_root "session $*" || exit 1
        switch_session "${1:-auto}"
        ;;
    status)
        cmd_status
        ;;
    cec|cec-map)
        need_root "cec" || exit 1
        tui_cec
        ;;
    install-launcher)
        install_launcher
        ;;
    vacuum-only)
        vacuum_only
        ;;
    home)
        home_preset
        ;;
    network-tiles)
        add_network_tiles
        ;;
    setup)
        cmd_setup
        ;;
    audio)
        cmd_audio "$@"
        ;;
    splash)
        shift
        cmd_splash "${1:-}"
        ;;
    --help|-h|help)
        usage
        exit 0
        ;;
    "")
        if [[ -t 1 ]]; then
            load_plugins
            tui_main
        else
            usage
        fi
        ;;
    *)
        echo "Unknown command '$1' (try: tvpc-tweaks --help)" >&2
        exit 1
        ;;
esac