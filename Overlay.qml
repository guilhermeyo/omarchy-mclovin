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
      picker.reset(root.url)
      Qt.callLater(function() { picker.takeFocus() })
    }
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.guilhermeyo.mclovin")
  }

  // The picker hands off to the form when someone wants a rule for the link
  // they are looking at, instead of making them find the bar widget.
  function editRuleFor(index, forUrl) {
    root.mode = "editor"
    root.ruleIndex = index
    form.load(index, forUrl)
    Qt.callLater(function() { form.takeFocus() })
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
      width: Math.min(Style.space(root.editing ? 620 : 520), panel.width - Style.gapsOut * 2)

      // The picker is a list and wants a fixed, generous height. The form is a
      // document: it should be exactly as tall as it needs, up to a cap.
      readonly property real formHeight: Math.max(
        Style.space(380),
        Math.min(Style.space(700), form.desiredHeight + card.padding * 2))

      height: Math.min(
        root.editing ? formHeight : Style.space(540),
        panel.height - Style.gapsOut * 2)
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
        onChosen: function(browserId, profile, remember) {
          var pattern = remember ? Router.displayHost(Router.parseUrl(picker.url)) : ""
          if (root.service) root.service.choose(browserId, picker.url, pattern, profile)
          root.dismiss()
        }
        onRuleRequested: root.editRuleFor(-1, picker.url)
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
