import QtQuick
import qs.Commons
import "Motion.js" as Motion

// Header of a drill-in page (HUi.PageStack): back chevron + title. The whole
// left part is the back target; the chevron nudges left on hover, like the
// macOS Control Center. Trailing controls (a switch, a value) go inside as
// children and are laid out on the right.
//
//   HUi.PageHeader { title: "Battery history"; onBack: pages.pop() }
Item {
  id: root

  property string title: ""
  property color ink: Color.popups.text
  property string iconFont: Style.font.family
  signal back()

  default property alias trailing: trailingRow.data

  implicitHeight: Style.space(36)

  Pressable {
    id: backArea
    // The hover fill reaches a little past the chevron, like a macOS row.
    x: -Style.space(6)
    width: titleRow.implicitWidth + Style.space(18)
    height: Style.space(Motion.controlHeight)
    anchors.verticalCenter: parent.verticalCenter
    radius: Style.space(Motion.radiusRow)
    tint: root.ink
    pressScaleEnabled: false
    activeFocusOnTab: false
    Accessible.name: "Back"
    onClicked: root.back()

    Row {
      id: titleRow
      x: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰅁"
        color: root.ink
        font.family: root.iconFont
        font.pixelSize: Style.font.iconLarge
        transform: Translate {
          x: backArea.hovered && !Motion.reduceMotion ? -Style.space(3) : 0
          Behavior on x {
            NumberAnimation {
              duration: backArea.hovered ? Motion.instant : Motion.fast
              easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
            }
          }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        color: root.ink
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.weight: Font.DemiBold
      }
    }
  }

  Row {
    id: trailingRow
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)
  }
}
