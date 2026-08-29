import QtQuick
import qs.Commons
import qs.Ui

// A titled card for the expanded editor. Children land in the content area
// under the title bar; `meta` is a short right-aligned note such as the
// screen a mapping targets.
BorderSurface {
  id: root

  default property alias content: body.data
  property string title: ""
  property string meta: ""
  property bool active: false
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property int inset: Style.space(10)
  readonly property int titleHeight: Style.space(28)

  color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.018)
  borderSpec: Border.controlSpec(active ? "focus" : "normal", foreground, accent)
  radius: Style.cornerRadius

  Text {
    textFormat: Text.PlainText
    id: titleText
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.leftMargin: root.inset
    height: root.titleHeight
    verticalAlignment: Text.AlignVCenter
    text: root.title
    color: root.active ? root.accent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
  }

  Text {
    textFormat: Text.PlainText
    anchors.left: titleText.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: root.inset
    height: root.titleHeight
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignRight
    text: root.meta
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Item {
    id: body
    anchors.fill: parent
    anchors.topMargin: root.titleHeight
    anchors.leftMargin: root.inset
    anchors.rightMargin: root.inset
    anchors.bottomMargin: root.inset
  }
}
