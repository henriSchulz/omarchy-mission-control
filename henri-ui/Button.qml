import QtQuick
import qs.Commons
import "Motion.js" as Motion

// Standard button. Glyph icons use the theme font (like the rest of the shell).
//
//   HUi.Button { text: "Speichern"; prominent: true; onClicked: … }
//   HUi.Button { icon: "󰐥"; onClicked: … }            // icon-only → square
Pressable {
  id: root

  property string text: ""
  property string icon: ""
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.body

  readonly property bool iconOnly: text === "" && icon !== ""

  implicitHeight: Style.space(Motion.controlHeight)
  implicitWidth: iconOnly ? implicitHeight : row.implicitWidth + Style.spacing.controlPaddingX * 2

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.spacing.md

    Text {
      visible: root.icon !== ""
      text: root.icon
      color: root.contentColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      anchors.verticalCenter: parent.verticalCenter
      Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
    Text {
      visible: root.text !== ""
      text: root.text
      color: root.contentColor
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      font.weight: root.prominent ? Font.DemiBold : Font.Medium
      anchors.verticalCenter: parent.verticalCenter
      Behavior on color { ColorAnimation { duration: Motion.fast } }
    }
  }
}
