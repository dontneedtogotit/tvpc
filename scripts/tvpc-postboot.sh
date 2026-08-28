#!/usr/bin/env bash
# tvpc-postboot.sh — run once after the first boot: SSH, Wi-Fi, polish.
# Usage: sudo ./scripts/tvpc-postboot.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0)"; exit 1; }

# shellcheck source=/dev/null
if [[ -r /etc/default/tvpc ]]; then . /etc/default/tvpc; fi
HTPC_USER="${TVPC_USER:-htpc}"

echo "=== tvpc post-boot configuration ==="

# ---------------------------------------------------------------------------
echo "[1/4] SSH"
if ! command -v sshd >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
fi
systemctl enable --now ssh
echo "  SSH listening on port 22 — ssh $HTPC_USER@<nuc-ip>"

# ---------------------------------------------------------------------------
echo "[2/4] Wi-Fi"
if command -v nmcli >/dev/null 2>&1; then
  wifi_dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  if [[ -n ${wifi_dev:-} ]]; then
    echo "  Wi-Fi device: $wifi_dev"
    if nmcli -t -f DEVICE,STATE device status | grep "^$wifi_dev:unmanaged" >/dev/null; then
      echo "  device was unmanaged; handing it to NetworkManager"
      nmcli device set "$wifi_dev" managed yes || true
    fi
    nmcli radio wifi | grep disabled >/dev/null && nmcli radio wifi on || true
    nmcli device wifi list || true
    echo
    echo "  Connect with:"
    echo "    nmcli device wifi connect '<SSID>' password '<password>'"
  else
    echo "  No Wi-Fi device found. Hardware present?"
    lspci | grep -i network || true
    echo "  If a device is listed but missing here: sudo apt-get install linux-firmware"
  fi
else
  echo "  NetworkManager not installed: sudo apt-get install network-manager"
fi

# ---------------------------------------------------------------------------
echo "[3/4] Recommended packages"
# `dpkg -l | grep "^ii\s*$pkg"` matched on a prefix, so "git" counted as
# installed whenever git-man was. dpkg-query asks about the exact package.
missing=()
for pkg in pavucontrol vim htop git curl wget; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep "install ok installed" >/dev/null || missing+=("$pkg")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "  Installing: ${missing[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
else
  echo "  All present"
fi

# ---------------------------------------------------------------------------
echo "[4/4] Polish"
if ! systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi
command -v powertop >/dev/null 2>&1 && powertop --auto-tune >/dev/null 2>&1 || true

# NOTE: this script used to run `chage -d 0 htpc`, which expires the password
# and forces a change at next login. On a box that autologins into a desktop
# that is not hardening — PAM blocks the autologin on the expired password and
# you are back to staring at a black screen. Change the password directly
# instead; it is a one-off, and it happens now rather than at boot.
echo
echo "  The default password for '$HTPC_USER' is 'htpc'. Change it now:"
if [[ -t 0 ]]; then
  passwd "$HTPC_USER" || echo "  (skipped — run 'sudo passwd $HTPC_USER' later)"
else
  echo "    sudo passwd $HTPC_USER"
fi

echo
echo "=== Post-boot configuration complete ==="
echo
echo "  tvpc-doctor                     full health check"
echo "  sudo tvpc-repair --check        diagnose a black screen"
echo "  sudo ./scripts/enhance-cec.sh   Samsung remote button mapping"
echo "  sudo ./scripts/customize.sh     re-apply UI tweaks"
