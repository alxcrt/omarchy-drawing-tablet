import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Two pictures, one story: the screens with the mapped region on top, and the
// tablet with its active area below. Both are drawn from the same profile
// the apply plan reads, so what is shown is what Hyprland gets.
BorderSurface {
  id: root

  property var profile: null
  property var monitors: []
  property bool interactive: false
  property bool framed: true
  property bool showTablet: true
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal regionEdited(var region)

  readonly property int inset: Style.space(8)
  readonly property var bounds: Model.layoutBounds(monitors)
  readonly property var target: Model.outputTarget(profile, monitors)
  readonly property bool customRegion: !!profile && !!profile.region && profile.region.mode === "custom" && !!target.box
  readonly property var regionRect: Model.regionCanvasRect(profile, monitors, screens.width, screens.height, inset)
  readonly property var areaFractions: Model.activeAreaFractions(profile, monitors)
  readonly property var tabletSize: Model.effectiveTabletSize(profile)
  readonly property bool sizeKnown: tabletSize.width > 0 && tabletSize.height > 0
  readonly property bool tabletDisabled: false

  implicitHeight: Style.space(showTablet ? 250 : 160)
  color: framed ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.025) : "transparent"
  borderSpec: framed ? Border.controlSpec("normal", foreground, accent) : Border.none()
  radius: framed ? Style.cornerRadius : 0

  Item {
    id: screens
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: root.showTablet ? Math.round(parent.height * 0.6) : parent.height

    Repeater {
      model: 8
      Rectangle {
        required property int index
        x: Math.round(index * screens.width / 7)
        width: 1
        height: screens.height
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      }
    }

    Repeater {
      model: root.monitors

      Rectangle {
        id: card
        required property var modelData
        readonly property var previewRect: Model.layoutRect(modelData, root.bounds, screens.width, screens.height, root.inset)
        readonly property bool isTarget: root.target.kind === "monitor" && !!root.target.box
          && String(root.target.box.name || "") === String(modelData.name || "")
        readonly property bool inLayout: root.target.kind === "layout"

        x: previewRect.x
        y: previewRect.y
        width: previewRect.width
        height: previewRect.height
        radius: Math.min(Style.cornerRadius, Style.space(5))
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, isTarget || inLayout ? 0.06 : 0.03)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, isTarget || inLayout ? 0.6 : 0.35)

        Column {
          anchors.centerIn: parent
          width: Math.max(0, parent.width - Style.space(10))
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: String(card.modelData.name || "Screen")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: card.height >= Style.space(44)
            width: parent.width
            text: Model.monitorLabel(card.modelData, false).replace(/ \([^)]*\)$/, "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: card.height >= Style.space(58)
            width: parent.width
            text: Number(card.modelData.width || 0) + "×" + Number(card.modelData.height || 0)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }

    Rectangle {
      id: region
      visible: !!root.regionRect && !root.tabletDisabled
      x: (root.regionRect ? root.regionRect.x : 0) + dragArea.offsetX
      y: (root.regionRect ? root.regionRect.y : 0) + dragArea.offsetY
      width: root.regionRect ? root.regionRect.width : 0
      height: root.regionRect ? root.regionRect.height : 0
      radius: Math.min(Style.cornerRadius, Style.space(4))
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
      border.width: Math.max(1, Style.normalBorderWidth)
      border.color: root.accent

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(4)
        visible: root.regionRect && root.regionRect.follows
        text: "follows focus"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(3)
        text: "󰏫"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        enabled: root.interactive && root.customRegion
        hoverEnabled: enabled
        cursorShape: enabled ? (dragStarted ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
        // Pointer coordinates must come from the stationary canvas. Using
        // mouse.x/y directly makes the origin move with the region and feeds
        // its own movement back into the next drag delta.
        property real pointerStartX: 0
        property real pointerStartY: 0
        property real offsetX: 0
        property real offsetY: 0
        property bool dragStarted: false

        onPressed: function(mouse) {
          var point = dragArea.mapToItem(screens, mouse.x, mouse.y)
          pointerStartX = point.x
          pointerStartY = point.y
          dragStarted = false
          offsetX = 0
          offsetY = 0
        }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var point = dragArea.mapToItem(screens, mouse.x, mouse.y)
          var deltaX = point.x - pointerStartX
          var deltaY = point.y - pointerStartY
          if (!dragStarted) {
            var threshold = Style.space(4)
            if (deltaX * deltaX + deltaY * deltaY < threshold * threshold) return
            dragStarted = true
          }
          offsetX = deltaX
          offsetY = deltaY
        }
        onReleased: function(mouse) {
          var deltaX = offsetX
          var deltaY = offsetY
          var moved = dragStarted
          offsetX = 0
          offsetY = 0
          dragStarted = false
          if (!moved) return
          var next = Model.regionFromCanvasDrag(root.profile, root.monitors, screens.width, screens.height, root.inset, deltaX, deltaY)
          if (next) root.regionEdited(next)
        }
        onCanceled: {
          dragStarted = false
          offsetX = 0
          offsetY = 0
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.monitors.length === 0
      anchors.centerIn: parent
      text: "No screens reported by Hyprland"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  Rectangle {
    visible: root.showTablet
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: screens.bottom
    anchors.leftMargin: root.inset
    anchors.rightMargin: root.inset
    height: 1
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
  }

  Item {
    id: tabletArea
    visible: root.showTablet
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: screens.bottom
    anchors.bottom: parent.bottom
    anchors.margins: root.inset

    readonly property real drawWidth: root.sizeKnown ? root.tabletSize.width : 16
    readonly property real drawHeight: root.sizeKnown ? root.tabletSize.height : 10
    readonly property var fit: Model.fitAspect(Math.max(1, width - Style.space(4)), Math.max(1, height - Style.space(4)), drawWidth, drawHeight)

    Rectangle {
      id: tablet
      readonly property real usableWidth: Math.max(1, tabletArea.width - Style.space(4))
      readonly property real usableHeight: Math.max(1, tabletArea.height - Style.space(4))
      x: Style.space(2) + tabletArea.fit.x * usableWidth
      y: Style.space(2) + tabletArea.fit.y * usableHeight
      width: Math.max(1, tabletArea.fit.w * usableWidth)
      height: Math.max(1, tabletArea.fit.h * usableHeight)
      radius: Math.min(Style.cornerRadius, Style.space(6))
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.tabletDisabled ? 0.02 : 0.05)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.tabletDisabled ? 0.3 : 0.55)

      Rectangle {
        visible: !root.tabletDisabled
        x: (root.areaFractions ? root.areaFractions.x : 0) * parent.width
        y: (root.areaFractions ? root.areaFractions.y : 0) * parent.height
        width: (root.areaFractions ? root.areaFractions.w : 1) * parent.width
        height: (root.areaFractions ? root.areaFractions.h : 1) * parent.height
        radius: Math.min(Style.cornerRadius, Style.space(4))
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: root.accent
      }

      Column {
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Style.space(10))
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.tabletDisabled ? "disabled" : (root.profile ? String(root.profile.label || "Tablet") : "Tablet")
          color: root.tabletDisabled ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: tablet.height >= Style.space(40)
          width: parent.width
          text: root.sizeKnown
            ? Math.round(root.tabletSize.width) + " × " + Math.round(root.tabletSize.height) + " mm"
            : "size unknown"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }
}
