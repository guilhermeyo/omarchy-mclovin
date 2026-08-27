import QtQuick
import QtTest
import "../Router.js" as Router

TestCase {
  name: "ZoomDirectRouting"

  function test_preset_is_a_portable_builtin_action() {
    var rule = Router.zoomPresetRule()

    compare(rule.when, Router.WHEN_REGEX)
    compare(rule.action, Router.ACTION_ZOOM)
    compare(rule.terms.length, 1)
    compare(Router.ruleTargetLabel(rule), "Zoom directly")
    verify(rule.command === undefined)
    verify(rule.browser === undefined)
  }

  function test_preset_matches_numbered_zoom_meetings() {
    var rule = Router.zoomPresetRule()
    var matches = [
      "https://zoom.us/j/123456789",
      "https://us02web.zoom.us/w/123-456-789?pwd=secret",
      "https://app.zoom.us/wc/join/987654321?pwd=x%2By"
    ]

    for (var i = 0; i < matches.length; i++)
      verify(Router.ruleMatches(rule, Router.parseUrl(matches[i])), matches[i])
  }

  function test_preset_rejects_non_meeting_and_lookalike_urls() {
    var rule = Router.zoomPresetRule()
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

  function test_unknown_action_without_another_target_is_dropped() {
    var config = Router.normalizeConfig({
      rules: [{ when: "host", terms: ["example.com"], action: "unknown" }]
    })

    compare(config.rules.length, 0)
  }
}
