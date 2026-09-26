// Mission Control -- a macOS-style workspace overview for Omarchy.
//
// A Spaces strip of live desktop thumbnails across the top, and underneath it
// the current desktop's windows shrunk down so none overlaps, each with its app
// icon and title. Click a window to go to it, click a desktop to switch to it.
//
// The open is two-phase, and that is the whole trick behind the macOS feel: the
// surface goes up with every window drawn at its real size and position -- which
// is pixel-for-pixel the desktop you were already looking at -- and only then do
// the windows shrink into the overview. The desktop appears to shrink, rather
// than a different-looking screen fading in over it. See `shown` vs `expanded`.
//
// The thumbnails are live, not stale, even for windows on workspaces you cannot
// see: Hyprland renders a toplevel into an offscreen buffer on demand for
// screencopy, so visibility does not matter.
//
// Why this is not hyprexpo: hyprexpo does a similar job inside the compositor,
// but it is a render pass, not a client -- it clears the whole monitor to
// bg_col every frame, so a transparent bg_col still paints black and nothing
// can show through from underneath, and wallpaper_bg = 1 draws Hyprland's
// built-in wallpaper, which Omarchy does not use. Owning a surface is the only
// way to get the real desktop behind the overview. Both were measured, not
// assumed -- see docs/FINDINGS.md.
//
// This is an `overlay` plugin with keepLoaded: true, which means the shell
// mounts it at startup and it stays mounted. That matters: an earlier
// standalone version launched per keypress and took ~340ms before anything
// appeared, of which ~145ms was Qt/QML starting up and ~190ms was decoding
// Omarchy's 5120x2880 wallpaper. Neither is avoidable per launch. Mounted once
// at shell startup, a toggle shows in ~80ms.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
// henri-ui ships inside this repo (henri-ui/, mirrored from Henri's central copy)
// so the public plugin works without anyone's home folder. Imported relatively.
import "henri-ui/Motion.js" as Motion
import "henri-ui" as HUi

Item {
  id: root

  // --- plugin contract --------------------------------------------------
  // Set by the shell's Loader when this plugin is mounted.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // What the user last asked for, as opposed to what is currently on screen.
  // The shell reads this to decide what `toggle` means, and it has to be the
  // intent rather than the state: the open and the close are both animated, so
  // mid-animation neither `shown` nor `expanded` answers "should this be open?"
  // correctly. An earlier version keyed the toggle on the on-screen state and
  // wedged -- a pending expand timer would fire during the close, leave
  // `expanded` true while hidden, and every later toggle read that as "already
  // open" and tried to close something already closed.
  property bool opened: false

  // --- modes ----------------------------------------------------------------
  // "mission": the Spaces strip and the current desktop's windows (F8, four
  //            fingers up).
  // "app":     App Exposé -- one app's windows from every desktop of this
  //            monitor, packed side by side, minimized ones in a smaller row
  //            underneath; no strip (SHIFT+F8, four fingers down). Tab moves
  //            on to the next app.
  // "desktop": Show Desktop -- every window slides out to the nearest screen
  //            edge, leaving a sliver, so the wallpaper is clear (CTRL+F8).
  property string mode: "mission"
  readonly property bool missionMode: root.mode === "mission"
  readonly property bool appMode: root.mode === "app"
  readonly property bool desktopMode: root.mode === "desktop"
  // App Exposé: the app id (Wayland class) being shown.
  property string appClass: ""

  // Desktops added with the strip's "+" that Hyprland has not created yet: it
  // only creates a workspace once something lands on it, so until then (and
  // again whenever one runs empty) the desktop exists only here. Kept in
  // memory on purpose -- this plugin writes no state anywhere, see README.
  // [{ id, monitor }]
  property var extraDesktops: []

  // Testing hook: with MISSION_CONTROL_TEST_SCREEN=<output> a standalone
  // instance builds its overlay on that output only and never takes the
  // keyboard, so it can be exercised on a headless output while the real shell
  // and the user's screen are untouched. Empty in the shell.
  readonly property string testScreen: String(Quickshell.env("MISSION_CONTROL_TEST_SCREEN") || "")

  function validMode(value) {
    const m = String(value || "");
    return m === "app" || m === "desktop" ? m : "mission";
  }

  // The app id of the focused window, for App Exposé; the most recently used
  // window when nothing is focused (an empty desktop, a layer had the focus).
  function activeAppClass() {
    const tls = Hyprland.toplevels.values || [];
    let best = null;
    for (let i = 0; i < tls.length; i++) {
      const t = tls[i];
      const o = t.lastIpcObject;
      if (!o || o.mapped === false || o.hidden === true)
        continue;
      if (t.activated)
        return String(o["class"] || "").slice(0, root.maxIconNameLength);
      if (!best || (o.focusHistoryID || 0) < (best.lastIpcObject.focusHistoryID || 0))
        best = t;
    }
    return best ? String(best.lastIpcObject["class"] || "").slice(0, root.maxIconNameLength) : "";
  }

  // Called by the shell on summon. The payload picks the mode:
  //   {}                        Mission Control
  //   {"mode":"app"}            App Exposé of the active app
  //   {"mode":"app","app":"…"}  App Exposé of that app id
  //   {"mode":"desktop"}        Show Desktop
  // Summoned again while up in another mode, the overview changes mode in
  // place: the windows glide to their new places instead of closing and
  // reopening.
  function open(payloadJson) {
    let payload = {};
    try { payload = JSON.parse(String(payloadJson || "{}")) || {}; } catch (e) { payload = {}; }
    const m = root.validMode(payload.mode);
    if (m === "app") {
      const wanted = String(payload.app || "").slice(0, root.maxIconNameLength);
      root.appClass = wanted.length > 0 ? wanted : root.activeAppClass();
    }
    root.mode = m;
    // The background may have changed since the last open.
    root.refreshWallpaper()
    root.setShown(true)
  }

  // Called by the shell when IT closes us (`omarchy-shell shell hide <id>`).
  // Must NOT call back into shell.hide(), or the two bounce off each other.
  function close() {
    root.setShown(false)
  }

  // The keys: the same mode again closes, another mode switches in place.
  function toggle(wanted) {
    const m = root.validMode(wanted);
    if (root.opened && root.mode === m) {
      root.dismiss();
      return;
    }
    root.summon(JSON.stringify({ mode: m }));
  }

  // Open through the shell, so its open-plugin bookkeeping matches ours.
  function summon(payloadJson) {
    if (root.shell && typeof root.shell.summon === "function")
      root.shell.summon((root.manifest && root.manifest.id) || "henri.missioncontrol", payloadJson);
    else
      root.open(payloadJson);
  }

  // Closing on our own initiative -- Escape, a click on the backdrop, picking a
  // window. Tells the shell as well, so its open-plugin bookkeeping does not go
  // on thinking we are up; without this the next `toggle` would try to hide an
  // already-hidden overview and appear to do nothing.
  function dismiss() {
    root.setShown(false)
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "henri.missioncontrol")
  }

  // --- appearance ---------------------------------------------------------
  // The labels follow the shell's menu font, so this matches the rest of
  // Omarchy and honours OMARCHY_MENU_FONT. Note it must be an explicit family:
  // the fontconfig alias `sans` resolves to whatever the user has installed,
  // which on a developer box is often a monospace whose digits look wrong once
  // they are scaled up to strip-label size.
  readonly property string fontFamily: Style.font.menuFamily

  // Omarchy keeps the active wallpaper behind a stable symlink, which is also
  // where its own background plugin reads it from. Following the link rather
  // than the theme directory means a theme switch is picked up with no reload.
  // The wallpaper is loaded through Omarchy's state symlink -- a fixed
  // pathname, and the ONLY one this plugin ever hands to an image loader. What
  // changes is a cache token appended as a query, because the link's path is
  // stable while its target moves (on a theme switch, and on a background
  // switch within a theme) and QtQuick caches images by URL. Qt strips a query
  // before opening a local file but keeps it in the cache key.
  //
  // 1.0.1 resolved the link and used the RESOLVED PATH as the source. That was
  // a regression on 1.0.0, which only ever used the fixed link: a pathname
  // something else controls should not reach an image loader, and bounding the
  // string does not bound what it points at -- the same mistake as the icon
  // lookup in section 13. Found in review of the sibling Launchpad plugin,
  // where the identical code had been copied.
  readonly property string wallpaperLink:
      Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property string wallpaperToken: ""
  readonly property string wallpaperSource:
      "file://" + root.wallpaperLink
      + (root.wallpaperToken.length > 0
         ? "?v=" + encodeURIComponent(root.wallpaperToken) : "")

  readonly property string pluginDir:
      Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  function refreshWallpaper() {
    if (!wallpaperProbe.running) {
      wallpaperProbe.running = true
      probeWatchdog.restart()
    }
  }

  Process {
    id: wallpaperProbe
    // Absolute interpreter and a minimal environment: a bare command name is
    // resolved through whatever PATH this process inherited, so a shadowed
    // executable would be run automatically by a plugin mounted for the whole
    // session.
    command: ["/bin/sh", root.pluginDir + "/bin/wallpaper-token"]
    clearEnvironment: true
    environment: ({ "HOME": Quickshell.env("HOME") })
    stdout: StdioCollector {
      onStreamFinished: root.wallpaperToken = String(text || "").trim().slice(0, 128)
    }
  }

  // A deadline. Nothing that runs automatically in a long-lived process should
  // be able to hang without one, however small it is.
  Timer {
    id: probeWatchdog
    interval: 2000
    onTriggered: if (wallpaperProbe.running) wallpaperProbe.running = false
  }

  Timer {
    running: true
    interval: 400
    onTriggered: root.refreshWallpaper()
  }

  // --- window decoration ----------------------------------------------------
  // At progress 0 each copy has to look exactly like the real window, or the
  // swipe starts with a pop: captures carry no border and no rounded corners,
  // those are drawn by Hyprland. Read them from Hyprland on each open, since a
  // theme switch changes the border colours.
  property int decoRounding: 12
  property int decoBorder: 2
  property color decoActive: "#ffd3ae78"
  property color decoInactive: "#aa595959"

  Process {
    id: decoProbe
    command: ["/usr/bin/hyprctl", "-j", "--batch",
      "getoption general:col.active_border; getoption general:col.inactive_border; getoption general:border_size; getoption decoration:rounding"]
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = String(text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i].trim();
          if (!line.startsWith("{"))
            continue;
          let o;
          try { o = JSON.parse(line); } catch (e) { continue; }
          // First colour of a gradient; the shape is checked, not trusted.
          const grad = String(o.gradient || "").split(" ")[0];
          const colour = /^[0-9a-fA-F]{8}$/.test(grad) ? "#" + grad : "";
          const num = Number(o["int"]);
          if (o.option === "general:col.active_border" && colour) root.decoActive = colour;
          else if (o.option === "general:col.inactive_border" && colour) root.decoInactive = colour;
          else if (o.option === "general:border_size" && num >= 0 && num <= 20) root.decoBorder = num;
          else if (o.option === "decoration:rounding" && num >= 0 && num <= 64) root.decoRounding = num;
        }
      }
    }
  }

  // The selection ring only appears once the user starts choosing -- arrow
  // keys, Tab or the pointer. Showing it on arrival made the first window pop
  // a white frame and grow at the end of every open, which macOS does not do.
  property bool showSelection: false

  // --- state machine ------------------------------------------------------

  // Surface up, with every window still drawn at its real size and position.
  property bool shown: false

  // Second phase: what actually shrinks the windows into the overview. This
  // cannot be folded into `shown`, because the windows have to be painted at
  // full size for at least one frame before the animation has anywhere to
  // start from.
  property bool expanded: false

  // Our last frame and the real desktop are not identical -- we draw a slight
  // dim and our captures exclude hyprbars' title bars -- so cutting the surface
  // away the instant the windows are home is a visible pop. Dissolving the last
  // stretch hides the difference: the real desktop is directly behind a
  // transparent window, so fading our content out *is* a crossfade to it.
  property bool contentVisible: false

  // The fade is applied to the whole SURFACE, by the compositor, not to the QML
  // items -- because QtQuick opacity is inherited multiplicatively by each
  // child rather than applied to the subtree as a group. Fading the items
  // individually made the dark window thumbnails become transparent at the same
  // rate as the bright wallpaper behind them, so the wallpaper peeked through
  // and the screen got BRIGHTER halfway through a fade to nothing.
  //
  // Measured off a 60fps capture of the close: mean luma ran
  // 0.148 -> 0.180 -> 0.143 over ~130ms, exactly the fade duration. That bump
  // was the flash. Compositor-side opacity composites our surface first and
  // then blends the result, which is what we actually meant.
  //
  // Fades OUT only. Showing is instant: the first frame is meant to be
  // identical to the desktop underneath, so fading it in just shows the real
  // windows and our copies at the same time -- measured off a 60fps capture,
  // that double image was the "overlapping windows" on every swipe.
  property real contentOpacity: 0
  NumberAnimation {
    id: contentFade
    target: root
    property: "contentOpacity"
    to: 0
    duration: root.fadeDuration
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.easeExit
  }
  onContentVisibleChanged: {
    if (root.contentVisible) {
      contentFade.stop();
      if (!contentFadeIn.running)
        root.contentOpacity = 1;
    } else {
      contentFadeIn.stop();
      contentFade.start();
    }
  }
  // Reduce Motion only: the way in is a crossfade too.
  NumberAnimation {
    id: contentFadeIn
    target: root
    property: "contentOpacity"
    to: 1
    duration: Motion.base
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.easeOut
  }

  // The Spaces strip slides in on open and then STAYS PUT until the surface is
  // torn down, rather than animating back out on close.
  //
  // Animating it out was a flicker: that band of screen then changed twice in
  // quick succession -- first the strip slid away and uncovered our copy of the
  // wallpaper, then the surface vanished and the same band changed again to the
  // real desktop and bar. Two transitions in one place reads as the region
  // being redrawn, which is exactly what it was. Now it leaves once, dissolved
  // together with everything else by the closing crossfade.
  //
  // The strip itself now rides on `progress`, so it follows the fingers during a
  // swipe. `stripHold` pins it in place for a close that starts from the settled
  // overview (keyboard, click, Escape) -- the case the flicker note is about. A
  // swipe down deliberately does not hold it: the strip leaving with the fingers
  // is the point there.
  property bool stripHold: false
  readonly property real stripProgress: root.stripHold ? 1 : Math.max(0, Math.min(1, root.progress))
  // Reset for the next open, once nothing is on screen to see it move.
  onShownChanged: {
    root.setSwipeMode(root.shown);
    if (root.shown)
      return;
    root.resetSlide();
    root.stripHold = false;
    progressAnim.stop();
    progressSpring.stop();
    root.springVelocity = 0;
    root.progressAnimDuration = 0;
    root.progress = 0;
  }

  // henri-ui full-screen tokens: the open (keyboard, click, backstop) runs
  // Motion.slower, the close the exit share of it -- leaving is faster than
  // arriving. Both follow Motion.speed.
  // Measured on macOS 26 (60 fps recording, missionControl.2windows in
  // ~/macos-scrape): the open takes 250 ms, the close ~165 ms -- henri-ui's
  // overview tokens. The earlier `slower` (520 ms) was twice the real thing.
  readonly property int shrinkDuration: Motion.overview
  readonly property int unshrinkDuration: Motion.overviewExit
  // Shortest animation, for finishing a nearly-done shrink.
  readonly property int shrinkMinDuration: Motion.fast
  // The closing crossfade over the tail: a short exit fade.
  readonly property int fadeDuration: Motion.exit(Motion.fast)
  // Soft start, long gentle settle: henri-ui's easeInOut (the windows move from
  // A to B, both ways). OutQuart moved the windows 18% of the way in the first
  // 5% of the time, which read as a jolt; this eases in over the first frames
  // and glides home. Deliberately not easeExit on the close: that curve ends at
  // full speed, and the windows would slam into their real rects right where
  // the copy has to be indistinguishable from the desktop.
  readonly property var shrinkCurve: Motion.easeInOut
  // The close starts fast and settles (measured: a third of the way home
  // after the first 25 ms, then easing in) -- easeOut, not the mirror of the
  // open. It still ends slowly, so the copy lands on the real window rather
  // than slamming into it.
  readonly property var unshrinkCurve: Motion.easeOut
  // Share of the duration after which the curve is ~98.8% home -- where the
  // closing crossfade starts.
  readonly property real fadeStartAt: 0.85

  // One animated number drives the whole shrink, 0 = real desktop, 1 = overview.
  // Every window, the strip and the labels derive from it, so they cannot drift
  // apart the way four independent Behaviors per window did. See shrinkCurve.
  //
  // Not a binding: during a touchpad swipe it is set directly from the fingers,
  // and otherwise animated from wherever it currently is -- so a swipe can grab
  // an animation mid-flight, and a release continues from the finger position
  // instead of restarting from 0 or 1.
  property real progress: 0
  NumberAnimation {
    id: progressAnim
    target: root
    property: "progress"
  }
  onExpandedChanged: if (!root.tracking) root.animateProgress(root.expanded ? 1 : 0)

  // Animate to `to` from the current value. Duration scales with the distance
  // left, so finishing a half-done swipe does not take as long as a full open.
  // After a swipe the release speed is matched: OutCubic starts at three times
  // its average speed, so 3 * distance / velocity continues the finger motion
  // without a visible kink.
  // How long the animation just started will take, for the close timers.
  property int progressAnimDuration: 0

  function animateProgress(to) {
    progressAnim.stop();
    // Reduce Motion: nothing shrinks or slides. The windows are already in
    // place and the surface crossfades -- see the fades in setShown.
    if (Motion.reduceMotion) {
      progressSpring.stop();
      root.springVelocity = 0;
      root.progress = to;
      root.progressAnimDuration = 0;
      return;
    }
    const dist = Math.abs(to - root.progress);
    if (dist < 0.001 && !progressSpring.running) {
      root.progress = to;
      root.progressAnimDuration = 0;
      return;
    }
    // A released swipe keeps moving on the spring that followed the fingers,
    // so position and speed carry over without a kink.
    if (root.releasing || progressSpring.running) {
      root.springTarget = to;
      // Critically damped: an initial speed towards the target above
      // omega * distance would overshoot, i.e. the windows would briefly grow
      // past full size or shrink past the overview. Cap it there.
      const toward = (to - root.progress) * root.springVelocity;
      const cap = root.springOmegaRelease * dist;
      if (toward > 0 && Math.abs(root.springVelocity) > cap)
        root.springVelocity = Math.sign(root.springVelocity) * cap;
      root.springOmega = root.springOmegaRelease;
      progressSpring.start();
      root.progressAnimDuration = root.springSettleTime();
      return;
    }
    const full = to > root.progress ? root.shrinkDuration : root.unshrinkDuration;
    const dur = Math.round(full * Math.sqrt(Math.min(1, dist)));
    progressAnim.from = root.progress;
    progressAnim.to = to;
    progressAnim.duration = Math.max(root.shrinkMinDuration, Math.min(full, dur));
    progressAnim.easing.type = Easing.BezierSpline;
    progressAnim.easing.bezierCurve = to > root.progress ? root.shrinkCurve : root.unshrinkCurve;
    root.progressAnimDuration = progressAnim.duration;
    progressAnim.start();
  }

  // --- finger follower ------------------------------------------------------
  // Setting `progress` straight from the touchpad made every fast or coarse
  // update a visible jump. The fingers now only move `springTarget`; a
  // critically damped spring pulls `progress` towards it every frame. Slow
  // swipes feel attached, fast ones are smoothed into a glide, and position and
  // velocity stay continuous through the release.
  property real springTarget: 0
  property real springVelocity: 0 // progress per second
  property real springOmega: root.springOmegaTracking
  // Lag behind the fingers is about 2 / omega: ~70ms while tracking.
  // Deliberately a literal, not a henri-ui preset: this is not an animation
  // but the low-pass filter that keeps the windows attached to the fingers.
  // Tying it to Motion.speed would make direct manipulation feel laggy.
  readonly property real springOmegaTracking: 28
  // The release is an animation, so it is henri-ui's `smooth` spring (no
  // overshoot): omega = 2 pi / response, which also keeps it in step with
  // Motion.speed. Critically damped; settles (1.5%) in ~5.2 / omega: ~290ms
  // after release at speed 1 -- in the region of the measured 250 ms open.
  readonly property real springOmegaRelease: 2 * Math.PI / Motion.smooth.response

  FrameAnimation {
    id: progressSpring
    onTriggered: root.stepSpring(Math.min(frameTime, 1 / 30))
  }

  // One step of a critically damped spring: [position, velocity] after dt
  // seconds. Semi-implicit Euler in sub-steps; stable for these stiffnesses.
  function springStep(x, v, target, w, dt) {
    const steps = Math.max(1, Math.ceil(dt / 0.004));
    const h = dt / steps;
    for (let i = 0; i < steps; i++) {
      v += (w * w * (target - x) - 2 * w * v) * h;
      x += v * h;
    }
    return [x, v];
  }

  // Past the end of a swipe's range: resist, a little, like a rubber band.
  function rubberBand(over) {
    return 0.06 * (1 - 1 / (1 + over * 3));
  }

  function stepSpring(dt) {
    const next = root.springStep(root.progress, root.springVelocity, root.springTarget, root.springOmega, dt);
    let x = next[0];
    let v = next[1];
    if (!root.tracking && Math.abs(root.springTarget - x) < 0.001 && Math.abs(v) < 0.01) {
      x = root.springTarget;
      v = 0;
      progressSpring.stop();
    }
    root.springVelocity = v;
    root.progress = x;
  }

  // Milliseconds until the release spring is within 1.5% of its target.
  function springSettleTime() {
    const w = root.springOmegaRelease;
    let x = root.progress - root.springTarget;
    let v = root.springVelocity;
    let t = 0;
    while (t < 1.5 && (Math.abs(x) > 0.015 || Math.abs(v) > 0.2)) {
      v += (-w * w * x - 2 * w * v) * 0.004;
      x += v * 0.004;
      t += 0.004;
    }
    return Math.round(t * 1000);
  }

  // --- sideways swipe between desktops ---------------------------------------
  // While the overview is up, input.lua hands the horizontal four-finger swipe
  // to us (mission_control_swipe_mode) instead of Hyprland's workspace swipe,
  // which would only animate the real desktops hidden behind this surface. The
  // exposé then slides sideways under the fingers with the neighbouring desktop
  // coming in beside it, like Spaces in macOS Mission Control.
  //
  // `slide` is in pages: desktop k is drawn ((k - current) + slide) screen
  // widths across, so -1 has the next desktop centred. The switch is dispatched
  // on release; when Hyprland reports it, `slide` is rebased by the same step,
  // so nothing on screen moves and the spring simply carries on to 0. Arrow keys
  // go through the same rebase and so slide too.
  property real slide: 0
  property real slideTarget: 0
  property real slideVelocity: 0 // pages per second
  property real slideOmega: root.springOmegaTracking
  property bool slideTracking: false
  property real slideStart: 0
  property real slideTravel: 0
  property real slideTrackVelocity: 0 // pages per ms, negative = towards next
  property real slideLastTime: 0
  // Whether there is a desktop either side; kept by the focused monitor's panel.
  property bool slideCanPrev: false
  property bool slideCanNext: false
  // Direction of a switch we dispatched, so the rebase goes the way the user
  // went even when the keyboard wraps around the ends.
  property int slidePendingDir: 0
  // Touchpad units per page, same as gestures:workspace_swipe_distance.
  readonly property real slideDistance: 500

  signal slideRequested(int dir)

  FrameAnimation {
    id: slideSpring
    onTriggered: {
      const next = root.springStep(root.slide, root.slideVelocity, root.slideTarget, root.slideOmega,
                                   Math.min(frameTime, 1 / 30));
      let x = next[0];
      let v = next[1];
      if (!root.slideTracking && Math.abs(root.slideTarget - x) < 0.001 && Math.abs(v) < 0.01) {
        x = root.slideTarget;
        v = 0;
        slideSpring.stop();
      }
      root.slideVelocity = v;
      root.slide = x;
    }
  }

  Timer {
    id: slideWatchdog
    interval: 350
    onTriggered: if (root.slideTracking) root.handleSlide("end", 0, root.slideLastTime)
  }

  function setSwipeMode(on) {
    // The swap lives in input.lua; without the Lua config there is nothing to
    // call and Hyprland's own workspace swipe simply stays.
    if (!Hyprland.usingLua)
      return;
    Hyprland.dispatch("function() if mission_control_swipe_mode then mission_control_swipe_mode("
                      + (on ? "true" : "false") + ") end end");
  }
  Component.onDestruction: root.setSwipeMode(false)

  function resetSlide() {
    slideSpring.stop();
    slideWatchdog.stop();
    root.slideTracking = false;
    root.slidePendingDir = 0;
    root.slide = 0;
    root.slideTarget = 0;
    root.slideVelocity = 0;
  }

  // Release towards `target`, on the slower spring, never overshooting it.
  function settleSlide(target) {
    root.slideTarget = target;
    root.slideOmega = root.springOmegaRelease;
    const dist = Math.abs(target - root.slide);
    const toward = (target - root.slide) * root.slideVelocity;
    const cap = root.springOmegaRelease * dist;
    if (toward > 0 && Math.abs(root.slideVelocity) > cap)
      root.slideVelocity = Math.sign(root.slideVelocity) * cap;
    slideSpring.start();
  }

  // The desktop changed by `step` while shown: keep every page where it is.
  function rebaseSlide(step) {
    root.slide += step;
    root.slideStart += step;
    if (root.slideTracking) {
      root.slideTarget += step;
      slideSpring.start();
    } else {
      root.settleSlide(0);
    }
  }

  function handleSlide(phase, value, time) {
    if (phase === "start") {
      // Only Mission Control has desktops side by side to slide between.
      if (!root.opened || !root.missionMode)
        return;
      root.slideTracking = true;
      slideWatchdog.restart();
      if (!slideSpring.running)
        root.slideVelocity = 0;
      root.slideOmega = root.springOmegaTracking;
      root.slideStart = root.slideTarget;
      root.slideTravel = 0;
      root.slideTrackVelocity = 0;
      root.slideLastTime = time;
      if (value !== 0)
        root.handleSlide("update", value, time);
    } else if (phase === "update" && root.slideTracking) {
      slideWatchdog.restart();
      // Fingers left is negative x, and brings in the next desktop.
      const step = value / root.slideDistance;
      root.slideTravel += step;
      const dt = time - root.slideLastTime;
      if (dt > 0) {
        root.slideTrackVelocity = root.slideTrackVelocity * 0.5 + (step / dt) * 0.5;
        root.slideLastTime = time;
      }
      const raw = root.slideStart + root.slideTravel;
      const lo = root.slideCanNext ? -1 : 0;
      const hi = root.slideCanPrev ? 1 : 0;
      root.slideTarget = raw < lo ? lo - root.rubberBand(lo - raw)
          : raw > hi ? hi + root.rubberBand(raw - hi)
          : raw;
      if (!slideSpring.running)
        slideSpring.start();
    } else if (phase === "end" && root.slideTracking) {
      root.slideTracking = false;
      slideWatchdog.stop();
      if (time - root.slideLastTime > 80 || value === 1)
        root.slideTrackVelocity = 0;
      // A flick decides by its direction, a slow drag by how far it got.
      const v = root.slideTrackVelocity;
      let side = 0;
      if (Math.abs(v) > 0.0006)
        side = v < 0 ? -1 : 1;
      else if (Math.abs(root.slideTarget + v * 120) > 0.25)
        side = root.slideTarget < 0 ? -1 : 1;
      if ((side < 0 && !root.slideCanNext) || (side > 0 && !root.slideCanPrev))
        side = 0;
      root.settleSlide(side);
      if (side !== 0)
        root.slideRequested(-side);
    }
  }

  // --- touchpad swipe -------------------------------------------------------
  // Hyprland's gesture callbacks (input.lua) forward the raw finger motion as
  // custom socket events: "mission-control-gesture:<phase>:<value>:<time_ms>".
  // Spawning a process per update would be far too slow for that; the event
  // socket is already open and costs nothing.
  //
  // Only numbers are parsed out of it and nothing is dispatched from it, so a
  // client forging such an event could at most wiggle the overview.
  property bool tracking: false
  property bool releasing: false
  property real trackStart: 0
  property real trackTravel: 0
  property real trackVelocity: 0 // progress per ms, positive = opening
  property real trackLastTime: 0
  // Finger travel, in touchpad units, for a full open. Short on purpose: a
  // flick should be enough.
  readonly property real gestureDistance: 150

  // Safety net: a swipe whose end never arrives (a lost event, a gesture
  // callback misconfigured in input.lua) must not leave the overview stuck
  // half-open with tracking on -- that state ignores Escape and the close
  // timers. Fingers moving produce updates every few ms, so silence this long
  // means they are gone.
  Timer {
    id: trackWatchdog
    interval: 350
    onTriggered: if (root.tracking) root.handleGesture("end", 0, root.trackLastTime)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom")
        return;
      const data = String(event.data || "");
      // The keys, as Hyprland events straight from the binds (bindings.lua):
      //   "mission-control toggle [mission|app|desktop]"   "mission-control hide"
      // No process per key press, so F8 is on screen the frame it is pressed.
      if (data.startsWith("mission-control ") && data.length <= 64) {
        const words = data.slice("mission-control ".length).trim().split(/\s+/);
        if (words[0] === "toggle")
          root.toggle(words[1]);
        else if (words[0] === "hide" && root.opened)
          root.dismiss();
        return;
      }
      const sideways = data.startsWith("mission-control-hswipe:");
      if ((!sideways && !data.startsWith("mission-control-gesture:")) || data.length > 96)
        return;
      const parts = data.split(":");
      const value = Number(parts[2]);
      const time = Number(parts[3]);
      if (!isFinite(value) || !isFinite(time))
        return;
      if (sideways)
        root.handleSlide(parts[1], value, time);
      else
        root.handleGesture(parts[1], value, time);
    }
  }

  function handleGesture(phase, value, time) {
    if (phase === "start") {
      progressAnim.stop();
      if (!progressSpring.running)
        root.springVelocity = 0;
      root.springTarget = root.progress;
      root.springOmega = root.springOmegaTracking;
      collapseThenHide.stop();
      fadeOutSoon.stop();
      expandFallback.stop();
      root.tracking = true;
      trackWatchdog.restart();
      root.stripHold = false;
      root.trackStart = Math.max(0, Math.min(1, root.springTarget));
      root.trackTravel = 0;
      root.trackVelocity = 0;
      root.trackLastTime = time;
      root.contentVisible = true;
      if (!root.shown) {
        // The direction picks the mode: up is Mission Control, down is App
        // Exposé (macOS: three or four fingers up / down). Hyprland delivers
        // the first movement with the start; a start without movement yet
        // waits for the first update.
        root.gestureUndecided = value === 0;
        if (value !== 0)
          root.gestureMode(value);
        root.refreshWallpaper();
        Hyprland.refreshMonitors();
        Hyprland.refreshWorkspaces();
        Hyprland.refreshToplevels();
        if (!decoProbe.running) decoProbe.running = true;
        root.showSelection = false;
        root.shown = true;
      }
      // Hyprland only starts a gesture once the fingers have moved, and that
      // first movement arrives with the start rather than as an update.
      if (value !== 0)
        root.handleGesture("update", value, time);
    } else if (phase === "update" && root.tracking) {
      trackWatchdog.restart();
      if (root.gestureUndecided && value !== 0)
        root.gestureMode(value);
      // Swiping up is negative y. Up opens Mission Control; in App Exposé it
      // is the other way round, down opens and up closes.
      const step = (root.appMode ? value : -value) / root.gestureDistance;
      root.trackTravel += step;
      const dt = time - root.trackLastTime;
      if (dt > 0) {
        const instant = step / dt;
        root.trackVelocity = root.trackVelocity * 0.5 + instant * 0.5;
        root.trackLastTime = time;
      }
      const raw = root.trackStart + root.trackTravel;
      // Past fully open: resist, a little, like a rubber band.
      root.springTarget = raw <= 0 ? 0
          : raw <= 1 ? raw
          : 1 + root.rubberBand(raw - 1);
      if (!progressSpring.running)
        progressSpring.start();
    } else if (phase === "end" && root.tracking) {
      root.tracking = false;
      trackWatchdog.stop();
      // Fingers held still before lifting: no fling.
      if (time - root.trackLastTime > 80 || value === 1)
        root.trackVelocity = 0;
      let open = root.springTarget + root.trackVelocity * 120 > 0.4;
      if (Math.abs(root.trackVelocity) > 0.002)
        open = root.trackVelocity > 0;
      root.releasing = true;
      root.gestureUndecided = false;
      if (open)
        root.summon(JSON.stringify({ mode: root.mode, app: root.appClass }));
      else
        root.dismiss();
      root.releasing = false;
    }
  }

  // A swipe that started with the overview hidden and has not moved yet.
  property bool gestureUndecided: false
  function gestureMode(value) {
    root.gestureUndecided = false;
    if (value > 0) {
      root.mode = "app";
      root.appClass = root.activeAppClass();
    } else {
      root.mode = "mission";
    }
  }
  // Windows have arrived. Expensive work (live capture of every other desktop)
  // waits for this so it does not compete with the animation for frames.
  readonly property bool settled: root.expanded && root.progress >= 1

  function lerp(a, b, t) {
    return a + (b - a) * t;
  }

  // Repeater models built from JS arrays reset -- destroy and recreate every
  // delegate, captures included -- whenever the array is reassigned, and these
  // arrays are recomputed on every lastIpcObject update. The refresh on open
  // lands mid-animation, so without this the windows were rebuilt while
  // shrinking. Keep the old array unless the members actually changed.
  function sameList(a, b) {
    if (!a || !b || a.length !== b.length)
      return false;
    for (let i = 0; i < a.length; i++)
      if (a[i] !== b[i])
        return false;
    return true;
  }

  // Same members, any order.
  function sameSet(a, b) {
    if (!a || !b || a.length !== b.length)
      return false;
    for (let i = 0; i < a.length; i++)
      if (b.indexOf(a[i]) < 0)
        return false;
    return true;
  }

  function setShown(next) {
    // An explicit open or close always wins over a swipe in progress, so
    // Escape, a click or the keybind can never be locked out by one.
    if (root.tracking && !root.releasing) {
      root.tracking = false;
      trackWatchdog.stop();
    }
    root.opened = next;
    if (next) {
      // Pressed again mid-close: the surface is still up, so just re-expand
      // rather than falling through the "already shown" guard and doing
      // nothing while it finishes collapsing.
      collapseThenHide.stop();
      fadeOutSoon.stop();
      root.contentVisible = true;
      root.stripHold = false;
      if (root.shown) {
        root.expanded = true;
        // Explicitly: `expanded` may already be true (a swipe that went back
        // to open), and then there is no change signal to start it.
        root.animateProgress(1);
        return;
      }
    } else if (!root.shown) {
      // Already hidden. Still clear `expanded`, so that a state left
      // inconsistent by anything at all heals on the next close rather than
      // wedging the toggle.
      root.expanded = false;
      return;
    }
    if (next) {
      // This plugin stays mounted, possibly idle for hours. Hyprland's model is
      // event-driven, but a window that was moved or resized while we held no
      // interest in it can leave lastIpcObject stale -- and every thumbnail's
      // position and size is computed from that, so a stale rect puts windows
      // in visibly wrong places. Ask for the current state before showing.
      //
      // Three round trips on the Hyprland socket, all before the first frame.
      // Cheap enough to keep in the critical path, and the alternative --
      // showing first and correcting after -- would move windows under the
      // pointer.
      Hyprland.refreshMonitors();
      Hyprland.refreshWorkspaces();
      Hyprland.refreshToplevels();
      if (!decoProbe.running) decoProbe.running = true;
      root.showSelection = false;
      root.contentVisible = true;
      // Reduce Motion: the surface fades in over the desktop instead of the
      // windows shrinking out of it.
      if (Motion.reduceMotion) {
        root.contentOpacity = 0;
        contentFadeIn.restart();
      }
      root.shown = true;
      // The shrink is started by the window itself, once its surface is
      // actually up -- see onBackingWindowVisibleChanged below. This is only a
      // backstop so the overview can never sit there showing full-size windows
      // if that signal does not arrive.
      expandFallback.start();
    } else {
      // Reverse of the open: shrink back out to the real desktop, then drop the
      // surface once the windows are home. Dropping it first would cut the
      // animation off and read as a flicker.
      if (!root.releasing && root.progress > 0.99)
        root.stripHold = true;
      root.expanded = false;
      root.animateProgress(0);
      expandFallback.stop();
      // Timed off the animation actually running, which is shorter when the
      // close starts part-way (a released swipe).
      const dur = (progressAnim.running || progressSpring.running) ? root.progressAnimDuration : 0;
      // The curve is ~98.8% home at fadeStartAt: the copy is then
      // indistinguishable from the desktop, so a short fade over the tail hands
      // over without the full-size copy lingering on screen.
      const fadeAt = Math.round(dur * root.fadeStartAt);
      fadeOutSoon.interval = fadeAt;
      collapseThenHide.interval = Math.max(dur, fadeAt + root.fadeDuration) + 16;
      fadeOutSoon.restart();
      collapseThenHide.restart();
    }
  }

  // Dispatch syntax depends on which parser Hyprland was configured with, and
  // getting it wrong fails at the far end where nothing here would notice.
  // Omarchy uses the Lua config, and in Lua mode the string is not a dispatcher
  // name and its arguments -- it is a Lua expression pasted into
  // `hl.dispatch(...)`. So the usual "workspace 3" is a syntax error, and
  // "focuswindow address:0x..." is too. Hyprland.usingLua is exactly the flag
  // for this, so branch on it rather than hardcoding one dialect.
  //
  // (`hl.dsp.workspace` exists but is a table of workspace *management* verbs --
  // rename, move to monitor, toggle_special. Merely going to one is a focus.)
  function dispatch(luaExpr, legacy) {
    Hyprland.dispatch(Hyprland.usingLua ? luaExpr : legacy);
  }

  // Everything interpolated into a dispatch is checked for SHAPE first.
  //
  // Under the Lua parser a dispatch string is not a command with arguments, it
  // is an expression the compositor evaluates -- so a value carrying a quote
  // would close the string literal it was pasted into and the rest would run as
  // Lua. These particular values arrive from Hyprland's own IPC rather than
  // from a client, so this is not a live hole; it is refusing to have one. The
  // cost is two regular expressions, and the alternative is trusting that the
  // provenance of every field stays what it is today.
  //
  // Refuse rather than escape. A workspace id that is not a number and an
  // address that is not hex are not values worth salvaging.
  function safeWorkspaceId(value) {
    const text = String(value);
    return /^-?[0-9]{1,10}$/.test(text) ? text : "";
  }

  function safeAddress(value) {
    const text = String(value || "");
    const bare = text.startsWith("0x") ? text.slice(2) : text;
    return /^[0-9a-fA-F]{1,16}$/.test(bare) ? "0x" + bare : "";
  }

  // Switching and closing are one action, but the dispatch travels over a
  // socket -- hiding in the same tick can cut it off, so give it a frame.
  function goToWorkspace(id) {
    const target = root.safeWorkspaceId(id);
    if (target === "")
      return;
    root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })", "workspace " + target);
    hideSoon.start();
  }

  // HyprlandToplevel.address is the bare pointer -- "55c058e3d1d0" -- while
  // every dispatcher that takes one wants hyprctl's spelling, "0x55c058e3d1d0".
  // Without the prefix Hyprland answers "window not found" and the click simply
  // does nothing, so normalise here rather than at each call site.
  function focusWindow(address) {
    const addr = root.safeAddress(address);
    if (addr === "")
      return;
    root.dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })",
                  "focuswindow address:" + addr);
    hideSoon.start();
  }

  // Backstop only. The real trigger is the surface becoming visible; a fixed
  // delay cannot do the job, because the layer surface takes ~80ms to be mapped
  // and composited. Expanding on a 16ms timer meant most of the 260ms shrink
  // ran while there was still nothing on screen, and the overview appeared with
  // the windows already three-quarters of the way down -- which throws away the
  // entire point of animating from the real desktop.
  Timer {
    id: expandFallback
    interval: 400
    onTriggered: if (root.opened) root.expanded = true
  }

  // Start dissolving just before the windows finish returning, so the fade is
  // over the tail of the movement rather than after it.
  Timer {
    id: fadeOutSoon
    // Set on each close.
    interval: Math.round(root.unshrinkDuration * root.fadeStartAt)
    onTriggered: if (!root.opened && !root.tracking) root.contentVisible = false
  }

  Timer {
    id: collapseThenHide
    interval: Math.max(root.unshrinkDuration, Math.round(root.unshrinkDuration * root.fadeStartAt) + root.fadeDuration)
    onTriggered: if (!root.opened && !root.tracking) root.shown = false
  }

  Timer {
    id: hideSoon
    interval: 80
    onTriggered: root.dismiss()
  }

  // Window titles and app ids are chosen by the application itself, and a web
  // page can set its browser tab's title, so every one of these strings is
  // attacker-influenced by the time it reaches us. Two defences, both applied
  // at the point of display:
  //
  // 1. `textFormat: Text.PlainText` on every sink that shows one. A QML Text
  //    defaults to Text.AutoText, which sniffs the string for HTML and switches
  //    to rich text when it finds any -- and rich text follows markup into
  //    resource handling. A title is data, never markup.
  // 2. A documented length cap, applied here rather than relying on elide.
  //    Eliding only stops it being *drawn*; the whole string is still laid out.
  readonly property int maxLabelLength: 128

  function displayLabel(value) {
    const text = String(value || "");
    return text.length > root.maxLabelLength
      ? text.slice(0, root.maxLabelLength) + "\u2026"
      : text;
  }

  // Icon for a window, looked up from its app id. heuristicLookup copes with
  // the usual mismatches between a Wayland app id and a .desktop file name.
  // A Wayland client chooses its own app id, so this string is attacker-chosen
  // text arriving in a long-lived shell process. Two rules follow from that:
  //
  //   1. An absolute path is honoured ONLY when it came out of a desktop entry
  //      -- a local file the session installed. An earlier version fell back to
  //      the app id for the icon name and then turned any leading "/" into a
  //      file:// URL, which let a client point the shell at any pathname it
  //      liked and have it opened as an image: across local file boundaries, at
  //      a FIFO that never returns, or at something crafted to exhaust the
  //      decoder. The process holding that image is the whole shell.
  //   2. A raw app id is only ever used as an icon THEME name, and only when it
  //      looks like one. A slash, a colon, a leading dot, "..", or an
  //      unreasonable length means it is not a theme name, so it is refused
  //      rather than sanitised -- there is no need to salvage a hostile value
  //      when a generic icon is a perfectly good answer.
  //
  // Reported by the Omarchy marketplace security review.
  readonly property int maxIconNameLength: 128
  readonly property int maxIconPathLength: 512

  function looksLikeIconName(value) {
    return value.length > 0
        && value.length <= root.maxIconNameLength
        && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value)
        && value.indexOf("..") === -1;
  }

  function iconFor(appId) {
    const fallback = Quickshell.iconPath("application-x-executable", true);
    // Bounded before it is used for anything at all, lookup included.
    const id = String(appId || "").slice(0, root.maxIconNameLength);
    if (id.length === 0)
      return fallback;

    const entry = DesktopEntries.heuristicLookup(id);
    const fromEntry = String((entry && entry.icon) || "");
    if (fromEntry.length > 0 && fromEntry.length <= root.maxIconPathLength) {
      if (fromEntry.startsWith("/") && fromEntry.indexOf("..") === -1)
        return "file://" + fromEntry;
      if (root.looksLikeIconName(fromEntry)) {
        const themed = Quickshell.iconPath(fromEntry, true);
        if (themed.length > 0)
          return themed;
      }
    }

    // No entry, or nothing usable in it. The app id is all that is left, and it
    // is untrusted: theme name only, never a path.
    if (!root.looksLikeIconName(id))
      return fallback;
    const guess = Quickshell.iconPath(id, true);
    return guess.length > 0 ? guess : fallback;
  }

  Variants {
    // Skip Quickshell's placeholder screen. When the only output drops its
    // link (an OLED waking from DPMS re-handshakes DisplayPort), Quickshell
    // hands out a nameless placeholder for a beat. Building a panel for it
    // would instantiate every thumbnail below against windows that have no
    // monitor, and Hyprland 0.56 crashes on that capture request.
    model: Quickshell.screens.filter(s => s && s.name !== ""
                                          && (root.testScreen === "" || String(s.name) === root.testScreen))

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"


      // Hiding tears down the layer surface but keeps the QML tree and, more to
      // the point, the decoded wallpaper -- which is the 190ms.
      visible: root.shown

      // Whole-surface opacity, handed to Hyprland. See contentOpacity.
      //
      // Held at 0 until every window copy has its first frame. A capture
      // context only exists while shown, and its first buffer arrives a few
      // frames after the surface maps -- revealing before that showed bare
      // wallpaper where the windows had been, for 2-3 frames at the start of
      // every swipe. Transparent until then, the real desktop simply stays
      // visible underneath.
      HyprlandWindow.opacity: panel.revealed ? root.contentOpacity : 0

      property bool revealed: false
      readonly property bool capturesReady: {
        const n = exposeRepeater.count;
        for (let i = 0; i < n; i++) {
          const item = exposeRepeater.itemAt(i);
          if (item && !item.captureReady)
            return false;
        }
        return true;
      }
      // Latched: a window opening while the overview is up must not blank it.
      onCapturesReadyChanged: if (panel.capturesReady && root.shown) panel.revealed = true
      Connections {
        target: root
        function onShownChanged() {
          if (root.shown) {
            // With a single desktop macOS shows its thumbnail straight away
            // (measured: the recording's strip has the thumbnail and the "+"
            // from the first frame); the strip only folds to names when
            // there are several.
            panel.stripExpanded = panel.slotIds.length <= 1;
            // A FrameAnimation does not run in a hidden window, so the fold
            // ordered on the last close never happened: snap it now.
            stripOpen.snap(stripOpen.to);
            if (panel.capturesReady) panel.revealed = true;
            else revealTimeout.restart();
          } else {
            revealTimeout.stop();
            panel.revealed = false;
            panel.finishReorder();
            panel.dragTile = -1;
            panel.dragSlot = -1;
            panel.resetTileOrder();
            // Back to the way macOS opens: strip folded, nothing peeked.
            panel.stripExpanded = false;
            panel.peek = -1;
            panel.altHeld = false;
            panel.dragWindow = -1;
            panel.dropSlot = -2;
          }
        }
      }
      // While hidden, refresh the kept frames so what shows for the first
      // frames of an open is recent rather than from the last open. Not on a
      // clock: a 1.5 s timer was 25 screencopy round-trips per 10 s (measured
      // 2026-09-26) for an overlay nobody was looking at, and kept the
      // compositor from ever going quiet. Now on desktop changes -- a window
      // opened, closed, moved, a workspace switched -- debounced, with a slow
      // fallback for content that changes without any of that. Not on focus:
      // every layer that opens and closes flips the active window, which on
      // this desktop happens every couple of seconds, and a focus change
      // does not change what the windows show anyway.
      function recaptureHidden() {
        if (root.shown) return;
        for (let i = 0; i < exposeRepeater.count; i++) {
          const item = exposeRepeater.itemAt(i);
          if (item) item.recapture();
        }
      }
      Timer {
        id: hiddenRecapture
        interval: Motion.slow
        onTriggered: panel.recaptureHidden()
      }
      Timer {
        interval: 30000
        repeat: true
        running: !root.shown
        onTriggered: hiddenRecapture.restart()
      }
      Connections {
        target: Hyprland
        function onRawEvent(event) {
          if (root.shown) return;
          switch (event.name) {
          case "openwindow": case "closewindow": case "movewindow": case "movewindowv2":
          case "workspace": case "workspacev2": case "fullscreen": case "changefloatingmode":
            hiddenRecapture.restart();
          }
        }
      }

      // A window that never delivers a frame must not keep the overview away.
      Timer {
        id: revealTimeout
        interval: 250
        onTriggered: if (root.shown) panel.revealed = true
      }

      // `visible` is our intent; `backingWindowVisible` is the surface actually
      // being up, which is what the shrink has to start from. One more frame
      // after that, so the full-size state -- indistinguishable from the real
      // desktop -- is painted at least once and the animation has somewhere to
      // come from.
      onBackingWindowVisibleChanged: {
        if (backingWindowVisible && panel.revealed && root.opened)
          firstFrame.start();
        else
          firstFrame.stop();
      }
      // The keyboard open waits for the reveal too, or its first frames play
      // while the surface is still held transparent.
      onRevealedChanged: if (panel.revealed && panel.backingWindowVisible && root.opened) firstFrame.start()

      Timer {
        id: firstFrame
        interval: 16
        onTriggered: if (root.opened) root.expanded = true
      }

      // Overlay so it covers the bar and the dock too; exclusive keyboard focus
      // so the arrow keys work without a click first.
      WlrLayershell.namespace: "mission-control"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: root.testScreen !== "" ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      // --- which monitor are we on -----------------------------------------
      // Window positions come out of Hyprland in global logical coordinates, so
      // mapping them into a thumbnail needs this monitor's logical origin and
      // size. HyprlandMonitor.width/height are *physical* pixels; divide by
      // scale to get the logical box the client rectangles live in.
      readonly property var hyprMonitor: {
        const mons = Hyprland.monitors.values || [];
        for (let i = 0; i < mons.length; i++)
          if (String(mons[i].name) === String(panel.screen.name))
            return mons[i];
        return null;
      }
      readonly property real monX: hyprMonitor ? hyprMonitor.x : 0
      readonly property real monY: hyprMonitor ? hyprMonitor.y : 0
      readonly property real monW: hyprMonitor ? hyprMonitor.width / hyprMonitor.scale : panel.width
      readonly property real monH: hyprMonitor ? hyprMonitor.height / hyprMonitor.scale : panel.height

      // --- which desktops ---------------------------------------------------
      // Only this monitor's workspaces, and only real ones: the scratchpad and
      // other special workspaces have negative ids and are not desktops.
      // Workspaces 1-N exist at all times because looknfeel.lua pins them
      // persistent -- without that Hyprland would only create them on demand
      // and the strip would have holes that appear and vanish.
      property var desktops: []
      onDesktopsLiveChanged: {
        if (!root.sameList(panel.desktops, panel.desktopsLive))
          panel.desktops = panel.desktopsLive;
        if (!panel.reorderPending)
          panel.setSlotIds(panel.desktopsLive.map(d => d.id));
      }
      readonly property var desktopsLive: {
        const out = [];
        const seen = {};
        const all = Hyprland.workspaces.values || [];
        for (let i = 0; i < all.length; i++) {
          const ws = all[i];
          if (ws.id < 0)
            continue;
          if (panel.hyprMonitor && ws.monitor && ws.monitor.id !== panel.hyprMonitor.id)
            continue;
          out.push(ws);
          seen[ws.id] = true;
        }
        // Desktops added with "+" that Hyprland has nothing on (yet, or any
        // more): empty desktops until they are removed with their "x".
        const extra = root.extraDesktops;
        for (let i = 0; i < extra.length; i++) {
          if (seen[extra[i].id] || String(extra[i].monitor) !== String(panel.screen.name))
            continue;
          out.push(panel.placeholderDesk(extra[i].id));
        }
        out.sort((a, b) => a.id - b.id);
        return out;
      }

      // Stand-ins for desktops Hyprland does not have. Cached so the same id
      // gives the same object and the sameList checks above keep working.
      property var placeholders: ({})
      function placeholderDesk(id) {
        if (!panel.placeholders[id])
          panel.placeholders[id] = { id: id, name: String(id), focused: false, toplevels: null, placeholder: true };
        return panel.placeholders[id];
      }

      function isExtra(id) {
        const extra = root.extraDesktops;
        for (let i = 0; i < extra.length; i++)
          if (extra[i].id === id && String(extra[i].monitor) === String(panel.screen.name))
            return true;
        return false;
      }

      // --- adding and removing desktops -------------------------------------
      // "+" at the end of the strip adds a desktop after the last one; up to
      // 16 per display, as in macOS. Hyprland creates the workspace itself
      // once a window lands on it or it is switched to, so until then it is
      // one of root.extraDesktops.
      readonly property int maxDesktops: 16
      function addDesktop() {
        if (panel.slotIds.length >= panel.maxDesktops || !Hyprland.usingLua)
          return -1;
        let max = 0;
        const all = Hyprland.workspaces.values || [];
        for (let i = 0; i < all.length; i++)
          if (all[i].id > max)
            max = all[i].id;
        const extra = root.extraDesktops;
        for (let i = 0; i < extra.length; i++)
          if (extra[i].id > max)
            max = extra[i].id;
        const id = max + 1;
        root.extraDesktops = extra.concat([{ id: id, monitor: String(panel.screen.name) }]);
        return id;
      }

      // The "x" on a thumbnail. Its windows go to the desktop on its left (or
      // the right, for the first one), and every desktop after it moves down a
      // number so there is no hole -- macOS renumbers the same way. Same Lua
      // batch as a reorder: each step's target has just been emptied.
      property bool removePending: false
      function removeDesktop(id) {
        if (!Hyprland.usingLua || panel.reorderPending)
          return;
        const ids = panel.slotIds.map(v => root.safeWorkspaceId(v));
        const idx = panel.slotIds.indexOf(id);
        if (idx < 0 || ids.length < 2 || ids.indexOf("") >= 0)
          return;
        const content = panel.slotContent();
        const steps = [];
        const move = (slot, target) => {
          for (let i = 0; i < content[slot].length; i++)
            steps.push("mv(\"" + content[slot][i] + "\", \"" + target + "\")");
        };
        move(idx, ids[idx > 0 ? idx - 1 : 1]);
        for (let s = idx + 1; s < ids.length; s++)
          move(s, ids[s - 1]);
        // Stay where you were: follow the current desktop to its new number,
        // or, if it is the one being removed, go where its windows went.
        const cur = panel.currentDesktop ? panel.slotIds.indexOf(panel.currentDesktop.id) : -1;
        let focusTo = "";
        if (cur === idx)
          focusTo = ids[idx > 0 ? idx - 1 : 1];
        else if (cur > idx)
          focusTo = ids[cur - 1];
        if (focusTo !== "")
          steps.push("pcall(hl.dispatch, hl.dsp.focus({ workspace = \"" + focusTo + "\" }))");

        // The desktops only this plugin knows about move down with the rest.
        const removed = panel.slotIds[idx];
        const last = panel.slotIds[panel.slotIds.length - 1];
        const mon = String(panel.screen.name);
        const kept = [];
        const extra = root.extraDesktops;
        for (let i = 0; i < extra.length; i++) {
          const e = extra[i];
          if (String(e.monitor) !== mon || e.id < removed) { kept.push(e); continue; }
          if (e.id === removed || e.id === last) continue;
          kept.push({ id: e.id - 1, monitor: e.monitor });
        }
        root.extraDesktops = kept;

        // The focus change is a renumbering, not a switch: no sideways slide.
        panel.removePending = true;
        removeSettle.restart();
        if (steps.length === 0)
          return;
        root.dispatch("function() local function mv(a, w) pcall(hl.dispatch, hl.dsp.window.move({ workspace = w, follow = false, window = \"address:\" .. a })) end "
                      + steps.join(" ") + " end", "");
      }
      Timer {
        id: removeSettle
        interval: 400
        onTriggered: panel.removePending = false
      }

      // Every window of each slot, in reading order, as dispatch-safe
      // addresses: each lands on an empty workspace below, and inserting them
      // left to right, top to bottom rebuilds the tiling about as it was.
      function slotContent() {
        const content = [];
        for (let s = 0; s < panel.slotIds.length; s++) {
          const desk = panel.deskById(panel.slotIds[s]);
          const tls = desk && desk.toplevels ? (desk.toplevels.values || []) : [];
          const wins = [];
          for (let i = 0; i < tls.length; i++) {
            const addr = root.safeAddress(tls[i].address);
            const o = tls[i].lastIpcObject;
            if (addr !== "")
              wins.push({ addr: addr, x: o && o.at ? o.at[0] : 0, y: o && o.at ? o.at[1] : 0 });
          }
          wins.sort((a, b) => (a.x - b.x) || (a.y - b.y));
          content.push(wins.map(w => w.addr));
        }
        return content;
      }

      // A window dropped on a desktop thumbnail, or on "+" (a new desktop).
      function moveWindowToSlot(address, slot) {
        if (!Hyprland.usingLua)
          return;
        const addr = root.safeAddress(address);
        let id = slot === -1 ? panel.addDesktop() : (panel.slotIds[slot] ?? -1);
        const target = root.safeWorkspaceId(id);
        if (addr === "" || target === "" || id < 0)
          return;
        root.dispatch("hl.dsp.window.move({ workspace = \"" + target + "\", follow = false, window = \"address:" + addr + "\" })", "");
      }

      Component.onCompleted: {
        panel.desktops = panel.desktopsLive;
        panel.setSlotIds(panel.desktopsLive.map(d => d.id));
        panel.windows = panel.windowsLive;
        panel.focusedTile = panel.focusedTileLive;
      }

      // --- reordering desktops ----------------------------------------------
      // Drag a thumbnail along the strip to move that desktop elsewhere; the
      // others slide aside to make room. Hyprland has no workspace order apart
      // from the ids, and the ids are what SUPER+n means, so a reorder keeps the
      // ids where they are and moves the WINDOWS between them.
      //
      // The strip is built so that nothing is rebuilt when that happens. A
      // thumbnail is a TILE with a fixed identity, and `tileOrder` says which
      // tile sits in which slot; a tile shows whatever workspace owns its slot.
      // On drop the dragged tile simply stays where it was put -- it IS the new
      // slot's content once Hyprland has moved the windows. Tying the thumbnails
      // to Hyprland's workspace objects instead would not survive the move: a
      // workspace that is empty for an instant mid-shuffle is destroyed and
      // recreated, and a rebuilt thumbnail shows bare wallpaper for the 2-3
      // frames until its captures deliver.
      //
      // Between the drop and Hyprland reporting the moves (`reorderPending`),
      // the slots, the tiles' windows, the exposé and the focus marker are held
      // at what is on screen, so the burst of move events cannot show through.

      // Workspace id per slot, ascending. Held while a reorder is in flight.
      property var slotIds: []
      // tileOrder[slot] = tile index.
      property var tileOrder: []
      signal tilesSnap()

      function setSlotIds(ids) {
        if (root.sameList(panel.slotIds, ids))
          return;
        const resized = ids.length !== panel.slotIds.length;
        // Order first: the tile Repeater follows slotIds.length, and every tile
        // must find itself in tileOrder when it is created.
        if (resized)
          panel.tileOrder = ids.map((_, i) => i);
        panel.slotIds = ids;
        if (resized)
          panel.tilesSnap();
      }

      function resetTileOrder() {
        panel.tileOrder = panel.slotIds.map((_, i) => i);
        panel.tilesSnap();
      }

      function deskById(id) {
        const all = Hyprland.workspaces.values || [];
        for (let i = 0; i < all.length; i++)
          if (all[i].id === id)
            return all[i];
        return panel.isExtra(id) ? panel.placeholderDesk(id) : null;
      }

      readonly property real stripPitch: panel.stripTileW + panel.stripGap
      readonly property real stripRowX:
          Math.round((panel.width - panel.slotIds.length * panel.stripPitch + panel.stripGap) / 2)

      // The tile being dragged and the slot it would land in.
      property int dragTile: -1
      property int dragSlot: -1

      // tileOrder with the dragged tile moved to where it hovers.
      readonly property var displayOrder: {
        const o = panel.tileOrder.slice();
        const from = o.indexOf(panel.dragTile);
        if (from < 0 || panel.dragSlot < 0)
          return o;
        o.splice(from, 1);
        o.splice(Math.min(panel.dragSlot, o.length), 0, panel.dragTile);
        return o;
      }

      // The tile showing the focused desktop. Held during a reorder: the focus
      // follows its windows in Hyprland a few milliseconds after the drop, and
      // the marker must not flick to the wrong tile in between.
      property int focusedTile: -1
      readonly property int focusedTileLive: {
        const s = panel.currentDesktop ? panel.slotIds.indexOf(panel.currentDesktop.id) : -1;
        return s >= 0 && s < panel.tileOrder.length ? panel.tileOrder[s] : -1;
      }
      onFocusedTileLiveChanged: if (!panel.reorderPending) panel.focusedTile = panel.focusedTileLive

      property bool reorderPending: false
      // address -> workspace id each moved window has to end up on, and the
      // workspace the focus has to follow to ("" when it stays).
      property var reorderExpect: ({})
      property string reorderFocus: ""

      function endDrag(tile) {
        const order = panel.displayOrder;
        const from = panel.tileOrder.indexOf(tile);
        const to = order.indexOf(tile);
        if (from >= 0 && to >= 0 && from !== to)
          panel.commitReorder(from, to, order);
        panel.dragTile = -1;
        panel.dragSlot = -1;
      }

      function commitReorder(from, to, order) {
        // The moves are one Lua function; the legacy parser has no equivalent.
        if (!Hyprland.usingLua)
          return;
        const ids = panel.slotIds.map(id => root.safeWorkspaceId(id));
        if (ids.indexOf("") >= 0)
          return;
        // Every window of each slot, in reading order: each lands on an empty
        // workspace below, and inserting them left to right, top to bottom
        // rebuilds the tiling about as it was.
        const content = [];
        for (let s = 0; s < ids.length; s++) {
          const desk = panel.deskById(panel.slotIds[s]);
          const tls = desk && desk.toplevels ? (desk.toplevels.values || []) : [];
          const wins = [];
          for (let i = 0; i < tls.length; i++) {
            const addr = root.safeAddress(tls[i].address);
            const o = tls[i].lastIpcObject;
            if (addr !== "")
              wins.push({ addr: addr, x: o && o.at ? o.at[0] : 0, y: o && o.at ? o.at[1] : 0 });
          }
          wins.sort((a, b) => (a.x - b.x) || (a.y - b.y));
          content.push(wins.map(w => w.addr));
        }

        // Where each slot's windows go: the slot its tile now occupies.
        const dest = [];
        for (let s = 0; s < ids.length; s++)
          dest.push(order.indexOf(panel.tileOrder[s]));

        // A drag is a rotation: park the dragged desktop's windows, shift the
        // ones in between over by one, then drop the parked ones into the gap.
        // Each step's target has just been emptied, so nothing is inserted into
        // another desktop's layout. All of it is one Lua call, so Hyprland
        // applies it in one go. The temporary workspace is a special one, which
        // nothing lists as a desktop.
        const park = "special:mcreorder";
        const steps = [];
        const move = (slot, target) => {
          for (let i = 0; i < content[slot].length; i++)
            steps.push("mv(\"" + content[slot][i] + "\", \"" + target + "\")");
        };
        move(from, park);
        if (from < to)
          for (let k = from; k < to; k++) move(k + 1, ids[k]);
        else
          for (let k = from; k > to; k--) move(k - 1, ids[k]);
        move(from, ids[to]);

        // Stay on the desktop you were on: follow its windows.
        const focusSlot = panel.currentDesktop ? panel.slotIds.indexOf(panel.currentDesktop.id) : -1;
        const focusTo = focusSlot >= 0 && dest[focusSlot] !== focusSlot ? ids[dest[focusSlot]] : "";
        if (focusTo !== "")
          steps.push("pcall(hl.dispatch, hl.dsp.focus({ workspace = \"" + focusTo + "\" }))");

        const expect = {};
        for (let s = 0; s < ids.length; s++)
          for (let i = 0; i < content[s].length; i++)
            expect[content[s][i]] = ids[dest[s]];

        // Hold everything first, then re-seat the tiles, then send it.
        panel.reorderExpect = expect;
        panel.reorderFocus = focusTo;
        panel.reorderPending = true;
        panel.tileOrder = order;
        reorderDeadline.restart();
        if (steps.length === 0)
          return;
        // pcall per step: a window that closed in the meantime must not abort
        // the rest and strand windows on the parking workspace.
        root.dispatch("function() local function mv(a, w) pcall(hl.dispatch, hl.dsp.window.move({ workspace = w, follow = false, window = \"address:\" .. a })) end "
                      + steps.join(" ") + " end", "");
      }

      function reorderLanded() {
        const tls = Hyprland.toplevels.values || [];
        for (let i = 0; i < tls.length; i++) {
          const want = panel.reorderExpect[root.safeAddress(tls[i].address)];
          if (want !== undefined && (!tls[i].workspace || String(tls[i].workspace.id) !== want))
            return false;
        }
        return panel.reorderFocus === ""
            || (panel.currentDesktop !== null && String(panel.currentDesktop.id) === panel.reorderFocus);
      }

      function finishReorder() {
        if (!panel.reorderPending)
          return;
        reorderDeadline.stop();
        panel.reorderPending = false;
        panel.reorderExpect = ({});
        panel.reorderFocus = "";
        panel.setSlotIds(panel.desktopsLive.map(d => d.id));
        panel.focusedTile = panel.focusedTileLive;
        // Same windows, possibly in a new focus order: keep the array, or the
        // exposé would rebuild every window it is showing.
        if (!root.sameSet(panel.windows, panel.windowsLive))
          panel.windows = panel.windowsLive;
        // The windows' positions on their new workspaces.
        Hyprland.refreshToplevels();
      }

      Timer {
        interval: 16
        repeat: true
        running: panel.reorderPending
        onTriggered: if (panel.reorderLanded()) panel.finishReorder()
      }

      // Never hold the overview frozen on a move that did not happen.
      Timer {
        id: reorderDeadline
        interval: 1000
        onTriggered: panel.finishReorder()
      }

      readonly property var currentDesktop: {
        for (let i = 0; i < panel.desktops.length; i++)
          if (panel.desktops[i].focused)
            return panel.desktops[i];
        return panel.desktops.length > 0 ? panel.desktops[0] : null;
      }

      // Windows of the current desktop, most recently used first --
      // focusHistoryID counts up from the window you were last in, so ascending
      // order puts the one you are coming back to in the top-left.
      property var windows: []
      // Reassigning the array rebuilds every delegate, captures included, and
      // a rebuilt capture is blank for a few frames. So while the overview is
      // up the order does not matter (it is only the layout order for a fresh
      // open): the array is kept as long as the same windows are in it. And
      // while it is closing nothing is taken over at all: clicking a window
      // focuses it, Hyprland reorders the focus history at once, and the
      // rebuild landed right in the middle of the close animation.
      onWindowsLiveChanged: {
        if (panel.reorderPending)
          return;
        if (root.shown && !root.opened)
          return;
        const same = root.shown ? root.sameSet(panel.windows, panel.windowsLive)
                                : root.sameList(panel.windows, panel.windowsLive);
        if (!same)
          panel.windows = panel.windowsLive;
      }
      // Whatever was held back during the close is taken over once hidden.
      Connections {
        target: root
        function onShownChanged() {
          if (!root.shown && !panel.reorderPending && !root.sameList(panel.windows, panel.windowsLive))
            panel.windows = panel.windowsLive;
        }
      }
      // App Exposé shows one app from every desktop; the other modes the
      // current desktop.
      readonly property var windowsLive: root.appMode ? panel.appWindows(root.appClass)
                                                     : panel.windowsOf(panel.currentDesktop)

      // Every window of one app on this monitor, most recently used first,
      // wherever it is -- other desktops and the dock's special:minimized
      // workspace included (those go in the smaller row underneath).
      function appWindows(cls) {
        const out = [];
        if (!cls)
          return out;
        const tls = Hyprland.toplevels.values || [];
        for (let i = 0; i < tls.length; i++) {
          const t = tls[i];
          const o = t.lastIpcObject;
          if (!t.wayland || !o || o.mapped === false || o.hidden === true)
            continue;
          if (String(o["class"] || "") !== cls)
            continue;
          if (panel.hyprMonitor && t.monitor && t.monitor.id !== panel.hyprMonitor.id)
            continue;
          out.push(t);
        }
        out.sort((a, b) => (a.lastIpcObject.focusHistoryID || 0) - (b.lastIpcObject.focusHistoryID || 0));
        return out;
      }

      // App ids on this monitor, most recently used first, for Tab in App
      // Exposé.
      function appClasses() {
        const seen = {};
        const out = [];
        const tls = Hyprland.toplevels.values || [];
        const sorted = tls.slice().filter(t => t.wayland && t.lastIpcObject && t.lastIpcObject.mapped !== false)
            .sort((a, b) => (a.lastIpcObject.focusHistoryID || 0) - (b.lastIpcObject.focusHistoryID || 0));
        for (let i = 0; i < sorted.length; i++) {
          const t = sorted[i];
          if (panel.hyprMonitor && t.monitor && t.monitor.id !== panel.hyprMonitor.id)
            continue;
          const cls = String(t.lastIpcObject["class"] || "");
          if (cls === "" || seen[cls])
            continue;
          seen[cls] = true;
          out.push(cls);
        }
        return out;
      }

      function nextApp(dir) {
        const classes = panel.appClasses();
        if (classes.length === 0)
          return;
        const i = classes.indexOf(root.appClass);
        root.appClass = classes[((i < 0 ? 0 : i + dir) + classes.length) % classes.length];
      }

      // A window parked by the dock: on a special workspace, not a desktop.
      function isMinimized(t) {
        return !!(t && t.workspace && t.workspace.id < 0);
      }

      function windowsOf(desk) {
        const out = [];
        if (!desk)
          return out;
        const tls = desk.toplevels ? (desk.toplevels.values || []) : [];
        for (let i = 0; i < tls.length; i++) {
          const t = tls[i];
          const o = t.lastIpcObject;
          if (!t.wayland || !o || o.mapped === false || o.hidden === true)
            continue;
          out.push(t);
        }
        out.sort((a, b) => (a.lastIpcObject.focusHistoryID || 0) - (b.lastIpcObject.focusHistoryID || 0));
        return out;
      }

      // The desktop `rel` places from the current one, or null past the ends.
      function desktopAt(rel) {
        const i = panel.desktops.indexOf(panel.currentDesktop);
        const j = i + rel;
        return (i < 0 || j < 0 || j >= panel.desktops.length) ? null : panel.desktops[j];
      }

      // --- sideways swipe ---------------------------------------------------
      // Only the focused monitor's overview slides; the others stay put.
      readonly property bool slideOwner: panel.hyprMonitor !== null && panel.hyprMonitor.focused
      readonly property real slideX: panel.slideOwner ? root.slide * panel.width : 0
      Binding { target: root; property: "slideCanPrev"; value: panel.desktopAt(-1) !== null; when: panel.slideOwner }
      Binding { target: root; property: "slideCanNext"; value: panel.desktopAt(1) !== null; when: panel.slideOwner }

      Connections {
        target: root
        function onSlideRequested(dir) {
          if (!panel.slideOwner)
            return;
          const next = panel.desktopAt(dir);
          const target = next ? root.safeWorkspaceId(next.id) : "";
          if (target === "")
            return;
          root.slidePendingDir = dir;
          root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })", "workspace " + target);
        }
      }

      property int deskIndex: -1
      onCurrentDesktopChanged: {
        const i = panel.desktops.indexOf(panel.currentDesktop);
        const old = panel.deskIndex;
        panel.deskIndex = i;
        // Following a desktop's windows to their new slot is not a switch.
        if (panel.reorderPending || panel.removePending)
          return;
        if (!panel.slideOwner || !root.shown || old < 0 || i < 0 || i === old)
          return;
        const step = root.slidePendingDir !== 0 ? root.slidePendingDir : i - old;
        root.slidePendingDir = 0;
        // A jump further than one desktop has no page in between to slide past.
        if (Math.abs(step) === 1)
          root.rebaseSlide(step);
        else
          root.resetSlide();
      }

      // --- geometry ---------------------------------------------------------
      // Proportions taken off a real Mission Control screenshot: the Spaces
      // strip is about a sixth of the screen, and the thumbnails in it about
      // two thirds of the strip, leaving room for a label underneath.
      readonly property real uiScale: panel.width / 1920
      // The strip opens folded, showing only the desktops' names, and unfolds
      // into thumbnails when the pointer touches it or a window is dragged
      // towards it (macOS). Once unfolded it stays so until the overview
      // closes. The windows underneath move down a little to make room.
      property bool stripExpanded: false
      HUi.SpringValue {
        id: stripOpen
        to: panel.stripExpanded ? 1 : 0
        preset: Motion.smooth
      }
      readonly property real stripFullH: Math.round(panel.height * 0.155)
      readonly property real stripCollapsedH: Math.round(panel.stripLabelBand + panel.stripPad * 2)
      readonly property real stripH: root.lerp(panel.stripCollapsedH, panel.stripFullH, stripOpen.value)
      readonly property real stripPad: Math.round(12 * uiScale)
      readonly property real stripGap: Math.round(22 * uiScale)
      readonly property int stripLabelSize: Math.max(9, Math.round(15 * uiScale))
      readonly property real stripLabelBand: Math.round(stripLabelSize * 1.9)

      // Thumbnails keep the screen's aspect ratio, so each is a faithful
      // miniature. Fit to whichever axis runs out first -- with a dozen
      // desktops it is the width, with two it is the strip height.
      // Off the held slots, so a reorder's burst of events cannot resize them.
      readonly property int deskCount: Math.max(1, panel.slotIds.length)
      // 86% of the width for the row, leaving the right edge to the "+".
      readonly property real stripTileH: Math.min(
          stripFullH - stripLabelBand - stripPad * 2,
          ((panel.width * 0.86) - (deskCount - 1) * stripGap) / deskCount * (panel.height / panel.width))
      readonly property real stripTileW: stripTileH * panel.width / panel.height
      // The "+" is half a thumbnail wide, at the right edge (macOS).
      readonly property real plusW: Math.round(panel.stripTileW * 0.5)
      readonly property real plusX: panel.width - panel.stripPad * 2 - panel.plusW
      readonly property bool plusVisible: panel.slotIds.length < panel.maxDesktops && Hyprland.usingLua

      // The exposé is NOT a grid of equal cells. macOS shrinks the whole
      // desktop by one factor and leaves every window where it actually is, at
      // its real relative size -- that is what makes it read as "your desktop,
      // smaller" instead of "a gallery of windows". Packing windows into equal
      // cells blew small windows up to the size of big ones and put everything
      // in the wrong place.
      //
      // Spreading overlapping windows apart, which macOS also does, is not
      // needed here: Hyprland tiles, so the windows on a workspace already do
      // not overlap. Floating ones can, and are left overlapping on purpose --
      // that is where they are.
      //
      // The margins are measured off a real Mission Control screenshot: a gap
      // under the Spaces strip of ~5.8% of the screen, ~10% left at the bottom
      // (macOS keeps the dock clear down there, and so do we), and a hair of
      // side padding. On a 16:10 screen that lands the scale near 0.68.
      readonly property real exposeGapTop: Math.round(panel.height * 0.058)
      readonly property real exposeGapBottom: Math.round(panel.height * 0.10)
      readonly property real exposeGapSide: Math.round(panel.width * 0.015)
      readonly property real exposeAreaX: exposeGapSide
      // Without the strip (App Exposé, Show Desktop) the area starts under
      // the bar.
      readonly property real exposeAreaY: (root.missionMode ? stripH : panel.barBand) + exposeGapTop
      readonly property real exposeAreaW: panel.width - exposeGapSide * 2
      readonly property real exposeAreaH: panel.height - exposeAreaY - exposeGapBottom

      // Quick Look (Space): the selected window grows to fill most of the
      // exposé area.
      readonly property real peekAreaX: exposeGapSide * 3
      readonly property real peekAreaY: exposeAreaY - exposeGapTop * 0.5
      readonly property real peekAreaW: panel.width - peekAreaX * 2
      readonly property real peekAreaH: panel.height - peekAreaY - exposeGapBottom * 0.5

      // Scale off the monitor's *usable* area, not the whole monitor. The bar
      // and the window gap mean a tiled window starts ~100px down; feeding the
      // full monitor rect in scaled that dead strip along with everything else
      // and pushed the windows a long way below the Spaces strip.
      // Careful: hyprctl reports a monitor's width/height in PHYSICAL pixels but
      // its reserved area in LOGICAL ones (it is the strip taken out of the
      // workspace coordinate space, which is where window rectangles live).
      // Verified against the bar, which measures 35 logical px and is reported
      // as 35. So this one is not divided by scale, unlike monW/monH above.
      readonly property var reserved: {
        const o = panel.hyprMonitor ? panel.hyprMonitor.lastIpcObject : null;
        return o && o.reserved ? o.reserved : [0, 0, 0, 0];
      }
      readonly property real usableW: Math.max(1, panel.monW - reserved[0] - reserved[2])
      readonly property real usableH: Math.max(1, panel.monH - reserved[1] - reserved[3])

      // The one scale every window shares.
      readonly property real shrink: Math.min(exposeAreaW / usableW, exposeAreaH / usableH)

      // Where the scaled desktop is pinned. Anchoring on the *windows* rather
      // than on the desktop rect is what makes the gap under the Spaces strip a
      // fixed ratio: whatever the bar reserves, the topmost window always lands
      // exposeGapTop below the strip. Horizontally the block is centred.
      function originFor(ws) {
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (let i = 0; i < ws.length; i++) {
          const o = ws[i].lastIpcObject;
          // Same live-binding hazard as the delegates: skip rather than throw.
          if (!o || !o.at || !o.size)
            continue;
          x0 = Math.min(x0, o.at[0]);
          y0 = Math.min(y0, o.at[1]);
          x1 = Math.max(x1, o.at[0] + o.size[0]);
          y1 = Math.max(y1, o.at[1] + o.size[1]);
        }
        if (x0 === Infinity)
          return { x: panel.exposeAreaX, y: panel.exposeAreaY };
        return {
          x: panel.exposeAreaX + (panel.exposeAreaW - (x1 - x0) * panel.shrink) / 2 - (x0 - panel.monX) * panel.shrink,
          y: panel.exposeAreaY - (y0 - panel.monY) * panel.shrink
        };
      }
      readonly property var origin: panel.originFor(panel.windows)
      readonly property real originX: origin.x
      readonly property real originY: origin.y

      // --- where each window goes ---------------------------------------------
      // One entry per panel.windows: { x, y, s, onScreen, minimized } -- the
      // overview rect's top-left and scale in this monitor's logical pixels.
      // One binding for all of them, so the layout is consistent whatever
      // changes it (mode, strip, a window closing).
      readonly property var layout: {
        const wins = panel.windows;
        if (root.appMode)
          return panel.packLayout(wins);
        if (root.desktopMode)
          return panel.edgeLayout(wins);
        const o = panel.originFor(wins);
        const out = [];
        for (let i = 0; i < wins.length; i++) {
          const ipc = wins[i].lastIpcObject;
          const at = ipc && ipc.at ? ipc.at : [0, 0];
          out.push({ x: o.x + (at[0] - panel.monX) * panel.shrink,
                     y: o.y + (at[1] - panel.monY) * panel.shrink,
                     s: panel.shrink, onScreen: true, minimized: false });
        }
        return out;
      }

      function sizeOf(t) {
        const o = t ? t.lastIpcObject : null;
        return o && o.size ? [Math.max(1, o.size[0]), Math.max(1, o.size[1])] : [1, 1];
      }

      // App Exposé: windows from several desktops have no common desktop to
      // shrink, so they are packed into rows -- most recent first, aspect
      // ratios kept, never enlarged (macOS). The row count that gives the
      // largest scale wins. Minimized windows go in their own, smaller row
      // along the bottom.
      function packLayout(wins) {
        const out = new Array(wins.length);
        const main = [], mini = [];
        for (let i = 0; i < wins.length; i++)
          (panel.isMinimized(wins[i]) ? mini : main).push(i);
        const gap = Math.round(28 * panel.uiScale);
        const bandH = mini.length > 0 ? Math.round(panel.exposeAreaH * 0.22) : 0;
        const placed = panel.packInto(wins, main, panel.exposeAreaX, panel.exposeAreaY,
                                      panel.exposeAreaW, panel.exposeAreaH - bandH, gap, 1);
        for (let i = 0; i < placed.length; i++)
          out[main[i]] = placed[i];
        if (mini.length > 0) {
          const row = panel.packInto(wins, mini, panel.exposeAreaX, panel.exposeAreaY + panel.exposeAreaH - bandH + gap,
                                     panel.exposeAreaW, bandH - gap, gap, 0.6);
          for (let i = 0; i < row.length; i++) {
            row[i].minimized = true;
            out[mini[i]] = row[i];
          }
        }
        const cur = panel.currentDesktop;
        for (let i = 0; i < wins.length; i++) {
          if (!out[i])
            out[i] = { x: panel.exposeAreaX, y: panel.exposeAreaY, s: 0.5, minimized: false };
          const ws = wins[i].workspace;
          out[i].onScreen = !!(cur && ws && ws.id === cur.id);
        }
        return out;
      }

      function packInto(wins, idx, ax, ay, aw, ah, gap, maxScale) {
        const n = idx.length;
        const out = [];
        if (n === 0 || aw <= 0 || ah <= 0)
          return out;
        const sizes = idx.map(i => panel.sizeOf(wins[i]));
        let best = null;
        for (let rows = 1; rows <= n; rows++) {
          const perRow = Math.ceil(n / rows);
          const rowList = [];
          for (let r = 0; r < rows; r++) {
            const row = sizes.slice(r * perRow, (r + 1) * perRow);
            if (row.length > 0)
              rowList.push(row);
          }
          let s = maxScale;
          let hSum = 0;
          for (let r = 0; r < rowList.length; r++) {
            let wSum = 0, hMax = 0;
            for (let k = 0; k < rowList[r].length; k++) {
              wSum += rowList[r][k][0];
              hMax = Math.max(hMax, rowList[r][k][1]);
            }
            s = Math.min(s, (aw - (rowList[r].length - 1) * gap) / wSum);
            hSum += hMax;
          }
          s = Math.min(s, (ah - (rowList.length - 1) * gap) / hSum);
          if (!best || s > best.s)
            best = { s: s, rows: rowList };
        }
        const s = Math.max(0.01, best.s);
        let blockH = (best.rows.length - 1) * gap;
        const rowH = [];
        for (let r = 0; r < best.rows.length; r++) {
          let hMax = 0;
          for (let k = 0; k < best.rows[r].length; k++)
            hMax = Math.max(hMax, best.rows[r][k][1] * s);
          rowH.push(hMax);
          blockH += hMax;
        }
        let y = ay + (ah - blockH) / 2;
        for (let r = 0; r < best.rows.length; r++) {
          const row = best.rows[r];
          let rowW = (row.length - 1) * gap;
          for (let k = 0; k < row.length; k++)
            rowW += row[k][0] * s;
          let x = ax + (aw - rowW) / 2;
          for (let k = 0; k < row.length; k++) {
            out.push({ x: Math.round(x), y: Math.round(y + (rowH[r] - row[k][1] * s) / 2), s: s, minimized: false });
            x += row[k][0] * s + gap;
          }
          y += rowH[r] + gap;
        }
        return out;
      }

      // Show Desktop: every window slides out to whichever screen edge is
      // nearest, leaving a sliver showing, so the wallpaper is clear.
      readonly property real edgeSliver: Math.round(panel.width * 0.03)
      function edgeLayout(wins) {
        const out = [];
        for (let i = 0; i < wins.length; i++) {
          const ipc = wins[i].lastIpcObject;
          const at = ipc && ipc.at ? ipc.at : [0, 0];
          const size = panel.sizeOf(wins[i]);
          const x = at[0] - panel.monX, y = at[1] - panel.monY;
          const cx = x + size[0] / 2, cy = y + size[1] / 2;
          const d = [cx, panel.monW - cx, cy, panel.monH - cy];
          let edge = 0;
          for (let k = 1; k < 4; k++)
            if (d[k] < d[edge])
              edge = k;
          const e = { x: x, y: y, s: 1, onScreen: true, minimized: false };
          if (edge === 0) e.x = -(size[0] - panel.edgeSliver);
          else if (edge === 1) e.x = panel.monW - panel.edgeSliver;
          else if (edge === 2) e.y = -(size[1] - panel.edgeSliver);
          else e.y = panel.monH - panel.edgeSliver;
          out.push(e);
        }
        return out;
      }

      // Icon and title sizes come off the screen, not off the window, so every
      // label in the view is the same size -- measured at ~2.3% and ~0.85% of
      // the screen width in the macOS shot.
      readonly property int iconSize: Math.max(18, Math.round(panel.width * 0.023))
      readonly property int titleSize: Math.max(10, Math.round(panel.width * 0.0085))

      // Everything here sits on the (dimmed) wallpaper, not on a theme surface,
      // so the ink is white like macOS Mission Control -- in every theme. The
      // theme foreground (dark in cupertino) would vanish against it.
      readonly property color overlayInk: "#ffffff"

      // Desktop thumbnails: henri-ui's control radius, scaled with the rest of
      // the overview geometry (which follows the screen, not the font).
      readonly property real thumbRadius: Style.space(Motion.radiusControl * panel.uiScale)

      // --- selection --------------------------------------------------------
      // Index into panel.windows; -1 when the desktop is empty.
      property int selected: panel.windows.length > 0 ? 0 : -1

      // Windows sit wherever they sit, so arrow keys pick the nearest one in
      // that direction rather than stepping through a grid. Distance is
      // weighted so a window that is roughly in line wins over one that is
      // nearer but far off to the side.
      // Off the overview layout, not the real desktop: in App Exposé the
      // windows come from several desktops and only their overview places
      // are comparable.
      function centreOf(i) {
        const l = panel.layout[i];
        const size = panel.sizeOf(panel.windows[i]);
        if (!l)
          return { x: 0, y: 0 };
        return { x: l.x + size[0] * l.s / 2, y: l.y + size[1] * l.s / 2 };
      }

      function move(dx, dy) {
        const n = panel.windows.length;
        if (n === 0)
          return;
        if (panel.selected < 0 || panel.selected >= n) {
          panel.selected = 0;
          return;
        }
        const from = panel.centreOf(panel.selected);
        let best = -1;
        let bestCost = Infinity;
        for (let i = 0; i < n; i++) {
          if (i === panel.selected)
            continue;
          const to = panel.centreOf(i);
          const along = (to.x - from.x) * dx + (to.y - from.y) * dy;
          if (along <= 0)
            continue;
          const across = Math.abs((to.x - from.x) * dy) + Math.abs((to.y - from.y) * dx);
          const cost = along + across * 2;
          if (cost < bestCost) {
            bestCost = cost;
            best = i;
          }
        }
        // Nothing that way: stay put rather than jumping to the far side.
        if (best >= 0)
          panel.selected = best;
      }

      // --- background -------------------------------------------------------
      // The wallpaper, blurred here in QML, with a dark tint over it.
      //
      // Sharp, not blurred. macOS does not blur the desktop in Mission Control
      // -- it shows the real wallpaper and shrinks the windows down onto it,
      // and only the Spaces strip along the top is a frosted band. An earlier
      // version blurred the whole screen, which was this project's own
      // invention rather than the thing it was copying.
      //
      // Nothing here is a compositor blur either, and nothing should become
      // one: a `blur = true` layer rule on a full-screen layer -- and equally
      // Quickshell's BackgroundEffect, which asks the compositor for the same
      // thing -- makes hyprbars' title bars flicker between transparent and
      // coloured every time they redraw, and
      // decoration:blur:new_optimizations = false does not stop it.
      // The desktop's top bar is a layer below ours. Where it sits, our copy
      // of the wallpaper starts transparent -- so the real bar stays visible --
      // and fades in as the Spaces strip slides over it. Covering it at once
      // made the bar vanish in one frame when a swipe began, and reappear in
      // one frame when the overview was gone.
      readonly property real barBand: Math.max(0, Math.min(panel.height, panel.reserved[1]))

      Item {
        anchors.fill: parent
        anchors.topMargin: panel.barBand
        clip: true
        Image {
          y: -panel.barBand
          width: panel.width
          height: panel.height
          source: wallpaper.source
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
        }
      }

      Item {
        width: panel.width
        height: panel.barBand
        clip: true
        Image {
          id: wallpaper
          // Only the bar band; the rest is the clipped copy above. Same source
          // and size, so both share one decoded image.
          width: panel.width
          height: panel.height
          opacity: root.stripProgress
          source: root.wallpaperSource
          fillMode: Image.PreserveAspectCrop
          // Do NOT add sourceSize here. Omarchy's wallpapers are 5K and the
          // obvious "decode it smaller" made the window *slower* to appear --
          // 505ms against 341ms -- because Qt still parses the whole JPEG and
          // then does a smooth scale on top. Matching the size on the strip
          // thumbnails so they share one cache entry did not recover it either
          // (496ms). Measured, twice.
          // Asynchronous. The helper checks the target is a bounded regular file
          // but cannot hold it -- the link can be replaced between that check and
          // this load -- so decoding off the main thread bounds the consequence
          // rather than the input: a late background instead of a shell that
          // renders and stops answering.
          asynchronous: true
          cache: true
        }
      }

      // A whisper of dim, so the shrunken windows have something to sit
      // against. Not the heavy scrim the blurred version needed.
      Rectangle {
        anchors.fill: parent
        color: "#0b0d14"
        // Grows with the shrink; a constant dim darkened the screen in one
        // step the moment a swipe began. Show Desktop does not dim: the
        // point of it is the desktop.
        opacity: (root.desktopMode ? 0 : 0.14) * Math.max(0, Math.min(1, root.progress))
      }

      // Click anywhere that is not a window or a desktop to dismiss. A
      // TapHandler, not a MouseArea: a MouseArea grabs the press outright and
      // any handler on a sibling never sees the gesture.
      TapHandler {
        onTapped: {
          if (panel.peek >= 0) panel.peek = -1;
          else root.dismiss();
        }
      }

      // Quick Look: index into panel.windows of the window shown large, -1
      // for none. Space toggles it on the selection.
      property int peek: -1
      function togglePeek() {
        if (panel.peek >= 0)
          panel.peek = -1;
        else if (panel.selected >= 0 && panel.selected < panel.windows.length && !root.desktopMode)
          panel.peek = panel.selected;
      }
      // Option held: the "x" shows on every desktop thumbnail (macOS).
      property bool altHeld: false

      // A window being dragged (index into panel.windows, -1 for none) and
      // where it would land: a strip slot, -1 for the "+", -2 for nowhere.
      property int dragWindow: -1
      property int dropSlot: -2
      function dropSlotAt(x, y) {
        if (!panel.stripExpanded || y > panel.stripH)
          return -2;
        if (panel.plusVisible && x >= panel.plusX - panel.stripGap / 2)
          return -1;
        const slot = Math.floor((x - panel.stripRowX + panel.stripGap / 2) / panel.stripPitch);
        if (slot < 0 || slot >= panel.slotIds.length)
          return -2;
        // Its own desktop is not a destination.
        if (panel.currentDesktop && panel.slotIds[slot] === panel.currentDesktop.id)
          return -2;
        return slot;
      }

      Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: {
          // On a Quick Look, Escape first puts the window back (drill-in rule:
          // Escape goes one level up before it closes).
          if (panel.peek >= 0) panel.peek = -1;
          else root.dismiss();
        }
        // Left/right walk the Spaces strip and actually switch desktop, without
        // closing -- the exposé below follows, so you can flick through the
        // desktops and only then pick a window. Up/down move between the
        // windows of whichever desktop you landed on. App Exposé has no strip,
        // so there left/right move between its windows instead.
        Keys.onLeftPressed: { if (root.missionMode) panel.stepDesktop(-1); else { root.showSelection = true; panel.move(-1, 0) } }
        Keys.onRightPressed: { if (root.missionMode) panel.stepDesktop(1); else { root.showSelection = true; panel.move(1, 0) } }
        Keys.onUpPressed: { root.showSelection = true; panel.move(0, -1) }
        Keys.onDownPressed: { root.showSelection = true; panel.move(0, 1) }
        // Tab: the next window; in App Exposé the next app (macOS).
        Keys.onTabPressed: { root.showSelection = true; if (root.appMode) panel.nextApp(1); else panel.cycleWindow() }
        Keys.onBacktabPressed: { root.showSelection = true; if (root.appMode) panel.nextApp(-1); else panel.cycleWindow() }
        Keys.onSpacePressed: { root.showSelection = true; panel.togglePeek() }
        Keys.onReturnPressed: panel.activateSelection()
        Keys.onEnterPressed: panel.activateSelection()
        Keys.onReleased: event => {
          if (event.key === Qt.Key_Alt) { panel.altHeld = false; event.accepted = true }
        }

        // Keys.onPressed runs before the named handlers above, so this is where
        // anything that has to win over plain arrow navigation goes.
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Alt) {
            panel.altHeld = true;
            event.accepted = true;
            return;
          }
          // CTRL+DOWN closes, mirroring the CTRL+UP that opened it. There is a
          // Hyprland bind for this too -- a modifier pressed on a virtual
          // keyboard does not reliably reach a client through an
          // exclusive-focus layer, so the compositor bind is the one that is
          // guaranteed to fire and this is the belt to its braces.
          if ((event.modifiers & Qt.ControlModifier)
              && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
            root.dismiss();
            event.accepted = true;
            return;
          }
          // Number keys jump straight to a desktop, like SUPER+n does normally.
          if (root.missionMode && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const want = event.key - Qt.Key_0;
            for (let i = 0; i < panel.desktops.length; i++) {
              if (panel.desktops[i].id === want) {
                root.goToWorkspace(want);
                event.accepted = true;
                return;
              }
            }
          }
        }
      }

      // Switch desktop but stay open. Not goToWorkspace(), which quits: the
      // point of walking the strip is to look before you leap.
      function stepDesktop(dir) {
        const n = panel.desktops.length;
        if (n === 0)
          return;
        let i = 0;
        for (let k = 0; k < n; k++)
          if (panel.desktops[k].focused)
            i = k;
        const next = panel.desktops[(i + dir + n) % n];
        const target = root.safeWorkspaceId(next.id);
        if (target === "")
          return;
        root.slidePendingDir = dir;
        root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })",
                      "workspace " + target);
      }

      function cycleWindow() {
        const n = panel.windows.length;
        if (n > 0)
          panel.selected = (panel.selected + 1 + n) % n;
      }

      // Landing on another desktop starts its selection over; without this the
      // index left over from the previous desktop points at nothing.
      onWindowsChanged: {
        panel.selected = panel.windows.length > 0 ? 0 : -1;
        panel.peek = -1;
      }

      function activateSelection() {
        if (panel.selected >= 0 && panel.selected < panel.windows.length)
          root.focusWindow(String(panel.windows[panel.selected].address));
        else
          root.dismiss();
      }

      // Everything eases in together rather than the contents popping in over a
      // static background -- the two-step open is the thing that gives away
      // that this is a separate process and not the compositor.
      Item {
        id: stage
        anchors.fill: parent
        // No fade and no scale on the whole stage any more. The motion lives on
        // the individual windows (real rect -> shrunken rect) and on the strip
        // sliding in from above; fading the lot on top of that made the open
        // look like a cross-dissolve between two screens instead of one screen
        // shrinking.

        // --- Spaces strip ---------------------------------------------------
        // Only Mission Control has the strip. A mode switch while up slides
        // it in or out on its own spring; on open it rides the progress.
        HUi.SpringValue {
          id: stripIn
          to: root.missionMode ? 1 : 0
          preset: Motion.smooth
        }
        Connections {
          target: root
          function onShownChanged() { if (root.shown) stripIn.snap(stripIn.to) }
        }

        Rectangle {
          id: strip
          width: parent.width
          height: panel.stripH
          // Slides down from off-screen as the desktop shrinks to make room for
          // it, which is where macOS puts the motion. Driven by stripProgress,
          // which holds it in place on a non-swipe close -- see stripHold.
          readonly property real reveal: root.stripProgress * stripIn.value
          y: root.lerp(-panel.stripH, 0, strip.reveal)
          opacity: strip.reveal
          visible: strip.reveal > 0.001
          color: Qt.rgba(1, 1, 1, 0.07)

          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Util.alpha(panel.overlayInk, Motion.hairlineAlpha)
          }

          // The pointer touching the strip unfolds it. Not before the windows
          // have settled: while they are still shrinking the strip is sliding
          // in under a stationary pointer, which is not a touch.
          HoverHandler {
            id: stripHover
            onHoveredChanged: if (hovered && root.settled) panel.stripExpanded = true
          }

          // Top of the thumbnail row, centred in the unfolded strip.
          readonly property real rowY:
              Math.round((panel.stripFullH - panel.stripTileH - panel.stripLabelBand) / 2)
          // Where the labels sit while the strip is folded: on their own,
          // centred in the band.
          readonly property real foldedLabelY: Math.round((panel.stripCollapsedH - panel.stripLabelBand) / 2)

          // Labels belong to the SLOTS, not to the thumbnails: a desktop's
          // number is its place, so dragging a thumbnail carries its windows
          // along and leaves the numbering in order -- as in macOS. The bright
          // label marks where the desktop you are on is (or will be) sitting.
          Repeater {
            model: panel.slotIds.length

            delegate: Text {
              id: slotLabel
              required property int index
              readonly property int wsId: panel.slotIds[slotLabel.index] ?? -1
              readonly property var desk: panel.deskById(slotLabel.wsId)
              readonly property bool marked: panel.displayOrder[slotLabel.index] === panel.focusedTile
              x: panel.stripRowX + slotLabel.index * panel.stripPitch
              // Folded: on their own in the band. Unfolding, they move down
              // under the thumbnails growing out of them.
              y: root.lerp(strip.foldedLabelY, strip.rowY + panel.stripTileH, stripOpen.value)
              width: panel.stripTileW
              height: panel.stripLabelBand
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              // Same treatment as the window title: a workspace name is
              // configuration-supplied text, not markup.
              textFormat: Text.PlainText
              text: root.displayLabel(slotLabel.desk ? (slotLabel.desk.name || slotLabel.desk.id) : slotLabel.wsId)
              // An explicit sans face: the system's default `sans` resolves
              // to Comic Code here, a monospace whose digits look like kana
              // once they are scaled up.
              font.family: root.fontFamily
              font.pixelSize: panel.stripLabelSize
              color: slotLabel.marked ? panel.overlayInk
                                      : Util.alpha(panel.overlayInk, Motion.secondaryTextAlpha)
              Behavior on color {
                ColorAnimation {
                  duration: slotLabel.marked ? Motion.instant : Motion.fast
                  easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                }
              }
              style: Text.Raised
              styleColor: Qt.rgba(0, 0, 0, 0.55)
            }
          }

          Repeater {
            model: panel.slotIds.length

            delegate: Item {
              id: deskCell
              required property int index
              width: panel.stripTileW
              height: panel.stripTileH

              // The slot this tile's windows belong to (committed order), and
              // the slot it is drawn at (with a drag in progress).
              readonly property int homeSlot: panel.tileOrder.indexOf(deskCell.index)
              readonly property int shownSlot: panel.displayOrder.indexOf(deskCell.index)
              readonly property int wsId: deskCell.homeSlot >= 0 ? (panel.slotIds[deskCell.homeSlot] ?? -1) : -1
              readonly property var desk: panel.deskById(deskCell.wsId)
              readonly property bool isFocused: panel.focusedTile === deskCell.index

              // --- drag to reorder ---------------------------------------
              readonly property bool held: deskDrag.active
              // Released and still flying home: stays on top of its neighbours.
              property bool landing: false
              property real dragHomeX: 0
              property real dragOriginX: 0
              property real dragOriginY: 0
              property real dragDX: 0
              property real dragDY: 0
              readonly property real slotX: panel.stripRowX + Math.max(0, deskCell.shownSlot) * panel.stripPitch

              // Held: pinned to the pointer. Otherwise the tile glides to its
              // slot -- smooth for the neighbours making room, snappy for the
              // dropped one settling in, carrying the release speed.
              HUi.SpringValue {
                id: xSpring
                to: deskCell.held ? deskCell.dragHomeX + deskCell.dragDX : deskCell.slotX
                preset: deskCell.held || deskCell.landing ? Motion.snappy : Motion.smooth
                epsilon: 0.5
                onRunningChanged: deskCell.checkLanded()
              }
              HUi.SpringValue {
                id: ySpring
                to: deskCell.held ? deskCell.dragDY : 0
                preset: Motion.snappy
                epsilon: 0.5
                onRunningChanged: deskCell.checkLanded()
              }
              HUi.SpringValue {
                id: liftSpring
                to: deskCell.held ? Motion.liftScale : 1
                preset: Motion.snappy
              }

              function checkLanded() {
                if (!xSpring.running && !ySpring.running)
                  deskCell.landing = false;
              }

              Connections {
                target: panel
                function onTilesSnap() {
                  xSpring.snap(xSpring.to);
                  ySpring.snap(ySpring.to);
                  deskCell.landing = false;
                }
              }

              x: xSpring.value
              y: strip.rowY + ySpring.value
              z: deskCell.held || deskCell.landing ? 2 : 0
              // Folded away: the thumbnails grow out of their labels as the
              // strip unfolds (macOS), so they scale up from the bottom.
              transformOrigin: Item.Bottom
              scale: liftSpring.value * root.lerp(0.6, 1, stripOpen.value)
              opacity: stripOpen.value
              visible: stripOpen.value > 0.001

              // A window being dragged over this desktop: it stands out.
              readonly property bool dropHover: panel.dragWindow >= 0 && panel.dropSlot === deskCell.shownSlot

              property var deskWindows: []
              // Held during a reorder -- the tile keeps showing what it showed
              // until Hyprland has moved the windows to match it.
              onDeskWindowsLiveChanged: if (!panel.reorderPending && !root.sameList(deskCell.deskWindows, deskCell.deskWindowsLive)) deskCell.deskWindows = deskCell.deskWindowsLive
              Component.onCompleted: deskCell.deskWindows = deskCell.deskWindowsLive
              Connections {
                target: panel
                // Same windows, maybe in a new stacking order: keep the array,
                // or every capture in the tile is rebuilt and blanks for frames.
                function onReorderPendingChanged() {
                  if (!panel.reorderPending && !root.sameSet(deskCell.deskWindows, deskCell.deskWindowsLive))
                    deskCell.deskWindows = deskCell.deskWindowsLive;
                }
              }
              readonly property var deskWindowsLive: {
                const out = [];
                const tls = deskCell.desk && deskCell.desk.toplevels ? (deskCell.desk.toplevels.values || []) : [];
                for (let i = 0; i < tls.length; i++) {
                  const t = tls[i];
                  const o = t.lastIpcObject;
                  if (!t.wayland || !o || o.mapped === false || o.hidden === true)
                    continue;
                  out.push(t);
                }
                // Back to front: the window you last used ends up on top,
                // which is where it is on the real desktop.
                out.sort((a, b) => (b.lastIpcObject.focusHistoryID || 0) - (a.lastIpcObject.focusHistoryID || 0));
                return out;
              }

              Item {
                id: thumb
                width: panel.stripTileW
                height: panel.stripTileH

                // Rounded corners the only way QtQuick offers for arbitrary
                // content: render the tile to a texture and mask it with a
                // rounded rectangle. `clip: true` would only ever cut a square.
                Item {
                  anchors.fill: parent
                  layer.enabled: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: thumbMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                  }

                  // Every desktop shows the wallpaper, windows or not -- that
                  // is what makes an empty one read as "an empty desktop"
                  // rather than as a hole in the strip.
                  Image {
                    anchors.fill: parent
                    source: wallpaper.source
                    fillMode: Image.PreserveAspectCrop
                    // No sourceSize -- same source and same (absent) size as
                    // the background image, so this is a cache hit. See the
                    // note there for why asking for a smaller decode is a
                    // pessimisation, not an optimisation.
                    asynchronous: false
                    cache: true
                    smooth: true
                  }

                  Repeater {
                    model: deskCell.deskWindows

                    delegate: ScreencopyView {
                      required property var modelData
                      readonly property var ipc: modelData.lastIpcObject
                      readonly property real k: panel.stripTileW / panel.monW

                      // lastIpcObject goes undefined for a beat -- a toplevel
                      // Hyprland has announced but not yet described, or one
                      // being torn down while the model still holds it. The
                      // model filter cannot prevent that: it runs once, and
                      // these are live bindings that re-evaluate afterwards.
                      // Unguarded they throw on `.at[0]` and flood the log at
                      // shell startup, when every window is announced at once.
                      readonly property var at: (ipc && ipc.at) ? ipc.at : [0, 0]
                      readonly property var size: (ipc && ipc.size) ? ipc.size : [0, 0]

                      x: (at[0] - panel.monX) * k
                      y: (at[1] - panel.monY) * k
                      width: size[0] * k
                      height: size[1] * k

                      // No capture source at all while hidden. ScreencopyView
                      // requests a frame from the compositor the moment it has
                      // a source, regardless of `live`, so a bare
                      // `captureSource` here means every screen change (or
                      // shell start) fires one capture per window while the
                      // overlay is not even visible. Null tears the context
                      // down; `shown` flipping true creates it and captures.
                      // Nor while the strip is folded: nothing of it shows,
                      // and most opens never unfold it.
                      captureSource: root.shown && panel.stripExpanded ? modelData.wayland : null
                      // Live, but only while shown. This plugin stays
                      // mounted, so an unconditional `live: true` would keep
                      // pulling frames of every window on every workspace
                      // forever, for a view nobody is looking at.
                      //
                      // A one-shot `live: false` + captureFrame() on open was
                      // tried, to cut the cost of capturing every window on
                      // every desktop. Reverted: the high CPU that motivated
                      // it turned out to be an artifact of measuring while a
                      // terminal was animating on the captured desktop, not a
                      // standing cost -- and one-shot capture of an
                      // *off-screen* toplevel is unverified, where live
                      // capture of one is measured and works. Do not
                      // reintroduce it without a window open on another
                      // workspace to test against.
                      // ...and not until the shrink has finished: every
                      // frame of another desktop is a render Hyprland does
                      // just for us, and doing that for all desktops while
                      // the windows are moving is what dropped frames. The
                      // source above still takes one frame straight away.
                      live: root.shown && root.settled && panel.stripExpanded
                      paintCursor: false
                    }
                  }

                  Rectangle {
                    anchors.fill: parent
                    color: "#05060a"
                    opacity: deskCell.isFocused ? 0.0 : (deskHover.hovered || deskCell.held || deskCell.dropHover ? 0.10 : 0.28)
                    Behavior on opacity {
                      NumberAnimation {
                        duration: deskHover.hovered ? Motion.instant : Motion.fast
                        easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                      }
                    }
                  }
                }

                Item {
                  id: thumbMask
                  anchors.fill: parent
                  layer.enabled: true
                  visible: false
                  Rectangle {
                    anchors.fill: parent
                    radius: panel.thumbRadius
                    color: "black"
                  }
                }

                // One border at three brightnesses -- the desktop you are on,
                // the one under the cursor, the rest. A second colour here
                // would read as a second meaning.
                Rectangle {
                  anchors.fill: parent
                  radius: panel.thumbRadius
                  color: Util.alpha(panel.overlayInk, 0)
                  border.width: Math.max(1, Math.round(2 * panel.uiScale))
                  border.color: deskCell.dropHover ? Color.accent
                              : deskCell.isFocused ? Util.alpha(panel.overlayInk, 0.96)
                              : deskHover.hovered || deskCell.held ? Util.alpha(panel.overlayInk, 0.55)
                              : Util.alpha(panel.overlayInk, 0.16)
                  Behavior on border.color {
                    ColorAnimation {
                      duration: deskHover.hovered ? Motion.instant : Motion.fast
                      easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                    }
                  }
                }

                // The "x" that removes this desktop: top-left, on hover, or on
                // every thumbnail while Option is held (macOS). Never on the
                // last remaining desktop. A MouseArea, so the press stops here
                // and does not also switch to the desktop underneath.
                Rectangle {
                  id: closeBadge
                  readonly property bool wanted: panel.slotIds.length > 1 && Hyprland.usingLua && !deskCell.held
                      && ((deskHover.hovered && stripOpen.value > 0.9) || panel.altHeld)
                  width: Math.max(Motion.controlMin, Math.round(22 * panel.uiScale))
                  height: width
                  radius: width / 2
                  x: -Math.round(width * 0.35)
                  y: -Math.round(width * 0.35)
                  z: 3
                  color: badgeArea.pressed ? "#c8c8cc" : badgeArea.containsMouse ? "#ffffff" : "#ececef"
                  border.width: 1
                  border.color: Qt.rgba(0, 0, 0, 0.25)
                  opacity: closeBadge.wanted ? 1 : 0
                  visible: opacity > 0.001
                  scale: closeBadge.wanted ? 1 : Motion.iconFromScale
                  Behavior on opacity {
                    NumberAnimation {
                      duration: closeBadge.wanted ? Motion.instant : Motion.fast
                      easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                    }
                  }
                  Behavior on scale {
                    NumberAnimation {
                      duration: closeBadge.wanted ? Motion.instant : Motion.fast
                      easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                    }
                  }
                  Behavior on color {
                    ColorAnimation {
                      duration: badgeArea.containsMouse ? Motion.instant : Motion.fast
                      easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                    }
                  }
                  Text {
                    anchors.centerIn: parent
                    text: "\u00d7"
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(closeBadge.width * 0.72)
                    color: "#1d1d1f"
                  }
                  MouseArea {
                    id: badgeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: if (deskCell.wsId >= 0) panel.removeDesktop(deskCell.wsId)
                  }
                }

                HoverHandler { id: deskHover }
                TapHandler { onTapped: if (deskCell.wsId >= 0) root.goToWorkspace(deskCell.wsId) }

                // Positions are read off the scene, not the handler's own
                // translation: the tile moves under the pointer, and a
                // translation measured in the tile's coordinates would chase
                // itself. The offset is taken from where the drag ACTIVATED,
                // so the tile does not jump by the drag threshold.
                DragHandler {
                  id: deskDrag
                  target: null
                  enabled: panel.slotIds.length > 1 && root.settled && !panel.reorderPending && Hyprland.usingLua
                      && panel.stripExpanded && panel.dragWindow < 0
                  cursorShape: Qt.ClosedHandCursor
                  onActiveChanged: {
                    if (active) {
                      deskCell.dragHomeX = xSpring.value;
                      deskCell.dragOriginX = centroid.scenePosition.x;
                      deskCell.dragOriginY = centroid.scenePosition.y;
                      deskCell.dragDX = 0;
                      deskCell.dragDY = 0;
                      xSpring.snap(xSpring.to);
                      ySpring.snap(ySpring.to);
                      panel.dragTile = deskCell.index;
                      panel.dragSlot = deskCell.homeSlot;
                    } else {
                      deskCell.landing = true;
                      const cap = Motion.maximumFlickVelocity;
                      xSpring.velocity = Math.max(-cap, Math.min(cap, centroid.velocity.x));
                      ySpring.velocity = Math.max(-cap, Math.min(cap, centroid.velocity.y));
                      panel.endDrag(deskCell.index);
                    }
                  }
                  onCentroidChanged: {
                    if (!active)
                      return;
                    deskCell.dragDX = centroid.scenePosition.x - deskCell.dragOriginX;
                    deskCell.dragDY = centroid.scenePosition.y - deskCell.dragOriginY;
                    xSpring.snap(xSpring.to);
                    ySpring.snap(ySpring.to);
                    // The slot under the tile's centre.
                    const centre = deskCell.dragHomeX + deskCell.dragDX + panel.stripTileW / 2;
                    const slot = Math.floor((centre - panel.stripRowX + panel.stripGap / 2) / panel.stripPitch);
                    panel.dragSlot = Math.max(0, Math.min(panel.slotIds.length - 1, slot));
                  }
                }

                scale: deskHover.hovered && !deskCell.held ? 1.03 : 1.0
                Behavior on scale {
                  NumberAnimation {
                    duration: deskHover.hovered ? Motion.instant : Motion.fast
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                  }
                }
              }
            }
          }

          // "+" at the right edge: a new desktop after the last one (macOS).
          // Unfolds with the thumbnails, and lights up under a dragged window.
          Rectangle {
            id: plusTile
            readonly property bool dropHover: panel.dragWindow >= 0 && panel.dropSlot === -1
            readonly property bool lit: plusHover.hovered || plusTile.dropHover
            x: panel.plusX
            y: strip.rowY
            width: panel.plusW
            height: panel.stripTileH
            radius: panel.thumbRadius
            color: Util.alpha(panel.overlayInk, plusTap.pressed ? 0.28 : plusTile.lit ? 0.22 : 0.12)
            border.width: Math.max(1, Math.round(2 * panel.uiScale))
            border.color: plusTile.dropHover ? Color.accent
                        : Util.alpha(panel.overlayInk, plusTile.lit ? 0.55 : 0.16)
            opacity: stripOpen.value * (panel.plusVisible ? 1 : 0)
            visible: opacity > 0.001
            transformOrigin: Item.Bottom
            scale: root.lerp(0.6, 1, stripOpen.value) * (plusTap.pressed ? Motion.pressScale : 1)
            Behavior on color {
              ColorAnimation {
                duration: plusTile.lit ? Motion.instant : Motion.fast
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
              }
            }
            Behavior on border.color {
              ColorAnimation {
                duration: plusTile.lit ? Motion.instant : Motion.fast
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
              }
            }
            Text {
              anchors.centerIn: parent
              text: "+"
              font.family: root.fontFamily
              // Guarded: the tile height is NaN for a frame before the panel
              // has a size, and a NaN pixel size is a warning per frame.
              font.pixelSize: Math.max(8, Math.round(isFinite(panel.stripTileH) ? panel.stripTileH * 0.45 : 8))
              color: panel.overlayInk
              style: Text.Raised
              styleColor: Qt.rgba(0, 0, 0, 0.35)
            }
            HoverHandler { id: plusHover }
            TapHandler {
              id: plusTap
              onTapped: panel.addDesktop()
            }
          }
        }

        // The current desktop's exposé rides on the sideways swipe.
        Item {
          id: exposeLayer
          x: panel.slideX
          width: parent.width
          height: parent.height

          // --- exposé of the current desktop ----------------------------------
          Repeater {
            id: exposeRepeater
            model: panel.windows

            delegate: Item {
              id: win
              required property var modelData
              required property int index
              readonly property var ipc: modelData.lastIpcObject
              readonly property bool isSelected: panel.selected === win.index
              readonly property bool captureReady: copy.hasContent
              function recapture() {
                if (copy.hasContent || copy.captureSource)
                  copy.captureFrame();
              }

              // Two rects per window, and the animation between them is the
              // whole effect.
              //
              // "real" is where the window is on the actual desktop: this layer
              // covers the screen one-to-one and the wallpaper underneath is the
              // real one, so a window drawn here at scale 1 sits exactly on top
              // of itself. That is the frame the open starts from, which is why
              // it reads as the desktop shrinking rather than a new screen
              // appearing.
              //
              // "target" is its place in the overview, out of panel.layout: the
              // same position and size scaled by the one factor every window
              // shares (Mission Control), a packed row (App Exposé) or a
              // screen edge (Show Desktop).
              // Screen-relative: what Hyprland reports, minus this monitor's
              // origin. The overview layout is built in this space.
              // Guarded for the same reason as the strip thumbnails above:
              // lastIpcObject can go undefined under a live binding.
              readonly property var at: (ipc && ipc.at) ? ipc.at : [0, 0]
              readonly property var size: (ipc && ipc.size) ? ipc.size : [0, 0]

              readonly property real screenX: at[0] - panel.monX
              readonly property real screenY: at[1] - panel.monY
              readonly property real realW: size[0]
              readonly property real realH: size[1]

              readonly property var slot: panel.layout[win.index]
                  || ({ x: win.screenX, y: win.screenY, s: 1, onScreen: true, minimized: false })
              // On the real screen right now? Windows from other desktops (App
              // Exposé) are not: they have no rect to start from, so they are
              // born at their overview place and fade in there instead.
              readonly property bool onScreen: win.slot.onScreen !== false
              readonly property real realX: win.onScreen ? win.screenX : win.slot.x
              readonly property real realY: win.onScreen ? win.screenY : win.slot.y

              // The overview rect glides when the layout changes while the
              // overview is up -- the strip unfolding, a mode switch, a window
              // closing -- on springs, so an interrupted move keeps its speed.
              // Snapped on open: there the shrink itself is the animation.
              HUi.SpringValue { id: tX; to: win.slot.x; preset: Motion.smooth; epsilon: 0.5 }
              HUi.SpringValue { id: tY; to: win.slot.y; preset: Motion.smooth; epsilon: 0.5 }
              HUi.SpringValue { id: tS; to: win.slot.s; preset: Motion.smooth }
              // Every spring here is a FrameAnimation, and a hidden window
              // renders no frames: a target that moved while the overview was
              // hidden (a window resized, the strip folding on close, a Quick
              // Look interrupted) leaves the spring stuck at its old value
              // until the next open -- when it then glides from there, which
              // read as the windows jumping off towards a corner at the start
              // of a swipe. So: snapped on open, and snapped on every layout
              // change until the overview has settled. Only a settled
              // overview glides (the strip unfolding, a mode switch, a drag).
              function snapTarget() {
                tX.snap(tX.to);
                tY.snap(tY.to);
                tS.snap(tS.to);
                peekT.snap(peekT.to);
                dX.snap(dX.to);
                dY.snap(dY.to);
                dS.snap(dS.to);
              }
              Connections {
                target: root
                function onShownChanged() { if (root.shown) win.snapTarget() }
              }
              Connections {
                target: panel
                function onLayoutChanged() { if (!root.settled) win.snapTarget() }
              }
              readonly property real targetX: tX.value
              readonly property real targetY: tY.value
              readonly property real targetS: tS.value
              readonly property real targetW: win.realW * win.targetS
              readonly property real targetH: win.realH * win.targetS

              // Quick Look (Space): grown to fill most of the exposé area, never
              // past its real size.
              readonly property bool peeking: panel.peek === win.index
              HUi.SpringValue { id: peekT; to: win.peeking ? 1 : 0; preset: Motion.smooth }
              readonly property real peekS: Math.min(1, panel.peekAreaW / Math.max(1, win.realW),
                                                     panel.peekAreaH / Math.max(1, win.realH))
              readonly property real peekX: panel.peekAreaX + (panel.peekAreaW - win.realW * win.peekS) / 2
              readonly property real peekY: panel.peekAreaY + (panel.peekAreaH - win.realH * win.peekS) / 2

              // Drag to a desktop in the strip. The offset is measured from
              // where the drag activated, so the window does not jump by the
              // drag threshold; while held it is pinned to the pointer, dropped
              // anywhere else it springs home with the release speed, dropped
              // on a desktop it stays there and dissolves (Hyprland moves the
              // real window, and this copy leaves with it).
              readonly property bool held: winDrag.active
              property bool landing: false
              property bool dropped: false
              property real dragOriginX: 0
              property real dragOriginY: 0
              property real dragDX: 0
              property real dragDY: 0
              HUi.SpringValue {
                id: dX
                to: win.held || win.dropped ? win.dragDX : 0
                preset: Motion.snappy
                epsilon: 0.5
                onRunningChanged: win.checkLanded()
              }
              HUi.SpringValue {
                id: dY
                to: win.held || win.dropped ? win.dragDY : 0
                preset: Motion.snappy
                epsilon: 0.5
                onRunningChanged: win.checkLanded()
              }
              // Over the strip the dragged window shrinks towards thumbnail
              // size, about its centre, so it shrinks under the pointer.
              readonly property bool overStrip: (win.held || win.dropped) && panel.dropSlot !== -2
              HUi.SpringValue {
                id: dS
                to: win.overStrip ? Math.min(1, (panel.stripTileW / panel.monW) / Math.max(0.01, win.targetS)) : 1
                preset: Motion.smooth
              }
              function checkLanded() {
                if (!dX.running && !dY.running)
                  win.landing = false;
              }

              // The rect on screen this frame: open/close progress first, then
              // Quick Look, then the drag.
              readonly property real p: root.progress
              readonly property real ovX: root.lerp(win.realX, win.targetX, win.p)
              readonly property real ovY: root.lerp(win.realY, win.targetY, win.p)
              readonly property real ovS: root.lerp(win.onScreen ? 1 : win.targetS * 0.92, win.targetS, win.p)
              readonly property real baseS: root.lerp(win.ovS, win.peekS, peekT.value)
              readonly property real fs: win.baseS * dS.value
              readonly property real fx: root.lerp(win.ovX, win.peekX, peekT.value) + dX.value + win.realW * (win.baseS - win.fs) / 2
              readonly property real fy: root.lerp(win.ovY, win.peekY, peekT.value) + dY.value + win.realH * (win.baseS - win.fs) / 2
              readonly property real fw: win.realW * win.fs
              readonly property real fh: win.realH * win.fs

              // Labels and the selection ring belong to the overview, so they
              // sit at the overview rect and fade in over the last stretch of
              // the shrink instead of riding down at full size. Show Desktop
              // has no labels: the windows are on their way out.
              readonly property real labelOpacity: root.desktopMode ? 0
                  : Math.max(0, Math.min(1, (root.progress - 0.55) / 0.45))

              // Born while the overview was already up (a window opened, Tab
              // to another app): fades in rather than popping.
              property real born: 1
              Component.onCompleted: {
                win.snapTarget();
                if (root.settled) {
                  win.born = 0;
                  bornIn.start();
                }
              }
              NumberAnimation {
                id: bornIn
                target: win
                property: "born"
                to: 1
                duration: Motion.fast
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Motion.easeOut
              }

              z: win.held || win.landing || win.dropped || win.peeking ? 2 : 0

              // The window itself. Its size never changes -- it stays at the real
              // size and is moved and scaled with a transform. Animating
              // width/height (as before) re-laid-out the capture, ring, icon and
              // title every frame; a transform is just a matrix on the GPU. Scale
              // is uniform, so this is the same motion as before, only cheaper.
              Item {
                id: body
                x: win.fx
                y: win.fy
                width: win.realW
                height: win.realH
                transform: Scale {
                  xScale: win.fs
                  yScale: win.fs
                }
                // Off-screen windows fade in with the open; a minimized one
                // sits a little dimmer in its row; a dropped one dissolves
                // into the desktop it was dropped on.
                opacity: (win.onScreen ? 1 : win.p) * win.born * (win.slot.minimized ? 0.75 : 1) * (win.dropped ? 0 : 1)
                Behavior on opacity {
                  enabled: win.dropped
                  NumberAnimation {
                    duration: Motion.fast
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeExit
                  }
                }

                // Hyprland's border, drawn outside the window like Hyprland does.
                // Fades out over the shrink: in the overview windows are bare.
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -root.decoBorder
                  radius: root.decoRounding + root.decoBorder
                  color: "transparent"
                  border.width: root.decoBorder
                  border.color: win.modelData.activated ? root.decoActive : root.decoInactive
                  opacity: Math.max(0, 1 - root.progress * 2)
                  visible: win.onScreen && opacity > 0 && root.decoBorder > 0
                  scale: shot.scale
                }

                Item {
                  id: shot
                  anchors.fill: parent

                  // Rounded like the real window. The layer also gives the
                  // scaled-down copy smooth filtering instead of shimmering.
                  layer.enabled: root.decoRounding > 0
                  layer.smooth: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: winMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                  }

                  ScreencopyView {
                    id: copy
                    anchors.fill: parent
                    // Kept alive while hidden, unlike the strip thumbnails. A
                    // context created on open delivers its first buffer 2-3
                    // frames after the surface maps, and until then the window
                    // is simply missing from the screen -- measured off a 60fps
                    // capture of every open. These are only the current
                    // desktop's windows, so a live context costs one capture on
                    // creation and one per refresh below, nothing per frame.
                    captureSource: win.modelData.wayland
                    live: root.shown
                    paintCursor: false
                  }

                  scale: win.isSelected && root.settled && root.showSelection && !win.peeking && !win.held ? 1.02 : 1.0
                  Behavior on scale {
                    NumberAnimation {
                      duration: win.isSelected ? Motion.instant : Motion.fast
                      easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                    }
                  }
                }

                Item {
                  id: winMask
                  anchors.fill: parent
                  layer.enabled: true
                  visible: false
                  Rectangle {
                    anchors.fill: parent
                    radius: root.decoRounding
                    color: "black"
                  }
                }

                HoverHandler {
                  id: winHover
                  // Only once the windows have settled: during the shrink they are
                  // sliding under a stationary pointer, so every window they pass
                  // under would grab the selection.
                  onHoveredChanged: if (hovered && root.settled && Math.abs(root.slide) < 0.01 && panel.dragWindow < 0) {
                    root.showSelection = true;
                    panel.selected = win.index;
                  }
                }

                TapHandler {
                  onTapped: root.focusWindow(String(win.modelData.address))
                }

                DragHandler {
                  id: winDrag
                  target: null
                  enabled: root.settled && root.missionMode && panel.peek < 0 && Hyprland.usingLua
                      && panel.dragTile < 0 && !win.dropped
                  cursorShape: Qt.ClosedHandCursor
                  onActiveChanged: {
                    if (active) {
                      win.dragOriginX = centroid.scenePosition.x;
                      win.dragOriginY = centroid.scenePosition.y;
                      win.dragDX = 0;
                      win.dragDY = 0;
                      dX.snap(0);
                      dY.snap(0);
                      panel.dragWindow = win.index;
                      panel.dropSlot = -2;
                    } else {
                      const slot = panel.dropSlot;
                      panel.dragWindow = -1;
                      if (slot !== -2) {
                        win.dropped = true;
                        panel.moveWindowToSlot(String(win.modelData.address), slot);
                      } else {
                        win.landing = true;
                        const cap = Motion.maximumFlickVelocity;
                        dX.velocity = Math.max(-cap, Math.min(cap, centroid.velocity.x));
                        dY.velocity = Math.max(-cap, Math.min(cap, centroid.velocity.y));
                      }
                      panel.dropSlot = -2;
                    }
                  }
                  onCentroidChanged: {
                    if (!active)
                      return;
                    win.dragDX = centroid.scenePosition.x - win.dragOriginX;
                    win.dragDY = centroid.scenePosition.y - win.dragOriginY;
                    dX.snap(dX.to);
                    dY.snap(dY.to);
                    // Carried towards the strip: it unfolds to receive it.
                    if (centroid.scenePosition.y < panel.stripFullH)
                      panel.stripExpanded = true;
                    panel.dropSlot = panel.dropSlotAt(centroid.scenePosition.x, centroid.scenePosition.y);
                  }
                }
              }

              // Selection is a ring in the accent colour plus a nudge in size
              // (macOS: a blue frame under the pointer). No fill and no dim on
              // the others: in the exposé the windows are the content, and
              // dimming five of six makes the whole view look switched off.
              // Outside the scaled body so its border is not scaled down with it.
              Rectangle {
                x: win.fx
                y: win.fy
                width: win.fw
                height: win.fh
                scale: shot.scale
                radius: Style.space(Motion.radiusPopover * panel.uiScale)
                color: Util.alpha(Color.accent, 0)
                border.width: Math.max(2, Math.round(3 * panel.uiScale))
                // Gone the instant a close starts: left at the overview rect while
                // the window grows back, it was a ghost frame on every close.
                visible: root.settled && root.showSelection && !root.desktopMode && !win.dropped
                border.color: Util.alpha(Color.accent, win.isSelected ? 0.95 : 0)
                Behavior on border.color {
                  ColorAnimation {
                    duration: win.isSelected ? Motion.instant : Motion.fast
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                  }
                }
              }

              // Icon straddling the bottom edge of the window with the title
              // under it -- the macOS arrangement. Capped against the window so a
              // small floating window does not get an icon wider than itself.
              Image {
                id: appIcon
                width: Math.min(panel.iconSize, win.fw * 0.4)
                height: width
                x: win.fx + (win.fw - width) / 2
                y: win.fy + win.fh - height / 2
                opacity: win.labelOpacity * win.born * (win.dropped ? 0 : 1)
                visible: opacity > 0
                source: root.iconFor(win.ipc ? win.ipc["class"] : "")
                sourceSize.width: panel.iconSize
                sourceSize.height: panel.iconSize
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
              }

              // The title shows for the window under the pointer, the selected
              // one and the one in Quick Look (macOS), not for all at once.
              Text {
                readonly property bool wanted: winHover.hovered || (win.isSelected && root.showSelection) || win.peeking
                width: Math.max(win.fw, panel.width * 0.16)
                x: win.fx + (win.fw - width) / 2
                y: appIcon.y + appIcon.height + Math.round(panel.titleSize * 0.5)
                horizontalAlignment: Text.AlignHCenter
                // Untrusted: see root.displayLabel.
                textFormat: Text.PlainText
                text: root.displayLabel(win.modelData.title || (win.ipc && win.ipc["class"]) || "")
                font.family: root.fontFamily
                font.pixelSize: panel.titleSize
                color: panel.overlayInk
                opacity: win.labelOpacity * (wanted && !win.dropped ? 1 : 0)
                Behavior on opacity {
                  NumberAnimation {
                    duration: Motion.fast
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
                  }
                }
                visible: opacity > 0
                elide: Text.ElideRight
                maximumLineCount: 1
                style: Text.Raised
                styleColor: Qt.rgba(0, 0, 0, 0.6)
              }
            }
          }

          // An empty desktop says so, rather than leaving a blank half-screen
          // that looks like something failed to load.
          Text {
            visible: panel.windows.length === 0 && !root.desktopMode
            opacity: Math.max(0, Math.min(1, (root.progress - 0.55) / 0.45))
            anchors.horizontalCenter: parent.horizontalCenter
            y: panel.exposeAreaY + panel.exposeAreaH * 0.42
            textFormat: Text.PlainText
            text: root.appMode ? "No windows of this app" : "No windows"
            font.family: root.fontFamily
            font.pixelSize: Math.round(22 * panel.uiScale)
            color: Util.alpha(panel.overlayInk, Motion.secondaryTextAlpha)
          }
        }

        // --- neighbouring desktops, for the sideways swipe ------------------
        // The overview layout only, no interaction: they are just passing
        // through. Instantiated all the while the overview is up, so their
        // captures already have frames when a swipe brings them into view.
        Repeater {
          model: panel.slideOwner && root.missionMode ? [-1, 1] : []

          delegate: Item {
            id: page
            required property int modelData
            readonly property var desk: panel.desktopAt(page.modelData)
            x: (page.modelData + root.slide) * panel.width
            width: panel.width
            height: panel.height
            visible: page.desk !== null && Math.abs(page.modelData + root.slide) < 1
            opacity: Math.max(0, Math.min(1, (root.progress - 0.55) / 0.45))

            property var wins: []
            readonly property var winsLive: panel.windowsOf(page.desk)
            onWinsLiveChanged: if (!root.sameList(page.wins, page.winsLive)) page.wins = page.winsLive
            Component.onCompleted: page.wins = page.winsLive
            readonly property var origin: panel.originFor(page.wins)

            Repeater {
              model: page.wins

              delegate: Item {
                id: other
                required property var modelData
                readonly property var ipc: modelData.lastIpcObject
                readonly property var at: (ipc && ipc.at) ? ipc.at : [0, 0]
                readonly property var size: (ipc && ipc.size) ? ipc.size : [0, 0]
                readonly property real w: other.size[0] * panel.shrink
                readonly property real h: other.size[1] * panel.shrink
                x: page.origin.x + (other.at[0] - panel.monX) * panel.shrink
                y: page.origin.y + (other.at[1] - panel.monY) * panel.shrink
                width: other.w
                height: other.h

                Item {
                  anchors.fill: parent
                  layer.enabled: root.decoRounding > 0
                  layer.smooth: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: otherMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                  }
                  ScreencopyView {
                    anchors.fill: parent
                    // Same rules as the strip thumbnails: no source while
                    // hidden, live only once the overview has settled.
                    captureSource: root.shown ? other.modelData.wayland : null
                    live: root.shown && root.settled
                    paintCursor: false
                  }
                }

                Item {
                  id: otherMask
                  anchors.fill: parent
                  layer.enabled: true
                  visible: false
                  Rectangle {
                    anchors.fill: parent
                    radius: root.decoRounding * panel.shrink
                    color: "black"
                  }
                }

                Image {
                  id: otherIcon
                  width: Math.min(panel.iconSize, other.w * 0.4)
                  height: width
                  x: (other.w - width) / 2
                  y: other.h - height / 2
                  source: root.iconFor(other.ipc ? other.ipc["class"] : "")
                  sourceSize.width: panel.iconSize
                  sourceSize.height: panel.iconSize
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                }

                Text {
                  width: Math.max(other.w, panel.width * 0.16)
                  x: (other.w - width) / 2
                  y: otherIcon.y + otherIcon.height + Math.round(panel.titleSize * 0.5)
                  horizontalAlignment: Text.AlignHCenter
                  // Untrusted: see root.displayLabel.
                  textFormat: Text.PlainText
                  text: root.displayLabel(other.modelData.title || (other.ipc && other.ipc["class"]) || "")
                  font.family: root.fontFamily
                  font.pixelSize: panel.titleSize
                  color: Util.alpha(panel.overlayInk, Motion.secondaryTextAlpha)
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  style: Text.Raised
                  styleColor: Qt.rgba(0, 0, 0, 0.6)
                }
              }
            }

            Text {
              visible: page.wins.length === 0
              anchors.horizontalCenter: parent.horizontalCenter
              y: panel.exposeAreaY + panel.exposeAreaH * 0.42
              textFormat: Text.PlainText
              text: "No windows"
              font.family: root.fontFamily
              font.pixelSize: Math.round(22 * panel.uiScale)
              color: Util.alpha(panel.overlayInk, Motion.secondaryTextAlpha)
            }
          }
        }
      }
    }
  }
}
