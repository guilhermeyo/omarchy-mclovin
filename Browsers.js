.pragma library

// Everything about the browsers on this machine: finding them, reading their
// profiles, and turning a desktop entry into an argv that opens a URL.
//
// Split out of Router.js because none of it has an opinion about routing — it
// answers "what can open a link and how", while Router answers "which one
// should". Nothing here imports anything.

// ------------------------------------------------------------ Exec= expansion

// Split an Exec= line the way the desktop entry spec asks: double quotes group,
// backslash escapes inside them. Good enough for the browser entries that ship
// on a Linux desktop, and it never throws on a malformed line.
function tokenizeExec(execString) {
  var out = []
  var current = ""
  var inQuotes = false
  var started = false
  var raw = String(execString || "")

  for (var i = 0; i < raw.length; i++) {
    var c = raw.charAt(i)
    if (inQuotes) {
      if (c === "\\" && i + 1 < raw.length) { current += raw.charAt(++i); continue }
      if (c === "\"") { inQuotes = false; continue }
      current += c
      continue
    }
    if (c === "\"") { inQuotes = true; started = true; continue }
    if (c === " " || c === "\t") {
      if (started) { out.push(current); current = ""; started = false }
      continue
    }
    current += c
    started = true
  }
  if (started) out.push(current)
  return out
}

// Field codes the spec defines. %u/%U take the URL; the rest are metadata the
// launcher is supposed to supply and are dropped, per the spec's instruction to
// remove unhandled codes rather than pass them through literally.
function expandExec(execString, url) {
  var tokens = tokenizeExec(execString)
  var out = []
  var target = String(url || "")
  var urlSeen = false

  for (var i = 0; i < tokens.length; i++) {
    var t = tokens[i]
    if (t === "%u" || t === "%U" || t === "%f" || t === "%F") {
      urlSeen = true
      if (target) out.push(target)
      continue
    }
    if (t === "%i" || t === "%c" || t === "%k" || t === "%d" || t === "%D"
        || t === "%n" || t === "%N" || t === "%v" || t === "%m") continue
    // A code glued to other text (Exec=foo --url=%u) still has to lose the code.
    if (t.indexOf("%") !== -1) {
      if (/%[uUfF]/.test(t)) urlSeen = true
      t = t.replace(/%[uUfF]/g, target).replace(/%[a-zA-Z]/g, "")
      if (!t) continue
    }
    out.push(t)
  }

  // A desktop entry with no placeholder at all still has to receive the link.
  // Matches parse_exec_field in the mclovin CLI, which appends it rather than
  // dropping it on the floor.
  if (!urlSeen && target) out.push(target)

  return out
}

// A rule's `command` is a shell-ish line like "brave {url}". Same tokenizer as
// Exec=, with {url} as the placeholder. An empty {url} (the picker launched
// with no link) collapses the token away instead of passing "" to the browser.
function expandCommand(command, url) {
  var tokens = tokenizeExec(command)
  var out = []
  var target = String(url || "")
  for (var i = 0; i < tokens.length; i++) {
    var t = tokens[i].replace(/\{url\}/g, target)
    if (t) out.push(t)
  }
  return out
}

// -------------------------------------------------------------------- profiles

// Where each Chromium-family browser keeps the Local State file that maps a
// profile's on-disk directory to its display name. Paths are relative to
// ~/.config. Desktop entry ids do not map to directory names by any rule
// ("com.google.Chrome" lives in google-chrome/), so this is a lookup table with
// a generic guess appended for forks nobody has heard of yet.
function localStateCandidates(browserId) {
  var id = String(browserId || "").toLowerCase()
  var out = []
  if (id.indexOf("brave") !== -1) out.push("BraveSoftware/Brave-Browser/Local State")
  if (id.indexOf("chromium") !== -1) out.push("chromium/Local State")
  if (id.indexOf("chrome") !== -1) {
    out.push("google-chrome/Local State")
    out.push("google-chrome-stable/Local State")
    out.push("google-chrome-beta/Local State")
    out.push("google-chrome-unstable/Local State")
  }
  if (id.indexOf("edge") !== -1) {
    out.push("microsoft-edge/Local State")
    out.push("microsoft-edge-stable/Local State")
  }
  if (id.indexOf("vivaldi") !== -1) out.push("vivaldi/Local State")
  if (out.length === 0) out.push(id + "/Local State")
  return out
}

function isChromiumFamily(browserId) {
  var id = String(browserId || "").toLowerCase()
  return id.indexOf("brave") !== -1 || id.indexOf("chrom") !== -1
    || id.indexOf("edge") !== -1 || id.indexOf("vivaldi") !== -1
}

function isFirefoxFamily(browserId) {
  var id = String(browserId || "").toLowerCase()
  return id.indexOf("firefox") !== -1 || id.indexOf("librewolf") !== -1
    || id.indexOf("floorp") !== -1 || id.indexOf("waterfox") !== -1
}

// Gecko browsers keep profiles in an INI, and `-P` takes the display name
// directly, so name and "directory" are the same string here. Paths are
// relative to $HOME; every candidate is watched and the first with profiles
// wins, because which one exists depends on how the browser was packaged.
function firefoxBaseDirs(browserId) {
  var id = String(browserId || "").toLowerCase()
  if (id.indexOf("librewolf") !== -1) return [".librewolf"]
  if (id.indexOf("floorp") !== -1) return [".floorp"]
  if (id.indexOf("waterfox") !== -1) return [".waterfox"]
  return [
    ".mozilla/firefox",
    ".config/mozilla/firefox",
    "snap/firefox/common/.mozilla/firefox",
    ".var/app/org.mozilla.firefox/.mozilla/firefox"
  ]
}

function firefoxProfilesPaths(browserId) {
  var bases = firefoxBaseDirs(browserId)
  var out = []
  for (var i = 0; i < bases.length; i++) out.push(bases[i] + "/profiles.ini")
  return out
}

// Firefox creates these itself on first run; they are not profiles anyone
// chose, and offering them as picker rows is noise.
var FIREFOX_AUTO_PROFILES = ["default", "default-release"]

function parseFirefoxProfiles(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  var seen = {}
  var inProfile = false

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.charAt(0) === ";" || line.charAt(0) === "#") continue

    if (line.charAt(0) === "[") {
      // [General] and [InstallXXXX] carry defaults and install mappings, not
      // profiles; only [ProfileN] sections describe one.
      inProfile = line.toLowerCase().indexOf("[profile") === 0
      continue
    }
    if (!inProfile) continue

    var eq = line.indexOf("=")
    if (eq === -1) continue
    if (line.slice(0, eq).trim().toLowerCase() !== "name") continue

    var name = line.slice(eq + 1).trim()
    if (!name || seen[name]) continue
    if (FIREFOX_AUTO_PROFILES.indexOf(name) !== -1) continue
    seen[name] = true
    out.push({ dir: name, name: name })
  }

  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

// info_cache keys are the directory names ("Default", "Profile 3"); each value
// carries the name the user sees in the browser's profile switcher.
function parseProfileEntries(raw) {
  var data = raw
  if (typeof raw === "string") {
    try { data = JSON.parse(raw) } catch (e) { return [] }
  }
  if (!data || typeof data !== "object") return []
  var cache = data.profile && data.profile.info_cache
  if (!cache || typeof cache !== "object") return []

  var out = []
  for (var dir in cache) {
    var info = cache[dir] || {}
    out.push({ dir: dir, name: String(info.name || dir) })
  }
  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

// Rules name the profile the way the user sees it. Fall back to treating the
// value as a directory name, which is what someone hand-editing the config is
// most likely to have written.
function resolveProfileDirectory(entries, displayName) {
  var wanted = String(displayName || "").trim()
  if (!wanted) return ""
  var list = entries || []
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].name) === wanted) return String(list[i].dir)
  }
  for (var j = 0; j < list.length; j++) {
    if (String(list[j].dir) === wanted) return String(list[j].dir)
  }
  return wanted
}

// Firefox 143+ keeps user-created profiles in `Profile Groups/<id>.sqlite`
// rather than profiles.ini, which by then only holds the auto-generated
// default/default-release. Those profiles have no name `-P` can resolve, so
// they are launched by absolute path with `--profile` instead.
//
// Input is one "<base>\t<relative path>|<name>" line per profile, which is what
// the sqlite3 shell-out in Service.qml prints. Split on the first separator
// each time: a profile name may contain anything, a path column will not.
function parseFirefoxGroups(stdout) {
  var lines = String(stdout || "").split("\n")
  var out = []
  var seen = {}

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue

    var tab = line.indexOf("\t")
    if (tab === -1) continue
    var base = line.slice(0, tab)
    var rest = line.slice(tab + 1)

    var bar = rest.indexOf("|")
    if (bar === -1) continue
    var rel = rest.slice(0, bar).trim()
    var name = rest.slice(bar + 1).trim()
    if (!rel || !name || seen[name]) continue

    seen[name] = true
    out.push({ dir: base + "/" + rel, name: name })
  }

  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

// Flags have to land right after the binary, before any URL: Chromium hands a
// URL to an already-running process and only honours them when they precede it.
// Same reasoning applies to Firefox.
function profileArgs(browserId, profileDirectory) {
  if (!profileDirectory) return []
  if (isChromiumFamily(browserId)) return ["--profile-directory=" + profileDirectory]

  // An absolute path came from the SQLite store and is the only handle those
  // profiles have; a bare name came from profiles.ini and `-P` resolves it.
  return profileDirectory.charAt(0) === "/"
    ? ["--profile", profileDirectory]
    : ["-P", profileDirectory]
}

// ------------------------------------------------------------------- private
//
// Not guessed: each of these is the Exec line the browser's own
// `[Desktop Action new-private-window]` runs, read off the installed .desktop.
// A browser with no entry here gets nothing, and the UI says so rather than
// opening an ordinary window and calling it private.
function privateFlag(browserId) {
  if (isChromiumFamily(browserId)) return "--incognito"
  if (isFirefoxFamily(browserId)) return "--private-window"
  return ""
}

function supportsPrivate(browserId) { return privateFlag(browserId) !== "" }

// Profile and private compose. Verified on Firefox, where both are visible at
// once — a window launched with `--profile <path> --private-window` titles
// itself "… — <profile> — Mozilla Firefox Private Browsing". Chromium's
// incognito is per-profile by design and its window exposes no state to read
// back, so that family rests on the vendor's own flag rather than on a
// measurement. Profile args come first, which is the order that was tested.
function launchArgs(browserId, execString, url, profileDirectory, wantPrivate) {
  var argv = expandExec(execString, url)
  if (argv.length === 0) return argv

  var flags = profileArgs(browserId, profileDirectory)
  if (wantPrivate) {
    var flag = privateFlag(browserId)
    if (flag) flags.push(flag)
  }

  // No --new-window. Asking for a profile that is already open should land on
  // the window that is already open, and the browser is the only thing that
  // knows which window belongs to which profile: a normal Chromium window
  // reports the same app id whatever profile it is showing, so the compositor
  // cannot be asked to focus "the one for profile 44". Forcing a new window
  // here took that decision away from the only component able to make it.
  if (flags.length === 0) return argv

  return [argv[0]].concat(flags, argv.slice(1))
}

// --------------------------------------------------------- existing windows
//
// "Open Brave · 44" when Brave · 44 is already on screen should take you there,
// not stack a second window on top. The browser will not do this — asked for a
// profile with no URL, Chromium opens another window — so the compositor has to
// be asked instead, which means recognising which window belongs to which
// browser and profile.
//
// A `--app=` window names itself `<binary>-<host>_<path>-<Profile>`, with every
// slash in the path collapsed to an underscore. The path always starts with
// one, so the host is always followed by two: `--app=https://web.whatsapp.com/`
// reports "brave-web.whatsapp.com__-Default" and `.../send` reports
// "brave-web.whatsapp.com__send-Default". That doubled underscore is the
// marker, and it is what keeps a web app from ever counting as the browser
// being open, which it is not.
function isAppWindowClass(cls) { return String(cls || "").indexOf("__") !== -1 }

// Exact, not prefixed, and case-sensitive. "google-chrome".indexOf(
// "google-chrome-beta") style matching makes stable Chrome and Chrome Beta each
// other's windows, so asking for one silently gets you the other; the same for
// firefox against firefox-esr.
//
// Case is what tells a Wayland window from an XWayland one. Chromium's Wayland
// app id is the desktop id verbatim, `brave-browser`, while its X11 WM_CLASS is
// capitalised, `Brave-browser` -- and those are different browser processes.
// Measured here: a second Brave under XWayland had four windows of its own, and
// with the comparison folding case they were candidates. Raising one did
// nothing for a link handed to the Wayland instance -- Brave opened a new
// window anyway, and the focus landed on a password manager popup -- so folding
// case bought a wrong window and a stolen focus. A browser whose window id
// genuinely differs from its desktop id simply falls through to launching,
// which is the harmless direction.
function isOrdinaryWindowOf(cls, browserId) {
  var c = String(cls || "")
  var id = String(browserId || "")
  if (!c || !id || isAppWindowClass(c)) return false
  return c === id
}

// Firefox writes the profile into the window title — "… — Personal — Mozilla
// Firefox" — so its windows can be told apart. Chromium-family windows report
// the same class and the same title shape whatever profile they are showing,
// so the only case that can be answered honestly there is a browser with a
// single profile: every ordinary window of it is that profile by definition.
// With several, guessing would send the link to the wrong one, and returning
// nothing simply falls through to launching, which is what happened before.
// Firefox titles read "<page> — <profile> — Mozilla Firefox", and drop the page
// when there is not one yet: "<profile> — Mozilla Firefox". So the profile is
// whatever sits immediately before the brand segment, not a fixed position.
//
// A private window extends that segment — "Mozilla Firefox Private Browsing" in
// English, "Mozilla Firefox (Navegação privativa)" in pt-BR. Rather than match
// the English wording, require the brand segment to be *exactly* the brand:
// anything longer is some mode, and no mode is a place to send an ordinary
// request. Returns "" for those, and for anything that is not Firefox at all.
function geckoTitleProfile(title) {
  var parts = String(title || "").split(" — ")
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i].indexOf("Mozilla Firefox") !== 0) continue
    if (parts[i] !== "Mozilla Firefox") return ""
    return i > 0 ? parts[i - 1] : ""
  }
  return ""
}

// Which installed browser an ordinary window belongs to: its desktop id, or ""
// for an --app= window, a PWA, or anything that is not a browser. The
// activation record in Service.qml keeps only these. Recording every window
// would let a few minutes of terminal switching push the last Brave window out
// of a bounded list, and the browser's window is the one the record is for.
function ordinaryWindowBrowser(cls, browsers) {
  var list = browsers || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && isOrdinaryWindowOf(cls, list[i].id)) return String(list[i].id)
  }
  return ""
}

// The browser's ordinary windows, most recently activated first.
//
// `order` is the service's record of ToplevelManager.activeToplevel over time,
// most recent first; the protocol itself carries no history. Windows the
// record has never seen follow it: the one the compositor flags active goes
// ahead of everything, since it is the current one whatever the record missed,
// and the rest keep list order, which is the order every pick used before
// there was a record.
//
// Membership in `toplevels` is checked before a handle is read. A handle in a
// plain JS array whose window has closed is not null the way a `property var`
// becomes null -- it stays truthy, reads undefined, and throws on a method
// call (measured under qmltestrunner). The live list is the only thing that
// says whether a recorded window still exists.
function ordinaryToplevelsByRecency(toplevels, order, browserId) {
  var open = toplevels || []
  var history = order || []
  var out = []
  var i, top

  for (i = 0; i < history.length; i++) {
    top = history[i]
    if (!top || open.indexOf(top) === -1 || out.indexOf(top) !== -1) continue
    if (isOrdinaryWindowOf(top.appId, browserId)) out.push(top)
  }
  for (i = 0; i < open.length; i++) {
    top = open[i]
    if (!top || out.indexOf(top) !== -1 || !isOrdinaryWindowOf(top.appId, browserId)) continue
    if (top.activated) out.unshift(top)
    else out.push(top)
  }
  return out
}

// Given the compositor's list of open windows, the one that already belongs to
// this browser and profile, or null. Wayland toplevels rather than a compositor
// query: `appId`, `title` and `activate()` come from the foreign-toplevel
// protocol, so this needs no hyprctl, no JSON, no dispatcher dialect, and no
// round trip — the answer is available at the moment the choice is made.
//
// `order` is optional and only the Chromium branch reads it. Gecko keeps the
// compositor's flag and then list order: a Firefox window takes a link on its
// own whichever one it is, so nothing downstream depends on the choice.
function findProfileToplevel(toplevels, browserId, profileName, profileCount, order) {
  var list = toplevels || []
  var wanted = String(profileName || "")

  if (isFirefoxFamily(browserId)) {
    var first = null
    for (var i = 0; i < list.length; i++) {
      var top = list[i]
      if (!top || !isOrdinaryWindowOf(top.appId, browserId)) continue
      // Evaluated for every candidate, including when no profile is pinned:
      // a stock Firefox reports no profiles at all, and skipping the check in
      // that case is exactly how a Private Browsing window gets focused for an
      // ordinary request.
      var found = geckoTitleProfile(top.title)
      if (!found) continue
      if (wanted && found !== wanted) continue
      if (top.activated) return top
      if (!first) first = top
    }
    return first
  }

  // Chromium-family windows report the same appId and title shape whatever
  // profile they show, so with several profiles there is nothing to match on
  // and launching beats focusing the wrong one.
  if (wanted && Number(profileCount) > 1) return null

  var recent = ordinaryToplevelsByRecency(list, order, browserId)
  return recent.length ? recent[0] : null
}

// ------------------------------------------------------ where a link lands
//
// Chromium 146 and later hand a forwarded URL to the profile's most recently
// activated browser window of ANY type: GetExistingBrowserForOpenBehavior() in
// chrome/browser/ui/startup/startup_browser_creator_impl.cc takes
// GetLastActiveBrowser() with no window-type filter, and OpenTabsInBrowser()
// opens a fresh window when that browser is not TYPE_NORMAL. Up to M145 this
// went through FindTabbedBrowser(), which skipped app windows, and a link
// always became a tab (CL 7279203, crbug 431671320). The Linux branch that
// would still prefer a normal window on the current workspace is dead under
// Wayland, where GetCurrentWorkspace() answers "". So on Hyprland: focus the
// WhatsApp --app= window, pick Brave · 44 for a link, and Brave opens a second
// window with the argv that made a tab a minute earlier. Measured 4/4 on Brave
// 152 with one profile; workspace and monitor irrelevant, activation order the
// only input. The app window is this plugin's own doing -- launchWebapp
// focuses it on purpose -- so a WhatsApp link primes the miss for the next
// link routed to Brave.
//
// Activating the ordinary window right before the launch puts it back at the
// front of Chromium's order and the URL becomes a tab, 3/3. So the question
// here is not "does an app window exist" -- one left on another workspace and
// not touched since does no harm -- but whether this browser's ordinary
// window is still the last thing activated. The protocol shows appId, title
// and a single `activated` flag, so that is answered from the outside in: if
// the window the link is bound for is the one the compositor has active,
// nothing of the browser's was activated after it and the link lands there on
// its own. Anything else -- an --app= window, a PWA, undocked DevTools, or
// only a terminal -- might have, and raising costs nothing when it had not:
// the tab lands in the same window either way.
//
// What this cannot see, and how each degrades: a window.open popup reports the
// ordinary class and is a candidate here, so when it was the last window used
// it is the one raised and Chromium still opens a new window -- today's
// behaviour, no worse. An incognito window is likewise indistinguishable on a
// single-profile browser. With several profiles nothing is raised, pinned or
// not: Chromium's order is per profile, and activating a window makes its
// profile the browser's last-used one, so an unpinned link would follow the
// raise into a profile the browser would not have chosen -- worse than the
// second window. In every case `raise` is only ever additional to the launch,
// never a replacement for it.
function linkLanding(toplevels, order, browserId, profileName, profileCount, wantPrivate) {
  function none(reason) { return { raise: null, reason: reason } }

  if (!isChromiumFamily(browserId)) return none("not Chromium: the link joins a window on its own")
  if (wantPrivate) return none("private: a new window is the point")
  if (Number(profileCount) > 1) {
    return none(profileCount + " profiles, and Chromium windows do not say which one they show")
  }

  var top = findProfileToplevel(toplevels, browserId, profileName, profileCount, order)
  if (!top) return none("no ordinary window of " + browserId + " is open")
  if (top.activated) return none("already active: the link lands there on its own")

  var active = null
  var list = toplevels || []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].activated) { active = list[i]; break }
  return {
    raise: top,
    reason: "active window is " + (active ? String(active.appId || "?") : "none")
  }
}

// A Hyprland window selector is a regex, so the class has to survive being
// read as one: `brave-web.whatsapp.com__-Default` is full of dots.
function classSelector(cls) {
  var c = String(cls || "")
  if (!c) return ""
  return "class:^(" + c.replace(/[\\^$.|?*+()\[\]{}]/g, "\\$&") + ")$"
}

// The Hyprland selector that reaches this window and no other. `hyprlandToplevels`
// is Hyprland.toplevels.values: each entry pairs a HyprlandToplevel, whose
// `address` is the window's address in bare hex ("55bedbe16bc0" for the window
// `hyprctl clients` lists as 0x55bedbe16bc0), with `wayland`, the same Toplevel
// handle ToplevelManager hands out. By address, because a class selector
// focuses whichever window Hyprland lists first -- fine when any window of the
// profile will do, wrong with a link in hand, when the window that gets
// focused is the window that gets the tab. Class is the fallback for a window
// Hyprland's model does not know, which is where every raise went before.
function windowSelector(top, hyprlandToplevels) {
  if (!top) return ""
  var list = hyprlandToplevels || []
  for (var i = 0; i < list.length; i++) {
    var h = list[i]
    if (!h || h.wayland !== top) continue
    var address = String(h.address || "").replace(/^0x/, "")
    if (address) return "address:0x" + address
  }
  return classSelector(top.appId)
}

// --------------------------------------------------------------- web apps
//
// Omarchy installs a web app as a desktop entry whose Exec is
// `omarchy-launch-webapp <url>`: a chromeless `--app=` window pinned to one
// site. That URL is the only thing in the entry that says what the app is
// *for*, which makes it the handle for "does this link belong in that app".
//
// The other two shapes in the wild are `omarchy-launch-or-focus-webapp
// <pattern> <url>` and a hand-written `<browser> --app=<url>`; all three are
// read the same way.
function webappUrl(execString) {
  var tokens = tokenizeExec(execString)
  if (tokens.length === 0) return ""

  var head = String(tokens[0] || "")
  var launcher = head.indexOf("omarchy-launch-webapp") !== -1
    || head.indexOf("omarchy-launch-or-focus-webapp") !== -1

  for (var i = 1; i < tokens.length; i++) {
    var t = String(tokens[i])
    if (t.indexOf("--app=") === 0) return t.slice(6)
    // A launcher's first URL-shaped argument. The or-focus variant puts a
    // window pattern in front of it, so position alone cannot find it.
    if (launcher && t.indexOf("://") !== -1) return t
  }
  return ""
}

// A desktop entry read as a web app, or null. `host` is left to the caller:
// the URL parser lives in Router.js and this file imports nothing.
function webappEntry(entry) {
  if (!entry) return null
  if (entry.noDisplay === true) return null
  var id = String(entry.id || "")
  if (!id) return null
  var url = webappUrl(entry.execString)
  if (!url) return null
  return { id: id, name: String(entry.name || id), icon: entry.icon, url: url, entry: entry }
}

// The registered domain, near enough: the last two labels. This decides only
// whether a link and a web app are "the same site" — api.whatsapp.com and
// web.whatsapp.com are, and a share link lands on the first while the app sits
// on the second. A wrong answer under a multi-label suffix like .co.uk costs a
// suggested picker row, never a route: nothing here fires without a rule.
function siteKey(host) {
  var parts = String(host || "").toLowerCase().split(".")
  if (parts.length <= 2) return parts.join(".")
  return parts.slice(parts.length - 2).join(".")
}

// Whether a `--app=` window belongs to a site.
//
// Splitting the class on `-` does not work: both the binary (google-chrome) and
// a host (my-site.com) carry dashes, so there is no field to take. What is
// certain is where the host ends — at the `__` isAppWindowClass describes — so
// the site is matched as the tail of the host: preceded by the `-` that closes
// the binary or the `.` that makes it a subdomain, and followed by that pair.
function isAppWindowOfSite(appId, site) {
  var id = String(appId || "").toLowerCase()
  var s = String(site || "").toLowerCase()
  if (!s) return false

  var at = id.indexOf(s + "__")
  while (at > 0) {
    var before = id.charAt(at - 1)
    if (before === "-" || before === ".") return true
    at = id.indexOf(s + "__", at + 1)
  }
  return false
}

// The open `--app=` window for a site, or null. Activated first, for the same
// reason findProfileToplevel does it: the protocol carries no focus history, so
// the window the compositor has active is the only "most recent" available.
function findAppToplevel(toplevels, site) {
  var list = toplevels || []
  var first = null
  for (var i = 0; i < list.length; i++) {
    var top = list[i]
    if (!top || !isAppWindowOfSite(top.appId, site)) continue
    if (top.activated) return top
    if (!first) first = top
  }
  return first
}

// `<browser> --app=<url>`. The flag precedes the entry's own arguments for the
// same reason profile flags do, and the URL is never appended a second time:
// it travels inside --app=, and a copy on the command line opens an ordinary
// window next to the app one.
function webappArgs(browserId, execString, url, profileDirectory) {
  var argv = expandExec(execString, "")
  if (argv.length === 0) return []
  var flags = profileArgs(browserId, profileDirectory)
  flags.push("--app=" + String(url || ""))
  return [argv[0]].concat(flags, argv.slice(1))
}

// --------------------------------------------------------------- handlers
//
// Which applications claim a URI scheme, read off disk rather than from
// DesktopEntries.
//
// DesktopEntries indexes by desktop id, and an id is not unique across the data
// directories. Two files named Zoom.desktop -- Omarchy's web app handler in
// ~/.local/share and the native client's in /usr/share -- both claim
// zoommtg://, and the plugin could not see that at all: it was handed one entry
// and never told there was a second. `xdg-mime query default` has the same
// blindness, answering "Zoom.desktop" for either.
//
// Input is one "<path>\t<name>\t<exec>" line per entry, which is what the
// shell-out in Service.qml prints. Split on the first separator each time: a
// Name may contain anything, a path will not.
function parseHandlers(stdout) {
  var lines = String(stdout || "").split("\n")
  var out = []
  var seen = {}

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue

    var a = line.indexOf("\t")
    if (a === -1) continue
    var path = line.slice(0, a).trim()
    var rest = line.slice(a + 1)

    var b = rest.indexOf("\t")
    var name = (b === -1 ? rest : rest.slice(0, b)).trim()
    var exec = b === -1 ? "" : rest.slice(b + 1).trim()

    if (!path || path.charAt(0) !== "/" || seen[path]) continue
    seen[path] = true

    out.push({
      path: path,
      name: name || path.split("/").pop().replace(/\.desktop$/, ""),
      exec: exec,
      // The directory is what tells two identically named entries apart, and it
      // is the only thing a person can use to choose between them.
      where: path.slice(0, path.lastIndexOf("/"))
    })
  }

  out.sort(function(a, b) { return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0) })
  return out
}

// ------------------------------------------------------------------- browsers

// DesktopEntry.categories is a QStringList, which reaches JS as an array-LIKE
// object: it indexes and has .length, but Array.isArray() says false and
// String() flattens it to "Network,WebBrowser". Both of the obvious checks are
// therefore wrong, so normalize by shape rather than by type.
function categoryList(categories) {
  if (!categories) return []
  if (typeof categories === "string") return categories.split(";")
  if (typeof categories.length === "number") {
    var out = []
    for (var i = 0; i < categories.length; i++) out.push(String(categories[i]))
    return out
  }
  return String(categories).split(";")
}

// DesktopEntries has no MimeType property, so Categories is the signal. Every
// browser that registers itself as an http handler also declares WebBrowser —
// it is what puts them in the "Internet" menu.
function isBrowserEntry(entry, selfDesktopId) {
  if (!entry) return false
  if (entry.noDisplay === true) return false
  var id = String(entry.id || "")
  if (!id) return false
  if (selfDesktopId && id === selfDesktopId) return false
  if (selfDesktopId && id === selfDesktopId.replace(/\.desktop$/, "")) return false

  // Any mclovin is a router, not a browser — including the retired CLI, which
  // installs mclovin.desktop with Categories=Network;WebBrowser and NoDisplay
  // unset. Matching only selfDesktopId let it show up as a picker row and as a
  // rule target, so a link could be routed into a second router carrying its
  // own rules.toml.
  if (id.toLowerCase().indexOf("mclovin") !== -1) return false

  var list = categoryList(entry.categories)
  for (var i = 0; i < list.length; i++) {
    if (String(list[i]).trim().toLowerCase() === "webbrowser") return true
  }
  return false
}

// One picker row per launchable target: a browser with no profiles is one row,
// a browser with profiles is one row each and no bare row, because launching
// "Chromium" with no profile when three exist just reopens whichever was last
// used — a choice the user did not make.
function pickerEntries(browsers, profilesByBrowser) {
  var out = []
  var list = browsers || []

  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    var id = String(b.id)
    var name = String(b.name || id)
    var profiles = (profilesByBrowser || {})[id] || []

    if (profiles.length === 0) {
      out.push({ browserId: id, name: name, profile: "", icon: b.icon, entry: b })
      continue
    }
    for (var j = 0; j < profiles.length; j++) {
      out.push({
        browserId: id,
        name: name,
        profile: String(profiles[j].name),
        icon: b.icon,
        entry: b
      })
    }
  }
  return out
}

// Filter across the browser name, the profile name, and the desktop id, so
// typing "design" finds the Chrome profile and typing "brave" finds Brave.
function filterPickerEntries(entries, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return entries || []
  var out = []
  var list = entries || []
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    var haystack = (String(e.name) + " " + String(e.profile) + " " + String(e.browserId)).toLowerCase()
    if (haystack.indexOf(q) !== -1) out.push(e)
  }
  return out
}

function sortBrowsers(entries) {
  var out = entries.slice()
  out.sort(function(a, b) {
    var an = String((a && a.name) || "").toLowerCase()
    var bn = String((b && b.name) || "").toLowerCase()
    return an < bn ? -1 : (an > bn ? 1 : 0)
  })
  return out
}
