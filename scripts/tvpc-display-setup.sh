#!/usr/bin/env bash
# tvpc-display-setup.sh — make Plasma legible from a couch.
#
# Runs inside the session (autostart), best-effort: a display tweak must never
# be able to take the screen down, so every step here is allowed to fail.
# Configure in /etc/default/tvpc:
#   TVPC_SCALE=1.5          global scale; 1 disables scaling entirely
#   TVPC_MODE=1920x1080@60  force a mode; empty (default) = trust the EDID
set -uo pipefail

[[ -r /etc/default/tvpc ]] && . /etc/default/tvpc
SCALE="${TVPC_SCALE:-1.5}"
MODE="${TVPC_MODE:-}"

command -v kscreen-doctor >/dev/null 2>&1 || { echo "kscreen-doctor missing; skipping"; exit 0; }

# kscreen needs the session up before it will answer.
for _ in $(seq 1 15); do
  kscreen-doctor -o >/dev/null 2>&1 && break
  sleep 2
done

OUTPUT="$(kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && /enabled/ {print $3; exit}')"
[[ -n ${OUTPUT:-} ]] || { echo "no enabled output reported; skipping"; exit 0; }

if [[ -n $MODE ]]; then
  kscreen-doctor "output.$OUTPUT.mode.$MODE" \
    && echo "mode -> $MODE on $OUTPUT" \
    || echo "could not set mode $MODE (see: kscreen-doctor -o)"
fi

if [[ $SCALE != "1" && $SCALE != "1.0" ]]; then
  kscreen-doctor "output.$OUTPUT.scale.$SCALE" \
    && echo "scale -> $SCALE on $OUTPUT" \
    || echo "could not set scale $SCALE"
fi
