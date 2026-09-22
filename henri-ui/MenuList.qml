import QtQuick
import qs.Commons
import "Motion.js" as Motion

// macOS menu body: instant highlight (like NSMenu, no glide), pointer +
// keyboard (↑ ↓ Home End ⏎), separators, shortcuts, disabled/destructive
// entries, and the NSMenu blink on activation before `activated` fires.
// Put it in HUi.Surface inside HUi.Reveal and close the Reveal in onActivated;
// Esc is not handled here — it bubbles up to HUi.Reveal (dismissRequested).
//
//   HUi.MenuList {
//     model: [ { text: "Neu", icon: "󰐕", shortcut: "⌘N" }, { separator: true },
//              { text: "Löschen", danger: true } ]
//     // `checked` on any entry adds NSMenu's state column: ✓ in front of the
//     // checked ones, the other labels stay aligned.
//     onActivated: (index, entry) => { menu.open = false; run(entry) }
//   }
FocusScope {
  id: root

  property var model: []
  property int currentIndex: -1
  property int minWidth: Style.space(180)
  property string fontFamily: Style.font.menuFamily || Style.font.family
  property bool flashing: false

  signal activated(int index, var entry)

  readonly property bool hasCheckColumn: {
    for (var i = 0; i < model.length; i++) if (model[i] && model[i].checked !== undefined) return true
    return false
  }

  implicitWidth: Math.max(minWidth, col.rowsWidth)
  implicitHeight: col.implicitHeight

  function entry(i) { return i >= 0 && i < model.length ? model[i] : null }
  function selectable(i) {
    var e = entry(i)
    return e !== null && !e.separator && e.enabled !== false
  }
  function move(step) {
    var n = model.length
    if (n === 0) return
    var i = currentIndex
    for (var k = 0; k < n; k++) {
      i = (i + step + n) % n
      if (selectable(i)) { currentIndex = i; return }
    }
  }
  function activate(i) {
    if (flashing || !selectable(i)) return
    currentIndex = i
    flashing = true
    flash.restart()
  }

  // NSMenu blink: highlight off → on → fire.
  SequentialAnimation {
    id: flash
    ScriptAction { script: hl.suppressed = true }
    PauseAnimation { duration: Motion.flashDuration }
    ScriptAction { script: hl.suppressed = false }
    PauseAnimation { duration: Motion.flashDuration }
    ScriptAction {
      script: {
        root.flashing = false
        root.activated(root.currentIndex, root.entry(root.currentIndex))
      }
    }
  }

  Keys.onUpPressed: move(-1)
  Keys.onDownPressed: move(1)
  Keys.onPressed: function(e) {
    if (e.key === Qt.Key_Home) { currentIndex = -1; move(1); e.accepted = true }
    else if (e.key === Qt.Key_End) { currentIndex = 0; move(-1); e.accepted = true }
    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { activate(currentIndex); e.accepted = true }
  }

  HoverHandler {
    id: listHover
    onHoveredChanged: if (!hovered && !root.flashing) root.currentIndex = -1
  }

  Highlight {
    id: hl
    glide: false
    color: Color.menu.selectedBackground     // theme-authored (cupertino: blue)
    target: root.currentIndex >= 0 ? rep.itemAt(root.currentIndex) : null
  }

  Column {
    id: col
    width: root.width
    // Widest row, so shortcuts never collide with labels.
    readonly property real rowsWidth: {
      var w = 0
      for (var i = 0; i < rep.count; i++) { var it = rep.itemAt(i); if (it) w = Math.max(w, it.implicitWidth) }
      return w
    }

    Repeater {
      id: rep
      model: root.model

      delegate: Item {
        id: row
        required property int index
        required property var modelData
        readonly property bool isSeparator: modelData.separator === true
        readonly property bool isCurrent: root.currentIndex === index && !hl.suppressed
        readonly property color textColor: isCurrent ? Color.menu.selectedText
          : modelData.danger ? Color.urgent : Color.menu.text

        width: col.width
        height: isSeparator ? Style.space(9) : Style.space(Motion.menuItemHeight)
        opacity: modelData.enabled === false ? Motion.disabledOpacity : 1
        implicitWidth: isSeparator ? 0 : content.implicitWidth + Style.spacing.xl * 2
          + (shortcutLabel.visible ? shortcutLabel.implicitWidth + Style.space(24) : 0)

        Rectangle {
          visible: row.isSeparator
          anchors.verticalCenter: parent.verticalCenter
          x: Style.spacing.lg
          width: parent.width - Style.spacing.lg * 2
          height: 1
          color: Util.alpha(Color.foreground, Motion.hairlineAlpha)
        }

        Row {
          id: content
          visible: !row.isSeparator
          anchors.verticalCenter: parent.verticalCenter
          x: Style.spacing.xl
          spacing: Style.spacing.lg

          Text {
            visible: root.hasCheckColumn
            width: Style.space(10)
            horizontalAlignment: Text.AlignHCenter
            text: row.modelData.checked === true ? "✓" : ""
            color: row.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            visible: !!row.modelData.icon
            text: row.modelData.icon || ""
            color: row.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.icon
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: row.modelData.text || ""
            color: row.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          id: shortcutLabel
          visible: !row.isSeparator && !!row.modelData.shortcut
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xl
          anchors.verticalCenter: parent.verticalCenter
          text: row.modelData.shortcut || ""
          color: row.isCurrent ? Color.menu.selectedText : Util.alpha(Color.menu.text, Motion.secondaryTextAlpha)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        HoverHandler {
          enabled: !row.isSeparator && !root.flashing
          onHoveredChanged: if (hovered && root.selectable(row.index)) root.currentIndex = row.index
        }
        TapHandler {
          enabled: !row.isSeparator
          onTapped: root.activate(row.index)
        }
      }
    }
  }
}
