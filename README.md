# tvpc — Android-like HTPC Linux (Ubuntu 24.04 + Plasma Mobile + VacuumTube)

A one-script, reproducible build for turning any x86_64 PC into a
TV/HTPC appliance that feels like an Android tablet:

- **Plasma Mobile** as the default session (phone/tablet-style app grid)
- **VacuumTube** (Flatpak) as the first-class YouTube client
- **CEC** for TV remote passthrough
- **HDMI audio** forced on boot
- **Auto-login** — boots straight to the home screen
- **Unattended-upgrades** for security patches

## Quick start

```bash
# On a fresh Ubuntu 24.04 minimal install:
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y git
git clone https://github.com/<your-user>/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

After reboot you land on the Plasma Mobile home screen. Open the app
drawer and **pin VacuumTube** to the favorites bar.

## Repo layout

```
tvpc/
├── install.sh            # One-shot installer (run as root)
├── scripts/
│   └── customize.sh      # Idempotent post-install tweaks
├── overlays/             # Files copied verbatim onto the target
│   ├── etc/sddm.conf.d/autologin.conf
│   ├── etc/pipewire/pipewire-pulse.d/99-htpc.conf
│   └── etc/systemd/logind.conf
└── README.md
```

## Customizing

Edit `scripts/customize.sh` or add new files under `overlays/` and
re-run `./scripts/customize.sh` (safe to run multiple times).

## Notes

- **Default user:** `htpc` / `htpc` — change the password immediately.
- **HDMI audio card** in `99-htpc.conf` may need adjusting for your
  hardware (`pactl list cards`).
- For **Raspberry Pi** use `pi-gen` or `rpi-5.0` kernel options instead
  of the generic x86_64 installer.
