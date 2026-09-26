import QtQuick
import qs.Commons
import "Motion.js" as Motion

// Live audio waveform: a row of bars fed by a ring buffer of 0…1 levels,
// oldest first. The bars never move and are never re-laid out -- each one
// renders at full height and is squeezed by a Scale transform, so a scrolling
// waveform costs one property write per bar instead of a relayout per frame.
//
// Feed it by replacing `levels` with a new array (in-place edits do not
// notify). Push one value per visual tick, not one per audio frame: a daemon
// sending ~95 frames/s would scroll far faster than anything reads.
//
//   HUi.Waveform { levels: root.levels; barCount: 34; live: listening }
//
// `working` swaps the level-driven look for a settled line with a sweep
// travelling along it -- "busy" without a spinner. Drive `sweep` 0…1 from a
// NumberAnimation in the consumer, so one animated number lights every bar.
Item {
  id: root

  property var levels: []
  property int barCount: 34
  property real barWidth: Style.space(3)
  property color ink: Color.accent

  /// Bars follow `levels`. False settles them to a flat line.
  property bool live: false
  /// Flat line with a travelling highlight instead of levels.
  property bool working: false
  property real sweep: 0
  /// How far either side of `sweep` a bar still lights, as a fraction of the
  /// whole row.
  property real sweepReach: 0.22

  implicitHeight: Style.space(26)
  readonly property real floorScale: barWidth / Math.max(1, height)

  Row {
    id: row
    anchors.fill: parent
    spacing: (width - root.barWidth * root.barCount) / Math.max(1, root.barCount - 1)

    Repeater {
      model: root.barCount

      Rectangle {
        id: bar
        required property int index

        readonly property real level: root.levels[index] || 0
        readonly property real target: root.live
          ? Math.max(root.floorScale, level)
          : root.floorScale

        // Distance from the travelling sweep, 0 at its centre.
        readonly property real reach: Math.abs(index / Math.max(1, root.barCount - 1) - root.sweep)
        readonly property real glow: Math.max(0, 1 - reach / root.sweepReach)

        width: root.barWidth
        height: root.height
        radius: width / 2
        color: root.ink
        antialiasing: true

        opacity: Motion.disabledOpacity + (1 - Motion.disabledOpacity)
          * (root.working ? glow : Math.min(1, level * 2))
        Behavior on opacity {
          NumberAnimation {
            duration: Motion.instant
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Motion.easeOut
          }
        }

        transform: Scale {
          origin.x: root.barWidth / 2
          origin.y: root.height / 2
          xScale: 1
          yScale: bar.target
          // A feeding tick is shorter than `instant`, so a bar is always still
          // travelling when its next value lands: the steps smooth into one
          // continuous movement instead of stepping once per tick.
          Behavior on yScale {
            NumberAnimation {
              duration: Motion.instant
              easing.type: Easing.BezierSpline
              easing.bezierCurve: Motion.easeOut
            }
          }
        }
      }
    }
  }
}
