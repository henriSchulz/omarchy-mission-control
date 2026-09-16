-- Touchpad gestures, for ~/.config/hypr/input.lua.
--
-- The overview follows the fingers: a vertical swipe streams its motion to the
-- plugin, which moves the windows as you swipe and, on release, settles open or
-- closed depending on how far and how fast you went. Swipe up opens, swipe down
-- closes, and you can change your mind mid-swipe.
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
    ["end"] = function(e) mc_event("end", e.cancelled and 1 or 0, e.time_ms) end,
  },
})
