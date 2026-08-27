(function () {
  "use strict";

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

  function interceptZoomClick(event) {
    if (!event.isTrusted || event.defaultPrevented) return;
    if (event.type === "click" && event.button !== 0) return;
    if (event.type === "auxclick" && event.button !== 1) return;

    const anchor = clickedAnchor(event);
    if (!anchor) return;

    const url = McLovinZoom.normalizedMeetingUrl(anchor.href, document.baseURI);
    if (!url) return;

    const newTab = wantsNewTab(event, anchor);
    event.preventDefault();
    event.stopImmediatePropagation();

    // The service worker performs the fallback while the extension is alive.
    // This catch covers the narrow reload/uninstall race where it is not.
    chrome.runtime.sendMessage({ type: "openZoomDirectly", url, newTab })
      .catch(() => normalBrowserFallback(url, newTab));
  }

  globalThis.addEventListener("click", interceptZoomClick, true);
  globalThis.addEventListener("auxclick", interceptZoomClick, true);
})();
