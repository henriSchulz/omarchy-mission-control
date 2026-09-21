import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import "Motion.js" as Motion

// macOS menu-bar battery (SF Symbols `battery.100` family), redrawn as vectors —
// Apple's symbol files may not be redistributed, so the geometry is rebuilt
// from the originals' proportions:
//   · faint outline (ink @ 0.4), solid fill that follows the charge level
//   · terminal nub on the right
//   · charging → bolt, plugged in but not charging (full / charge limit) → plug;
//     the glyph is knocked out of the fill like the original
//   · discharging at ≤ 20 % → fill turns red
//
//   HUi.BatteryGlyph { level: 0.84; charging: true; height: 12 }
Item {
  id: root

  property real level: 1                 // 0 … 1
  property bool charging: false          // bolt
  property bool plugged: false           // plug (on AC, not charging)
  property bool lowWarning: !charging && !plugged && level <= 0.2
  property color ink: Color.foreground
  property color lowColor: Color.urgent

  // Proportions of the original at 12 pt: body 23 × 11.5, nub 1.5 × 4.
  readonly property real bodyH: height
  readonly property real bodyW: Math.round(bodyH * 2.0)
  readonly property real stroke: Math.max(1, bodyH / 11.5)
  readonly property real nubW: Math.max(1.2, bodyH * 0.13)
  readonly property real nubGap: stroke * 0.8
  readonly property real inset: stroke * 2      // fill sits one hairline inside the outline
  readonly property string mark: charging ? "bolt" : (plugged ? "plug" : "")

  implicitHeight: 12
  implicitWidth: bodyW + nubGap + nubW
  width: implicitWidth

  // ── Outline + nub ──────────────────────────────────────────────────────
  Rectangle {
    width: root.bodyW; height: root.bodyH
    radius: root.bodyH * 0.3
    color: "transparent"
    border.width: root.stroke
    border.color: Qt.alpha(root.ink, 0.4)
    antialiasing: true
  }
  Rectangle {
    x: root.bodyW + root.nubGap
    anchors.verticalCenter: parent.verticalCenter
    width: root.nubW; height: root.bodyH * 0.36
    topRightRadius: root.nubW; bottomRightRadius: root.nubW
    color: Qt.alpha(root.ink, 0.4)
    antialiasing: true
  }

  // ── Fill (level), with the charge mark knocked out ─────────────────────
  Item {
    id: fillLayer
    x: root.inset; y: root.inset
    width: root.bodyW - root.inset * 2
    height: root.bodyH - root.inset * 2
    visible: false
    layer.enabled: true

    Rectangle {
      height: parent.height
      width: Math.max(root.level > 0 ? height * 0.6 : 0, parent.width * Math.max(0, Math.min(1, root.level)))
      radius: root.bodyH * 0.16
      color: root.lowWarning ? root.lowColor : root.ink
      antialiasing: true
      Behavior on width { NumberAnimation { duration: Motion.base; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut } }
      Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
  }

  // Mask: the charge mark, grown by a hairline so a gap separates it from the fill.
  Item {
    id: knockout
    anchors.fill: fillLayer
    visible: false
    layer.enabled: true
    Loader {
      x: markBox.x - fillLayer.x; y: markBox.y - fillLayer.y
      width: markBox.width; height: markBox.height
      sourceComponent: root.mark === "" ? null : markShape
      onLoaded: { item.fillColor = "black"; item.strokeColor = "black"; item.strokeW = root.stroke * 2.4 }
    }
  }

  MultiEffect {
    source: fillLayer
    anchors.fill: fillLayer
    maskEnabled: root.mark !== ""
    maskInverted: true
    maskSource: knockout
    maskThresholdMin: 0.4
    maskSpreadAtMin: 0.3
  }

  // ── Charge mark on top ─────────────────────────────────────────────────
  Item {
    id: markBox
    readonly property bool isPlug: root.mark === "plug"
    width: isPlug ? root.bodyH * 1.2 : root.bodyH * 0.56
    height: isPlug ? root.bodyH * 0.72 : root.bodyH * 0.9
    x: (root.bodyW - width) / 2
    y: (root.bodyH - height) / 2
    opacity: root.mark === "" ? 0 : 1
    scale: root.mark === "" ? Motion.iconFromScale : 1
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut } }

    Loader {
      id: markLoader
      anchors.fill: parent
      sourceComponent: markShape
      onLoaded: { item.fillColor = Qt.binding(function() { return root.ink }); item.strokeColor = "transparent"; item.strokeW = 0 }
    }
  }

  Component {
    id: markShape
    Shape {
      id: s
      property color fillColor: "black"
      property color strokeColor: "transparent"
      property real strokeW: 0
      readonly property bool plug: root.mark === "plug"
      readonly property real w: width
      readonly property real h: height
      preferredRendererType: Shape.CurveRenderer

      // SF `bolt.fill`
      ShapePath {
        fillColor: s.plug ? "transparent" : s.fillColor
        strokeColor: s.plug ? "transparent" : s.strokeColor
        strokeWidth: s.strokeW
        joinStyle: ShapePath.RoundJoin
        startX: s.w * 0.64; startY: 0
        PathLine { x: s.w * 0.02; y: s.h * 0.58 }
        PathLine { x: s.w * 0.46; y: s.h * 0.58 }
        PathLine { x: s.w * 0.36; y: s.h }
        PathLine { x: s.w * 0.98; y: s.h * 0.42 }
        PathLine { x: s.w * 0.54; y: s.h * 0.42 }
        PathLine { x: s.w * 0.64; y: 0 }
      }
      // SF `powerplug.fill`, lying down: cord ─ body ═ prongs
      ShapePath {
        fillColor: s.plug ? s.fillColor : "transparent"
        strokeColor: s.plug ? s.strokeColor : "transparent"
        strokeWidth: s.strokeW
        joinStyle: ShapePath.RoundJoin
        // cord
        startX: 0; startY: s.h * 0.42
        PathLine { x: s.w * 0.3; y: s.h * 0.42 }
        PathLine { x: s.w * 0.3; y: s.h * 0.08 }
        PathArc { x: s.w * 0.38; y: 0; radiusX: s.w * 0.08; radiusY: s.h * 0.08 }
        PathLine { x: s.w * 0.62; y: 0 }
        PathArc { x: s.w * 0.7; y: s.h * 0.12; radiusX: s.w * 0.08; radiusY: s.h * 0.12 }
        // upper prong
        PathLine { x: s.w * 0.7; y: s.h * 0.2 }
        PathLine { x: s.w; y: s.h * 0.2 }
        PathLine { x: s.w; y: s.h * 0.36 }
        PathLine { x: s.w * 0.7; y: s.h * 0.36 }
        // lower prong
        PathLine { x: s.w * 0.7; y: s.h * 0.64 }
        PathLine { x: s.w; y: s.h * 0.64 }
        PathLine { x: s.w; y: s.h * 0.8 }
        PathLine { x: s.w * 0.7; y: s.h * 0.8 }
        PathLine { x: s.w * 0.7; y: s.h * 0.88 }
        PathArc { x: s.w * 0.62; y: s.h; radiusX: s.w * 0.08; radiusY: s.h * 0.12 }
        PathLine { x: s.w * 0.38; y: s.h }
        PathArc { x: s.w * 0.3; y: s.h * 0.92; radiusX: s.w * 0.08; radiusY: s.h * 0.08 }
        PathLine { x: s.w * 0.3; y: s.h * 0.58 }
        PathLine { x: 0; y: s.h * 0.58 }
        PathLine { x: 0; y: s.h * 0.42 }
      }
    }
  }
}
