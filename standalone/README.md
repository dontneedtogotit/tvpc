# tvpc-cameras-gui — standalone for Omarchy / Hyprland

A standalone packaging of the tvpc IP security camera manager. Designed to drop
into any Arch-based Omarchy / Hyprland install without pulling in the full tvpc
repo.

## What it is

`tvpc-cameras-gui` is a PySide6 desktop app that:

* discovers cameras on your LAN (RTSP, ONVIF, HTTP, mDNS, ARP)
* manages a config file of `NAME|URL|USER|PASS|...` entries
* shows live preview thumbnails via ffmpeg
* opens picture-in-picture mpv windows
* records to disk with ffmpeg
* monitors camera health and notifies on status changes

## One-liner install (Omarchy / Arch)

```bash
curl -fsSL https://raw.githubusercontent.com/dontneedtogotit/tvpc/main/standalone/install.sh | bash
```

This clones the repo into `~/.local/share/tvpc-cameras-gui`, creates a venv,
installs PySide6 + requests, drops a desktop entry into
`~/.local/share/applications/`, and adds Hyprland window rules so the app
floats at 1280×760 centered.

## Manual install

```bash
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc
bash standalone/install.sh
```

## After install

1. Search for **tvpc Cameras** in your app launcher (Fuzzel, rofi, etc.)
2. Or run from a terminal:
   ```bash
   tvpc-cameras-gui
   ```
3. On first launch the wizard checks for `ffmpeg`, `mpv`, and PySide6.
   If anything is missing, use the wizard's one-click install or run:
   ```bash
   sudo pacman -S ffmpeg mpv python-pyside6
   ```

## Config

* `~/.config/tvpc/cameras.conf` — camera list
* `~/.config/tvpc/recordings/` — saved MKV recordings
* `~/.config/tvpc/layout.conf` — last grid layout choice

## Updating

Re-run the install script; it rsyncs the package fresh and keeps your config.

## Hyprland integration

The installer appends to your `~/.config/hypr/hyprland.conf`:

```
# tvpc-cameras-gui window rules
source = ~/.config/hypr/tvpc-cameras-gui.conf
```

That file sets float + size + center for the app so it behaves like a tool
window rather than a fullscreen app.

## Uninstall

```bash
rm -rf ~/.local/share/tvpc-cameras-gui
rm -f ~/.local/bin/tvpc-cameras-gui
rm -f ~/.local/share/applications/tvpc-cameras-gui.desktop
rm -f ~/.config/hypr/tvpc-cameras-gui.conf
# Optionally remove config and recordings:
rm -rf ~/.config/tvpc
```

## Dependencies

* Python 3.9+
* PySide6
* ffmpeg
* mpv (for PiP / fullscreen windows)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| App doesn't appear in launcher | Run `update-desktop-database ~/.local/share/applications` |
| Black previews | `ffmpeg` missing — `sudo pacman -S ffmpeg` |
| PiP fails | `mpv` missing — `sudo pacman -S mpv` |
| ImportError: PySide6 | `sudo pacman -S python-pyside6` |
| Window opens fullscreen | Remove `source = ~/.config/hypr/tvpc-cameras-gui.conf` from hyprland.conf and restart Hyprland |
