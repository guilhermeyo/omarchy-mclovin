# Browser companion privacy

The mclovin browser companion does not collect, sell, transmit, or use personal
data for advertising or analytics.

## What it can access

The extension runs a small isolated content script on every HTTP and HTTPS page.
That is the honest way to say it, and it is worth saying plainly: a link can
appear in any calendar, chat, email, or document, and catching the click where
it happens is the only place the decision still exists.

What the script does with that access is narrow. It does not scan page text,
forms, cookies, storage, browsing history, or network traffic, and it reads
nothing until a trusted click lands on a link. At that moment it looks at one
thing: that link's destination.

## What leaves the page

Only a link matching one of your own mclovin rules — and only the rules whose
destination leaves the browser, such as a web app or a desktop application. The
matchers for those rules are the only thing the extension is told; where a link
ends up is decided by mclovin on the other side and never travels into the
browser.

Every other link is untouched, including links matching a rule that names a
browser: those keep the browser's ordinary behaviour.

Choosing **Open link with mclovin** from the right-click menu sends that one
link regardless of any rule. That is an explicit request, and it is the only way
an unmatched link reaches mclovin.

## Local data

The native host stores this connection status locally:

- extension id;
- extension version;
- last successful handshake time.

It is stored at
`~/.local/state/omarchy-mclovin/browser-companion.json`. No link, meeting URL, or
source page URL is retained. Running `browser-companion/native/manage uninstall`
removes the status after the final native-host registration is removed.

## Network activity

The extension contains no remote code and makes no network requests of its own.
Chromium and the applications your rules point at continue to handle their normal
traffic. If the local bridge is unavailable, the original link is opened in the
browser as it would have been, so a click is never lost.
