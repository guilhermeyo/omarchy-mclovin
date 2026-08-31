(function () {
  "use strict";

  // Rules arrive from the service worker once per page. Until they do, and if
  // they never do, every click behaves exactly as it did before the extension
  // existed. Failing open is the whole safety story here: a companion that
  // cancels a navigation it then cannot complete is worse than no companion.
  let rules = null;

  chrome.runtime.sendMessage({ type: "rules" })
    .then((response) => { if (response && Array.isArray(response.rules)) rules = response.rules; })
    .catch(() => {});

  function clickedAnchor(event) {
    const path = typeof event.composedPath === "function" ? event.composedPath() : [];
    for (const node of path) {
      if (node && node.nodeType === Node.ELEMENT_NODE && node.matches("a[href]"))
        return node;
    }

    const target = event.target;
    return target && target.nodeType === Node.ELEMENT_NODE
      ? target.closest("a[href]")
      : null;
  }

  function wantsNewTab(event, anchor) {
    const target = String(anchor.target || "").toLowerCase();
    return event.type === "auxclick" || event.ctrlKey || event.metaKey || event.shiftKey
      || (target && target !== "_self" && target !== "_top" && target !== "_parent");
  }

  function normalBrowserFallback(url, newTab) {
    if (newTab) window.open(url, "_blank", "noopener");
    else window.location.assign(url);
  }

  function interceptClick(event) {
    if (!rules || rules.length === 0) return;
    if (!event.isTrusted || event.defaultPrevented) return;
    if (event.type === "click" && event.button !== 0) return;
    if (event.type === "auxclick" && event.button !== 1) return;

    const anchor = clickedAnchor(event);
    if (!anchor) return;

    const url = McLovinRules.isRouted(rules, anchor.href, document.baseURI);
    if (!url) return;

    const newTab = wantsNewTab(event, anchor);
    event.preventDefault();
    event.stopImmediatePropagation();

    chrome.runtime.sendMessage({ type: "openUrl", url, newTab })
      .then((response) => {
        // The service worker performs its own fallback and answers ok:false only
        // when that failed too. Navigating here is the last thing standing
        // between a cancelled click and a link that went nowhere.
        if (!response || response.ok !== true) normalBrowserFallback(url, newTab);
      })
      .catch(() => normalBrowserFallback(url, newTab));
  }

  globalThis.addEventListener("click", interceptClick, true);
  globalThis.addEventListener("auxclick", interceptClick, true);
})();
