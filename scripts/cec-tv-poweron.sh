#!/usr/bin/env bash
# cec-tv-poweron.sh — Compatibility wrapper for tvpc-cec.sh poweron
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$REPO_ROOT/scripts/tvpc-cec.sh" ]]; then
  exec "$REPO_ROOT/scripts/tvpc-cec.sh" poweron "$@"
elif command -v tvpc-cec >/dev/null 2>&1; then
  exec tvpc-cec poweron "$@"
else
  CEC=/usr/bin/cec-client
  [[ -x "$CEC" ]] || exit 0
  sleep 2
  echo "on 0" | "$CEC" -s 2>/dev/null || true
  echo "as" | "$CEC" -s 2>/dev/null || true
fi
