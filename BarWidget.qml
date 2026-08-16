import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Router.js" as Router

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
  readonly property int importCount: service ? service.importableCount : 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.38)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Not-the-default is signalled by dimming, the same way the rest of the bar
  // shows an inactive module. `Color.urgent` is deliberately avoided: themes
  // that do not define a bar.active token fall back to a fixed red that has
  // nothing to do with the palette, which looks like a rendering bug rather
  // than a status. Unknown reads as fine — the handler query has not come back
  // yet during the first moments of a session.
  readonly property color barIconColor: (!handlerKnown || isDefault)
    ? barForeground
    : Qt.darker(barForeground, 1.55)
  readonly property bool showCount: String(setting("showCount", false)) === "true" || setting("showCount", false) === true

  readonly property string statusLine: !handlerKnown
    ? "Checking the default handler…"
    : (isDefault ? "Handling every link" : "Not the default handler")

  // Delete is destructive and sits next to two harmless arrows, so it gets the
  // one warm colour in the panel on hover.
  readonly property color urgentish: bar ? bar.urgent : Color.urgent

  function summonPicker() {
    root.close()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon(root.pluginId, "{}")
  }

  function editRule(index) {
    root.close()
    if (root.service) root.service.openEditor(index, "")
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
    // Sized so the longest thing a rule block prints — a browser with a long
    // profile name — fits without an ellipsis.
    contentWidth: panel.fittedContentWidth(Style.space(380))
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
        label: "Make mclovin the default"
        onActivated: if (root.service) root.service.becomeDefault()
      }

      // Only offered while there is something to take. Importing is one-shot:
      // after it runs the count drops to zero unless the CLI's file changes.
      ActionRow {
        visible: root.importCount > 0
        glyph: "󰇚"
        label: "Import " + root.importCount + " rule" + (root.importCount === 1 ? "" : "s") + " from the mclovin CLI"
        onActivated: if (root.service) root.service.importFromMclovin()
      }

      PanelSeparator {
        foreground: root.foreground
        visible: root.stats && root.stats.lastUrl !== ""
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

      // No numbering and no arrows: the narrowest rule wins, so position is a
      // consequence of what the rules say rather than something to manage. The
      // list is shown narrowest-first because that is the order they are tried.
      Repeater {
        model: root.rules

        CursorSurface {
          id: ruleSurface
          required property var modelData
          required property int index

          width: content.width
          implicitHeight: ruleRow.implicitHeight + Style.spacing.lg
          foreground: root.foreground
          fill: root.hoverFill
          hasCursor: ruleHover.containsMouse

          // Two lines so neither half has to be abbreviated: the term owns the
          // first, the destination the second. They stop competing for the same
          // width, which is what forced the ellipses.
          RowLayout {
            id: ruleRow
            anchors.left: parent.left; anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
            spacing: Style.space(8)

            readonly property int badgeSize: Style.space(18)

            ColumnLayout {
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              spacing: Style.space(2)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                // The matcher is context, not content — one glyph in a chip.
                // The legend under the list says what each one means.
                Rectangle {
                  Layout.alignment: Qt.AlignVCenter
                  Layout.preferredWidth: ruleRow.badgeSize
                  Layout.preferredHeight: ruleRow.badgeSize
                  radius: Math.max(2, Style.cornerRadius)
                  color: "transparent"
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)

                  Text {
                    anchors.centerIn: parent
                    text: Router.whenBadge(ruleSurface.modelData.when)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                }

                // The term is the rule. Extra terms share this cell.
                Text {
                  Layout.fillWidth: true
                  Layout.preferredWidth: 0
                  Layout.alignment: Qt.AlignVCenter
                  text: Router.ruleTerms(ruleSurface.modelData)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }

              // Indented to the term's left edge so the pair reads as one block
              // rather than two stacked rows.
              Text {
                Layout.fillWidth: true
                Layout.preferredWidth: 0
                Layout.leftMargin: ruleRow.badgeSize + Style.space(8)
                text: root.service
                  ? root.service.targetName(ruleSurface.modelData)
                  : Router.ruleTargetLabel(ruleSurface.modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              Layout.alignment: Qt.AlignVCenter
              iconText: "󰅖"
              tooltipText: "Delete this rule"
              foreground: root.faint
              hoverColor: root.urgentish
              fontFamily: root.fontFamily
              size: Style.space(20)
              onClicked: if (root.service) root.service.removeRule(ruleSurface.index)
            }
          }

          // Clicking the row opens the form on it. The buttons above sit on top
          // and swallow their own clicks, so this only fires on the text.
          MouseArea {
            id: ruleHover
            anchors.fill: parent
            z: -1
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.editRule(ruleSurface.index)
          }
        }
      }

      // Four symbols cost one dim line and teach the whole vocabulary at once,
      // which a per-row tooltip cannot.
      Text {
        width: parent.width
        visible: root.rules.length > 0
        text: "^ starts with   ~ contains   @ host   / regex"
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      ActionRow {
        glyph: "󰐕"
        label: "Add rule"
        onActivated: root.editRule(-1)
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
