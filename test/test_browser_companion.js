"use strict";

const assert = require("assert");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const extensionRoot = path.join(__dirname, "..", "browser-companion", "extension");
const zoom = require(path.join(extensionRoot, "zoom-links.js"));

const manifest = JSON.parse(fs.readFileSync(
  path.join(extensionRoot, "manifest.json"),
  "utf8",
));
const publicKey = Buffer.from(manifest.key, "base64");
const idHex = crypto.createHash("sha256").update(publicKey).digest("hex").slice(0, 32);
const extensionId = [...idHex]
  .map(character => String.fromCharCode("a".charCodeAt(0) + Number.parseInt(character, 16)))
  .join("");
assert.strictEqual(extensionId, "nplmoglnnfadaifhkpkmimcbgmfakfec");
assert.deepStrictEqual(
  fs.readdirSync(extensionRoot).sort(),
  ["background.js", "content.js", "manifest.json", "zoom-links.js"],
  "the loadable extension directory must contain browser files only",
);

const accepted = [
  "https://zoom.us/j/123456789",
  "https://us02web.zoom.us/w/123-456-789?pwd=secret",
  "https://app.zoom.us/wc/join/987654321?pwd=x%2By",
  "HTTPS://APP.ZOOM.US/j/111222333",
];

const rejected = [
  "http://zoom.us/j/123456789",
  "https://zoom.us/my/team-room",
  "https://zoom.us/oauth/authorize",
  "https://zoom.us.evil.example/j/123456789",
  "https://example.com/zoom.us/j/123456789",
  "https://zoom.us/j/not-a-number",
  "https://user@zoom.us/j/123456789",
  "https://zoom.us:8443/j/123456789",
];

for (const url of accepted)
  assert.ok(zoom.normalizedMeetingUrl(url), `should accept ${url}`);
for (const url of rejected)
  assert.strictEqual(zoom.normalizedMeetingUrl(url), "", `should reject ${url}`);

assert.strictEqual(
  zoom.normalizedMeetingUrl("/j/123456789?pwd=secret", "https://us02web.zoom.us/calendar"),
  "https://us02web.zoom.us/j/123456789?pwd=secret",
);

async function testBackgroundBridge() {
  const nativeMessages = [];
  const tabUpdates = [];
  const tabCreates = [];
  const lifecycleListeners = {};
  let messageListener;
  let nativeFailure = null;

  const context = vm.createContext({
    URL,
    console,
    chrome: {
      runtime: {
        getManifest: () => ({ version: manifest.version }),
        sendNativeMessage: async (host, message) => {
          nativeMessages.push({ host, message });
          if (nativeFailure) throw nativeFailure;
          return { ok: true };
        },
        onInstalled: { addListener: listener => { lifecycleListeners.installed = listener; } },
        onStartup: { addListener: listener => { lifecycleListeners.startup = listener; } },
        onMessage: { addListener: listener => { messageListener = listener; } },
      },
      tabs: {
        create: async options => { tabCreates.push(options); },
        update: async (tabId, options) => { tabUpdates.push({ tabId, options }); },
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
  assert.ok(lifecycleListeners.installed);
  assert.ok(lifecycleListeners.startup);

  const response = await new Promise(resolve => {
    assert.strictEqual(messageListener(
      { type: "openZoomDirectly", url: "https://zoom.us/j/123456789" },
      { tab: { id: 7 } },
      resolve,
    ), true);
  });
  assert.strictEqual(response.ok, true);
  assert.strictEqual(nativeMessages.at(-1).message.type, "openZoomDirectly");
  assert.strictEqual(nativeMessages.at(-1).message.version, manifest.version);

  nativeFailure = new Error("host unavailable");
  const fallbackResponse = await new Promise(resolve => {
    messageListener(
      { type: "openZoomDirectly", url: "https://zoom.us/j/987654321" },
      { tab: { id: 11 } },
      resolve,
    );
  });
  assert.strictEqual(fallbackResponse.ok, false);
  assert.strictEqual(tabUpdates.length, 1);
  assert.strictEqual(tabUpdates[0].tabId, 11);
  assert.strictEqual(tabUpdates[0].options.url, "https://zoom.us/j/987654321");
  assert.deepStrictEqual(tabCreates, []);
}

testBackgroundBridge()
  .then(() => console.log("browser companion tests passed"))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
