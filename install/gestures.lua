-- Touchpad gestures, for ~/.config/hypr/input.lua.
--
-- The overview follows the fingers: a vertical swipe streams its motion to the
-- plugin, which moves the windows as you swipe and, on release, settles open or
-- closed depending on how far and how fast you went. From the desktop, up
-- opens Mission Control and down opens App Exposé of the app you are in (as
-- in macOS); the opposite direction closes, and you can change your mind
-- mid-swipe.
--
-- How: Hyprland (0.56+) accepts a table of start/update/end callbacks as a
-- gesture action. Each callback emits a custom event on Hyprland's event socket
-- (`hl.dsp.event`), which the plugin already listens on. Spawning
-- `omarchy-shell` per update would be far too slow to track a finger.
--
-- libinput only emits swipes for three or more fingers. Pick the count that is
-- not already taken by a horizontal workspace swipe -- `vertical` and
-- `horizontal` on the same count coexist, the initial direction decides.
--
-- Testing note: there is no ungesture in the Lua API, so `hyprctl reload`
-- cannot remove a gesture registered earlier in the session. After editing,
-- log out and back in.

local function mc_event(phase, value, time_ms)
  hl.dispatch(hl.dsp.event(string.format("mission-control-gesture:%s:%s:%d",
    phase, value, math.floor(time_ms or 0))))
end

hl.gesture({
  fingers = 4,
  direction = "vertical",
  action = {
    start = function(e) mc_event("start", string.format("%.3f", e.delta and e.delta.y or 0), e.time_ms) end,
    update = function(e) mc_event("update", string.format("%.3f", e.delta and e.delta.y or 0), e.time_ms) end,
    -- Hyprland names the release callback `finish`, not `end`.
    finish = function(e) mc_event("end", e.cancelled and 1 or 0, e.time_ms) end,
  },
})

-- Sideways swipe between desktops while the overview is up.
--
-- Hyprland's own workspace swipe would only slide the real desktops hidden
-- behind the overview. So while it is shown, the plugin calls
-- mission_control_swipe_mode(true), which swaps the horizontal gesture for one
-- that streams to the plugin -- the exposé then slides with the fingers, the
-- neighbouring desktop coming in beside it. On hide it calls (false) and the
-- normal workspace swipe is back. A config reload resets both.
local function mc_hswipe_event(phase, value, time_ms)
  hl.dispatch(hl.dsp.event(string.format("mission-control-hswipe:%s:%s:%d",
    phase, value, math.floor(time_ms or 0))))
end
local mc_hswipe_active = false
function mission_control_swipe_mode(open)
  open = open and true or false
  if open == mc_hswipe_active then return end
  mc_hswipe_active = open
  hl.gesture({ fingers = 4, direction = "horizontal", action = "unset" })
  if open then
    hl.gesture({
      fingers = 4,
      direction = "horizontal",
      action = {
        start = function(e) mc_hswipe_event("start", string.format("%.3f", e.delta and e.delta.x or 0), e.time_ms) end,
        update = function(e) mc_hswipe_event("update", string.format("%.3f", e.delta and e.delta.x or 0), e.time_ms) end,
        finish = function(e) mc_hswipe_event("end", e.cancelled and 1 or 0, e.time_ms) end,
      },
    })
  else
    hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
  end
end
hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
