#!/usr/bin/env bash
# tvpc-vacuumtube-scroll — "scroll horizontally when hovering over videos"
# for the VacuumTube flatpak.
#
# VacuumTube is an Electron app wrapping YouTube Leanback. Electron main
# windows cannot have a preload injected from flags.txt (the --preload
# Chromium flag only applies to <webview> tags), so this patcher edits the
# app's main file directly:
#
#   * If VacuumTube already declares a preload AND the file is writable,
#     this appends the wheel hook to the END of that preload. No change to
#     index.js, nothing to re-do beyond `flatpak update` re-apply.
#   * Otherwise, it writes a standalone preload into the app's per-user
#     config dir (writable, inside the sandbox) and patches index.js to
#     point webPreferences.preload at it.
#
# Breaks on `flatpak update` (the app files are replaced). After an update,
# just re-run this script.
#
# Usage:
#   ./scripts/tvpc-vacuumtube-scroll.sh         apply
#   ./scripts/tvpc-vacuumtube-scroll.sh status
#   ./scripts/tvpc-vacuumtube-scroll.sh revert
set -euo pipefail

APP_ID=rocks.shy.VacuumTube
PRELOAD_DIR_REL=".var/app/${APP_ID}/config/${APP_ID}"
HOOK_NAME="tvpc-hover-scroll.js"
MARKER_START="/* >>> tvpc hover-horizontal-scroll >>> */"
MARKER_END="/* <<< tvpc hover-horizontal-scroll <<< */"

HOOK_JS='/* tvpc hover-horizontal-scroll for VacuumTube.
 * Run from the Electron preload context. Vertical wheel over a
 * horizontally-scrollable element becomes horizontal scroll. */
(function () {
    var SKIP = { INPUT: 1, TEXTAREA: 1, SELECT: 1 };
    function scrollerOf(el) {
        var n = el;
        while (n && n !== document && n !== document.documentElement) {
            if (n.scrollWidth > n.clientWidth + 4) return n;
            n = n.parentNode;
        }
        return null;
    }
    function onWheel(e) {
        if (e.ctrlKey) return; // pinch-zoom
        var t = e.target;
        if (t && t.nodeName && SKIP[t.nodeName]) return;
        if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
        var sc = scrollerOf(t);
        if (!sc || sc.scrollWidth <= sc.clientWidth + 1) return;
        sc.scrollLeft += e.deltaY;
        e.preventDefault();
        e.stopPropagation();
    }
    window.addEventListener("wheel", onWheel, { passive: false, capture: true });
})();'

resolve_user_home() {
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then echo "/home/$SUDO_USER"
    elif [[ $EUID -eq 0 && -n ${HOME:-} ]]; then echo "$HOME"
    else echo "$HOME"; fi
}

detect_app_dir() {
    local uh; uh="$(resolve_user_home)"
    for prefix in "$uh/.local/share/flatpak/app" "/var/lib/flatpak/app"; do
        local d="$prefix/$APP_ID/x86_64/stable/active"
        [[ -d $d/files ]] && { echo "$d"; return 0; }
    done
    return 1
}

get_main_file() {
    local files="$1" pkg
    pkg="$files/package.json"
    [[ -f $pkg ]] || { echo "index.js"; return; }
    grep -m1 '"main"' "$pkg" | sed -E 's/.*"main"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | tr -d '[:space:]' | grep -v '^$' || echo "index.js"
}

# Resolve a preload value from a `preload: <expr>` line in the main file.
# Handles `path.join(__dirname, 'x.js')`, `'x.js'`, `"x.js"`, and bare tokens.
resolve_existing_preload() {
    local main="$1" main_dir
    local line; line=$(grep -m1 -E '^[[:space:]]*preload[[:space:]]*:' "$main" || true)
    [[ -z $line ]] && return 1
    local expr=${line#*preload:}
    expr="${expr%,}"   # drop trailing comma
    expr="$(echo "$expr" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    main_dir="$(dirname "$main")"
    case "$expr" in
        path.join*)
            local args=${expr#path.join(}; args=${args%)};
            local tail; tail=$(echo "$args" | tr ',' '\n' | tail -1 | sed -E "s/^[[:space:]]*['\"]//; s/['\"][[:space:]]*$//")
            [[ "$tail" = /* ]] && echo "$tail" || echo "$main_dir/$tail"
            ;;
        \'*\'|\"*\")
            local s=${expr#\'}; s=${s%\'}; s=${s#\"}; s=${s%\"}
            [[ "$s" = /* ]] && echo "$s" || echo "$main_dir/$s"
            ;;
        *)
            [[ "$expr" = /* ]] && echo "$expr" || echo "$main_dir/$expr"
            ;;
    esac
}

write_file() { # write_file <path> <owner> <mode> [sudo]
    local p="$1" owner="$2" mode="$3" use_sudo="${4:-}"
    if [[ -n $use_sudo ]]; then
        echo "$HOOK_JS" | sudo tee "$p" >/dev/null
        sudo chown "$owner" "$p"
        sudo chmod "$mode" "$p"
    else
        printf '%s\n' "$HOOK_JS" >"$p"
        chown "$owner" "$p" 2>/dev/null || true
        chmod "$mode" "$p"
    fi
}

# ----- subcommands -----
do_status() {
    local app_dir; app_dir="$(detect_app_dir)" || { echo "VacuumTube flatpak not installed."; return 1; }
    local files="$app_dir/files"
    local main; main="$(get_main_file "$files")"
    local main_path="$files/$main"
    echo "Flatpak active dir: $app_dir"
    echo "Main file:          $main_path"
    local existing; existing="$(resolve_existing_preload "$main_path" 2>/dev/null || true)"
    if [[ -n $existing ]]; then
        echo "Existing preload:   $existing"
        if [[ -f $existing ]] && grep -qF "$MARKER_START" "$existing"; then
            echo "tvpc hook:          APPLIED in $existing"
        else
            echo "tvpc hook:          not applied (preload has no tvpc block)"
        fi
    else
        echo "Existing preload:   (none declared in $main)"
        local uh; uh="$(resolve_user_home)"
        local our="$uh/$PRELOAD_DIR_REL/$HOOK_NAME"
        if [[ -f $our ]]; then
            echo "Standalone preload: $our (present)"
            if grep -qF "preload" "$main_path" 2>/dev/null; then
                echo "tvpc hook:          standalone preload in place"
            else
                echo "tvpc hook:          preload file present but index.js not patched?"
            fi
        else
            echo "tvpc hook:          not applied"
        fi
    fi
}

do_apply() {
    local app_dir; app_dir="$(detect_app_dir)" || { echo "VacuumTube flatpak not found." >&2; exit 1; }
    local files="$app_dir/files"
    local main; main="$(get_main_file "$files")"
    local main_path="$files/$main"
    [[ -f $main_path ]] || { echo "Main file not found: $main_path" >&2; exit 1; }

    local uh; uh="$(resolve_user_home)"
    local user="tv"
    [[ -n ${SUDO_USER:-} ]] && user="$SUDO_USER"
    [[ $EUID -ne 0 && -n ${USER:-} ]] && user="$USER"

    # Backup the main file
    local bak="${main_path}.tvpc-bak"
    [[ -f $bak ]] || { cp -a "$main_path" "$bak"; echo "Backup -> $bak"; }

    local existing; existing="$(resolve_existing_preload "$main_path" 2>/dev/null || true)"

    if [[ -n $existing && -f $existing ]]; then
        # ----- Path A: append to the existing preload -----
        if grep -qF "$MARKER_START" "$existing"; then
            echo "Hook already present in $existing"
            return 0
        fi
        if [[ -w $existing ]]; then
            {
                printf '\n%s\n' "$MARKER_START"
                printf '%s\n' "$HOOK_JS"
                printf '%s\n' "$MARKER_END"
            } >>"$existing"
            echo "Appended hook -> $existing (no index.js change)"
        else
            # Try via sudo (system flatpak): chmod, append, leave writable for future updates
            {
                printf '\n%s\n' "$MARKER_START"
                printf '%s\n' "$HOOK_JS"
                printf '%s\n' "$MARKER_END"
            } | sudo tee -a "$existing" >/dev/null
            echo "Appended hook -> $existing (via sudo)"
        fi
    else
        # ----- Path B: standalone preload in user config + patch index.js -----
        local dest="$uh/$PRELOAD_DIR_REL/$HOOK_NAME"
        mkdir -p "$(dirname "$dest")"
        if [[ -w $(dirname "$dest") ]]; then
            printf '%s\n' "$HOOK_JS" >"$dest"
            chown "$user" "$dest" 2>/dev/null || true
            chmod 0644 "$dest"
        else
            sudo mkdir -p "$(dirname "$dest")"
            sudo chown "$user" "$(dirname "$dest")" 2>/dev/null || true
            printf '%s\n' "$HOOK_JS" | sudo tee "$dest" >/dev/null
            sudo chown "$user" "$dest"
            sudo chmod 0644 "$dest"
        fi
        echo "Wrote standalone preload -> $dest"

        # Patch main_path: set webPreferences.preload to dest
        local esc; esc=$(printf '%s' "$dest" | sed "s/'/'\\\\''/g")
        if grep -qE '^[[:space:]]*preload[[:space:]]*:' "$main_path"; then
            # Replace existing preload value
            if [[ -w $main_path ]]; then
                sed -i -E "s|^[[:space:]]*preload[[:space:]]*:[[:space:]]*.*$|    preload: '${esc}',|" "$main_path"
            else
                sudo sed -i -E "s|^[[:space:]]*preload[[:space:]]*:[[:space:]]*.*$|    preload: '${esc}',|" "$main_path"
            fi
            echo "Replaced existing preload value in $main"
        elif grep -qE '^[[:space:]]*webPreferences[[:space:]]*:' "$main_path"; then
            # Inject preload: after webPreferences: {
            if [[ -w $main_path ]]; then
                sed -i -E "/^[[:space:]]*webPreferences[[:space:]]*:[[:space:]]*\{/a\\    preload: '${esc}'," "$main_path"
            else
                sudo sed -i -E "/^[[:space:]]*webPreferences[[:space:]]*:[[:space:]]*\{/a\\    preload: '${esc}'," "$main_path"
            fi
            echo "Injected preload into webPreferences in $main"
        else
            # No webPreferences at all — add one after `new BrowserWindow({`
            if [[ -w $main_path ]]; then
                sed -i -E "/new[[:space:]]+BrowserWindow[[:space:]]*\([[:space:]]*\{/a\\    webPreferences: { preload: '${esc}' }," "$main_path"
            else
                sudo sed -i -E "/new[[:space:]]+BrowserWindow[[:space:]]*\([[:space:]]*\{/a\\    webPreferences: { preload: '${esc}' }," "$main_path"
            fi
            echo "Added webPreferences with preload in $main"
        fi
    fi

    echo
    echo "Done. Restart VacuumTube (close + reopen) to load the preload."
    echo "Re-run this script after 'flatpak update' to re-apply."
}

do_revert() {
    local app_dir; app_dir="$(detect_app_dir 2>/dev/null || true)"
    if [[ -z $app_dir ]]; then echo "VacuumTube flatpak not found."; return 0; fi
    local files="$app_dir/files"
    local main; main="$(get_main_file "$files")"
    local main_path="$files/$main"
    local bak="${main_path}.tvpc-bak"

    # Always try to remove the hook block from the existing preload
    local existing; existing="$(resolve_existing_preload "$main_path" 2>/dev/null || true)"
    if [[ -n $existing && -f $existing && -r $existing ]]; then
        if grep -qF "$MARKER_START" "$existing"; then
            local tmp; tmp="$(mktemp)"
            awk -v start="$MARKER_START" -v end="$MARKER_END" '
                $0==start {skip=1; next}
                $0==end   {skip=0; next}
                !skip     {print}
            ' "$existing" >"$tmp"
            if [[ -w $existing ]]; then
                cp "$tmp" "$existing"
            else
                sudo cp "$tmp" "$existing"
            fi
            rm -f "$tmp"
            echo "Removed hook block from $existing"
        fi
    fi

    # Restore index.js backup if it exists
    if [[ -f $bak ]]; then
        if [[ -w $main_path ]] || $EUID -eq 0; then
            cp -a "$bak" "$main_path"
            echo "Restored $main from backup"
        else
            sudo cp -a "$bak" "$main_path"
            echo "Restored $main from backup (via sudo)"
        fi
        rm -f "$bak"
    fi

    # Remove standalone preload if present
    local uh; uh="$(resolve_user_home)"
    local dest="$uh/$PRELOAD_DIR_REL/$HOOK_NAME"
    if [[ -f $dest ]]; then
        rm -f "$dest"
        echo "Removed standalone preload $dest"
    fi

    echo "Reverted."
}

case "${1:-apply}" in
    apply)   do_apply ;;
    status)  do_status ;;
    revert)  do_revert ;;
    *)       echo "Usage: $0 {apply|status|revert}"; exit 1 ;;
esac
