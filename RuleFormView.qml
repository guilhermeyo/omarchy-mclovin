import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Router.js" as Router

// The rule form.
//
// The whole design goal is that nobody has to know the config file exists. Each
// section is a sentence with a blank in it — "when a link starts with …, open it
// in …" — and the preview underneath answers the only question that matters
// while you type: would this actually catch the links I mean, and is some
// earlier rule going to grab them first?
Item {
  id: root

  property var service: null
  property int ruleIndex: -1

  signal saved()
  signal cancelled()

  // Bumped by every edit so the preview bindings below re-evaluate. ListModel
  // mutations and imperative writes are invisible to QML bindings otherwise.
  property int revision: 0

  property string when: Router.WHEN_STARTS_WITH
  property bool advanced: false
  property string targetKind: "browser"
  property string browserValue: ""
  property string webappValue: ""
  property string commandText: ""
  property string testUrl: ""
  property string seedUrl: ""
  property bool wantPrivate: false
  property string presetValue: Router.PRESET_CUSTOM

  readonly property bool creating: ruleIndex < 0
  readonly property var rules: (service && service.rules) || []

  readonly property color foreground: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color accent: Color.menu.selectedText
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.38)
  readonly property string fontFamily: Style.font.menuFamily

  // ------------------------------------------------------------- model glue

  ListModel { id: termModel }

  function terms() {
    revision
    var out = []
    for (var i = 0; i < termModel.count; i++) {
      var v = String(termModel.get(i).value || "").trim()
      if (v) out.push(v)
    }
    return out
  }

  function setTerm(index, value) {
    if (index < 0 || index >= termModel.count) return
    termModel.setProperty(index, "value", String(value))
    revision++
  }

  function addTerm() {
    termModel.append({ value: "" })
    revision++
  }

  function removeTerm(index) {
    if (termModel.count <= 1) return
    termModel.remove(index)
    revision++
  }

  function applyRulePreset(id) {
    root.presetValue = String(id || Router.PRESET_CUSTOM)
    if (root.presetValue === Router.PRESET_CUSTOM) {
      root.loadNewRule(root.seedUrl)
      return
    }

    var preset = Router.rulePreset(root.presetValue)
    if (!preset || !preset.rule) return
    var rule = preset.rule

    root.when = rule.when
    root.advanced = rule.when === Router.WHEN_REGEX
    root.commandText = String(rule.command || "")
    root.wantPrivate = rule.private === true
    root.testUrl = String(preset.testUrl || "")
    if (rule.action === Router.ACTION_ZOOM) {
      root.targetKind = "zoom"
    } else if (rule.webapp) {
      // Same order normalizeRule reads them in. Without this branch a preset
      // that names a web app would land on "browser" and lose its destination
      // without saying so.
      root.targetKind = "webapp"
      root.webappValue = resolveWebappValue(rule.webapp)
    } else if (root.commandText) {
      root.targetKind = "command"
    } else {
      root.targetKind = "browser"
      root.browserValue = resolveBrowserValue(rule.browser, rule.profile)
    }
    termModel.clear()
    var list = rule.terms || []
    for (var i = 0; i < list.length; i++) termModel.append({ value: String(list[i]) })
    if (termModel.count === 0) termModel.append({ value: "" })
    root.revision++
  }

  function loadNewRule(seedUrl) {
    // A new rule seeded from the link in hand: host is the choice people make
    // nine times out of ten, and it is already filled in.
    root.presetValue = Router.PRESET_CUSTOM
    root.when = Router.WHEN_HOST
    root.advanced = false
    root.targetKind = "browser"
    root.commandText = ""
    root.wantPrivate = false
    root.testUrl = String(seedUrl || "")
    termModel.clear()
    var host = seedUrl ? Router.displayHost(Router.parseUrl(seedUrl)) : ""
    termModel.append({ value: host })
    root.browserValue = root.browserOptions.length ? root.browserOptions[0].value : ""
    root.webappValue = resolveWebappValue("")
    root.revision++
  }

  // Browser + profile travel as one string so the dropdown stays a plain
  // value/label list. Ids never contain a pipe; profile names might, so only
  // the first separator counts.
  function packTarget(browserId, profile) { return String(browserId || "") + "|" + String(profile || "") }
  function unpackBrowser(value) {
    var v = String(value || "")
    var bar = v.indexOf("|")
    return bar === -1 ? v : v.slice(0, bar)
  }
  function unpackProfile(value) {
    var v = String(value || "")
    var bar = v.indexOf("|")
    return bar === -1 ? "" : v.slice(bar + 1)
  }

  // A rule can name a target the picker does not offer as its own row: a
  // browser with no profile, when that browser has profiles, has no bare entry
  // in the list. Without this the dropdown falls back to printing its own raw
  // value ("brave-browser|") and the preview loses the destination entirely.
  // Prefer the exact pair, then any row for the same browser, then nothing.
  function resolveBrowserValue(browserId, profile) {
    var wanted = packTarget(browserId, profile)
    var options = root.browserOptions
    var i
    for (i = 0; i < options.length; i++) {
      if (options[i].value === wanted) return wanted
    }
    var id = String(browserId || "")
    for (i = 0; i < options.length; i++) {
      if (unpackBrowser(options[i].value) === id) return options[i].value
    }
    return options.length ? options[0].value : ""
  }

  readonly property var browserOptions: {
    revision
    var rows = (service && service.pickerEntries) || []
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      out.push({
        value: packTarget(r.browserId, r.profile),
        label: r.profile ? r.name + " · " + r.profile : r.name
      })
    }
    return out
  }

  // Every installed web app, not just the one that owns the link: the form is
  // where a rule is written from scratch, and the picker's link is not in hand.
  readonly property var webappOptions: {
    revision
    var apps = (service && service.webapps) || []
    var out = []
    for (var i = 0; i < apps.length; i++) {
      out.push({ value: String(apps[i].id), label: String(apps[i].name) })
    }
    return out
  }

  // A rule can name a web app that has since been uninstalled. Falling back to
  // the first keeps the dropdown from printing a raw desktop id.
  function resolveWebappValue(id) {
    var wanted = String(id || "")
    var options = root.webappOptions
    for (var i = 0; i < options.length; i++) {
      if (options[i].value === wanted) return wanted
    }
    return options.length ? options[0].value : ""
  }

  readonly property var presetOptions: Router.rulePresetOptions()

  // ------------------------------------------------------------- lifecycle

  function load(index, seedUrl) {
    root.ruleIndex = index === undefined ? -1 : index
    root.revision = 0
    root.seedUrl = String(seedUrl || "")
    root.testUrl = root.seedUrl
    termModel.clear()

    var existing = (index >= 0 && index < root.rules.length) ? root.rules[index] : null

    if (existing) {
      root.presetValue = Router.PRESET_CUSTOM
      root.when = existing.when
      root.advanced = existing.when === Router.WHEN_REGEX
      var list = existing.terms || []
      for (var i = 0; i < list.length; i++) termModel.append({ value: String(list[i]) })
      if (existing.action === Router.ACTION_ZOOM) {
        root.targetKind = "zoom"
        root.commandText = ""
        root.browserValue = root.browserOptions.length ? root.browserOptions[0].value : ""
      } else if (existing.command) {
        root.targetKind = "command"
        root.commandText = existing.command
        root.browserValue = root.browserOptions.length ? root.browserOptions[0].value : ""
      } else if (existing.webapp) {
        root.targetKind = "webapp"
        root.commandText = ""
        root.browserValue = root.browserOptions.length ? root.browserOptions[0].value : ""
      } else {
        root.targetKind = "browser"
        root.commandText = ""
        root.browserValue = resolveBrowserValue(existing.browser, existing.profile)
      }
      root.webappValue = resolveWebappValue(existing.webapp)
      root.wantPrivate = existing.private === true
    } else {
      root.loadNewRule(seedUrl)
    }

    if (termModel.count === 0) termModel.append({ value: "" })
    root.revision++
  }

  function takeFocus() { Qt.callLater(function() { if (termRepeater.count > 0) firstFieldFocus() }) }
  function firstFieldFocus() {
    var item = termRepeater.itemAt(0)
    if (item && item.field) item.field.forceActiveFocus()
  }

  // ---------------------------------------------------------------- preview

  readonly property var draftRule: {
    revision
    var t = terms()
    if (t.length === 0) return null
    if (root.targetKind === "zoom")
      return Router.makeRule(root.when, t, "", "", "", false, { action: Router.ACTION_ZOOM })
    if (root.targetKind === "command") {
      var cmd = String(root.commandText).trim()
      if (!cmd) return null
      return Router.makeRule(root.when, t, "", "", cmd)
    }
    if (root.targetKind === "webapp") {
      var app = String(root.webappValue).trim()
      if (!app) return null
      return Router.makeRule(root.when, t, "", "", "", false, { webapp: app })
    }
    var id = unpackBrowser(root.browserValue)
    if (!id) return null
    return Router.makeRule(root.when, t, id, unpackProfile(root.browserValue), "",
                           root.wantPrivate && root.canGoPrivate)
  }

  readonly property bool valid: draftRule !== null

  // Private is a browser flag, so a command rule never offers it — the command
  // already says how it wants to launch. A browser with no private mode says so
  // rather than accepting a tick it cannot honour.
  readonly property bool canGoPrivate: {
    revision
    if (root.targetKind !== "browser" || !service) return false
    var id = unpackBrowser(root.browserValue)
    return id ? service.supportsPrivate(id) : false
  }

  readonly property string targetLabel: {
    revision
    if (root.targetKind === "zoom") return "Zoom directly"
    if (root.targetKind === "command") return String(root.commandText).trim()
    if (root.targetKind === "webapp") {
      for (var w = 0; w < root.webappOptions.length; w++) {
        if (root.webappOptions[w].value === root.webappValue) return root.webappOptions[w].label
      }
      return ""
    }
    for (var i = 0; i < root.browserOptions.length; i++) {
      if (root.browserOptions[i].value === root.browserValue) return root.browserOptions[i].label
    }
    return ""
  }

  readonly property string example: draftRule ? Router.exampleUrl(draftRule) : ""

  // The rule list as it would be after saving — including the re-sort, since
  // editing a rule changes how narrow it is and therefore where it lands.
  readonly property var projectedRules: {
    revision
    var out = []
    for (var i = 0; i < root.rules.length; i++) out.push(root.rules[i])
    if (!draftRule) return out
    if (root.creating) out.push(draftRule)
    else if (root.ruleIndex < out.length) out[root.ruleIndex] = draftRule
    return Router.sortBySpecificity(out)
  }

  // Found by identity rather than arithmetic: the sort moved it.
  readonly property int ownIndex: {
    revision
    if (!draftRule) return -1
    for (var i = 0; i < projectedRules.length; i++) {
      if (projectedRules[i] === draftRule) return i
    }
    return -1
  }

  // Which URL the conflict check runs against: whatever is in the test box,
  // falling back to the synthesised example.
  readonly property string checkUrl: String(root.testUrl).trim() || root.example

  readonly property int winnerIndex: {
    revision
    if (!draftRule || !checkUrl) return -1
    return Router.winningRuleIndex(projectedRules, checkUrl)
  }

  // Only a real conflict: this rule would catch the link, but another rule is
  // narrower and takes it. A link this rule simply does not match is not a
  // warning, it is the test box doing its job.
  readonly property bool checkMatches: {
    revision
    if (!draftRule || !checkUrl) return false
    return Router.ruleMatches(draftRule, Router.parseUrl(checkUrl))
  }

  readonly property bool shadowed: checkMatches && winnerIndex !== -1 && winnerIndex !== ownIndex

  readonly property bool testMatches: {
    revision
    var u = String(root.testUrl).trim()
    if (!u || !draftRule) return false
    return Router.ruleMatches(draftRule, Router.parseUrl(u))
  }

  function save() {
    if (!root.valid || !root.service) return
    root.service.saveRule(root.ruleIndex, root.draftRule)
    root.saved()
  }

  Keys.priority: Keys.AfterItem
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      root.cancelled()
      event.accepted = true
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
               && (event.modifiers & Qt.ControlModifier)) {
      root.save()
      event.accepted = true
    }
  }

  // -------------------------------------------------------------------- ui

  // How tall the card should be. Adding the parts up by hand got this wrong:
  // half the rows are wrapping Text, whose implicitHeight is only truthful once
  // the width it wraps at is settled, so the sum came in short and the card
  // squeezed the preview against the footer. Letting the layout report its own
  // implicitHeight — with the scroller contributing its content height as a
  // preferred size — is both accurate and self-maintaining.
  implicitHeight: formLayout.implicitHeight

  ColumnLayout {
    id: formLayout
    anchors.fill: parent
    // Looser than the rhythm inside the form on purpose: this spacing separates
    // the three fixed regions — header, scrolling body, footer — and at `md`
    // the footer rule sat almost against the test field. The rhythm between
    // fields stays `md`, so the form itself reads the same.
    spacing: Style.spacing.lg

    // ------------------------------------------------------------- header
    RowLayout {
      id: headerRow
      Layout.fillWidth: true
      spacing: Style.spacing.md

      McLovinIcon {
        iconSize: Style.font.display
        color: root.foreground
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          text: root.creating ? "New rule" : "Edit rule"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          text: "When two rules catch the same link, the narrower one wins"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

    }

    Dropdown {
      Layout.fillWidth: true
      visible: root.creating
      label: "Start from…"
      options: root.presetOptions
      value: root.presetValue
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      onChanged: function(value) { root.applyRulePreset(value) }
    }

    PanelSeparator { foreground: root.foreground }

    // ----------------------------------------------------------- scrolling
    Flickable {
      Layout.fillWidth: true
      Layout.fillHeight: true
      // Asks for exactly the content, so the card can grow to fit; fillHeight
      // still lets it give the space back and scroll when the screen is the
      // shorter of the two. Header and footer sit outside, so they stay put.
      Layout.preferredHeight: body.implicitHeight
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      ColumnLayout {
        id: body
        width: parent.width
        spacing: Style.spacing.md

        // ------------------------------------------------- when a link…
        RowLayout {
          Layout.fillWidth: true

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "When a link…"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Regex is one click away, not in anyone's face.
          Text {
            text: root.advanced ? "hide advanced" : "advanced"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: mouseAdvanced.containsMouse

            MouseArea {
              id: mouseAdvanced
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.advanced = !root.advanced
                if (!root.advanced && root.when === Router.WHEN_REGEX) root.when = Router.WHEN_CONTAINS
                root.revision++
              }
            }
          }
        }

        ButtonGroup {
          Layout.fillWidth: true
          value: root.when
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          options: {
            var base = [
              { value: Router.WHEN_STARTS_WITH, label: "Starts with" },
              { value: Router.WHEN_CONTAINS, label: "Contains" },
              { value: Router.WHEN_HOST, label: "Host is" }
            ]
            if (root.advanced) base.push({ value: Router.WHEN_REGEX, label: "Regex" })
            return base
          }
          onChanged: function(value) { root.when = value; root.revision++ }
        }

        Text {
          Layout.fillWidth: true
          text: {
            switch (root.when) {
              case Router.WHEN_STARTS_WITH:
                return "The link begins with this. Good for one section of a site: github.com/acme/"
              case Router.WHEN_HOST:
                return "The link is on exactly this site, with or without www."
              case Router.WHEN_REGEX:
                return "A regular expression tested against the whole link, case-insensitive."
              default:
                return "This text appears anywhere in the link. Good for a word like invoice."
            }
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ------------------------------------------------------- terms
        Repeater {
          id: termRepeater
          model: termModel

          RowLayout {
            id: termRow
            required property int index
            required property string value
            property alias field: termField

            Layout.fillWidth: true
            spacing: Style.space(6)

            TextField {
              id: termField
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              Layout.minimumWidth: Style.space(160)
              foreground: root.foreground
              text: termRow.value
              placeholderText: {
                switch (root.when) {
                  case Router.WHEN_STARTS_WITH: return "https://github.com/acme/"
                  case Router.WHEN_HOST: return "example.com"
                  case Router.WHEN_REGEX: return "^https?://(\\w+)\\.internal\\."
                  default: return "invoice"
                }
              }
              onTextChanged: root.setTerm(termRow.index, text)
              onAccepted: root.save()
            }

            PanelActionButton {
              visible: termModel.count > 1
              iconText: "󰅖"
              tooltipText: "Remove this term"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: root.removeTerm(termRow.index)
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            text: "+ Add another"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.addTerm()
          }

          Text {
            Layout.fillWidth: true
            visible: termModel.count > 1
            text: "Any one of these is enough"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }
        }

        PanelSeparator { foreground: root.foreground }

        // -------------------------------------------------- open it in…
        PanelSectionHeader {
          Layout.fillWidth: true
          text: "Open it in…"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        ButtonGroup {
          Layout.fillWidth: true
          value: root.targetKind
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          options: [
            { value: "browser", label: "A browser" },
            { value: "webapp", label: "A web app" },
            { value: "command", label: "A command" },
            { value: "zoom", label: "Zoom directly" }
          ]
          onChanged: function(value) { root.targetKind = value; root.revision++ }
        }

        Dropdown {
          Layout.fillWidth: true
          visible: root.targetKind === "browser"
          showLabel: false
          options: root.browserOptions
          value: root.browserValue
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onChanged: function(value) { root.browserValue = value; root.revision++ }
        }

        Text {
          Layout.fillWidth: true
          visible: root.targetKind === "browser" && root.browserOptions.length === 0
          text: "No browsers detected yet."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Dropdown {
          Layout.fillWidth: true
          visible: root.targetKind === "webapp" && root.webappOptions.length > 0
          showLabel: false
          options: root.webappOptions
          value: root.webappValue
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onChanged: function(value) { root.webappValue = value; root.revision++ }
        }

        Text {
          Layout.fillWidth: true
          visible: root.targetKind === "webapp"
          text: root.webappOptions.length === 0
            ? "No web apps installed. Omarchy writes one per site under Install → Web app."
            : "Links land in the window that app already has open, and open one when it has none."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Toggle {
          Layout.fillWidth: true
          visible: root.targetKind === "browser" && root.browserOptions.length > 0
          enabled: root.canGoPrivate
          opacity: root.canGoPrivate ? 1 : 0.5
          checked: root.wantPrivate && root.canGoPrivate
          label: "Open in a private window"
          description: root.canGoPrivate
            ? "Every link this rule catches opens incognito, in this profile."
            : (root.targetLabel || "This browser") + " has no private-window flag."
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: {
            if (!root.canGoPrivate) return
            root.wantPrivate = !root.wantPrivate
            root.revision++
          }
        }

        TextField {
          Layout.fillWidth: true
          visible: root.targetKind === "command"
          foreground: root.foreground
          text: root.commandText
          placeholderText: "zapzap {url}"
          onTextChanged: { root.commandText = text; root.revision++ }
        }

        Text {
          Layout.fillWidth: true
          visible: root.targetKind === "command"
          text: "{url} is replaced with the link. Leave it out and the app opens with nothing."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.targetKind === "zoom"
          text: "Turns a numbered Zoom meeting link into zoommtg:// before a browser opens. If the protocol cannot launch, the original link goes to your fallback browser."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.targetKind === "zoom"
          text: "After you save, the mclovin panel offers an optional Chromium companion for Zoom links clicked inside any website."
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        // ------------------------------------------------------ preview
        PanelSectionHeader {
          Layout.fillWidth: true
          text: "Preview"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          Layout.fillWidth: true
          text: {
            if (!root.valid) return "Fill in a term and a destination to see what this catches."
            var where = root.targetLabel
              + (root.wantPrivate && root.canGoPrivate ? ", in a private window" : "")
            if (root.when === Router.WHEN_REGEX)
              return "Anything this pattern matches opens in " + where + ". Paste a link below to check it."
            return "A link like " + root.example + " would open in " + where + "."
          }
          color: root.valid ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WrapAnywhere
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            Layout.fillWidth: true
            // A TextField will not shrink below its implicitWidth on its own,
            // which pushes the verdict off the edge of the card.
            Layout.preferredWidth: 0
            Layout.minimumWidth: Style.space(120)
            foreground: root.foreground
            text: root.testUrl
            placeholderText: "Try a link…"
            onTextChanged: { root.testUrl = text; root.revision++ }
          }

          Text {
            visible: String(root.testUrl).trim() !== "" && root.valid
            text: root.testMatches ? "󰄬 matches" : "󰅖 no match"
            color: root.testMatches ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: implicitWidth
          }
        }

        // The one thing a list of ordered rules gets wrong in practice.
        Rectangle {
          Layout.fillWidth: true
          visible: root.shadowed
          implicitHeight: shadowText.implicitHeight + Style.spacing.xl
          radius: Style.cornerRadius
          color: root.selectedBackground

          Text {
            id: shadowText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            text: {
              var winner = root.projectedRules[root.winnerIndex]
              if (!winner) return ""
              return "“" + Router.ruleSummary(winner) + "” is narrower and takes this link"
                + " — it opens in " + (root.service ? root.service.targetName(winner) : Router.ruleTargetLabel(winner))
                + ". Narrow this rule further if you want it to win instead."
            }
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    PanelSeparator { foreground: root.foreground }

    // ------------------------------------------------------------- footer
    RowLayout {
      id: footerRow
      Layout.fillWidth: true
      Layout.bottomMargin: Style.space(2)
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: "Ctrl+Enter save  ·  Esc cancel"
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        verticalAlignment: Text.AlignVCenter
      }

      Button {
        text: "Cancel"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.cancelled()
      }

      Button {
        text: root.creating ? "Add rule" : "Save rule"
        bordered: true
        enabled: root.valid
        opacity: root.valid ? 1 : 0.45
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.save()
      }
    }
  }
}
