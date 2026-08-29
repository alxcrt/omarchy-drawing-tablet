import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one place that talks to the outside world: probes the hardware, reads
// and writes the profile file, and pushes the result into Hyprland with
// `hyprctl eval`. The panel and the background service both instantiate it,
// so a mapping applies the same way whether a person or a hotplug asked.
Item {
  id: root

  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string documentPath: Model.documentPath(home)

  property var document: Model.parseDocument("")
  property bool documentLoaded: false
  property var tablets: []
  property var monitors: []
  property var hyprlandNames: []
  property bool uinput: false
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  property bool probed: false
  property bool probing: false
  property bool applying: false
  property bool applyQueued: false
  property bool saving: false
  property bool evalSupported: true
  property bool evalChecked: false
  property string hyprlandVersion: ""
  property string lastError: ""
  property string lastNotes: ""
  property string lastApplied: ""
  property int appliedCount: 0

  // What this engine last wrote, so a watch notification for its own save is
  // told apart from an edit made by another bar instance or by hand.
  property string lastWrittenText: ""

  signal probeFinished()
  signal applyFinished(bool success)
  signal documentReplaced()
  signal externalChange()

  readonly property int connectedCount: {
    var count = 0
    for (var i = 0; i < root.tablets.length; i++) if (root.tablets[i] && root.tablets[i].present) count++
    return count
  }

  function reloadDocument() {
    documentFile.reload()
  }

  function probe() {
    if (probeProcess.running) return
    root.probing = true
    probeProcess.command = Model.probeCommand()
    probeProcess.running = true
  }

  function probeAndApply() {
    root.applyQueued = true
    root.probe()
  }

  // Persist first, then apply: a mapping that Hyprland rejects is still worth
  // keeping on disk, since the error text tells the person what to change.
  function saveDocument(next) {
    var normalized = Model.normalizeDocument(next)
    root.document = normalized
    root.documentReplaced()
    root.saving = true
    root.lastWrittenText = Model.serializeDocument(normalized)
    saveProcess.command = Model.saveCommand(root.documentPath, root.lastWrittenText)
    saveProcess.running = true
  }

  function applyAll() {
    if (!root.evalSupported) return
    if (applyProcess.running) {
      root.applyQueued = true
      return
    }
    var plan = Model.applyPlan(root.document, root.monitors, root.hyprlandNames)
    root.lastNotes = plan.notes.join("\n")
    var command = ["sh", "-c",
      'status=0; for lua in "$@"; do out=$(hyprctl eval "$lua" 2>&1); if [ "$out" != "ok" ]; then printf "%s\\n" "$out"; status=1; fi; done; exit $status',
      "sh"]
    for (var i = 0; i < plan.statements.length; i++) command.push(plan.statements[i].lua)
    root.applying = true
    root.appliedCount = plan.statements.filter(function(statement) { return statement.id !== "" }).length
    applyProcess.command = command
    applyProcess.running = true
  }

  function checkHyprland() {
    if (versionProcess.running) return
    versionProcess.command = Model.hyprlandVersionCommand()
    versionProcess.running = true
  }

  FileView {
    id: documentFile
    path: root.documentPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var text = documentFile.text()
      var external = root.documentLoaded && text !== root.lastWrittenText
      root.lastWrittenText = text
      root.document = Model.parseDocument(text)
      root.documentLoaded = true
      root.documentReplaced()
      if (external) root.externalChange()
    }
    onLoadFailed: {
      // No file yet is the normal first run. Anything else is still not
      // fatal: whatever is in memory keeps working, and the next save writes
      // a fresh file.
      root.documentLoaded = true
      root.documentReplaced()
    }
  }

  Process {
    id: versionProcess
    stdout: StdioCollector { id: versionOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalChecked = true
      root.hyprlandVersion = String(versionOutput.text || "").split("\n")[0].trim()
      root.evalSupported = exitCode === 0 && Model.hyprlandSupportsEval(versionOutput.text)
    }
  }

  Process {
    id: probeProcess
    stdout: StdioCollector { id: probeOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.probing = false
      var probe = Model.parseProbe(probeOutput.text)
      root.tablets = probe.tablets
      root.monitors = probe.monitors
      root.hyprlandNames = probe.hyprlandNames
      root.uinput = probe.uinput === true
      root.probed = true
      var merged = Model.mergeDiscovered(root.document, probe.tablets)
      if (merged.changed) {
        // A new tablet earns a profile on disk right away, and so does any
        // correction the hardware made, so a second panel instance and the
        // service see the same document.
        root.applyQueued = true
        root.saveDocument(merged.document)
      } else {
        root.document = merged.document
        root.documentReplaced()
        if (root.applyQueued) {
          root.applyQueued = false
          root.applyAll()
        }
      }
      root.probeFinished()
    }
  }

  Process {
    id: saveProcess
    stderr: StdioCollector { id: saveErrors; waitForEnd: true }
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.lastError = "Could not write " + root.documentPath + ": " + String(saveErrors.text || "").trim()
        root.applyQueued = false
        return
      }
      root.applyQueued = false
      // The atomic rename left the watcher on the old inode; point it at the
      // new file, or outside edits go unnoticed from now on.
      documentFile.reload()
      root.applyAll()
    }
  }

  Process {
    id: applyProcess
    stdout: StdioCollector { id: applyOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      var output = String(applyOutput.text || "").trim()
      if (exitCode === 0) {
        root.lastError = ""
        root.lastApplied = new Date().toISOString()
      } else {
        root.lastError = output !== "" ? output.replace(/^error:\s*/, "Hyprland: ") : "Hyprland did not accept the tablet configuration."
      }
      root.applyFinished(exitCode === 0)
      if (root.applyQueued) {
        root.applyQueued = false
        root.applyAll()
      }
    }
  }

  Component.onCompleted: checkHyprland()
}
