import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Router.js" as Router
import "Browsers.js" as Browsers

// The browser picker screen. Type to filter, arrows to move, Enter to open.
// Rows are browser+profile pairs — see Browsers.pickerEntries for why.
Item {
  id: root

  property var service: null
  property string url: ""
  property string filterText: ""
  property int selectedIndex: 0
  property bool remember: false

  // Separate from `remember` on purpose. Private is a property of this one
  // open; remembering is a property of every future one. Ticking both is
  // allowed and says so in the remember line, but neither implies the other.
  property bool wantPrivate: false

  signal chosen(string browserId, string profile, bool remember, bool wantPrivate)
  signal cancelled()
  signal ruleRequested()

  readonly property var parsed: Router.parseUrl(root.url)
  readonly property string host: Router.displayHost(root.parsed)
  readonly property var allRows: (service && service.pickerEntries) || []
  readonly property var rows: Browsers.filterPickerEntries(root.allRows, root.filterText)

  readonly property color foreground: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int rowHeight: Math.max(
    Style.space(44),
    Style.font.body + Style.font.bodySmall + Style.spacing.controlPaddingY * 2)

  readonly property var selectedRow: root.rows[root.selectedIndex] || null
  readonly property string selectedLabel: selectedRow
    ? (selectedRow.profile ? selectedRow.name + " · " + selectedRow.profile : selectedRow.name)
    : ""

  // Whether the highlighted browser has a private mode at all. Offering the
  // toggle on a browser that cannot honour it would be a lie the user only
  // discovers after the window is already open.
  readonly property bool canGoPrivate: selectedRow && service
    ? service.supportsPrivate(String(selectedRow.browserId))
    : false

  function reset(nextUrl) {
    root.url = String(nextUrl || "")
    root.filterText = ""
    root.selectedIndex = 0
    // Both reset every time. A sticky toggle would quietly write a rule, or
    // quietly stop writing one, on the next unrelated link.
    root.remember = false
    root.wantPrivate = false
  }

  function takeFocus() { keyCatcher.forceActiveFocus() }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
  }

  function move(delta) {
    var count = root.rows.length
    if (count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + count) % count
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate(index, forcePrivate) {
    var row = root.rows[index]
    if (!row) return
    var goPrivate = (forcePrivate === true || root.wantPrivate)
      && (service ? service.supportsPrivate(String(row.browserId)) : false)
    root.chosen(String(row.browserId), String(row.profile || ""),
                root.remember && root.host !== "" && root.url !== "",
                goPrivate)
  }

  // Util.fileUrl rather than a hand-built file:// prefix: it percent-encodes
  // each path segment, which a browser installed under a path with a space
  // needs and a bare concatenation gets wrong.
  function iconFor(row) {
    var name = String((row && row.icon) || "")
    if (!name) return Quickshell.iconPath("application-x-executable", true)
    if (name.charAt(0) === "/") return Util.fileUrl(name)
    return Quickshell.iconPath(name, true)
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: root.visible

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (root.filterText) root.setFilter("")
        else root.cancelled()
        event.accepted = true
      } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
        if (root.url) root.remember = !root.remember
        event.accepted = true
      } else if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
        root.ruleRequested()
        event.accepted = true
      } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
        root.move(1)
        event.accepted = true
      } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab
                 || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
        root.move(-1)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        // Shift opens this one privately without arming the toggle, so the
        // fast path cannot leave state behind for the next link.
        root.activate(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0)
        event.accepted = true
      } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
        if (root.canGoPrivate) root.wantPrivate = !root.wantPrivate
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
    spacing: Style.spacing.md

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

    Text {
      width: parent.width
      text: root.filterText || "Type to filter…"
      color: root.foreground
      opacity: root.filterText ? 1 : 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Item {
      width: parent.width
      height: parent.height - header.height - privateRow.height - rememberRow.height
              - footer.height - Style.spacing.md * 5 - Style.space(24)

      ListView {
        id: list
        anchors.fill: parent
        model: root.rows
        clip: true
        currentIndex: root.selectedIndex
        boundsBehavior: Flickable.StopAtBounds
        spacing: Style.space(2)

        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index

          readonly property bool selected: index === root.selectedIndex
          readonly property string profile: String(modelData.profile || "")

          width: list.width
          height: root.rowHeight
          radius: Style.cornerRadius
          color: selected ? root.selectedBackground : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Image {
              source: root.iconFor(row.modelData)
              width: Style.font.iconLarge
              height: Style.font.iconLarge
              anchors.verticalCenter: parent.verticalCenter
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Style.font.iconLarge * 2
              sourceSize.height: Style.font.iconLarge * 2
              smooth: true
            }

            Column {
              width: parent.width - Style.font.iconLarge - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                width: parent.width
                text: String(row.modelData.name)
                color: row.selected ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: row.profile !== ""
                text: row.profile
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
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
        visible: root.rows.length === 0
        text: root.allRows.length === 0
              ? "No web browsers found"
              : "No matches for “" + root.filterText + "”"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    // Private first, remember second: this open, then every open after it.
    Rectangle {
      id: privateRow
      width: parent.width
      height: root.url ? root.rowHeight : 0
      visible: root.url !== ""
      radius: Style.cornerRadius
      color: root.wantPrivate ? root.selectedBackground : "transparent"
      opacity: root.canGoPrivate ? 1 : 0.5

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.wantPrivate ? "󰄲" : "󰄱"
          color: root.wantPrivate ? root.selectedText : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: privateRow.width - Style.space(20) - Style.font.icon - Style.space(10)
          text: root.canGoPrivate
            ? "Open in a private window, just this once"
            : (root.selectedRow ? root.selectedRow.name + " has no private mode" : "No private mode")
          color: root.wantPrivate ? root.selectedText : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: root.canGoPrivate
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.wantPrivate = !root.wantPrivate
      }
    }

    Rectangle {
      id: rememberRow
      width: parent.width
      height: root.url ? root.rowHeight : 0
      visible: root.url !== ""
      radius: Style.cornerRadius
      color: root.remember ? root.selectedBackground : "transparent"
      // Stated on the row that writes the rule, because that is the surprising
      // combination: the private tick above is about this open, but together
      // they mean every future link to this host opens private too.
      readonly property string privateSuffix:
        (root.remember && root.wantPrivate && root.canGoPrivate) ? " — as a private rule" : ""

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.remember ? "󰄲" : "󰄱"
          color: root.remember ? root.selectedText : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: rememberRow.width - Style.space(20) - Style.font.icon - Style.space(10)
          text: (root.selectedLabel
                  ? "Always use " + root.selectedLabel + " for " + root.host
                  : "Always use this browser for " + root.host)
                + rememberRow.privateSuffix
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

    Text {
      id: footer
      width: parent.width
      text: root.url
        ? "Enter open  ·  Shift+Enter private  ·  Ctrl+R remember  ·  Esc cancel"
        : "Enter open  ·  Esc cancel"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
