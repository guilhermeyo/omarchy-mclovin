# Chrome Web Store submission notes

## Single purpose

Open a numbered Zoom meeting link clicked on any website directly through the
user's local mclovin Zoom target, without leaving an otherwise disposable Zoom
landing tab open.

## Permission justifications

### Site access: `http://*/*` and `https://*/*`

A Zoom meeting link can appear in any calendar, chat, email, document, or other
website. The static content script therefore needs to observe link-click events
on all HTTP and HTTPS origins. It does not read or transmit page content. At the
moment of a trusted click, it reads only that anchor's destination and ignores
the event unless the URL is a validated numbered meeting on `zoom.us` or a real
subdomain.

### `nativeMessaging`

The extension must hand a validated Zoom HTTPS URL to the locally installed
mclovin bridge, which converts it to `zoommtg://` and launches the registered
handler. The service worker also sends an id/version handshake so the local
mclovin panel can report that setup succeeded. No other application or native
host is contacted.

## Data use disclosure

- No data is sold or used for advertising, credit, lending, or analytics.
- No authentication, financial, health, location, personal communication, web
  history, or user activity data is collected.
- No page content or meeting URL is retained.
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

1. Install mclovin and add its Zoom-direct preset.
2. Run `browser-companion/native/manage install chromium`.
3. Install the extension and confirm mclovin reports the handshake.
4. From a non-Zoom page, click an anchor whose destination is a numbered Zoom
   meeting URL and confirm the Zoom handler opens without a landing tab.
5. Confirm `https://zoom.us.evil.example/j/123456789`, non-HTTPS URLs, vanity
   rooms, account pages, and non-numeric meeting paths retain normal browser
   behaviour.
6. Make the native host unavailable and confirm the original HTTPS navigation
   is restored.
