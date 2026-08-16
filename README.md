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

It lists one row per **browser profile**, not per browser: three Chromium
profiles are three rows, and a browser with no profiles is a single row. Picking
"Chromium" when three profiles exist would just reopen whichever was last used,
which is not a choice.

```
 Brave            44
 Chromium         Work
 Chromium         Design
 Firefox          Personal
 Google Chrome    Design
```

| Key | Does |
|-----|------|
| type | filter across browser name, profile name, and desktop id |
| `↑` `↓` `Tab` | move |
| `Enter` | open the link in the highlighted browser and profile |
| `Ctrl+R` | toggle "always use <browser · profile> for <host>" |
| `Esc` | clear the filter, then cancel |

Typing `sico` finds the Chromium profile named "Design". Cancelling
drops the link — nothing opens.

Profiles come from the browser itself: Chromium-family from `Local State`,
Firefox from `Profile Groups/*.sqlite` (Firefox 143+) and `profiles.ini` before
that. The SQLite read shells out to `sqlite3`; without it installed you lose the
Firefox profile rows and nothing else.

**Rules.** Ticking the remember box in the picker writes a rule for that host.
Everything else happens in the rule form, which is the bar widget's drop-down →
**Add rule**, or clicking any rule in the list to edit it.

## The rule form

Three questions, in order, with the answer to the third visible while you
answer the first two.

**When a link…** picks how the rule matches:

| | Catches | Good for |
|---|---|---|
| **Starts with** | the link begins with this | one section of a site — `github.com/acme/` |
| **Contains** | the text appears anywhere | a word — `invoice` |
| **Host is** | the link is on exactly this site, www or not | `example.com` |
| **Regex** | a case-insensitive pattern | the rest |

Regex lives behind the **advanced** link in the corner, so it is one click away
rather than in the way. A rule opened for editing that already uses one expands
it for you.

**+ Add another** gives the rule a second term, a third, and so on. Any one of
them matching is enough, so `example.com` and `example.org` live in one rule instead of
two.

**Open it in…** is either a browser — picked from the same browser·profile list
the picker shows, never a field you have to guess the spelling of — or a command
with `{url}` in it.

**Preview** is the part that makes the rest trustworthy:

- *"A link like https://github.com/acme/… would open in Chromium · Work."*
  Rewritten on every keystroke.
- A **Try a link…** box that says `matches` or `no match` against what you type.
  For regex rules this replaces the example, since there is no honest way to
  invent a URL from a pattern.
- A warning when an **earlier rule already catches the link**, naming it:
  *"Rule 1 (Contains github.com/acme) catches this link first, so this
  rule would never run for it. Move this rule up."*

`Ctrl+Enter` saves, `Esc` cancels. You never see the config file.

## When two rules catch the same link

The narrower one wins. There is no order to manage.

"Narrower" is measured as how much of the link a rule pins down — essentially
the length of the text it constrains, with a point of credit for being anchored:

| Matcher | Counts as |
|---|---|
| `Host is` | length of the host, +1 for being exact rather than a substring |
| `Starts with` | length of the prefix, +1 for being anchored |
| `Contains` | length of the text |
| `Regex` | its literal characters only — metacharacters describe what a pattern *accepts*, not what it pins down |

So `Contains github.com/acme` (24) beats `Contains github.com` (10)
without anyone dragging anything, which is the case that actually comes up.

Ranking by matcher kind instead would get that backwards: `Host is github.com`
constrains ten characters, while a `Contains` rule naming an organisation inside
that host constrains twenty-four and is plainly the more specific rule.

A rule with several terms is only as narrow as its widest one, since any of them
can match. Exact ties keep the order the rules were written in.

The list is shown and stored narrowest-first, which is the order they are tried,
so the panel and the file always read the same way.

**Opening a browser with no link.** Right-click the bar icon, or use the
drop-down's **Open the picker**. Same window, no URL, picks just launch the
browser.

## Configuration

Rules live in `~/.config/omarchy-mclovin/config.json`. The plugin watches the
file, so editing it by hand takes effect immediately.

The form writes this for you; it is documented because the file is yours and
editing it by hand still works — the plugin watches it and reloads.

```json
{
  "version": 1,
  "fallback": "",
  "webapp": "",
  "rules": [
    { "when": "startsWith", "terms": ["github.com/acme"], "browser": "chromium", "profile": "Work" },
    { "when": "host", "terms": ["example.com", "example.org"], "browser": "firefox" },
    { "when": "contains", "terms": ["zoom.us"], "command": "brave {url}" },
    { "when": "regex", "terms": ["^https?://(\\w+)\\.internal\\."], "browser": "chromium" }
  ]
}
```

Matchers, narrowest rule wins:

- `when` — `startsWith`, `contains`, `host`, or `regex`.
- `terms` — one or more; any of them matching is enough.

The older shape (`match` as a string or array, `matchRegex` for patterns) is
still read and is migrated to the above the next time anything is saved.

Targets, one per rule:

- `browser` — a desktop entry id, with or without the `.desktop` suffix.
- `profile` — optional, alongside `browser`. Name it the way the browser's
  profile switcher does ("Work", not "Profile 3"); mclovin resolves the mapping
  itself. Chromium-family gets `--profile-directory`, Firefox gets `--profile`
  with the profile's path, or `-P` for the older named profiles.
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
the mclovin CLI**. It reads the TOML and resolves browser names to desktop entry
ids. Profiles and `command =` rules come across intact.

The CLI is first-match-wins and this plugin is narrowest-wins, so the imported
rules get re-ranked rather than keeping their file positions. For the ordering
people actually write — the specific rule above the general one — that lands on
the same answer. A pair where the *wider* rule was deliberately first is the
exception, and the form's preview will show it opening somewhere new.

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
omarchy-shell mclovin becomeDefault              # register as the http/https handler
omarchy-shell mclovin restoreDefault firefox     # hand the handler back to a real browser
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
omarchy-shell mclovin restoreDefault firefox      # while the plugin is still loaded
# or, once it is gone:
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
