# Browser companion

The companion catches numbered Zoom meeting links clicked inside a
Chromium-family browser. Those clicks normally stay inside the browser and
never reach mclovin's system HTTP handler.

It is optional. Desktop links already work through the built-in Zoom-direct
rule without it.

## Layout

Only `extension/` is loaded into Chromium:

```text
browser-companion/
├── extension/       Manifest V3 extension: manifest and JavaScript only
└── native/          local native-messaging host and lifecycle manager
```

Keeping native files outside the extension payload prevents Python caches,
installer files, or generated state from invalidating the unpacked extension
or entering a store package.

## Setup

The mclovin panel offers setup after a Zoom-direct rule exists. From a terminal,
the same action is:

```bash
./browser-companion/native/manage setup
```

With no Chrome Web Store URL configured, setup opens `chrome://extensions`.
Enable Developer mode, choose **Load unpacked**, and select the printed
`browser-companion/extension/` directory. Once loaded, the extension performs a
local handshake and the mclovin panel changes to **Ready**.

Lifecycle commands:

```bash
./browser-companion/native/manage install [chromium|chrome|brave|vivaldi|edge]
./browser-companion/native/manage status --json
./browser-companion/native/manage open
./browser-companion/native/manage uninstall [chromium|chrome|brave|vivaldi|edge]
```

`install` writes one native-host manifest per detected browser profile. The
manifest allows exactly the stable extension origin and points to the host by
absolute path, as Chromium requires. `uninstall` removes only those manifests
and mclovin's local companion status.

## Message flow

1. A content script listens for trusted `click` and `auxclick` events on HTTP
   and HTTPS pages.
2. It ignores everything except numeric Zoom meeting paths on `zoom.us` or a
   real subdomain.
3. The extension service worker validates the URL again and sends it through
   Chromium native messaging.
4. The native host validates the caller and URL a third time, then invokes
   `mclovin-open --zoom-direct`.
5. If any bridge step fails, the service worker restores the original browser
   navigation.

The native host also accepts a `status` handshake. It writes only extension id,
extension version, and last-seen time to
`~/.local/state/omarchy-mclovin/browser-companion.json`; no page or link history
is stored.

## Release identity

The manifest's public `key` fixes the extension id at:

```text
nplmoglnnfadaifhkpkmimcbgmfakfec
```

That exact origin is duplicated in the two native scripts and covered by tests.
Use the manifest as-is when creating the Chrome Web Store item and verify the
dashboard reports the same id before publishing. If the store publisher must
change the identity, update the manifest key, both native constants, and the id
assertion together before shipping.

For store metadata and review justifications, see
[`CHROMEWEBSTORE.md`](CHROMEWEBSTORE.md). The user-facing data policy is in
[`PRIVACY.md`](PRIVACY.md).
