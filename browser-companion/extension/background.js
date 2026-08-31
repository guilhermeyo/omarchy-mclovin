"use strict";

const HOST = "io.github.guilhermeyo.mclovin";

// Cached for the life of this service worker generation. A worker wake costs one
// native-host process, a click costs none. mclovin re-reads its own config on
// every route anyway, so a stale cache here only delays which links are watched,
// never where a watched link goes.
let cachedRules = null;

async function fetchRules() {
  const response = await chrome.runtime.sendNativeMessage(HOST, {
    type: "rules",
    version: chrome.runtime.getManifest().version,
  });
  return response && Array.isArray(response.rules) ? response.rules : [];
}

async function rules() {
  if (cachedRules) return cachedRules;
  try {
    cachedRules = await fetchRules();
  } catch (_) {
    // The bridge may not be registered yet. Answer with nothing to watch, so
    // every page behaves as though the extension were not installed.
    cachedRules = [];
  }
  return cachedRules;
}

async function reportConnected() {
  try {
    const response = await chrome.runtime.sendNativeMessage(HOST, {
      type: "status",
      version: chrome.runtime.getManifest().version,
    });
    if (response && Array.isArray(response.rules)) cachedRules = response.rules;
  } catch (_) {
    // Not registered yet. The next browser start, extension reload, or click
    // tries again; ordinary browsing remains untouched.
  }
}

async function browserFallback(sender, url, newTab) {
  const tabId = sender.tab && sender.tab.id;
  if (newTab || tabId === undefined) {
    const create = { url, active: true };
    if (tabId !== undefined) create.openerTabId = tabId;
    await chrome.tabs.create(create);
  } else {
    await chrome.tabs.update(tabId, { url });
  }
}

chrome.runtime.onInstalled.addListener(reportConnected);
chrome.runtime.onStartup.addListener(reportConnected);
reportConnected();

// mclovin's config changed under us, most likely because a rule was added. The
// panel drives this; there is nothing to poll.
chrome.runtime.onMessageExternal.addListener(() => { cachedRules = null; });

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return false;

  if (message.type === "rules") {
    rules().then((list) => sendResponse({ ok: true, rules: list }));
    return true;
  }

  if (message.type !== "openUrl") return false;

  (async () => {
    try {
      const response = await chrome.runtime.sendNativeMessage(HOST, {
        type: "openUrl",
        url: message.url,
        version: chrome.runtime.getManifest().version,
      });
      if (!response || response.ok !== true)
        throw new Error((response && response.error) || "mclovin did not open the link");
      sendResponse({ ok: true });
    } catch (error) {
      // `ok` answers "was the click handled", not "did mclovin handle it". The
      // content script cancelled the navigation before any of this ran, so a
      // fallback that worked is still a success -- and saying otherwise makes
      // the page navigate a second time to the place it just went.
      try {
        await browserFallback(sender, message.url, message.newTab === true);
        sendResponse({ ok: true, viaBrowser: true, error: String(error.message || error) });
      } catch (fallbackError) {
        sendResponse({ ok: false, error: String(fallbackError.message || fallbackError) });
      }
    }
  })();

  return true;
});
