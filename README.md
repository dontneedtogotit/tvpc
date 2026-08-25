# tvpc — Android-like HTPC Linux (Ubuntu 24.04 + Plasma Mobile + VacuumTube)

A one-script, reproducible build for turning an **Intel NUC7i5BNH** into a
TV/HTPC appliance that feels like an Android tablet on a **2013 Samsung ~80" TV**:

- **Plasma Mobile** as the default session (phone/tablet-style app grid)
- **VacuumTube** (Flatpak) as the first-class YouTube client with VA-API HW decode
- **CEC** for TV remote passthrough + auto power-on at boot (fails gracefully)
- **HDMI audio** forced to LPCM 2.0 (hdmi-stereo-extra) via `htpc-audio.service`
- **Auto-login** — boots straight to the home screen
- **Unattended-upgrades** + **Flatpak auto-update** for security patches
- **Broadwell GPU tuning**: i915 GuC/HuC, TearFree, VA-API decode
- **ZRAM swap**, **TLP** power tuning (~6W idle), tracker/indexer disabled

## Quick start

```bash
# On a fresh Ubuntu 24.04 Server (minimal) install on the NUC:
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

After reboot:
- TV powers on via CEC and switches to the NUC's HDMI input
- You land on the Plasma Mobile home screen at 1080p UI scale
- **VacuumTube** is pinned in the favorites bar (bottom dock)
- Audio routes over HDMI to the Samsung TV via `htpc-audio.service`
- Broadwell VA-API decode is active (`vainfo` shows H.264/HEVC entrypoints)

## Repo layout

```
tvpc/
├── install.sh                    # One-shot installer (run as root)
├── scripts/
│   ├── customize.sh              # Idempotent post-install tweaks
│   ├── cec-tv-poweron.sh         # CEC power-on + active source (fails safely)
│   └── install-extras.sh         # HW verification + NUC tuneables
├── overlays/                     # Files copied verbatim onto the target
│   └── etc/
│       ├── sddm.conf.d/autologin.conf
│       ├── pipewire/pipewire-pulse.d/99-htpc.conf
│       ├── pipewire/pipewire.conf.d/90-hdmi-pin.conf
│       ├── modules-load.d/i915.conf
│       ├── default/grub.d/tvpc.cfg
│       ├── NetworkManager/conf.d/90-tvpc-nuc.conf
│       ├── systemd/logind.conf
│       ├── systemd/system/htpc-audio.service
│       └── X11/xorg.conf.d/20-intel.conf
├── Makefile                      # Convenience targets
├── README.md
└── .gitignore
```

## Customizing

Edit `scripts/customize.sh` or add new files under `overlays/` and
re-run `./scripts/customize.sh` (safe to run multiple times).

## Hardware-specific notes

| Component | Setting | Why |
|-----------|---------|-----|
| **GPU (HD 620)** | `i915.enable_guc=2` | Enables GuC/HuC firmware for VA-API HW decode |
| **HDMI Audio** | `hdmi-stereo-extra` via `htpc-audio.service` | 2013 Samsung only accepts LPCM 2.0 reliably |
| **Resolution** | 1920×1080@60 via kwinrules | 4K@30 is flaky; 1080p UI readable on 80" |
| **CEC** | `cec-client on 0; as` | Powers on TV, makes NUC active source |
| **Swap** | ZRAM (50% RAM, zstd) | Silent, fast, saves SSD wear |
| **Power** | TLP + powertop auto-tune | Idle ~6W on NUC7 |
| **Wi-Fi** | Disabled via NM | Wired GbE preferred for 4K streaming |

## Post-reboot verification

```bash
vainfo                               # Broadwell VA-API entrypoints
pactl list sinks                     # HDMI sink is default
cec-client -l                        # CEC bus shows TV + NUC
systemctl status htpc-startup         # CEC power-on service
systemctl status htpc-audio          # HDMI audio profile service
flatpak run io.github.vacuumtube.VacuumTube --enable-features=VaapiVideoDecoder
```

## Troubleshooting

- **No audio**: `systemctl restart htpc-audio`
- **TV won't power on**: run `cec-client -s` manually; enable Anynet+ in TV menu
- **VacuumTube stutters**: ensure `vainfo` shows `VAEntrypointVLD` for H.264
- **UI too small**: edit `~/.config/plasma-desktop-appletsrc` Scale=1.2 → 1.5
- **VA-API not working**: reboot after first install; GuC firmware loads at boot

## Optional additions

```bash
# Netflix (Widevine via flatpak)
flatpak install flathub com.github.vkrinic.flatflix

# Jellyfin
flatpak install flathub com.github.iwalton3.jellyfin-media-player

# Plex
flatpak install flathub tv.plex.PlexHTPC
```