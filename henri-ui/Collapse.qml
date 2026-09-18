import QtQuick
import "Motion.js" as Motion

// Height follows content with the smooth spring, clipped; content fades.
// Use for expandable sections AND for panels whose content changes size
// (keep expanded: true — the height then glides to every new size).
//
//   HUi.Collapse { expanded: showDetails; width: parent.width; Column { … } }
Item {
  id: root

  property bool expanded: true
  default property alias content: inner.data

  readonly property real contentHeight: inner.childrenRect.height

  clip: true
  implicitWidth: inner.childrenRect.width
  implicitHeight: hs.value
  visible: expanded || hs.value > 0.5

  SpringValue { id: hs; epsilon: 0.3; to: root.expanded ? root.contentHeight : 0 }
  Component.onCompleted: snap()

  // Jump to the current state without animating — e.g. resetting a section
  // while its popup is hidden, so it does not animate on the next open.
  function snap() { hs.snap(expanded ? contentHeight : 0) }

  Item {
    id: inner
    width: root.width
    height: root.contentHeight
    opacity: root.expanded ? 1 : 0
    Behavior on opacity {
      NumberAnimation {
        duration: root.expanded ? Motion.base : Motion.exit(Motion.fast)
        easing.type: Easing.BezierSpline
        easing.bezierCurve: root.expanded ? Motion.easeOut : Motion.easeExit
      }
    }
  }
}
