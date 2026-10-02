// Mission Control -- a macOS-style workspace overview for Omarchy.
//
// A Spaces strip of live desktop thumbnails across the top, and underneath it
// the current desktop's windows shrunk down so none overlaps, each with its app
// icon and title. Click a window to go to it, click a desktop to switch to it
// (the overview stays up, so you can then pick a window there).
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
// Every duration, curve and distance comes from Motion.qml (a singleton
// registered by the qmldir next to this file) -- see docs/ANIMATION-SPEC.md.

Item {
  id: root

  // --- plugin contract --------------------------------------------------
  // Set by the shell's Loader when this plugin is mounted.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // One line in the shell log on mount, so "is the new code running?" has an
  // answer after a restart (the shell's hot reload does not re-create a
  // keepLoaded overlay, and a cached old version is otherwise invisible).
  readonly property string build: "1.5.3 swipe-owner"
  Component.onCompleted: console.info("henri.missioncontrol " + root.build + " mounted")

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
    easing.bezierCurve: Motion.easeIn
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
  // Reduced motion only: the way in is a crossfade too.
  NumberAnimation {
    id: contentFadeIn
    target: root
    property: "contentOpacity"
    to: 1
    duration: Motion.instant
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
    progressTween.stop();
    progressSpring.stop();
    root.springSettling = false;
    root.springVelocity = 0;
    root.progressAnimDuration = 0;
    root.progress = 0;
  }

  // The open is the spec's `slow` (the overview opening); the close its "tile
  // back to the real window" case: `base`, while the overview dissolves.
  // Both ways the windows travel from A to B, so ease-in-out -- a curve that
  // starts at full speed moved them 18% of the way in the first 5% of the time,
  // which read as a jolt, and one that ends at full speed slammed the copy into
  // its real rect right where it has to be indistinguishable from the desktop.
  readonly property int shrinkDuration: Motion.slow
  readonly property int unshrinkDuration: Motion.base
  // Shortest animation, for finishing a nearly-done shrink.
  readonly property int shrinkMinDuration: Motion.fast
  // The closing crossfade over the tail of the movement.
  readonly property int fadeDuration: Motion.d(Motion.fast)
  readonly property var shrinkCurve: Motion.easeInOut
  readonly property var unshrinkCurve: Motion.easeInOut
  // Share of the duration after which the curve is ~98% home -- where the
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
  // Stepped per delivered frame with the step capped, not off the wall clock:
  // over a fullscreen window the compositor holds our first frames back for
  // ~100 ms, and a clock-driven animation then lands at the end in one jump
  // instead of shrinking the window at all. This way a stall delays the
  // motion; it never skips it.
  FrameAnimation {
    id: progressTween
    property real from: 0
    property real to: 1
    property int duration: 1
    property var curve: Motion.easeInOut
    property real t: 0
    onTriggered: {
      t += Math.min(frameTime, 1 / 30) * 1000 / duration;
      if (t >= 1) {
        t = 1;
        root.progress = to;
        stop();
        return;
      }
      root.progress = from + (to - from) * root.bezier(curve, t);
    }
  }
  // y for x on a cubic bezier (x1, y1, x2, y2), like CSS cubic-bezier.
  function bezier(c, x) {
    const x1 = c[0], y1 = c[1], x2 = c[2], y2 = c[3];
    let u = x;
    for (let i = 0; i < 6; i++) {
      const bx = 3 * u * (1 - u) * (1 - u) * x1 + 3 * u * u * (1 - u) * x2 + u * u * u - x;
      const dx = 3 * (1 - u) * (1 - u) * x1 + 6 * u * (1 - u) * (x2 - x1) + 3 * u * u * (1 - x2);
      if (Math.abs(dx) < 1e-6)
        break;
      u = Math.max(0, Math.min(1, u - bx / dx));
    }
    return 3 * u * (1 - u) * (1 - u) * y1 + 3 * u * u * (1 - u) * y2 + u * u * u;
  }
  onExpandedChanged: if (!root.tracking) root.animateProgress(root.expanded ? 1 : 0)

  // Animate to `to` from the current value -- also after a swipe, which
  // finishes from wherever the fingers left it (spec: on release, glide to
  // the target). Duration scales with the distance left, so finishing a
  // half-done swipe does not take as long as a full open.
  // How long the animation just started will take, for the close timers.
  property int progressAnimDuration: 0

  function animateProgress(to) {
    // Fingers just lifted: carry on from the speed they had.
    if (root.releasing && !Motion.reduced) {
      root.settleProgress(to);
      return;
    }
    progressTween.stop();
    progressSpring.stop();
    root.springSettling = false;
    root.springVelocity = 0;
    // Reduced motion: nothing shrinks or slides. The windows are already in
    // place and the surface crossfades -- see the fades in setShown.
    const dist = Math.abs(to - root.progress);
    if (Motion.reduced || dist < 0.001) {
      root.progress = to;
      root.progressAnimDuration = 0;
      return;
    }
    const full = to > root.progress ? root.shrinkDuration : root.unshrinkDuration;
    const dur = Math.round(full * Math.sqrt(Math.min(1, dist)));
    progressTween.from = root.progress;
    progressTween.to = to;
    progressTween.duration = Math.max(root.shrinkMinDuration, Math.min(full, dur));
    progressTween.curve = to > root.progress ? root.shrinkCurve : root.unshrinkCurve;
    progressTween.t = 0;
    root.progressAnimDuration = progressTween.duration;
    progressTween.start();
  }

  // --- under the fingers ----------------------------------------------------
  // While the fingers are down, `progress` IS their position: every touchpad
  // update sets it, nothing in between. (A spring used to pull it along behind
  // them, about 70 ms late -- smooth, but not attached.) The spring below only
  // runs after the release, see "release"; the speed it starts with is the
  // fingers', measured over the last updates.
  property real springTarget: 0
  property real springVelocity: 0 // progress per second
  // Finger samples [time ms, travel] of the swipe in progress, and how far
  // back the speed at release looks.
  property var trackSamples: []
  property var slideSamples: []
  readonly property int velocityWindow: 100

  function sample(list, time, travel) {
    list.push([time, travel]);
    while (list.length > 2 && time - list[0][0] > 2 * root.velocityWindow)
      list.shift();
  }

  // Travel per second at the last sample: the slope of a line through the
  // samples of the last `velocityWindow` ms. One update against the next is
  // too jittery to hand to a spring.
  function fingerSpeed(list) {
    const n = list.length;
    if (n < 2)
      return 0;
    const last = list[n - 1][0];
    let from = n - 2;
    while (from > 0 && last - list[from - 1][0] <= root.velocityWindow)
      from--;
    let mt = 0, mx = 0;
    for (let i = from; i < n; i++) { mt += list[i][0]; mx += list[i][1]; }
    mt /= n - from;
    mx /= n - from;
    let num = 0, den = 0;
    for (let i = from; i < n; i++) {
      num += (list[i][0] - mt) * (list[i][1] - mx);
      den += (list[i][0] - mt) * (list[i][0] - mt);
    }
    return den > 0 ? num / den * 1000 : 0;
  }

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
    const to = root.springTarget;
    const before = to - root.progress;
    const next = root.springStep(root.progress, root.springVelocity, to, root.settleRate, dt);
    root.springVelocity = next[1];
    root.progress = next[0];
    // Closing: dissolve over the tail of the way home, like the timed close.
    if (to <= 0 && !root.settleFading && root.progress <= root.fadeStartProgress) {
      root.settleFading = true;
      fadeOutSoon.interval = 1;
      collapseThenHide.interval = root.fadeDuration + 16;
      fadeOutSoon.restart();
      collapseThenHide.restart();
    }
    if (root.arrived(before, to - next[0])) {
      progressSpring.stop();
      root.springSettling = false;
      root.springVelocity = 0;
      root.progress = to;
    }
  }

  // --- release --------------------------------------------------------------
  // A curve starts from standstill, so handing a released swipe to one made the
  // windows stop under the lifting fingers and set off again (measured: 0.07 of
  // the way per frame, then 0.003, then up again). On release a spring takes
  // the windows on from the fingers' speed to the end of the way.
  // Critically damped, so it cannot swing past (spec: the only
  // spring allowed); its rate is the one that is home after the token duration
  // the timed open or close takes.
  property bool springSettling: false
  property real settleRate: 0
  property bool settleFading: false
  // Close enough to count as there: a pixel or two of the longest way.
  readonly property real settleEpsilon: 0.002
  // Where the timed close starts its fade: the curve's value at fadeStartAt.
  readonly property real fadeStartProgress: 1 - root.bezier(root.unshrinkCurve, root.fadeStartAt)
  // Fingers do not lift in the same frame, and libinput holds updates back for
  // up to 100 ms while their number changes (measured on this trackpad: 13 to
  // 52 ms between the last update and the end). A gap this long is still the
  // lift, not a hand that stopped first.
  readonly property int liftGap: 120

  // `left` is the signed way still to go; done when it is nothing, or flipped.
  function arrived(before, left) {
    return Math.abs(left) < root.settleEpsilon || before * left < 0;
  }

  // The most speed a critically damped spring takes over without crossing its
  // target: rate x distance. Anything faster is trimmed to that.
  function carried(v, rate, dist) {
    const most = rate * Math.abs(dist);
    return Math.max(-most, Math.min(most, v));
  }

  function settleProgress(to) {
    progressTween.stop();
    root.progressAnimDuration = 0;
    root.settleFading = false;
    const dist = to - root.progress;
    if (Math.abs(dist) < root.settleEpsilon) {
      progressSpring.stop();
      root.springSettling = false;
      root.springVelocity = 0;
      root.progress = to;
      return;
    }
    root.settleRate = Motion.springRate(dist > 0 ? root.shrinkDuration : root.unshrinkDuration);
    root.springVelocity = root.carried(root.springVelocity, root.settleRate, dist);
    root.springTarget = to;
    root.springSettling = true;
    if (!progressSpring.running)
      progressSpring.start();
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
  readonly property real slideDistance: 550

  signal slideRequested(int dir)

  // The sideways swipe sits under the fingers too; this is its release spring.
  FrameAnimation {
    id: slideSpring
    onTriggered: {
      const to = root.slideTarget;
      const before = to - root.slide;
      const next = root.springStep(root.slide, root.slideVelocity, to, Motion.springRate(Motion.base),
                                   Math.min(frameTime, 1 / 30));
      root.slideVelocity = next[1];
      root.slide = next[0];
      if (root.arrived(before, to - next[0])) {
        stop();
        root.slideSettling = false;
        root.slideVelocity = 0;
        root.slide = to;
      }
    }
  }
  // A released swipe on its way to the page, see "release".
  property bool slideSettling: false
  // Pages travel from A to B: ease-in-out, `base` for a whole page and less
  // for the rest of a released swipe.
  NumberAnimation {
    id: slideAnim
    target: root
    property: "slide"
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.easeInOut
  }

  Timer {
    id: slideWatchdog
    interval: 350
    // No end arrived: the fingers are long gone, so no speed to carry.
    onTriggered: if (root.slideTracking) root.handleSlide("end", 0, root.slideLastTime + root.liftGap + 1)
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
    slideAnim.stop();
    slideWatchdog.stop();
    root.slideSettling = false;
    root.slideTracking = false;
    root.slidePendingDir = 0;
    root.slide = 0;
    root.slideTarget = 0;
    root.slideVelocity = 0;
  }

  // Glide to `target` from wherever the page is now. `carry`: the fingers just
  // let go, keep their speed (the spring) instead of starting a curve.
  function settleSlide(target, carry) {
    slideAnim.stop();
    if (carry && !Motion.reduced && Math.abs(target - root.slide) >= root.settleEpsilon) {
      root.slideVelocity = root.carried(root.slideVelocity, Motion.springRate(Motion.base), target - root.slide);
      root.slideTarget = target;
      root.slideSettling = true;
      if (!slideSpring.running)
        slideSpring.start();
      return;
    }
    slideSpring.stop();
    root.slideSettling = false;
    root.slideVelocity = 0;
    root.slideTarget = target;
    const dist = Math.abs(target - root.slide);
    if (Motion.reduced || dist < 0.001) {
      root.slide = target;
      return;
    }
    slideAnim.from = root.slide;
    slideAnim.to = target;
    slideAnim.duration = Math.max(Motion.fast, Math.round(Motion.base * Math.sqrt(Math.min(1, dist))));
    slideAnim.start();
  }

  // The desktop changed by `step` while shown: keep every page where it is.
  function rebaseSlide(step) {
    root.slide += step;
    root.slideStart += step;
    if (root.slideTracking || root.slideSettling) {
      root.slideTarget += step;
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
      slideAnim.stop();
      slideSpring.stop();
      root.slideSettling = false;
      root.slideVelocity = 0;
      root.slideSamples = [[time, 0]];
      root.slideTarget = root.slide;
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
      root.sample(root.slideSamples, time, root.slideTravel);
      const raw = root.slideStart + root.slideTravel;
      const lo = root.slideCanNext ? -1 : 0;
      const hi = root.slideCanPrev ? 1 : 0;
      root.slideTarget = raw < lo ? lo - root.rubberBand(lo - raw)
          : raw > hi ? hi + root.rubberBand(raw - hi)
          : raw;
      root.slide = root.slideTarget;
    } else if (phase === "end" && root.slideTracking) {
      root.slideTracking = false;
      slideWatchdog.stop();
      // A cancelled swipe (the number of fingers changed) is a release too.
      const still = time - root.slideLastTime > root.liftGap;
      if (still)
        root.slideTrackVelocity = 0;
      // In the rubber band the page barely moves for all the fingers do.
      const banded = root.slide < (root.slideCanNext ? -1 : 0) || root.slide > (root.slideCanPrev ? 1 : 0);
      root.slideVelocity = still || banded ? 0 : root.fingerSpeed(root.slideSamples);
      // A flick decides by its direction, a slow drag by how far it got.
      const v = root.slideTrackVelocity;
      let side = 0;
      if (Math.abs(v) > 0.0006)
        side = v < 0 ? -1 : 1;
      else if (Math.abs(root.slideTarget + v * 120) > 0.25)
        side = root.slideTarget < 0 ? -1 : 1;
      if ((side < 0 && !root.slideCanNext) || (side > 0 && !root.slideCanPrev))
        side = 0;
      root.settleSlide(side, true);
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
    // No end arrived: the fingers are long gone, so no speed to carry.
    onTriggered: if (root.tracking) root.handleGesture("end", 0, root.trackLastTime + root.liftGap + 1)
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
      progressTween.stop();
      progressSpring.stop();
      root.springSettling = false;
      root.springVelocity = 0;
      root.trackSamples = [[time, 0]];
      root.springTarget = root.progress;
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
      root.sample(root.trackSamples, time, root.trackTravel);
      const raw = root.trackStart + root.trackTravel;
      // Past fully open: resist, a little, like a rubber band.
      root.springTarget = raw <= 0 ? 0
          : raw <= 1 ? raw
          : 1 + root.rubberBand(raw - 1);
      root.progress = root.springTarget;
    } else if (phase === "end" && root.tracking) {
      root.tracking = false;
      trackWatchdog.stop();
      // Fingers held still before lifting: no fling. A cancelled swipe (the
      // number of fingers changed) is a release like any other.
      const still = time - root.trackLastTime > root.liftGap;
      if (still)
        root.trackVelocity = 0;
      // What the release spring starts with (settleProgress trims it).
      // Not out of the rubber band, where the windows barely move.
      root.springVelocity = still || root.progress > 1 ? 0 : root.fingerSpeed(root.trackSamples);
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
      // Reduced motion: the surface fades in over the desktop instead of the
      // windows shrinking out of it.
      if (Motion.reduced) {
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
      if (root.springSettling) {
        // A released swipe: the spring starts the fade when the windows are
        // nearly home (stepSpring). This is only the backstop.
        fadeOutSoon.stop();
        collapseThenHide.interval = root.shrinkDuration + root.unshrinkDuration;
        collapseThenHide.restart();
        return;
      }
      const dur = progressTween.running ? root.progressAnimDuration : 0;
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
          if (item && item.page === 0 && !item.captureReady)
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
            // The thumbnails are there from the first frame (Henri: the strip
            // is open the moment F8 is pressed, no unfolding on hover).
            panel.stripExpanded = true;
            // Everything in the strip snaps into place while hidden and only
            // animates from here on.
            panel.stripAnimates = true;
            if (panel.capturesReady) panel.revealed = true;
            else revealTimeout.restart();
          } else {
            panel.stripAnimates = false;
            revealTimeout.stop();
            panel.revealed = false;
            panel.finishReorder();
            panel.dragTile = -1;
            panel.dragSlot = -1;
            panel.resetTileOrder();
            // Folded while hidden: nothing in it captures then.
            panel.stripExpanded = false;
            panel.peek = -1;
            panel.altHeld = false;
            panel.dragWindow = -1;
            panel.dropSlot = -2;
            panel.transitDesk = -1;
            panel.transitFrom = -1;
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
        interval: 250
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
        panel.syncModel();
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

      function setSlotIds(ids) {
        if (root.sameList(panel.slotIds, ids))
          return;
        // Order first: the tile Repeater follows slotIds.length, and every tile
        // must find itself in tileOrder when it is created.
        if (ids.length !== panel.slotIds.length)
          panel.tileOrder = ids.map((_, i) => i);
        panel.slotIds = ids;
      }

      function resetTileOrder() {
        panel.tileOrder = panel.slotIds.map((_, i) => i);
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

      // The desktop on this monitor -- its active workspace, not the focused
      // one: `focused` is only ever true on the focused monitor, so the
      // overview on a second monitor would fall back to its first desktop.
      readonly property var currentDesktop: {
        const active = panel.hyprMonitor && panel.hyprMonitor.activeWorkspace ? panel.hyprMonitor.activeWorkspace.id : -1;
        for (let i = 0; i < panel.desktops.length; i++)
          if (panel.desktops[i].id === active)
            return panel.desktops[i];
        for (let i = 0; i < panel.desktops.length; i++)
          if (panel.desktops[i].focused || panel.desktops[i].active)
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
                                         : root.desktopMode ? panel.windowsOf(panel.currentDesktop)
                                         : panel.pageWindows()

      // Mission Control: the current desktop's windows plus those of its
      // neighbours (and of a desktop being travelled to or from), so a
      // sideways swipe, the arrow keys and a click on a thumbnail have the
      // other desktop already drawn beside this one, captures warm, and the
      // switch itself changes nothing on screen (see rebaseSlide).
      property int transitDesk: -1
      property int transitFrom: -1
      function pageWindows() {
        const cur = panel.currentDesktop;
        const out = panel.windowsOf(cur);
        if (!panel.slideOwner)
          return out;
        const seen = {};
        if (cur) seen[cur.id] = true;
        const desks = [panel.desktopAt(-1), panel.desktopAt(1),
                       panel.deskById(panel.transitDesk), panel.deskById(panel.transitFrom)];
        for (let k = 0; k < desks.length; k++) {
          const d = desks[k];
          if (!d || seen[d.id])
            continue;
          seen[d.id] = true;
          const ws = panel.windowsOf(d);
          for (let i = 0; i < ws.length; i++)
            out.push(ws[i]);
        }
        return out;
      }
      function deskIndexOf(id) {
        for (let i = 0; i < panel.desktops.length; i++)
          if (panel.desktops[i].id === id)
            return i;
        return -1;
      }
      function pageOf(t) {
        if (!root.missionMode || !t || !t.workspace || !panel.currentDesktop)
          return 0;
        const i = panel.deskIndexOf(t.workspace.id);
        const c = panel.deskIndexOf(panel.currentDesktop.id);
        return i < 0 || c < 0 ? 0 : i - c;
      }
      readonly property int currentCount: {
        let n = 0;
        for (let i = 0; i < panel.windows.length; i++)
          if (panel.pageOf(panel.windows[i]) === 0)
            n++;
        return n;
      }
      function firstOnScreen() {
        for (let i = 0; i < panel.windows.length; i++)
          if (panel.pageOf(panel.windows[i]) === 0)
            return i;
        return -1;
      }

      // The exposé's model, diffed against panel.windows so delegates survive
      // a change (see the Repeater).
      ListModel { id: winModel }
      function syncModel() {
        const list = panel.windows;
        for (let i = winModel.count - 1; i >= 0; i--)
          if (list.indexOf(winModel.get(i).handle) < 0)
            winModel.remove(i);
        for (let i = 0; i < list.length; i++) {
          let found = false;
          for (let j = 0; j < winModel.count; j++)
            if (winModel.get(j).handle === list[i]) { found = true; break; }
          if (!found)
            winModel.append({ handle: list[i] });
        }
      }

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
      // (The test screen is never the focused monitor, so it counts as the
      // owner outright.)
      //
      // HyprlandMonitor.focused alone is not enough: Quickshell only sets it on
      // a `focusedmon` event, and Hyprland sends one when the focus MOVES to
      // another monitor. After a shell restart on a single-screen setup no
      // monitor is ever "focused" -- no panel owned the swipe, it found no
      // neighbouring desktop, gave the rubber band and sprang back, and the
      // arrow keys switched without sliding. So while no monitor carries the
      // live flag, go by what Hyprland answered to the refresh on open.
      readonly property bool anyFocused: {
        const mons = Hyprland.monitors.values || [];
        for (let i = 0; i < mons.length; i++)
          if (mons[i].focused)
            return true;
        return false;
      }
      readonly property bool monitorFocused: panel.hyprMonitor !== null
          && (panel.anyFocused ? panel.hyprMonitor.focused
              : !!panel.hyprMonitor.lastIpcObject && panel.hyprMonitor.lastIpcObject.focused === true)
      readonly property bool slideOwner: root.testScreen !== "" || panel.monitorFocused
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
        if (!root.shown || old < 0 || i < 0 || i === old)
          return;
        // The selection starts over on the desktop you landed on. The window
        // list holds the neighbours' windows too, so it often does not change
        // on a switch -- and a selection left on the old desktop's window sent
        // Enter straight back there.
        panel.selected = panel.firstOnScreen();
        panel.peek = -1;
        root.showSelection = false;
        if (!panel.slideOwner)
          return;
        const step = root.slidePendingDir !== 0 ? root.slidePendingDir : i - old;
        root.slidePendingDir = 0;
        // Whatever the distance: the pages are drawn per desktop, so the
        // rebase keeps every one of them where it is.
        root.rebaseSlide(step);
      }

      // --- geometry ---------------------------------------------------------
      // Proportions taken off a real Mission Control screenshot: the Spaces
      // strip is about a sixth of the screen, and the thumbnails in it about
      // two thirds of the strip, leaving room for a label underneath.
      readonly property real uiScale: panel.width / 1920
      // Unfolded (thumbnails) whenever the overview is up, folded to the
      // labels only while hidden, so nothing in it captures then. Its height
      // is never animated (spec): it snaps, the thumbnails fade and rise into
      // it, and the labels and the windows underneath travel to their places.
      property bool stripExpanded: false
      // False while hidden, so every strip transition snaps there.
      property bool stripAnimates: false
      readonly property real stripFullH: Math.round(panel.height * 0.155)
      readonly property real stripCollapsedH: Math.round(panel.stripLabelBand + panel.stripPad * 2)
      readonly property real stripH: panel.stripExpanded ? panel.stripFullH : panel.stripCollapsedH
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
        // One origin per desktop: each page is its own shrunken desktop.
        const groups = {};
        for (let i = 0; i < wins.length; i++) {
          const key = wins[i].workspace ? wins[i].workspace.id : "cur";
          (groups[key] = groups[key] || []).push(i);
        }
        const out = new Array(wins.length);
        for (const key in groups) {
          const idx = groups[key];
          const o = panel.originFor(idx.map(i => wins[i]));
          for (let k = 0; k < idx.length; k++) {
            const i = idx[k];
            const ipc = wins[i].lastIpcObject;
            const at = ipc && ipc.at ? ipc.at : [0, 0];
            out[i] = { x: o.x + (at[0] - panel.monX) * panel.shrink,
                       y: o.y + (at[1] - panel.monY) * panel.shrink,
                       s: panel.shrink, onScreen: true, minimized: false };
          }
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

      // Scaled with the rest of the overview geometry (which follows the
      // screen, not the font).
      readonly property real thumbRadius: Style.space(8 * panel.uiScale)
      readonly property real ringRadius: Style.space(10 * panel.uiScale)
      readonly property real hairlineAlpha: 0.10
      readonly property real secondaryInkAlpha: 0.65

      // --- selection --------------------------------------------------------
      // Index into panel.windows; -1 when the desktop is empty.
      property int selected: panel.windows.length > 0 ? 0 : -1
      // The selected window's rect on screen, kept by its delegate; the
      // selection ring below glides between them.
      property real selX: 0
      property real selY: 0
      property real selW: 0
      property real selH: 0
      // An arrow key auto-repeating: the ring follows without a glide.
      property bool keyRepeat: false

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
          if (i === panel.selected || panel.pageOf(panel.windows[i]) !== 0)
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
          panel.keyRepeat = event.isAutoRepeat;
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
          // Number keys switch to that desktop and stay open, like the arrow
          // keys: look before you leap. The number of the desktop you are
          // already on has nowhere to go, so it acts like Enter: the selected
          // window opens (or, with nothing selected, the overview closes here).
          if (root.missionMode && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const want = event.key - Qt.Key_0;
            if (panel.deskIndexOf(want) >= 0) {
              if (panel.currentDesktop && panel.currentDesktop.id === want)
                panel.activateSelection();
              else
                panel.switchTo(want);
              event.accepted = true;
              return;
            }
          }
        }
      }

      // Switch desktop but stay open: the point of walking the strip is to
      // look before you leap.
      function stepDesktop(dir) {
        const n = panel.desktops.length;
        if (n === 0)
          return;
        let i = Math.max(0, panel.desktops.indexOf(panel.currentDesktop));
        panel.switchTo(panel.desktops[(i + dir + n) % n].id);
      }

      // Switch desktop but stay open: the other desktop's windows are drawn
      // beside this one (see pageWindows) and slide in on the rebase.
      function switchTo(id) {
        const cur = panel.currentDesktop;
        const ci = cur ? panel.deskIndexOf(cur.id) : -1;
        const ti = panel.deskIndexOf(id);
        const target = root.safeWorkspaceId(id);
        if (ci < 0 || ti < 0 || ci === ti || target === "")
          return;
        panel.transitFrom = cur.id;
        panel.transitDesk = id;
        root.slidePendingDir = ti - ci;
        root.dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })", "workspace " + target);
      }

      function cycleWindow() {
        const n = panel.windows.length;
        for (let k = 1; k <= n; k++) {
          const i = (panel.selected + k + n) % n;
          if (panel.pageOf(panel.windows[i]) === 0) {
            panel.selected = i;
            return;
          }
        }
      }

      // Landing on another desktop starts its selection over; without this the
      // index left over from the previous desktop points at nothing.
      onWindowsChanged: {
        panel.syncModel();
        panel.selected = panel.firstOnScreen();
        panel.peek = -1;
      }

      // Enter: the selected window, if it is on this desktop; otherwise just
      // close here (never focus a window on another desktop, which would
      // switch back).
      function activateSelection() {
        const i = panel.selected;
        if (i >= 0 && i < panel.windows.length && panel.pageOf(panel.windows[i]) === 0)
          root.focusWindow(String(panel.windows[i].address));
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
        // Only Mission Control has the strip. A mode switch while up brings
        // it down 16 px with a fade, or takes it away the same way (spec, side
        // panel); on open it rides the progress instead.
        property real stripIn: root.missionMode ? 1 : 0
        Behavior on stripIn {
          enabled: panel.stripAnimates
          NumberAnimation {
            duration: root.missionMode ? Motion.d(Motion.base) : Motion.d(Motion.fast)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.missionMode ? Motion.easeOut : Motion.easeIn
          }
        }

        Rectangle {
          id: strip
          width: parent.width
          height: panel.stripH
          // Slides down from off-screen as the desktop shrinks to make room for
          // it, which is where macOS puts the motion. Driven by stripProgress,
          // which holds it in place on a non-swipe close -- see stripHold.
          readonly property real reveal: root.stripProgress * stage.stripIn
          y: root.lerp(-panel.stripH, 0, root.stripProgress) - Motion.px(Motion.distanceLg) * (1 - stage.stripIn)
          opacity: strip.reveal
          visible: strip.reveal > 0.001
          color: Qt.rgba(1, 1, 1, 0.07)

          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Util.alpha(panel.overlayInk, panel.hairlineAlpha)
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
              // Folded: on their own in the band. Unfolding, they travel down
              // under the thumbnails (text is moved, never scaled).
              y: panel.stripExpanded ? strip.rowY + panel.stripTileH : strip.foldedLabelY
              Behavior on y {
                enabled: panel.stripAnimates
                NumberAnimation {
                  duration: Motion.travel(Motion.base)
                  easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut
                }
              }
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
                                      : Util.alpha(panel.overlayInk, panel.secondaryInkAlpha)
              Behavior on color {
                ColorAnimation {
                  duration: Motion.instant
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
              // Held: pinned to the pointer, no transition. Released: glides
              // to its slot in `fast` ease-out; the neighbours making room
              // travel in `base` ease-in-out (spec, drag & drop). Explicit
              // animations rather than Behaviors, so the pointer never runs
              // through one and a glide always starts from where the tile is.
              readonly property bool held: deskDrag.active
              // Released and still flying home: stays on top of its neighbours.
              property bool landing: false
              property real dragHomeX: 0
              property real dragOriginX: 0
              property real dragOriginY: 0
              property real dragDX: 0
              property real dragDY: 0
              readonly property real slotX: panel.stripRowX + Math.max(0, deskCell.shownSlot) * panel.stripPitch
              // Vertical offset while held, and on the way home.
              property real dragY: 0

              NumberAnimation {
                id: xGlide
                target: deskCell
                property: "x"
                easing.type: Easing.BezierSpline
                onRunningChanged: if (!running && !yGlide.running) deskCell.landing = false
              }
              NumberAnimation {
                id: yGlide
                target: deskCell
                property: "dragY"
                to: 0
                duration: Motion.fast
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Motion.easeOut
                onRunningChanged: if (!running && !xGlide.running) deskCell.landing = false
              }
              function glideX(to) {
                xGlide.stop();
                if (!panel.stripAnimates || Motion.reduced || Math.abs(to - deskCell.x) < 0.5) {
                  deskCell.x = to;
                  return;
                }
                xGlide.from = deskCell.x;
                xGlide.to = to;
                xGlide.duration = deskCell.landing ? Motion.fast : Motion.base;
                xGlide.easing.bezierCurve = deskCell.landing ? Motion.easeOut : Motion.easeInOut;
                xGlide.start();
              }
              function glideHome() {
                yGlide.stop();
                if (!panel.stripAnimates || Motion.reduced) {
                  deskCell.dragY = 0;
                  return;
                }
                yGlide.from = deskCell.dragY;
                yGlide.start();
              }
              onSlotXChanged: if (!deskCell.held) deskCell.glideX(deskCell.slotX)
              onDragDXChanged: if (deskCell.held) deskCell.x = deskCell.dragHomeX + deskCell.dragDX
              onDragDYChanged: if (deskCell.held) deskCell.dragY = deskCell.dragDY

              // Unfolding: the thumbnails fade in and rise 8 px, staggered in
              // reading order; folding is one fade, no stagger.
              property real unfold: panel.stripExpanded ? 1 : 0
              Behavior on unfold {
                enabled: panel.stripAnimates
                SequentialAnimation {
                  PauseAnimation { duration: panel.stripExpanded ? Motion.stagger(deskCell.shownSlot) : 0 }
                  NumberAnimation {
                    duration: panel.stripExpanded ? Motion.d(Motion.base) : Motion.d(Motion.fast)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: panel.stripExpanded ? Motion.easeOut : Motion.easeIn
                  }
                }
              }
              // Hover (and held): scale 1.02 and a 2 px lift, `instant` both ways.
              readonly property bool lit: deskHover.hovered || deskCell.held
              property real lift: deskCell.lit ? -Motion.px(Motion.hoverLift) : 0
              Behavior on lift {
                NumberAnimation { duration: Motion.instant; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
              }
              scale: deskCell.lit ? Motion.sc(Motion.scaleHover) : 1
              Behavior on scale {
                NumberAnimation { duration: Motion.instant; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
              }

              y: strip.rowY + Motion.px(Motion.distanceMd) * (1 - deskCell.unfold) + deskCell.lift + deskCell.dragY
              z: deskCell.held || deskCell.landing ? 2 : 0
              opacity: deskCell.unfold
              visible: deskCell.unfold > 0.001

              // A window being dragged over this desktop: it stands out.
              readonly property bool dropHover: panel.dragWindow >= 0 && panel.dropSlot === deskCell.shownSlot

              property var deskWindows: []
              // Held during a reorder -- the tile keeps showing what it showed
              // until Hyprland has moved the windows to match it.
              onDeskWindowsLiveChanged: if (!panel.reorderPending && !root.sameList(deskCell.deskWindows, deskCell.deskWindowsLive)) deskCell.deskWindows = deskCell.deskWindowsLive
              Component.onCompleted: {
                deskCell.x = deskCell.slotX;
                deskCell.deskWindows = deskCell.deskWindowsLive;
              }
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
                        duration: Motion.instant
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
                      duration: Motion.instant
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
                      && ((deskHover.hovered && deskCell.unfold > 0.9) || panel.altHeld)
                  width: Math.max(20, Math.round(22 * panel.uiScale))
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
                  // A small element: `fast` in, `instant` out.
                  Behavior on opacity {
                    NumberAnimation {
                      duration: closeBadge.wanted ? Motion.d(Motion.fast) : Motion.instant
                      easing.type: Easing.BezierSpline
                      easing.bezierCurve: closeBadge.wanted ? Motion.easeOut : Motion.easeIn
                    }
                  }
                  Behavior on color {
                    ColorAnimation {
                      duration: Motion.instant
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
                // Switches the desktop and stays open, like the arrow and
                // number keys (Henri: switching and closing at once felt wrong).
                TapHandler { onTapped: if (deskCell.wsId >= 0) panel.switchTo(deskCell.wsId) }

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
                      xGlide.stop();
                      yGlide.stop();
                      deskCell.landing = false;
                      deskCell.dragHomeX = deskCell.x;
                      deskCell.dragOriginX = centroid.scenePosition.x;
                      deskCell.dragOriginY = centroid.scenePosition.y;
                      deskCell.dragDX = 0;
                      deskCell.dragDY = 0;
                      deskCell.dragY = 0;
                      panel.dragTile = deskCell.index;
                      panel.dragSlot = deskCell.homeSlot;
                    } else {
                      deskCell.landing = true;
                      panel.endDrag(deskCell.index);
                      deskCell.glideX(deskCell.slotX);
                      deskCell.glideHome();
                    }
                  }
                  onCentroidChanged: {
                    if (!active)
                      return;
                    deskCell.dragDX = centroid.scenePosition.x - deskCell.dragOriginX;
                    deskCell.dragDY = centroid.scenePosition.y - deskCell.dragOriginY;
                    // The slot under the tile's centre.
                    const centre = deskCell.dragHomeX + deskCell.dragDX + panel.stripTileW / 2;
                    const slot = Math.floor((centre - panel.stripRowX + panel.stripGap / 2) / panel.stripPitch);
                    panel.dragSlot = Math.max(0, Math.min(panel.slotIds.length - 1, slot));
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
            // Unfolds with the thumbnails, last in the row.
            property real unfold: panel.stripExpanded ? 1 : 0
            Behavior on unfold {
              enabled: panel.stripAnimates
              SequentialAnimation {
                PauseAnimation { duration: panel.stripExpanded ? Motion.stagger(panel.slotIds.length) : 0 }
                NumberAnimation {
                  duration: panel.stripExpanded ? Motion.d(Motion.base) : Motion.d(Motion.fast)
                  easing.type: Easing.BezierSpline
                  easing.bezierCurve: panel.stripExpanded ? Motion.easeOut : Motion.easeIn
                }
              }
            }
            x: panel.plusX
            y: strip.rowY + Motion.px(Motion.distanceMd) * (1 - plusTile.unfold)
            width: panel.plusW
            height: panel.stripTileH
            radius: panel.thumbRadius
            color: Util.alpha(panel.overlayInk, plusTap.pressed ? 0.28 : plusTile.lit ? 0.22 : 0.12)
            border.width: Math.max(1, Math.round(2 * panel.uiScale))
            border.color: plusTile.dropHover ? Color.accent
                        : Util.alpha(panel.overlayInk, plusTile.lit ? 0.55 : 0.16)
            opacity: plusTile.unfold * (panel.plusVisible ? 1 : 0)
            visible: opacity > 0.001
            Behavior on color {
              ColorAnimation {
                duration: Motion.instant
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut
              }
            }
            Behavior on border.color {
              ColorAnimation {
                duration: Motion.instant
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
            // Not a JS array: reassigning an array model destroys and recreates
            // every delegate, captures included, and a fresh capture is blank
            // for a few frames -- which showed as a flash whenever the list
            // changed under a live overview (a desktop switch, a window
            // closing, a focus change). winModel is diffed instead: delegates
            // survive, only what left goes and what came is added.
            model: winModel

            delegate: Item {
              id: win
              required property var handle
              readonly property int idx: panel.windows.indexOf(win.handle)
              // Which desktop this window belongs to, relative to the current
              // one: 0 is the desktop on screen, -1 / +1 the neighbours (drawn
              // a screen width to the side, ready for a sideways swipe or a
              // click on their thumbnail), further for a jump. Only Mission
              // Control has pages.
              readonly property int page: panel.pageOf(win.handle)
              x: root.missionMode ? win.page * panel.width : 0
              visible: Math.abs(win.page + root.slide) < 1.001
              readonly property var ipc: win.handle.lastIpcObject
              readonly property bool isSelected: panel.selected === win.idx
              readonly property bool captureReady: copy.hasContent
              function recapture() {
                // Only with a context that has delivered a frame: without one
                // captureFrame() just warns, and a neighbour's context is torn
                // down while hidden.
                if (copy.captureSource && copy.hasContent)
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

              readonly property var slot: panel.layout[win.idx]
                  || ({ x: win.screenX, y: win.screenY, s: 1, onScreen: true, minimized: false })
              // On the real screen right now? Windows from other desktops (App
              // Exposé) are not: they have no rect to start from, so they are
              // born at their overview place and fade in there instead.
              readonly property bool onScreen: win.page === 0 && win.slot.onScreen !== false
              readonly property real realX: win.onScreen ? win.screenX : win.slot.x
              readonly property real realY: win.onScreen ? win.screenY : win.slot.y

              // The overview rect travels when the layout changes while the
              // overview is up -- the strip unfolding, a mode switch, a window
              // closing -- `base` ease-in-out from wherever it is. Only once
              // settled: before that the shrink itself is the animation, and a
              // target that moved while hidden (a window resized, the strip
              // folding on close) has to snap, or the windows would set off
              // towards a corner at the start of the next open.
              property real targetX: win.slot.x
              property real targetY: win.slot.y
              property real targetS: win.slot.s
              Behavior on targetX {
                enabled: root.settled
                NumberAnimation { duration: Motion.travel(Motion.base); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut }
              }
              Behavior on targetY {
                enabled: root.settled
                NumberAnimation { duration: Motion.travel(Motion.base); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut }
              }
              Behavior on targetS {
                enabled: root.settled
                NumberAnimation { duration: Motion.travel(Motion.base); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut }
              }
              readonly property real targetW: win.realW * win.targetS
              readonly property real targetH: win.realH * win.targetS

              // Quick Look (Space): grown to fill most of the exposé area, never
              // past its real size. There and back is a move from A to B.
              readonly property bool peeking: panel.peek === win.idx
              property real peekT: win.peeking ? 1 : 0
              Behavior on peekT {
                NumberAnimation { duration: Motion.travel(Motion.base); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut }
              }
              readonly property real peekS: Math.min(1, panel.peekAreaW / Math.max(1, win.realW),
                                                     panel.peekAreaH / Math.max(1, win.realH))
              readonly property real peekX: panel.peekAreaX + (panel.peekAreaW - win.realW * win.peekS) / 2
              readonly property real peekY: panel.peekAreaY + (panel.peekAreaH - win.realH * win.peekS) / 2

              // Drag to a desktop in the strip. The offset is measured from
              // where the drag activated, so the window does not jump by the
              // drag threshold; while held it is pinned to the pointer with no
              // transition, dropped anywhere else it glides home in `fast`
              // ease-out (spec, drag & drop), dropped on a desktop it stays
              // there and dissolves (Hyprland moves the real window, and this
              // copy leaves with it).
              readonly property bool held: winDrag.active
              property bool landing: false
              property bool dropped: false
              property real dragOriginX: 0
              property real dragOriginY: 0
              property real dragDX: 0
              property real dragDY: 0
              property real offX: 0
              property real offY: 0
              onDragDXChanged: if (win.held) win.offX = win.dragDX
              onDragDYChanged: if (win.held) win.offY = win.dragDY
              ParallelAnimation {
                id: homeGlide
                onRunningChanged: if (!running) win.landing = false
                NumberAnimation { target: win; property: "offX"; to: 0; duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
                NumberAnimation { target: win; property: "offY"; to: 0; duration: Motion.fast; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
              }
              function glideHome() {
                homeGlide.stop();
                if (Motion.reduced) {
                  win.offX = 0;
                  win.offY = 0;
                  return;
                }
                win.landing = true;
                homeGlide.start();
              }
              // Over the strip the dragged window shrinks towards thumbnail
              // size, about its centre, so it shrinks under the pointer.
              readonly property bool overStrip: (win.held || win.dropped) && panel.dropSlot !== -2
              property real dS: win.overStrip ? Math.min(1, (panel.stripTileW / panel.monW) / Math.max(0.01, win.targetS)) : 1
              Behavior on dS {
                NumberAnimation { duration: Motion.travel(Motion.fast); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
              }

              // The rect on screen this frame: open/close progress first, then
              // Quick Look, then the drag.
              readonly property real p: root.progress
              readonly property real ovX: root.lerp(win.realX, win.targetX, win.p)
              readonly property real ovY: root.lerp(win.realY, win.targetY, win.p)
              readonly property real ovS: root.lerp(win.onScreen ? 1 : win.targetS * 0.92, win.targetS, win.p)
              readonly property real baseS: root.lerp(win.ovS, win.peekS, win.peekT)
              readonly property real fs: win.baseS * win.dS
              readonly property real fx: root.lerp(win.ovX, win.peekX, win.peekT) + win.offX + win.realW * (win.baseS - win.fs) / 2
              readonly property real fy: root.lerp(win.ovY, win.peekY, win.peekT) + win.offY + win.realH * (win.baseS - win.fs) / 2
              readonly property real fw: win.realW * win.fs
              readonly property real fh: win.realH * win.fs

              // Labels and the selection ring belong to the overview, so they
              // sit at the overview rect and fade in over the last stretch of
              // the shrink instead of riding down at full size. Show Desktop
              // has no labels: the windows are on their way out.
              readonly property real labelOpacity: root.desktopMode ? 0
                  : Math.max(0, Math.min(1, (root.progress - 0.55) / 0.45))

              // Born while the overview was already up (a window opened, Tab
              // to another app): fades in and rises 4 px (spec, new list
              // entry) rather than popping.
              property real born: 1
              Component.onCompleted: {
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
                duration: Motion.d(Motion.base)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Motion.easeOut
              }

              z: win.held || win.landing || win.dropped || win.peeking ? 2 : 0

              // The selection ring lives outside the delegates (one ring that
              // glides between windows); while selected, this rect feeds it.
              Binding { target: panel; property: "selX"; value: win.fx; when: win.isSelected; restoreMode: Binding.RestoreNone }
              Binding { target: panel; property: "selY"; value: win.fy; when: win.isSelected; restoreMode: Binding.RestoreNone }
              Binding { target: panel; property: "selW"; value: win.fw; when: win.isSelected; restoreMode: Binding.RestoreNone }
              Binding { target: panel; property: "selH"; value: win.fh; when: win.isSelected; restoreMode: Binding.RestoreNone }

              // The window itself. Its size never changes -- it stays at the real
              // size and is moved and scaled with a transform. Animating
              // width/height (as before) re-laid-out the capture, ring, icon and
              // title every frame; a transform is just a matrix on the GPU. Scale
              // is uniform, so this is the same motion as before, only cheaper.
              Item {
                id: body
                x: win.fx
                y: win.fy + Motion.px(Motion.distanceSm) * (1 - win.born)
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
                    duration: Motion.d(Motion.fast)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeIn
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
                  border.color: win.handle.activated ? root.decoActive : root.decoInactive
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
                    // Windows of the neighbouring desktops only while shown,
                    // and live only once settled -- the same rules the strip
                    // thumbnails follow (every frame of another desktop is a
                    // render Hyprland does just for us).
                    captureSource: win.page === 0 || root.shown ? win.handle.wayland : null
                    live: root.shown && (win.page === 0 || root.settled)
                    paintCursor: false
                  }

                  // Selected (keyboard or pointer): the tile hover, scale 1.02
                  // and a 2 px lift, `instant` both ways.
                  readonly property bool lit: win.isSelected && root.settled && root.showSelection && !win.peeking && !win.held
                  scale: shot.lit ? Motion.sc(Motion.scaleHover) : 1
                  Behavior on scale {
                    NumberAnimation { duration: Motion.instant; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
                  }
                  transform: Translate {
                    y: shot.lit ? -Motion.px(Motion.hoverLift) : 0
                    Behavior on y {
                      NumberAnimation { duration: Motion.instant; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
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
                  onHoveredChanged: if (hovered && root.settled && win.page === 0 && Math.abs(root.slide) < 0.01 && panel.dragWindow < 0) {
                    panel.keyRepeat = false;
                    root.showSelection = true;
                    panel.selected = win.idx;
                  }
                }

                TapHandler {
                  onTapped: root.focusWindow(String(win.handle.address))
                }

                DragHandler {
                  id: winDrag
                  target: null
                  enabled: root.settled && root.missionMode && win.page === 0 && panel.peek < 0 && Hyprland.usingLua
                      && panel.dragTile < 0 && !win.dropped
                  cursorShape: Qt.ClosedHandCursor
                  onActiveChanged: {
                    if (active) {
                      homeGlide.stop();
                      win.landing = false;
                      win.dragOriginX = centroid.scenePosition.x;
                      win.dragOriginY = centroid.scenePosition.y;
                      win.dragDX = 0;
                      win.dragDY = 0;
                      win.offX = 0;
                      win.offY = 0;
                      panel.dragWindow = win.idx;
                      panel.dropSlot = -2;
                    } else {
                      const slot = panel.dropSlot;
                      panel.dragWindow = -1;
                      if (slot !== -2) {
                        win.dropped = true;
                        panel.moveWindowToSlot(String(win.handle.address), slot);
                      } else {
                        win.glideHome();
                      }
                      panel.dropSlot = -2;
                    }
                  }
                  onCentroidChanged: {
                    if (!active)
                      return;
                    win.dragDX = centroid.scenePosition.x - win.dragOriginX;
                    win.dragDY = centroid.scenePosition.y - win.dragOriginY;
                    // Carried towards the strip: it unfolds to receive it.
                    if (centroid.scenePosition.y < panel.stripFullH)
                      panel.stripExpanded = true;
                    panel.dropSlot = panel.dropSlotAt(centroid.scenePosition.x, centroid.scenePosition.y);
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
              // A small element: `fast` in, `instant` out.
              Text {
                id: winTitle
                readonly property bool wanted: winHover.hovered || (win.isSelected && root.showSelection) || win.peeking
                width: Math.max(win.fw, panel.width * 0.16)
                x: win.fx + (win.fw - width) / 2
                y: appIcon.y + appIcon.height + Math.round(panel.titleSize * 0.5)
                horizontalAlignment: Text.AlignHCenter
                // Untrusted: see root.displayLabel.
                textFormat: Text.PlainText
                text: root.displayLabel(win.handle.title || (win.ipc && win.ipc["class"]) || "")
                font.family: root.fontFamily
                font.pixelSize: panel.titleSize
                color: panel.overlayInk
                opacity: win.labelOpacity * (wanted && !win.dropped ? 1 : 0)
                Behavior on opacity {
                  NumberAnimation {
                    duration: winTitle.wanted ? Motion.d(Motion.fast) : Motion.instant
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: winTitle.wanted ? Motion.easeOut : Motion.easeIn
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

          // Selection is one ring in the accent colour (macOS: a blue frame
          // under the pointer) that glides from window to window -- `fast`
          // ease-in-out, or without a glide while an arrow key auto-repeats --
          // plus the nudge on the window itself. No fill and no dim on the
          // others: in the exposé the windows are the content, and dimming
          // five of six makes the whole view look switched off. A plain
          // Rectangle with nothing inside, so moving and resizing it lays out
          // nothing else. Gone the instant a close starts: left at the
          // overview rect while the window grows back, it was a ghost frame.
          Rectangle {
            id: ring
            readonly property bool wanted: root.settled && root.showSelection && !root.desktopMode
                && panel.selected >= 0 && panel.selected < panel.windows.length
            // Glides only on a change of selection: while the selected window
            // itself moves (a drag, Quick Look, the layout settling) the ring
            // sticks to it.
            property bool glide: false
            Connections {
              target: panel
              function onSelectedChanged() { ring.glide = ring.wanted && panel.dragWindow < 0 }
            }
            x: panel.selX
            y: panel.selY
            width: panel.selW
            height: panel.selH
            Behavior on x {
              enabled: ring.glide
              NumberAnimation { duration: panel.keyRepeat ? Motion.instant : Motion.travel(Motion.fast); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut; onRunningChanged: if (!running) ring.glide = false }
            }
            Behavior on y {
              enabled: ring.glide
              NumberAnimation { duration: panel.keyRepeat ? Motion.instant : Motion.travel(Motion.fast); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut; onRunningChanged: if (!running) ring.glide = false }
            }
            Behavior on width {
              enabled: ring.glide
              NumberAnimation { duration: panel.keyRepeat ? Motion.instant : Motion.travel(Motion.fast); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut }
            }
            Behavior on height {
              enabled: ring.glide
              NumberAnimation { duration: panel.keyRepeat ? Motion.instant : Motion.travel(Motion.fast); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeInOut }
            }
            // The same nudge as the window under it.
            scale: Motion.sc(Motion.scaleHover)
            transform: Translate { y: -Motion.px(Motion.hoverLift) }
            radius: panel.ringRadius
            color: "transparent"
            border.width: Math.max(2, Math.round(3 * panel.uiScale))
            border.color: Color.accent
            opacity: ring.wanted ? 1 : 0
            visible: opacity > 0.001
            Behavior on opacity {
              NumberAnimation {
                duration: ring.wanted ? Motion.d(Motion.fast) : Motion.instant
                easing.type: Easing.BezierSpline
                easing.bezierCurve: ring.wanted ? Motion.easeOut : Motion.easeIn
              }
            }
          }

          // An empty desktop says so, rather than leaving a blank half-screen
          // that looks like something failed to load.
          Text {
            visible: panel.currentCount === 0 && !root.desktopMode
            opacity: Math.max(0, Math.min(1, (root.progress - 0.55) / 0.45))
            anchors.horizontalCenter: parent.horizontalCenter
            y: panel.exposeAreaY + panel.exposeAreaH * 0.42
            textFormat: Text.PlainText
            text: root.appMode ? "No windows of this app" : "No windows"
            font.family: root.fontFamily
            font.pixelSize: Math.round(22 * panel.uiScale)
            color: Util.alpha(panel.overlayInk, panel.secondaryInkAlpha)
          }
        }
      }
    }
  }
}
