# Working in this repository

Read this before changing anything. It is not style advice; it is the list of
things that have already gone wrong here, written down so they go wrong once.

## Common tasks

The rest of this file is what has gone wrong. This is what to do when nothing
has yet: the ordinary changes, with the files, the commands, and the check that
says it took. Every one of these was run before it was written down; where a
step could not be run against a throwaway copy it says so.

### Add a routing rule

"Make Figma links open in Chromium · Work."

For a person the answer is the rule form — bar widget → **Add rule**. Use it if
the shell is up, because the preview is the only thing that will tell you a
narrower rule already swallows the link. What follows is for a scripted change,
or for when the shell is not running.

Rules live in `~/.config/omarchy-mclovin/config.json`. `Service.qml` builds that
path from `$HOME` (`configDir: home + "/.config/omarchy-mclovin"`), not from
`XDG_CONFIG_HOME` — exporting the latter does not move it, which matters when
you try to sandbox this and find you are editing the real file.

Append to `rules`:

```json
{ "when": "host", "terms": ["figma.com"], "browser": "chromium", "profile": "Work" }
```

`browser` is a desktop entry id, `.desktop` optional. `profile` is the display
name the browser's own switcher shows. `Browsers.resolveProfileDirectory`
(`Browsers.js:214`, reached from `Service.qml:611`) matches that name against
the browser's `Local State` and maps it to the on-disk directory:

```sh
jq -r '.profile.info_cache | to_entries[] | "\(.key)\t\(.value.name)"' \
  ~/.config/chromium/'Local State'
```

The left column is the directory, the right column is what goes in the rule. A
directory name works too — the resolver falls back to it, deliberately, because
it is what someone hand-editing this file is most likely to have written — but
the display name is what the form writes and the one to prefer.

**The shell does not need restarting, and does not need `refresh`.** `configFile`
in `Service.qml` is a `FileView` with `watchChanges: true` and
`onFileChanged: reload()`. Measured on a running shell: with seven rules loaded,
writing an eighth into the file made the very next `status` call report eight —
no restart, no IPC call in between. Restoring the file dropped it back to seven
just as fast. `refresh` re-reads browsers, web apps, profiles, the scheme
handlers and the default handler, and re-polls the companion; the config
re-reads itself.

Confirm through the status IPC:

```sh
ID=io.github.guilhermeyo.mclovin
omarchy-shell $ID status | jq '.rules'
```

That count is the check that matters, because both ways of getting the file
wrong are silent:

- **Invalid JSON loses every rule.** `Router.normalizeConfig` parses inside a
  `try` and falls back to `{}` on failure. A trailing comma turns seven rules
  into zero and nothing anywhere says so — links simply start reaching the
  picker again. Verified: `normalizeConfig` on a config whose only defect is a
  trailing comma returns `0` rules.
- **A misspelled `when` is not rejected, it is migrated.** `normalizeRule` treats
  a rule with no valid `when` as the pre-form shape and gives it `contains`.
  Verified: `{"when":"hosts","terms":["figma.com"],…}` comes back as
  `{"when":"contains","terms":["figma.com"],…}`, which also catches
  `https://example.com/figma.com`. This is the same behaviour a test once pinned
  as the expectation — see "Prove a fix fails without itself".

The file keeps the order you wrote until something saves; the shell sorts
narrowest-first in memory and writes that order back on the next save. So do not
read the file's order as confirmation. Read the count, then open the form and
look at the preview.

### Add a site to the native-app table

Two files, one commit — and it is already the third row of the table in "Two
files that must agree, and nothing enforcing it".

**Watch the URI open something first.** The conversion is the vendor's own
convention and there is nothing to derive it from, so the only evidence that a
format is right is an application coming up.

```sh
# Does anything on this machine claim the scheme at all?
grep -rl 'x-scheme-handler/spotify' /usr/share/applications \
  ~/.local/share/applications --include='*.desktop'
xdg-mime query default x-scheme-handler/spotify

# Hand it a URI and watch.
gio open 'spotify:track:4uLU6hMCjMI75M1A2tKUQC'
```

An empty grep means nothing here can verify the conversion, so do not write it.
A hit does not settle it either: open the entry the grep names and check it is
the site's own application. On this machine that query answers `mclovin.desktop`
— an unrelated URL router that claims `x-scheme-handler/spotify` — so both
commands say "claimed" while nothing Spotify-shaped is installed. And do not
read `xdg-open`'s exit status as an answer: it exits 0 with nothing registered,
which is the failure the whole `scheme_handler_exists` helper in `mclovin-open`
exists to route around. The evidence is the window.

Then `Router.js`, `nativeApps()`:

```js
{
  id: "spotify",
  label: "Spotify",
  scheme: "spotify",
  pattern: "^https://open\\.spotify\\.com/(track|album|playlist)/[A-Za-z0-9]+(?:[/?#]|$)"
}
```

`test_every_native_app_is_well_formed` in `test/tst_router.qml` requires an id
matching `^[a-z][a-z0-9-]*$`, a scheme matching `^[a-z][a-z0-9+.-]*$`, a
non-empty label, a unique id, a pattern that compiles, and a pattern beginning
exactly `^https://`. The anchor is not tidiness: an unanchored pattern claims
links on every site that merely mentions this one.

Then `mclovin-open`: a conversion function beside `zoom_join_uri`, and a case in
`native_uri()` under the same id.

```sh
native_uri() {
  case $1 in
    zoom) zoom_join_uri "$2" ;;
    spotify) spotify_open_uri "$2" ;;
    *) return 1 ;;
  esac
}
```

The id travels on `--native=<id>` from `Service.qml` rather than being
re-derived, so the two files cannot disagree about which site a link is on — but
only if they spell the id the same way. The conversion re-validates scheme, host
and path shape, because this is where a web URL becomes a URI handed to a
desktop application; the Router pattern is the routing and preview half, not the
trust boundary.

**Nothing compares the two lists.** `test_every_native_app_is_well_formed` pins
the shape of the Router table and never reads `mclovin-open` — verified by
adding the entry above with no shim conversion and watching all 20 QML tests
still pass. Its comment says what happens if you add one side only — "a rule
saves and then opens nothing". The test you have to write goes in
`test/test_zoom_open.sh`, which stubs `xdg-open` and `xdg-mime` and asserts
against a log. Add three cases beside the Zoom ones:

- the conversion itself,
- a lookalike host that must **not** convert (`open.spotify.com.evil.example`),
- and no handler registered at all — `MCLOVIN_TEST_ZOOM_HANDLER=''` — which must
  reach the fallback browser and must never call `xdg-open`.

```sh
sh test/test_zoom_open.sh
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input test/
```

End to end, with the shell out of the loop:

```sh
./mclovin-open --native=spotify 'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC'
```

The application comes up, or the fallback browser does, or a critical
notification says neither could be reached and the exit status is non-zero —
`fallback_url` ends that way when the configured fallback and `first_browser`
both fail. What cannot happen is silence, which is the point of the shim.

### Add a preset to the rule form's Start from… library

`Router.js`, `rulePresets()`. Data only.

**Read the portability rule first, because it decides what belongs here.**
`test_preset_is_a_portable_builtin_action` is named after it: the library ships
to everyone, so a preset built on a built-in action, a web app, or a matcher
travels. One naming a specific browser and profile only helps the machine it was
written on — and it fails quietly there. `applyRulePreset` hands `rule.browser`
to `resolveBrowserValue` (`RuleFormView.qml:156-168`), which, when that browser
is not in the picker, returns the **first** browser in the list. The preset then
loads a browser its own label does not name, with nothing said. So the entry
below is a walkthrough of the shape, not a candidate for the shipped library.

```js
{
  id: "figma-work",
  label: "Figma → Chromium · Work",
  description: "Design files in the work profile.",
  category: "Design",
  testUrl: "https://www.figma.com/file/abc/Design",
  rule: makeRule(WHEN_HOST, ["figma.com"], "chromium", "Work", "", false, null)
}
```

**`RuleFormView.qml` needs no change**, because it reads the library rather than
the entries. `rulePresetOptions()` builds the dropdown — Custom rule first, then
`{ value: id, label: label }` per entry — and `applyRulePreset` copies the
selected entry's `rule` and `testUrl` into the editable form, branching on the
destination kind the rule already carries. That is what keeps the form from
growing one control and one handler per preset.

Verified by adding exactly the entry above to a copy of `Router.js` and calling
both functions:

```
rulePresetOptions -> [{"value":"custom",…},
                      {"value":"figma-work","label":"Figma → Chromium · Work"},
                      {"value":"zoom-meeting",…}]
rulePreset("figma-work").rule -> {"when":"host","terms":["figma.com"],
                                  "browser":"chromium","profile":"Work"}
```

Two more things about the entry:

- `rule` goes through `makeRule`, which returns `null` for a destination it does
  not understand, and `applyRulePreset` returns early on a preset with no rule.
  A malformed preset therefore appears in the dropdown and does nothing when
  picked. Print the rule before believing it.
- `description` and `category` are carried and asserted on the Zoom entry by
  `test_preset_is_a_portable_builtin_action`, but no QML renders them today.
  Write them; do not expect them on screen.

### Add a browser to the companion's table

`browser-companion/native/manage`, the `BROWSERS` dict. One entry:

```python
"opera": {
    "config": "opera",
    "programs": ["opera"],
    "flags": "",
},
```

- `config` — the directory under `~/.config` where that browser keeps its
  profile. `existing_browsers()` tests for it, so it decides both whether the
  panel offers setup at all and where the native-messaging manifest is written:
  `~/.config/<config>/NativeMessagingHosts/io.github.guilhermeyo.mclovin.json`.
- `programs` — executables to try, in order, for `manage open`.
- `flags` — the file under `~/.config` the browser reads its command line from
  at startup. The extension path is appended to the `--load-extension=` line
  there; that is the whole install mechanism, and it is why this needs neither a
  Chrome Web Store listing nor Developer mode. **Leave it `""` until you have
  watched that browser's launcher read that file.** The `<name>-flags.conf`
  convention comes from the Arch and Omarchy launcher wrappers, not from
  Chromium, and it does not follow from the browser's name: `opera-flags.conf`
  above is a guess nobody in this repository has confirmed, which is why the
  entry ships empty.

Nothing else changes. `argparse` takes its `choices` from `sorted(BROWSERS)`, so
the new name becomes a valid value for `install`, `uninstall` and `setup`, and
for `open --browser`, the moment the key exists.

Verified with `opera` added to a copy of the script and run against a throwaway
`HOME` — with `"flags": "opera-flags.conf"` set, to exercise the flags path:

```sh
H=$(mktemp -d)/home
mkdir -p "$H/.config/opera"
printf -- '--ozone-platform=wayland\n' > "$H/.config/opera-flags.conf"
env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$H" ./manage install --json
```

Exactly two things changed and nothing else: the manifest appeared at
`$H/.config/opera/NativeMessagingHosts/io.github.guilhermeyo.mclovin.json`, and
the flags file grew one line.

```
--ozone-platform=wayland
--load-extension=/…/browser-companion/extension
```

`uninstall` put the file back to its single original line and removed the
manifest. Run separately against the real table with an existing
`--load-extension=/…/omarchy/extensions/copy-url`, the path was appended to that
line rather than replacing it — Omarchy's own extensions live on it, and a
rewrite would uninstall them.

Note what that run does **not** prove. It shows `manage` writing a line and
reading it back, which happens just as happily for a filename the browser never
opens. That is the failure to avoid: a wrong flags file leaves the extension
reported under `loadingBrowsers` while nothing is loaded.

**A browser with no flags file.** `chrome-testing` is the entry that already
ships `"flags": ""`. `flags_path()` returns `None`, `load_extension()` returns
`False`, and the install still writes the native-messaging manifest. Measured:
`manage install` reported `chrome-testing` under `registeredBrowsers` and not
under `loadingBrowsers`. That pair is the state to recognise — the bridge is
registered, the extension is not loaded, and the person has to load
`browser-companion/extension/` by hand from `chrome://extensions` with Developer
mode on.

Flags are read once at startup, so any of this takes effect when the browser is
closed and opened again, not before.

This table is the companion's alone. It does not put the browser in the picker —
that list comes from the shell's desktop entry index — and it does not teach the
profile reader where to look. Profiles are gated by
`Browsers.isChromiumFamily()`, called at `Service.qml:304` before any Local
State path is watched, and it matches only `brave`, `chrom`, `edge` and
`vivaldi`: `isChromiumFamily("opera")` is `false`, so no profile file is read
for it at all. `localStateCandidates()` is usually **not** what needs editing —
it already ends in a generic `<id>/Local State` guess, and returns
`["opera/Local State"]` unprompted. Add an entry there only for a browser whose
config directory does not match its desktop entry id.

### Change what the marketplace listing says

The fields are top-level in `manifest.json`: `description` for the text,
`version` for the number. A git tag is not read.

Edit that file as text. `jq` and `json.dumps` reflow `kinds` into a five-line
array and turn a two-line change into a six-line diff.

**Pushing to `main` does not update the listing.** `plugins.omarchy.org` renders
`manifest.json` at a pinned commit, so changing what it says means pointing the
marketplace at a newer commit. That is an issue on
`omacom/omarchy-plugin-marketplace` titled `[Verify]: io.github.guilhermeyo.mclovin`,
whose body carries exactly six `###` headings in exactly this order — the parser
rejects the whole request otherwise:

```
### Verification action
### Plugin ID
### Repository URL
### Target commit
### Verification acknowledgment
### Standard installation acknowledgment
```

Editing an issue re-runs the validation, so point the existing one at the newer
commit rather than opening a second. Find it and read it before writing:

```sh
gh issue list --repo omacom/omarchy-plugin-marketplace --search mclovin --state all
gh issue view 3939 --repo omacom/omarchy-plugin-marketplace
gh issue edit 3939 --repo omacom/omarchy-plugin-marketplace --body-file body.md
```

Take the body from the issue that is already validated and change only the
**Target commit** line, to the full 40-character hash. The acknowledgment
checkboxes are part of the accepted body — and in the currently validated issue
the second one is *unticked* — so retyping them from memory is how a request
that would have passed gets rejected on a checkbox.

## Run the tests. All of them.

```sh
omarchy plugin validate .
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input test/
node test/test_browser_companion.js
python3 test/test_native_host.py
python3 test/test_companion_manage.py
sh test/test_zoom_open.sh
sh test/test_open_fallback.sh
```

**`qmltestrunner` must be the Qt6 one, by absolute path.** The one `qtchooser`
puts on `PATH` is Qt5 and exits 1 with *no output at all* against these tests,
which reads as a broken suite rather than a wrong binary.

`qmllint -I "$OMARCHY_PATH/shell" *.qml` is worth running, with one known
exception: it exits 255 with no diagnostic on `Panel.qml` when run from the
repository root, and has done so at every commit in this repository's history.
The same file copied elsewhere passes. CI runs `qmlformat` instead for that
reason.

CI runs everything above except `omarchy plugin validate` (Arch-only, so its
checks are reimplemented in the workflow) and `qmllint`.

## Prove a fix fails without itself

Every fix here carries a test that fails against the code it replaces. Not as
ceremony — twice in one week a test was written that passed against the bug:

- One asserted a rule with an empty `when` is dropped. Router migrates it to
  `contains` and routes it, so the test was pinning a defect as the expectation.
- One compared `0` with `0` because its fixture used the normalised rule shape
  while the code under test reads the CLI's shape. Every rule resolved to
  nothing and every assertion passed against an empty set.

So: write the test, `git stash` the fix or `git show HEAD:<file>` over it, watch
the test fail, put the fix back. If it does not fail, the test is not testing.

## The failure this codebase is organised against

**A swallowed click.** `mclovin-open` says so in its own header, and most bugs
found here have been a variation of reporting success for something that could
not have happened:

- `setsid "$@" &` followed by `return 0` — the shell forks, the child dies with
  127 into a discarded stream, and the caller has been told it worked.
- `xdg-open` exits 0 with nothing registered for a scheme. Its exit status
  cannot answer "is anything installed"; ask `xdg-mime`.
- `Quickshell.execDetached` reports nothing back, so a command that does not
  exist still counts as a route.
- `target=$(setting .a) || target=$(setting .b)` short-circuits on the first
  successful *read*, not the first successful *resolution*.

Before returning true, ask what you actually know.

## Two files that must agree, and nothing enforcing it

This has bitten four times. When you add a case to one of these, add it to the
other in the same commit, and add the test that fails if only one moves:

| | |
|---|---|
| `INTERCEPTABLE` / `ACTIONS` in `mclovin-native-host` | the destinations `Router.normalizeRule` accepts |
| `rules.js` matchers in the extension | `Router.termMatches` |
| `nativeApps()` ids in `Router.js` | the `native_uri()` cases in `mclovin-open` |
| the extension `key` in `manifest.json` | `EXTENSION_ID` in `mclovin-native-host` and `manage` |
| version in `manifest.json` | version in `browser-companion/extension/manifest.json` |

The panel once hid a working feature for a whole release because a gate asked
for a Zoom action while the native host served three destination kinds.

## Things that are not what they look like

- **A desktop id is not unique.** Two files named `Zoom.desktop` in different
  data directories both claim `zoommtg://`. `DesktopEntries` indexes by id, so
  the plugin is handed one and never told of the other, and `xdg-mime query
  default` answers the same id for both. Anything that must tell two entries
  apart uses the absolute path.
- **`IFS=$(printf '\n')` is the empty string.** Command substitution strips
  trailing newlines. Use a literal newline.
- **`set --` inside a shell function** sets that function's own positional
  parameters. A helper cannot return an argv.
- **`.pragma library`** at the top of `Router.js`, `Browsers.js` and `Import.js`
  is QML, not JavaScript. `node --check` rejects them on line one, and importing
  one from QML pulls in `QtQml.WorkerScript`.
- **A test that shells out must stub `xdg-open` and `xdg-mime`.** Without them
  the real ones run against the sandbox's own desktop entries through
  `XDG_DATA_HOME` and launch something, which is indistinguishable from the code
  under test having chosen it.

## House style

Comments explain **why**, and name the failure that motivated the code. A
comment that restates the line above it is noise; a comment that says which bug
this shape prevents is the only durable form of that knowledge. Read
`Browsers.js` or `mclovin-open` before writing one.

English everywhere — code, comments, commit messages, documentation. No emoji.
[Conventional Commits](https://www.conventionalcommits.org). No AI attribution
and no automatic `Co-Authored-By`.

Commit messages carry the reasoning, not the diff. The diff is already in the
commit.

## Do not

- **Do not name a site in a destination.** "Open it in…" lists destination
  *kinds*. A button reading "Zoom directly" is a category error that becomes six
  buttons, five of them wrong for any given rule.
- **Do not write a conversion, URI format, or statistic you have not watched
  work.** Release notes here once carried an invented figure about the
  marketplace catalogue. The catalogue has no such data.
- **Do not compare this plugin to another in anything public.** Other people's
  work in the same problem space is theirs. Read it, learn from it, never
  mention it in a listing, a README or a release.
- **Do not commit or push without being asked.** Show the diff, say what the
  commit would be, and wait.

## The marketplace listing

`plugins.omarchy.org` renders `manifest.json` at a pinned commit, so pushing to
`main` does not update it. Updating means an issue on
`omacom/omarchy-plugin-marketplace` titled `[Verify]: ` whose body carries
exactly six `###` headings in exactly the documented order — the parser rejects
the whole request otherwise — with the full 40-character target commit.

Editing that issue re-runs the validation, so point an existing one at a newer
commit rather than opening a second.

Version and description come from `manifest.json`; a git tag is not read. Edit
that file as text: `jq` and `json.dumps` reflow `kinds` into a five-line array
and turn a two-line change into a six-line diff.
