.pragma library
// Henri UI tokens — SINGLE SOURCE OF TRUTH for every QML plugin.
// Never copy this file into a plugin; import it by absolute URL:
//   import "file:///home/henri/.local/share/henri-ui/Motion.js" as Motion
// Change a value here + reload the shell → every plugin follows.
// Keep gtk.css / motion.css and the tables in the henri-ui skill in step.

// ── Global switches ────────────────────────────────────────────────────────
// speed scales every duration and spring (1.2 = everything 20 % slower).
var speed = 1.0
// reduceMotion: components keep only crossfades (no scale, slide or spring).
var reduceMotion = false

function ms(v) { return Math.round(v * speed) }

// San Francisco itself, not `Style.font.family` — that one is the system
// "monospace" fontconfig alias (`omarchy font set`), shared with terminals
// and everything else that needs a true monospace, so it can't become a
// proportional font without breaking those. Plugins that want the Big Sur
// look for their own body/heading text use `Motion.uiFont` explicitly
// instead; local only (installed from SF-Symbols-27.dmg) — never commit the
// font file, only this family name.
var uiFont = "SF Pro"

// ── Durations (ms) ─────────────────────────────────────────────────────────
var instant = ms(90)    // hover in, press feedback
var fast = ms(160)      // hover out, color change, icon/text crossfade, tooltip
var base = ms(240)      // menus, dropdowns, toggles, small size changes
var slow = ms(380)      // panels, popovers, sheets, page transitions
var slower = ms(520)    // full screen rebuild: overview, launcher
// Mission Control, measured on macOS 26 (60 fps recording, missionControl.2windows
// in ~/macos-scrape): the windows shrink into the overview in 250 ms on an
// ease-in-out, and return in ~165 ms on an ease-out (fast start).
var overview = ms(250)
var overviewExit = ms(165)

function exit(d) { return Math.round(d * 0.7) }   // leaving is faster than arriving

// ── Curves (for easing.type: Easing.BezierSpline; Qt wants the 1,1 end point) ─
var easeOut = [0.22, 1, 0.36, 1, 1, 1]      // default: appear, react to input
var easeInOut = [0.45, 0, 0.15, 1, 1, 1]    // visible thing moves A → B
var easeExit = [0.4, 0, 0.7, 0.2, 1, 1]     // disappear

// ── Springs (SwiftUI response/dampingRatio) for HUi.SpringValue { preset: … } ─
function spring(response, dampingRatio) { return { response: response * speed, dampingRatio: dampingRatio } }
var smooth = spring(0.35, 1.0)    // default movement, highlight, popover scale
var snappy = spring(0.40, 0.85)   // toggles, press release, drag end
var gentle = spring(0.50, 1.0)    // big surfaces: panels, overview, sheets
var bouncy = spring(0.45, 0.75)   // rare, playful only

// ── Choreography ───────────────────────────────────────────────────────────
var pressScale = 0.97
// A dragged item (reorderable tile, Spaces thumbnail) lifts to this scale while
// held and settles back on drop with the snappy spring.
var liftScale = 1.05
var menuFromScale = 0.96
var popoverFromScale = 0.95
var exitToScale = 0.98
var iconFromScale = 0.8     // icon/glyph/dot crossfade: scales up from this
var menuOffsetY = -4          // menus drop 4 px out of their anchor
var toastOffset = 16          // toasts slide in from the screen edge
var pageParallax = 0.3        // outgoing page moves 30 % while the new one slides in
var flashDuration = ms(70)    // menu item blink after a click (macOS)
// Reveal waits for its window's first frame before animating; give up after this.
var firstFrameTimeout = 400
var tooltipDelay = 500
// Expensive work (spawning processes, scanning directories, building large
// models) waits this long after a surface opens, so no fork lands in the first
// frames of its animation.
var settleDelay = ms(120)
// Super+Tab switcher: the strip only appears once Super+Tab is held this long,
// a quick tap switches without flashing it (Cmd+Tab / Alt+Tab behaviour).
var switcherDelay = 50
// On commit the strip drifts this far in the direction the workspaces slide,
// so the overlay and the desktop read as one movement.
var carryOffset = 24
// Volume/brightness HUD: stays this long after the last key press (macOS).
var hudHold = ms(1500)
// One full cycle of a "thinking" indicator (the three pulsing dots while an
// agent composes an answer). Slower than any transition on purpose: it is a
// heartbeat, not a reaction, and at transition speed it reads as impatience.
var thinkingCycle = ms(1200)
var tooltipGrace = 1000       // follow-up tooltips show instantly within this window
// Rejected input (wrong password): one horizontal shake, 3 swings — the only
// allowed wobble, like the macOS login field.
var shakeDistance = 6
var shakeDuration = ms(300)

var staggerStep = 15
var staggerMax = 10
function stagger(index) { return Math.min(Math.max(0, index), staggerMax) * staggerStep }

// ── State fills (alpha of the tint color) ──────────────────────────────────
var hoverAlpha = 0.08
var pressedAlpha = 0.14
var disabledOpacity = 0.4
// Secondary text (shortcuts, captions, subtitles) = foreground at this alpha.
// Not Color.muted: in cupertino muted is 2.4:1 on the background; 0.65 gives 5.0:1.
var secondaryTextAlpha = 0.65

// ── Glass (translucent material) ────────────────────────────────────────────
// True frosted glass: panels/popovers sit at a low alpha over the desktop,
// tiles/rows inside them read noticeably more opaque so their edges stay
// legible without a hard outline — the gap between glassPanelAlpha and
// glassTileAlpha is what makes the boundary readable on a bright wallpaper.
// Pair with a Hyprland `layer_rule` blur on the surface's namespace (see
// looknfeel.lua's rule for HUi.PopupPanel's shared namespace) — without the
// compositor blur behind it, low alpha alone just looks washed out, not glass.
var glass = true
var glassTileAlpha = 0.42
var glassTileHoverAlpha = 0.55
var glassPanelAlpha = 0.35

// Text/glyph color on a filled color (accent buttons, selection): white or
// black, whichever has more contrast (WCAG). Pass a QML color.
function onColor(c) {
  function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  var l = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
  return (1.05 / (l + 0.05)) >= ((l + 0.05) / 0.05) ? "#ffffff" : "#000000"
}

// ── Shape (px, before Style.space scaling) ─────────────────────────────────
var radiusPanel = 14
var radiusPopover = 10
var radiusControl = 8
var radiusRow = 8
var radiusChip = 6
var radiusPill = 999   // capsules: toolbar clusters, segmented controls
var hairlineAlpha = 0.10

// ── Size (Apple HIG, desktop) ──────────────────────────────────────────────
var controlHeight = 30        // default control / hit target
var controlMin = 20           // never smaller
var menuItemHeight = 28
var focusRing = 2
var textMin = 10              // pt; body text follows Style.font.body
var contrastText = 4.5        // WCAG ratio for text ≤ 17 pt
var contrastLarge = 3.0       // ≥ 18 pt or bold, and UI glyphs

// ── Kinetic scrolling ──────────────────────────────────────────────────────
var flickDeceleration = 1500
var maximumFlickVelocity = 4000
