# tvpc — Android-like HTPC Linux (Ubuntu 24.04 + Plasma Mobile + VacuumTube)

A one-script, reproducible build for turning an **Intel NUC7i5BNH** into a
TV/HTPC appliance that feels like an Android tablet on a **2013 Samsung ~80" TV**:

- **Plasma Mobile** as the default session (phone/tablet-style app grid)
- **VacuumTube** (Flatpak) as the first-class YouTube client with VA-API HW decode
- **CEC** for TV remote passthrough + auto power-on at boot
- **HDMI audio** forced to LPCM 2.0 (hdmi-stereo-extra) — reliable on 2013 Samsungs
- **Auto-login** — boots straight to the home screen
- **Unattended-upgrades** + **Flatpak auto-update** for security patches
- **Broadwell GPU tuning**: i915 GuC/HuC, TearFree, VA-API decode
- **ZRAM swap**, **TLP** power tuning (~6W idle), tracker/indexer disabled

## Quick start

```bash
# On a fresh Ubuntu 24.04 Server (minimal) install on the NUC:
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git
git clone https://github.com/<your-user>/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

After reboot:
- TV powers on via CEC and switches to the NUC's HDMI input
- You land on the Plasma Mobile home screen at 1080p UI scale
- **VacuumTube** is pinned in the favorites bar (bottom dock)
- Audio routes over HDMI to the Samsung TV
- Broadwell VA-API decode is active (`vainfo` shows H.264/HEVC entrypoints)

## Repo layout

```
tvpc/
├── install.sh                    # One-shot installer (run as root)
├── scripts/
│   ├── customize.sh              # Idempotent post-install tweaks
│   ├── cec-tv-poweron.sh         # CEC power-on + active source
│   └── install-extras.sh         # HW verification + NUC tuneables
├── overlays/                     # Files copied verbatim onto the target
│   ├── etc/
│   │   ├── sddm.conf.d/autologin.conf
│   │   ├── pipewire/pipewire-pulse.d/99-htpc.conf
│   │   ├── pipewire/pipewire.conf.d/90-hdmi-pin.conf
│   │   ├── modules-load.d/i915.conf
│   │   ├── default/grub.d/tvpc.cfg
│   │   ├── NetworkManager/conf.d/90-tvpc-nuc.conf
│   │   ├── systemd/logind.conf
│   │   └── X11/xorg.conf.d/20-intel.conf
│   └── usr/local/bin/htpc-volume-step
├── Makefile                      # Convenience targets
└── README.md
```

## Customizing

Edit `scripts/customize.sh` or add new files under `overlays/` and
re-run `./scripts/customize.sh` (safe to run multiple times).

## Hardware-specific notes

| Component | Setting | Why |
|-----------|---------|-----|
| **GPU (HD 620)** | `i915.enable_guc=2` | Enables GuC/HuC firmware for VA-API HW decode |
| **HDMI Audio** | `hdmi-stereo-extra` | 2013 Samsung only accepts LPCM 2.0 reliably |
| **Resolution** | 1920×1080@60 forced | 4K@30 is flaky; 1080p UI is readable on 80" |
| **CEC** | `cec-client on 0; as` | Powers on TV, makes NUC active source |
| **Swap** | ZRAM (50% RAM, zstd) | Silent, fast, saves SSD wear |
| **Power** | TLP + powertop auto-tune | Idle ~6W on NUC7 |
| **Wi-Fi** | Disabled by default | Wired GbE preferred for 4K streaming |

## Post-reboot verification

```bash
vainfo                              # Broadwell VA-API entrypoints
pactl list sinks                    # HDMI sink is default
cec-client -l                       # CEC bus shows TV + NUC
systemctl status htpc-startup       # CEC service ran
flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder --use-gl=egl
```

## Troubleshooting

- **No audio**: `pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:hdmi-stereo-extra`
- **TV won't power on**: check `cec-client -s` manually; some 2013 Samsungs need Anynet+ enabled in TV menu
- **VacuumTube stutters**: ensure `vainfo` shows `VAEntrypointVLD` for H.264; force `--enable-features=VaapiVideoDecoder`
- **UI too small**: edit `~/.config/kcmoutputrc` Scale=1.2 → 1.5

## Optional additions

```bash
# Netflix (Widevine via flatpak)
flatpak install flathub com.github.vkrinic.flatflix

# Jellyfin
flatpak install flathub com.github.iwalton3.jellyfin-media-player

# Plex
flatpak install flathub tv.plex.PlexHTPC
```