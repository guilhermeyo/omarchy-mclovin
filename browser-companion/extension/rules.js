(function (root) {
  "use strict";

  // The matchers from mclovin's Router.js, in the browser.
  //
  // Duplicated rather than shared because a content script cannot import the
  // plugin's QML-side JavaScript, and asking the native host on every click
  // would spawn a process per link. Kept deliberately small, and kept honest by
  // never being the deciding vote: mclovin re-reads its own rules and routes
  // the URL itself. A disagreement here costs a link that behaves normally
  // (missed) or one that takes a slower road to the same place (extra), never
  // a link that lands somewhere nobody asked for.

  function bareHost(value) {
    let v = String(value || "").trim().toLowerCase();
    const scheme = v.indexOf("://");
    if (scheme !== -1) {
      v = v.slice(scheme + 3);
      const cut = v.search(/[\/?#]/);
      if (cut !== -1) v = v.slice(0, cut);
    }
    const at = v.lastIndexOf("@");
    if (at !== -1) v = v.slice(at + 1);
    const colon = v.lastIndexOf(":");
    if (colon !== -1 && v.indexOf("]") === -1) v = v.slice(0, colon);
    return v.indexOf("www.") === 0 ? v.slice(4) : v;
  }

  // A prefix typed without a scheme still matches: people write
  // "github.com/acme" far more often than "https://github.com/acme".
  function matchesPrefix(url, term) {
    const u = url.toLowerCase();
    const t = term.toLowerCase();
    if (u.indexOf(t) === 0) return true;
    const scheme = u.indexOf("://");
    return scheme !== -1 && u.slice(scheme + 3).indexOf(t) === 0;
  }

  function termMatches(when, term, url, host) {
    switch (when) {
      case "startsWith": return matchesPrefix(url, term);
      case "host": return host === bareHost(term);
      case "regex":
        try { return new RegExp(term, "i").test(url); } catch (_) { return false; }
      default: return url.toLowerCase().indexOf(term.toLowerCase()) !== -1;
    }
  }

  // Whether any rule claims this link. Which rule, and where it sends the link,
  // is not the extension's business and never travels here.
  function isRouted(rules, raw, base) {
    let parsed;
    try {
      parsed = new URL(String(raw || ""), base);
    } catch (_) {
      return false;
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;

    const url = parsed.href;
    const host = bareHost(parsed.hostname);
    const list = Array.isArray(rules) ? rules : [];

    for (const rule of list) {
      if (!rule || !Array.isArray(rule.terms)) continue;
      for (const term of rule.terms) {
        if (term && termMatches(rule.when, String(term), url, host)) return parsed.href;
      }
    }
    return false;
  }

  const api = Object.freeze({ isRouted, bareHost, termMatches });
  root.McLovinRules = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(globalThis);
