#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ $haystack == *"$needle"* ]] || fail "expected output to contain: $needle" 
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ $haystack != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

# 1. Check overlay files exist
OVERLAY="$ROOT/overlays/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"
[[ -f "$OVERLAY/metadata.desktop" ]] || fail "Missing metadata.desktop in overlay"
[[ -f "$OVERLAY/contents/ui/main.qml" ]] || fail "Missing main.qml in overlay"
[[ -f "$OVERLAY/contents/ui/Theme.qml" ]] || fail "Missing Theme.qml in overlay"
[[ -f "$OVERLAY/contents/ui/launcher/LauncherHome.qml" ]] || fail "Missing LauncherHome.qml in overlay"
[[ -f "$OVERLAY/contents/ui/launcher/LauncherMenu.qml" ]] || fail "Missing LauncherMenu.qml in overlay"
[[ -f "$OVERLAY/contents/ui/launcher/delegates/ModernCardDelegate.qml" ]] || fail "Missing ModernCardDelegate.qml in overlay"
[[ -f "$OVERLAY/contents/ui/launcher/delegates/AppDelegate.qml" ]] || fail "Missing AppDelegate.qml in overlay"
[[ -f "$OVERLAY/contents/ui/launcher/delegates/SettingDelegate.qml" ]] || fail "Missing SettingDelegate.qml in overlay"

# 2. Test list command
list_out="$(HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" list)"
assert_contains "$list_out" "midnight"
assert_contains "$list_out" "oled"
assert_contains "$list_out" "cyberpunk"
assert_contains "$list_out" "sunset"
assert_contains "$list_out" "emerald"
assert_contains "$list_out" "[ACTIVE]"

# 3. Test set command
HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" set cyberpunk
user_conf="$TMP/.config/tvpc/bigscreen-theme.json"
[[ -f "$user_conf" ]] || fail "User config not created at $user_conf"
assert_contains "$(cat "$user_conf")" '"theme": "cyberpunk"'

# Status should reflect cyberpunk
status_out="$(HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" status)"
assert_contains "$status_out" "Active Theme       : cyberpunk"

# Switch to sunset
HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" set sunset
assert_contains "$(cat "$user_conf")" '"theme": "sunset"'

# Invalid theme should fail
if HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" set nonexistent 2>/dev/null; then
  fail "Expected setting nonexistent theme to fail"
fi

# 4. Preview command
prev_out="$("$ROOT/scripts/tvpc-bigscreen-theme.sh" preview oled)"
assert_contains "$prev_out" "Theme Preview: oled"
assert_contains "$prev_out" "#000000"

# 5. Test install and revert in a simulated user directory
HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" install
installed_theme="$TMP/.local/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen/contents/ui/Theme.qml"
[[ -f "$installed_theme" ]] || fail "User override not installed"

# Verify kwinrc and kglobalshortcutsrc were deployed
user_kwinrc="$TMP/.config/kwinrc"
[[ -f "$user_kwinrc" ]] || fail "kwinrc not created"
assert_contains "$(cat "$user_kwinrc")" "BorderlessMaximizedWindows=false"
assert_contains "$(cat "$user_kwinrc")" "ButtonsOnRight=X"
assert_contains "$(cat "$user_kwinrc")" "LayoutName=thumbnail_grid"

user_shortcuts="$TMP/.config/kglobalshortcutsrc"
[[ -f "$user_shortcuts" ]] || fail "kglobalshortcutsrc not created"
assert_contains "$(cat "$user_shortcuts")" "Walk Through Windows=Alt+Tab"
assert_contains "$(cat "$user_shortcuts")" "Window Close=Alt+F4"

# Verify main.qml contains Alt+Tab and Close controls
main_qml="$OVERLAY/contents/ui/main.qml"
assert_contains "$(cat "$main_qml")" "triggerAltTab"
assert_contains "$(cat "$main_qml")" "triggerCloseApp"
assert_contains "$(cat "$main_qml")" "Switch (Alt+Tab)"
assert_contains "$(cat "$main_qml")" "Close (✕)"

HOME="$TMP" "$ROOT/scripts/tvpc-bigscreen-theme.sh" revert
[[ ! -d "$TMP/.local/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen" ]] || fail "User override not cleaned up on revert"

# 6. Test tvpc-tweaks theme integration
HOME="$TMP" "$ROOT/scripts/tvpc-tweaks.sh" theme emerald
assert_contains "$(cat "$user_conf")" '"theme": "emerald"'

echo "tvpc-bigscreen-theme tests passed."
