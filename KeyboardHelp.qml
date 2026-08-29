import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool expanded: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal closeRequested()

  readonly property var groups: {
    var groups = [{
      title: "Moving around",
      bindings: [
        { keys: "↑ ↓  or  j k", action: "Move between the controls" },
        { keys: "← →  or  h l", action: "Change the highlighted option" },
        { keys: "Enter, Space", action: "Open the highlighted menu or flip the switch" },
        { keys: "Tab", action: root.expanded ? "Move focus through the fields" : "Switch to the next bar panel" }
      ]
    }]
    if (root.expanded) {
      groups.push({
        title: "Custom region",
        bindings: [
          { keys: "Shift + ← → ↑ ↓", action: "Move the region by 1% of the screen" },
          { keys: "Ctrl + ← → ↑ ↓", action: "Grow or shrink the region by 1%" },
          { keys: "Drag", action: "Move the region on the preview" }
        ]
      })
    }
    groups.push({
      title: "Anywhere",
      bindings: [
        { keys: "e", action: root.expanded ? "Back to the compact panel" : "Open the full editor" },
        { keys: "a", action: "Apply the mapping again" },
        { keys: "r", action: "Rescan tablets and screens" },
        { keys: "d", action: "Reset this tablet to Hyprland's defaults" },
        { keys: "?", action: "Show these keys" },
        { keys: "q, Esc", action: "Close" }
      ]
    })
    return groups
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.58)

    MouseArea {
      anchors.fill: parent
      onClicked: root.closeRequested()
    }
  }

  BorderSurface {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(48), Style.space(560))
    height: Math.min(parent.height - Style.space(32), helpColumn.implicitHeight + Style.space(36))
    color: root.background
    borderSpec: Border.controlSpec("focus", root.foreground, root.accent)
    radius: Style.cornerRadius

    MouseArea {
      anchors.fill: parent
      onClicked: function(mouse) { mouse.accepted = true }
    }

    Column {
      id: helpColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(18)
      spacing: Style.space(14)

      Text {
        textFormat: Text.PlainText
        text: "Keyboard"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Repeater {
        model: root.groups

        Column {
          required property var modelData
          width: parent.width
          spacing: Style.space(5)

          PanelSectionHeader {
            text: String(modelData.title || "").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: modelData.bindings

            Item {
              required property var modelData
              width: parent.width
              implicitHeight: Math.max(keysText.implicitHeight, actionText.implicitHeight)

              Text {
                textFormat: Text.PlainText
                id: keysText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(150)
                text: String(modelData.keys || "")
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                id: actionText
                anchors.left: keysText.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.action || "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Any key closes this."
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
