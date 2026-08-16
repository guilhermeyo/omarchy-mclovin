# mclovin — an Omarchy shell plugin

Choose which browser opens every link.

When you click a link, mclovin pops a picker in the middle of the screen listing
the browsers you actually have installed. Pick one and the link opens there. Tick
"always use this browser" and the choice becomes a rule, so the next link to that
host skips the picker entirely.

A bar widget shows whether mclovin is handling links, what it routed today, and
the rules you have built up.

Everything runs inside `omarchy-shell` as QML. There is no daemon, no compiled
binary, and no dependency on the [mclovin CLI](https://github.com/guilhermeyo/mclovin)
that shares the name.

## Requirements

- Omarchy Quattro (the Quickshell-based shell — `omarchy plugin list` should work)
- Nothing else

## Install

```bash
omarchy plugin add https://github.com/guilhermeyo/omarchy-mclovin.git --enable
```

That puts the bar widget on the right side of the bar. Click it, then click
**Make mclovin the default** to register mclovin as the system handler for
`http` and `https`.

Until you do that, the bar icon stays in the theme's urgent colour — links are
still opening, just not through mclovin.

## Using it

**The picker.** Any link that does not match a rule opens the picker.

| Key | Does |
|-----|------|
| type | filter the browser list |
| `↑` `↓` `Tab` | move |
| `Enter` | open the link in the highlighted browser |
| `Ctrl+R` | toggle "always use this browser for <host>" |
| `Esc` | clear the filter, then cancel |

Cancelling drops the link. Nothing opens.

**Rules.** Ticking the remember box writes a rule keyed on the host, minus any
`www.`. Rules match as a case-insensitive substring of the whole URL, so a
hand-written `github.com/acme` routes one organisation somewhere different from
the rest of GitHub. First match wins, and the list is in order.

Delete a rule from the bar widget's drop-down.

**Opening a browser with no link.** Right-click the bar icon, or use the
drop-down's **Open the picker**. Same window, no URL, picks just launch the
browser.

## Configuration

Rules live in `~/.config/omarchy-mclovin/config.json`. The plugin watches the
file, so editing it by hand takes effect immediately.

```json
{
  "version": 1,
  "fallback": "",
  "webapp": "",
  "rules": [
    { "match": "github.com/acme", "browser": "chromium", "profile": "Work" },
    { "match": ["example.com", "example.org"], "browser": "firefox" },
    { "match": "zoom.us", "command": "brave {url}" },
    { "matchRegex": "^https?://(\\w+)\\.internal\\.", "browser": "chromium" }
  ]
}
```

Matchers, first one that fits wins:

- `match` — case-insensitive substring of the URL. A string, or a list of them.
- `matchRegex` — case-insensitive regular expression, when substring is not
  enough.

Targets, one per rule:

- `browser` — a desktop entry id, with or without the `.desktop` suffix.
- `profile` — optional, alongside `browser`. Name it the way the browser's
  profile switcher does ("Work", not "Profile 3"); mclovin reads the mapping out
  of the browser's own `Local State`. Chromium-family gets
  `--profile-directory`, Firefox gets `-P`.
- `command` — a raw command line with `{url}` where the link goes, for anything
  that is not a plain browser.

And two settings:

- `fallback` — a browser to use when nothing matches, instead of showing the
  picker. Leave it empty to always ask.
- `webapp` — which browser gets `--app=` windows from `omarchy-launch-webapp`.
  Falls back to `fallback`, then to the first browser found. Webapps never open
  the picker.

## Importing from the mclovin CLI

If you have the [mclovin CLI](https://github.com/guilhermeyo/mclovin) with rules
in `~/.config/mclovin/rules.toml`, the drop-down offers **Import N rules from
the mclovin CLI**. It reads the TOML, resolves browser names to desktop entry
ids, and prepends the rules in file order — both routers are first-match-wins,
so the order you already tuned carries over. Profiles and `command =` rules come
across intact.

It is a one-shot copy, not a live binding. After importing, this plugin owns its
config and the CLI can go away.

Two things do not come across:

- **`rewrite` rules** are skipped. This plugin dispatches URLs, it does not
  transform them, and importing the match without the rewrite would send the
  right link to the right browser with the wrong address.
- **`fallback_browser`** is not imported. In the CLI it is an emergency backstop
  used only when the picker cannot open; here the same word means "route there
  instead of asking". Copying it would silently switch the picker off.

The offer disappears once there is nothing left to take.

Today's counters live in `~/.cache/omarchy-mclovin/stats.json` and reset at
midnight.

The bar widget has one setting, `showCount`, which puts today's link count next
to the icon. Set it in `~/.config/omarchy/shell.json` on the widget's entry.

## IPC

```bash
omarchy-shell mclovin open https://example.com   # route a URL
omarchy-shell mclovin status                     # JSON: handler, browsers, profiles, rules, today
omarchy-shell mclovin refresh                    # re-read browsers and the default handler
omarchy-shell mclovin importRules                # import from the CLI's rules.toml
omarchy-shell mclovin-bar toggle                 # open the bar drop-down (bind a key to this)
```

`open` answers `routed` when a rule took it, `asked` when the picker went up,
and `failed` when neither worked.

## How it hooks into the system

XDG requires an *executable on disk* to be the registered handler for
`x-scheme-handler/http`, and `omarchy-shell` is a process that is already
running — it cannot be the `Exec=` target. So **Make mclovin the default** writes
one desktop entry:

```
~/.local/share/applications/io.github.guilhermeyo.mclovin.desktop
```

pointing at `mclovin-open`, a ten-line shell script in this repo whose entire job
is to hand the URL to the shell over IPC. It then runs `xdg-mime default` for
both schemes.

If the shell is not running when a link is clicked, the script falls back to
launching your configured `fallback` browser directly, and failing that, the
first installed browser it finds. A link is never silently swallowed.

### Webapps

`omarchy-launch-webapp` calls the default browser as `<browser> --app=URL`, and
it only does that for browsers on a hard-coded whitelist — anything else it
replaces with `chromium.desktop`. mclovin's id is not on that list, so **webapps
open in Chromium unless you widen it**:

```bash
sudo sed -i 's/| mclovin\*)/| mclovin* | io.github.guilhermeyo.mclovin*)/' \
  "$(command -v omarchy-launch-webapp)"
```

The shim recognises `--app=` and hands it straight to the `webapp` browser from
your config without going near the picker. Note that an `omarchy update` will
restore the original whitelist.

## Uninstall

```bash
omarchy plugin remove io.github.guilhermeyo.mclovin
```

Point the system at a real browser again first, otherwise links have no handler:

```bash
xdg-mime default firefox.desktop x-scheme-handler/http x-scheme-handler/https
rm ~/.local/share/applications/io.github.guilhermeyo.mclovin.desktop
```

Your rules in `~/.config/omarchy-mclovin/` are left alone.

## Notes

- The picker lists every installed application that declares the `WebBrowser`
  desktop category. If you also have the mclovin CLI installed, it declares that
  category too and will appear in the list — routing to it hands the link to a
  second router rather than to a browser.
- Browsers are read from the shell's desktop entry index, so one installed
  mid-session shows up without a restart.

## Licence

MIT. See [LICENSE](LICENSE).
