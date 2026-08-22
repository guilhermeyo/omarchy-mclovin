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
// A `--app=` window reports a class like "brave-web.whatsapp.com__-Default".
// That marker is what keeps a webapp from ever counting as the browser being
// open, which it is not.
function isAppWindowClass(cls) { return String(cls || "").indexOf("__-") !== -1 }

// Exact, not prefixed. "google-chrome".indexOf("google-chrome-beta") style
// matching makes stable Chrome and Chrome Beta each other's windows, so asking
// for one silently gets you the other; the same for firefox against
// firefox-esr. A browser whose window id genuinely differs from its desktop id
// simply falls through to launching, which is the harmless direction.
function isOrdinaryWindowOf(cls, browserId) {
  var c = String(cls || "").toLowerCase()
  var id = String(browserId || "").toLowerCase()
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

// Given the compositor's list of open windows, the one that already belongs to
// this browser and profile, or null. Wayland toplevels rather than a compositor
// query: `appId`, `title` and `activate()` come from the foreign-toplevel
// protocol, so this needs no hyprctl, no JSON, no dispatcher dialect, and no
// round trip — the answer is available at the moment the choice is made.
function findProfileToplevel(toplevels, browserId, profileName, profileCount) {
  var list = toplevels || []
  var gecko = isFirefoxFamily(browserId)
  var wanted = String(profileName || "")
  var first = null

  for (var i = 0; i < list.length; i++) {
    var top = list[i]
    if (!top || !isOrdinaryWindowOf(top.appId, browserId)) continue

    if (gecko) {
      // Evaluated for every candidate, including when no profile is pinned:
      // a stock Firefox reports no profiles at all, and skipping the check in
      // that case is exactly how a Private Browsing window gets focused for an
      // ordinary request.
      var found = geckoTitleProfile(top.title)
      if (!found) continue
      if (wanted && found !== wanted) continue
    } else if (wanted && Number(profileCount) > 1) {
      // Chromium-family windows report the same appId and title shape whatever
      // profile they show, so with several profiles there is nothing to match
      // on and launching beats focusing the wrong one.
      continue
    }

    // The protocol carries no focus history, so "most recently used" is not
    // answerable. The window the compositor has active is the one case that is.
    if (top.activated) return top
    if (!first) first = top
  }
  return first
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
