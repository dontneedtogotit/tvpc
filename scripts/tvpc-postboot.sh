#!/usr/bin/env bash
# tvpc-postboot.sh - Run after first boot into Plasma Mobile to enable SSH, fix Wi-Fi, and polish
# 
# Usage: sudo ./tvpc-postboot.sh
set -euo pipefail

echo "=== tvpc post-boot configuration ==="

# 1. Enable SSH server
echo "[1/4] Enabling SSH server..."
if ! command -v sshd >/dev/null 2>&1; then
    apt-get update
    apt-get install -y openssh-server
fi
systemctl enable ssh
systemctl start ssh
echo "SSH enabled on port 22"
echo "To connect from your laptop: ssh htpc@<nuc-ip-address>"
echo "Default password: htpc (change it immediately!)"

# 2. Check and fix Wi-Fi if needed
echo ""
echo "[2/4] Checking Wi-Fi status..."
if command -v nmcli >/dev/null 2>&1; then
    # NetworkManager is available
    wifi_dev=$(nmcli device status | grep wifi | awk '{print $1}' || echo "")
    if [[ -n "$wifi_dev" ]]; then
        echo "Wi-Fi device found: $wifi_dev"
        # Check if it's managed
        if nmcli device show "$wifi_dev" | grep -q "STATE:\s*unmanaged"; then
            echo "Wi-Fi device is unmanaged, making it managed..."
            nmcli device set "$wifi_dev" managed yes
        fi
        
        # Check if radio is on
        if nmcli radio wifi | grep -q "disabled"; then
            echo "Enabling Wi-Fi radio..."
            nmcli radio wifi on
        fi
        
        # List available networks
        echo "Scanning for Wi-Fi networks..."
        nmcli device wifi list
        
        echo ""
        echo "To connect to Wi-Fi:"
        echo "  nmcli device wifi list"
        echo "  nmcli device wifi connect '<SSID>' password '<password>'"
    else
        echo "No Wi-Fi device detected by NetworkManager"
        # Check if it's a driver issue
        lspci | grep -i network || true
        lsusb | grep -i network || true
        echo ""
        echo "If you see a wireless device above but it's not working,"
        echo "you may need to install additional firmware:"
        echo "  sudo apt-get install linux-firmware"
    fi
else
    echo "NetworkManager not found, checking with ip link..."
    ip link show | grep -i wireless || echo "No wireless interfaces visible"
    echo ""
    echo "To install NetworkManager and Wi-Fi tools:"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install network-manager"
fi

# 3. Install any missing firmware/packages
echo ""
echo "[3/4] Checking for recommended packages..."
# These are commonly needed for HTPC functionality
recommended_packages="\
    pavucontrol \
    vim \
    htop \
    git \
    curl \
    wget \
    "

# Check which ones are missing
missing_pkgs=""
for pkg in $recommended_packages; do
    if ! dpkg -l | grep -q "^ii\s*$pkg"; then
        missing_pkgs="$missing_pkgs $pkg"
    fi
done

if [[ -n "$missing_pkgs" ]]; then
    echo "Installing recommended packages: $missing_pkgs"
    apt-get update
    apt-get install -y $missing_pkgs
else
    echo "All recommended packages already installed"
fi

# 4. Final polishing
echo ""
echo "[4/4] Applying final polish..."

# Change default password (important for security!)
echo ""
echo "===== IMPORTANT: Change default password ====="
echo "The default password for user 'htpc' is currently 'htpc'"
echo "You should change it immediately for security:"
echo "  passwd"
echo ""

# Enable automatic updates if not already done
if ! systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
    echo "Enabling automatic security updates..."
    dpkg-reconfigure -plow unattended-upgrades
fi

# Optimize power settings for NUC
if command -v powertop >/dev/null 2>&1; then
    echo "Applying power optimizations..."
    powertop --auto-tune || true
fi

# Ensure VacuumTube is set to use VA-API
echo ""
echo "To ensure VacuumTube uses hardware video decode:"
echo "  Edit the VacuumTube shortcut to add:"
echo "    --enable-features=VaapiVideoDecoder --use-gl=egl"
echo "Or run it manually with:"
echo "    flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder"

# Final instructions
echo ""
echo "=== Post-boot configuration complete ==="
echo ""
echo "Next steps:"
echo "1. Change your password: passwd"
echo "2. Connect to Wi-Fi (if needed):"
echo "   nmcli device wifi list"
echo "   nmcli device wifi connect '<SSID>' password '<password>'"
echo "3. From your laptop, connect via SSH:"
echo "   ssh htpc@<nuc-ip-address>"
echo "4. Enjoy your HTPC!"
echo ""
echo "Useful commands:"
echo "  sudo tvpc-install          # Re-run the installer if needed"
echo "  sudo ./scripts/customize.sh  # Re-apply UI tweaks"
echo "  vainfo                     # Check VA-API status"
echo "  pactl list sinks           # Check audio output"