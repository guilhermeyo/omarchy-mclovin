import QtQuick
import Quickshell
import Quickshell.Io
import "Router.js" as Router

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
      if (Router.isBrowserEntry(values[i], root.desktopId)) out.push(values[i])
    }
    root.browsers = Router.sortBrowsers(out)
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
      if (Router.isChromiumFamily(id)) {
        rels = Router.localStateCandidates(id)
        for (j = 0; j < rels.length; j++)
          out.push({ browser: id, kind: "chromium", path: root.home + "/.config/" + rels[j] })
      } else if (Router.isFirefoxFamily(id)) {
        rels = Router.firefoxProfilesPaths(id)
        for (j = 0; j < rels.length; j++)
          out.push({ browser: id, kind: "firefox", path: root.home + "/" + rels[j] })
      }
    }
    return out
  }

  // What the picker lists: one row per browser, or one row per profile when a
  // browser has them.
  readonly property var pickerEntries: Router.pickerEntries(root.browsers, root.profilesByBrowser)

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
          ? Router.parseFirefoxProfiles(text())
          : Router.parseProfileEntries(text()))
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
      if (Router.isFirefoxFamily(id)) out.push(id)
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
        var rels = Router.firefoxBaseDirs(modelData)
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
          onStreamFinished: root.setProfiles(modelData, Router.parseFirefoxGroups(text), true)
        }
      }
    }
  }

  // -------------------------------------------------------------- routing

  // The single entry point for an incoming link. Returns a short status string
  // because IPC callers (and the shim's fallback path) need to know whether the
  // shell actually took the URL.
  function route(url) {
    var target = String(url || "").trim()
    if (!target) return "empty"

    var parsed = Router.parseUrl(target)
    var rule = Router.firstMatch(root.rules, parsed)

    if (rule) {
      if (launch(rule, target)) {
        record(targetName(rule), Router.ruleLabel(rule), target)
        return "routed"
      }
      // The rule names a browser that is no longer installed. Asking beats
      // silently swallowing the click.
    } else if (root.fallbackBrowser) {
      var fallback = { browser: root.fallbackBrowser, profile: root.config.fallbackProfile || "" }
      if (launch(fallback, target)) {
        record(targetName(fallback), "", target)
        return "routed"
      }
    }

    return ask(target) ? "asked" : "failed"
  }

  // Opens the picker overlay with the URL in flight. The overlay is a separate
  // kind on this same plugin, so summoning by our own id reaches it.
  function ask(url) {
    if (!root.shell || typeof root.shell.summon !== "function") return false
    return root.shell.summon(root.pluginId, JSON.stringify({ url: String(url || "") })) === true
  }

  // Called by the picker once the user has chosen. Kept here rather than in the
  // overlay so the launch/record/remember sequence has one implementation.
  function choose(browserId, url, rememberPattern, profile) {
    var target = { browser: browserId, profile: String(profile || "") }
    if (!launch(target, url)) return false
    if (rememberPattern) {
      setConfig(Router.upsertRule(root.config, rememberPattern, browserId, target.profile))
      record(targetName(target), rememberPattern, url)
    } else {
      record(targetName(target), "", url)
    }
    return true
  }

  // A target is a rule-shaped object: either {command} or {browser, profile}.
  function launch(target, url) {
    if (!target) return false

    if (target.command) {
      var cmdArgv = Router.expandCommand(target.command, url)
      if (!cmdArgv.length) return false
      Quickshell.execDetached(cmdArgv)
      return true
    }

    var entry = browserById(target.browser)
    if (!entry) return false
    var argv = Router.expandExec(entry.execString, url)
    if (!argv.length) return false

    if (target.profile) {
      var dir = Router.resolveProfileDirectory(profilesFor(entry.id), target.profile)
      argv = Router.applyProfile(argv, entry.id, dir)
    }

    Quickshell.execDetached(argv)
    return true
  }

  // What the stats show for a target: the browser's display name, with the
  // profile when one is pinned, or the bare command for a command rule.
  function targetName(target) {
    if (!target) return ""
    if (target.command) return String(target.command).split(" ")[0]
    var name = browserName(target.browser)
    return target.profile ? name + " · " + target.profile : name
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

  function addRule(match, browserId, profile) {
    setConfig(Router.upsertRule(root.config, match, browserId, profile))
  }
  function removeRule(index) { setConfig(Router.removeRuleAt(root.config, index)) }

  // The form's one write. A negative index means "new"; anything else replaces
  // in place so editing a rule cannot change where it sits in the order.
  function saveRule(index, rule) {
    setConfig(index < 0 ? Router.appendRule(root.config, rule)
                        : Router.setRuleAt(root.config, index, rule))
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
  function setFallback(browserId) {
    var next = Router.normalizeConfig(root.config)
    next.fallback = String(browserId || "")
    setConfig(next)
  }

  // ------------------------------------------------- import from the CLI

  // The mclovin CLI keeps its rules in TOML at a fixed path. Reading it is a
  // one-shot import, not a live binding: after importing, this plugin owns its
  // own config and the CLI can be uninstalled without anything breaking.
  readonly property string mclovinTomlPath: home + "/.config/mclovin/rules.toml"
  property var importable: ({ rules: [], fallback: "", skipped: 0 })

  // Only what is not already here, so the offer disappears once taken instead
  // of sitting in the panel forever inviting a no-op.
  readonly property int importableCount: Router.countNewRules(root.config, root.importable, root.browsers)

  function importFromMclovin() {
    var pending = root.importableCount
    if (pending === 0) return 0
    setConfig(Router.mergeImported(root.config, root.importable, root.browsers))
    return pending
  }

  FileView {
    path: root.mclovinTomlPath
    watchChanges: true
    printErrors: false
    onLoaded: root.importable = Router.parseMclovinToml(text())
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
      "update-desktop-database " + shq(root.applicationsDir) + " 2>/dev/null; "
      + "xdg-mime default " + shq(root.desktopId) + " x-scheme-handler/http x-scheme-handler/https"]
    onExited: root.refreshHandler()
  }

  Process {
    id: restoreHandler
    property string desktopId: ""
    command: ["xdg-mime", "default", desktopId, "x-scheme-handler/http", "x-scheme-handler/https"]
    onExited: root.refreshHandler()
  }

  // Single-quote for `sh -c`. Paths under $HOME rarely need it, but a username
  // with a space would otherwise silently register a broken handler.
  function shq(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'" }

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

  // Roll the daily counters over without waiting for the next click, so a bar
  // widget left open past midnight does not keep showing yesterday's total.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: if (root.stats.date !== root.today()) root.stats = Router.emptyStats(root.today())
  }

  // --------------------------------------------------------------------- IPC

  // `omarchy-shell mclovin open <url>` — what the .desktop shim calls. Short
  // target name on purpose: it ends up in a shell script that users read.
  IpcHandler {
    target: "mclovin"

    function open(url: string): string {
      return root.route(url)
    }

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
