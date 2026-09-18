import QtQuick
import QtQuick.Controls
import "Motion.js" as Motion

// Drill-in navigation (Control Center style): the new page slides in from the
// right, the old one moves 30 % left and fades (parallax); back mirrors it.
// Height glides to each page's implicitHeight. Esc/← = back.
//
//   HUi.PageStack { id: pages; width: parent.width; initialItem: mainPage }
//   pages.push(wifiPage) … pages.pop()
StackView {
  id: root

  readonly property real parallax: Motion.reduceMotion ? 0 : width * Motion.pageParallax
  readonly property real travel: Motion.reduceMotion ? 0 : width

  clip: true
  implicitHeight: hs.value

  // Esc / ← go back one page; on the first page Esc falls through to the
  // surrounding HUi.Reveal, which closes the surface.
  Keys.onPressed: function(e) {
    if ((e.key === Qt.Key_Escape || e.key === Qt.Key_Left || e.key === Qt.Key_Back) && root.depth > 1) {
      root.pop()
      e.accepted = true
    }
  }
  SpringValue { id: hs; epsilon: 0.3; to: root.currentItem ? root.currentItem.implicitHeight : 0 }

  component Move: NumberAnimation {
    property: "x"
    duration: Motion.slow
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.easeInOut
  }
  component Fade: NumberAnimation {
    property: "opacity"
    duration: Motion.slow
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.easeInOut
  }

  pushEnter: Transition { Move { from: root.travel; to: 0 } Fade { from: 0; to: 1 } }
  pushExit: Transition { Move { from: 0; to: -root.parallax } Fade { from: 1; to: 0 } }
  popEnter: Transition { Move { from: -root.parallax; to: 0 } Fade { from: 0; to: 1 } }
  popExit: Transition { Move { from: 0; to: root.travel } Fade { from: 1; to: 0 } }
  replaceEnter: Transition { Fade { from: 0; to: 1 } }
  replaceExit: Transition { Fade { from: 1; to: 0 } }
}
