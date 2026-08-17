import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Router.js" as Router

// The plugin's one fullscreen surface, hosting two screens: the browser picker
// and the rule form.
//
// They share a file because the shell gives a plugin a single `overlay` entry
// point — declaring `panel` as well would make the panel loader take over and
// the overlay would never mount. Sharing is no loss: both are the same centred
// card over the same scrim, and keeping the chrome in one place is why they
// look like one app.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string mode: "picker"
  property string url: ""
  property int ruleIndex: -1

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property bool editing: mode === "editor"

  // Called by the shell with whatever summon() passed. `mode` selects the
  // screen; an unparseable payload falls back to the picker, which is the one
  // that is safe to show without context.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = {} }

    root.mode = String(payload.mode || "") === "editor" ? "editor" : "picker"
    root.url = String(payload.url || "")
    root.ruleIndex = payload.ruleIndex === undefined ? -1 : Number(payload.ruleIndex)
    root.opened = true

    if (service && typeof service.refreshBrowsers === "function") service.refreshBrowsers()

    if (root.editing) {
      form.load(root.ruleIndex, root.url)
      Qt.callLater(function() { form.takeFocus() })
    } else {
      picker.reset(root.url, payload.private === true)
      Qt.callLater(function() { picker.takeFocus() })
    }
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.guilhermeyo.mclovin")
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
      // The form carries preview prose that should not wrap to a third line;
      // the picker carries a remember row with a term field and three chips.
      // Both need more than a plain list would.
      width: Math.min(Style.space(root.editing ? 680 : 620), panel.width - Style.gapsOut * 2)

      // Both screens are documents: exactly as tall as their content, insets
      // included, so nothing scrolls where there is room and — for the picker —
      // there is never a gap between the last browser and the first checkbox.
      //
      // The clamp against panel.height is what makes the small monitor work:
      // 1280x720 logical leaves 710, and anything wanting more gives the
      // difference back to its scroller rather than growing off screen. The
      // floor keeps a half-filled surface from looking collapsed.
      readonly property real contentHeight: Math.max(
        Style.space(320),
        (root.editing ? form.implicitHeight : picker.implicitHeight)
          + card.contentTopInset + card.contentBottomInset)

      height: Math.min(contentHeight, panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      MouseArea { anchors.fill: parent; onClicked: {} }

      PickerView {
        id: picker
        visible: !root.editing
        enabled: visible
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        service: root.service
        onCancelled: root.dismiss()
        onChosen: function(browserId, profile, remember, wantPrivate) {
          // The picker owns what the rule matches; this only hands it over.
          var rule = remember
            ? { when: picker.rememberWhen, term: picker.rememberTerm }
            : null

          // Only dismiss on success. Closing on a failed launch is the same
          // gesture as closing on a successful one, which turns "the link went
          // nowhere" into a mystery instead of a message.
          var ok = root.service
            ? root.service.choose(browserId, picker.url, profile, wantPrivate, rule)
            : false
          if (ok) {
            root.dismiss()
          } else {
            picker.errorText = (root.service && root.service.lastError)
              ? root.service.lastError
              : "Could not open that browser"
          }
        }
      }

      RuleFormView {
        id: form
        visible: root.editing
        enabled: visible
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        service: root.service
        onCancelled: root.dismiss()
        onSaved: root.dismiss()
      }
    }
  }
}
