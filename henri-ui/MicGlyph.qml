import QtQuick
import qs.Commons
import "Motion.js" as Motion

// Microphone glyph, rebuilt from SF Symbols' `mic.fill` proportions rather
// than shipped as a font glyph -- the same reason HUi.BatteryGlyph is drawn:
// Apple's symbol files may not be redistributed, so the geometry is rebuilt.
// Capsule, an arc that is the bottom half of a stroked circle, and a stem.
//
//   HUi.MicGlyph { height: Style.space(20); ink: Color.accent; live: listening }
Item {
  id: root

  property color ink: Color.accent
  /// Dimmed when false, so one glyph carries "armed" and "idle" without a
  /// second icon to crossfade to.
  property bool live: true

  readonly property real s: height
  readonly property real stroke: Math.max(1.5, s * 0.095)

  implicitHeight: Style.space(20)
  implicitWidth: s
  width: implicitWidth

  opacity: root.live ? 1 : Motion.disabledOpacity
  Behavior on opacity {
    NumberAnimation {
      duration: Motion.fast
      easing.type: Easing.BezierSpline
      easing.bezierCurve: Motion.easeOut
    }
  }

  Rectangle {                                // capsule
    width: root.s * 0.34
    height: root.s * 0.5
    radius: width / 2
    x: (root.s - width) / 2
    y: root.s * 0.06
    color: root.ink
    antialiasing: true
  }

  Item {                                     // arc: lower half of a stroked circle
    width: root.s * 0.64
    height: root.s * 0.32
    x: (root.s - width) / 2
    y: root.s * 0.44
    clip: true
    Rectangle {
      width: parent.width
      height: parent.width
      y: -parent.width / 2
      radius: width / 2
      color: "transparent"
      border.width: root.stroke
      border.color: root.ink
      antialiasing: true
    }
  }

  Rectangle {                                // stem
    width: root.stroke
    height: root.s * 0.16
    radius: width / 2
    x: (root.s - width) / 2
    y: root.s * 0.76
    color: root.ink
    antialiasing: true
  }
}
