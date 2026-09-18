import QtQuick
import qs.Commons
import "Motion.js" as Motion

// One selection shape for a group of items. glide: true (tabs, segmented
// controls, sidebars) slides it between items; glide: false (menus, lists
// navigated by hover) jumps instantly, like NSMenu.
// It must share its parent's coordinate space with the targets (sibling of
// the items, or placed at 0,0 over the Column/Row that holds them).
//
//   HUi.Highlight { target: list.currentItem }
Rectangle {
  id: root

  property Item target: null
  property real inset: 0
  property bool suppressed: false      // e.g. blink off during a menu flash
  property bool glide: true

  color: Color.accent
  radius: Style.space(Motion.radiusRow)
  // glide: false binds straight to the target — no spring frame in between.
  readonly property bool _direct: !glide && target !== null
  x: _direct ? target.x + inset : sx.value
  y: _direct ? target.y + inset : sy.value
  width: _direct ? target.width - inset * 2 : sw.value
  height: _direct ? target.height - inset * 2 : sh.value
  opacity: target && !suppressed ? 1 : 0
  Behavior on opacity {
    enabled: root.glide && !root.suppressed
    NumberAnimation { duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
  }

  SpringValue { id: sx; epsilon: 0.3; to: root.target ? root.target.x + root.inset : root.x }
  SpringValue { id: sy; epsilon: 0.3; to: root.target ? root.target.y + root.inset : root.y }
  SpringValue { id: sw; epsilon: 0.3; to: root.target ? root.target.width - root.inset * 2 : root.width }
  SpringValue { id: sh; epsilon: 0.3; to: root.target ? root.target.height - root.inset * 2 : root.height }

  // Appearing from nothing: start at the target instead of flying in from 0,0.
  property Item _previous: null
  onTargetChanged: {
    if (target && (!glide || !_previous || opacity < 0.05)) {
      sx.snap(target.x + inset); sy.snap(target.y + inset)
      sw.snap(target.width - inset * 2); sh.snap(target.height - inset * 2)
    }
    _previous = target
  }
}
