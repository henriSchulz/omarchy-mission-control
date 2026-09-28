pragma Singleton
import QtQuick
import Quickshell

// Motion tokens for Mission Control: the one place a duration, curve or
// distance is written down (docs/ANIMATION-SPEC.md). Nothing else in the
// plugin carries a number for any of these.
QtObject {
  // MC_REDUCED_MOTION=1: no translate or scale anywhere, only `instant` fades.
  readonly property bool reduced: String(Quickshell.env("MC_REDUCED_MOTION") || "") === "1"

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
