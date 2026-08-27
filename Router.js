.pragma library

// Pure routing logic: no QML types, no side effects. Everything here is
// callable from a plain JS test harness, which is why the file holds the URL
// parsing, rule matching, and Exec= expansion rather than Service.qml.

var CONFIG_VERSION = 1

// Built-in destinations do more than choose a browser. Keeping their stable
// ids in the rule instead of writing an installation-specific command path
// makes the config portable between machines and plugin locations.
var ACTION_ZOOM = "zoom"

// The ready-made Zoom rule only catches numbered meeting links on zoom.us or
// one of its subdomains. The launcher validates the URL again before turning it
// into a zoommtg:// URI; this pattern is the routing/preview half, not the trust
// boundary.
var ZOOM_MEETING_PATTERN = "^https://([a-z0-9-]+\\.)*zoom\\.us/(j|w|wc/join)/[0-9-]+(?:[/?#]|$)"

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

  // Path only, without query or fragment: those identify one page, and no rule
  // anyone writes by hand is about one page.
  var afterAuthority = rest.slice(authority.length)
  var path = afterAuthority
  for (var j = 0; j < afterAuthority.length; j++) {
    var pc = afterAuthority.charAt(j)
    if (pc === "?" || pc === "#") { path = afterAuthority.slice(0, j); break }
  }

  var host = authority.toLowerCase()
  return {
    url: url,
    scheme: scheme,
    host: host,
    path: path,
    // www. is noise for both display and rule matching — nobody wants one rule
    // for www.github.com and another for github.com.
    domain: host.indexOf("www.") === 0 ? host.slice(4) : host
  }
}

// What the picker's "Path" chip suggests: the place a link lives rather than
// the link itself. https://github.com/acme/app/issues/1842 is about a project,
// so the useful prefix is https://github.com/acme/app — the first couple of
// segments, stopping at anything that looks like an id.
function pathPrefix(parsed, maxSegments) {
  var host = parsed.domain || parsed.host
  if (!host) return ""

  var max = maxSegments === undefined ? 2 : maxSegments
  var segments = String(parsed.path || "").split("/")
  var kept = []
  for (var i = 0; i < segments.length && kept.length < max; i++) {
    var segment = segments[i]
    if (!segment) continue
    if (/^\d+$/.test(segment)) break
    kept.push(segment)
  }

  var base = (parsed.scheme || "https") + "://" + host
  return kept.length ? base + "/" + kept.join("/") : base + "/"
}

// What the picker shows and what a remembered rule keys on. Falls back to the
// whole URL so a scheme-less or malformed link still reads as something.
function displayHost(parsed) {
  return parsed.domain || parsed.url
}

// ------------------------------------------------------------- rule matching
//
// A rule is a matcher kind plus a list of terms. Four kinds, because those are
// the four things people actually mean when they say "send this somewhere":
//
//   startsWith  the link begins with this prefix   https://github.com/acme/
//   contains    this text appears anywhere in it   invoice
//   host        the site is exactly this host      example.com
//   regex       for the two per cent who need it
//
// Terms are OR'd: one rule can carry example.com and example.org.
//
// The older shape — `match` as a string or array, `matchRegex` for the escape
// hatch — is still read and migrated on load, so configs written before the
// form existed keep working and get upgraded on the next save.

var WHEN_STARTS_WITH = "startsWith"
var WHEN_CONTAINS = "contains"
var WHEN_HOST = "host"
var WHEN_REGEX = "regex"

function isWhen(value) {
  return value === WHEN_STARTS_WITH || value === WHEN_CONTAINS
    || value === WHEN_HOST || value === WHEN_REGEX
}

// A list that came from the config parse is a real JS array. The same list read
// back after it has crossed into QML is array-LIKE: it indexes and has .length,
// but Array.isArray() says false and String() flattens it to "a,b". Every place
// that asks "is this a list?" has to ask by shape, because the answer by type
// depends on which side of the boundary the value last touched.
//
// This has bitten three times: desktop entry categories, and rule terms, where
// a two-term rule silently became one term with a comma in it and matched
// nothing. The two callers below are worse — see their own comments.
function asArray(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object" && typeof value.length === "number") return value
  return null
}

function termList(terms) {
  var out = []
  var list = asArray(terms) || [terms]

  for (var i = 0; i < list.length; i++) {
    var v = String(list[i] === undefined || list[i] === null ? "" : list[i]).trim()
    if (v) out.push(v)
  }
  return out
}

// www is noise on both sides of a host comparison.
function bareHost(value) {
  var v = String(value || "").trim().toLowerCase()
  if (v.indexOf("://") !== -1) v = parseUrl(v).host
  return v.indexOf("www.") === 0 ? v.slice(4) : v
}

// A prefix typed without a scheme should still match: people write
// "github.com/acme" far more often than "https://github.com/acme".
function matchesPrefix(url, term) {
  var u = url.toLowerCase()
  var t = term.toLowerCase()
  if (u.indexOf(t) === 0) return true
  var schemeEnd = u.indexOf("://")
  if (schemeEnd === -1) return false
  return u.slice(schemeEnd + 3).indexOf(t) === 0
}

function termMatches(when, term, parsed) {
  switch (when) {
    case WHEN_STARTS_WITH:
      return matchesPrefix(parsed.url, term)
    case WHEN_HOST:
      return parsed.domain === bareHost(term)
    case WHEN_REGEX:
      try { return new RegExp(term, "i").test(parsed.url) } catch (e) { return false }
    default:
      return parsed.url.toLowerCase().indexOf(term.toLowerCase()) !== -1
  }
}

function ruleMatches(rule, parsed) {
  if (!rule) return false
  var terms = termList(rule.terms)
  for (var i = 0; i < terms.length; i++) {
    if (termMatches(rule.when, terms[i], parsed)) return true
  }
  return false
}

// Human wording for one matcher kind, used by the form's preview and by the
// rule rows in the bar drop-down. Reads as a sentence, not as a config key.
function whenLabel(when) {
  switch (when) {
    case WHEN_STARTS_WITH: return "Starts with"
    case WHEN_HOST: return "Host is"
    case WHEN_REGEX: return "Matches"
    default: return "Contains"
  }
}

// A single glyph for the rule list, where the matcher is context and the term
// is the content. Borrowed from where each symbol already means this: ^ anchors
// a prefix in regex, / delimits a pattern, @ prefixes a host, ~ is the
// "approximately/contains" operator in a dozen query languages.
function whenBadge(when) {
  switch (when) {
    case WHEN_STARTS_WITH: return "^"
    case WHEN_HOST: return "@"
    case WHEN_REGEX: return "/"
    default: return "~"
  }
}

// What the bar widget prints for a rule, and what upsert dedupes on.
function ruleLabel(rule) {
  if (!rule) return ""
  var terms = termList(rule.terms)
  if (rule.when === WHEN_REGEX) return "/" + terms.join("/ or /") + "/"
  return terms.join("  or  ")
}

// The compact form for the rule list: extra terms sit in the same cell behind a
// separator instead of repeating the matcher on a second row.
function ruleTerms(rule) {
  if (!rule) return ""
  return termList(rule.terms).join("  ·  ")
}

function ruleSummary(rule) {
  if (!rule) return ""
  return whenLabel(rule.when) + " " + ruleLabel(rule)
}

function ruleTargetLabel(rule) {
  if (!rule) return ""
  if (rule.action === ACTION_ZOOM) return "Zoom directly"
  if (rule.command) return rule.command
  if (rule.webapp) return String(rule.webapp).replace(/\.desktop$/, "")
  var target = String(rule.browser || "")
  return rule.profile ? target + " · " + rule.profile : target
}

// A link that would land on this rule, so the form can say "something like
// this" while the user is still typing. Synthesised from the first term: for a
// prefix that is already a URL it is the term itself plus a plausible path; for
// a bare word it is a URL with the word in it.
function exampleUrl(rule) {
  var terms = termList(rule && rule.terms)
  if (terms.length === 0) return ""
  var term = terms[0]

  switch (rule.when) {
    case WHEN_HOST:
      return "https://" + bareHost(term) + "/"
    case WHEN_STARTS_WITH:
      if (term.indexOf("://") !== -1) return term.replace(/\/+$/, "") + "/some/page"
      return "https://" + term.replace(/^\/+|\/+$/g, "") + "/some/page"
    case WHEN_REGEX:
      // No honest way to synthesise a URL from an arbitrary pattern; the test
      // field below it is the answer for regex rules.
      return ""
    default:
      if (term.indexOf("://") !== -1) return term
      // A term like "github.com/acme" is already most of a URL, and wrapping it
      // in example.com/ produces a link nobody would ever click. Detect that by
      // whether the part before the first slash looks like a host.
      var head = term.split("/")[0]
      if (head.indexOf(".") !== -1 && head.indexOf(" ") === -1)
        return "https://" + term.replace(/^\/+|\/+$/g, "") + "/…"
      return "https://example.com/" + term.replace(/^\/+/, "")
  }
}

// Which rule in the list actually wins for a URL. The form uses this to warn
// when an earlier rule already swallows the link being described — first match
// wins is easy to state and easy to forget.
function winningRuleIndex(rules, url) {
  var parsed = parseUrl(url)
  var list = rules || []
  for (var i = 0; i < list.length; i++) {
    if (ruleMatches(list[i], parsed)) return i
  }
  return -1
}

// ---------------------------------------------------------- specificity
//
// When two rules catch the same link, the narrower one wins. There is no
// user-managed order to get wrong.
//
// The measure is how much of the URL a rule pins down, which is essentially the
// length of the text it constrains. Ranking by matcher kind instead would be
// wrong in the common case: `Host is github.com` constrains ten characters,
// while `Contains github.com/acme` constrains fifteen and is
// obviously the narrower rule.
//
//   host        length of the host, +1 because it is an exact match rather
//               than a substring that happens to be the same length
//   startsWith  length of the prefix, +1 for being anchored
//   contains    length of the text
//   regex       length of its literal characters only — metacharacters
//               describe what the pattern accepts, not what it pins down
//
// Ties keep the order the rules were written in.

function regexLiteralLength(pattern) {
  var p = String(pattern || "")
  var count = 0
  for (var i = 0; i < p.length; i++) {
    var c = p.charAt(i)
    if (c === "\\") { i++; continue }
    if ("^$.|?*+()[]{}".indexOf(c) !== -1) continue
    count++
  }
  return count
}

function termSpecificity(when, term) {
  var t = String(term || "")
  switch (when) {
    case WHEN_HOST: return bareHost(t).length + 1
    case WHEN_STARTS_WITH: return t.length + 1
    case WHEN_REGEX: return regexLiteralLength(t)
    default: return t.length
  }
}

// A rule is as specific as its loosest term: any one of them can match, so the
// widest one is what the rule actually promises to catch.
function ruleSpecificity(rule) {
  var terms = termList(rule && rule.terms)
  if (terms.length === 0) return 0
  var lowest = -1
  for (var i = 0; i < terms.length; i++) {
    var score = termSpecificity(rule.when, terms[i])
    if (lowest === -1 || score < lowest) lowest = score
  }
  return lowest
}

// Narrowest first. The explicit index tiebreak keeps this deterministic without
// relying on the engine's sort being stable.
function sortBySpecificity(rules) {
  var decorated = []
  for (var i = 0; i < rules.length; i++) {
    decorated.push({ rule: rules[i], score: ruleSpecificity(rules[i]), index: i })
  }
  decorated.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    return a.index - b.index
  })
  var out = []
  for (var j = 0; j < decorated.length; j++) out.push(decorated[j].rule)
  return out
}

// The list is kept sorted on both read and write, so walking it in order and
// taking the first match *is* "most specific wins", and the file on disk reads
// in the same order the panel shows.
function firstMatch(rules, parsed) {
  // By shape: `rules` arrives straight off a QML property, so a type check here
  // would answer "not a list" and route every single link to the picker.
  var list = asArray(rules)
  if (!list) return null
  for (var i = 0; i < list.length; i++) {
    if (ruleMatches(list[i], parsed)) return list[i]
  }
  return null
}

function normalizeConfig(raw) {
  var parsed = raw
  if (typeof raw === "string") {
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
  }
  if (!parsed || typeof parsed !== "object") parsed = {}

  // By shape, and this one is the dangerous one: normalizeConfig is called with
  // the live config object from six places before writing it back to disk. A
  // type check that answered "not a list" would replace every rule with nothing
  // and then save that.
  var rules = asArray(parsed.rules) || []
  var clean = []
  for (var i = 0; i < rules.length; i++) {
    var r = normalizeRule(rules[i])
    if (r) clean.push(r)
  }

  clean = sortBySpecificity(clean)

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

// A rule needs somewhere to send the URL — a built-in action, an Omarchy web
// app, a desktop entry (optionally with a browser profile), or a raw command
// line containing {url}. Anything without a matcher or without a target is
// dropped rather than kept as a rule that can never fire.
function normalizeRule(raw) {
  if (!raw || typeof raw !== "object") return null

  var when = isWhen(raw.when) ? raw.when : ""
  var terms = termList(raw.terms)

  // Migrate the pre-form shape.
  if (!when) {
    var regex = String(raw.matchRegex || "").trim()
    if (regex) {
      when = WHEN_REGEX
      terms = [regex]
    } else {
      when = WHEN_CONTAINS
      if (terms.length === 0) terms = termList(raw.match)
    }
  }
  if (terms.length === 0) return null

  var out = { when: when, terms: terms }

  var action = String(raw.action || "").trim()
  var command = String(raw.command || "").trim()
  var webapp = String(raw.webapp || "").trim()
  var browser = String(raw.browser || "").trim()
  if (action === ACTION_ZOOM) {
    out.action = action
  } else if (command) {
    out.command = command
  } else if (webapp) {
    // A web app carries neither of the two modifiers a browser target takes: it
    // owns one window on one site, so there is no profile to pin, and no
    // Chromium `--app=` window has ever been an incognito one.
    out.webapp = webapp
  } else if (browser) {
    out.browser = browser
    var profile = String(raw.profile || "").trim()
    if (profile) out.profile = profile
    // Only meaningful next to a browser. A command rule already spells out how
    // it wants to be launched, and bolting --incognito onto an arbitrary
    // command line would be a guess.
    if (raw.private === true || String(raw.private) === "true") out.private = true
  } else {
    return null
  }

  return out
}

// The last parameter carries a destination that is neither a browser nor a
// command: `{ webapp }` for an Omarchy web app, `{ action }` for a built-in.
// One object rather than one positional argument each — the third and fourth
// kinds of destination arrived together, and a seventh, eighth and ninth
// positional string that every other call site has to pass as "" is how a
// signature stops being readable.
function makeRule(when, terms, browser, profile, command, wantPrivate, target) {
  return normalizeRule({
    when: when,
    terms: terms,
    browser: browser,
    profile: profile,
    command: command,
    webapp: (target || {}).webapp,
    action: (target || {}).action,
    private: wantPrivate === true
  })
}

// One click in the form produces the narrow rule users otherwise have to type
// as an advanced regular expression. It is still an ordinary editable rule in
// config; the preset only supplies the safe defaults.
function zoomPresetRule() {
  return makeRule(WHEN_REGEX, [ZOOM_MEETING_PATTERN], "", "", "", false, { action: ACTION_ZOOM })
}

// Replacing an existing rule for the same matcher rather than appending keeps
// "remember this" idempotent — picking a different browser for a host you
// already have a rule for updates it instead of adding a shadowed duplicate.
function upsertRule(config, when, term, browser, profile, wantPrivate, webapp) {
  var next = normalizeConfig(config)
  var candidate = makeRule(isWhen(when) ? when : WHEN_HOST, [term],
                           browser, profile, "", wantPrivate, { webapp: webapp })
  if (!candidate) return next
  return replaceOrAppend(next, candidate)
}

function replaceOrAppend(config, candidate) {
  var next = normalizeConfig(config)
  var key = ruleKey(candidate)
  for (var i = 0; i < next.rules.length; i++) {
    if (ruleKey(next.rules[i]) === key) {
      next.rules[i] = candidate
      return next
    }
  }
  next.rules.push(candidate)
  return next
}

// Two rules are "the same rule" when they select the same links, regardless of
// where they send them.
function ruleKey(rule) {
  if (!rule) return ""
  return String(rule.when) + "::" + termList(rule.terms).join(" ").toLowerCase()
}

// Editing in place, then letting normalizeConfig re-sort: a rule that becomes
// narrower moves up on its own, which is the whole point of dropping manual
// ordering.
function setRuleAt(config, index, rule) {
  var next = normalizeConfig(config)
  var candidate = normalizeRule(rule)
  if (!candidate) return next
  if (index < 0 || index >= next.rules.length) return replaceOrAppend(next, candidate)
  next.rules[index] = candidate
  return normalizeConfig(next)
}

function appendRule(config, rule) {
  var next = normalizeConfig(config)
  var candidate = normalizeRule(rule)
  if (!candidate) return next
  return replaceOrAppend(next, candidate)
}

function removeRuleAt(config, index) {
  var next = normalizeConfig(config)
  if (index < 0 || index >= next.rules.length) return next
  next.rules.splice(index, 1)
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
