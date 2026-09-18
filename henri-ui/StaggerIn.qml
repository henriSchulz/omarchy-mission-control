import QtQuick
import "Motion.js" as Motion

// Content that enters one after another when a surface opens (tiles, rows).
// Enter: fade + rise 6 px, delayed by index × 15 ms (max 10 steps).
// Exit: all together and fast — never staggered.
//
//   Repeater { delegate: HUi.StaggerIn { active: reveal.open; index: model.index; Tile { … } } }
Item {
  id: root

  property bool active: false
  property int index: 0
  default property alias content: inner.data

  property bool _in: false

  implicitWidth: inner.childrenRect.width
  implicitHeight: inner.childrenRect.height

  onActiveChanged: {
    if (active) {
      if (Motion.stagger(index) === 0) _in = true
      else delay.restart()
    } else {
      delay.stop()
      _in = false
    }
  }
  Component.onCompleted: if (active) delay.restart()

  Timer { id: delay; interval: Motion.stagger(root.index); onTriggered: root._in = true }

  Item {
    id: inner
    width: root.width
    height: root.height
    opacity: root._in ? 1 : 0
    transform: Translate { y: rise.value }
    Behavior on opacity {
      NumberAnimation {
        duration: root._in ? Motion.base : Motion.exit(Motion.fast)
        easing.type: Easing.BezierSpline
        easing.bezierCurve: root._in ? Motion.easeOut : Motion.easeExit
      }
    }
  }
  SpringValue { id: rise; epsilon: 0.1; to: root._in || Motion.reduceMotion ? 0 : 6 }
  Component.onDestruction: delay.stop()
}
