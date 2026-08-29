import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// A select control for a KeyboardPanel. The menu is positioned in the panel's
// own coordinate space (`popupParent`) so it stays attached to its trigger
// wherever the panel sits, and `value` is never written from inside: the
// caller's binding stays the single source of truth and only `changed` fires.
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []
  property Item popupParent: null
  property bool ownerOpen: true
  property bool hasCursor: false
  property bool showLabel: true
  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal changed(string value)

  readonly property bool popupOpen: menu.opened
  readonly property int rowHeight: Style.spacing.controlHeight
  readonly property int menuRowHeight: Style.spacing.popupRowHeight
  readonly property int menuRowsShown: 8
  readonly property var menuBorder: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)

  implicitWidth: Style.spacing.dropdownWidth
  implicitHeight: (root.showLabel && root.label !== "" ? caption.implicitHeight + Style.spacing.labelGap : 0) + rowHeight

  onOwnerOpenChanged: if (!ownerOpen) menu.close()
  onVisibleChanged: if (!visible) menu.close()

  function open() { menu.open() }
  function close() { menu.close() }
  function toggle() {
    if (menu.opened) menu.close()
    else menu.open()
  }

  function valueOf(option) {
    return option !== null && typeof option === "object" ? String(option.value) : String(option)
  }

  function labelOf(option) {
    return option !== null && typeof option === "object" ? String(option.label) : String(option)
  }

  function indexOfValue(wanted) {
    for (var i = 0; i < root.options.length; i++) if (root.valueOf(root.options[i]) === String(wanted)) return i
    return -1
  }

  function currentLabel() {
    var index = root.indexOfValue(root.value)
    return index >= 0 ? root.labelOf(root.options[index]) : String(root.value)
  }

  // Below the trigger when it fits, above it otherwise.
  function menuPosition() {
    var gap = Style.spacing.xxs
    var host = root.popupParent || root
    var below = trigger.mapToItem(host, 0, trigger.height + gap)
    if (below.y + menu.height <= host.height) return below
    return trigger.mapToItem(host, 0, -menu.height - gap)
  }

  function choose(index) {
    if (index < 0 || index >= root.options.length) return
    var picked = root.valueOf(root.options[index])
    menu.close()
    root.changed(picked)
  }

  PanelSectionHeader {
    id: caption
    visible: root.showLabel && root.label !== ""
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.label
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  BorderSurface {
    id: trigger
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: root.rowHeight
    radius: Style.cornerRadius
    activeFocusOnTab: true

    readonly property bool hot: triggerMouse.containsMouse || root.hasCursor
    color: Style.controlFill(activeFocus, hot, root.foreground, root.accent)
    borderSpec: Border.controlSpec(activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: chevron.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.rightMargin: Style.spacing.sm
      text: root.currentLabel()
      color: root.enabled ? root.foreground : Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      id: chevron
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Style.spacing.controlPaddingX
      text: menu.opened ? "󰅃" : "󰅀"
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: triggerMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggle()
    }

    Keys.onPressed: function(event) {
      var opens = event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down
      if (opens) {
        root.toggle()
        event.accepted = true
      } else if (event.key === Qt.Key_Escape && menu.opened) {
        menu.close()
        event.accepted = true
      }
    }
  }

  Popup {
    id: menu
    parent: root.popupParent || root
    // An Item popup stays inside the layer-shell surface; a window popup
    // would be a second Wayland surface the compositor never focuses.
    popupType: Popup.Item
    readonly property point place: root.menuPosition()
    x: place.x
    y: place.y
    width: trigger.width
    height: Math.min(root.options.length, root.menuRowsShown) * root.menuRowHeight
      + topPadding + bottomPadding
    padding: Style.spacing.xxs
    topPadding: Border.top(root.menuBorder) + Style.spacing.xxs
    bottomPadding: Border.bottom(root.menuBorder) + Style.spacing.xxs
    leftPadding: Border.left(root.menuBorder) + Style.spacing.xxs
    rightPadding: Border.right(root.menuBorder) + Style.spacing.xxs
    focus: true

    background: BorderSurface {
      color: root.background
      borderSpec: root.menuBorder
      radius: Style.cornerRadius
    }

    onOpened: {
      rows.currentIndex = Math.max(0, root.indexOfValue(root.value))
      rows.positionViewAtIndex(rows.currentIndex, ListView.Contain)
      rows.forceActiveFocus()
    }

    contentItem: ListView {
      id: rows
      clip: true
      model: root.options
      keyNavigationWraps: false
      highlightMoveDuration: 0

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          menu.close()
        } else if (event.key === Qt.Key_Down || event.text === "j") {
          rows.currentIndex = Math.min(root.options.length - 1, rows.currentIndex + 1)
        } else if (event.key === Qt.Key_Up || event.text === "k") {
          rows.currentIndex = Math.max(0, rows.currentIndex - 1)
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.choose(rows.currentIndex)
        } else {
          return
        }
        event.accepted = true
      }

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool current: index === rows.currentIndex
        width: rows.width
        height: root.menuRowHeight
        radius: Math.max(0, Style.cornerRadius - Style.spacing.xxs)
        color: current ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.rightMargin: Style.spacing.controlPaddingX
          text: root.labelOf(row.modelData)
          color: row.current ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: rows.currentIndex = row.index
          onClicked: root.choose(row.index)
        }
      }
    }
  }
}
