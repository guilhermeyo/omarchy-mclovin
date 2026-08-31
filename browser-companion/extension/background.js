"use strict";

importScripts("zoom-links.js");

const HOST = "io.github.guilhermeyo.mclovin.zoom";

async function reportConnected() {
  try {
    await chrome.runtime.sendNativeMessage(HOST, {
      type: "status",
      version: chrome.runtime.getManifest().version,
    });
  } catch (_) {
    // The bridge may not be registered yet. The next browser start, extension
    // reload, or Zoom click tries again; ordinary browsing remains untouched.
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

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "openZoomDirectly") return false;

  const url = McLovinZoom.normalizedMeetingUrl(message.url);
  if (!url) {
    sendResponse({ ok: false, error: "not a Zoom meeting URL" });
    return false;
  }

  (async () => {
    try {
      const response = await chrome.runtime.sendNativeMessage(HOST, {
        type: "openZoomDirectly",
        url,
        version: chrome.runtime.getManifest().version,
      });
      if (!response || response.ok !== true)
        throw new Error(response && response.error || "mclovin did not open the link");
      sendResponse({ ok: true });
    } catch (error) {
      try {
        await browserFallback(sender, url, message.newTab === true);
      } finally {
        sendResponse({ ok: false, error: String(error && error.message || error) });
      }
    }
  })();

  return true;
});
