#!/usr/bin/env bash
# tests/test-tvpc.sh — Unified integration test suite for tvpc
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home" "$TMP/repo/.git" "$TMP/repo/scripts" "$TMP/repo/overlays"
: >"$TMP/repo/install.sh"

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

make_stub() {
  local name="$1" body="$2"
  printf '%s\n' '#!/usr/bin/env bash' "$body" >"$BIN/$name"
  chmod +x "$BIN/$name"
}

echo "== 1. Syntax Check =="
bash -n "$ROOT/install.sh" "$ROOT/scripts/tvpc.sh" "$0"
echo "Bash syntax OK"

echo "== 2. GUI & Tweaks Contract Tests =="
make_stub kdialog '
: "${KIALOG_LOG:?}"
printf "%q " "$@" >>"$KIALOG_LOG"
printf "\\n" >>"$KIALOG_LOG"
if [[ " $* " == *" --textbox "* ]]; then
  previous=""
  for arg in "$@"; do
    if [[ $previous == --textbox && -f $arg ]]; then
      cp "$arg" "$DIALOG_FILE"
      break
    fi
    previous="$arg"
  done
fi
case " $* " in
  *" --warningcontinuecancel "*) printf "continue\\n" ;;
  *" --warningyesno "*) printf "yes\\n" ;;
esac
exit 0
'

make_stub pkexec '
printf "pkexec" >>"${PRIV_LOG:-$TMP/priv.log}"
printf " %q" "$@" >>"${PRIV_LOG:-$TMP/priv.log}"
printf "\\n" >>"${PRIV_LOG:-$TMP/priv.log}"
exec "$@"
'

make_stub tvpc-controller 'printf "input status ok\\n"'
make_stub tvpc-cec-setup 'printf "cec check ok\\n"'
make_stub tvpc-tweaks 'printf "tweaks ok\\n"'

# Setup GUI check
: >"$TMP/setup-dialog"
: >"$TMP/setup-priv.log"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" TMPDIR="$TMP" \
  KIALOG_LOG="$TMP/kdialog.log" DIALOG_FILE="$TMP/setup-dialog" \
  PRIV_LOG="$TMP/setup-priv.log" \
  bash "$ROOT/scripts/tvpc.sh" gui setup --check

assert_contains "$(cat "$TMP/setup-dialog")" "Input devices"
assert_contains "$(cat "$TMP/setup-dialog")" "HDMI-CEC"
assert_contains "$(cat "$TMP/setup-priv.log")" "tvpc-controller status"
assert_contains "$(cat "$TMP/setup-priv.log")" "tvpc-cec-setup --check"

# CEC map tweaks contract
printf '%s\n' '01 key:103' '41 pactl:+2%' >"$TMP/cec-map"
cec_output="$(env -i PATH="$BIN:/usr/bin:/bin" TVPC_CEC_MAP="$TMP/cec-map" \
  bash "$ROOT/scripts/tvpc.sh" tweaks cec-list)"
assert_contains "$cec_output" $'01\tUp\tkey:103'
assert_contains "$cec_output" $'41\tVol+\tpactl:+2%'
assert_contains "$(env -i PATH="$BIN:/usr/bin:/bin" TVPC_CEC_MAP="$TMP/cec-map" \
  bash "$ROOT/scripts/tvpc.sh" tweaks cec-get 41)" "pactl:+2%"

# Update GUI dirty check
make_stub git '
printf "git" >>"${GIT_LOG:-$TMP/git.log}"
printf " %q" "$@" >>"${GIT_LOG:-$TMP/git.log}"
printf "\\n" >>"${GIT_LOG:-$TMP/git.log}"
case " $* " in
  *" rev-parse --is-inside-work-tree"*) printf "true\\n" ;;
  *" rev-parse --show-toplevel"*) printf "%s\\n" "$TVPC_REPO_ROOT" ;;
  *" status --porcelain --untracked-files=all"*) printf " M local-file\\n" ;;
  *" symbolic-ref --quiet --short HEAD"*) printf "main\\n" ;;
  *" rev-parse --abbrev-ref @{u}"*) printf "origin/main\\n" ;;
  *" rev-list --count HEAD..origin/main"*) printf "0\\n" ;;
  *" rev-list --count origin/main..HEAD"*) printf "0\\n" ;;
esac
exit 0
'
make_stub apt 'printf "Listing...\\nlinux-image 1 amd64 [upgradable from: 0]\\n"'
make_stub flatpak 'printf "org.example.App\\n"'
: >"$TMP/update-dialog"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" TMPDIR="$TMP" \
  TVPC_REPO_ROOT="$TMP/repo" KIALOG_LOG="$TMP/update-kdialog.log" \
  DIALOG_FILE="$TMP/update-dialog" GIT_LOG="$TMP/git.log" \
  bash "$ROOT/scripts/tvpc.sh" gui update --check
assert_contains "$(cat "$TMP/update-dialog")" "dirty"
assert_not_contains "$(cat "$TMP/update-dialog")" "Everything is up to date"

# Update GUI clean check + apply
: >"$TMP/git.log"
make_stub git '
printf "git" >>"${GIT_LOG:-$TMP/git.log}"
printf " %q" "$@" >>"${GIT_LOG:-$TMP/git.log}"
printf "\\n" >>"${GIT_LOG:-$TMP/git.log}"
case " $* " in
  *" rev-parse --is-inside-work-tree"*) printf "true\\n" ;;
  *" rev-parse --show-toplevel"*) printf "%s\\n" "$TVPC_REPO_ROOT" ;;
  *" status --porcelain --untracked-files=all"*) exit 0 ;;
  *" symbolic-ref --quiet --short HEAD"*) printf "main\\n" ;;
  *" rev-parse --abbrev-ref @{u}"*) printf "origin/main\\n" ;;
  *" rev-list --count HEAD..origin/main"*) printf "1\\n" ;;
  *" rev-list --count origin/main..HEAD"*) printf "0\\n" ;;
esac
exit 0
'
make_stub apt-get 'printf "apt-get" >>"${APT_LOG:-$TMP/apt.log}"; printf " %q" "$@" >>"${APT_LOG:-$TMP/apt.log}"; printf "\\n" >>"${APT_LOG:-$TMP/apt.log}"; exit 0'
make_stub flatpak 'printf "flatpak" >>"${FLATPAK_LOG:-$TMP/flatpak.log}"; printf " %q" "$@" >>"${FLATPAK_LOG:-$TMP/flatpak.log}"; printf "\\n" >>"${FLATPAK_LOG:-$TMP/flatpak.log}"; case " $* " in *" remote-ls "*) printf "org.example.App\\n" ;; esac; exit 0'
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "converge"' >"$TMP/repo/install.sh"
chmod +x "$TMP/repo/install.sh"
: >"$TMP/update-dialog"
: >"$TMP/priv.log"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" TMPDIR="$TMP" \
  TVPC_REPO_ROOT="$TMP/repo" KIALOG_LOG="$TMP/update-kdialog.log" \
  DIALOG_FILE="$TMP/update-dialog" PRIV_LOG="$TMP/priv.log" GIT_LOG="$TMP/git.log" \
  APT_LOG="$TMP/apt.log" FLATPAK_LOG="$TMP/flatpak.log" \
  TVPC_UPDATE_LOCK_FILE="$TMP/updater.lock" \
  bash "$ROOT/scripts/tvpc.sh" gui update
assert_contains "$(cat "$TMP/update-kdialog.log")" "1 new commit"
assert_contains "$(cat "$TMP/apt.log")" "apt-get update"
assert_contains "$(cat "$TMP/apt.log")" "apt-get upgrade"
assert_contains "$(cat "$TMP/flatpak.log")" "flatpak update"
assert_contains "$(cat "$TMP/priv.log")" "install.sh --no-packages"
echo "GUI contract tests passed."

echo "== 3. Bigscreen Theme Tests =="
OVERLAY="$ROOT/overlays/usr/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"
[[ -f "$OVERLAY/metadata.desktop" ]] || fail "Missing metadata.desktop in overlay"
[[ -f "$OVERLAY/contents/ui/main.qml" ]] || fail "Missing main.qml in overlay"
[[ -f "$OVERLAY/contents/ui/Theme.qml" ]] || fail "Missing Theme.qml in overlay"
[[ -f "$OVERLAY/contents/ui/launcher/LauncherHome.qml" ]] || fail "Missing LauncherHome.qml in overlay"

list_out="$(HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme list)"
assert_contains "$list_out" "midnight"
assert_contains "$list_out" "oled"
assert_contains "$list_out" "cyberpunk"
assert_contains "$list_out" "sunset"
assert_contains "$list_out" "emerald"
assert_contains "$list_out" "[ACTIVE]"

HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme set cyberpunk
user_conf="$TMP/.config/tvpc/bigscreen-theme.json"
[[ -f "$user_conf" ]] || fail "User config not created at $user_conf"
assert_contains "$(cat "$user_conf")" '"theme": "cyberpunk"'

status_out="$(HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme status)"
assert_contains "$status_out" "Active Theme       : cyberpunk"

HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme set sunset
assert_contains "$(cat "$user_conf")" '"theme": "sunset"'

if HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme set nonexistent 2>/dev/null; then
  fail "Expected setting nonexistent theme to fail"
fi

prev_out="$("$ROOT/scripts/tvpc.sh" theme preview oled)"
assert_contains "$prev_out" "Theme Preview: oled"

HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme install
user_dir="$TMP/.local/share/plasma/plasmoids/org.kde.mycroft.bigscreen.homescreen"
[[ -d "$user_dir" ]] || fail "User override directory not created at $user_dir"
[[ -f "$user_dir/contents/ui/Theme.qml" ]] || fail "Theme.qml not copied to user override"

HOME="$TMP" "$ROOT/scripts/tvpc.sh" theme revert
[[ ! -d "$user_dir" ]] || fail "User override directory still exists after revert"

HOME="$TMP" "$ROOT/scripts/tvpc.sh" tweaks theme emerald
assert_contains "$(cat "$user_conf")" '"theme": "emerald"'
echo "Theme tests passed."

echo "== 4. Layout, Dock, and Add Apps Tests =="
grep -q "singleRowContainer" "$OVERLAY/contents/ui/launcher/LauncherHome.qml" || fail "LauncherHome.qml missing singleRowContainer"
grep -q "topBarHeight" "$OVERLAY/contents/ui/main.qml" || fail "main.qml missing topBarHeight"
grep -q "tvpc-addapps" "$ROOT/scripts/tvpc.sh" || fail "tvpc.sh missing tvpc-addapps"
grep -q "tvpc-addapps.desktop" "$ROOT/install.sh" || fail "install.sh missing tvpc-addapps.desktop"
grep -q "noborder=true" "$ROOT/install.sh" || fail "install.sh missing noborder=true for vacuumtube"
echo "Layout and dock tests passed."

echo "== 5. Hyprland Config Validation =="
CONFIG="$ROOT/config/hypr/hyprland.lua"
if [[ -f $CONFIG ]]; then
  LUA=""
  for cand in lua lua5.4 lua5.3 luajit; do
    command -v "$cand" >/dev/null 2>&1 && { LUA="$cand"; break; }
  done
  if [[ -n $LUA ]]; then
    if command -v luac >/dev/null 2>&1; then
      luac -p "$CONFIG" || exit 1
    fi
    echo "Hyprland Lua config valid."
  fi
fi

echo "All tvpc tests passed!"
