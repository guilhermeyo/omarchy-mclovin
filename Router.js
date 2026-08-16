.pragma library

// Pure routing logic: no QML types, no side effects. Everything here is
// callable from a plain JS test harness, which is why the file holds the URL
// parsing, rule matching, and Exec= expansion rather than Service.qml.

var CONFIG_VERSION = 1

// ---------------------------------------------------------------- URL pieces

// A hand-rolled parser instead of `new URL()`: QML's JS engine has it, but it
// throws on the half-formed input that reaches an http handler in practice
// (bare "example.com", "mailto:" leaking through a misconfigured mimeapps).
// Returning empty strings beats an exception on the hot path.
function parseUrl(raw) {
  var url = String(raw || "").trim()
  var scheme = ""
  var rest = url

  var schemeEnd = url.indexOf("://")
  if (schemeEnd > 0) {
    scheme = url.slice(0, schemeEnd).toLowerCase()
    rest = url.slice(schemeEnd + 3)
  }

  // Authority ends at the first /, ?, or #.
  var authority = rest
  for (var i = 0; i < rest.length; i++) {
    var c = rest.charAt(i)
    if (c === "/" || c === "?" || c === "#") { authority = rest.slice(0, i); break }
  }

  // Strip userinfo and port; keep the bare host.
  var at = authority.lastIndexOf("@")
  if (at !== -1) authority = authority.slice(at + 1)
  var colon = authority.lastIndexOf(":")
  if (colon !== -1 && authority.indexOf("]") === -1) authority = authority.slice(0, colon)

  var host = authority.toLowerCase()
  return {
    url: url,
    scheme: scheme,
    host: host,
    // www. is noise for both display and rule matching — nobody wants one rule
    // for www.github.com and another for github.com.
    domain: host.indexOf("www.") === 0 ? host.slice(4) : host
  }
}

// What the picker shows and what a remembered rule keys on. Falls back to the
// whole URL so a scheme-less or malformed link still reads as something.
function displayHost(parsed) {
  return parsed.domain || parsed.url
}

// ------------------------------------------------------------- rule matching

// A rule matches when one of its patterns is a case-insensitive substring of
// the URL. Substring rather than exact-host so "github.com/acme" can route an
// org to a different profile than the rest of GitHub — the single most common
// thing people want from a URL router, and it needs no regex syntax to express.
//
// `match` may be a string or a list of strings; `matchRegex` is the escape
// hatch, and exists mainly so importing an existing rules.toml is lossless.
function ruleMatches(rule, parsed) {
  if (!rule) return false

  var regex = String(rule.matchRegex || "").trim()
  if (regex) {
    try { return new RegExp(regex, "i").test(parsed.url) } catch (e) { return false }
  }

  var patterns = matchList(rule.match)
  for (var i = 0; i < patterns.length; i++) {
    if (parsed.url.toLowerCase().indexOf(patterns[i]) !== -1) return true
  }
  return false
}

function matchList(match) {
  var out = []
  if (Array.isArray(match)) {
    for (var i = 0; i < match.length; i++) {
      var v = String(match[i] || "").trim().toLowerCase()
      if (v) out.push(v)
    }
    return out
  }
  var single = String(match || "").trim().toLowerCase()
  return single ? [single] : []
}

// What the bar widget prints for a rule, and what upsert dedupes on.
function ruleLabel(rule) {
  if (!rule) return ""
  if (rule.matchRegex) return "/" + rule.matchRegex + "/"
  var patterns = matchList(rule.match)
  return patterns.join(", ")
}

function ruleTargetLabel(rule) {
  if (!rule) return ""
  if (rule.command) return rule.command
  var target = String(rule.browser || "")
  return rule.profile ? target + " · " + rule.profile : target
}

// First match wins, so rules are ordered most-specific-first by the caller.
// Returns the rule itself (not just the browser) because the bar widget shows
// which rule fired.
function firstMatch(rules, parsed) {
  if (!Array.isArray(rules)) return null
  for (var i = 0; i < rules.length; i++) {
    if (ruleMatches(rules[i], parsed)) return rules[i]
  }
  return null
}

function normalizeConfig(raw) {
  var parsed = raw
  if (typeof raw === "string") {
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
  }
  if (!parsed || typeof parsed !== "object") parsed = {}

  var rules = Array.isArray(parsed.rules) ? parsed.rules : []
  var clean = []
  for (var i = 0; i < rules.length; i++) {
    var r = normalizeRule(rules[i])
    if (r) clean.push(r)
  }

  return {
    version: CONFIG_VERSION,
    fallback: String(parsed.fallback || "").trim(),
    fallbackProfile: String(parsed.fallbackProfile || "").trim(),
    // Which browser gets `--app=` windows. Never the picker: a webapp launcher
    // asking which browser to use every time would be unusable.
    webapp: String(parsed.webapp || "").trim(),
    rules: clean
  }
}

// A rule needs somewhere to send the URL — either a desktop entry (optionally
// with a browser profile) or a raw command line containing {url}. Anything
// without a matcher or without a target is dropped rather than kept as a rule
// that can never fire.
function normalizeRule(raw) {
  if (!raw || typeof raw !== "object") return null

  var out = {}
  var patterns = matchList(raw.match)
  var regex = String(raw.matchRegex || "").trim()
  if (patterns.length === 0 && !regex) return null

  if (regex) out.matchRegex = regex
  if (patterns.length === 1) out.match = patterns[0]
  else if (patterns.length > 1) out.match = patterns

  var command = String(raw.command || "").trim()
  var browser = String(raw.browser || "").trim()
  if (command) {
    out.command = command
  } else if (browser) {
    out.browser = browser
    var profile = String(raw.profile || "").trim()
    if (profile) out.profile = profile
  } else {
    return null
  }

  return out
}

// Replacing an existing rule for the same pattern rather than appending keeps
// "remember this" idempotent — picking a different browser for a host you
// already have a rule for updates it instead of adding a shadowed duplicate.
function upsertRule(config, match, browser, profile) {
  var next = normalizeConfig(config)
  var candidate = normalizeRule({ match: match, browser: browser, profile: profile })
  if (!candidate) return next

  var key = ruleLabel(candidate).toLowerCase()
  for (var i = 0; i < next.rules.length; i++) {
    if (ruleLabel(next.rules[i]).toLowerCase() === key) {
      next.rules[i] = candidate
      return next
    }
  }
  next.rules.push(candidate)
  return next
}

function removeRuleAt(config, index) {
  var next = normalizeConfig(config)
  if (index < 0 || index >= next.rules.length) return next
  next.rules.splice(index, 1)
  return next
}

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

  for (var i = 0; i < tokens.length; i++) {
    var t = tokens[i]
    if (t === "%u" || t === "%U" || t === "%f" || t === "%F") {
      if (target) out.push(target)
      continue
    }
    if (t === "%i" || t === "%c" || t === "%k" || t === "%d" || t === "%D"
        || t === "%n" || t === "%N" || t === "%v" || t === "%m") continue
    // A code glued to other text (Exec=foo --url=%u) still has to lose the code.
    if (t.indexOf("%") !== -1) {
      t = t.replace(/%[uUfF]/g, target).replace(/%[a-zA-Z]/g, "")
      if (!t) continue
    }
    out.push(t)
  }
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

// The flag has to land right after the binary, before any URL: Chromium hands
// a URL to an already-running process and only honours the profile when the
// flag precedes it. Same reasoning applies to Firefox.
function applyProfile(argv, browserId, profileDirectory) {
  if (!profileDirectory || argv.length === 0) return argv
  var out = argv.slice()

  if (isChromiumFamily(browserId)) {
    out.splice(1, 0, "--profile-directory=" + profileDirectory)
    return out
  }

  // An absolute path came from the SQLite store and is the only handle those
  // profiles have; a bare name came from profiles.ini and `-P` resolves it.
  if (profileDirectory.charAt(0) === "/") {
    out.splice(1, 0, "--profile")
    out.splice(2, 0, profileDirectory)
  } else {
    out.splice(1, 0, "-P")
    out.splice(2, 0, profileDirectory)
  }
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
// typing "invoice" finds the Chromium profile and typing "brave" finds Brave.
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

function filterBrowsers(entries, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return entries
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var name = String((e && e.name) || "").toLowerCase()
    var id = String((e && e.id) || "").toLowerCase()
    if (name.indexOf(q) !== -1 || id.indexOf(q) !== -1) out.push(e)
  }
  return out
}

// ------------------------------------------------------------ rules.toml import

// A deliberately small TOML reader: enough for the shape the mclovin CLI
// writes, and nothing else. It is not a general TOML parser and does not try to
// be — the alternative was vendoring one into a plugin whose whole point is
// being light.
//
// Handles: root key/value pairs, [[handler]] array-of-tables, the
// [handler.browser] sub-table, string and string-array values, single or double
// quotes, full-line and trailing comments outside quotes.
function parseTomlValue(raw) {
  var v = String(raw || "").trim()
  if (!v) return ""

  if (v.charAt(0) === "[") {
    var inner = v.slice(1, v.lastIndexOf("]"))
    var parts = []
    var buf = ""
    var quote = ""
    for (var i = 0; i < inner.length; i++) {
      var c = inner.charAt(i)
      if (quote) {
        if (c === quote) { quote = "" } else { buf += c }
        continue
      }
      if (c === "\"" || c === "'") { quote = c; continue }
      if (c === ",") { if (buf.trim()) parts.push(buf.trim()); buf = ""; continue }
      buf += c
    }
    if (buf.trim()) parts.push(buf.trim())
    return parts
  }

  var q = v.charAt(0)
  if (q === "\"" || q === "'") {
    var end = v.lastIndexOf(q)
    return end > 0 ? v.slice(1, end) : v.slice(1)
  }
  return v
}

// Strip a trailing comment, but only when the # is outside a quoted string —
// URLs with fragments live in these files.
function stripComment(line) {
  var quote = ""
  for (var i = 0; i < line.length; i++) {
    var c = line.charAt(i)
    if (quote) {
      if (c === quote) quote = ""
      continue
    }
    if (c === "\"" || c === "'") { quote = c; continue }
    if (c === "#") return line.slice(0, i)
  }
  return line
}

function parseMclovinToml(text) {
  var lines = String(text || "").split("\n")
  var out = { fallback: "", rules: [], skipped: 0 }
  var current = null
  var section = ""      // "" = root, "handler" = inside [[handler]], "handler.browser"

  function flush() {
    if (!current) return
    var hasMatch = matchList(current.match).length > 0 || current.matchRegex
    var hasTarget = current.command || current.browser
    // A rewrite means the URL is transformed before dispatch, which this plugin
    // does not do. Importing it would route the right link to the right browser
    // but silently drop the rewrite, so leave it behind and say so.
    if (hasMatch && hasTarget && !current.rewrite) out.rules.push(current)
    else out.skipped++
    current = null
  }

  for (var i = 0; i < lines.length; i++) {
    var line = stripComment(lines[i]).trim()
    if (!line) continue

    if (line === "[[handler]]") {
      flush()
      current = {}
      section = "handler"
      continue
    }
    if (line === "[handler.browser]") {
      section = "handler.browser"
      continue
    }
    if (line.charAt(0) === "[") {
      // Any other table ([webapp], [[something-else]]) ends the current handler.
      flush()
      section = "other"
      continue
    }

    var eq = line.indexOf("=")
    if (eq === -1) continue
    var key = line.slice(0, eq).trim()
    var value = parseTomlValue(line.slice(eq + 1))

    if (section === "handler.browser" && current) {
      if (key === "name") current.browser = String(value)
      else if (key === "profile") current.profile = String(value)
      continue
    }
    if (section === "handler" && current) {
      if (key === "match") current.match = value
      else if (key === "match_regex") current.matchRegex = String(value)
      else if (key === "command") current.command = String(value)
      else if (key === "browser") current.browser = String(value)
      else if (key === "rewrite") current.rewrite = String(value)
      continue
    }
    if (section === "" && key === "fallback_browser") out.fallback = String(value)
  }

  flush()
  return out
}

// mclovin writes browser names the way a human types them ("brave"), which is
// not always the desktop entry id ("brave-browser"). Match on id, then on id
// prefix, then on display name.
function resolveBrowserId(browsers, value) {
  var wanted = String(value || "").trim()
  if (!wanted) return ""
  var list = browsers || []
  var lower = wanted.toLowerCase()

  for (var i = 0; i < list.length; i++) {
    if (String(list[i].id).toLowerCase() === lower) return String(list[i].id)
  }
  for (var j = 0; j < list.length; j++) {
    var id = String(list[j].id).toLowerCase()
    if (id.indexOf(lower) === 0 || lower.indexOf(id) === 0) return String(list[j].id)
  }
  for (var k = 0; k < list.length; k++) {
    if (String(list[k].name).toLowerCase() === lower) return String(list[k].id)
  }
  return wanted
}

// Imported rules resolved against the installed browsers, in file order.
function resolveImported(imported, browsers) {
  var out = []
  var rules = (imported && imported.rules) || []
  for (var i = 0; i < rules.length; i++) {
    var r = rules[i]
    var rule = normalizeRule({
      match: r.match,
      matchRegex: r.matchRegex,
      command: r.command,
      browser: r.command ? "" : resolveBrowserId(browsers, r.browser),
      profile: r.profile
    })
    if (rule) out.push(rule)
  }
  return out
}

// How many of the CLI's rules the config does not already carry. Compared on
// the matcher alone: a rule for the same pattern pointing somewhere else is an
// edit the user made here, not something to re-import.
function countNewRules(config, imported, browsers) {
  var current = normalizeConfig(config)
  var have = {}
  for (var i = 0; i < current.rules.length; i++) have[ruleLabel(current.rules[i]).toLowerCase()] = true

  var incoming = resolveImported(imported, browsers)
  var count = 0
  for (var j = 0; j < incoming.length; j++) {
    if (!have[ruleLabel(incoming[j]).toLowerCase()]) count++
  }
  return count
}

// Merge an imported rules.toml into an existing config. Imported rules land
// first and in file order, because mclovin's router is also first-match-wins and
// the user already ordered them specific-to-general.
function mergeImported(config, imported, browsers) {
  var next = normalizeConfig(config)
  var incoming = resolveImported(imported, browsers)

  var seen = {}
  for (var j = 0; j < incoming.length; j++) seen[ruleLabel(incoming[j]).toLowerCase()] = true

  var kept = []
  for (var k = 0; k < next.rules.length; k++) {
    if (!seen[ruleLabel(next.rules[k]).toLowerCase()]) kept.push(next.rules[k])
  }

  next.rules = incoming.concat(kept)

  // `fallback_browser` is deliberately NOT imported. In the CLI it is an
  // emergency backstop used only when the picker cannot open; here it means
  // "route there instead of asking". Copying the value across would read as
  // the same setting and silently switch the picker off for every unmatched
  // link. The shim already covers the CLI's meaning.
  return next
}

// ---------------------------------------------------------------------- stats

function emptyStats(today) {
  return { date: String(today || ""), count: 0, byBrowser: {}, lastRule: "", lastUrl: "", lastBrowser: "", lastAt: "" }
}

function normalizeStats(raw, today) {
  var parsed = raw
  if (typeof raw === "string") {
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
  }
  if (!parsed || typeof parsed !== "object") return emptyStats(today)
  // A stale day is reset rather than accumulated: "today" is the only window
  // the widget ever shows, so carrying yesterday's count forward would lie.
  if (String(parsed.date || "") !== String(today || "")) return emptyStats(today)
  return {
    date: String(parsed.date || ""),
    count: Number(parsed.count) || 0,
    byBrowser: (parsed.byBrowser && typeof parsed.byBrowser === "object") ? parsed.byBrowser : {},
    lastRule: String(parsed.lastRule || ""),
    lastUrl: String(parsed.lastUrl || ""),
    lastBrowser: String(parsed.lastBrowser || ""),
    lastAt: String(parsed.lastAt || "")
  }
}

function recordRoute(stats, today, browserName, ruleLabel, url, at) {
  var next = normalizeStats(stats, today)
  next.date = String(today || "")
  next.count = next.count + 1
  var key = String(browserName || "unknown")
  next.byBrowser[key] = (Number(next.byBrowser[key]) || 0) + 1
  next.lastRule = String(ruleLabel || "")
  next.lastUrl = String(url || "")
  next.lastBrowser = key
  next.lastAt = String(at || "")
  return next
}

function browserBreakdown(stats) {
  var out = []
  var by = (stats && stats.byBrowser) || {}
  for (var name in by) out.push({ name: name, count: Number(by[name]) || 0 })
  out.sort(function(a, b) { return b.count - a.count })
  return out
}
