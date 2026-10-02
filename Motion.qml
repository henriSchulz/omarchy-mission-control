pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Motion tokens for Mission Control: the one place a duration, curve or
// distance is written down (docs/ANIMATION-SPEC.md). Nothing else in the
// plugin carries a number for any of these.
QtObject {
  // Reduced motion: no translate or scale anywhere, only `instant` fades. On
  // when MC_REDUCED_MOTION=1 is in the environment, or when the system-wide
  // switch (System Settings > Accessibility > Reduce motion) is on: that one
  // lives in henri-ui's Prefs.js (`var reduceMotion = true`), read here as a
  // plain file -- nothing of henri-ui is imported. MC_REDUCED_MOTION=0 forces
  // it off for testing.
  readonly property string envReduced: String(Quickshell.env("MC_REDUCED_MOTION") || "")
  // text() blocks on the first read (blockLoading), so the very first open
  // already knows; it is reactive, so a change on disk flips it live.
  readonly property bool systemReduced: /^\s*var\s+reduceMotion\s*=\s*true\b/m.test(prefs.text() || "")
  readonly property bool reduced: envReduced === "1" || (envReduced !== "0" && systemReduced)

  readonly property FileView prefs: FileView {
    path: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/henri-ui/Prefs.js"
    blockLoading: true      // known before the first open
    watchChanges: true
    printErrors: false      // no henri-ui on this machine: just the env switch
    onFileChanged: reload()
  }

  // Durations (ms)
  readonly property int instant: 80   // hover, pressed, colour change
  readonly property int fast: 140     // focus change, small elements in/out, closing
  readonly property int base: 200     // tiles, panels, list rows in
  readonly property int slow: 260     // the overview opening, big surfaces
  readonly property int staggerStep: 20
  readonly property int staggerMax: 120

  // Curves, for easing.type: Easing.BezierSpline (Qt wants the 1,1 end point).
  readonly property var easeOut: [0.23, 1, 0.32, 1, 1, 1]      // appears, moves
  readonly property var easeIn: [0.4, 0, 1, 1, 1, 1]           // disappears
  readonly property var easeInOut: [0.65, 0, 0.35, 1, 1, 1]    // travels A -> B

  // Rate (1/s) of a critically damped spring -- the only spring the spec
  // allows, it cannot swing past its target -- that is 99 % home `ms` after
  // starting from rest: (1 + wt) e^-wt = 0.01 at wt = 6.64. For a released
  // swipe, whose speed a fixed curve cannot take over.
  function springRate(ms) { return 6640 / Math.max(1, ms) }

  // Distances (px) and scales
  readonly property int distanceSm: 4
  readonly property int distanceMd: 8
  readonly property int distanceLg: 16
  readonly property real scaleEnter: 0.96
  readonly property real scaleExit: 0.98
  readonly property real scaleHover: 1.02
  readonly property int hoverLift: 2

  // Reduced motion: every fade is `instant`, every move snaps, every scale is 1.
  function d(ms) { return reduced ? instant : ms }
  function travel(ms) { return reduced ? 0 : ms }
  function px(v) { return reduced ? 0 : v }
  function sc(v) { return reduced ? 1 : v }
  // Offset of the i-th element in reading order; from the 7th on, all at once.
  function stagger(i) { return reduced ? 0 : Math.min(Math.max(0, i) * staggerStep, staggerMax) }
}
