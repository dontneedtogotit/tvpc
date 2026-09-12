#!/usr/bin/env bash
# enhance-cec.sh — Compatibility wrapper for tvpc-cec.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$REPO_ROOT/scripts/tvpc-cec.sh"
if [[ ! -x "$TARGET" ]] && command -v tvpc-cec >/dev/null 2>&1; then
  TARGET="$(command -v tvpc-cec)"
fi

if [[ "${1:-}" == "--check" ]]; then
  exec "$TARGET" check
else
  exec "$TARGET" setup "$@"
fi
