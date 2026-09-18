import QtQuick
import qs.Commons
import "Motion.js" as Motion

// Base of everything clickable: hover/press fill, press scale with spring
// release, disabled fade, keyboard focus ring, Space/Enter activation.
// Put label/icon children inside; they fill the item.
//
//   HUi.Pressable { onClicked: …; Text { anchors.centerIn: parent; text: "Hi" } }
Item {
  id: root

  property color tint: Color.foreground        // hover/press fills are this color at low alpha
  property bool prominent: false               // accent-filled (primary action)
  property bool selected: false                // accent fill, e.g. current menu entry
  property bool showFill: true                 // false: highlight comes from elsewhere (HUi.Highlight)
  property bool pressScaleEnabled: true
  property real radius: Style.space(Motion.radiusControl)
  property int cursorShape: Qt.PointingHandCursor

  readonly property bool hovered: hover.hovered
  readonly property bool pressed: tap.pressed || keyPressed
  property bool keyPressed: false
  readonly property color contentColor: (prominent || selected) ? Motion.onColor(Color.accent) : tint

  signal clicked()
  signal secondaryClicked()

  default property alias content: contentItem.data

  activeFocusOnTab: enabled
  opacity: enabled ? 1 : Motion.disabledOpacity
  scale: pressS.value
  Behavior on opacity { NumberAnimation { duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut } }

  function fillColor() {
    if (prominent || selected) {
      var a = Color.accent
      return pressed ? Qt.darker(a, 1.12) : hovered && prominent ? Qt.lighter(a, 1.08) : a
    }
    if (!showFill) return Util.alpha(tint, 0)
    // Same hue at alpha 0 when idle, so the fade never passes through black.
    return Util.alpha(tint, pressed ? Motion.pressedAlpha : hovered ? Motion.hoverAlpha : 0)
  }

  Rectangle {
    id: fill
    anchors.fill: parent
    radius: root.radius
    color: root.fillColor()
    Behavior on color {
      ColorAnimation {
        duration: (root.hovered || root.pressed) ? Motion.instant : Motion.fast
        easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
      }
    }
  }

  // Keyboard focus ring, only for keyboard focus (not after a mouse click).
  Rectangle {
    anchors.fill: parent
    anchors.margins: -Style.space(Motion.focusRing)
    radius: root.radius + Style.space(Motion.focusRing)
    color: "transparent"
    border.width: Style.space(Motion.focusRing)
    border.color: Util.alpha(Color.accent, 0.6)
    opacity: root.activeFocus && root.focusReason !== Qt.MouseFocusReason ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
  }
  property int focusReason: Qt.OtherFocusReason
  onActiveFocusChanged: if (!activeFocus) focusReason = Qt.OtherFocusReason

  Item { id: contentItem; anchors.fill: parent }

  SpringValue {
    id: pressS
    preset: Motion.snappy
    to: root.pressed && root.pressScaleEnabled && !Motion.reduceMotion ? Motion.pressScale : 1
  }

  HoverHandler { id: hover; enabled: root.enabled; cursorShape: root.cursorShape }
  TapHandler {
    id: tap
    enabled: root.enabled
    acceptedButtons: Qt.LeftButton
    onPressedChanged: if (pressed) root.focusReason = Qt.MouseFocusReason
    onTapped: root.clicked()
  }
  TapHandler {
    enabled: root.enabled
    acceptedButtons: Qt.RightButton
    onTapped: root.secondaryClicked()
  }

  Keys.onPressed: function(e) {
    if (e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
      if (!e.isAutoRepeat) root.keyPressed = true
      e.accepted = true
    }
  }
  Keys.onReleased: function(e) {
    if ((e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !e.isAutoRepeat) {
      root.keyPressed = false
      root.clicked()
      e.accepted = true
    }
  }
}
