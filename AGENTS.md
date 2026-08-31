# Working in this repository

Read this before changing anything. It is not style advice; it is the list of
things that have already gone wrong here, written down so they go wrong once.

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
