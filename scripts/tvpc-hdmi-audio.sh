#!/usr/bin/env bash
# tvpc-hdmi-audio.sh — put sound on the TV's HDMI input, whatever it is called.
#
# The previous version hardcoded alsa_card.pci-0000_00_1f.3 and the profile
# "output:hdmi-stereo-extra", and ran as root from a system unit — where there
# is no PipeWire to talk to, so it could never have worked. This runs inside
# the user session and detects the card, profile and sink.
#
# On "hdmi-stereo-extra": those are not LPCM variants. hdmi-stereo,
# hdmi-stereo-extra1, hdmi-stereo-extra2 are simply HDMI port 1, 2 and 3 on the
# codec. Any of them is 2-channel LPCM, which is what a 2013 Samsung wants —
# the thing to avoid is hdmi-surround* and the IEC958 passthrough profiles.
# So: pick whichever hdmi-stereo profile ALSA reports as actually connected.
set -uo pipefail

log() { echo "tvpc-hdmi-audio: $*"; }

# PipeWire may still be starting when the session comes up.
for _ in $(seq 1 30); do
  pactl info >/dev/null 2>&1 && break
  sleep 1
done
if ! pactl info >/dev/null 2>&1; then
  log "PipeWire/pulse not responding after 30s — giving up"
  exit 1
fi

# card <TAB> profile <TAB> available
mapfile -t CANDIDATES < <(pactl list cards 2>/dev/null | awk '
  /^Card #/                       { name=""; inprof=0 }
  /^[[:space:]]*Name:[[:space:]]/ { name=$2 }
  /^[[:space:]]*Profiles:/        { inprof=1; next }
  /^[[:space:]]*Active Profile:/  { inprof=0 }
  inprof && $1 ~ /^output:hdmi-stereo/ {
    prof=$1; sub(/:$/, "", prof)
    avail = (index($0, "available: no") > 0) ? "no" : "yes"
    print name "\t" prof "\t" avail
  }')

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  log "no HDMI stereo profile found — is the TV on and the cable in?"
  pactl list cards short 2>/dev/null | sed 's/^/  card: /'
  exit 1
fi

# Prefer a profile ALSA says is plugged in; otherwise take the first.
PICK=""
for row in "${CANDIDATES[@]}"; do
  [[ $row == *$'\t'yes ]] && { PICK="$row"; break; }
done
[[ -n $PICK ]] || { PICK="${CANDIDATES[0]}"; log "no HDMI port reports as connected; trying anyway"; }

CARD="${PICK%%$'\t'*}"
PROFILE="$(cut -f2 <<<"$PICK")"

log "card=$CARD profile=$PROFILE"
pactl set-card-profile "$CARD" "$PROFILE" || { log "failed to set profile"; exit 1; }

# The sink only exists once the profile is active.
SINK=""
for _ in $(seq 1 10); do
  SINK="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /hdmi/ {print $2; exit}')"
  [[ -n $SINK ]] && break
  sleep 1
done
if [[ -z $SINK ]]; then
  log "profile set but no HDMI sink appeared"
  exit 1
fi

pactl set-default-sink "$SINK"
pactl set-sink-mute "$SINK" 0 2>/dev/null || true
log "default sink -> $SINK"
