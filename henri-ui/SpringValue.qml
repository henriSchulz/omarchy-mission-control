import QtQuick
import "Motion.js" as Motion

// SwiftUI-style spring for QML. Shared by all plugins — never copy it:
//   import "file:///home/henri/.local/share/henri-ui" as HUi   →   HUi.SpringValue { … }
//
//   HUi.SpringValue { id: s; to: popup.open ? 1 : Motion.popoverFromScale; preset: Motion.gentle }
//   Item { scale: s.value }
//
// Retargeting mid-flight keeps the current velocity, so rapid open/close or
// hover in/out never jumps or restarts — the core of the macOS feel.
// Always pick a preset from Motion.js (smooth/snappy/gentle/bouncy) so that
// changing a preset centrally retunes every plugin.
FrameAnimation {
  id: root

  property real to: 0
  property real value: 0
  property real velocity: 0
  property var preset: Motion.smooth
  readonly property real response: preset.response
  readonly property real dampingRatio: preset.dampingRatio
  // Rest threshold in the value's own unit: ~0.5 for pixels, ~0.001 for scale/opacity.
  property real epsilon: 0.001

  // Jump to v without animating; keeps the `to` binding intact, so the spring
  // then runs from v to the current target (e.g. start an open from 0.96).
  function snap(v) {
    velocity = 0
    value = Motion.reduceMotion ? to : v
    running = value !== to
  }

  running: false
  onToChanged: {
    if (Motion.reduceMotion) { velocity = 0; value = to; running = false; return }
    if (value !== to) running = true
  }
  Component.onCompleted: value = to

  onTriggered: {
    const dt = Math.min(frameTime, 1 / 30)
    const k = Math.pow(2 * Math.PI / response, 2)
    const c = 4 * Math.PI * dampingRatio / response
    const steps = Math.max(1, Math.ceil(dt / 0.002))
    const h = dt / steps
    let x = value
    let v = velocity
    for (let i = 0; i < steps; i++) {
      v += (-k * (x - to) - c * v) * h
      x += v * h
    }
    if (Math.abs(x - to) < epsilon && Math.abs(v) < epsilon * 10) {
      value = to
      velocity = 0
      running = false
    } else {
      value = x
      velocity = v
    }
  }
}
