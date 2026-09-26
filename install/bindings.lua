-- Mission Control keybindings, for ~/.config/hypr/bindings.lua (Omarchy's Lua
-- Hyprland config). Plugins cannot bind keys themselves, so this is manual.
--
-- The keys go to the plugin as Hyprland events (custom>>mission-control ...),
-- which it listens for on the socket it already has open: no process per key
-- press, so the overview is on screen the frame the key goes down. Pressing
-- the same key again closes; another mode's key switches the mode in place.
-- F8 is only what was free on the machine this was written on -- any key
-- works. On a Dell XPS the F8 key doubles as the display-switch key, so its
-- XF86Display keysym is bound too, whichever way Fn-Lock is set.

o.bind("F8", "Mission Control", hl.dsp.event("mission-control toggle"))
o.bind("SHIFT + F8", "App Exposé", hl.dsp.event("mission-control toggle app"))
o.bind("CTRL + F8", "Show Desktop", hl.dsp.event("mission-control toggle desktop"))

-- The same for a laptop whose F8 is a media key.
o.bind("XF86Display", "Mission Control", hl.dsp.event("mission-control toggle"))
o.bind("SHIFT + XF86Display", "App Exposé", hl.dsp.event("mission-control toggle app"))
o.bind("CTRL + XF86Display", "Show Desktop", hl.dsp.event("mission-control toggle desktop"))

-- The shell's IPC works as well, e.g. for a hot corner or a dock:
--   omarchy-shell shell toggle henri.missioncontrol '{"mode":"app"}'
