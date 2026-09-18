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

// ── Durations (ms) ─────────────────────────────────────────────────────────
var instant = ms(90)    // hover in, press feedback
var fast = ms(160)      // hover out, color change, icon/text crossfade, tooltip
var base = ms(240)      // menus, dropdowns, toggles, small size changes
var slow = ms(380)      // panels, popovers, sheets, page transitions
var slower = ms(520)    // full screen: overview, mission control, launcher

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
var menuFromScale = 0.96
var popoverFromScale = 0.95
var exitToScale = 0.98
var menuOffsetY = -4          // menus drop 4 px out of their anchor
var toastOffset = 16          // toasts slide in from the screen edge
var pageParallax = 0.3        // outgoing page moves 30 % while the new one slides in
var flashDuration = ms(70)    // menu item blink after a click (macOS)
// Reveal waits for its window's first frame before animating; give up after this.
var firstFrameTimeout = 400
var tooltipDelay = 500
var tooltipGrace = 1000       // follow-up tooltips show instantly within this window

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
var radiusRow = 6
var radiusChip = 5
var hairlineAlpha = 0.10

// ── Size (Apple HIG, desktop) ──────────────────────────────────────────────
var controlHeight = 28        // default control / hit target
var controlMin = 20           // never smaller
var menuItemHeight = 26
var focusRing = 2
var textMin = 10              // pt; body text follows Style.font.body
var contrastText = 4.5        // WCAG ratio for text ≤ 17 pt
var contrastLarge = 3.0       // ≥ 18 pt or bold, and UI glyphs

// ── Kinetic scrolling ──────────────────────────────────────────────────────
var flickDeceleration = 1500
var maximumFlickVelocity = 4000
