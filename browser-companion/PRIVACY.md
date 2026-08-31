# Browser companion privacy

The mclovin browser companion does not collect, sell, transmit, or use personal
data for advertising or analytics.

## What it can access

The extension runs a small isolated content script on HTTP and HTTPS pages so
it can catch a Zoom meeting link regardless of which calendar, chat, email, or
document contains it. The script does not scan page text, forms, cookies,
storage, browsing history, or network traffic. It examines the destination of a
link only when the user clicks it.

Only an HTTPS URL on `zoom.us` or a real `zoom.us` subdomain with a numbered
`/j/`, `/w/`, or `/wc/join/` meeting path is passed to the extension service
worker and local native host. Lookalike domains and non-meeting Zoom pages are
ignored.

## Local data

The native host stores this connection status locally:

- extension id;
- extension version;
- last successful handshake time.

It is stored at
`~/.local/state/omarchy-mclovin/browser-companion.json`. Meeting URLs and source
page URLs are not retained. Running `browser-companion/native/manage uninstall`
removes the status after the final native-host registration is removed.

## Network activity

The extension contains no remote code and makes no network requests of its own.
Chromium and Zoom continue to handle their normal browser and application
traffic. If the local Zoom launch fails, the original HTTPS meeting URL is
opened normally in the browser so the user's click is not lost.
