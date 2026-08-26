# tvpc — Android-like HTPC Linux

A reproducible build turning an **Intel NUC7i5BNH** + **2013 Samsung ~80" TV**
into a phone/tablet-style HTPC appliance (Plasma Mobile + VacuumTube).

---

## 🔧 Quick Install

### Method 1: Online install (existing Ubuntu Server)
```bash
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

### Method 2: Offline USB (one-time internet to build USB)
```bash
sudo ./scripts/make-offline-usb.sh /dev/sdX
# Boot USB → Auto-install → sudo tvpc-install → reboot
```

### Method 3: Ventoy (ISO on Ventoy, data partition offline)
```bash
sudo ./scripts/prepare-ventoy-data.sh /dev/sdXN   # prep data partition
# Boot ISO via Ventoy → add kernel param: autoinstall ds=nocloud;label=TVPC-DATA
```

---

## Post-install: Run once after first boot

```bash
sudo ./tvpc-postboot.sh
```

This enables SSH, fixes Wi-Fi, installs recommended packages, and guides you through password changes.

---

## What you get

- **Plasma Mobile**: Android-like home screen with app grid (Wayland)
- **VacuumTube**: Native YouTube client (Flatpak) with VA-API hardware decode
- **CEC**: Auto powers on TV + switches to HDMI input on boot
- **HDMI audio**: Forced LPCM 2.0 (Samsung 2013 compatibility)
- **Auto-login**: Boots straight to Plasma Mobile
- **SSH**: Enabled for remote management
- **Maintenance**: unattended-upgrades + weekly Flatpak updates
- **Optimizations**: i915 GuC firmware, TLP power, ZRAM, no swap partition

---

## Repo structure

```
tvpc/
├── install.sh                       # One-shot installer (online)
├── tvpc-postboot.sh                # Run once after first boot (SSH, Wi-Fi, polish)
├── scripts/
│   ├── make-offline-usb.sh         # Full offline USB creator
│   ├── prepare-ventoy-data.sh      # Ventoy data partition prep
│   ├── install-ubuntu-server.sh    # Simple USB builder
│   ├── customize.sh                # Idempotent UI/theme tweaks
│   ├── cec-tv-poweron.sh          # CEC power-on (fails gracefully)
│   ├── install-extras.sh           # HW verification + NUC tuneables
│   └── fix-apt-sources.sh          # Post-install apt source fix
├── autoinstall/
│   ├── user-data                   # Subiquity autoinstall config
│   └── meta-data
├── overlays/etc/
│   ├── sddm.conf.d/autologin.conf
│   ├── pipewire/pipewire-pulse.d/99-htpc.conf
│   ├── systemd/system/htpc-audio.service
│   ├── systemd/system/htpc-startup.service
│   ├── modules-load.d/i915.conf
│   ├── default/grub.d/tvpc.cfg
│   ├── systemd/logind.conf
│   └── X11/xorg.conf.d/20-intel.conf
├── Makefile
└── README.md
```

---

## Hardware profile: NUC7i5BNH + Samsung TV (2013, ~80")

| Component | Setting | Rationale |
|-----------|---------|-----------|
| **GPU** | `i915.enable_guc=2` | GuC/HuC firmware for VA-API decode |
| **HDMI Audio** | `hdmi-stereo-extra` | 2013 Samsung accepts LPCM 2.0 only |
| **Resolution** | 1080p@60 via KWin rules | 4K@30 flaky on 2013 model |
| **Power** | TLP + powertop | ~6W idle |
| **Swap** | ZRAM (zstd, 50%) | Silent, no disk I/O |
| **CEC** | `cec-client on 0; as` | Power on TV + switch input |

---

## Post-reboot checklist

```bash
# SSH from laptop
ssh htpc@<nuc-ip>

# Check everything
vainfo                     # VA-API entrypoints
pactl list sinks           # HDMI sink active
systemctl status htpc-startup  # CEC service
systemctl status htpc-audio   # HDMI profile set
systemctl status ssh          # SSH enabled

# Connect Wi-Fi (if no ethernet)
nmcli device wifi list
nmcli device wifi connect '<SSID>' password '<password>'

# Launch VacuumTube with hardware decode
flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder
```

---

## Troubleshooting

- **No audio** → `sudo systemctl restart htpc-audio`
- **CEC fail** → enable Anynet+ in TV settings; test: `echo "on 0" | cec-client -s`
- **VA-API broken** → `sudo reboot` (GuC loads at boot)
- **UI too small** → edit `~/.config/plasma-desktop-appletsrc`, increase `Scale`
- **SSH refused** → `sudo systemctl enable --now ssh`
- **Wi-Fi missing** → check `iw list`; install firmware: `sudo apt install linux-firmware`

---

## Optional apps

```bash
flatpak install flathub com.github.vkrinic.flatflix        # Netflix
flatpak install flathub com.github.iwalton3.jellyfin-media-player # Jellyfin
flatpak install flathub tv.plex.PlexHTPC                  # Plex
```