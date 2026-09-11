#!/usr/bin/env bash
# tvpc-bigscreen-theme — Manage modern themes and homescreen styling for Plasma Bigscreen
#
# Usage:
#   tvpc-bigscreen-theme list                 List available themes & active theme
#   tvpc-bigscreen-theme set <theme>          Switch active theme (midnight, oled, cyberpunk, sunset, emerald)
#   sudo tvpc-bigscreen-theme install         Deploy modern homescreen overlay system-wide
#   sudo tvpc-bigscreen-theme revert          Restore original upstream Bigscreen homescreen
#   tvpc-bigscreen-theme status               Show installation & theme status
#   tvpc-bigscreen-theme preview [theme]      Show color palette preview in terminal
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS_CONF="/etc/tvpc/bigscreen-theme.json"
SYS_DEFAULT="/etc/default/tvpc"
SYS_PLASMOID_DIR="/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"
SYS_BACKUP_DIR="/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen.tvpc-orig"
OVERLAY_SRC="$REPO_ROOT/overlays/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"

if [[ -r "$SYS_DEFAULT" ]]; then
    # shellcheck source=/dev/null
    . "$SYS_DEFAULT"
fi
TVPC_USER="${TVPC_USER:-${HTPC_USER:-htpc}}"

get_user_home() {
    if [[ $EUID -eq 0 ]]; then
        local h; h="$(getent passwd "$TVPC_USER" | cut -d: -f6 || true)"
        if [[ -n "$h" && -d "$h" ]]; then
            echo "$h"
        else
            echo "${HOME:-/home/$TVPC_USER}"
        fi
    else
        echo "${HOME:-/home/$USER}"
    fi
}

USER_CONF="$(get_user_home)/.config/tvpc/bigscreen-theme.json"
USER_PLASMOID_DIR="$(get_user_home)/.local/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"

THEMES=(
    "midnight:Midnight Glass:Deep obsidian & frosted navy with vibrant sky-blue glow (Default)"
    "oled:OLED Stealth:Pure pitch black with high-contrast monochrome & silver accents"
    "cyberpunk:Cyberpunk Neon:Dark violet glass with electric magenta & neon cyan accents"
    "sunset:Sunset Amber:Dark charcoal glass with warm amber & radiant sunset glow"
    "emerald:Emerald Pine:Deep forest glass with lush mint & emerald accents"
)

get_active_theme() {
    local t=""
    if [[ -f "$USER_CONF" ]]; then
        t="$(grep -o '"theme": *"[^"]*"' "$USER_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    fi
    if [[ -z "$t" && -f "$SYS_CONF" ]]; then
        t="$(grep -o '"theme": *"[^"]*"' "$SYS_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    fi
    if [[ -z "$t" && -n "${TVPC_BIGSCREEN_THEME:-}" ]]; then
        t="$TVPC_BIGSCREEN_THEME"
    fi
    echo "${t:-midnight}"
}

cmd_list() {
    local active; active="$(get_active_theme)"
    echo "============================================================"
    echo "  Plasma Bigscreen Modern Themes"
    echo "============================================================"
    printf "%-12s %-18s %-6s %s\n" "ID" "NAME" "STATE" "DESCRIPTION"
    printf "%-12s %-18s %-6s %s\n" "------------" "------------------" "------" "----------------------------------------"
    for item in "${THEMES[@]}"; do
        IFS=":" read -r id name desc <<<"$item"
        local mark="      "
        if [[ "$id" == "$active" ]]; then
            mark="[ACTIVE]"
        fi
        printf "%-12s %-18s %-6s %s\n" "$id" "$name" "$mark" "$desc"
    done
    echo
    echo "Switch theme with:  tvpc-bigscreen-theme set <id>"
}

cmd_set() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "Usage: tvpc-bigscreen-theme set <theme-id>" >&2
        echo "Valid themes: midnight, oled, cyberpunk, sunset, emerald" >&2
        exit 1
    fi

    local valid=0
    for item in "${THEMES[@]}"; do
        IFS=":" read -r id name desc <<<"$item"
        if [[ "$id" == "$target" ]]; then
            valid=1
            break
        fi
    done

    if [[ $valid -eq 0 ]]; then
        echo "Error: Unknown theme '$target'." >&2
        echo "Available themes: midnight, oled, cyberpunk, sunset, emerald" >&2
        exit 1
    fi

    # Write configuration
    local json="{\n  \"theme\": \"$target\",\n  \"updated_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"\n}\n"

    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$(dirname "$SYS_CONF")"
        printf "%b" "$json" >"$SYS_CONF"
        chmod 0644 "$SYS_CONF"
        
        # Also persist in /etc/default/tvpc
        if [[ -f "$SYS_DEFAULT" ]]; then
            if grep -q '^TVPC_BIGSCREEN_THEME=' "$SYS_DEFAULT"; then
                sed -i "s/^TVPC_BIGSCREEN_THEME=.*/TVPC_BIGSCREEN_THEME=$target/" "$SYS_DEFAULT"
            else
                echo "TVPC_BIGSCREEN_THEME=$target" >>"$SYS_DEFAULT"
            fi
        fi

        # Seed user config as well
        local uh; uh="$(get_user_home)"
        if [[ -d "$uh" ]]; then
            mkdir -p "$uh/.config/tvpc"
            printf "%b" "$json" >"$uh/.config/tvpc/bigscreen-theme.json"
            chown -R "$TVPC_USER:$TVPC_USER" "$uh/.config/tvpc" 2>/dev/null || true
        fi
    else
        mkdir -p "$(dirname "$USER_CONF")"
        printf "%b" "$json" >"$USER_CONF"
    fi

    echo "Theme successfully set to: $target ($name)"
    if pgrep -x plasma-bigscreen >/dev/null 2>&1 || pgrep -x plasmashell >/dev/null 2>&1; then
        echo "Restart display session or restart Bigscreen to view theme changes."
    fi
}

apply_window_controls() {
    local target_dir="$1"
    mkdir -p "$target_dir"
    
    local kwinrc="$target_dir/kwinrc"
    if [[ ! -f "$kwinrc" ]]; then
        cat >"$kwinrc" <<'EOF'
[Windows]
BorderlessMaximizedWindows=false

[org.kde.kdecoration2]
BorderSize=Normal
ButtonsOnLeft=
ButtonsOnRight=X
CloseOnDoubleClickOnMenu=false
library=org.kde.breeze
theme=Breeze

[TabBox]
ActivitiesMode=1
ApplicationsMode=0
DesktopMode=0
HighlightWindows=true
LayoutName=thumbnail_grid
MultiScreenMode=0
OrderMinimizedMode=0
ShowDelay=false
ShowDesktop=true
SwitchingMode=0
EOF
    else
        if grep -q '^\[Windows\]' "$kwinrc"; then
            sed -i '/^\[Windows\]/a BorderlessMaximizedWindows=false' "$kwinrc"
        else
            printf '\n[Windows]\nBorderlessMaximizedWindows=false\n' >>"$kwinrc"
        fi
        if grep -q '^\[org\.kde\.kdecoration2\]' "$kwinrc"; then
            sed -i 's/^ButtonsOnRight=.*/ButtonsOnRight=X/' "$kwinrc"
        else
            printf '\n[org.kde.kdecoration2]\nButtonsOnRight=X\nlibrary=org.kde.breeze\ntheme=Breeze\n' >>"$kwinrc"
        fi
        if ! grep -q '^\[TabBox\]' "$kwinrc"; then
            cat >>"$kwinrc" <<'EOF'

[TabBox]
ActivitiesMode=1
ApplicationsMode=0
DesktopMode=0
HighlightWindows=true
LayoutName=thumbnail_grid
MultiScreenMode=0
OrderMinimizedMode=0
ShowDelay=false
ShowDesktop=true
SwitchingMode=0
EOF
        fi
    fi

    local kg="$target_dir/kglobalshortcutsrc"
    if [[ ! -f "$kg" ]]; then
        cat >"$kg" <<'EOF'
[kwin]
Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows
Walk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)
Walk Through Windows Alternative=none,,Walk Through Windows Alternative
Walk Through Windows Alternative (Reverse)=none,,Walk Through Windows Alternative (Reverse)
Window Close=Alt+F4,Alt+F4,Close Window
Show Desktop=Meta+D,Meta+D,Show Desktop
EOF
    else
        if ! grep -q 'Walk Through Windows=' "$kg"; then
            if grep -q '^\[kwin\]' "$kg"; then
                sed -i '/^\[kwin\]/a Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows\nWalk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)\nWindow Close=Alt+F4,Alt+F4,Close Window' "$kg"
            else
                cat >>"$kg" <<'EOF'

[kwin]
Walk Through Windows=Alt+Tab,Alt+Tab,Walk Through Windows
Walk Through Windows (Reverse)=Alt+Shift+Tab,Alt+Shift+Backtab,Walk Through Windows (Reverse)
Window Close=Alt+F4,Alt+F4,Close Window
EOF
            fi
        fi
    fi
}

cmd_install() {
    if [[ ! -d "$OVERLAY_SRC" ]]; then
        echo "Error: Source overlay directory not found at $OVERLAY_SRC" >&2
        exit 1
    fi

    if [[ $EUID -eq 0 ]]; then
        echo "== Installing Modern Bigscreen Homescreen (System-Wide) =="
        if [[ -d "$SYS_PLASMOID_DIR" && ! -d "$SYS_BACKUP_DIR" ]]; then
            echo "Backing up upstream Bigscreen homescreen -> $SYS_BACKUP_DIR"
            cp -a "$SYS_PLASMOID_DIR" "$SYS_BACKUP_DIR"
        fi

        mkdir -p "$SYS_PLASMOID_DIR"
        cp -a "$OVERLAY_SRC/." "$SYS_PLASMOID_DIR/"
        echo "Successfully deployed modern homescreen to $SYS_PLASMOID_DIR"

        apply_window_controls "/etc/skel/.config"
        local uh; uh="$(get_user_home)"
        if [[ -d "$uh" ]]; then
            apply_window_controls "$uh/.config"
            chown -R "$TVPC_USER:$TVPC_USER" "$uh/.config" 2>/dev/null || true
        fi
        echo "Configured Alt+Tab app switcher and Close X button in kwinrc/kglobalshortcutsrc"
    else
        echo "== Installing Modern Bigscreen Homescreen (User Override) =="
        mkdir -p "$USER_PLASMOID_DIR"
        cp -a "$OVERLAY_SRC/." "$USER_PLASMOID_DIR/"
        echo "Successfully deployed modern homescreen to $USER_PLASMOID_DIR"
        apply_window_controls "$(get_user_home)/.config"
        echo "Configured user Alt+Tab app switcher and Close X button"
        echo "(Tip: Run with sudo to install system-wide across all users)"
    fi
}

cmd_revert() {
    if [[ $EUID -eq 0 ]]; then
        if [[ -d "$SYS_BACKUP_DIR" ]]; then
            echo "Restoring original upstream Bigscreen homescreen from $SYS_BACKUP_DIR..."
            rm -rf "$SYS_PLASMOID_DIR"
            cp -a "$SYS_BACKUP_DIR" "$SYS_PLASMOID_DIR"
            rm -rf "$SYS_BACKUP_DIR"
            echo "Reverted system Bigscreen homescreen to upstream stock."
        else
            echo "No backup found at $SYS_BACKUP_DIR. Nothing to revert system-wide."
        fi
    fi

    if [[ -d "$USER_PLASMOID_DIR" ]]; then
        echo "Removing user override at $USER_PLASMOID_DIR..."
        rm -rf "$USER_PLASMOID_DIR"
        echo "Removed user override."
    fi
    echo "Revert complete."
}

cmd_status() {
    local active; active="$(get_active_theme)"
    echo "== Plasma Bigscreen Theme Status =="
    echo "Active Theme       : $active"
    echo "Config (System)    : $( [[ -f "$SYS_CONF" ]] && echo "Present ($SYS_CONF)" || echo "None" )"
    echo "Config (User)      : $( [[ -f "$USER_CONF" ]] && echo "Present ($USER_CONF)" || echo "None" )"
    echo "System Plasmoid    : $( [[ -f "$SYS_PLASMOID_DIR/contents/ui/Theme.qml" ]] && echo "MODERNIZED" || echo "Upstream / Stock" )"
    echo "System Backup      : $( [[ -d "$SYS_BACKUP_DIR" ]] && echo "Available ($SYS_BACKUP_DIR)" || echo "None" )"
    echo "User Plasmoid      : $( [[ -f "$USER_PLASMOID_DIR/contents/ui/Theme.qml" ]] && echo "Installed" || echo "Not Installed" )"
}

cmd_preview() {
    local t="${1:-$(get_active_theme)}"
    echo "== Theme Preview: $t =="
    case "$t" in
        midnight)
            echo "  Background: #0a0e17 (Obsidian Navy)"
            echo "  Surface   : rgba(22, 31, 48, 0.65) (Frosted Glass)"
            echo "  Accent    : #0ea5e9 / #38bdf8 (Sky Cyan Glow)"
            echo "  Text      : #f8fafc (Crisp Slate White)"
            ;;
        oled)
            echo "  Background: #000000 (Pure Black)"
            echo "  Surface   : rgba(18, 18, 18, 0.85) (Deep Smoke)"
            echo "  Accent    : #ffffff (Silver / Diamond Focus)"
            echo "  Text      : #ffffff (True White)"
            ;;
        cyberpunk)
            echo "  Background: #090514 (Deep Violet)"
            echo "  Surface   : rgba(28, 15, 48, 0.72) (Neon Glass)"
            echo "  Accent    : #f43f5e / #06b6d4 (Magenta / Cyan Glow)"
            echo "  Text      : #fdf4ff (Neon Lavender)"
            ;;
        sunset)
            echo "  Background: #140c0a (Dark Charcoal)"
            echo "  Surface   : rgba(38, 22, 18, 0.72) (Warm Amber Glass)"
            echo "  Accent    : #f59e0b / #f97316 (Golden Amber & Sunset Orange)"
            echo "  Text      : #fff7ed (Warm Ivory)"
            ;;
        emerald)
            echo "  Background: #06140f (Deep Forest)"
            echo "  Surface   : rgba(13, 38, 28, 0.72) (Emerald Frosted Glass)"
            echo "  Accent    : #10b981 / #34d399 (Vibrant Emerald & Mint)"
            echo "  Text      : #ecfdf5 (Cool Mint White)"
            ;;
        *)
            echo "Unknown theme '$t'"
            ;;
    esac
}

case "${1:-}" in
    list)
        cmd_list ;;
    set)
        shift; cmd_set "${1:-}" ;;
    install)
        cmd_install ;;
    revert)
        cmd_revert ;;
    status)
        cmd_status ;;
    preview)
        shift; cmd_preview "${1:-}" ;;
    --help|-h|"")
        sed -n '2,11p' "$0" | sed 's/^# \?//'
        ;;
    *)
        echo "Unknown option '$1' (try --help)" >&2
        exit 1
        ;;
esac
