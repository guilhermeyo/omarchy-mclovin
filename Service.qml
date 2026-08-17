import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Router.js" as Router
import "Browsers.js" as Browsers
import "Import.js" as Import

// Headless singleton that owns everything stateful: the rules, the stats, the
// list of installed browsers, and the IPC entry point the XDG handler calls.
//
// It is a `service` kind so the shell loads it at startup and keeps it alive.
// That matters: the bar widget may not be on the bar and the picker overlay is
// only mounted when summoned, but the IPC target has to answer the moment a
// link is clicked. Both UI kinds receive this instance as their `service`
// property (shell.qml hands it over in the panel loader and the bar widget
// looks it up), so there is exactly one copy of the state.
Item {
  id: root

  // Injected by shell.qml when the service is instantiated.
  property var shell: null
  property var manifest: null

  // Set by Panel.qml while the bar widget exists, null the rest of the time.
  // The panel is optional; the service is not.
  property var panel: null

  // The last command line handed to a browser, for `status` to report.
  property var lastLaunch: null

  // Why the last launch did not happen. A pick that fails has to be able to say
  // so: dismissing the picker either way makes a broken launch look exactly
  // like a successful one, which is the worst thing this plugin can do.
  property string lastError: ""

  readonly property string pluginId: (manifest && manifest.id) || "io.github.guilhermeyo.mclovin"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy-mclovin"
  readonly property string configPath: configDir + "/config.json"
  readonly property string cacheDir: home + "/.cache/omarchy-mclovin"
  readonly property string statsPath: cacheDir + "/stats.json"
  readonly property string applicationsDir: home + "/.local/share/applications"
  readonly property string desktopId: pluginId + ".desktop"
  readonly property string desktopPath: applicationsDir + "/" + desktopId

  // Absolute path to the shim the .desktop file points at. Resolved from this
  // QML file's own location so it keeps working wherever the plugin is
  // installed — the git checkout, a clone, or a hand-made directory.
  readonly property string handlerScript: Qt.resolvedUrl("mclovin-open").toString().replace("file://", "")
  readonly property string iconPath: Qt.resolvedUrl("mclovin.svg").toString().replace("file://", "")

  // ------------------------------------------------------------------ state

  property var config: Router.normalizeConfig(null)
  property var stats: Router.emptyStats(today())
  property bool configLoaded: false

  // "" until the first query lands. Distinguishing unknown from "not us" keeps
  // the bar widget from flashing an alarm colour during shell startup.
  property string currentHandler: ""
  readonly property bool isDefault: currentHandler === desktopId
  readonly property bool handlerKnown: currentHandler !== ""

  readonly property var rules: config.rules || []
  readonly property string fallbackBrowser: config.fallback || ""

  // Every installed web browser, minus ourselves. Recomputed whenever the
  // desktop entry index changes, so a browser installed mid-session shows up
  // without a shell restart.
  property var browsers: []

  function today() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }

  function refreshBrowsers() {
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var out = []
    for (var i = 0; i < values.length; i++) {
      if (Browsers.isBrowserEntry(values[i], root.desktopId)) out.push(values[i])
    }
    root.browsers = Browsers.sortBrowsers(out)
  }

  function browserById(id) {
    var wanted = String(id || "")
    if (!wanted) return null
    for (var i = 0; i < root.browsers.length; i++) {
      var e = root.browsers[i]
      if (String(e.id) === wanted) return e
      // Rules written by hand may omit the .desktop suffix.
      if (String(e.id) === wanted.replace(/\.desktop$/, "")) return e
      if (String(e.id) + ".desktop" === wanted) return e
    }
    return null
  }

  function browserName(id) {
    var entry = browserById(id)
    return entry ? String(entry.name) : String(id || "")
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshBrowsers() }
  }

  // -------------------------------------------------------------- profiles

  // Chromium-family profile directories, keyed by desktop entry id. Read from
  // each browser's Local State so a rule can name a profile the way the user
  // sees it in the profile switcher rather than as "Profile 3".
  property var profilesByBrowser: ({})

  // Chromium keeps profiles in ~/.config/<vendor>/Local State as JSON; Gecko
  // keeps them in ~/.mozilla/<vendor>/profiles.ini. Both are watched so a
  // profile created mid-session shows up in the picker.
  readonly property var profileSources: {
    var out = []
    for (var i = 0; i < root.browsers.length; i++) {
      var id = String(root.browsers[i].id)
      var rels, j
      if (Browsers.isChromiumFamily(id)) {
        rels = Browsers.localStateCandidates(id)
        for (j = 0; j < rels.length; j++)
          out.push({ browser: id, kind: "chromium", path: root.home + "/.config/" + rels[j] })
      } else if (Browsers.isFirefoxFamily(id)) {
        rels = Browsers.firefoxProfilesPaths(id)
        for (j = 0; j < rels.length; j++)
          out.push({ browser: id, kind: "firefox", path: root.home + "/" + rels[j] })
      }
    }
    return out
  }

  // What the picker lists: one row per browser, or one row per profile when a
  // browser has them.
  readonly property var pickerEntries: Browsers.pickerEntries(root.browsers, root.profilesByBrowser)

  // Candidates are tried in order and the first one holding profiles wins, so a
  // later empty or missing file must not clear what an earlier one found. The
  // exception is `authoritative`, used by the Firefox SQLite reader: it is the
  // real source on Firefox 143+ and must be allowed to replace whatever the
  // legacy INI produced.
  property var authoritativeProfiles: ({})

  function setProfiles(browserId, entries, authoritative) {
    if (!entries || entries.length === 0) return
    var key = String(browserId)
    if (!authoritative) {
      if (root.authoritativeProfiles[key]) return
      var existing = root.profilesByBrowser[key]
      if (existing && existing.length > 0) return
    } else {
      var flags = ({})
      for (var f in root.authoritativeProfiles) flags[f] = root.authoritativeProfiles[f]
      flags[key] = true
      root.authoritativeProfiles = flags
    }

    var next = ({})
    for (var k in root.profilesByBrowser) next[k] = root.profilesByBrowser[k]
    next[key] = entries
    root.profilesByBrowser = next
  }

  function profilesFor(browserId) { return root.profilesByBrowser[String(browserId)] || [] }

  Instantiator {
    model: root.profileSources

    delegate: QtObject {
      required property var modelData

      property FileView view: FileView {
        path: modelData.path
        watchChanges: true
        printErrors: false
        onLoaded: root.setProfiles(modelData.browser, modelData.kind === "firefox"
          ? Browsers.parseFirefoxProfiles(text())
          : Browsers.parseProfileEntries(text()))
        onFileChanged: reload()
      }
    }
  }

  // Firefox 143+ moved user-created profiles into a SQLite store, and QML
  // cannot read SQLite. Shelling out to sqlite3 is the whole dependency, it is
  // read-only, and it runs at startup and on refresh — not on the hot path. If
  // sqlite3 is missing the command produces nothing and the INI reader above
  // stands, which costs the Firefox profile rows and nothing else.
  readonly property var firefoxBrowsers: {
    var out = []
    for (var i = 0; i < root.browsers.length; i++) {
      var id = String(root.browsers[i].id)
      if (Browsers.isFirefoxFamily(id)) out.push(id)
    }
    return out
  }

  function reloadFirefoxProfiles() {
    for (var i = 0; i < firefoxGroupReaders.count; i++) {
      var obj = firefoxGroupReaders.objectAt(i)
      if (obj && obj.reader) obj.reader.running = true
    }
  }

  Instantiator {
    id: firefoxGroupReaders
    model: root.firefoxBrowsers

    delegate: QtObject {
      required property var modelData

      readonly property var baseDirs: {
        var rels = Browsers.firefoxBaseDirs(modelData)
        var out = []
        for (var i = 0; i < rels.length; i++) out.push(root.home + "/" + rels[i])
        return out
      }

      property Process reader: Process {
        running: true
        command: [
          "sh", "-c",
          'command -v sqlite3 >/dev/null 2>&1 || exit 0\n'
          + 'for base in "$@"; do\n'
          + '  dir="$base/Profile Groups"\n'
          + '  [ -d "$dir" ] || continue\n'
          + '  for db in "$dir"/*.sqlite; do\n'
          + '    [ -f "$db" ] || continue\n'
          + '    sqlite3 -readonly -list -separator "|" "$db" "select path, name from Profiles;" 2>/dev/null |\n'
          + '      while IFS= read -r line; do printf "%s\\t%s\\n" "$base" "$line"; done\n'
          + '  done\n'
          + 'done\n',
          "sh"
        ].concat(baseDirs)

        stdout: StdioCollector {
          onStreamFinished: root.setProfiles(modelData, Browsers.parseFirefoxGroups(text), true)
        }
      }
    }
  }

  // -------------------------------------------------------------- routing

  // The single entry point for an incoming link. Returns a short status string
  // because IPC callers (and the shim's fallback path) need to know whether the
  // shell actually took the URL.
  function route(url, wantPrivate) {
    var target = String(url || "").trim()

    // No link is a real request, not a mistake: `omarchy-launch-browser` and
    // any keybind like it invoke the default browser with no arguments, and
    // the answer to "open a browser" is the picker.
    if (!target) return ask("", wantPrivate === true) ? "asked" : "failed"

    var parsed = Router.parseUrl(target)
    var rule = Router.firstMatch(root.rules, parsed)

    if (rule) {
      if (launch(rule, target)) {
        record(targetName(rule), Router.ruleLabel(rule), target)
        return "routed"
      }
      // The rule names a browser that is no longer installed. Asking beats
      // silently swallowing the click.
    } else if (root.fallbackBrowser && !wantPrivate) {
      var fallback = { browser: root.fallbackBrowser, profile: root.config.fallbackProfile || "" }
      if (launch(fallback, target)) {
        record(targetName(fallback), "", target)
        return "routed"
      }
    }

    return ask(target, wantPrivate === true) ? "asked" : "failed"
  }

  // Opens the picker overlay with the URL in flight. The overlay is a separate
  // kind on this same plugin, so summoning by our own id reaches it.
  function ask(url, wantPrivate) {
    if (!root.shell || typeof root.shell.summon !== "function") return false
    return root.shell.summon(root.pluginId, JSON.stringify({
      url: String(url || ""),
      private: wantPrivate === true
    })) === true
  }

  // Called by the picker once the user has chosen. Kept here rather than in the
  // overlay so the launch/record/remember sequence has one implementation.
  // `remember` is null, or {when, term} straight off the picker's chips — the
  // picker decides what the rule should match, this only writes it.
  function choose(browserId, url, profile, wantPrivate, remember) {
    var target = {
      browser: browserId,
      profile: String(profile || ""),
      private: wantPrivate === true
    }
    if (!launch(target, url)) return false

    var term = remember ? String(remember.term || "").trim() : ""
    if (term) {
      setConfig(Router.upsertRule(root.config, remember.when, term, browserId,
                                  target.profile, target.private))
      record(targetName(target), term, url)
    } else {
      record(targetName(target), "", url)
    }
    return true
  }

  // A target is a rule-shaped object: {command}, or {browser, profile, private}.
  function launch(target, url) {
    root.lastError = ""
    if (!target) return false

    if (target.command) {
      var cmdArgv = Browsers.expandCommand(target.command, url)
      if (!cmdArgv.length) {
        root.lastError = "The command “" + target.command + "” is empty"
        return false
      }
      root.lastLaunch = { command: target.command, argv: cmdArgv }
      Quickshell.execDetached(cmdArgv)
      return true
    }

    var entry = browserById(target.browser)
    if (!entry) {
      root.lastError = "No installed browser matches “" + target.browser + "”"
      return false
    }

    var dir = target.profile
      ? Browsers.resolveProfileDirectory(profilesFor(entry.id), target.profile)
      : ""
    var argv = Browsers.launchArgs(entry.id, entry.execString, url, dir, target.private === true)
    if (!argv.length) {
      root.lastError = entry.name + " has no usable Exec line in its desktop entry"
      return false
    }

    // Kept as state rather than a log line: when a link lands in the wrong
    // browser the only question that matters is what was actually run, and
    // `status` is where someone already looks.
    // A pick with no link means "take me to that browser". If that profile
    // already has a window, going there is the answer; a second window is not.
    // A private pick always opens: the point of it is a fresh private window.
    if (!String(url || "") && target.private !== true) {
      var existing = Browsers.findProfileToplevel(
        ToplevelManager.toplevels.values, entry.id, target.profile,
        profilesFor(entry.id).length)

      if (existing) {
        root.lastLaunch = { browser: entry.id, profile: target.profile, directory: dir,
                            private: false, focused: String(existing.title || "") }
        focusDelay.toplevel = existing
        focusDelay.fallbackArgv = argv
        focusDelay.restart()
        return true
      }
    }

    root.lastLaunch = { browser: entry.id, profile: target.profile,
                        directory: dir, private: target.private === true, argv: argv }
    Quickshell.execDetached(argv)
    return true
  }

  // Deliberately late: the overlay is a layer surface holding exclusive
  // keyboard focus and is dismissed on the same tick this decision is made.
  // Raising the browser before that surface is gone gets undone when the
  // compositor hands focus back to whatever was underneath.
  //
  // Last pick wins if two land inside the window, which is what picking twice
  // means. A window closed in the meantime is gone from QML by then, and
  // launching beats raising nothing.
  Timer {
    id: focusDelay
    property var toplevel: null
    property var fallbackArgv: []
    interval: 220
    onTriggered: {
      if (toplevel) toplevel.activate()
      else if (fallbackArgv.length) Quickshell.execDetached(fallbackArgv)
      toplevel = null
    }
  }

  function supportsPrivate(browserId) {
    var entry = browserById(browserId)
    return entry ? Browsers.supportsPrivate(entry.id) : false
  }

  // What the stats and the rule list show for a target: the browser's display
  // name, the pinned profile, and whether it opens private — all on one line,
  // so the rule rows keep their two-line shape.
  function targetName(target) {
    if (!target) return ""
    if (target.command) return String(target.command).split(" ")[0]
    var name = browserName(target.browser)
    if (target.profile) name += " · " + target.profile
    if (target.private) name += " · private"
    return name
  }

  function record(name, ruleLabel, url) {
    var next = Router.recordRoute(root.stats, today(), name, ruleLabel, url,
                                  Qt.formatDateTime(new Date(), "yyyy-MM-ddTHH:mm:ss"))
    root.stats = next
    statsFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  // ---------------------------------------------------------------- rules

  function setConfig(next) {
    root.config = Router.normalizeConfig(next)
    configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  function removeRule(index) { setConfig(Router.removeRuleAt(root.config, index)) }

  // The form's one write. A negative index means "new"; anything else replaces
  // in place so editing a rule cannot change where it sits in the order.
  function saveRule(index, rule) {
    setConfig(index < 0 ? Router.appendRule(root.config, rule)
                        : Router.setRuleAt(root.config, index, rule))
  }

  // The bar widget is optional, so every panel call has to survive its absence.
  function drivePanel(action) {
    if (!root.panel || typeof root.panel[action] !== "function") return "no bar widget"
    root.panel[action]()
    return "ok"
  }

  // Summoning our own plugin id reaches the overlay, which switches screens on
  // the payload's `mode`.
  function openEditor(index, url) {
    if (!root.shell || typeof root.shell.summon !== "function") return false
    return root.shell.summon(root.pluginId, JSON.stringify({
      mode: "editor",
      ruleIndex: index === undefined ? -1 : index,
      url: String(url || "")
    })) === true
  }
  // ------------------------------------------------- import from the CLI

  // The mclovin CLI keeps its rules in TOML at a fixed path. Reading it is a
  // one-shot import, not a live binding: after importing, this plugin owns its
  // own config and the CLI can be uninstalled without anything breaking.
  readonly property string mclovinTomlPath: home + "/.config/mclovin/rules.toml"
  property var importable: ({ rules: [], fallback: "", skipped: 0 })

  // Only what is not already here, so the offer disappears once taken instead
  // of sitting in the panel forever inviting a no-op.
  readonly property int importableCount: Import.countNewRules(root.config, root.importable, root.browsers)

  function importFromMclovin() {
    var pending = root.importableCount
    if (pending === 0) return 0
    setConfig(Import.mergeImported(root.config, root.importable, root.browsers))
    return pending
  }

  FileView {
    path: root.mclovinTomlPath
    watchChanges: true
    printErrors: false
    onLoaded: root.importable = Import.parseMclovinToml(text())
    onFileChanged: reload()
    onLoadFailed: root.importable = ({ rules: [], fallback: "", skipped: 0 })
  }

  // ------------------------------------------------- default handler wiring

  // Writing the .desktop and flipping xdg-mime is the one thing this plugin
  // cannot do from QML alone: XDG requires an executable on disk to be the
  // registered handler. The shim next to this file is that executable, and all
  // it does is forward the URL back here over IPC.
  function desktopFileContents() {
    return "[Desktop Entry]\n"
      + "Type=Application\n"
      + "Name=mclovin\n"
      + "GenericName=Web Browser Picker\n"
      + "Comment=Choose which browser opens this link\n"
      + "Exec=" + root.handlerScript + " %u\n"
      + "Icon=" + root.iconPath + "\n"
      + "Terminal=false\n"
      + "NoDisplay=true\n"
      + "StartupNotify=false\n"
      // Deliberately not WebBrowser: that is the category the picker filters on,
      // and listing ourselves there would offer mclovin as a target for mclovin.
      + "Categories=Network;\n"
      + "MimeType=x-scheme-handler/http;x-scheme-handler/https;\n"
  }

  function becomeDefault() {
    desktopFile.setText(desktopFileContents())
    registerHandler.running = true
  }

  function restoreDefault(browserId) {
    var entry = browserById(browserId)
    if (!entry) return false
    restoreHandler.desktopId = String(entry.id).replace(/\.desktop$/, "") + ".desktop"
    restoreHandler.running = true
    return true
  }

  function refreshHandler() { if (!queryHandler.running) queryHandler.running = true }

  Process {
    id: ensureDirs
    running: true
    command: ["mkdir", "-p", root.configDir, root.cacheDir, root.applicationsDir]
    onExited: {
      configFile.reload()
      statsFile.reload()
      root.refreshHandler()
    }
  }

  Process {
    id: queryHandler
    command: ["xdg-mime", "query", "default", "x-scheme-handler/https"]
    stdout: StdioCollector {
      onStreamFinished: root.currentHandler = String(text).trim()
    }
  }

  Process {
    id: registerHandler
    command: ["sh", "-c",
      "update-desktop-database " + Util.shellQuote(root.applicationsDir) + " 2>/dev/null; "
      + "xdg-mime default " + Util.shellQuote(root.desktopId) + " x-scheme-handler/http x-scheme-handler/https"]
    onExited: root.refreshHandler()
  }

  Process {
    id: restoreHandler
    property string desktopId: ""
    command: ["xdg-mime", "default", desktopId, "x-scheme-handler/http", "x-scheme-handler/https"]
    onExited: root.refreshHandler()
  }

  // ------------------------------------------------------------------- disk

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.config = Router.normalizeConfig(text())
      root.configLoaded = true
    }
    onFileChanged: reload()
    onLoadFailed: {
      // No config yet is the normal first-run state, not an error.
      root.config = Router.normalizeConfig(null)
      root.configLoaded = true
    }
  }

  FileView {
    id: statsFile
    path: root.statsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.stats = Router.normalizeStats(text(), root.today())
    onFileChanged: reload()
    onLoadFailed: root.stats = Router.emptyStats(root.today())
  }

  FileView {
    id: desktopFile
    path: root.desktopPath
    atomicWrites: true
    printErrors: false
  }

  // --------------------------------------------------------------------- IPC

  // One target, named after the plugin id, which is what every first-party
  // panel and every plugin in the marketplace does. It lives on the service
  // rather than on Panel.qml — the usual home — because the XDG handler has to
  // answer even when the bar widget is not on the bar.
  //
  // The house convention also puts open/close/show/hide/toggle here for the
  // panel. `open` is taken: on this plugin it means "open this link", takes a
  // URL, and is the one call the desktop entry depends on. The panel gets the
  // suffixed names instead, and no-ops when the widget is absent.
  IpcHandler {
    target: root.pluginId

    function open(url: string): string {
      return root.route(url, false)
    }

    // What a browser's own --private/--incognito flag means when the handler
    // standing in for it is asked to open something.
    function openPrivate(url: string): string {
      return root.route(url, true)
    }

    function togglePanel(): string { return root.drivePanel("toggle") }
    function showPanel(): string { return root.drivePanel("open") }
    function hidePanel(): string { return root.drivePanel("close") }

    // Everything needed to work out why links are not arriving, in one call.
    function status(): string {
      return JSON.stringify({
        isDefault: root.isDefault,
        handler: root.currentHandler,
        desktopId: root.desktopId,
        script: root.handlerScript,
        browsers: root.browsers.length,
        rules: root.rules.length,
        fallback: root.fallbackBrowser,
        today: root.stats.count,
        importable: root.importableCount,
        lastLaunch: root.lastLaunch,
        lastError: root.lastError,
        profiles: (function() {
          var out = {}
          for (var k in root.profilesByBrowser) out[k] = root.profilesByBrowser[k].length
          return out
        })()
      })
    }

    function refresh(): string {
      root.refreshBrowsers()
      root.refreshHandler()
      root.reloadFirefoxProfiles()
      return "ok"
    }

    function importRules(): string {
      return String(root.importFromMclovin())
    }

    // The same two actions the drop-down offers, scriptable — worth having when
    // the thing you are trying to fix is the desktop not opening links.
    function becomeDefault(): string {
      root.becomeDefault()
      return "ok"
    }

    function restoreDefault(browserId: string): string {
      return root.restoreDefault(browserId) ? "ok" : "unknown browser"
    }
  }

  Component.onCompleted: refreshBrowsers()
}
