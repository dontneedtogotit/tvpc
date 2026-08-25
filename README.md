# tvpc — Android-like HTPC Linux (Ubuntu 24.04 + Plasma Mobile + VacuumTube)

This repo provides **two methods** to build your HTPC:

## Method 1: One-shot installer on existing Ubuntu Server
Use this if you already have Ubuntu 24.04 Server (minimal) installed on your NUC.

```bash
# On fresh Ubuntu 24.04 Server install:
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

## Method 2: Autoinstall USB (Recommended for fresh installs)
Use this for a completely unattended install from scratch on bare metal.

```bash
# From any Linux/macOS machine:
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc

# 1. Find your USB device (WARNING: will be erased!)
lsblk

# 2. Create bootable installer (replace /dev/sdX with your USB)
sudo ./scripts/install-ubuntu-server.sh /dev/sdX

# 3. Boot the NUC from USB, let it auto-install
#    (takes ~10-15 minutes depending on USB speed)

# 4. After reboot, SSH into the fresh install:
ssh htpc@tvpc.local   # password: htpc (change immediately!)

# 5. Run the final HTPC setup:
cd tvpc && sudo ./install.sh
sudo reboot
```

---

## What you get

After both methods complete, you'll have:

- **Plasma Mobile** as the default session (phone/tablet-style app grid)
- **VacuumTube** (Flatpak) as the first-class YouTube client with VA-API HW decode
- **CEC** for TV remote passthrough + auto power-on at boot
- **HDMI audio** forced to LPCM 2.0 (hdmi-stereo-extra) via `htpc-audio.service`
- **Auto-login** — boots straight to the home screen
- **Unattended-upgrades** + **Flatpak auto-update** for security patches
- **Broadwell GPU tuning**: i915 GuC/HuC, TearFree, VA-API decode
- **ZRAM swap**, **TLP** power tuning (~6W idle), tracker/indexer disabled

---

## Hardware-specific notes (Intel NUC7i5BNH + 2013 Samsung TV)

| Component | Setting | Why |
|-----------|---------|-----|
| **GPU (HD 620)** | `i915.enable_guc=2` | Enables GuC/HuC firmware for VA-API HW decode |
| **HDMI Audio** | `hdmi-stereo-extra` via `htpc-audio.service` | 2013 Samsung only accepts LPCM 2.0 reliably |
| **Resolution** | 1920×1080@60 via kwinrules | 4K@30 is flaky; 1080p UI readable on 80" |
| **CEC** | `cec-client on 0; as` | Powers on TV, makes NUC active source |
| **Swap** | ZRAM (50% RAM, zstd) | Silent, fast, saves SSD wear |
| **Power** | TLP + powertop auto-tune | Idle ~6W on NUC7 |
| **Wi-Fi** | Disabled via NM | Wired GbE preferred for 4K streaming |

---

## Post-reboot verification

```bash
vainfo                               # Broadwell VA-API entrypoints
pactl list sinks                     # HDMI sink is default
cec-client -l                        # CEC bus shows TV + NUC
systemctl status htpc-startup         # CEC power-on service
systemctl status htpc-audio          # HDMI audio profile service
flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder
```

---

## Troubleshooting

- **No audio**: `systemctl restart htpc-audio`
- **TV won't power on**: run `cec-client -s` manually; enable Anynet+ in TV menu
- **VacuumTube stutters**: ensure `vainfo` shows `VAEntrypointVLD` for H.264
- **UI too small**: edit `~/.config/plasma-desktop-appletsrc` Scale=1.2 → 1.5
- **VA-API not working**: reboot after first install; GuC firmware loads at boot

---

## Optional additions

```bash
# Netflix (Widevine via flatpak)
flatpak install flathub com.github.vkrinic.flatflix

# Jellyfin
flatpak install flathub com.github.iwalton3.jellyfin-media-player

# Plex
flatpak install flathub tv.plex.PlexHTPC
```