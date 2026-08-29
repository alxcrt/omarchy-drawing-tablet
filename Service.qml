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
      console.log("omarchy-tablet: re-applying tablet mappings (" + root.pendingReason + ")")
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

  Component.onCompleted: console.log("omarchy-tablet: service started")

  Connections {
    target: engine
    function onApplyFinished(success) {
      if (success) console.log("omarchy-tablet: applied " + engine.appliedCount + " tablet mapping(s) and the stylus settings")
      else console.warn("omarchy-tablet: " + engine.lastError)
    }
  }
}
