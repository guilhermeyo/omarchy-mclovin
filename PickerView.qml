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

  // The overlay is a fullscreen surface with a centred card, so the picker
  // opens *underneath* wherever the pointer already happened to be. Without
  // this, that row's containsMouse fires the moment the surface appears and
  // takes the selection off the first row before the user has done anything:
  // a pointer sitting still in the middle of the screen counted as a choice,
  // and whichever browser landed under it won.
  //
  // Moving the pointer onto the first row instead is not an option. A Wayland
  // client cannot warp the cursor at all — only the compositor can, and this
  // plugin deliberately stopped calling out to one in 896d15c. So the pointer
  // is left alone and hover stays inert until it actually travels.
  property bool pointerArmed: false
  property real pointerX: NaN
  property real pointerY: NaN

  function disarmPointer() {
    root.pointerArmed = false
    root.pointerX = NaN
    root.pointerY = NaN
  }

  // Positions are compared in root's coordinate space, never the row's.
  // Keyboard navigation scrolls rows under a stationary pointer, and a
  // row-local coordinate would read that scroll as movement and hand the
  // selection straight back to the mouse.
  function notePointer(item, localX, localY, index) {
    var p = item.mapToItem(root, localX, localY)
    if (!root.pointerArmed) {
      if (isNaN(root.pointerX)) {
        root.pointerX = p.x
        root.pointerY = p.y
        return
      }
      if (Math.abs(p.x - root.pointerX) < 2 && Math.abs(p.y - root.pointerY) < 2) return
      root.pointerArmed = true
    }
    root.selectedIndex = index
  }

  // Separate from `remember` on purpose. Private is a property of this one
  // open; remembering is a property of every future one. Ticking both is
  // allowed and says so in the remember line, but neither implies the other.
  property bool wantPrivate: false

  // Which shape the remembered rule takes, and the text it matches on. The
  // term is editable: the whole point is that a link to one pull request can
  // become a rule about the whole of GitHub without opening the form.
  property string rememberWhen: Router.WHEN_HOST
  property string rememberTerm: ""

  // Set by the overlay when a pick fails to launch. Shown in place of the key
  // hints, because at that moment the hints are not what you need to read.
  property string errorText: ""

  signal chosen(string browserId, string profile, bool remember, bool wantPrivate)
  signal handlerChosen(string scheme, string path, bool remember)
  signal cancelled()

  // Non-empty when the picker is choosing which application owns a URI scheme
  // rather than which browser opens a link. The rows, the header and what
  // Always writes all follow from it; everything else is the same screen.
  property string handlerScheme: ""
  readonly property bool choosingHandler: root.handlerScheme !== ""
  // service.schemeHandlers is named here, not only reached through handlersFor().
  // A binding re-evaluates on the properties it actually touched, and a function
  // call touches none -- so a scan finishing after this screen opened would have
  // left it listing nothing, with no way to tell that from "no application
  // claims this".
  readonly property var handlerRows: {
    if (!root.choosingHandler || !service) return []
    var all = service.schemeHandlers
    return (all && all[root.handlerScheme]) || []
  }

  readonly property var parsed: Router.parseUrl(root.url)
  readonly property string host: Router.displayHost(root.parsed)
  readonly property var allRows: (service && service.pickerEntries) || []
  readonly property var rows: root.choosingHandler
    ? root.handlerRows
    : Browsers.filterPickerEntries(root.allRows, root.filterText)

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
    if (root.choosingHandler)
      return (root.selectedRow ? String(root.selectedRow.name) : "this application")
        + " · every " + root.handlerScheme + ":// link"
    var where = root.selectedLabel || "this browser"
    if (root.wantPrivate && root.canGoPrivate) where += " · private"
    return where + " · " + whenWord(root.rememberWhen)
  }

  function reset(nextUrl, startPrivate, reason, scheme) {
    root.handlerScheme = String(scheme || "")
    root.url = String(nextUrl || "")
    root.filterText = ""
    root.selectedIndex = 0
    root.disarmPointer()
    // Both reset every time. A sticky toggle would quietly write a rule, or
    // quietly stop writing one, on the next unrelated link.
    root.remember = false
    // Armed only when the caller asked for private explicitly, which is the
    // one case where carrying it in is what was meant.
    root.wantPrivate = startPrivate === true
    root.rememberWhen = Router.WHEN_HOST
    root.rememberTerm = root.host
    // Why the picker opened, when a rule named a destination that could not be
    // run. It goes where a failed pick's message goes, because it is the same
    // kind of news and the same moment for reading it.
    root.errorText = String(reason || "")
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
    // Arrow keys scroll rows past the pointer. Disarming here keeps the row
    // that slides underneath it from snatching the selection back on the
    // next keypress.
    root.disarmPointer()
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate(index, forcePrivate) {
    var row = root.rows[index]
    if (!row) return

    if (root.choosingHandler) {
      root.handlerChosen(root.handlerScheme, String(row.path || ""), root.remember)
      return
    }
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
        root.activate(root.selectedIndex,
                      !root.choosingHandler && (event.modifiers & Qt.ShiftModifier) !== 0)
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
          text: root.choosingHandler
      ? (root.handlerScheme + ":// links")
      : (root.host || "Open a browser")
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
          // For a handler row the second line is the directory the entry lives
          // in, because two applications can share a name and an id and the
          // directory is the only thing that tells them apart.
          readonly property string profile: root.choosingHandler
            ? String(modelData.where || "")
            : String(modelData.profile || "")

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
                text: String(row.modelData.name || "")
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
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.notePointer(rowMouse, mouseX, mouseY, index)
            onPositionChanged: function(mouse) { root.notePointer(rowMouse, mouse.x, mouse.y, index) }
            // A click is always a deliberate choice, armed or not, and it acts
            // on the row under the pointer rather than the highlighted one.
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
    // An application either has a private mode or does not, and neither answer
    // belongs in a question about which application owns a scheme.
    CheckRow {
      Layout.fillWidth: true
      visible: root.url !== "" && !root.choosingHandler
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

      // Nothing below exists until Always is ticked. Unticked, this line is one
      // checkbox and one word — a question, not a form. `visible: false` takes
      // items out of the layout entirely, so the row and the card shrink with
      // them instead of leaving the hole a ghosted control would.
      Text {
        visible: root.remember
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
        visible: root.remember
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        Layout.minimumWidth: Style.space(90)
        foreground: root.foreground
        text: root.rememberTerm
        placeholderText: root.host
        onTextChanged: root.rememberTerm = text
      }

      // Tighter than the row's own spacing so the three read as one strip
      // hanging off the field, not as three more controls in the line.
      RowLayout {
        visible: root.remember
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(2)

        Chip { label: "Site";     when: Router.WHEN_HOST }
        Chip { label: "Path";     when: Router.WHEN_STARTS_WITH }
        Chip { label: "Contains"; when: Router.WHEN_CONTAINS }
      }

      // Holds the right edge while the row is just a checkbox, so ticking
      // Always grows the line rather than shoving it sideways.
      Item { Layout.fillWidth: true; visible: !root.remember }
    }

    Text {
      Layout.fillWidth: true
      text: root.errorText !== ""
        ? root.errorText
        : (root.choosingHandler
            ? "Enter open  ·  Ctrl+R always  ·  Esc cancel"
            : (root.url
                ? "Enter open  ·  Shift+Enter private  ·  Ctrl+R always  ·  Esc cancel"
                : "Enter open  ·  Esc cancel"))
      color: root.errorText !== "" ? root.selectedText : root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
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

  // All three the same width, measured off the longest label, so they read as
  // one quiet strip rather than three buttons of assorted sizes.
  TextMetrics {
    id: chipMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "Contains"
  }

  // How the remembered rule matches. Deliberately not a button: no box, no
  // fill, caption-sized dim text with a hairline under the active one. Private
  // and Always are the actions on these two lines; this is a detail of one of
  // them, and it does not exist at all until that one is ticked.
  component Chip: Item {
    id: chip
    property string label: ""
    property string when: ""
    readonly property bool active: root.rememberWhen === when

    Layout.alignment: Qt.AlignVCenter
    Layout.preferredWidth: chipMetrics.width + Style.space(6)
    implicitHeight: chipText.implicitHeight + Style.space(5)

    Text {
      id: chipText
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      text: chip.label
      color: chip.active ? root.foreground : root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      anchors.top: chipText.bottom
      anchors.topMargin: Style.space(2)
      anchors.horizontalCenter: parent.horizontalCenter
      width: chipText.implicitWidth
      height: 1
      visible: chip.active
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setRememberWhen(chip.when)
    }
  }
}
