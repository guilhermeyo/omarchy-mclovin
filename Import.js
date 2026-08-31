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
    // The CLI's web app browser is this plugin's `webapp` key under another
    // name -- both answer "which browser opens a chromeless --app window". It
    // used to fall into the catch-all below and be dropped, leaving a migrant
    // on a key no screen writes, with nothing in it.
    if (line === "[webapp]" || line === "[webapp.browser]") {
      flush()
      section = (line === "[webapp]") ? "webapp" : "webapp.browser"
      continue
    }
    if (line.charAt(0) === "[") {
      // Any other table ends the current handler.
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
      else if (key === "browser") {
        var inline = parseInlineTable(value)
        if (!inline) current.browser = String(value)
        else if (inline.command) {
          // `command` plus its args, joined the way expandCommand tokenizes it.
          var argv = [String(inline.command)]
          var args = inline.args
          if (args && typeof args.length === "number" && typeof args !== "string") {
            for (var a = 0; a < args.length; a++) argv.push(String(args[a]))
          }
          current.command = argv.join(" ")
        } else if (inline.name) {
          current.browser = String(inline.name)
          if (inline.profile) current.profile = String(inline.profile)
        }
      }
      else if (key === "rewrite") current.rewrite = String(value)
      continue
    }
    if (section === "webapp" && key === "browser") out.webapp = String(value)
    if (section === "webapp.browser" && key === "name") out.webapp = String(value)
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
// Split on commas at depth 0 and outside quotes, so an `args = [...]` inside an
// inline table stays in one piece.
function splitInline(body) {
  var out = []
  var buf = ""
  var quote = ""
  var depth = 0
  for (var i = 0; i < body.length; i++) {
    var c = body.charAt(i)
    if (quote) { if (c === quote) quote = ""; buf += c; continue }
    if (c === "\"" || c === "'") { quote = c; buf += c; continue }
    if (c === "[" || c === "{") depth++
    if (c === "]" || c === "}") depth--
    if (c === "," && depth === 0) { if (buf.trim()) out.push(buf.trim()); buf = ""; continue }
    buf += c
  }
  if (buf.trim()) out.push(buf.trim())
  return out
}

// A TOML inline table, as the CLI writes a handler target:
//
//   browser = { command = "spotify", args = ["--uri={url}"] }
//   browser = { name = "Chromium", profile = "Work" }
//
// parseTomlValue understands quoted strings and arrays only, so the raw `{ … }`
// fragment was stored as a browser NAME -- producing a rule that matched links
// and could never launch, because no installed browser is called that.
//
// The command shape maps exactly onto this plugin's own `command` target:
// expandCommand substitutes {url}, which is the same placeholder the CLI writes.
function parseInlineTable(raw) {
  var text = String(raw || "").trim()
  if (text.charAt(0) !== "{" || text.charAt(text.length - 1) !== "}") return null

  var out = {}
  var parts = splitInline(text.slice(1, -1))
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq === -1) continue
    out[parts[i].slice(0, eq).trim()] = parseTomlValue(parts[i].slice(eq + 1))
  }
  return out
}

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

// The rules in the CLI's file that this config does not already carry, in file
// order. Compared on the matcher alone: a rule for the same pattern pointing
// somewhere else is an edit the user made here, not something to re-import.
//
// One function, because the panel's label and the import's effect have to be
// the same set. They were written twice and drifted: the count excluded rules
// whose matcher was already present, while the merge DROPPED those same rules
// from the config and replaced them with the CLI's version. The panel offered
// "Import 2 new rules" and quietly overwrote five edited ones.
function newRules(config, imported, browsers) {
  var current = Router.normalizeConfig(config)
  var have = {}
  for (var i = 0; i < current.rules.length; i++) have[Router.ruleKey(current.rules[i])] = true

  var incoming = resolveImported(imported, browsers)
  var out = []
  for (var j = 0; j < incoming.length; j++) {
    if (!have[Router.ruleKey(incoming[j])]) out.push(incoming[j])
  }
  return out
}

function countNewRules(config, imported, browsers) {
  return newRules(config, imported, browsers).length
}

// Merge an imported rules.toml into an existing config. Imported rules land
// first and in file order, because mclovin's router is also first-match-wins and
// the user already ordered them specific-to-general. Nothing already in the
// config is touched.
function mergeImported(config, imported, browsers) {
  var next = Router.normalizeConfig(config)
  next.rules = newRules(config, imported, browsers).concat(next.rules)

  // The CLI's web app browser, but never over one already set here, and never a
  // browser that is not installed -- an unresolvable value in this key is worse
  // than an empty one, because mclovin-open skips an empty key and moves to the
  // fallback while a wrong one it cannot resolve is skipped too, silently.
  if (!next.webapp && imported && imported.webapp) {
    var id = resolveBrowserId(browsers, imported.webapp)
    if (id) next.webapp = id
  }

  // `fallback_browser` is deliberately NOT imported. In the CLI it is an
  // emergency backstop used only when the picker cannot open; here it means
  // "route there instead of asking". Copying the value across would read as
  // the same setting and silently switch the picker off for every unmatched
  // link. The shim already covers the CLI's meaning.
  return next
}
