#!/usr/bin/env bash
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

run_setup_check() {
  : >"$TMP/setup-dialog"
  : >"$TMP/setup-priv.log"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" TMPDIR="$TMP" \
    KIALOG_LOG="$TMP/kdialog.log" DIALOG_FILE="$TMP/setup-dialog" \
    PRIV_LOG="$TMP/setup-priv.log" \
    bash "$ROOT/scripts/tvpc-setup-gui.sh" --check
}

run_setup_check
assert_contains "$(cat "$TMP/setup-dialog")" "Input devices"
assert_contains "$(cat "$TMP/setup-dialog")" "HDMI-CEC"
assert_contains "$(cat "$TMP/setup-priv.log")" "tvpc-controller status"
assert_contains "$(cat "$TMP/setup-priv.log")" "tvpc-cec-setup --check"

# The CEC map commands are stable contracts used by the GUI.
printf '%s\n' '01 key:103' '41 pactl:+2%' >"$TMP/cec-map"
cec_output="$(env -i PATH="$BIN:/usr/bin:/bin" TVPC_CEC_MAP="$TMP/cec-map" \
  bash "$ROOT/scripts/tvpc-tweaks.sh" cec-list)"
assert_contains "$cec_output" $'01\tUp\tkey:103'
assert_contains "$cec_output" $'41\tVol+\tpactl:+2%'
assert_contains "$(env -i PATH="$BIN:/usr/bin:/bin" TVPC_CEC_MAP="$TMP/cec-map" \
  bash "$ROOT/scripts/tvpc-tweaks.sh" cec-get 41)" "pactl:+2%"

# A dirty worktree is a hard preflight failure, not an "up to date" result.
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
  bash "$ROOT/scripts/tvpc-update-gui.sh" --check
assert_contains "$(cat "$TMP/update-dialog")" "dirty"
assert_not_contains "$(cat "$TMP/update-dialog")" "Everything is up to date"

# A clean behind branch plans repo, apt, and Flatpak updates and applies them
# only after the user confirms.
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
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "converge"' >"$TMP/repo/scripts/tvpc-update.sh"
chmod +x "$TMP/repo/scripts/tvpc-update.sh"
: >"$TMP/update-dialog"
: >"$TMP/priv.log"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" TMPDIR="$TMP" \
  TVPC_REPO_ROOT="$TMP/repo" KIALOG_LOG="$TMP/update-kdialog.log" \
  DIALOG_FILE="$TMP/update-dialog" PRIV_LOG="$TMP/priv.log" GIT_LOG="$TMP/git.log" \
  APT_LOG="$TMP/apt.log" FLATPAK_LOG="$TMP/flatpak.log" \
  TVPC_UPDATE_LOCK_FILE="$TMP/updater.lock" \
  bash "$ROOT/scripts/tvpc-update-gui.sh"
assert_contains "$(cat "$TMP/update-kdialog.log")" "1 new commit"
assert_contains "$(cat "$TMP/apt.log")" "apt-get update"
assert_contains "$(cat "$TMP/apt.log")" "apt-get upgrade"
assert_contains "$(cat "$TMP/flatpak.log")" "flatpak update"
assert_contains "$(cat "$TMP/priv.log")" "tvpc-update.sh --no-packages"

printf '%s\n' 'GUI contract tests passed.'
