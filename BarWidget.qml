import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Bar icon plus its drop-down. The icon is the whole point of the widget: it
// goes urgent when mclovin is not the registered http handler, because that is
// the failure nobody notices — links keep opening, just never through here.
//
// All state is read off the service singleton; this file owns no data.
Panel {
  id: root
  moduleName: "io.github.guilhermeyo.mclovin"

  // A target of its own, separate from the service's `mclovin`, so a keybind
  // can drop the panel open: `omarchy-shell mclovin-bar toggle`. Summoning the
  // plugin id instead would reach the picker overlay, which is a different
  // surface with a different job.
  ipcTarget: "mclovin-bar"

  readonly property string pluginId: "io.github.guilhermeyo.mclovin"
  readonly property var service: bar?.shell?.serviceFor(pluginId)

  readonly property bool isDefault: service ? service.isDefault : false
  readonly property bool handlerKnown: service ? service.handlerKnown : false
  readonly property var stats: service ? service.stats : null
  readonly property var rules: service ? service.rules : []
  readonly property int todayCount: stats ? stats.count : 0
  readonly property var breakdown: service && stats
    ? (function() {
        var out = []
        var by = stats.byBrowser || {}
        for (var name in by) out.push({ name: name, count: by[name] })
        out.sort(function(a, b) { return b.count - a.count })
        return out
      })()
    : []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Unknown reads as fine rather than broken: the handler query has not come
  // back yet during the first moments of a session.
  readonly property color barIconColor: (!handlerKnown || isDefault) ? barForeground : root.urgent
  readonly property bool showCount: String(setting("showCount", false)) === "true" || setting("showCount", false) === true

  readonly property string statusLine: !handlerKnown
    ? "Checking the default handler…"
    : (isDefault ? "Handling every link" : "Not the default handler")

  function summonPicker() {
    root.close()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon(root.pluginId, "{}")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened && service) {
    service.refreshBrowsers()
    service.refreshHandler()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Row {
        spacing: Style.space(5)

        McLovinIcon {
          iconSize: Style.space(18)
          color: root.barIconColor
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.showCount && root.todayCount > 0
          text: String(root.todayCount)
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.summonPicker()
      else if (buttonCode === Qt.MiddleButton) { if (root.service) root.service.refreshHandler() }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(12)

      PanelHero {
        width: parent.width
        title: "mclovin"
        meta: root.statusLine
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconOpacity: root.isDefault ? 1.0 : 0.5
        iconComponent: Component {
          McLovinIcon {
            iconSize: Style.font.display
            color: root.isDefault ? root.foreground : root.dim
          }
        }
      }

      // The one row that fixes the one thing that can be wrong.
      ActionRow {
        visible: root.handlerKnown && !root.isDefault
        glyph: "󰄬"
        glyphColor: root.urgent
        label: "Make mclovin the default"
        onActivated: if (root.service) root.service.becomeDefault()
      }

      PanelSeparator { foreground: root.foreground }

      // ------------------------------------------------------------- today
      PanelSectionHeader {
        width: parent.width
        text: "Today"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        width: parent.width
        visible: root.todayCount === 0
        text: "No links routed yet"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Repeater {
        model: root.breakdown

        RowLayout {
          required property var modelData
          width: content.width
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: String(modelData.name)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            text: String(modelData.count)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      // -------------------------------------------------------- last route
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.stats && root.stats.lastUrl !== ""

        Text {
          width: parent.width
          text: root.stats && root.stats.lastRule
                ? "Last: " + root.stats.lastBrowser + " · rule “" + root.stats.lastRule + "”"
                : "Last: " + (root.stats ? root.stats.lastBrowser : "") + " · no rule"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.stats ? root.stats.lastUrl : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ------------------------------------------------------------- rules
      PanelSectionHeader {
        width: parent.width
        text: "Rules"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        width: parent.width
        visible: root.rules.length === 0
        text: "None yet — tick “Always use this browser” in the picker"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: root.rules

        CursorSurface {
          required property var modelData
          required property int index

          width: content.width
          implicitHeight: ruleRow.implicitHeight + Style.spacing.xl
          foreground: root.foreground
          fill: root.hoverFill

          RowLayout {
            id: ruleRow
            anchors.left: parent.left; anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Column {
              Layout.fillWidth: true
              spacing: 0

              Text {
                width: parent.width
                text: String(modelData.match)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.service ? root.service.browserName(modelData.browser) : String(modelData.browser)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Text {
              text: "󰅖"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              Layout.alignment: Qt.AlignVCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) root.service.removeRule(index)
              }
            }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      ActionRow {
        glyph: "󰖟"
        label: "Open the picker"
        onActivated: root.summonPicker()
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow

    property string glyph: ""
    property color glyphColor: root.foreground
    property string label: ""
    signal activated()

    width: content.width
    implicitHeight: actionInner.implicitHeight + Style.spacing.xl
    foreground: root.foreground
    fill: root.hoverFill

    RowLayout {
      id: actionInner
      anchors.left: parent.left; anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: actionRow.glyph
        color: actionRow.glyphColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        Layout.fillWidth: true
        text: actionRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: actionRow.activated()
    }
  }
}
