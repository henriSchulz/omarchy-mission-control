import QtQuick
import qs.Commons
import qs.Ui
import "Motion.js" as Motion

// Material for menus, popovers, panels, toasts: theme background, hairline,
// radius by role. Put it inside HUi.Reveal; children go into the content area.
//
//   HUi.Surface { role: "popups"; kind: "popover"; padding: Style.spacing.popupPadding; … }
BorderSurface {
  id: root

  property string role: "popups"      // popups | menu | tooltip | notifications (Color.<role>)
  property string kind: "popover"     // panel | popover | menu | chip → radius
  readonly property var palette: Color[role] || Color.popups

  color: palette.background
  radius: Style.space(kind === "panel" ? Motion.radiusPanel
    : kind === "chip" ? Motion.radiusChip : Motion.radiusPopover)
  borderSpec: Border.surfaceSpec(role, "border",
    Util.alpha(Color.foreground, Motion.hairlineAlpha), 1)
}
