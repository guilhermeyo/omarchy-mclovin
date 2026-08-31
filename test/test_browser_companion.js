"use strict";

const assert = require("assert");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const extensionRoot = path.join(__dirname, "..", "browser-companion", "extension");
const rules = require(path.join(extensionRoot, "rules.js"));

const manifest = JSON.parse(fs.readFileSync(
  path.join(extensionRoot, "manifest.json"),
  "utf8",
));

// The id the native host allowlists is derived from the manifest key. If the key
// ever changes without the host changing with it, the companion silently stops
// being allowed to talk, and this is the only place that would say so.
const publicKey = Buffer.from(manifest.key, "base64");
const idHex = crypto.createHash("sha256").update(publicKey).digest("hex").slice(0, 32);
const extensionId = [...idHex]
  .map(character => String.fromCharCode("a".charCodeAt(0) + Number.parseInt(character, 16)))
  .join("");
assert.strictEqual(extensionId, "nplmoglnnfadaifhkpkmimcbgmfakfec");

assert.deepStrictEqual(
  fs.readdirSync(extensionRoot).sort(),
  ["background.js", "content.js", "icons", "manifest.json", "rules.js"],
  "the loadable extension directory must contain browser files only",
);

// ------------------------------------------------------------------ matching
//
// The rules the native host serves carry a matcher and nothing else. Where a
// link ends up is mclovin's decision and never travels to the browser.

const watched = [
  { when: "contains", terms: ["whatsapp.com", "wa.me"] },
  { when: "regex", terms: ["^https://([a-z0-9-]+\\.)*zoom\\.us/(j|w|wc/join)/[0-9-]+(?:[/?#]|$)"] },
  { when: "host", terms: ["open.spotify.com"] },
  { when: "startsWith", terms: ["github.com/acme"] },
];

const claimed = [
  "https://web.whatsapp.com/send?phone=5511999999999",
  "https://wa.me/5511999999999?text=hello",
  "https://us02web.zoom.us/j/123456789?pwd=secret",
  "https://open.spotify.com/track/abc",
  "https://www.open.spotify.com/track/abc",
  "https://github.com/acme/app/issues/1",
];

const untouched = [
  "https://zoom.us/my/team-room",
  "https://zoom.us.evil.example/j/123456789",
  "https://notopen.spotify.com/track/abc",
  "https://github.com/someone-else/app",
  "https://news.ycombinator.com/",
  "mailto:someone@example.com",
  "javascript:alert(1)",
  "file:///etc/passwd",
  "",
];

for (const url of claimed)
  assert.ok(rules.isRouted(watched, url), `should claim ${url}`);
for (const url of untouched)
  assert.strictEqual(rules.isRouted(watched, url), false, `should ignore ${url}`);

// Nothing to watch is the state every browser starts in, and the state it keeps
// forever if the bridge is not registered. It must never intercept anything.
assert.strictEqual(rules.isRouted([], "https://wa.me/1"), false);
assert.strictEqual(rules.isRouted(null, "https://wa.me/1"), false);
assert.strictEqual(rules.isRouted(undefined, "https://wa.me/1"), false);

// A rule written by hand can hold anything. A pattern that does not compile is
// a rule that matches nothing, not an exception on every click.
assert.strictEqual(rules.isRouted([{ when: "regex", terms: ["("] }], "https://x.com/"), false);
assert.strictEqual(rules.isRouted([{ when: "contains" }], "https://x.com/"), false);
assert.strictEqual(rules.isRouted([null, undefined], "https://x.com/"), false);

// Relative hrefs are resolved against the page, the way the browser would.
assert.strictEqual(
  rules.isRouted(watched, "/j/123456789?pwd=secret", "https://us02web.zoom.us/calendar"),
  "https://us02web.zoom.us/j/123456789?pwd=secret",
);

// ------------------------------------------------------------------ bridge

async function testBackgroundBridge() {
  const nativeMessages = [];
  const tabUpdates = [];
  const tabCreates = [];
  const lifecycleListeners = {};
  let messageListener;
  let menuListener;
  const menuItems = [];
  let nativeFailure = null;
  let tabFailure = null;

  const context = vm.createContext({
    URL,
    console,
    chrome: {
      runtime: {
        getManifest: () => ({ version: manifest.version }),
        sendNativeMessage: async (host, message) => {
          nativeMessages.push({ host, message });
          if (nativeFailure) throw nativeFailure;
          return { ok: true, rules: watched };
        },
        onInstalled: { addListener: listener => { lifecycleListeners.installed = listener; } },
        onStartup: { addListener: listener => { lifecycleListeners.startup = listener; } },
        onMessage: { addListener: listener => { messageListener = listener; } },
        onMessageExternal: { addListener: () => {} },
      },
      contextMenus: {
        removeAll: done => { done(); },
        create: options => { menuItems.push(options); },
        onClicked: { addListener: listener => { menuListener = listener; } },
      },
      tabs: {
        create: async options => { if (tabFailure) throw tabFailure; tabCreates.push(options); },
        update: async (tabId, options) => {
          if (tabFailure) throw tabFailure;
          tabUpdates.push({ tabId, options });
        },
      },
    },
  });
  context.importScripts = file => vm.runInContext(
    fs.readFileSync(path.join(extensionRoot, file), "utf8"),
    context,
  );

  vm.runInContext(fs.readFileSync(path.join(extensionRoot, "background.js"), "utf8"), context);
  await new Promise(resolve => setImmediate(resolve));
  assert.strictEqual(nativeMessages[0].message.type, "status");
  assert.strictEqual(nativeMessages[0].message.version, manifest.version);
  assert.strictEqual(nativeMessages[0].host, "io.github.guilhermeyo.mclovin");
  assert.ok(lifecycleListeners.installed);
  assert.ok(lifecycleListeners.startup);
  assert.ok(menuListener, "the context menu must be wired before any click");

  const ask = (message, sender) => new Promise(resolve => {
    assert.strictEqual(messageListener(message, sender, resolve), true);
  });

  // The handshake already carried the rules, so a page asking for them costs no
  // second process.
  const before = nativeMessages.length;
  const served = await ask({ type: "rules" }, {});
  assert.deepStrictEqual(served.rules, watched);
  assert.strictEqual(nativeMessages.length, before, "rules must come from the handshake cache");

  const routed = await ask(
    { type: "openUrl", url: "https://wa.me/5511999999999" },
    { tab: { id: 7 } },
  );
  assert.strictEqual(routed.ok, true);
  assert.strictEqual(nativeMessages.at(-1).message.type, "openUrl");
  assert.strictEqual(nativeMessages.at(-1).message.url, "https://wa.me/5511999999999");
  assert.deepStrictEqual(tabUpdates, []);

  // Bridge down: the service worker navigates the tab itself, and reports the
  // click as handled. Saying otherwise makes the content script navigate a
  // second time to the place it just went.
  nativeFailure = new Error("host unavailable");
  const fellBack = await ask(
    { type: "openUrl", url: "https://wa.me/987654321" },
    { tab: { id: 11 } },
  );
  assert.strictEqual(fellBack.ok, true);
  assert.strictEqual(fellBack.viaBrowser, true);
  assert.strictEqual(tabUpdates.length, 1);
  assert.strictEqual(tabUpdates[0].tabId, 11);
  assert.strictEqual(tabUpdates[0].options.url, "https://wa.me/987654321");
  assert.deepStrictEqual(tabCreates, []);

  // A middle click or target=_blank opens a tab rather than replacing one.
  const newTab = await ask(
    { type: "openUrl", url: "https://wa.me/555", newTab: true },
    { tab: { id: 11 } },
  );
  assert.strictEqual(newTab.ok, true);
  assert.strictEqual(tabCreates.length, 1);
  assert.strictEqual(tabCreates[0].url, "https://wa.me/555");
  assert.strictEqual(tabCreates[0].openerTabId, 11);

  // Both the bridge and the tab API gone. Only now is the click unhandled, and
  // only now may the content script navigate the page itself.
  tabFailure = new Error("no tab");
  const unhandled = await ask(
    { type: "openUrl", url: "https://wa.me/000" },
    { tab: { id: 11 } },
  );
  assert.strictEqual(unhandled.ok, false);

  // ------------------------------------------------------------ context menu
  //
  // The click interception leaves rules naming a browser alone. This is the way
  // to ask anyway, and it is not limited to watched rules: right-clicking a link
  // and choosing mclovin is as explicit as a gesture gets.
  tabFailure = null;
  nativeFailure = null;
  tabCreates.length = 0;

  lifecycleListeners.installed();
  assert.strictEqual(menuItems.length, 1, "one menu item, recreated rather than duplicated");
  assert.strictEqual(menuItems[0].title, "Open link with mclovin");
  // Spread first: arrays built inside the vm context carry that realm's
  // prototype, and deepStrictEqual compares prototypes.
  assert.deepStrictEqual([...menuItems[0].contexts], ["link"]);
  assert.deepStrictEqual([...menuItems[0].targetUrlPatterns], ["http://*/*", "https://*/*"]);

  // A link no rule claims still goes to mclovin, which is what the gesture
  // means. The click interception would have left this one alone.
  const beforeMenu = nativeMessages.length;
  await menuListener(
    { menuItemId: "mclovin-open-link", linkUrl: "https://github.com/acme/app" },
    { id: 3 },
  );
  assert.strictEqual(nativeMessages.length, beforeMenu + 1);
  assert.strictEqual(nativeMessages.at(-1).message.type, "openUrl");
  assert.strictEqual(nativeMessages.at(-1).message.url, "https://github.com/acme/app");
  assert.deepStrictEqual(tabCreates, []);

  // Another extension's menu item must not be answered.
  await menuListener(
    { menuItemId: "somebody-else", linkUrl: "https://example.test/" },
    { id: 3 },
  );
  assert.strictEqual(nativeMessages.length, beforeMenu + 1);

  // Bridge down. Nothing was cancelled here, so this opens a tab rather than
  // replacing the one being read.
  nativeFailure = new Error("host unavailable");
  await menuListener(
    { menuItemId: "mclovin-open-link", linkUrl: "https://example.test/x" },
    { id: 3 },
  );
  assert.strictEqual(tabCreates.length, 1);
  assert.strictEqual(tabCreates[0].url, "https://example.test/x");
  assert.strictEqual(tabCreates[0].openerTabId, 3);
}

testBackgroundBridge()
  .then(() => console.log("browser companion tests passed"))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
