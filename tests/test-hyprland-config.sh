#!/usr/bin/env bash
# check-hyprland-config.sh — validate config/hypr/hyprland.lua without a NUC.
#
# Hyprland's config is Lua, so a typo is a runtime error on a machine whose
# only output is a television. This runs the config against a mock of the
# Hyprland 0.56 API and asserts the properties the TV shell depends on:
#
#   * it parses and executes with no error
#   * every hl.* call it makes exists
#   * the menu button is bound in the form that actually works
#   * bare arrows / OK / Back stay unbound, so they reach the app
#
# Needs `lua`. Skips cleanly if that is missing.
#
# Usage: ./scripts/check-hyprland-config.sh
set -uo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/config/hypr/hyprland.lua"

[[ -f $CONFIG ]] || { echo "missing: $CONFIG" >&2; exit 1; }

LUA=""
for cand in lua lua5.4 lua5.3 luajit; do
  command -v "$cand" >/dev/null 2>&1 && { LUA="$cand"; break; }
done
if [[ -z $LUA ]]; then
  echo "lua not installed (skipping hyprland config check)"
  exit 0
fi

if command -v luac >/dev/null 2>&1; then
  luac -p "$CONFIG" || exit 1
fi

CONFIG="$CONFIG" "$LUA" - <<'LUA'
local path = os.getenv("CONFIG")

-- Mock of the Hyprland 0.56 Lua API (wiki: Configuring/Basics/*).
-- Anything the config calls that is not here is a typo, and shows up as
-- "attempt to call a nil value" rather than as a black screen.
local cfg, binds = {}, {}
local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then merge(dst[k], v) else dst[k] = v end
  end
end
local function stub(name) return function(...) return { __dispatcher = name } end end
local handle = { set_enabled = function() end }

hl = {
  monitor        = function(t) cfg.__monitor = t end,
  config         = function(t) merge(cfg, t) end,
  env            = function(k, v) assert(type(k) == "string" and type(v) == "string", "hl.env takes two strings") end,
  curve          = function() end,
  animation      = function() end,
  gesture        = function() end,
  device         = function() end,
  workspace_rule = function() return handle end,
  permission     = function() end,
  exec_cmd       = function() end,
  dispatch       = function() end,
  on             = function(ev, fn)
                     assert(type(ev) == "string", "hl.on needs an event name")
                     assert(type(fn) == "function", "hl.on needs a function")
                     fn()
                   end,
  bind           = function(keys, d)
                     assert(type(keys) == "string", "bind keys must be a string")
                     assert(d ~= nil, "nil dispatcher for bind: " .. tostring(keys))
                     binds[keys] = true
                     return handle
                   end,
  window_rule    = function(t)
                     assert(type(t.match) == "table" and next(t.match) ~= nil,
                            "window_rule needs at least one match prop")
                     return handle
                   end,
  layer_rule     = function(t)
                     assert(type(t.match) == "table" and next(t.match) ~= nil,
                            "layer_rule needs at least one match prop")
                     return handle
                   end,
}
hl.dsp = {
  exec_cmd  = stub("exec_cmd"),
  exec_raw  = stub("exec_raw"),
  focus     = stub("focus"),
  exit      = stub("exit"),
  layout    = stub("layout"),
  window    = setmetatable({}, { __index = function(_, k) return stub("window." .. k) end }),
  workspace = setmetatable({}, { __index = function(_, k) return stub("workspace." .. k) end }),
}

local ok, err = pcall(dofile, path)
if not ok then
  io.stderr:write("hyprland.lua failed to run: " .. tostring(err) .. "\n")
  os.exit(1)
end

local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); os.exit(1) end
end

-- The remote's menu button. A bare "SUPER" binds nothing in Hyprland: a
-- modifier-only bind needs the target modmask plus the keysym.
check(binds["SUPER + SUPER_L"], "the menu button (SUPER + SUPER_L) is not bound")
check(not binds["SUPER"], 'bare "SUPER" is bound — that form binds nothing')

-- These must reach the application. VacuumTube's YouTube interface is
-- navigated with exactly these keys; stealing them breaks the whole box.
for _, k in ipairs({ "Return", "Escape", "left", "right", "up", "down", "KP_Enter" }) do
  check(not binds[k], 'bare "' .. k .. '" is bound — it would be stolen from the app')
end

-- TV-shell invariants.
check(cfg.general and cfg.general.layout == "monocle",
      "layout must be monocle so one app owns the screen")
check(cfg.misc and cfg.misc.key_press_enables_dpms,
      "key_press_enables_dpms must be on so the remote wakes the TV")
check(cfg.cursor and cfg.cursor.inactive_timeout and cfg.cursor.inactive_timeout > 0,
      "cursor.inactive_timeout must hide the idle pointer")

local n = 0
for _ in pairs(binds) do n = n + 1 end
print(("hyprland.lua OK — %d binds, monocle layout, remote keys left to the app"):format(n))
LUA
