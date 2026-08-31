# Known Defects — Backlog

Found by an audit of the whole plugin on 31/08/2026: four independent auditors,
then one skeptic per finding whose job was to refute it. Fourteen of thirty-four
findings died there, which is the number that makes the rest worth reading.

The confirmed ones that were fixed are in the history. These are the ones left,
each with the reproduction that survived refutation.

## Reported as success, still

- [ ] `Service.qml` command branch — `Quickshell.execDetached` reports nothing
      back, so a `command` rule whose binary is not installed is counted, written
      to stats as a successful route, and answered "routed" to the shim, which
      then exits 0 without reaching its own fallback. The shim's half of this
      class was fixed; this half needs the command to be probed before the launch
      is claimed, and doing that from QML means running it through `sh -c`, which
      changes how every command rule launches. Worth doing deliberately.

## The `--app=` path

- [ ] `mclovin-open` `desktop_program` keeps only the first `Exec=` token, so a
      Flatpak-exported browser is run as `flatpak --app=URL`. The whole Exec must
      be expanded and `--app=` inserted after the wrapper's own arguments, not
      after argv[0] — `--app` is not a flatpak global flag. Two proposed fixes
      were refuted: a helper cannot return an argv, because `set --` inside a
      function sets that function's own positional parameters.
- [ ] `mclovin-open` `first_browser` searches two of the four directories the
      launchers search, so a Flatpak-only or `/usr/local` browser is reported as
      "no browser found".
- [ ] The fallback path ignores `fallbackProfile`, which `Service.qml` honours.
      The same link lands in a different profile depending on whether the shell
      is up.

## Importing from the retired CLI

- [ ] `[webapp].browser` is still dropped: the table falls into the catch-all
      branch, so a migrant lands on the `webapp` key with it empty.
- [ ] A handler target written as an inline table — `browser = { command =
      "spotify", args = [...] }` — is imported as a browser *name*, producing a
      rule that matches links and can never launch. It should either become a
      `command` target, which the plugin already has, or be counted in `skipped`.

## Configuration surface

- [ ] Nothing writes or displays the `webapp` key (which browser opens `--app=`
      windows), or `webappProfile`, which does not exist. Both are reachable only
      by hand-editing config.json.
- [ ] When a rule's destination is no longer installed, `route()` computes the
      reason and throws it away before opening the picker, so the picker says
      nothing about why it appeared.

## The companion

- [ ] A browser rule narrower than a matching web-app rule is invisible to the
      extension, so the click is cancelled and reopened in a new tab rather than
      navigating.
- [ ] A `--load-extension` line holding more than one flag is corrupted by
      `manage`, and `status` then reports the extension as loading.
- [ ] Every frame on a page asks the service worker for rules at once, and each
      miss spawns its own native-host process.
- [ ] `chrome.runtime.onMessageExternal` can never fire — no extension is
      allowed to send to this one — so the rules cache is never invalidated from
      outside, and the comment claims the panel drives it.
- [ ] The panel offers the companion on the strength of a rule alone, with no
      check that a Chromium-family browser exists for `manage` to install into.

## Tooling

- [ ] `qmllint` exits 255 with no diagnostic on `Panel.qml` when run from the
      repository root. The same file copied elsewhere passes, so it is the tool
      resolving sibling QML rather than the file. CI runs `qmlformat` instead,
      which parses without resolving imports.

## Upstream

- [ ] `omarchy-launch-webapp` needs patching because its browser whitelist is hardcoded and
      there is no pre-update hook, so `git pull --ff-only` aborts the whole update whenever
      upstream touches that file (nine times in the last twelve months). Worth proposing
      upstream: honour an env var or a config key for the web app browser, so no handler
      outside the whitelist has to patch the tree at all.
