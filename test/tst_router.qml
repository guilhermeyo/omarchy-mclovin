import QtQuick
import QtTest
import "../Router.js" as Router

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
    compare(rule.action, Router.ACTION_ZOOM)
    compare(rule.terms.length, 1)
    compare(Router.ruleTargetLabel(rule), "Zoom directly")
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
    compare(config.rules[0].action, Router.ACTION_ZOOM)
    compare(config.rules[0].terms[0], "zoom.us")
  }

  // The seventh parameter became an object when the web app destination landed
  // in the same slot this one uses. Both kinds have to survive it, and a rule
  // still has to be dropped when the object names nothing.
  function test_make_rule_takes_a_target_object() {
    var zoom = Router.makeRule(Router.WHEN_HOST, ["zoom.us"], "", "", "", false,
                               { action: Router.ACTION_ZOOM })
    compare(zoom.action, Router.ACTION_ZOOM)
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
      if (reloaded.rules[i].action === Router.ACTION_ZOOM) sawAction = true
    }
    verify(sawWebapp)
    verify(sawAction)
  }

  function test_unknown_action_without_another_target_is_dropped() {
    var config = Router.normalizeConfig({
      rules: [{ when: "host", terms: ["example.com"], action: "unknown" }]
    })

    compare(config.rules.length, 0)
  }
}
