(function (root) {
  "use strict";

  // This is deliberately narrower than "a URL containing zoom.us". Only an
  // HTTPS URL on Zoom's real domain with a numeric meeting path can become a
  // zoommtg:// join URI. Vanity rooms and Zoom account pages keep their normal
  // browser behaviour.
  const meetingPath = /^\/(?:j|w)\/[0-9][0-9-]*\/?$|^\/wc\/join\/[0-9][0-9-]*\/?$/;

  function normalizedMeetingUrl(raw, base) {
    let parsed;
    try {
      parsed = new URL(String(raw || ""), base);
    } catch (_) {
      return "";
    }

    const hostname = parsed.hostname.toLowerCase();
    const onZoom = hostname === "zoom.us" || hostname.endsWith(".zoom.us");
    if (parsed.protocol !== "https:" || !onZoom || parsed.username || parsed.password)
      return "";
    if (parsed.port && parsed.port !== "443") return "";
    if (!meetingPath.test(parsed.pathname)) return "";

    return parsed.href;
  }

  const api = Object.freeze({ normalizedMeetingUrl });
  root.McLovinZoom = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
