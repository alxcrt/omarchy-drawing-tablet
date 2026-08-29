import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// Keeps the saved mapping in force without the panel being open. Hyprland
// forgets runtime `hl.device` state on every config reload, and a tablet
// plugged in later needs its profile pushed again, so this service watches
// for both and re-applies. Runs once per shell, not once per bar.
Item {
  id: root

  property var shell: null
  property alias engine: engine
  readonly property var tablets: engine.tablets
  readonly property string lastError: engine.lastError
  readonly property string lastApplied: engine.lastApplied

  property string pendingReason: "startup"

  function applyNow() {
    root.reapply("request")
  }

  function reapply(reason) {
    root.pendingReason = String(reason || "")
    reapplyTimer.restart()
  }

  // The panel calls this after it writes the profile file. Re-reading the file
  // is cheaper than trusting a watch that may have missed an atomic rename.
  function documentSaved() {
    engine.reloadDocument()
    root.reapply("panel save")
  }

  TabletEngine {
    id: engine
  }

  // Pen buttons as real mouse buttons. The helper is restarted whenever the
  // plan changes (a profile edit, a tablet plugged or unplugged) and stopped
  // when nothing is mapped, so it costs nothing until someone asks for it.
  property string helperPlan: ""
  property string helperError: ""

  function syncHelper() {
    var plan = Model.penButtonPlan(engine.document, engine.tablets)
    var text = plan.tablets.length ? JSON.stringify(plan) : ""
    if (text === root.helperPlan && (helper.running || text === "")) return
    root.helperPlan = text
    if (helper.running) {
      // Stopping it makes onExited start the new plan.
      helper.running = false
      return
    }
    root.startHelper()
  }

  function startHelper() {
    if (root.helperPlan === "" || helper.running) return
    if (!engine.uinput) {
      root.helperError = "Virtual input is not available: /dev/uinput is not open to this user."
      console.warn("omarchy-drawing-tablet: " + root.helperError)
      return
    }
    root.helperError = ""
    helper.command = Model.penButtonsCommand(engine.pluginDir, JSON.parse(root.helperPlan))
    helper.running = true
  }

  Process {
    id: helper
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { if (String(line || "").trim() !== "") console.log("omarchy-drawing-tablet pen buttons: " + line) }
    }
    onExited: function(exitCode) {
      // A plan change stops the old helper; start the new one. Any other
      // exit is retried after a pause so an unplugged tablet does not spin.
      if (root.helperPlan !== "") helperRestartTimer.restart()
    }
  }

  Timer {
    id: helperRestartTimer
    interval: 1500
    onTriggered: root.startHelper()
  }

  // The shell recreates this service on a plugin reload; the old helper must
  // go with the old instance or two virtual mice would press every button.
  Component.onDestruction: {
    root.helperPlan = ""
    if (helper.running) helper.running = false
  }

  Connections {
    target: engine
    function onProbeFinished() { root.syncHelper() }
  }

  // Hyprland has no IPC event for input devices, so udev is the hotplug
  // signal. Only the input subsystem is watched, and the burst of add events a
  // tablet raises (pen, pad, touch) collapses into one re-apply.
  Process {
    id: udevMonitor
    command: ["udevadm", "monitor", "--udev", "--subsystem-match=input"]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (/^UDEV\s+\[[0-9.]+\]\s+(add|remove)\s/.test(String(line || ""))) root.reapply("input hotplug")
      }
    }
    onExited: function(exitCode) { udevRestartTimer.restart() }
  }

  Timer {
    id: udevRestartTimer
    interval: 5000
    onTriggered: if (!udevMonitor.running) udevMonitor.running = true
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "configreloaded" || name === "monitoradded" || name === "monitorremoved") root.reapply(name)
    }
  }

  Timer {
    id: reapplyTimer
    interval: 1200
    onTriggered: {
      console.log("omarchy-drawing-tablet: re-applying tablet mappings (" + root.pendingReason + ")")
      // Re-read the profile first: a re-apply is exactly when a stale copy
      // would do damage, and the read is free.
      engine.reloadDocument()
      engine.probeAndApply()
    }
  }

  // The shell starts alongside Hyprland; give the compositor a moment to list
  // the devices before the first apply so a boot-time tablet is not missed.
  Timer {
    id: startupTimer
    interval: 2000
    running: true
    onTriggered: root.reapply("startup")
  }

  Connections {
    target: engine
    // Another bar instance saved, or someone edited the file by hand. The
    // engine's own saves and probes do not raise this, so there is no loop.
    function onExternalChange() { root.reapply("profile file changed") }
  }

  Component.onCompleted: console.log("omarchy-drawing-tablet: service started")

  Connections {
    target: engine
    function onApplyFinished(success) {
      if (success) console.log("omarchy-drawing-tablet: applied " + engine.appliedCount + " tablet mapping(s) and the stylus settings")
      else console.warn("omarchy-drawing-tablet: " + engine.lastError)
    }
  }
}
