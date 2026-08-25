#!/usr/bin/env bash
# cec-tv-poweron.sh — Power on the Samsung TV via CEC and switch input
# Target: Intel NUC7i5BNH + 2013 Samsung ~80" TV (Anynet+)
set -euo pipefail

CEC=/usr/bin/cec-client
if [[ ! -x "$CEC" ]]; then
  echo "cec-client not found" >&2
  exit 1
fi

# Give CEC bus a moment to settle
sleep 2

# Power on the TV (logical address 0 = playback device)
echo "on 0" | "$CEC" -s

# Make the NUC the active source so the TV switches to HDMI1
echo "as" | "$CEC" -s

# Nudge Samsung: some 2013 models need a second wake to switch input
sleep 1
echo "as" | "$CEC" -s

echo "CEC power-on + source switch complete."