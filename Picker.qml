import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Router.js" as Router

// The browser picker: a fullscreen layer with a centred card, summoned with the
// URL in flight. Shape and key handling follow the built-in emoji overlay, so
// it behaves like the rest of the desktop — type to filter, arrows to move,
// Enter to pick, Escape to back out, click the scrim to dismiss.
//
// Every colour comes from the [menu] surface tokens, which is the same set the
// emoji picker and the Omarchy menu use. A theme that restyles the menu
// restyles this too, with no work here.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string url: ""
  property string filterText: ""
  property int selectedIndex: 0
  property bool remember: false

  readonly property var parsed: Router.parseUrl(root.url)
  readonly property string host: Router.displayHost(root.parsed)
  readonly property var allBrowsers: (service && service.browsers) || []
  readonly property var browsers: Router.filterBrowsers(root.allBrowsers, root.filterText)

  // Menu surface tokens — shared with the emoji picker and the Omarchy menu.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int rowHeight: Math.max(Style.space(40), Style.font.body + Style.spacing.controlPaddingY * 2)

  // ------------------------------------------------------------- lifecycle

  // Called by the shell with whatever summon() was given. A missing or
  // unparseable payload still opens the picker, just without a URL — that is
  // the "launch a browser" path the bar widget uses.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = {} }

    root.url = String(payload.url || "")
    root.filterText = ""
    root.selectedIndex = 0
    // Default the toggle off: remembering is a deliberate act, and a sticky
    // toggle would quietly write a rule on the next unrelated link.
    root.remember = false
    root.opened = true
    if (service && typeof service.refreshBrowsers === "function") service.refreshBrowsers()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.guilhermeyo.mclovin")
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
  }

  function move(delta) {
    var count = root.browsers.length
    if (count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + count) % count
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate(index) {
    var entry = root.browsers[index]
    if (!entry || !service) return
    // Remembering only makes sense when there is a host to key the rule on.
    var pattern = (root.remember && root.host && root.url) ? root.host : ""
    service.choose(String(entry.id), root.url, pattern)
    dismiss()
  }

  function iconFor(entry) {
    var name = String((entry && entry.icon) || "")
    if (!name) return Quickshell.iconPath("application-x-executable", true)
    if (name.charAt(0) === "/") return "file://" + name
    return Quickshell.iconPath(name, true)
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-mclovin"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(460), panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
            if (root.url) root.remember = !root.remember
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab
                     || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex)
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // ----------------------------------------------------------- header
        Row {
          id: header
          width: parent.width
          spacing: Style.spacing.md

          McLovinIcon {
            iconSize: Style.font.displayLarge
            color: root.foreground
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - Style.font.displayLarge - Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.host || "Open a browser"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: root.url !== ""
              text: root.url
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ----------------------------------------------------------- filter
        Text {
          width: parent.width
          text: root.filterText || "Type to filter…"
          color: root.foreground
          opacity: root.filterText ? 1 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        // ------------------------------------------------------------ list
        Item {
          width: parent.width
          height: parent.height - header.height - rememberRow.height - footer.height
                  - Style.spacing.md * 4 - Style.space(24)

          ListView {
            id: list
            anchors.fill: parent
            model: root.browsers
            clip: true
            currentIndex: root.selectedIndex
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(2)

            delegate: Rectangle {
              required property var modelData
              required property int index

              width: list.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: index === root.selectedIndex ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Image {
                  source: root.iconFor(parent.parent.modelData)
                  width: Style.font.icon
                  height: Style.font.icon
                  anchors.verticalCenter: parent.verticalCenter
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: Style.font.icon * 2
                  sourceSize.height: Style.font.icon * 2
                  smooth: true
                }

                Text {
                  width: parent.width - Style.font.icon - Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(parent.parent.modelData.name || parent.parent.modelData.id)
                  color: index === root.selectedIndex ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.selectedIndex = index
                onClicked: root.activate(index)
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.browsers.length === 0
            text: root.allBrowsers.length === 0
                  ? "No web browsers found"
                  : "No matches for “" + root.filterText + "”"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // -------------------------------------------------------- remember
        Rectangle {
          id: rememberRow
          width: parent.width
          height: root.url ? root.rowHeight : 0
          visible: root.url !== ""
          radius: root.cornerRadius
          color: root.remember ? root.selectedBackground : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              // Nerd Font check box, filled when the rule will be written.
              text: root.remember ? "󰄲" : "󰄱"
              color: root.remember ? root.selectedText : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Always use this browser for " + root.host
              color: root.remember ? root.selectedText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.remember = !root.remember
          }
        }

        // ---------------------------------------------------------- footer
        Text {
          id: footer
          width: parent.width
          text: root.url ? "Enter open  ·  Ctrl+R remember  ·  Esc cancel"
                         : "Enter open  ·  Esc cancel"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
