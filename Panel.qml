import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.alxcrt.drawing-tablet"
  ipcTarget: "io.github.alxcrt.drawing-tablet"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real disabledOpacity: 0.45

  property string selectedTabletId: ""
  property bool expanded: false
  property bool keyboardHelpOpen: false
  property int cursorIndex: 0
  property bool cursorActive: false
  property bool pluginUpdateAvailable: false
  property bool pluginUpdating: false
  property string lastError: ""
  property var pendingStylus: null
  property bool manualScan: false

  // The background service is mounted once by the shell; the panel finds it
  // through the bar's host so a save can ask it to re-apply, and works alone
  // when it is not there.
  readonly property var coordinator: {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    var services = host ? host._services : null
    return services && services[root.moduleName] ? services[root.moduleName] : null
  }

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", false) === true
  visible: !(hideWhenDisconnected && !tabletConnected)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  readonly property var document: engine.document
  readonly property var profiles: document && document.tablets instanceof Array ? document.tablets : []
  readonly property var stylus: document && document.stylus ? document.stylus : Model.defaultStylus()
  readonly property var profile: Model.profileById(document, selectedTabletId)
  readonly property var liveTablet: Model.tabletById(engine.tablets, selectedTabletId)
  readonly property bool tabletConnected: engine.connectedCount > 0
  readonly property bool selectedConnected: !!liveTablet && liveTablet.present === true
  readonly property bool hyprlandTooOld: engine.evalChecked && !engine.evalSupported
  readonly property bool mappingApplied: engine.lastApplied !== "" && engine.lastError === ""
  readonly property bool barIconDimmed: engine.probed && !tabletConnected
  readonly property string barTooltip: root.profile && root.selectedConnected
    ? String(root.profile.label || "Drawing tablet") + " → " + Model.describeOutput(root.profile, engine.monitors)
    : (engine.probed && !root.tabletConnected ? "Drawing tablet · none connected" : "Drawing tablet")
  readonly property var outputOptions: Model.outputOptionsFor(root.profile, engine.monitors)
  readonly property var tabletOptions: Model.tabletOptions(root.profiles, engine.tablets)
  readonly property bool followsFocus: !!root.profile && root.profile.output.mode === "current"
  readonly property bool customRegion: !!root.profile && root.profile.region.mode === "custom"
  readonly property bool customArea: !!root.profile && root.profile.activeArea.mode === "custom"
  readonly property var tabletSize: Model.effectiveTabletSize(root.profile)
  // libinput decides what a tablet can do; the panel only offers what will
  // actually happen under the pen.
  readonly property bool rotationAvailable: !!root.profile && root.profile.rotatable !== false
  readonly property bool leftHandedAvailable: !!root.profile && root.profile.reversible !== false
  readonly property bool displayTablet: !!root.liveTablet && root.liveTablet.display === true
  readonly property bool eraserButtonPresent: Model.anyEraserButton(engine.tablets)
  readonly property bool penButtonsMapped: !!root.profile && Model.penButtonSummary(root.profile) !== "apps decide"
  readonly property string connectionLabel: root.profile
    ? (root.selectedConnected ? "Connected · " + Model.mappingSummary(root.profile, engine.monitors) : "Not connected")
    : (engine.probed ? "No tablet connected" : "Looking for tablets…")
  readonly property string statusText: {
    if (root.lastError !== "") return root.lastError
    if (engine.lastError !== "") return engine.lastError
    if (engine.applying || engine.saving) return "Applying…"
    if (engine.probing && !engine.probed) return "Scanning…"
    if (engine.lastNotes !== "") return engine.lastNotes
    if (root.mappingApplied) return "Applied to Hyprland"
    return ""
  }
  readonly property bool statusIsError: root.lastError !== "" || engine.lastError !== ""

  // Rows that appear only sometimes (an update offer) are listed here, so the
  // keyboard cursor counts exactly what is on screen.
  readonly property var actionRows: {
    var rows = []
    if (root.pluginUpdateAvailable)
      rows.push({ id: "update-plugin", icon: "󰚰",
                  title: root.pluginUpdating ? "Updating this panel…" : "Update this panel",
                  subtitle: root.pluginUpdating ? "Pulling the new version" : "A newer version is available" })
    return rows
  }

  // Compact keyboard cursor: one flat list of what is on screen, in order.
  readonly property var cursorRows: {
    var rows = []
    if (root.profile) {
      if (root.tabletOptions.length > 1) rows.push("tablet")
      rows.push("output", "region", "area")
      if (root.rotationAvailable) rows.push("transform")
      if (root.leftHandedAvailable) rows.push("leftHanded")
      rows.push("relative")
    }
    for (var i = 0; i < root.actionRows.length; i++) rows.push("action:" + root.actionRows[i].id)
    return rows
  }
  readonly property string cursorRow: root.cursorActive && root.cursorIndex >= 0 && root.cursorIndex < root.cursorRows.length
    ? root.cursorRows[root.cursorIndex] : ""

  function hasCursor(row) {
    return !root.expanded && root.cursorRow === row
  }

  function moveCursor(delta) {
    if (root.cursorRows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.cursorIndex = delta > 0 ? 0 : root.cursorRows.length - 1
      return
    }
    root.cursorIndex = Math.max(0, Math.min(root.cursorRows.length - 1, root.cursorIndex + delta))
  }

  function activateCursor() {
    var row = root.cursorRow
    if (row === "tablet") compactControls.tabletDropdown.toggle()
    else if (row === "output") compactControls.outputDropdown.toggle()
    else if (row === "region") compactControls.regionDropdown.toggle()
    else if (row === "area") compactControls.areaDropdown.toggle()
    else if (row === "transform") compactControls.transformDropdown.toggle()
    else if (row === "leftHanded") root.toggleLeftHanded()
    else if (row === "relative") root.toggleRelative()
    else if (row.indexOf("action:") === 0) root.activateRow(row.slice(7))
  }

  function cycleCursor(delta) {
    var row = root.cursorRow
    if (!root.profile) return
    if (row === "tablet") root.selectedTabletId = Model.cycleOptionValue(root.tabletOptions, root.selectedTabletId, delta)
    else if (row === "output") root.setOutput(Model.cycleOptionValue(root.outputOptions, Model.outputValue(root.profile), delta))
    else if (row === "region") root.setRegionMode(Model.cycleOptionValue(Model.regionOptions(), root.profile.region.mode, delta))
    else if (row === "area") root.setAreaMode(Model.cycleOptionValue(Model.activeAreaOptions(), root.profile.activeArea.mode, delta))
    else if (row === "transform") root.setTransform(Model.cycleOptionValue(Model.transformOptions(), String(root.profile.transform), delta))
    else if (row === "leftHanded") root.toggleLeftHanded()
    else if (row === "relative") root.toggleRelative()
  }

  function activateRow(id) {
    if (id === "update-plugin") root.updatePlugin()
  }

  // ---------------------------------------------------------------- editing

  function selectInitialTablet() {
    root.selectedTabletId = Model.initialTabletId(root.profiles, engine.tablets, root.selectedTabletId)
  }

  function saveProfile(next) {
    root.lastError = ""
    engine.saveDocument(Model.upsertProfile(root.document, next))
  }

  function editProfile(patch) {
    if (!root.profile) return
    var next = Model.clone(root.profile)
    for (var key in patch) next[key] = patch[key]
    root.saveProfile(next)
  }

  function setOutput(value) {
    if (!root.profile) return
    root.saveProfile(Model.withOutputValue(root.profile, value, engine.monitors))
  }

  function setRegionMode(mode) {
    if (!root.profile) return
    var region = Model.clone(root.profile.region)
    region.mode = String(mode)
    root.editProfile({ region: region })
  }

  function setRegion(region) {
    root.editProfile({ region: Model.clampRegion(region) })
  }

  function setAreaMode(mode) {
    if (!root.profile) return
    var area = Model.clone(root.profile.activeArea)
    area.mode = String(mode)
    if (area.mode === "custom" && (area.w <= 0 || area.h <= 0)) {
      area.x = 0
      area.y = 0
      area.w = root.tabletSize.width
      area.h = root.tabletSize.height
    }
    root.editProfile({ activeArea: area })
  }

  function setActiveArea(patch) {
    if (!root.profile) return
    var area = Model.clone(root.profile.activeArea)
    for (var key in patch) area[key] = patch[key]
    area.mode = "custom"
    root.editProfile({ activeArea: area })
  }

  function setTransform(value) {
    root.editProfile({ transform: Number(value) })
  }

  function toggleLeftHanded() {
    if (root.profile) root.editProfile({ leftHanded: !root.profile.leftHanded })
  }

  function toggleRelative() {
    if (root.profile) root.editProfile({ relativeInput: !root.profile.relativeInput })
  }

  function setButton(which, action) {
    if (!root.profile) return
    var buttons = Model.normalizeButtons(root.profile.buttons)
    buttons[which] = String(action)
    root.editProfile({ buttons: buttons })
  }

  function allowVirtualInput() {
    root.lastError = ""
    uinputSetupProcess.command = Model.uinputRuleCommand()
    uinputSetupProcess.startDetached()
  }

  Process { id: uinputSetupProcess }

  function nudgeRegion(dx, dy, dw, dh) {
    if (!root.profile || !root.customRegion) return
    root.setRegion(Model.nudgeRegion(root.profile, dx, dy, dw, dh))
  }

  function resetProfile() {
    if (!root.profile) return
    var fresh = Model.defaultProfile(root.profile)
    root.saveProfile(fresh)
  }

  function forgetTablet(id) {
    root.lastError = ""
    engine.saveDocument(Model.removeProfile(root.document, id))
    root.selectedTabletId = ""
    root.selectInitialTablet()
  }

  // Slider drags preview immediately but persist once the hand settles, so the
  // profile file is not rewritten on every pixel of movement.
  function editStylus(patch, immediate) {
    var next = Model.clone(root.pendingStylus || root.stylus)
    for (var key in patch) next[key] = patch[key]
    root.pendingStylus = next
    if (immediate === true) {
      stylusDebounce.stop()
      root.commitStylus()
    } else {
      stylusDebounce.restart()
    }
  }

  function commitStylus() {
    if (!root.pendingStylus) return
    var next = Model.clone(root.document)
    next.stylus = root.pendingStylus
    root.pendingStylus = null
    root.lastError = ""
    engine.saveDocument(next)
  }

  function rescan() {
    root.lastError = ""
    root.manualScan = true
    engine.probeAndApply()
  }

  function applyAgain() {
    root.lastError = ""
    engine.applyAll()
  }

  function notifyCoordinator() {
    if (root.coordinator && typeof root.coordinator.documentSaved === "function") root.coordinator.documentSaved()
  }

  // ---------------------------------------------------------------- lifecycle

  function open() {
    root.controller.show()
    root.cursorActive = false
    root.cursorIndex = 0
    engine.checkHyprland()
    engine.reloadDocument()
    engine.probe()
    root.checkPluginUpdate()
  }

  function openFromHotkey() { root.open() }

  function close() {
    root.keyboardHelpOpen = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function handleTextKey(text) {
    var key = String(text || "")
    if (root.keyboardHelpOpen) {
      root.keyboardHelpOpen = false
      return
    }
    if (key === "?") root.keyboardHelpOpen = true
    else if (key === "q") root.close()
    else if (key === "e") root.expanded = !root.expanded
    else if (key === "r") root.rescan()
    else if (key === "a") root.applyAgain()
    else if (key === "d") root.resetProfile()
  }

  onExpandedChanged: {
    root.cursorActive = false
    root.keyboardHelpOpen = false
  }

  onOpenedChanged: if (!opened) root.expanded = false

  // ---------------------------------------------------------------- plugin update

  function checkPluginUpdate() {
    if (pluginUpdateProcess.running || root.pluginUpdating) return
    pluginUpdateProcess.command = Model.pluginUpdateCheckCommand(root.moduleName, 6)
    pluginUpdateProcess.running = true
  }

  function updatePlugin() {
    if (pluginUpdateRunProcess.running || root.pluginUpdating) return
    root.lastError = ""
    root.pluginUpdating = true
    pluginUpdateRunProcess.command = Model.pluginUpdateCommand(root.moduleName)
    pluginUpdateRunProcess.running = true
  }

  Process {
    id: pluginUpdateProcess
    onExited: function(exitCode) {
      // Exit 10 is the one answer that means something; every other status
      // (no checkout, no network) is a reason to stay quiet, not to nag.
      root.pluginUpdateAvailable = exitCode === 10
    }
  }

  Process {
    id: pluginUpdateRunProcess
    stdout: StdioCollector { id: pluginUpdateOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.pluginUpdating = false
      if (exitCode !== 0) {
        root.lastError = "The panel update did not finish. Run `omarchy plugin update " + root.moduleName + "` to see why."
        return
      }
      root.pluginUpdateAvailable = false
      // A pulled update only takes effect once the shell restarts, since the
      // running QML is still the old version.
      if (Model.pluginUpdated(pluginUpdateOutput.text)) {
        shellRestartProcess.command = Model.shellRestartCommand()
        shellRestartProcess.startDetached()
      }
    }
  }

  Process { id: shellRestartProcess }

  // ---------------------------------------------------------------- engine

  TabletEngine {
    id: engine
    onDocumentReplaced: root.selectInitialTablet()
    onProbeFinished: {
      root.manualScan = false
      root.selectInitialTablet()
    }
    onApplyFinished: function(success) { root.notifyCoordinator() }
  }

  Timer {
    id: stylusDebounce
    interval: 250
    onTriggered: root.commitStylus()
  }

  // Tablets come and go while the panel is open; a light poll keeps the
  // connection state honest without a udev watcher per bar instance.
  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: engine.probe()
  }

  // Apply once on load as well, so the bar badge and status reflect the
  // mapping that is in force even before anything is changed.
  Component.onCompleted: engine.probeAndApply()

  // ---------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰽉"
    dimmed: root.barIconDimmed
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        OpticalGlyph {
          id: glyph
          anchors.fill: parent
          text: button.text
          color: button.foreground
          fontFamily: button.fontFamily
          fontSize: button.fontSize
        }

        Text {
          textFormat: Text.PlainText
          visible: root.tabletConnected && root.mappingApplied
          anchors.right: glyph.right
          anchors.bottom: glyph.bottom
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
          text: "󰄬"
          color: Color.accent
          font.family: button.fontFamily
          font.pixelSize: Math.max(7, Math.round(button.fontSize * 0.45))
          font.bold: true
        }
      }
    }
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  // ---------------------------------------------------------------- window

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.expanded ? 980 : 430))
    contentHeight: root.expanded
      ? panel.fittedContentHeight(Style.space(640))
      : panel.fittedContentHeight(compactColumn.implicitHeight)

    Item {
      width: 0
      height: 0

      Shortcut {
        sequence: "Shift+Left"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(-0.01, 0, 0, 0)
      }
      Shortcut {
        sequence: "Shift+Right"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0.01, 0, 0, 0)
      }
      Shortcut {
        sequence: "Shift+Up"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0, -0.01, 0, 0)
      }
      Shortcut {
        sequence: "Shift+Down"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0, 0.01, 0, 0)
      }
      Shortcut {
        sequence: "Ctrl+Left"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0, 0, -0.01, 0)
      }
      Shortcut {
        sequence: "Ctrl+Right"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0, 0, 0.01, 0)
      }
      Shortcut {
        sequence: "Ctrl+Up"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0, 0, 0, -0.01)
      }
      Shortcut {
        sequence: "Ctrl+Down"
        enabled: root.opened && root.expanded && root.customRegion && !root.keyboardHelpOpen && !keyCatcher.blocked
        onActivated: root.nudgeRegion(0, 0, 0, 0.01)
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: compactControls.anyPopupOpen
        || expandedControls.anyPopupOpen
        || expandedTabletControls.anyPopupOpen
        || stylusControls.anyPopupOpen
        || button1Dropdown.popupOpen || button2Dropdown.popupOpen || eraserDropdown.popupOpen
        || regionXField.field.activeFocus || regionYField.field.activeFocus
        || regionWField.field.activeFocus || regionHField.field.activeFocus
        || areaXField.field.activeFocus || areaYField.field.activeFocus
        || areaWField.field.activeFocus || areaHField.field.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.keyboardHelpOpen) { root.keyboardHelpOpen = false; return }
        if (root.expanded) return
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0 && root.cursorActive) root.cycleCursor(dx)
      }
      onActivateRequested: {
        if (root.keyboardHelpOpen) { root.keyboardHelpOpen = false; return }
        if (!root.expanded && root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.keyboardHelpOpen) root.keyboardHelpOpen = false
        else if (root.expanded) root.expanded = false
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.keyboardHelpOpen) { root.keyboardHelpOpen = false; return }
        if (!root.expanded) root.switchPanel(direction)
      }
      onTextKey: function(text) { root.handleTextKey(text) }

      // ------------------------------------------------------------ compact
      Column {
        id: compactColumn
        visible: !root.expanded
        width: parent.width
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(compactHeroIcon.implicitHeight, compactHeroLabels.implicitHeight, compactExpandButton.implicitHeight)

          Item {
            id: compactHeroIcon
            implicitWidth: compactHeroGlyph.implicitWidth
            implicitHeight: compactHeroGlyph.implicitHeight
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            opacity: root.selectedConnected ? 1.0 : 0.6

            Text {
              textFormat: Text.PlainText
              id: compactHeroGlyph
              text: "󰽉"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Text {
              textFormat: Text.PlainText
              visible: root.selectedConnected && root.mappingApplied
              anchors.right: compactHeroGlyph.right
              anchors.bottom: compactHeroGlyph.bottom
              anchors.rightMargin: -Style.space(2)
              anchors.bottomMargin: -Style.space(1)
              text: "󰄬"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Column {
            id: compactHeroLabels
            anchors.left: compactHeroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: compactExpandButton.visible ? compactExpandButton.left : parent.right
            anchors.rightMargin: compactExpandButton.visible ? Style.space(10) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.profile ? String(root.profile.label || "Tablet") : "Drawing tablet"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.connectionLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Button {
            id: compactExpandButton
            visible: !!root.profile && !root.hyprlandTooOld
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Expand"
            iconText: "󰊓"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.expanded = true
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.hyprlandTooOld
          width: parent.width
          text: "This panel needs Hyprland 0.55 or newer, which configures input devices through Lua. Found: "
            + (engine.hyprlandVersion !== "" ? engine.hyprlandVersion : "no hyprctl")
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Column {
          visible: root.profiles.length === 0 && !root.hyprlandTooOld
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: engine.probed
              ? "No drawing tablet detected. Plug one in and this panel picks it up on its own; the mapping you choose is remembered by make, model and serial."
              : "Looking for drawing tablets…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: root.manualScan && engine.probing ? "Scanning…" : "Rescan"
            iconText: "󰑓"
            bordered: true
            enabled: !(root.manualScan && engine.probing)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.rescan()
          }
        }

        Column {
          visible: !!root.profile && !root.hyprlandTooOld
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator { foreground: root.foreground }

          PanelDropdown {
            id: compactTabletDropdown
            visible: root.tabletOptions.length > 1
            popupParent: keyCatcher
            ownerOpen: root.opened && !root.expanded
            width: parent.width
            label: "TABLET"
            options: root.tabletOptions
            value: root.selectedTabletId
            hasCursor: root.hasCursor("tablet")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { root.selectedTabletId = value }
          }

          MappingControls {
            id: compactControls
            width: parent.width
            ownerOpen: root.opened && !root.expanded
            tabletDropdown: compactTabletDropdown
          }

          ToggleRows {
            width: parent.width
          }

          MappingCanvas {
            width: parent.width
            height: Style.space(190)
            profile: root.profile
            monitors: engine.monitors
            interactive: false
            foreground: root.foreground
            dim: root.dim
            accent: Color.accent
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.actionRows
            ActionRow {
              required property var modelData
              required property int index
              width: parent.width
              rowKey: "action:" + String(modelData.id || "")
              icon: String(modelData.icon || "")
              title: String(modelData.title || "")
              subtitle: String(modelData.subtitle || "")
              enabled: !root.pluginUpdating
              onActivated: root.activateRow(String(modelData.id || ""))
            }
          }

          StatusRow {
            width: parent.width
          }
        }
      }

      // ------------------------------------------------------------ expanded
      Item {
        id: expandedEditor
        visible: root.expanded
        anchors.fill: parent

        Item {
          id: editorNav
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Style.space(38)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "󰽉"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                text: root.profile ? String(root.profile.label || "Tablet") : "Drawing tablet"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: root.connectionLabel
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              text: "Keys"
              iconText: "?"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.keyboardHelpOpen = true
            }

            Button {
              text: "Compact"
              iconText: "󰊔"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.expanded = false
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
          }
        }

        Item {
          id: editorBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: editorNav.bottom
          anchors.bottom: editorFooter.top
          anchors.topMargin: Style.space(12)
          anchors.bottomMargin: Style.space(12)

          EditorPane {
            id: previewPane
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: tabletsPane.top
            anchors.bottomMargin: Style.space(12)
            width: Math.round(parent.width * 0.52)
            title: "Mapping preview"
            meta: root.customRegion ? "drag the region to move it" : (root.profile ? Model.describeOutput(root.profile, engine.monitors) : "")
            active: true
            foreground: root.foreground
            dim: root.dim
            accent: Color.accent
            fontFamily: root.fontFamily

            MappingCanvas {
              anchors.fill: parent
              profile: root.profile
              monitors: engine.monitors
              interactive: true
              foreground: root.foreground
              dim: root.dim
              accent: Color.accent
              fontFamily: root.fontFamily
              onRegionEdited: function(region) { root.setRegion(region) }
            }
          }

          EditorPane {
            id: tabletsPane
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            width: previewPane.width
            height: Style.space(150)
            title: "Tablets"
            meta: engine.connectedCount + " connected"
            foreground: root.foreground
            dim: root.dim
            accent: Color.accent
            fontFamily: root.fontFamily

            ListView {
              anchors.fill: parent
              clip: true
              spacing: Style.space(4)
              model: root.profiles

              delegate: BorderSurface {
                required property var modelData
                readonly property bool selected: String(modelData.id || "") === root.selectedTabletId
                readonly property var live: Model.tabletById(engine.tablets, modelData.id)
                width: ListView.view.width
                height: Style.space(34)
                color: selected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
                borderSpec: selected ? Border.controlSpec("selected", root.foreground, Color.accent) : Border.none()
                radius: Style.cornerRadius

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedTabletId = String(parent.modelData.id || "")
                }

                Column {
                  anchors.left: parent.left
                  anchors.right: forgetButton.left
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: String(parent.parent.modelData.label || "Tablet")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: (parent.parent.live && parent.parent.live.present ? "connected · " : "not connected · ")
                      + Model.mappingSummary(parent.parent.modelData, engine.monitors)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  id: forgetButton
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰅙"
                  tooltipText: "Forget this tablet"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: root.forgetTablet(String(parent.modelData.id || ""))
                }
              }
            }
          }

          ScrollView {
            id: settingsScroll
            anchors.left: previewPane.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: Style.space(12)
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy: settingsColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

            Column {
              id: settingsColumn
              width: settingsScroll.availableWidth
              spacing: Style.space(12)

              EditorPane {
                width: parent.width
                height: mappingContent.implicitHeight + Style.space(42)
                title: "Mapping"
                meta: root.profile ? Model.describeOutput(root.profile, engine.monitors) : ""
                foreground: root.foreground
                dim: root.dim
                accent: Color.accent
                fontFamily: root.fontFamily

                Column {
                  id: mappingContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  spacing: Style.space(10)

                  MappingControls {
                    id: expandedControls
                    width: parent.width
                    ownerOpen: root.opened && root.expanded
                    tabletDropdown: compactTabletDropdown
                  }

                  Grid {
                    visible: root.customRegion
                    width: parent.width
                    columns: 4
                    spacing: Style.space(8)
                    readonly property real cellWidth: (width - spacing * 3) / 4
                    opacity: root.followsFocus ? root.disabledOpacity : 1.0
                    enabled: !root.followsFocus

                    NumberField {
                      id: regionXField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "LEFT %"
                      from: 0
                      to: 95
                      value: root.profile ? Math.round(root.profile.region.x * 100) : 0
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        var region = Model.clone(root.profile.region)
                        region.x = value / 100
                        root.setRegion(region)
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }

                    NumberField {
                      id: regionYField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "TOP %"
                      from: 0
                      to: 95
                      value: root.profile ? Math.round(root.profile.region.y * 100) : 0
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        var region = Model.clone(root.profile.region)
                        region.y = value / 100
                        root.setRegion(region)
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }

                    NumberField {
                      id: regionWField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "WIDTH %"
                      from: 5
                      to: 100
                      value: root.profile ? Math.round(root.profile.region.w * 100) : 100
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        var region = Model.clone(root.profile.region)
                        region.w = value / 100
                        root.setRegion(region)
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }

                    NumberField {
                      id: regionHField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "HEIGHT %"
                      from: 5
                      to: 100
                      value: root.profile ? Math.round(root.profile.region.h * 100) : 100
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        var region = Model.clone(root.profile.region)
                        region.h = value / 100
                        root.setRegion(region)
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.displayTablet && !root.followsFocus && !!root.profile && root.profile.output.mode !== "monitor"
                    width: parent.width
                    text: "This tablet is a screen. Map it to its own display so the pen lands under its tip."
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.followsFocus
                    width: parent.width
                    text: "While the tablet follows the focused screen, the region and active area cannot be measured ahead of time, so the whole screen and the whole tablet are used."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }

              EditorPane {
                width: parent.width
                height: tabletContent.implicitHeight + Style.space(42)
                title: "Tablet"
                meta: root.liveTablet ? Model.tabletSizeLabel(root.liveTablet) : (root.profile ? Model.tabletSizeLabel(root.profile) : "")
                foreground: root.foreground
                dim: root.dim
                accent: Color.accent
                fontFamily: root.fontFamily

                Column {
                  id: tabletContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  spacing: Style.space(8)

                  Column {
                    width: parent.width
                    spacing: Style.space(3)

                    InfoRow { label: "Model"; value: root.profile ? String(root.profile.label || "") : "" }
                    InfoRow { label: "Vendor"; value: root.liveTablet ? String(root.liveTablet.vendor || "") : "—" }
                    InfoRow { label: "Device"; value: root.profile ? String(root.profile.kernelName || "") : "" }
                    InfoRow { label: "Hyprland name"; value: root.profile ? Model.hyprlandDeviceName(root.profile.kernelName) : "" }
                    InfoRow { label: "Pen"; value: root.liveTablet ? (Model.stylusSummary(root.liveTablet) || "—") : "—" }
                    InfoRow { label: "Pen buttons"; value: root.liveTablet ? Model.penLabel(root.liveTablet) : "—" }
                    InfoRow { label: "Pad"; value: root.liveTablet ? Model.padLabel(root.liveTablet) : "—" }
                    InfoRow { label: "Rotation"; value: root.liveTablet ? Model.rotationSupportLabel(root.liveTablet) : "—" }
                    InfoRow { label: "Identity"; value: root.profile ? String(root.profile.id || "") : "" }
                    InfoRow { label: "Status"; value: root.selectedConnected ? "connected" : "not connected"; valueAccent: root.selectedConnected }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "Pen buttons and the eraser reach the app under the pen through the Wayland tablet protocol: in apps that support tablets they act as middle and right click unless the app assigns them; apps without tablet support only see the pointer move. Hyprland does not remap them."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  ToggleRows {
                    id: expandedTabletControls
                    width: parent.width
                  }

                  Grid {
                    visible: root.customArea
                    width: parent.width
                    columns: 4
                    spacing: Style.space(8)
                    readonly property real cellWidth: (width - spacing * 3) / 4
                    opacity: root.followsFocus ? root.disabledOpacity : 1.0
                    enabled: !root.followsFocus

                    NumberField {
                      id: areaXField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "LEFT MM"
                      from: 0
                      to: Math.max(0, Math.round(root.tabletSize.width))
                      value: root.profile ? Math.round(root.profile.activeArea.x) : 0
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        root.setActiveArea({ x: value })
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }

                    NumberField {
                      id: areaYField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "TOP MM"
                      from: 0
                      to: Math.max(0, Math.round(root.tabletSize.height))
                      value: root.profile ? Math.round(root.profile.activeArea.y) : 0
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        root.setActiveArea({ y: value })
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }

                    NumberField {
                      id: areaWField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "WIDTH MM"
                      from: 1
                      to: Math.max(1, Math.round(root.tabletSize.width))
                      value: root.profile ? Math.round(root.profile.activeArea.w) : 0
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        root.setActiveArea({ w: value })
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }

                    NumberField {
                      id: areaHField
                      width: parent.cellWidth
                      fieldWidth: width
                      label: "HEIGHT MM"
                      from: 1
                      to: Math.max(1, Math.round(root.tabletSize.height))
                      value: root.profile ? Math.round(root.profile.activeArea.h) : 0
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(value) {
                        root.setActiveArea({ h: value })
                        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }
                  }
                }
              }

              EditorPane {
                width: parent.width
                height: buttonsContent.implicitHeight + Style.space(42)
                title: "Pen buttons"
                meta: root.profile ? Model.penButtonSummary(root.profile) : ""
                foreground: root.foreground
                dim: root.dim
                accent: Color.accent
                fontFamily: root.fontFamily

                Column {
                  id: buttonsContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "Hyprland hands pen buttons only to apps with tablet support. Map one here and the plugin presses a real mouse button for it, in every app, where the pen already put the cursor. Leave it to the app in drawing apps that already use the buttons, or they will fire twice."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Grid {
                    width: parent.width
                    columns: 3
                    spacing: Style.space(8)
                    readonly property real cellWidth: (width - spacing * 2) / 3

                    PanelDropdown {
                      id: button1Dropdown
                      popupParent: keyCatcher
                      ownerOpen: root.opened && root.expanded
                      width: parent.cellWidth
                      label: "BUTTON 1"
                      options: Model.buttonActionOptions()
                      value: root.profile ? root.profile.buttons.button1 : "app"
                      enabled: !!root.profile
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onChanged: function(value) { root.setButton("button1", value) }
                    }

                    PanelDropdown {
                      id: button2Dropdown
                      popupParent: keyCatcher
                      ownerOpen: root.opened && root.expanded
                      width: parent.cellWidth
                      label: "BUTTON 2"
                      options: Model.buttonActionOptions()
                      value: root.profile ? root.profile.buttons.button2 : "app"
                      enabled: !!root.profile
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onChanged: function(value) { root.setButton("button2", value) }
                    }

                    PanelDropdown {
                      id: eraserDropdown
                      popupParent: keyCatcher
                      ownerOpen: root.opened && root.expanded
                      width: parent.cellWidth
                      label: "ERASER END"
                      options: Model.buttonActionOptions()
                      value: root.profile ? root.profile.buttons.eraser : "app"
                      enabled: !!root.profile
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onChanged: function(value) { root.setButton("eraser", value) }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.penButtonsMapped && engine.probed && !engine.uinput
                    width: parent.width
                    text: "Virtual input is not available on this machine (/dev/uinput is not open to your user), so these mappings cannot act yet. Allow it once below; it asks for your password."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Button {
                    visible: root.penButtonsMapped && engine.probed && !engine.uinput
                    text: "Allow virtual input"
                    iconText: "󰌆"
                    bordered: true
                    selected: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.allowVirtualInput()
                  }
                }
              }

              EditorPane {
                width: parent.width
                height: stylusControls.implicitHeight + Style.space(42)
                title: "Stylus"
                meta: "applies to every tablet"
                foreground: root.foreground
                dim: root.dim
                accent: Color.accent
                fontFamily: root.fontFamily

                StylusControls {
                  id: stylusControls
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                }
              }
            }
          }
        }

        BorderSurface {
          id: editorFooter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(52)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.018)
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
          radius: Style.cornerRadius

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: footerButtons.left
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText !== "" ? root.statusText : "Changes apply and save as you make them."
            color: root.statusIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
          }

          Row {
            id: footerButtons
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              text: root.manualScan && engine.probing ? "Scanning…" : "Rescan"
              iconText: "󰑓"
              bordered: true
              enabled: !(root.manualScan && engine.probing)
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.rescan()
            }

            Button {
              text: "Apply again"
              iconText: "󰄬"
              bordered: true
              enabled: !engine.applying && !!root.profile
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.applyAgain()
            }

            Button {
              text: "Defaults"
              iconText: "󰦛"
              bordered: true
              enabled: !!root.profile
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.resetProfile()
            }
          }
        }
      }

      KeyboardHelp {
        anchors.fill: parent
        z: 100
        visible: root.keyboardHelpOpen
        expanded: root.expanded
        foreground: root.foreground
        background: root.bar ? root.bar.background : Color.background
        accent: Color.accent
        fontFamily: root.fontFamily
        onCloseRequested: root.keyboardHelpOpen = false
      }
    }
  }

  // ---------------------------------------------------------------- pieces

  component MappingControls: Grid {
    id: controls
    property bool ownerOpen: true
    property var tabletDropdown: null
    property alias outputDropdown: outputDropdown
    property alias regionDropdown: regionDropdown
    property alias areaDropdown: areaDropdown
    property alias transformDropdown: transformDropdown
    readonly property bool anyPopupOpen: outputDropdown.popupOpen || regionDropdown.popupOpen
      || areaDropdown.popupOpen || transformDropdown.popupOpen
      || (tabletDropdown ? tabletDropdown.popupOpen === true : false)

    columns: 2
    spacing: Style.space(8)
    readonly property real cellWidth: (width - spacing) / 2

    PanelDropdown {
      id: outputDropdown
      popupParent: keyCatcher
      ownerOpen: controls.ownerOpen
      width: controls.cellWidth
      label: "MAP TO"
      options: root.outputOptions
      value: root.profile ? Model.outputValue(root.profile) : "layout"
      enabled: !!root.profile
      hasCursor: root.hasCursor("output")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(value) { root.setOutput(value) }
    }

    PanelDropdown {
      id: regionDropdown
      popupParent: keyCatcher
      ownerOpen: controls.ownerOpen
      width: controls.cellWidth
      label: "SCREEN AREA"
      options: Model.regionOptions()
      value: root.profile ? root.profile.region.mode : "full"
      enabled: !!root.profile && !root.followsFocus
      opacity: root.followsFocus ? root.disabledOpacity : 1.0
      hasCursor: root.hasCursor("region")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(value) { root.setRegionMode(value) }
    }

    PanelDropdown {
      id: areaDropdown
      popupParent: keyCatcher
      ownerOpen: controls.ownerOpen
      width: controls.cellWidth
      label: "TABLET AREA"
      options: Model.activeAreaOptions()
      value: root.profile ? root.profile.activeArea.mode : "full"
      enabled: !!root.profile && !root.followsFocus && root.tabletSize.width > 0
      opacity: root.followsFocus || root.tabletSize.width <= 0 ? root.disabledOpacity : 1.0
      hasCursor: root.hasCursor("area")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(value) { root.setAreaMode(value) }
    }

    PanelDropdown {
      id: transformDropdown
      visible: root.rotationAvailable
      popupParent: keyCatcher
      ownerOpen: controls.ownerOpen
      width: controls.cellWidth
      label: "ROTATION"
      options: Model.transformOptions()
      value: root.profile ? String(root.profile.transform) : "0"
      enabled: !!root.profile
      hasCursor: root.hasCursor("transform")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(value) { root.setTransform(value) }
    }
  }

  component ToggleRows: Column {
    readonly property bool anyPopupOpen: false
    spacing: Style.space(6)

    Toggle {
      visible: root.leftHandedAvailable
      width: parent.width
      label: "Left-handed"
      description: root.rotationAvailable
        ? "Turn the tablet 180° so the cable points the other way"
        : "Turn the tablet 180° so the cable points the other way. The only rotation an external tablet supports."
      checked: !!root.profile && root.profile.leftHanded === true
      enabled: !!root.profile
      hasCursor: root.hasCursor("leftHanded")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.toggleLeftHanded()
    }

    Toggle {
      width: parent.width
      label: "Mouse mode"
      description: "Move the pointer relatively, like a mouse, instead of pointing at a spot on the screen"
      checked: !!root.profile && root.profile.relativeInput === true
      enabled: !!root.profile
      hasCursor: root.hasCursor("relative")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.toggleRelative()
    }

  }

  component StylusControls: Column {
    id: stylusColumn
    readonly property var live: root.pendingStylus || root.stylus
    readonly property bool anyPopupOpen: eraserModeDropdown.popupOpen || eraserOverrideDropdown.popupOpen
    spacing: Style.space(8)

    Toggle {
      width: parent.width
      label: "Limit the pressure range"
      description: stylusColumn.live.pressureRangeEnabled
        ? "Pen pressure is clipped to " + Math.round(stylusColumn.live.pressureMin * 100) + "–" + Math.round(stylusColumn.live.pressureMax * 100) + "%"
        : "The pen's own full pressure range is used"
      checked: stylusColumn.live.pressureRangeEnabled === true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.editStylus({ pressureRangeEnabled: !stylusColumn.live.pressureRangeEnabled }, true)
    }

    Column {
      width: parent.width
      spacing: Style.space(6)
      opacity: stylusColumn.live.pressureRangeEnabled ? 1.0 : root.disabledOpacity
      enabled: stylusColumn.live.pressureRangeEnabled === true

      Item {
        width: parent.width
        implicitHeight: minHeader.implicitHeight

        PanelSectionHeader {
          id: minHeader
          text: "LIGHTEST TOUCH"
          foreground: root.foreground
          fontFamily: root.fontFamily
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: Math.round((minSlider.dragging ? minSlider.liveValue : stylusColumn.live.pressureMin) * 100) + "%"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      CursorSurface {
        width: parent.width
        height: minSlider.implicitHeight + Style.spacing.controlGap
        outline: true
        foreground: root.foreground
        accent: Color.accent

        PanelSlider {
          id: minSlider
          bar: root.bar
          anchors.fill: parent
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(6)
          minimum: 0
          maximum: 1
          step: 0.01
          value: stylusColumn.live.pressureMin
          onMoved: function(next) { root.editStylus({ pressureMin: next, pressureMax: Math.max(next, stylusColumn.live.pressureMax) }) }
          onReleased: function(next) { root.editStylus({ pressureMin: next, pressureMax: Math.max(next, stylusColumn.live.pressureMax) }, true) }
        }
      }

      Item {
        width: parent.width
        implicitHeight: maxHeader.implicitHeight

        PanelSectionHeader {
          id: maxHeader
          text: "FULL PRESSURE"
          foreground: root.foreground
          fontFamily: root.fontFamily
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: Math.round((maxSlider.dragging ? maxSlider.liveValue : stylusColumn.live.pressureMax) * 100) + "%"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      CursorSurface {
        width: parent.width
        height: maxSlider.implicitHeight + Style.spacing.controlGap
        outline: true
        foreground: root.foreground
        accent: Color.accent

        PanelSlider {
          id: maxSlider
          bar: root.bar
          anchors.fill: parent
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(6)
          minimum: 0
          maximum: 1
          step: 0.01
          value: stylusColumn.live.pressureMax
          onMoved: function(next) { root.editStylus({ pressureMax: next, pressureMin: Math.min(next, stylusColumn.live.pressureMin) }) }
          onReleased: function(next) { root.editStylus({ pressureMax: next, pressureMin: Math.min(next, stylusColumn.live.pressureMin) }, true) }
        }
      }
    }

    Toggle {
      width: parent.width
      label: "Hide the cursor while drawing"
      description: "Hyprland hides the pointer when the pen is in use and shows it again on mouse movement"
      checked: stylusColumn.live.hideCursor === true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.editStylus({ hideCursor: !stylusColumn.live.hideCursor }, true)
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.eraserButtonPresent
        ? "The eraser button on the pen: by default it switches the tip into eraser mode; it can send a pen button instead."
        : "No connected pen has an eraser button (an eraser on the back end is not one), so the eraser settings below only matter for pens that do."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Grid {
      width: parent.width
      columns: 2
      spacing: Style.space(8)
      readonly property real cellWidth: (width - spacing) / 2

      PanelDropdown {
        id: eraserModeDropdown
        popupParent: keyCatcher
        ownerOpen: root.opened && root.expanded
        width: parent.cellWidth
        label: "ERASER BUTTON"
        options: Model.eraserModeOptions()
        value: String(stylusColumn.live.eraserButtonMode)
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(value) { root.editStylus({ eraserButtonMode: Number(value) }, true) }
      }

      PanelDropdown {
        id: eraserOverrideDropdown
        popupParent: keyCatcher
        ownerOpen: root.opened && root.expanded
        width: parent.cellWidth
        label: "ERASER BUTTON SENDS"
        options: Model.eraserOverrideOptions()
        value: String(stylusColumn.live.eraserButtonOverride)
        enabled: Number(stylusColumn.live.eraserButtonMode) === 1
        opacity: Number(stylusColumn.live.eraserButtonMode) === 1 ? 1.0 : root.disabledOpacity
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(value) { root.editStylus({ eraserButtonOverride: Number(value) }, true) }
      }
    }
  }

  component StatusRow: Item {
    implicitHeight: Math.max(statusLabel.implicitHeight, statusButtons.implicitHeight)

    Text {
      textFormat: Text.PlainText
      id: statusLabel
      anchors.left: parent.left
      anchors.right: statusButtons.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: root.statusText !== "" ? root.statusText : "Changes apply and save as you make them."
      color: root.statusIsError ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }

    Row {
      id: statusButtons
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Button {
        text: root.manualScan && engine.probing ? "Scanning…" : "Rescan"
        iconText: "󰑓"
        bordered: true
        enabled: !(root.manualScan && engine.probing)
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: root.rescan()
      }

      Button {
        text: "Defaults"
        iconText: "󰦛"
        bordered: true
        enabled: !!root.profile
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: root.resetProfile()
      }
    }
  }

  component InfoRow: Item {
    id: infoRow
    property string label: ""
    property string value: ""
    property bool valueAccent: false

    width: parent ? parent.width : 0
    implicitHeight: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)

    Text {
      textFormat: Text.PlainText
      id: infoLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(parent.width * 0.34, Style.space(110))
      text: infoRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      id: infoValue
      anchors.left: infoLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: infoRow.value
      color: infoRow.valueAccent ? Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: infoRow.valueAccent
      elide: Text.ElideRight
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string rowKey: ""
    property string icon: ""
    property string title: ""
    property string subtitle: ""
    signal activated()

    hasCursor: root.hasCursor(rowKey)
    foreground: root.foreground
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionRow.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: actionRow.enabled
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = Math.max(0, root.cursorRows.indexOf(actionRow.rowKey))
      }
      onClicked: actionRow.activated()
    }

    Row {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(12)

      Text {
        textFormat: Text.PlainText
        id: actionIcon
        anchors.verticalCenter: parent.verticalCenter
        text: actionRow.icon
        color: actionRow.enabled ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        width: parent.width - actionIcon.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: actionRow.title
          color: actionRow.enabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
