# tvpc — Android-like HTPC Linux

A reproducible build turning an **Intel NUC7i5BNH** + **2013 Samsung ~80" TV**
into a TV-shaped Linux appliance: boots straight into a desktop, YouTube via
VacuumTube, and the Samsung remote drives it over HDMI-CEC.

---

## Black screen at boot?

That was this repo's own fault, and it is fixed. On the affected machine, get a
terminal — **Ctrl+Alt+F3** on the TV, or SSH in from a laptop — and run:

```bash
cd tvpc && git pull
sudo ./scripts/tvpc-repair.sh --check    # what is wrong, changes nothing
sudo ./scripts/tvpc-repair.sh            # fix it
sudo reboot
```

If it is still black afterwards, `sudo ./scripts/tvpc-repair.sh --logs` prints
the kernel, SDDM, Xorg and session logs that explain why.

### What was actually broken

| # | Cause | Effect |
|---|-------|--------|
| 1 | `/etc/X11/xorg.conf.d/20-intel.conf` set `Driver "intel"` | `xserver-xorg-video-intel` is not installed on Ubuntu 24.04 and is not part of `xserver-xorg-video-all` any more. Xorg exits with *no screens found*, so SDDM never draws anything. |
| 2 | Autologin hardcoded `Session=plasma-mobile.desktop` | Nothing verified that session existed. If the package was missing, SDDM had nothing to start. |
| 3 | Plasma Mobile as the default session | It is Plasma 5.27's **touchscreen** shell. When its shell fails to start, `kwin_wayland` stays up showing a black root window and a pointer — a black screen with a cursor, exactly. |
| 4 | Default systemd target left at `multi-user.target` | This is an Ubuntu **Server** base. A display manager can be installed and enabled and still never run. |
| 5 | `quiet splash` on the kernel command line | Plymouth covered all of the above, so the failure was invisible. |
| 6 | `tvpc-postboot.sh` ran `chage -d 0 htpc` | An expired password blocks autologin under PAM. |

Fixes: the Xorg file is gone (`modesetting` handles Kaby Lake with no config at
all), `scripts/tvpc-session.sh` refuses to write an autologin session it cannot
find on disk, the default session is now plain Plasma Wayland, the installer
sets `graphical.target`, `splash` is gone, and the forced password expiry is
replaced by changing the password there and then.

---

## Sessions

The session is chosen once and stored in `/etc/default/tvpc`:

```bash
sudo ./scripts/tvpc-session.sh plasma          # default: Plasma Wayland desktop
sudo ./scripts/tvpc-session.sh plasma-mobile   # KDE's touchscreen shell
sudo ./scripts/tvpc-session.sh plasma-x11      # X11 fallback
sudo ./scripts/tvpc-session.sh kiosk           # kwin_wayland + one app
sudo ./scripts/tvpc-session.sh auto            # first of the above that exists

sudo ./scripts/tvpc-session.sh hypr            # opt-in: Hyprland, TV-tuned
sudo ./scripts/tvpc-session.sh bigscreen       # opt-in: KDE's TV shell
sudo ./scripts/tvpc-session.sh phosh           # opt-in: GNOME's phone shell
```

The opt-in ones need installing first (`tvpc-hyprland.sh`, `plasma-bigscreen`,
`phosh`). They are not in the `auto` chain. If the session is missing the
resolver refuses rather than writing autologin for a session that is not there.

**`plasma` is the default**, not `plasma-mobile`. Plasma Mobile is built for a
phone: it wants touch, it pulls in an on-screen keyboard, and it is the least
reliable of the four on this hardware. It is still one command away if you want
it — install it first with `TVPC_INSTALL_PLASMA_MOBILE=1` in `/etc/default/tvpc`.

`kiosk` is the safety net: `kwin_wayland` plus VacuumTube, no shell and no
panel. It is what `auto` falls back to so a broken Plasma never means a blank TV.

### Other shells and desktops

Checked against the Ubuntu 24.04 (noble) archive. Availability matters more
than reputation here: anything unpackaged means building from source on a box
you want to leave alone.

| Option | In 24.04? | What it is | Fit for a TV + remote |
|--------|-----------|------------|-----------------------|
| **Plasma Bigscreen** `plasma-bigscreen` 5.27.11 | yes | KDE's actual TV shell — big tiles, D-pad navigation | **The recommended shell here.** Archive-native, and the CEC remote drives it as-is. `tvpc-bigscreen.sh --switch` |
| **Kodi** `kodi` 20.5 | yes | The classic 10-foot media centre, HDMI-CEC built in | Best remote experience by a distance, but it replaces the session rather than running inside one. Noble ships no Kodi session file, and no `kodi-gbm` / `kodi-standalone-service` |
| **Phosh** `phosh` 0.38 | yes | GNOME's phone shell — the direct Plasma Mobile equivalent | Same problem as Plasma Mobile: built for touch. `tvpc-session.sh phosh` |
| **Lomiri** `lomiri` 0.2.1 | yes | Ubuntu Touch's shell | Touch-first, niche on desktop hardware |
| **Hyprland** 0.56 | not in the archive | Animated Wayland compositor, Lua-configured | Ships via the actively maintained `ppa:cppiber/hyprland`. Built into a TV shell here: `tvpc-hyprland.sh`, then `tvpc-session.sh hypr` |
| **Sway** 1.9, **labwc** 0.7, **wayfire** 0.8 | yes | Tiling/stacking Wayland compositors | Keyboard-driven; no remote story |
| **Cage** 0.1.5 | yes | Single-application kiosk compositor | Genuinely useful — close to what the built-in `kiosk` session does with `kwin_wayland` |
| **Weston** 13 | yes | Reference compositor with a kiosk shell | Works, but you get nothing else |
| GNOME, XFCE, LXQt, Cinnamon, Budgie | yes | Conventional desktops | Same category as Plasma; no advantage here |

Short version: if driving Plasma from the couch annoys you, use **Plasma
Bigscreen** —

```bash
sudo ./scripts/tvpc-bigscreen.sh --switch
sudo systemctl restart sddm
```

— and **Kodi** if you want a real media centre and don't mind it owning the
whole screen. The Hyprland route exists further down, but read the warning
on it first.

Two honest caveats: Plasma Bigscreen 5.27 is lightly maintained upstream, and
neither it nor Phosh has been tested on this hardware. Both are one command to
try and one command to leave — `tvpc-session.sh plasma` puts you back.

(An earlier version of this file said Bigscreen "still carries Mycroft
voice-assistant dependencies". That was wrong. It ships a
`mycroft-skill-launcher` binary, but its `Depends` are only KDE Frameworks,
Qt5, `plasma-workspace`, `plasma-nano` and `plasma-nm` — no voice assistant
is pulled in.)

### The Bigscreen session

KDE's own TV shell, and the one to use. Big tiles, D-pad navigation, and it
reads the plain arrow keys and Enter the CEC listener already sends — no key
remapping, no custom launcher, nothing to tune.

```bash
sudo ./scripts/tvpc-bigscreen.sh --switch
sudo systemctl restart sddm
```

`sudo tvpc-session plasma` puts you back, `bigscreen-x11` is there if Wayland
misbehaves, and `sudo tvpc-bigscreen --remove` uninstalls it.

**Why this is the low-risk option.** Everything comes from Ubuntu's universe
archive at the same Plasma 5.27 already installed, so no library is swapped
out from under the running desktop. `plasma-bigscreen` depends only on KDE
Frameworks, Qt5, `plasma-workspace`, `plasma-nano` and `plasma-nm` — all
already present or archive-native. The installer checks apt's exit status,
then confirms both session files are actually on disk before it will switch
anything, and `tvpc-session` independently refuses to point autologin at a
session that is not there.

Screen blanking is handled by `customize.sh`, which seeds
`powermanagementprofilesrc` into both `/etc/skel` and the live user's home.
`tvpc-bigscreen.sh` warns if that has not been run, because a TV that blanks
after five minutes looks exactly like a boot failure.

**Tuning it.** Two things need adjusting on almost every TV:

```bash
sudo tvpc-bigscreen --ui-scale 10      # whole UI too big? this is the knob
sudo tvpc-bigscreen --list-apps        # what the home screen shows, with ids
sudo tvpc-bigscreen --hide firefox,org.kde.plasma-systemmonitor
sudo tvpc-bigscreen --show firefox     # put one back
```

`--ui-scale` sets the base font point size, which sounds unrelated but is the
master scale control: everything in Bigscreen is laid out in
`Kirigami.Units.gridUnit`, and that is derived from font metrics. Bigscreen is
already a 10-foot UI built around the 10pt default, so `customize.sh`'s
couch-sized 13pt scales it a second time and the interface stops fitting the
screen. 10 is the value to start from. The choice is saved as
`TVPC_FONT_SIZE` in `/etc/default/tvpc` so re-running `customize.sh` keeps it.

`--hide` writes the `blacklist` key in `~/.config/applications-blacklistrc`,
which is what `ApplicationListModel::loadApplications()` reads. It is
undocumented but it is how Bigscreen is meant to be filtered; the ids are the
`.desktop` basenames that `--list-apps` prints. Bigscreen already omits
terminal applications and anything marked `NoDisplay`, and `--list-apps`
applies the same filter so what it prints is what you see on the TV.

### The Hyprland session

> **Warning — this broke a working box.** On a real NUC the install failed and
> left the machine at a black screen. Two defects: the installer discarded
> `apt-get`'s exit status, and it checked for Hyprland only *after* installing
> the bar, launcher and fonts. So a failed Hyprland still pulled PPA builds of
> shared libraries onto a system whose Plasma was linked against Ubuntu's.
>
> Both are fixed — the PPA is now pinned to priority 100 so it can never
> replace an already-installed Ubuntu package, Hyprland goes in first and
> alone, and any failure backs the PPA out again. But the underlying tension
> is real: Hyprland 0.56 wants newer core libraries than noble ships, and this
> box's Plasma does not. **Use Bigscreen above.** If you want Hyprland
> properly, Ubuntu 26.04 LTS packages it natively (0.53.3) and needs no PPA.
>
> Recovery, if you are reading this too late:
> ```bash
> sudo apt-get install -y ppa-purge
> sudo ppa-purge ppa:cppiber/hyprland
> sudo rm -f /etc/apt/preferences.d/90-tvpc-hyprland
> sudo tvpc-session plasma && sudo systemctl restart sddm
> ```


A Plasma Mobile-shaped shell with Hyprland's look: one app fills the screen,
a blurred status bar on top, a launcher on the menu button, and animations.

```bash
sudo ./scripts/tvpc-hyprland.sh     # install (adds a PPA)
sudo tvpc-session hypr              # switch to it
sudo systemctl restart sddm
```

`sudo tvpc-session plasma` puts you straight back, and
`sudo tvpc-hyprland --remove` uninstalls the lot.

**What makes it TV-shaped rather than a tiling desktop.** The layout is
`monocle`, so one app owns the screen and the rest stack behind it — you are
never asked to manage a tiling tree with a five-button remote. The only key
the shell claims is the menu button; **arrows, OK and Back are deliberately
left unbound** so they reach the app, which is what keeps YouTube navigable in
VacuumTube. Screen blanking is off, `hypridle` is not installed, and the
pointer hides after three seconds so an idle box shows a picture, not a cursor
on black.

**Where things live.** Config is Lua, not the old `hyprland.conf` — Hyprland
deprecated hyprlang in 0.55, and the PPA is on 0.56.

| File | Purpose |
|------|---------|
| `config/hypr/hyprland.lua` | compositor: layout, look, binds, window rules |
| `config/hypr/waybar/` | the status bar |
| `config/hypr/fuzzel.ini` | the launcher |
| `scripts/tvpc-hypr-menu.sh` | curated app + power menu |

Edit them in the repo and re-run `sudo tvpc-hyprland` to push them out;
a config you have edited by hand is left alone unless you pass `--force`
(which keeps a `.bak`). Hyprland reloads on save, so tuning over SSH while
watching the TV works.

**Knobs**, all in `/etc/default/tvpc`:

| Variable | Effect |
|----------|--------|
| `TVPC_OVERSCAN` | pixel inset if your TV crops the edges (try the TV's "Just Scan" mode first) |
| `TVPC_SCALE` / `TVPC_MODE` | force a scale factor or a video mode |
| `TVPC_AUTOSTART_APP` | command to launch at login; unset means start at the launcher |

**The PPA caveat, stated plainly.** Hyprland is not in the Ubuntu 24.04
archive, so this pulls from `ppa:cppiber/hyprland` — third-party, though
actively maintained and current. That PPA also carries its own builds of
core libraries: PipeWire, libinput, libxkbcommon, wayland-protocols, spdlog.
Letting those upgrade underneath a working Plasma desktop is how you get a
black screen, so the installer pins the **entire PPA to priority 100**:

* packages that exist only in the PPA (Hyprland and its own libraries)
  install normally, because nothing in the archive competes with them;
* packages already installed from Ubuntu are **never** silently replaced.

If Hyprland genuinely needs a newer core library than noble ships, apt now
reports an unmet dependency and installs nothing at all. That is the correct
outcome: a clean "no" is much better than half-upgrading the libraries under
a running desktop. The installer also puts Hyprland in **first and alone**,
and backs the PPA out again if it does not appear — so a failed install
leaves the box exactly as it was found.

**If it does go wrong**, `ppa-purge` reverts every package that came from
the PPA to its Ubuntu version:

```bash
sudo apt-get install -y ppa-purge
sudo ppa-purge ppa:cppiber/hyprland
sudo rm -f /etc/apt/preferences.d/90-tvpc-hyprland
sudo tvpc-session plasma && sudo systemctl restart sddm
```

`sudo tvpc-hyprland --remove` does the same thing for you.

**Untested on hardware.** I have no NUC to try this on. The config is
validated against Hyprland 0.56's documented Lua API and executed against a
mock of it, the installer has been run end-to-end against stubs, and
`tvpc-session` refuses to point autologin at a session that is not on disk —
so a failed install cannot black-screen the box. But the first real boot is
still the first real boot: keep SSH open, and `tvpc-repair --check` and
`~/.local/state/tvpc/hyprland.log` are there if it comes up wrong.

---

## Install

### Method 1: online, onto an existing Ubuntu 24.04 install

```bash
git clone https://github.com/dontneedtogotit/tvpc.git
cd tvpc
sudo ./install.sh
sudo reboot
```

The installer verifies before it finishes that sddm is enabled, the default
target is `graphical.target`, and the autologin session file exists. It exits
non-zero and tells you what to fix rather than letting you reboot into a black
screen.

### Method 2: offline USB

```bash
sudo ./scripts/make-offline-usb.sh /dev/sdX
# Boot USB -> auto-install -> sudo tvpc-install -> reboot
```

### Method 3: Ventoy

```bash
sudo ./scripts/prepare-ventoy-data.sh /dev/sdXN
# Boot the ISO via Ventoy, add: autoinstall ds=nocloud;label=TVPC-DATA
```

### After the first boot

```bash
sudo ./scripts/tvpc-postboot.sh   # SSH, Wi-Fi, password
```

---

## Keeping the machine where it is meant to be

`tvpc-update` compares the running system against the state this repo intends,
reports what is already done and what is not, and fixes the gaps.

```bash
sudo ./scripts/tvpc-update.sh --list          # what it checks
sudo ./scripts/tvpc-update.sh --check         # report only, changes nothing
sudo ./scripts/tvpc-update.sh                 # converge, then apt + flatpak update
sudo ./scripts/tvpc-update.sh --no-packages   # converge only
```

It checks 18 items: the config file, the TV user and its groups, the absence of
the display-breaking files, whether the helper programs in `/usr/local/bin`
still match the repo, whether every overlay file is applied, the kernel command
line, `graphical.target`, sddm, autologin pointing at a session that exists, the
audio and CEC units, zram, TLP, the flatpak timer, Flathub, VacuumTube, and the
TV user's Plasma config.

The helper and overlay checks compare file contents, so they catch **drift** —
a helper edited in place, or an overlay that changed in the repo and was never
re-applied — not just absence. It tells you when a reboot is needed, and it is
safe to re-run.

Three scripts, three jobs:

| Script | Question it answers | Needs the repo? |
|--------|--------------------|-----------------|
| `tvpc-doctor` | Is the machine working right now? | no |
| `tvpc-repair` | It boots to a black screen — fix that | no |
| `tvpc-update` | Is the machine where the repo says it should be? | yes |

---

## Tweaks app — `tvpc-tweaks`

A runnable "Tweaks" app that does the couch-level adjustments in one place:
**UI scaling**, **removing apps from the home screen**, theme, display mode,
TV sleep, autostart apps, and session switching. It is an arrow-key menu that
works over the CEC remote *and* SSH, and it doubles as one-shot commands for
scripted/headless use.

```bash
make tweaks            # install /usr/local/bin/tvpc-tweaks + a home-screen launcher
make tweaks-menu      # run it interactively right now
```

Launch **TV Tweaks** from the home screen (it opens in a terminal) or run it
from a shell. Both forms understand the same actions:

```bash
tvpc-tweaks scale 1.5            # global UI scale (live now, persisted via TVPC_SCALE)
tvpc-tweaks font 13             # base font size (scales the whole Bigscreen UI)
tvpc-tweaks apps                # list home-screen apps + shown/hidden state
tvpc-tweaks hide firefox,vlc    # remove apps from the home screen
tvpc-tweaks show firefox        # put an app back
tvpc-tweaks theme dark|light
tvpc-tweaks mode 1920x1080@60   # or: mode auto
tvpc-tweaks idle on|off         # stay awake / allow the TV to sleep
tvpc-tweaks autostart           # manage autostart apps (interactive)
tvpc-tweaks session plasma      # switch session (needs root)
tvpc-tweaks status
```

Home-screen app removal drives both mechanisms: Bigscreen's
`applications-blacklistrc` and plain Plasma's launcher favorites, so the app
drops off whichever shell is active. Scaling and mode persist through
`/etc/default/tvpc` (`TVPC_SCALE` / `TVPC_MODE`) and are applied live by
`tvpc-tweaks setup` at login. Reboot-persisting changes need root; user-level
tweaks apply immediately as the logged-in user.

### The full home-screen preset

`tvpc-tweaks home-preset` applies the recommended couch layout in one go:

- dark theme,
- a **Watch YouTube** hero tile (if VacuumTube is installed),
- a **Power** tile (reboot / shut down / restart shell / log out) via `tvpc-power`,
- **curates the home screen** down to a small whitelist — YouTube, a browser,
  Kodi, Files, Settings, Power — so the remote never scrolls two hundred entries,
- a dark wallpaper (where Plasma's tooling allows it),
- switches the session to **Plasma Bigscreen** when it is installed.

```bash
make home                 # sudo ./scripts/tvpc-tweaks.sh home-preset
```

Log out and back in (or `sudo systemctl restart sddm`) to see it. Re-run any
time; it is idempotent.

### VacuumTube-only home + All Apps

For the most minimal layout, `tvpc-tweaks vacuum-only` leaves **just
VacuumTube** on the home screen and makes every other app reachable through the
**All Apps** launcher (`tvpc-allapps`) — a browseable list of everything
installed, including apps hidden from the home. It also points the remote's
**Home** button at All Apps, so the rest of the catalogue is one press away
without cluttering the home.

```bash
make home-vacuum          # sudo ./scripts/tvpc-tweaks.sh vacuum-only
tvpc-allapps              # open the full app list on demand
```

On the default Plasma session the remote Home button already opens the full
launcher (Kickoff) too, so this mainly matters for the curated / Bigscreen home.

---

## Configuration — `/etc/default/tvpc`

| Setting | Default | Meaning |
|---------|---------|---------|
| `TVPC_USER` | `htpc` | Account the TV session logs in as |
| `TVPC_SESSION` | `auto` | `auto`, `plasma`, `plasma-mobile`, `plasma-x11`, `kiosk` |
| `TVPC_SCALE` | `1.5` | Plasma global scale for couch viewing; `1` disables |
| `TVPC_MODE` | *(empty)* | Force a mode, e.g. `1920x1080@60`; empty trusts the EDID |
| `TVPC_INSTALL_PLASMA_MOBILE` | `0` | Also install Plasma Mobile |
| `TVPC_WIRED_ONLY` | `0` | `1` powers down the Wi-Fi radio |

---

## Hardware profile: NUC7i5BNH

The NUC7i5BNH is a **Core i5-7260U — Kaby Lake (gen9), Iris Plus Graphics 640.**
Earlier revisions of this repo called it Broadwell throughout and tuned it for
the wrong generation; those settings are gone.

| Component | Setting | Rationale |
|-----------|---------|-----------|
| **GPU** | no `i915` module options | GuC/HuC submission is unused on gen9 by default and VA-API decode does not need it. The driver default is right. |
| **VA-API** | `LIBVA_DRIVER_NAME=iHD` | `intel-media-va-driver` is the gen9 driver; i965 is the fallback |
| **Xorg** | none | `modesetting` drives Kaby Lake correctly; the old `Driver "intel"` config is what caused the black screen |
| **HDMI audio** | first available `hdmi-stereo*` profile | Detected at runtime. `-extra1`/`-extra2` are HDMI **ports 2 and 3**, not LPCM variants — all of them are 2-channel LPCM, which is what a 2013 Samsung wants. Avoid `hdmi-surround` and the IEC958 passthrough profiles. |
| **Resolution** | EDID, `TVPC_MODE` to override | Forced via KMS/kscreen, not an Xorg Modeline |
| **Power** | TLP pinned to its AC profile | Mains-powered; never treat it as a laptop on battery |
| **Swap** | ZRAM (zstd, 50%) | Silent, no disk I/O |
| **CEC** | `cec-client` | Powers the TV on and claims the HDMI input at boot |

---

## Remote control (Samsung Anynet+ over CEC)

```bash
sudo ./scripts/enhance-cec.sh
```

| Button | Action |
|--------|--------|
| Play / Pause | play-pause via MPRIS |
| Stop / FF / RW | stop / next / previous |
| Vol +/−, Mute | system volume, 2% steps |
| OK, arrows, Exit | Enter, arrows, Esc |
| Root menu | Meta (application launcher) |

Three separate bugs used to stop this working, all fixed: the listener ran
`cec-client -d 1` (errors only, so no traffic frames to read), matched frames
with a regex anchored to the start of a line that always begins `TRAFFIC:`, then
converted the keycode to decimal and compared it against hex labels. Key
injection also needs `ydotoold`, which is a **separate package** on Ubuntu — the
`ydotool` package ships only the client, and there is no systemd unit for the
daemon, so this repo installs one.

Only one process can hold the CEC adapter. To watch raw traffic, stop the
listener first: `sudo systemctl stop tvpc-cec-remote && cec-client -d 8`.

---

## Health check

```bash
make doctor        # or: tvpc-doctor
```

Checks boot-to-desktop (target, sddm, session file, kernel command line, stale
Xorg config), GPU/VA-API, HDMI audio, CEC, Wi-Fi, SSH, swap and Flatpak updates.

---

## Troubleshooting

| Symptom | Try |
|---------|-----|
| Black screen at boot | `sudo tvpc-repair --check`, then `sudo tvpc-repair` |
| Screen goes black after a few minutes | `sudo ./scripts/customize.sh` — sets powerdevil to never blank or dim |
| No audio | `systemctl --user restart tvpc-audio`, then `tvpc-doctor` |
| Remote does nothing | `journalctl -u tvpc-cec-remote -f`; check `systemctl status ydotoold` |
| CEC not responding | Enable Anynet+ in the TV's settings; test `echo "on 0" \| cec-client -s` |
| VA-API broken | `LIBVA_DRIVER_NAME=iHD vainfo` |
| UI too small | Raise `TVPC_SCALE` in `/etc/default/tvpc`, log out and back in |
| Wrong resolution | Set `TVPC_MODE=1920x1080@60` in `/etc/default/tvpc` |
| SSH refused | `sudo systemctl enable --now ssh` |
| Wi-Fi missing | `sudo apt install linux-firmware`; check `iw list` |

---

## Repo structure

```
tvpc/
├── install.sh                      # One-shot installer (online), verifies before it exits
├── scripts/
│   ├── tvpc-repair.sh              # Fix a box that boots to a black screen
│   ├── tvpc-update.sh              # Converge the system to the intended state
│   ├── tvpc-session.sh             # Choose + wire up the graphical session
│   ├── tvpc-doctor.sh              # Health check
│   ├── tvpc-postboot.sh            # Run once after first boot
│   ├── tvpc-hdmi-audio.sh          # Detect and select the HDMI output
│   ├── customize.sh                # Idempotent UI/theme tweaks
│   ├── enhance-cec.sh              # Samsung remote button mapping
│   ├── cec-tv-poweron.sh           # CEC power-on at boot
│   ├── install-extras.sh           # HW checks + NUC tuning
│   ├── tvpc-tweaks.sh              # All-in-one UI/display/audio/CEC tweaks
│   ├── make-offline-usb.sh         # Offline USB creator
│   ├── prepare-ventoy-data.sh      # Ventoy data partition prep
│   └── install-ubuntu-server.sh    # Simple USB builder
├── autoinstall/                    # Subiquity autoinstall config
├── overlays/etc/                   # Files rsynced onto /
├── Makefile
└── README.md
```

---

## Optional apps

```bash
flatpak install flathub com.github.iwalton3.jellyfin-media-player
flatpak install flathub tv.plex.PlexHTPC
```

If you would rather have a purpose-built 10-foot interface than a desktop,
**Kodi** is packaged in Ubuntu (`kodi`, `kodi-gbm`, `kodi-standalone-service`)
and has HDMI-CEC remote support built in. It replaces the session rather than
running inside it, so it is not wired into `tvpc-session.sh`.
