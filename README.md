# tvpc — Android-like HTPC Linux

A reproducible build turning an **Intel NUC7i5BNH** + **2013 Samsung ~80" TV**
into a phone/tablet-style HTPC appliance (Plasma Mobile + VacuumTube).

---

## 🔧 Quick Install

### Method 1: Run on existing Ubuntu 24.04 Server (requires internet)
```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

### Method 2: Offline USB installer (one-time internet to build USB)
```bash
git clone https://github.com/dontneedgotit/tvpc.git
cd tvpc
sudo ./scripts/make-offline-usb.sh /dev/sdX   # requires 7z or xorriso

# Insert USB → Boot NUC → Auto-install → First boot: sudo tvpc-install → reboot
```

---

## What you get

- **Plasma Mobile**: Android-like home screen with app grid (Wayland)
- **VacuumTube**: Native YouTube client (Flatpak) with VA-API hardware decode
- **CEC**: Auto powers on TV + switches to HDMI input on boot
- **HDMI audio**: Forced LPCM 2.0 (Samsung 2013 compatibility)
- **Auto-login**: Boots straight to Plasma Mobile
- **Maintenance**: unattended-upgrades + weekly Flatpak updates
- **Optimizations**: i915 GuC firmware, TLP power, ZRAM, no swap partition

---

## Repo structure

```
tvpc/
├── install.sh                       # One-shot installer (online)
├── scripts/
│   ├── install-ubuntu-server.sh     # USB builder with autoinstall (online)
│   ├── make-offline-usb.sh          # Full offline USB creator
│   ├── customize.sh                 # Idempotent UI/theme tweaks
│   ├── cec-tv-poweron.sh            # CEC power-on (fails gracefully)
│   ├── install-extras.sh            # HW verification + NUC tuneables
│   └── fix-apt-sources.sh           # Post-install apt source fix (offline)
├── autoinstall/
│   ├── user-data                    # Subiquity autoinstall (offline config)
│   └── meta-data                    # cloud-init metadata
├── overlays/                        # System config files copied to target
│   └── etc/
│       ├── sddm.conf.d/autologin.conf
│       ├── pipewire/pipewire-pulse.d/99-htpc.conf
│       ├── systemd/system/htpc-audio.service
│       ├── systemd/system/htpc-startup.service
│       ├── modules-load.d/i915.conf
│       ├── default/grub.d/tvpc.cfg
│       ├── systemd/logind.conf
│       └── X11/xorg.conf.d/20-intel.conf
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

## Verification (after install + reboot)

```bash
vainfo                               # VA-API entrypoints
pactl list sinks                     # HDMI sink active
systemctl status htpc-startup         # CEC service
systemctl status htpc-audio          # HDMI profile set
flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder
```

---

## Troubleshooting

- **No audio** → `sudo systemctl restart htpc-audio`
- **CEC fail** → check Anynet+ in TV settings; test: `echo "on 0" \| cec-client -s`
- **VA-API broken** → `sudo reboot` (GuC loads at boot)
- **UI too small** → edit `~/.config/plasma-desktop-appletsrc`, increase `Scale`

---

## Optional apps

```bash
flatpak install flathub com.github.vkrinic.flatflix        # Netflix
flatpak install flathub com.github.iwalton3.jellyfin-media-player # Jellyfin
flatpak install flathub tv.plex.PlexHTPC                  # Plex
```