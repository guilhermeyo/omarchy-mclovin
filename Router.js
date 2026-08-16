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

// A rule matches when its pattern is a case-insensitive substring of the URL.
// Substring rather than exact-host so "github.com/acme" can route an org to a
// different profile than the rest of GitHub — the single most common thing
// people want from a URL router, and it needs no regex syntax to express.
function ruleMatches(rule, parsed) {
  var pattern = String((rule && rule.match) || "").trim().toLowerCase()
  if (!pattern) return false
  return parsed.url.toLowerCase().indexOf(pattern) !== -1
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
    var r = rules[i]
    if (!r || typeof r !== "object") continue
    var match = String(r.match || "").trim()
    var browser = String(r.browser || "").trim()
    if (!match || !browser) continue
    clean.push({ match: match, browser: browser })
  }

  return {
    version: CONFIG_VERSION,
    fallback: String(parsed.fallback || "").trim(),
    rules: clean
  }
}

// Replacing an existing rule for the same pattern rather than appending keeps
// "remember this" idempotent — picking a different browser for a host you
// already have a rule for updates it instead of adding a shadowed duplicate.
function upsertRule(config, match, browser) {
  var next = normalizeConfig(config)
  var pattern = String(match || "").trim()
  var target = String(browser || "").trim()
  if (!pattern || !target) return next

  for (var i = 0; i < next.rules.length; i++) {
    if (next.rules[i].match.toLowerCase() === pattern.toLowerCase()) {
      next.rules[i] = { match: pattern, browser: target }
      return next
    }
  }
  next.rules.push({ match: pattern, browser: target })
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
