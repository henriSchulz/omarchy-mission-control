import QtQuick
import qs.Commons
import "Motion.js" as Motion

// macOS switch: knob glides with the snappy spring and stretches while pressed,
// track color crossfades. Click, Space or Enter toggles.
//
//   HUi.Toggle { checked: wifi.on; onToggled: (on) => wifi.set(on) }
Item {
  id: root

  property bool checked: false
  signal toggled(bool checked)

  readonly property real gap: Style.space(2)
  readonly property real knobBase: height - gap * 2

  implicitWidth: Style.space(36)
  implicitHeight: Style.space(20)
  activeFocusOnTab: enabled
  opacity: enabled ? 1 : Motion.disabledOpacity

  function flip() { checked = !checked; toggled(checked) }

  Rectangle {
    id: track
    anchors.fill: parent
    radius: height / 2
    color: root.checked ? Color.accent
      : Util.alpha(Color.foreground, hover.hovered ? 0.24 : 0.18)
    Behavior on color { ColorAnimation { duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut } }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -Style.space(Motion.focusRing)
    radius: height / 2
    color: "transparent"
    border.width: Style.space(Motion.focusRing)
    border.color: Util.alpha(Color.accent, 0.6)
    opacity: root.activeFocus ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
  }

  Rectangle {
    id: knob
    width: kw.value
    height: root.knobBase
    radius: height / 2
    y: root.gap
    x: root.gap + kp.value * (root.width - root.gap * 2 - width)
    color: "#ffffff"
    border.width: 0.5
    border.color: Qt.rgba(0, 0, 0, 0.12)
  }

  SpringValue { id: kp; preset: Motion.snappy; to: root.checked ? 1 : 0 }
  SpringValue {
    id: kw
    preset: Motion.snappy
    epsilon: 0.1
    to: root.knobBase * (tap.pressed && !Motion.reduceMotion ? 1.25 : 1)
  }
  Component.onCompleted: { kp.snap(checked ? 1 : 0); kw.snap(knobBase) }

  HoverHandler { id: hover; enabled: root.enabled; cursorShape: Qt.PointingHandCursor }
  TapHandler { id: tap; enabled: root.enabled; onTapped: root.flip() }
  Keys.onPressed: function(e) {
    if (e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.flip(); e.accepted = true }
  }
}
