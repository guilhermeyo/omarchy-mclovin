.pragma library
.import "Router.js" as Router

// A one-shot reader for the mclovin CLI's rules.toml.
//
// Deliberately quarantined in its own file: it is a migration path, not part of
// how the plugin runs, and it is the only code here that will ever be deleted
// wholesale once nobody is coming from the CLI.

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
    var hasMatch = Router.termList(current.match).length > 0 || current.matchRegex
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
    var rule = Router.normalizeRule({
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
  var current = Router.normalizeConfig(config)
  var have = {}
  for (var i = 0; i < current.rules.length; i++) have[Router.ruleKey(current.rules[i])] = true

  var incoming = resolveImported(imported, browsers)
  var count = 0
  for (var j = 0; j < incoming.length; j++) {
    if (!have[Router.ruleKey(incoming[j])]) count++
  }
  return count
}

// Merge an imported rules.toml into an existing config. Imported rules land
// first and in file order, because mclovin's router is also first-match-wins and
// the user already ordered them specific-to-general.
function mergeImported(config, imported, browsers) {
  var next = Router.normalizeConfig(config)
  var incoming = resolveImported(imported, browsers)

  var seen = {}
  for (var j = 0; j < incoming.length; j++) seen[Router.ruleKey(incoming[j])] = true

  var kept = []
  for (var k = 0; k < next.rules.length; k++) {
    if (!seen[Router.ruleKey(next.rules[k])]) kept.push(next.rules[k])
  }

  next.rules = incoming.concat(kept)

  // `fallback_browser` is deliberately NOT imported. In the CLI it is an
  // emergency backstop used only when the picker cannot open; here it means
  // "route there instead of asking". Copying the value across would read as
  // the same setting and silently switch the picker off for every unmatched
  // link. The shim already covers the CLI's meaning.
  return next
}
