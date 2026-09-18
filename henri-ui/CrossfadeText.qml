import QtQuick
import qs.Commons
import "Motion.js" as Motion

// Text whose changes crossfade instead of snapping (numbers, clock, status,
// titles). Two layers: the new text fades in while the old fades out.
//
//   HUi.CrossfadeText { text: volume + " %"; color: Color.foreground }
Item {
  id: root

  property string text: ""
  property color color: Color.foreground
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.body
  property int fontWeight: Font.Normal
  property int horizontalAlignment: Text.AlignLeft
  property int elide: Text.ElideNone

  property bool _aFront: true
  readonly property Text front: _aFront ? a : b

  implicitWidth: front.implicitWidth
  implicitHeight: front.implicitHeight

  onTextChanged: {
    if (_aFront) b.text = text
    else a.text = text
    _aFront = !_aFront
  }
  Component.onCompleted: a.text = text

  component Layer: Text {
    width: root.width
    horizontalAlignment: root.horizontalAlignment
    elide: root.elide
    textFormat: Text.PlainText
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.weight: root.fontWeight
    Behavior on opacity {
      NumberAnimation { duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
    }
  }

  Layer { id: a; opacity: root._aFront ? 1 : 0 }
  Layer { id: b; opacity: root._aFront ? 0 : 1 }
}
