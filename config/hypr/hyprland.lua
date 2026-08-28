-- tvpc — Hyprland shell for a TV driven by a CEC remote.
--
-- Hyprland 0.55+ reads Lua from ~/.config/hypr/hyprland.lua. The older
-- hyprlang "hyprland.conf" format is deprecated upstream, so everything
-- here uses the Lua API as documented for 0.56.
--
-- Installed by scripts/tvpc-hyprland.sh. Hyprland reloads this the moment
-- it is saved, so it can be tuned over SSH while watching the result on
-- the TV. `hyprctl reload` forces it.

----------------------------------------------------------------------
-- Monitor
----------------------------------------------------------------------
-- TVPC_MODE / TVPC_SCALE come from /etc/default/tvpc via the session
-- wrapper. Leaving them unset means "ask the TV what it wants", which is
-- right on essentially every set.
local mode  = os.getenv("TVPC_MODE") or "preferred"
local scale = tonumber(os.getenv("TVPC_SCALE") or "") or "auto"

hl.monitor({ output = "", mode = mode, position = "auto", scale = scale })

-- Older TVs crop a few percent off each edge. TVPC_OVERSCAN insets the
-- window area by that many pixels. Leave it at 0 and first look for a
-- "Just Scan" / "Screen Fit" / "PC" picture-size mode on the TV — that is
-- the better fix, because it also stops the TV from rescaling the image.
local ov = tonumber(os.getenv("TVPC_OVERSCAN") or "") or 0

----------------------------------------------------------------------
-- Look and feel
----------------------------------------------------------------------
hl.config({
    general = {
        -- monocle: one app fills the screen and the rest stack behind it.
        -- This is the Plasma Mobile / TV shape — you are never asked to
        -- manage a tiling tree with a 5-button remote.
        layout      = "monocle",

        gaps_in     = 0,
        gaps_out    = { top = ov, right = ov, bottom = ov, left = ov },
        border_size = 2,

        col = {
            active_border   = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
            inactive_border = "rgba(00000000)",
        },

        resize_on_border = false,
        allow_tearing    = false,
    },

    decoration = {
        rounding       = 12,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        shadow = { enabled = false },

        -- Blur is what makes the bar and the launcher read as "Hyprland"
        -- rather than "a panel on a black screen". Two passes at size 6 is
        -- comfortable for Iris Plus 640; raise passes only if it stays smooth.
        blur = {
            enabled  = true,
            size     = 6,
            passes   = 2,
            vibrancy = 0.17,
        },
    },

    animations = { enabled = true },

    misc = {
        -- No anime mascot on the living-room TV, thanks.
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        force_default_wallpaper  = 0,
        background_color         = "rgb(0b0e14)",

        -- The remote wakes the screen: CEC key presses arrive as real key
        -- events through ydotool, so key_press_enables_dpms is what makes
        -- the "any button wakes the TV" behaviour work.
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,

        vfr = true,
        vrr = 0,

        font_family = "Noto Sans",
    },

    cursor = {
        -- Hide the pointer when it has not moved. This is the appliance
        -- fix for "black screen with a cursor sitting in the middle".
        inactive_timeout = 3,
        hide_on_key_press = true,
    },

    input = {
        kb_layout    = "us",
        follow_mouse = 1,
        sensitivity  = 0,

        -- No touchpad on a NUC, but harmless if a wireless keyboard has one.
        touchpad = { natural_scroll = false },
    },
})

----------------------------------------------------------------------
-- Environment
----------------------------------------------------------------------
-- Cursor big enough to find from the sofa.
hl.env("XCURSOR_SIZE",     "48")
hl.env("HYPRCURSOR_SIZE",  "48")
-- iHD is the right VA-API driver for Kaby Lake (Iris Plus 640).
hl.env("LIBVA_DRIVER_NAME", "iHD")
-- Electron/Chromium apps (VacuumTube) should use Wayland directly.
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")
hl.env("MOZ_ENABLE_WAYLAND", "1")

----------------------------------------------------------------------
-- Autostart
----------------------------------------------------------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    -- Solid background rather than an image: it is one less thing to fail,
    -- and it matches misc.background_color above.
    hl.exec_cmd("swaybg -c '#0b0e14'")
    -- Keeps the TV awake. There is no hypridle here on purpose — an
    -- appliance that blanks mid-film is a bug, not a power saving.
    hl.exec_cmd("tvpc-hypr-autostart")
end)

----------------------------------------------------------------------
-- Keybindings
----------------------------------------------------------------------
-- What the CEC remote actually sends (see scripts/enhance-cec.sh):
--   OK -> Return   Up/Down/Left/Right -> arrows
--   Root menu -> Super (alone)        Exit -> Escape
--
-- Bare arrows, Return and Escape are deliberately NOT bound. They have to
-- reach the app: YouTube's TV interface in VacuumTube is navigated with
-- exactly those keys. The only key the shell claims is the menu button.
local MOD = "SUPER"

-- Menu button. Binding a modifier on its own needs the target modmask AND
-- the keysym ("SUPER + SUPER_L"), not a bare "SUPER" — a bare modifier binds
-- nothing, which would leave the remote with no way into the shell at all.
-- The remote's root-menu code is sent as keycode 125 (KEY_LEFTMETA) by the
-- CEC listener, which is Super_L. Pressing it again closes the launcher.
hl.bind("SUPER + SUPER_L", hl.dsp.exec_cmd("tvpc-hypr-menu"), { release = true })

hl.bind(MOD .. " + Return", hl.dsp.exec_cmd("foot"))
hl.bind(MOD .. " + Q",      hl.dsp.window.close())
hl.bind(MOD .. " + F",      hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(MOD .. " + M",      hl.dsp.exec_cmd("tvpc-hypr-menu power"))

-- Cycle apps: with monocle this is how you get "back to the other thing".
hl.bind(MOD .. " + Tab",   hl.dsp.focus({ last = true }))
hl.bind(MOD .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(MOD .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(MOD .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(MOD .. " + down",  hl.dsp.focus({ direction = "down" }))

-- Volume and transport, for a USB/Bluetooth keyboard. The remote's own
-- volume and media keys are handled in the CEC listener instead, because
-- they must work even when nothing has keyboard focus.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true })
hl.bind("XF86AudioPlay",        hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause",       hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext",        hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",        hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

----------------------------------------------------------------------
-- Window rules
----------------------------------------------------------------------
-- Apps ask to be maximized and Hyprland honours it by default, which
-- fights the monocle layout. Ignore the request; the layout already
-- gives every window the whole screen.
hl.window_rule({
    name           = "suppress-maximize",
    match          = { class = ".*" },
    suppress_event = "maximize",
})

-- Media players must be able to hold the screen awake on their own.
hl.window_rule({
    name         = "media-idle-inhibit",
    match        = { class = ".*" },
    idle_inhibit = "fullscreen",
})

-- VacuumTube is the point of the box: give it the screen with no border
-- and no rounding so the video reaches the edges.
hl.window_rule({
    name        = "vacuumtube",
    match       = { class = "(?i)vacuumtube" },
    fullscreen  = true,
    border_size = 0,
    rounding    = 0,
    content     = "video",
})

----------------------------------------------------------------------
-- Layer rules
----------------------------------------------------------------------
-- The bar and the launcher are layer surfaces, not windows, so they need
-- their own rules. Blurring them is what gives the shell its depth
-- instead of looking like flat panels pasted on the wallpaper.
hl.layer_rule({
    name         = "blur-bar",
    match        = { namespace = "^waybar$" },
    blur         = true,
    ignore_alpha = 0.4,
})

hl.layer_rule({
    name         = "blur-launcher",
    match        = { namespace = "^launcher$" },
    blur         = true,
    ignore_alpha = 0.4,
})
