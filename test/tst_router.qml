import QtQuick
import QtTest
import "../Router.js" as Router
import "../Import.js" as Import

TestCase {
  name: "ZoomDirectRouting"

  function test_preset_is_a_portable_builtin_action() {
    var preset = Router.rulePreset(Router.PRESET_ZOOM_MEETING)
    var rule = preset.rule

    compare(preset.id, Router.PRESET_ZOOM_MEETING)
    compare(preset.category, "Meetings")
    verify(preset.label.indexOf("Zoom") !== -1)
    verify(preset.description.length > 0)
    verify(preset.testUrl.indexOf("https://") === 0)
    compare(rule.when, Router.WHEN_REGEX)
    compare(rule.action, Router.ACTION_NATIVE)
    compare(rule.terms.length, 1)
    compare(Router.ruleTargetLabel(rule), "Its native app")
    verify(rule.command === undefined)
    verify(rule.browser === undefined)
  }

  function test_preset_library_drives_selector_options() {
    var presets = Router.rulePresets()
    var options = Router.rulePresetOptions()

    compare(options.length, presets.length + 1)
    compare(options[0].value, Router.PRESET_CUSTOM)
    compare(options[0].label, "Custom rule")
    for (var i = 0; i < presets.length; i++) {
      compare(options[i + 1].value, presets[i].id)
      compare(options[i + 1].label, presets[i].label)
    }
    verify(Router.rulePreset("not-a-preset") === null)
  }

  function test_preset_library_returns_editable_copies() {
    var first = Router.rulePreset(Router.PRESET_ZOOM_MEETING)
    first.rule.terms[0] = "changed"

    var second = Router.rulePreset(Router.PRESET_ZOOM_MEETING)
    compare(second.rule.terms[0], Router.ZOOM_MEETING_PATTERN)
  }

  function test_preset_matches_numbered_zoom_meetings() {
    var rule = Router.rulePreset(Router.PRESET_ZOOM_MEETING).rule
    var matches = [
      "https://zoom.us/j/123456789",
      "https://us02web.zoom.us/w/123-456-789?pwd=secret",
      "https://app.zoom.us/wc/join/987654321?pwd=x%2By"
    ]

    for (var i = 0; i < matches.length; i++)
      verify(Router.ruleMatches(rule, Router.parseUrl(matches[i])), matches[i])
  }

  function test_preset_rejects_non_meeting_and_lookalike_urls() {
    var rule = Router.rulePreset(Router.PRESET_ZOOM_MEETING).rule
    var misses = [
      "http://zoom.us/j/123456789",
      "https://zoom.us/my/team-room",
      "https://zoom.us/oauth/authorize",
      "https://zoom.us.evil.example/j/123456789",
      "https://example.com/zoom.us/j/123456789",
      "https://zoom.us/j/not-a-number"
    ]

    for (var i = 0; i < misses.length; i++)
      verify(!Router.ruleMatches(rule, Router.parseUrl(misses[i])), misses[i])
  }

  function test_config_round_trips_the_action() {
    var config = Router.normalizeConfig({
      rules: [{
        when: "host",
        terms: ["zoom.us"],
        action: "zoom"
      }]
    })

    compare(config.rules.length, 1)
    // Written under the old name, read back under the new one.
    compare(config.rules[0].action, Router.ACTION_NATIVE)
    compare(config.rules[0].terms[0], "zoom.us")
  }

  // The seventh parameter became an object when the web app destination landed
  // in the same slot this one uses. Both kinds have to survive it, and a rule
  // still has to be dropped when the object names nothing.
  function test_make_rule_takes_a_target_object() {
    var zoom = Router.makeRule(Router.WHEN_HOST, ["zoom.us"], "", "", "", false,
                               { action: Router.ACTION_NATIVE })
    compare(zoom.action, Router.ACTION_NATIVE)
    verify(zoom.webapp === undefined)
    verify(zoom.browser === undefined)

    var webapp = Router.makeRule(Router.WHEN_CONTAINS, ["whatsapp.com"], "", "", "", false,
                                 { webapp: "WhatsApp" })
    compare(webapp.webapp, "WhatsApp")
    verify(webapp.action === undefined)
    verify(webapp.browser === undefined)

    var browser = Router.makeRule(Router.WHEN_HOST, ["example.com"], "brave", "Work", "", true)
    compare(browser.browser, "brave")
    compare(browser.profile, "Work")
    compare(browser.private, true)

    verify(Router.makeRule(Router.WHEN_HOST, ["example.com"], "", "", "", false, {}) === null)
    verify(Router.makeRule(Router.WHEN_HOST, ["example.com"], "", "", "", false) === null)
  }

  function test_both_destinations_round_trip_together() {
    var config = Router.normalizeConfig({
      rules: [
        { when: "contains", terms: ["whatsapp.com"], webapp: "WhatsApp" },
        { when: "host", terms: ["zoom.us"], action: "zoom" }
      ]
    })

    compare(config.rules.length, 2)
    var reloaded = Router.normalizeConfig(JSON.stringify(config))
    compare(reloaded.rules.length, 2)

    var sawWebapp = false, sawAction = false
    for (var i = 0; i < reloaded.rules.length; i++) {
      if (reloaded.rules[i].webapp === "WhatsApp") sawWebapp = true
      if (reloaded.rules[i].action === Router.ACTION_NATIVE) sawAction = true
    }
    verify(sawWebapp)
    verify(sawAction)
  }

  // The panel's label and the import's effect have to be the same set. They were
  // written twice and drifted: the count excluded rules whose matcher the config
  // already carried, while the merge dropped exactly those and replaced them
  // with the CLI's version -- so "Import 1 new rule" silently overwrote an
  // edited one.
  //
  // Imported rules are written in the CLI's own shape (`match`, `matchRegex`,
  // a browser NAME), which is what resolveImported reads and Router migrates.
  // Handing these tests the normalised shape instead makes every rule resolve
  // to nothing and the assertions pass against an empty set.
  function test_import_adds_what_it_counted_and_touches_nothing_else() {
    var config = {
      rules: [
        // Same matcher the CLI has, pointed somewhere else on purpose: this is
        // an edit made here, and importing must not undo it.
        { when: "contains", terms: ["example.com"], browser: "brave-browser", profile: "Personal" },
        { when: "contains", terms: ["only-here"], browser: "brave-browser" },
      ],
    }
    var imported = {
      rules: [
        { match: ["example.com"], browser: "Chromium" },
        { match: ["from-the-cli"], browser: "Chromium" },
      ],
      fallback: "",
      skipped: 0,
    }
    var browsers = [{ id: "chromium", name: "Chromium" }, { id: "brave-browser", name: "Brave" }]

    compare(Import.countNewRules(config, imported, browsers), 1)

    var merged = Import.mergeImported(config, imported, browsers)
    compare(merged.rules.length, 3, "one added to the two that were already there")

    var byTerm = {}
    for (var i = 0; i < merged.rules.length; i++) byTerm[merged.rules[i].terms[0]] = merged.rules[i]

    // The edit survives, pointing where the user pointed it.
    compare(byTerm["example.com"].browser, "brave-browser")
    compare(byTerm["example.com"].profile, "Personal")
    // The untouched rule survives.
    verify(byTerm["only-here"] !== undefined)
    // And the genuinely new one arrived, resolved from its CLI browser name.
    compare(byTerm["from-the-cli"].browser, "chromium")
  }

  function test_importing_twice_changes_nothing_the_second_time() {
    var imported = {
      rules: [
        { match: ["example.com"], browser: "Chromium" },
        { match: ["second.example"], browser: "Chromium" },
      ],
      fallback: "",
      skipped: 0,
    }
    var browsers = [{ id: "chromium", name: "Chromium" }]

    // Non-vacuous on purpose: assert the first import actually brought both
    // rules across before asserting the second brings nothing.
    compare(Import.countNewRules({ rules: [] }, imported, browsers), 2)
    var once = Import.mergeImported({ rules: [] }, imported, browsers)
    compare(once.rules.length, 2)

    compare(Import.countNewRules(once, imported, browsers), 0)
    var twice = Import.mergeImported(once, imported, browsers)
    compare(twice.rules.length, 2)
  }

  // The CLI writes a handler target as an inline table. parseTomlValue reads
  // quoted strings and arrays only, so the raw `{ … }` fragment was stored as a
  // browser NAME -- a rule that matched links and could never launch, because no
  // installed browser is called that.
  function test_an_inline_table_target_becomes_a_real_destination() {
    var toml =
      "[[handler]]\n" +
      "match = [\"open.spotify.com\"]\n" +
      "browser = { command = \"spotify\", args = [\"--uri={url}\"] }\n" +
      "\n" +
      "[[handler]]\n" +
      "match = [\"docs.example\"]\n" +
      "browser = { name = \"Chromium\", profile = \"Work\" }\n" +
      "\n" +
      "[webapp]\n" +
      "browser = \"Chromium\"\n"

    var parsed = Import.parseMclovinToml(toml)
    compare(parsed.rules.length, 2)
    compare(parsed.rules[0].command, "spotify --uri={url}")
    compare(parsed.rules[1].browser, "Chromium")
    compare(parsed.rules[1].profile, "Work")
    compare(parsed.webapp, "Chromium")

    var browsers = [{ id: "chromium", name: "Chromium" }]
    var merged = Import.mergeImported({ rules: [] }, parsed, browsers)

    var byTerm = {}
    for (var i = 0; i < merged.rules.length; i++) byTerm[merged.rules[i].terms[0]] = merged.rules[i]

    // The command target is this plugin's own, with {url} intact -- the same
    // placeholder expandCommand substitutes.
    compare(byTerm["open.spotify.com"].command, "spotify --uri={url}")
    verify(byTerm["open.spotify.com"].browser === undefined)
    // And the browser shape keeps its profile.
    compare(byTerm["docs.example"].browser, "chromium")
    compare(byTerm["docs.example"].profile, "Work")
    // The CLI's web app browser comes across, resolved to an installed id.
    compare(merged.webapp, "chromium")
  }

  function test_an_existing_webapp_browser_is_never_overwritten() {
    var parsed = Import.parseMclovinToml("[webapp]\nbrowser = \"Chromium\"\n")
    var browsers = [{ id: "chromium", name: "Chromium" }, { id: "brave-browser", name: "Brave" }]
    var merged = Import.mergeImported({ rules: [], webapp: "brave-browser" }, parsed, browsers)
    compare(merged.webapp, "brave-browser")
  }

  // Scheme -> absolute path of a desktop entry. By path, because the id is not
  // unique: two files named Zoom.desktop claim zoommtg:// on an Omarchy with the
  // Zoom web app installed, and xdg-mime answers "Zoom.desktop" for either.
  function test_handlers_are_kept_by_scheme_and_absolute_path() {
    var config = Router.normalizeConfig({
      rules: [],
      handlers: {
        zoommtg: "/usr/share/applications/Zoom.desktop",
        ZoomUs: "/usr/share/applications/Zoom.desktop",
        relative: "applications/Zoom.desktop",
        "not a scheme": "/usr/share/applications/X.desktop",
        empty: "",
      },
    })

    compare(config.handlers.zoommtg, "/usr/share/applications/Zoom.desktop")
    // Schemes are case-insensitive, and stored lowercased.
    compare(config.handlers.zoomus, "/usr/share/applications/Zoom.desktop")
    // A relative path could never be launched, and a name that is not a scheme
    // could never be looked up. Neither is kept as a setting that cannot work.
    verify(config.handlers.relative === undefined)
    verify(config.handlers["not a scheme"] === undefined)
    verify(config.handlers.empty === undefined)

    // Survives a save and a reload.
    var reloaded = Router.normalizeConfig(JSON.stringify(config))
    compare(reloaded.handlers.zoommtg, "/usr/share/applications/Zoom.desktop")
  }

  function test_handlers_survive_a_config_with_none() {
    compare(JSON.stringify(Router.normalizeConfig({ rules: [] }).handlers), "{}")
    compare(JSON.stringify(Router.normalizeConfig(null).handlers), "{}")
  }

  // The destination is "a native app", not "Zoom". A list of destination KINDS
  // that names one site is wrong the moment a second site is added, and five of
  // six buttons are then wrong for any given rule.
  function test_the_native_action_does_not_name_a_site() {
    var rule = Router.makeRule(Router.WHEN_HOST, ["zoom.us"], "", "", "", false,
                               { action: Router.ACTION_NATIVE })
    compare(rule.action, "native")
    compare(Router.ruleTargetLabel(rule), "Its native app")

    // A rule saved when this was called "zoom" keeps working, and is written
    // back under the name that does not name a site.
    var migrated = Router.normalizeRule({ when: "host", terms: ["zoom.us"], action: "zoom" })
    compare(migrated.action, "native")
    verify(Router.isNativeAction("zoom"))
    verify(Router.isNativeAction("native"))
    verify(!Router.isNativeAction("teleport"))

    // And a config holding the old name round-trips to the new one.
    var config = Router.normalizeConfig({
      rules: [{ when: "host", terms: ["zoom.us"], action: "zoom" }],
    })
    compare(config.rules[0].action, "native")
  }

  // Which site a link belongs to is a table lookup, because nothing derives
  // zoommtg://…confno=1842 from zoom.us/j/1842 except knowing Zoom.
  function test_a_link_finds_its_native_app_or_none() {
    compare(Router.nativeAppFor("https://us02web.zoom.us/j/123456789").id, "zoom")
    compare(Router.nativeAppFor("https://zoom.us/wc/join/987").scheme, "zoommtg")
    verify(Router.nativeAppFor("https://zoom.us/my/team-room") === null)
    verify(Router.nativeAppFor("https://zoom.us.evil.example/j/1") === null)
    verify(Router.nativeAppFor("https://news.ycombinator.com/") === null)
    verify(Router.nativeAppFor("") === null)
  }

  // Every entry in the table needs a conversion in mclovin-open under the same
  // id, and the shim's own suite covers each conversion. If an id is added here
  // without one there, a rule saves and then opens nothing.
  function test_every_native_app_is_well_formed() {
    var apps = Router.nativeApps()
    verify(apps.length > 0)
    var seen = {}
    for (var i = 0; i < apps.length; i++) {
      var a = apps[i]
      verify(/^[a-z][a-z0-9-]*$/.test(a.id), "id: " + a.id)
      verify(/^[a-z][a-z0-9+.-]*$/.test(a.scheme), "scheme: " + a.scheme)
      verify(String(a.label).length > 0)
      verify(!seen[a.id], "duplicate id: " + a.id)
      seen[a.id] = true
      // The pattern has to compile, and has to be anchored at https -- an
      // unanchored one would claim links on any site that mentions this one.
      var re = new RegExp(a.pattern)
      verify(re.test !== undefined)
      compare(a.pattern.indexOf("^https://"), 0, "unanchored pattern: " + a.id)
    }
  }

  function test_unknown_action_without_another_target_is_dropped() {
    var config = Router.normalizeConfig({
      rules: [{ when: "host", terms: ["example.com"], action: "unknown" }]
    })

    compare(config.rules.length, 0)
  }
}
