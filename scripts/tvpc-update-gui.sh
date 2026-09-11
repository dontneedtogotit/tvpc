#!/usr/bin/env bash
# tvpc-update-gui — a couch-friendly GUI for applying tvpc updates.
#
# Checks the repository, apt, and Flatpak sources, asks for confirmation,
# applies updates in a safe order, and reboots only with explicit consent.
#
# Usage:
#   tvpc-update-gui           # interactive GUI
#   tvpc-update-gui --check   # report state, change nothing
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

require_gui() {
  if ! have kdialog; then
    printf 'tvpc-update-gui needs kdialog (the Plasma dialog tool).\n' >&2
    return 1
  fi
}

show_text() {
  local title="$1" text="$2" tmp rc
  tmp="$(mktemp)"
  printf '%s\n' "$text" >"$tmp"
  kdialog --textbox "$tmp" 900 700 --title "$title" 2>/dev/null
  rc=$?
  rm -f "$tmp"
  if [[ $rc -ne 0 ]]; then
    kdialog --msgbox "$text" --title "$title"
  fi
}

run_privileged() {
  if have pkexec; then
    pkexec "$@"
  elif have sudo; then
    sudo -- "$@"
  else
    kdialog --sorry "A privileged helper is required, but neither pkexec nor sudo is available." \
      --title "tvpc update"
    return 1
  fi
}

# Resolve an installed copy without trusting its /usr/local/bin parent. The
# installer records the source checkout in /etc/tvpc/repo.path; an explicit
# TVPC_REPO_ROOT is useful for tests and controlled deployments.
resolve_repo_root() {
  local candidate source_path marker

  REPO_ROOT=""
  REPO_STATE="unavailable"
  REPO_DETAIL="no tvpc repository was found"

  if [[ -n ${TVPC_REPO_ROOT:-} ]]; then
    candidate="$TVPC_REPO_ROOT"
  elif [[ -r /etc/tvpc/repo.path ]]; then
    IFS= read -r candidate < /etc/tvpc/repo.path
  else
    source_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    candidate="$(cd "$(dirname "$source_path")/../.." 2>/dev/null && pwd || true)"
  fi

  if [[ -n $candidate && -f "$candidate/install.sh" && -d "$candidate/scripts" ]]; then
    if git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      REPO_ROOT="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$candidate")"
      REPO_STATE="found"
      REPO_DETAIL="repository: $REPO_ROOT"
      return 0
    fi
    REPO_DETAIL="invalid repository: $candidate"
  elif [[ -n $candidate ]]; then
    REPO_DETAIL="invalid repository path: $candidate"
  fi
  return 1
}

git_plan() {
  local status branch upstream output
  GIT_STATE="unavailable"
  GIT_AHEAD=0
  GIT_BEHIND=0
  GIT_UPSTREAM=""
  GIT_DETAIL="repository checks are unavailable"

  if [[ $REPO_STATE != found ]]; then
    GIT_DETAIL="$REPO_DETAIL"
    return 0
  fi

  if ! status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all 2>&1)"; then
    GIT_STATE="error"
    GIT_DETAIL="could not read the git worktree"
    return 0
  fi
  if [[ -n $status ]]; then
    GIT_STATE="blocked-dirty"
    GIT_DETAIL="dirty worktree; save or revert local changes before updating"
    return 0
  fi

  branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -z $branch || $branch == HEAD ]]; then
    GIT_STATE="no-upstream"
    GIT_DETAIL="detached HEAD; no safe upstream branch is configured"
    return 0
  fi

  if ! upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
    GIT_STATE="no-upstream"
    GIT_DETAIL="branch '$branch' has no upstream"
    return 0
  fi
  GIT_UPSTREAM="$upstream"

  if ! output="$(git -C "$REPO_ROOT" fetch --quiet 2>&1)"; then
    GIT_STATE="error"
    GIT_DETAIL="git fetch failed${output:+: $output}"
    return 0
  fi

  if ! GIT_BEHIND="$(git -C "$REPO_ROOT" rev-list --count "HEAD..$upstream" 2>/dev/null)"; then
    GIT_STATE="error"
    GIT_DETAIL="could not compare with upstream $upstream"
    return 0
  fi
  if ! GIT_AHEAD="$(git -C "$REPO_ROOT" rev-list --count "$upstream..HEAD" 2>/dev/null)"; then
    GIT_STATE="error"
    GIT_DETAIL="could not compare with upstream $upstream"
    return 0
  fi

  if [[ $GIT_AHEAD -gt 0 && $GIT_BEHIND -gt 0 ]]; then
    GIT_STATE="diverged"
    GIT_DETAIL="$GIT_AHEAD local and $GIT_BEHIND remote commit(s)"
  elif [[ $GIT_AHEAD -gt 0 ]]; then
    GIT_STATE="local-ahead"
    GIT_DETAIL="$GIT_AHEAD local commit(s) are not on $upstream"
  elif [[ $GIT_BEHIND -gt 0 ]]; then
    GIT_STATE="behind"
    GIT_DETAIL="$GIT_BEHIND new commit(s) on $upstream"
  else
    GIT_STATE="up-to-date"
    GIT_DETAIL="repository is up to date"
  fi
}

check_apt() {
  local output line
  APT_COUNT=0
  APT_STATE="unavailable"
  APT_DETAIL="apt is not installed"

  if ! have apt; then
    return 0
  fi
  if ! output="$(apt list --upgradable 2>&1)"; then
    APT_STATE="error"
    APT_DETAIL="apt could not list upgrades: $output"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z $line || $line == "Listing..."* ]] && continue
    APT_COUNT=$((APT_COUNT + 1))
  done <<<"$output"
  APT_STATE="available"
  APT_DETAIL="$APT_COUNT package update(s) available"
}

flatpak_updates_for() {
  local installation="$1" output line count=0
  if ! output="$(flatpak remote-ls --updates --columns=application "--$installation" 2>&1)"; then
    if flatpak remotes "--$installation" 2>/dev/null | grep -q .; then
      return 2
    fi
    printf '0\n'
    return 0
  fi
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    count=$((count + 1))
  done <<<"$output"
  printf '%s\n' "$count"
}

check_flatpak() {
  local user_count system_count user_output system_output user_result system_result
  FLATPAK_USER_COUNT=0
  FLATPAK_SYSTEM_COUNT=0
  FLATPAK_COUNT=0
  FLATPAK_STATE="unavailable"
  FLATPAK_DETAIL="Flatpak is not installed"

  if ! have flatpak; then
    return 0
  fi

  if user_output="$(flatpak_updates_for user)"; then
    user_count="$user_output"
    user_result=0
  else
    user_result=$?
  fi
  if system_output="$(flatpak_updates_for system)"; then
    system_count="$system_output"
    system_result=0
  else
    system_result=$?
  fi

  if [[ $user_result -ne 0 || $system_result -ne 0 ]]; then
    FLATPAK_STATE="error"
    FLATPAK_DETAIL="Flatpak could not inspect one or more installations"
    return 0
  fi

  FLATPAK_USER_COUNT="${user_count:-0}"
  FLATPAK_SYSTEM_COUNT="${system_count:-0}"
  FLATPAK_COUNT=$((FLATPAK_USER_COUNT + FLATPAK_SYSTEM_COUNT))
  FLATPAK_STATE="available"
  FLATPAK_DETAIL="$FLATPAK_COUNT Flatpak update(s) available"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

acquire_lock() {
  local lock_file="${TVPC_UPDATE_LOCK_FILE:-/tmp/tvpc-update-gui.lock}"
  if ! have flock; then
    return 0
  fi
  exec 9>"$lock_file" || {
    kdialog --sorry "Could not open the updater lock file: $lock_file" --title "tvpc update"
    return 1
  }
  if ! flock -n 9; then
    kdialog --sorry "Another tvpc updater is already running." --title "tvpc update"
    return 1
  fi
}

apply_git() {
  git_plan
  if [[ $GIT_STATE != behind ]]; then
    kdialog --sorry "Repository preflight changed: $GIT_DETAIL." --title "tvpc update"
    return 1
  fi
  if ! git -C "$REPO_ROOT" pull --ff-only; then
    return 1
  fi
  if [[ ! -x "$REPO_ROOT/scripts/tvpc-update.sh" ]]; then
    kdialog --sorry "The updated repository has no executable scripts/tvpc-update.sh." --title "tvpc update"
    return 1
  fi
  run_privileged "$REPO_ROOT/scripts/tvpc-update.sh" --no-packages
}

apply_apt() {
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
}

apply_flatpak() {
  local failed=0
  if [[ $FLATPAK_USER_COUNT -gt 0 ]] && ! flatpak update --user --noninteractive --assumeyes; then
    failed=1
  fi
  if [[ $FLATPAK_SYSTEM_COUNT -gt 0 ]] && ! run_privileged flatpak update --system --noninteractive --assumeyes; then
    failed=1
  fi
  return "$failed"
}

reboot_required() {
  local marker running newest path
  local -a markers kernels sorted

  markers=("${TVPC_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}" /run/reboot-required /var/run/reboot-required.pkgs)
  for marker in "${markers[@]}"; do
    [[ -e $marker ]] && return 0
  done

  running="$(uname -r 2>/dev/null || true)"
  shopt -s nullglob
  kernels=("${TVPC_BOOT_DIR:-/boot}"/vmlinuz-*)
  shopt -u nullglob
  if [[ ${#kernels[@]} -eq 0 || -z $running ]]; then
    return 1
  fi
  mapfile -t sorted < <(printf '%s\n' "${kernels[@]}" | sort -V)
  newest="${sorted[${#sorted[@]} - 1]##*/vmlinuz-}"
  [[ -n $newest && $newest != "$running" ]]
}

request_reboot() {
  if run_privileged systemctl reboot; then
    return 0
  fi
  kdialog --sorry "The reboot command was denied or failed." --title "tvpc update"
  return 1
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

plan_text() {
  local repo_state="${1:-}" apt_state="${2:-}" flatpak_state="${3:-}"
  printf 'Repository: %s (%s)\n' "$repo_state" "$GIT_DETAIL"
  printf 'Packages: %s (%s)\n' "$apt_state" "$APT_DETAIL"
  printf 'Flatpaks: %s (%s)\n' "$flatpak_state" "$FLATPAK_DETAIL"
}

gui_report() {
  local repo_state
  resolve_repo_root || true
  git_plan
  check_apt
  check_flatpak

  case "$GIT_STATE" in
    behind) repo_state="update available" ;;
    up-to-date) repo_state="up to date" ;;
    blocked-dirty|local-ahead|diverged|no-upstream|error) repo_state="blocked" ;;
    *) repo_state="unavailable" ;;
  esac
  show_text "tvpc update check" "$(plan_text "$repo_state" "$APT_STATE" "$FLATPAK_STATE")"
}

gui_apply() {
  local repo_state apt_state flatpak_state msg btn before_reboot after_reboot reboot_answer
  local blocked=0

  resolve_repo_root || true
  git_plan
  check_apt
  check_flatpak

  case "$GIT_STATE" in
    blocked-dirty|local-ahead|diverged|no-upstream|error) blocked=1 ;;
  esac
  [[ $APT_STATE == error || $FLATPAK_STATE == error ]] && blocked=1

  if [[ $blocked -eq 1 ]]; then
    show_text "tvpc update blocked" "$(plan_text "blocked" "$APT_STATE" "$FLATPAK_STATE")"
    return 1
  fi

  if [[ $GIT_STATE == up-to-date && $APT_COUNT -eq 0 && $FLATPAK_COUNT -eq 0 ]]; then
    if [[ $REPO_STATE == found ]]; then
      kdialog --msgbox "Everything is up to date." --title "tvpc update"
    else
      show_text "tvpc update" "No package updates are available. The tvpc repository is unavailable."
    fi
    return 0
  fi

  case "$GIT_STATE" in
    behind) repo_state="$GIT_DETAIL" ;;
    *) repo_state="no repository update" ;;
  esac
  apt_state="$APT_DETAIL"
  flatpak_state="$FLATPAK_DETAIL"
  msg="Updates are available:

$repo_state
$apt_state
$flatpak_state

Apply them now?"
  btn="$(kdialog --warningcontinuecancel "$msg" --title "tvpc update" 2>/dev/null)" || return 0
  [[ $btn == "continue" ]] || return 0

  acquire_lock || return 1
  before_reboot=0
  reboot_required && before_reboot=1

  if [[ $GIT_STATE == behind ]] && ! apply_git; then
    kdialog --sorry "Repository update failed; package updates were not started." --title "tvpc update"
    return 1
  fi
  if [[ $APT_COUNT -gt 0 ]] && ! apply_apt; then
    kdialog --sorry "Package update failed; Flatpak updates were not started." --title "tvpc update"
    return 1
  fi
  if [[ $FLATPAK_COUNT -gt 0 ]] && ! apply_flatpak; then
    kdialog --sorry "Flatpak update failed." --title "tvpc update"
    return 1
  fi

  after_reboot=0
  reboot_required && after_reboot=1
  if [[ $after_reboot -eq 0 ]]; then
    kdialog --msgbox "Updates applied. No reboot is needed." --title "tvpc update"
    return 0
  fi

  if [[ $before_reboot -eq 1 ]]; then
    msg="Updates applied. A reboot was already required before this run."
  else
    msg="Updates applied. A reboot is now required for them to take effect."
  fi
  reboot_answer="$(kdialog --warningyesno "$msg

Reboot now?" --title "tvpc update" 2>/dev/null)" || return 0
  [[ $reboot_answer == "yes" ]] && request_reboot || true
}

# ---------------------------------------------------------------------------
require_gui || exit 1
case "${1:-gui}" in
  --check|check) gui_report ;;
  gui|"")        gui_apply ;;
  *)
    kdialog --sorry "Unknown argument: $1" --title "tvpc update"
    exit 1
    ;;
esac
