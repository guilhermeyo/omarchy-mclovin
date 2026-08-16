import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Router.js" as Router
import "Browsers.js" as Browsers

// The browser picker screen. Type to filter, arrows to move, Enter to open.
// Rows are browser+profile pairs — see Browsers.pickerEntries for why.
//
// Everything below the list is one block: private, then remember, then the key
// hints. The card sizes itself to that block plus the list, so there is never a
// gap between the last browser and the first choice you make about it.
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

  // Which shape the remembered rule takes, and the text it matches on. The
  // term is editable: the whole point is that a link to one pull request can
  // become a rule about the whole of GitHub without opening the form.
  property string rememberWhen: Router.WHEN_HOST
  property string rememberTerm: ""

  signal chosen(string browserId, string profile, bool remember, bool wantPrivate)
  signal cancelled()

  readonly property var parsed: Router.parseUrl(root.url)
  readonly property string host: Router.displayHost(root.parsed)
  readonly property var allRows: (service && service.pickerEntries) || []
  readonly property var rows: Browsers.filterPickerEntries(root.allRows, root.filterText)

  readonly property color foreground: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.34)
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

  // The card hugs this, so a short browser list gives a short card.
  implicitHeight: pickerLayout.implicitHeight

  // -------------------------------------------------------------- remember

  // What each chip suggests. Site is the default because it is the answer nine
  // times out of ten; Path narrows to one project; Contains is the one you
  // trim by hand, so it starts from the host and gets shortened.
  function suggestionFor(when) {
    switch (when) {
      case Router.WHEN_STARTS_WITH: return Router.pathPrefix(root.parsed)
      default: return root.host
    }
  }

  function setRememberWhen(when) {
    root.rememberWhen = when
    root.rememberTerm = suggestionFor(when)
  }

  function whenWord(when) {
    switch (when) {
      case Router.WHEN_STARTS_WITH: return "path"
      case Router.WHEN_CONTAINS: return "contains"
      default: return "site"
    }
  }

  // The sentence on the remember line: exactly the rule that will exist.
  readonly property string rememberSummary: {
    var where = root.selectedLabel || "this browser"
    if (root.wantPrivate && root.canGoPrivate) where += " · private"
    return where + " · " + whenWord(root.rememberWhen)
  }

  function reset(nextUrl) {
    root.url = String(nextUrl || "")
    root.filterText = ""
    root.selectedIndex = 0
    // Both reset every time. A sticky toggle would quietly write a rule, or
    // quietly stop writing one, on the next unrelated link.
    root.remember = false
    root.wantPrivate = false
    root.rememberWhen = Router.WHEN_HOST
    root.rememberTerm = root.host
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
                root.remember && String(root.rememberTerm).trim() !== "",
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
      } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
        if (root.canGoPrivate) root.wantPrivate = !root.wantPrivate
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

  ColumnLayout {
    id: pickerLayout
    anchors.fill: parent
    spacing: Style.spacing.md

    // ---------------------------------------------------------------- header
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md

      McLovinIcon {
        iconSize: Style.font.displayLarge
        color: root.foreground
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          Layout.fillWidth: true
          text: root.host || "Open a browser"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: root.url !== ""
          text: root.url
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

    Text {
      Layout.fillWidth: true
      text: root.filterText || "Type to filter…"
      color: root.foreground
      opacity: root.filterText ? 1 : 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    // ------------------------------------------------------------------ list
    //
    // Asks for exactly the rows it has, so four browsers do not leave a hole
    // above the checkboxes. Past the cap it scrolls instead of growing.
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      // Capped at whole rows. A cap in pixels slices the last browser in half,
      // which reads as a rendering fault rather than as "there is more below".
      readonly property int maxVisibleRows: 6
      readonly property int rowPitch: root.rowHeight + list.spacing
      Layout.preferredHeight: Math.min(
        list.contentHeight,
        maxVisibleRows * rowPitch - list.spacing)
      Layout.minimumHeight: Style.space(80)

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

    PanelSeparator {
      Layout.fillWidth: true
      visible: root.url !== ""
      foreground: root.foreground
    }

    // --------------------------------------------------------------- private
    CheckRow {
      Layout.fillWidth: true
      visible: root.url !== ""
      checked: root.wantPrivate
      enabled: root.canGoPrivate
      opacity: root.canGoPrivate ? 1 : 0.5
      onToggled: if (root.canGoPrivate) root.wantPrivate = !root.wantPrivate

      Text {
        Layout.fillWidth: true
        text: root.canGoPrivate
          ? "Private — just this once"
          : (root.selectedRow ? root.selectedRow.name + " has no private mode" : "No private mode")
        color: root.wantPrivate ? root.selectedText : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }

    // -------------------------------------------------------------- remember
    //
    // The row reads as the rule it will create: Always <browser · profile>
    // <how> <what>. The term is a field and the how is three chips, so a link
    // to one pull request becomes a rule about a whole site without leaving
    // the picker.
    CheckRow {
      id: alwaysRow
      Layout.fillWidth: true
      visible: root.url !== ""
      checked: root.remember
      onToggled: root.remember = !root.remember

      Text {
        text: "Always"
        color: root.remember ? root.selectedText : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        text: root.rememberSummary
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        // A fixed cap, not a fraction of the row: sizing a child from the width
        // of the layout that is sizing it is what "recursive rearrange" means.
        Layout.maximumWidth: Style.space(190)
      }

      TextField {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        Layout.minimumWidth: Style.space(90)
        foreground: root.foreground
        text: root.rememberTerm
        placeholderText: root.host
        onTextChanged: root.rememberTerm = text
        // Typing here is a statement of intent; arm the checkbox with it.
        onActiveFocusChanged: if (activeFocus && root.url) root.remember = true
      }

      Chip { label: "Site";     when: Router.WHEN_HOST }
      Chip { label: "Path";     when: Router.WHEN_STARTS_WITH }
      Chip { label: "Contains"; when: Router.WHEN_CONTAINS }
    }

    Text {
      Layout.fillWidth: true
      text: root.url
        ? "Enter open  ·  Shift+Enter private  ·  Ctrl+R always  ·  Esc cancel"
        : "Enter open  ·  Esc cancel"
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }
  }

  // A checkbox glyph plus whatever the caller puts beside it, on one line.
  component CheckRow: RowLayout {
    id: checkRow
    property bool checked: false
    default property alias content: checkContent.data
    signal toggled()

    spacing: Style.space(8)

    Text {
      text: checkRow.checked ? "󰄲" : "󰄱"
      color: checkRow.checked ? root.selectedText : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignVCenter

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        enabled: checkRow.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: checkRow.toggled()
      }
    }

    RowLayout {
      id: checkContent
      Layout.fillWidth: true
      spacing: Style.space(8)
    }
  }

  // Tiny segmented control for how the remembered rule matches.
  component Chip: Rectangle {
    id: chip
    property string label: ""
    property string when: ""
    readonly property bool active: root.rememberWhen === when

    Layout.alignment: Qt.AlignVCenter
    implicitWidth: chipText.implicitWidth + Style.space(12)
    implicitHeight: Math.max(Style.space(20), chipText.implicitHeight + Style.space(6))
    radius: Math.max(2, Style.cornerRadius)
    color: chip.active ? root.selectedBackground : "transparent"
    border.width: 1
    border.color: chip.active
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      color: chip.active ? root.selectedText : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.setRememberWhen(chip.when)
        root.remember = true
      }
    }
  }
}
