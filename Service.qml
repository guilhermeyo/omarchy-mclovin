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
  readonly property string companionManager: Qt.resolvedUrl("browser-companion/native/manage").toString().replace("file://", "")
  readonly property string companionExtensionPath: Qt.resolvedUrl("browser-companion/extension").toString().replace("file://", "")

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
  // Whether any rule sends links somewhere the browser cannot reach on its own.
  //
  // This is the same set the native host serves to the extension --
  // INTERCEPTABLE = ("webapp", "action", "command") in mclovin-native-host -- and
  // the two must agree. It used to ask only for a Zoom action, from when Zoom was
  // the only thing the companion could open; a rule sending WhatsApp links to its
  // web app made the companion work while the panel went on hiding it.
  readonly property bool hasCompanionRule: {
    for (var i = 0; i < root.rules.length; i++) {
      var rule = root.rules[i]
      if (!rule) continue
      if (rule.webapp || rule.action || rule.command) return true
    }
    return false
  }

  // The extension is optional and runs outside omarchy-shell. Its management
  // command reports whether a native manifest is registered and whether the
  // extension has ever completed its local handshake. No page or link history
  // crosses this boundary; the status file contains only id, version and time.
  property var browserCompanion: ({
    extensionId: "",
    extensionPath: companionExtensionPath,
    registeredBrowsers: [],
    invalidBrowsers: [],
    connected: false,
    extensionVersion: "",
    lastSeen: "",
    storeUrl: ""
  })
  property string browserCompanionError: ""
  readonly property bool browserCompanionRegistered:
    browserCompanion.registeredBrowsers && browserCompanion.registeredBrowsers.length > 0

  // Somewhere for `manage install` to put the bridge. A Chromium-family profile
  // under ~/.config is what it looks for, and on a Firefox-only desktop there is
  // none -- so the panel offered a button whose only outcome was an error.
  readonly property bool browserCompanionInstallable: {
    var list = (root.browserCompanion && root.browserCompanion.installableBrowsers) || []
    return list.length > 0
  }
  readonly property bool browserCompanionConnected: browserCompanion.connected === true

  // Every installed web browser, minus ourselves. Recomputed whenever the
  // desktop entry index changes, so a browser installed mid-session shows up
  // without a shell restart.
  property var browsers: []

  function today() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }

  function acceptBrowserCompanionStatus(raw) {
    var value = String(raw || "").trim()
    if (!value) return
    try {
      var parsed = JSON.parse(value)
      if (!parsed || typeof parsed !== "object") throw new Error("status is not an object")
      root.browserCompanion = parsed
      root.browserCompanionError = ""
    } catch (error) {
      root.browserCompanionError = "Could not read browser companion status."
    }
  }

  function refreshBrowserCompanion() {
    if (!companionStatus.running) companionStatus.running = true
  }

  function setupBrowserCompanion() {
    root.browserCompanionError = ""
    if (!companionSetup.running) companionSetup.running = true
  }

  function openBrowserCompanionSetup() {
    root.browserCompanionError = ""
    if (!companionOpen.running) companionOpen.running = true
  }

  function refreshBrowsers() {
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var out = []
    for (var i = 0; i < values.length; i++) {
      if (Browsers.isBrowserEntry(values[i], root.desktopId)) out.push(values[i])
    }
    root.browsers = Browsers.sortBrowsers(out)
  }

  // Omarchy's web apps: chromeless `--app=` windows pinned to one site. Kept
  // apart from `browsers` because a web app is not somewhere to send any link,
  // only a link to the site it owns.
  property var webapps: []

  function refreshWebapps() {
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var out = []
    for (var i = 0; i < values.length; i++) {
      var app = Browsers.webappEntry(values[i])
      if (!app) continue
      app.host = Router.parseUrl(app.url).domain
      if (app.host) out.push(app)
    }
    root.webapps = Browsers.sortBrowsers(out)
  }

  // Applications claiming a URI scheme, by absolute path, read off disk.
  //
  // DesktopEntries cannot answer this: it indexes by desktop id, and two files
  // can share one. Both Zoom.desktop entries on an Omarchy with the Zoom web
  // app installed claim zoommtg://, and the plugin was handed one of them with
  // no indication the other existed.
  property var schemeHandlers: ({})
  property string pendingHandlerScheme: ""

  function handlersFor(scheme) { return root.schemeHandlers[String(scheme || "")] || [] }

  function chosenHandler(scheme) {
    var key = String(scheme || "")
    var stored = (root.config.handlers || {})[key] || ""
    if (!stored) return ""
    // A stored choice that no longer exists is worse than none: it would send
    // the link to a file that is gone. Fall back to asking again.
    var list = handlersFor(key)
    for (var i = 0; i < list.length; i++) if (list[i].path === stored) return stored
    return ""
  }

  function rememberHandler(scheme, path) {
    var next = Router.normalizeConfig(root.config)
    var handlers = ({})
    for (var k in (next.handlers || {})) handlers[k] = next.handlers[k]
    handlers[String(scheme || "")] = String(path || "")
    next.handlers = handlers
    setConfig(next)
  }

  // Every scheme the native-app table names, so a rule can ask about any of
  // them without a round trip at click time.
  function scanNativeHandlers() {
    var apps = Router.nativeApps()
    for (var i = 0; i < apps.length; i++) scanHandlers(apps[i].scheme)
  }

  function scanHandlers(scheme) {
    if (!scheme || handlerScan.running) return
    root.pendingHandlerScheme = String(scheme)
    handlerScan.scheme = String(scheme)
    handlerScan.running = true
  }

  // One `grep` over the four directories a launcher searches, printing
  // path, Name and Exec. Shelling out for the same reason the Firefox profile
  // reader does: this is not a hot path, and QML has no directory listing.
  Process {
    id: handlerScan
    property string scheme: ""
    running: false
    command: ["sh", "-c",
      'scheme=$1\n'
      + 'for dir in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" \\\n'
      + '           /usr/local/share/applications /usr/share/applications \\\n'
      + '           /var/lib/flatpak/exports/share/applications; do\n'
      + '  [ -d "$dir" ] || continue\n'
      + '  for f in "$dir"/*.desktop; do\n'
      + '    [ -f "$f" ] || continue\n'
      + '    grep -q "^MimeType=.*x-scheme-handler/$scheme;" "$f" || continue\n'
      + '    name=$(sed -n "s/^Name=//p" "$f" | head -n1)\n'
      + '    exec_line=$(sed -n "s/^Exec=//p" "$f" | head -n1)\n'
      + '    printf "%s\\t%s\\t%s\\n" "$f" "$name" "$exec_line"\n'
      + '  done\n'
      + 'done\n',
      "sh", scheme]

    stdout: StdioCollector {
      id: handlerOut
      waitForEnd: true
      onStreamFinished: {
        var next = ({})
        for (var k in root.schemeHandlers) next[k] = root.schemeHandlers[k]
        next[handlerScan.scheme] = Browsers.parseHandlers(text)
        root.schemeHandlers = next
      }
    }
  }

  function webappById(id) {
    var wanted = String(id || "")
    if (!wanted) return null
    for (var i = 0; i < root.webapps.length; i++) {
      var app = root.webapps[i]
      if (String(app.id) === wanted) return app
      // Rules written by hand may carry the .desktop suffix, or omit it.
      if (String(app.id) === wanted.replace(/\.desktop$/, "")) return app
      if (String(app.id) + ".desktop" === wanted) return app
    }
    return null
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
    function onValuesChanged() { root.refreshBrowsers(); root.refreshWebapps() }
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

    // More than one application claims the scheme this rule hands its URL to,
    // and nobody has said which. Handing it to XDG picks the first by directory
    // precedence, silently and forever -- which is how a machine with Omarchy's
    // Zoom web app installed sends every meeting link back to a browser while
    // the native client sits there.
    //
    // Asked here rather than inside launch(), because launch() answering true
    // for "a question was posed" would have route() record a link that has not
    // opened yet and answer "routed" to a caller that is still waiting.
    var nativeApp = (rule && Router.isNativeAction(rule.action)) ? Router.nativeAppFor(target) : null
    var scheme = nativeApp ? nativeApp.scheme : ""
    if (scheme && !chosenHandler(scheme) && handlersFor(scheme).length > 1) {
      root.lastError = ""
      return askHandler(scheme, target, rule) ? "asked" : "failed"
    }

    var reason = ""
    if (rule) {
      if (launch(rule, target)) {
        record(targetName(rule), Router.ruleLabel(rule), target)
        return "routed"
      }
      // The rule names a destination that is no longer installed. Asking beats
      // silently swallowing the click -- and the picker says why it appeared,
      // because lastError already knows and used to be thrown away here.
      reason = root.lastError
    } else if (root.fallbackBrowser && !wantPrivate) {
      var fallback = { browser: root.fallbackBrowser, profile: root.config.fallbackProfile || "" }
      if (launch(fallback, target)) {
        record(targetName(fallback), "", target)
        return "routed"
      }
      reason = root.lastError
    }

    return ask(target, wantPrivate === true, reason) ? "asked" : "failed"
  }

  // The picker, listing the applications that claim a scheme rather than the
  // installed browsers. Same overlay, same Always checkbox; what changes is what
  // the rows are and where the answer is written.
  function askHandler(scheme, url, rule) {
    if (!root.shell || typeof root.shell.summon !== "function") return false
    return root.shell.summon(root.pluginId, JSON.stringify({
      mode: "handler",
      scheme: String(scheme || ""),
      url: String(url || ""),
      action: String((rule && rule.action) || "")
    })) === true
  }

  // Called by the picker once an application has been chosen for a scheme.
  function chooseHandler(scheme, path, url, remember) {
    var app = Router.nativeAppFor(url)
    if (!app) return false
    if (remember) rememberHandler(scheme, path)
    var argv = [root.handlerScript, "--native=" + app.id, "--handler=" + String(path || ""),
                String(url || "")]
    root.lastLaunch = { action: Router.ACTION_NATIVE, app: app.id,
                        handler: String(path || ""), argv: argv }
    Quickshell.execDetached(argv)
    record("Its native app", "", url)
    return true
  }

  // Opens the picker overlay with the URL in flight. The overlay is a separate
  // kind on this same plugin, so summoning by our own id reaches it.
  function ask(url, wantPrivate, reason) {
    if (!root.shell || typeof root.shell.summon !== "function") return false
    return root.shell.summon(root.pluginId, JSON.stringify({
      url: String(url || ""),
      private: wantPrivate === true,
      // Why the picker opened, when it opened because a rule could not be
      // honoured. The picker shows it in place of the key hints, which is where
      // it already shows the same class of message after a failed pick.
      reason: String(reason || "")
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

  // A target is a rule-shaped object: {action}, {webapp}, {command}, or
  // {browser, profile, private}.
  function launch(target, url) {
    root.lastError = ""
    if (!target) return false

    if (Router.isNativeAction(target.action)) {
      var app = Router.nativeAppFor(url)
      if (!app) {
        // The rule says "its native app" and this link has none. Saying so beats
        // handing the browser a link the rule meant to keep out of it without a
        // word, and route() falls through to the fallback or the picker.
        root.lastError = "No native application is known for links like " + String(url || "")
        return false
      }
      var chosen = chosenHandler(app.scheme)
      var argv = [root.handlerScript, "--native=" + app.id]
      if (chosen) argv.push("--handler=" + chosen)
      argv.push(String(url || ""))
      root.lastLaunch = { action: Router.ACTION_NATIVE, app: app.id, handler: chosen, argv: argv }
      Quickshell.execDetached(argv)
      return true
    }

    if (target.webapp) {
      var app = webappById(target.webapp)
      if (!app) {
        root.lastError = "No web app matches “" + target.webapp + "”"
        return false
      }
      return launchWebapp(app, url)
    }

    if (target.command) {
      var cmdArgv = Browsers.expandCommand(target.command, url)
      if (!cmdArgv.length) {
        root.lastError = "The command “" + target.command + "” is empty"
        return false
      }
      root.lastLaunch = { command: target.command, argv: cmdArgv }

      // execDetached reports nothing back, so a command whose binary is not
      // installed was counted, written to stats as a route, and answered
      // "routed" to the shim -- which then exited 0 without reaching its own
      // fallback. The link was gone and every layer said it had worked.
      //
      // The launch goes through sh so the outcome can be acted on where it is
      // known: run the command if it exists, and if it does not, hand the link
      // back to mclovin-open with --fallback, which opens it in the fallback
      // browser and notifies if even that fails. The URL is a positional
      // argument throughout and never becomes shell source.
      Quickshell.execDetached(["sh", "-c",
        'helper=$1; link=$2; shift 2\n'
        + 'if command -v "$1" >/dev/null 2>&1; then exec "$@"; fi\n'
        + 'exec "$helper" --fallback "$link"\n',
        "sh", root.handlerScript, String(url || "")].concat(cmdArgv))
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

  // A web app target lands in the window already showing that site, or opens
  // one.
  //
  // Focusing is the point, not an optimisation. An `--app=` window is a browser
  // session, and a site that allows only one — WhatsApp Web is the one everybody
  // has — logs the open window out the moment a second claims it. So a link that
  // opens a second window does not merely duplicate the app, it breaks the app
  // that was already there.
  //
  // Matched on the site rather than the exact URL, because those two are never
  // the same: the app sits on web.whatsapp.com/ and the link that wants it is a
  // share URL on api.whatsapp.com/send. A `--app=` window cannot be navigated
  // from outside anyway, so the choice is that window or another one.
  function launchWebapp(app, url) {
    var existing = Browsers.findAppToplevel(ToplevelManager.toplevels.values,
                                            Browsers.siteKey(app.host))
    if (existing) {
      root.lastLaunch = { webapp: app.id, focused: String(existing.title || "") }
      focusDelay.toplevel = existing
      focusDelay.fallbackArgv = []
      focusDelay.restart()
      return true
    }

    var entry = browserById(root.config.webapp) || browserById(root.fallbackBrowser)
      || (root.browsers.length ? root.browsers[0] : null)
    if (!entry) {
      root.lastError = "No browser is installed to open “" + app.name + "”"
      return false
    }

    // --app= is a Chromium flag. Gecko has no equivalent, and handing it one
    // opens nothing at all rather than an ordinary window.
    if (!Browsers.isChromiumFamily(entry.id)) {
      root.lastError = entry.name + " has no --app window. Set “webapp” in "
        + "config.json to a Chromium-family browser."
      return false
    }

    // The link, not the app's own URL: a share link carries the chat it is
    // about in its query, and dropping it opens the app on nothing.
    var argv = Browsers.webappArgs(entry.id, entry.execString, String(url || app.url), "")
    if (!argv.length) {
      root.lastError = entry.name + " has no usable Exec line in its desktop entry"
      return false
    }

    root.lastLaunch = { webapp: app.id, browser: entry.id, argv: argv }
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
      if (toplevel) root.raiseToplevel(toplevel)
      else if (fallbackArgv.length) Quickshell.execDetached(fallbackArgv)
      toplevel = null
    }
  }

  // Raising someone else's window is the one thing the toplevel protocol turns
  // out not to answer on its own. `activate()` lands while the picker is up,
  // because the shell holds the keyboard at that moment, and does nothing at
  // all when a rule fires with no overlay on screen — measured on Hyprland
  // 0.56.2 with misc:focus_on_activate already true: the timer runs, the
  // handle is the right window, and the window stays exactly where it was.
  //
  // So the protocol is still asked first — synchronous, no dialect, and it is
  // what works in the picker — and the dispatcher follows for the case it did
  // not take. Focusing a window that activate() already focused is a no-op.
  function raiseToplevel(top) {
    if (!top) return
    top.activate()

    var cls = String(top.appId || "")
    if (!cls) return
    // A Hyprland window selector is a regex, so the class has to survive being
    // read as one: `brave-web.whatsapp.com__-Default` is full of dots.
    focusDispatch.selector = "class:^(" + cls.replace(/[\\^$.|?*+()\[\]{}]/g, "\\$&") + ")$"
    focusDispatch.running = true
  }

  // Hyprland's Lua config and its classic config take different dispatcher
  // dialects, and the wrong one is a parse error rather than a focus — which is
  // why 896d15c dropped hyprctl in the first place. Both are sent, Lua first,
  // the way omarchy-launch-or-focus sends them; the wrong dialect exits non-zero
  // without touching a window, so `||` picks the one this machine speaks.
  Process {
    id: focusDispatch
    property string selector: ""
    command: ["sh", "-c",
      "hyprctl dispatch "
      + Util.shellQuote("hl.dsp.focus({ window = \"" + selector.replace(/\\/g, "\\\\") + "\" })")
      + " >/dev/null 2>&1 || hyprctl dispatch focuswindow "
      + Util.shellQuote(selector) + " >/dev/null 2>&1"]
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
    if (Router.isNativeAction(target.action)) return "Its native app"
    if (target.command) return String(target.command).split(" ")[0]
    if (target.webapp) {
      var app = webappById(target.webapp)
      return (app ? app.name : String(target.webapp).replace(/\.desktop$/, "")) + " · web app"
    }
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
      // Here rather than in Component.onCompleted: this is the point the rest
      // of the startup already treats as "the environment is ready", and a
      // Process started before it does not run.
      root.scanNativeHandlers()
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

  Process {
    id: companionStatus
    command: [root.companionManager, "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.acceptBrowserCompanionStatus(text)
    }
    stderr: StdioCollector {
      onStreamFinished: if (String(text).trim())
        root.browserCompanionError = "Could not check the browser companion."
    }
  }

  // One contextual action does both safe local preparation steps: register the
  // native host and open Chromium's own extension/install screen. Chromium is
  // still the authority that shows and accepts the all-sites permission.
  Process {
    id: companionSetup
    command: [root.companionManager, "setup", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.acceptBrowserCompanionStatus(text)
    }
    stderr: StdioCollector {
      onStreamFinished: if (String(text).trim())
        root.browserCompanionError = "Could not prepare the browser companion."
    }
    onExited: root.refreshBrowserCompanion()
  }

  Process {
    id: companionOpen
    command: [root.companionManager, "open", "--json"]
    stderr: StdioCollector {
      onStreamFinished: if (String(text).trim())
        root.browserCompanionError = "Could not open Chromium extension setup."
    }
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
        webapps: root.webapps.length,
        // Both reported because this is what someone debugging "my Zoom link
        // went to a browser" needs: how many applications claim the scheme, and
        // which one was chosen.
        // What someone debugging "my link went to a browser" needs: for each
        // site with a native application, how many things claim its scheme and
        // which one was chosen.
        nativeApps: (function() {
          var out = {}
          var apps = Router.nativeApps()
          for (var i = 0; i < apps.length; i++) {
            out[apps[i].id] = { scheme: apps[i].scheme,
                                claimedBy: handlersFor(apps[i].scheme).length,
                                chosen: chosenHandler(apps[i].scheme) }
          }
          return out
        })(),
        hasCompanionRule: root.hasCompanionRule,
        rules: root.rules.length,
        fallback: root.fallbackBrowser,
        today: root.stats.count,
        importable: root.importableCount,
        lastLaunch: root.lastLaunch,
        lastError: root.lastError,
        browserCompanion: root.browserCompanion,
        profiles: (function() {
          var out = {}
          for (var k in root.profilesByBrowser) out[k] = root.profilesByBrowser[k].length
          return out
        })()
      })
    }

    function refresh(): string {
      root.refreshBrowsers()
      root.refreshWebapps()
      root.scanNativeHandlers()
      root.refreshHandler()
      root.reloadFirefoxProfiles()
      root.refreshBrowserCompanion()
      return "ok"
    }

    function setupBrowserCompanion(): string {
      root.setupBrowserCompanion()
      return "ok"
    }

    function refreshBrowserCompanion(): string {
      root.refreshBrowserCompanion()
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

  Component.onCompleted: {
    refreshBrowsers()
    refreshWebapps()
    refreshBrowserCompanion()
  }
}
