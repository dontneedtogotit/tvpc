#!/usr/bin/env bash
# cec-tv-poweron.sh — Power on the Samsung TV via CEC and switch input
# Target: Intel NUC7i5BNH + 2013 Samsung ~80" TV (Anynet+)
# Safe to fail: if CEC adapter is missing, does not break boot
set -euo pipefail

CEC=/usr/bin/cec-client
if [[ ! -x "$CEC" ]]; then
  echo "cec-client not found, skipping TV power-on"
  exit 0
fi

# Give CEC bus a moment to settle
sleep 2

# Power on the TV (logical address 0 = TV on the CEC bus)
echo "on 0" | "$CEC" -s 2>/dev/null || echo "TV power-on command failed (CEC may be unavailable)"

# Make the NUC the active source so the TV switches to HDMI1
echo "as" | "$CEC" -s 2>/dev/null || true

# Nudge Samsung: some 2013 models need a second wake to switch input
sleep 1
echo "as" | "$CEC" -s 2>/dev/null || true

echo "CEC power-on + source switch complete."