#!/usr/bin/env bash
# tvpc-update.sh — wrapper for unified install.sh --update
#
#   sudo ./scripts/tvpc-update.sh --check        report only, change nothing
#   sudo ./scripts/tvpc-update.sh                converge, then update packages
#   sudo ./scripts/tvpc-update.sh --no-packages  converge only, no apt/flatpak
#   ./scripts/tvpc-update.sh --list              list the state items and exit
set -uo pipefail

resolve_repo_root() {
  local candidate source_path
  if [[ -n ${TVPC_REPO_ROOT:-} ]]; then
    candidate="$TVPC_REPO_ROOT"
  elif [[ -r /etc/tvpc/repo.path ]]; then
    IFS= read -r candidate < /etc/tvpc/repo.path
  else
    source_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    candidate="$(cd "$(dirname "$source_path")/.." 2>/dev/null && pwd || true)"
  fi

  REPO_ROOT=""
  if [[ -n $candidate && -f "$candidate/install.sh" ]]; then
    REPO_ROOT="$candidate"
  fi
}

resolve_repo_root

if [[ -z "$REPO_ROOT" || ! -x "$REPO_ROOT/install.sh" ]]; then
  echo "tvpc: install.sh not found or not executable" >&2
  exit 1
fi

# Detect flags that are standalone modes
has_mode=0
for arg in "$@"; do
  case "$arg" in
    --check|--list|-h|--help|help) has_mode=1 ;;
  esac
done

if [[ $has_mode -eq 1 ]]; then
  exec "$REPO_ROOT/install.sh" "$@"
else
  exec "$REPO_ROOT/install.sh" --update "$@"
fi
