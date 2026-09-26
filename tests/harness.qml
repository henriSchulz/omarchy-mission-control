import QtQuick
import Quickshell
import Quickshell.Io

// Standalone test harness for henri.missioncontrol: loads the plugin from
// MC_PLUGIN (a directory), hands it a fake `shell`, and exposes it over IPC:
//   qs -p <this dir> ipc call mc open '{"mode":"app"}'
//   qs -p <this dir> ipc call mc hide
//   qs -p <this dir> ipc call mc state
// Run with MISSION_CONTROL_TEST_SCREEN=HEADLESS-1 so only that output gets
// the overlay and no keyboard focus is taken.
ShellRoot {
  id: harness
  property var plugin: null

  QtObject {
    id: fakeShell
    function summon(id, payload) { if (harness.plugin) harness.plugin.open(payload || "{}"); return true }
    function hide(id) { if (harness.plugin) harness.plugin.close(); return true }
    function toggle(id, payload) { if (harness.plugin && harness.plugin.opened) harness.plugin.close(); else if (harness.plugin) harness.plugin.open(payload || "{}"); return true }
  }

  Loader {
    id: loader
    source: "file://" + Quickshell.env("MC_PLUGIN") + "/MissionControl.qml"
    onLoaded: {
      harness.plugin = item
      item.shell = fakeShell
      item.manifest = { id: "henri.missioncontrol" }
      console.warn("HARNESS loaded plugin")
    }
    onStatusChanged: if (status === Loader.Error) console.warn("HARNESS load error: " + sourceComponent.errorString())
  }

  IpcHandler {
    target: "mc"
    function open(payload: string): string { if (!harness.plugin) return "no plugin"; harness.plugin.open(payload); return "ok" }
    function hide(): string { if (!harness.plugin) return "no plugin"; harness.plugin.close(); return "ok" }
    function toggle(mode: string): string { if (!harness.plugin) return "no plugin"; harness.plugin.toggle(mode); return "ok" }
    function state(): string {
      const p = harness.plugin
      if (!p) return "no plugin"
      return JSON.stringify({ opened: p.opened, shown: p.shown, expanded: p.expanded, progress: p.progress, mode: p.mode, appClass: p.appClass, extra: p.extraDesktops })
    }
    function evalq(code: string): string {
      try { const p = harness.plugin; const f = new Function("p", "harness", code); const r = f(p, harness); return r === undefined ? "ok" : String(JSON.stringify(r)) } catch (e) { return "error: " + e }
    }
    function panel(code: string): string {
      // Same, with the first overlay panel as `panel`.
      try {
        const p = harness.plugin; let v = null
        for (let i = 0; i < p.data.length; i++) { const o = p.data[i]; if (o && o.instances !== undefined) v = o }
        const panel = v ? v.instances[0] : null
        if (!panel) return "no panel"
        const f = new Function("p", "panel", code); const r = f(p, panel); return r === undefined ? "ok" : String(JSON.stringify(r))
      } catch (e) { return "error: " + e }
    }
  }
}
