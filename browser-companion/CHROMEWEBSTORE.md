# Chrome Web Store submission notes

## Single purpose

Open a link clicked on any website through the user's own local mclovin routing
rules, so a link destined for a desktop application or a web app reaches it
instead of opening a browser tab the user did not want.

## Permission justifications

### Site access: `http://*/*` and `https://*/*`

A link the user has a rule for can appear in any calendar, chat, email, document,
or other website. The static content script therefore needs to observe link-click
events on all HTTP and HTTPS origins. It does not read or transmit page content.
At the moment of a trusted click it reads only that anchor's destination, and
ignores the event unless the destination matches one of the user's own rules.

### `nativeMessaging`

The extension hands the matched link to the locally installed mclovin bridge,
which applies the user's rules and launches the registered handler. The service
worker also sends an id/version handshake, and receives in return the matchers it
should watch for. No other application or native host is contacted.

### `contextMenus`

A single item, **Open link with mclovin**, shown only on links. It gives the user
a way to route a link the automatic path deliberately leaves alone. It carries no
access to page content.

## Data use disclosure

- No data is sold or used for advertising, credit, lending, or analytics.
- No authentication, financial, health, location, personal communication, web
  history, or user activity data is collected.
- No page content or link is retained.
- Extension id, version, and last handshake time are stored locally only.
- There is no remote code and no extension-originated network request.

The public privacy text is in `PRIVACY.md`.

## Packaging

Package only the contents of `browser-companion/extension/`. Native files are
distributed with the Omarchy plugin, not in the Web Store archive.

The expected extension id is `nplmoglnnfadaifhkpkmimcbgmfakfec`, fixed by the
public manifest key. Verify this id in the Developer Dashboard before publishing
because the native host allows that exact origin without wildcards.

After a listing exists, set `STORE_URL` in `browser-companion/native/manage` to
the listing URL. The mclovin panel will then open the store instead of the
developer-mode extensions page, while native registration and status remain the
same.

## Review test

1. Install mclovin and add a rule whose destination is a web app or an
   application — its Zoom-direct preset is the quickest.
2. Run `browser-companion/native/manage install chromium`.
3. Install the extension and confirm mclovin reports the handshake.
4. From an unrelated page, click an anchor matching that rule and confirm the
   application opens without a landing tab.
5. Confirm a link matching no rule, a link matching a rule that names a browser,
   and non-HTTP schemes all retain normal browser behaviour.
6. Right-click any link, choose **Open link with mclovin**, and confirm it is
   routed even when the automatic path would have ignored it.
7. Make the native host unavailable and confirm the original navigation is
   restored.
