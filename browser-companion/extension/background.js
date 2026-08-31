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

// The in-flight fetch, so the frames of one page share it.
//
// Every frame asks on load, and `if (cachedRules)` is only false until the
// first answer arrives -- so a page with a dozen iframes spawned a dozen
// native-host processes to compute the same list. Awaiting the promise instead
// of the value collapses them into one.
let rulesInFlight = null;

async function rules() {
  if (cachedRules) return cachedRules;
  if (rulesInFlight) return rulesInFlight;
  rulesInFlight = (async () => {
    try {
      return await fetchRules();
    } catch (_) {
      // The bridge may not be registered yet. Answer with nothing to watch, so
      // every page behaves as though the extension were not installed.
      return [];
    }
  })();
  try {
    cachedRules = await rulesInFlight;
  } finally {
    rulesInFlight = null;
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

// ------------------------------------------------------------ context menu
//
// The click interception deliberately leaves rules that name a browser alone: a
// link already headed for the browser you are reading in should navigate the
// tab, and only the browser can do that. This is the way to ask anyway, and it
// is not limited to watched rules — right-clicking a link and choosing mclovin
// is as explicit as a gesture gets, so it routes whatever was clicked. A link
// no rule claims reaches the picker, which is the honest answer to "let me
// choose where this goes".
const MENU_ID = "mclovin-open-link";

function createMenu() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID,
      title: "Open link with mclovin",
      contexts: ["link"],
      targetUrlPatterns: ["http://*/*", "https://*/*"],
    });
  });
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== MENU_ID || !info.linkUrl) return;
  try {
    const response = await chrome.runtime.sendNativeMessage(HOST, {
      type: "openUrl",
      url: info.linkUrl,
      version: chrome.runtime.getManifest().version,
    });
    if (!response || response.ok !== true)
      throw new Error((response && response.error) || "mclovin did not open the link");
  } catch (_) {
    // Nothing was cancelled here — the page never saw this gesture — so the
    // fallback opens a tab rather than replacing the one being read.
    await chrome.tabs.create({
      url: info.linkUrl,
      active: true,
      ...(tab && tab.id !== undefined ? { openerTabId: tab.id } : {}),
    });
  }
});

chrome.runtime.onInstalled.addListener(() => { createMenu(); reportConnected(); });
chrome.runtime.onStartup.addListener(() => { createMenu(); reportConnected(); });
reportConnected();

// The cache is refreshed by the handshake, which runs on install, on browser
// start, and every time the service worker wakes -- which is what happens after
// it has been idle, which is what happens between the rule being added and the
// next link being clicked.
//
// There used to be a chrome.runtime.onMessageExternal listener here claiming
// the panel drove invalidation. Nothing may send to this extension --
// externally_connectable is not declared -- so it could never fire, and the
// comment described a mechanism that did not exist.

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
