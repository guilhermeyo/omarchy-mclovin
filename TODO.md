# Known Defects — Backlog

Found during the 22/08/2026 audit of the web app path, after Omarchy web apps
turned out to be opening in Chromium instead of the configured browser. The
routing bug itself is fixed; everything below is what the audit turned up on the
way and is still open.

## Privacy (do these first)

- [ ] `mclovin-open:46-50,122` — `--app=` breaks out of the argument loop and the
      webapp exec never appends an incognito flag. `mclovin-open --incognito --app=URL`
      opens a normal, history-recording window. `Browsers.js:283-305` composes it
      correctly on the IPC path; the shim never learned to.
- [ ] `mclovin-open:218-229` — with the shell down, the fallback goes through
      `launch_desktop`, which adds no private flag either. `Service.qml:269`
      deliberately refuses to send a private request to the fallback (`&& !wantPrivate`,
      it asks instead); the shim's offline path breaks that same guarantee silently.

## Web app path

- [ ] `mclovin-open:119-122` — no Chromium-family guard on the resolved target. If
      `.webapp` or `.fallback` names a Gecko browser the shim runs `firefox --app=URL`,
      which does not exist. The retired CLI guarded this (`webapp.rs:62-79`); the shim
      ported the resolution order but not the check.
- [ ] `mclovin-open:120-121` — `exit 1` with no `notify-send` when `.webapp` names an
      uninstalled browser, or when `jq` is missing so `setting()` always fails. A web
      app click that does nothing and says nothing. The safety-net notification at
      `:231-233` only covers the non-webapp path.
- [ ] `mclovin-open:87` — `desktop_program` keeps only the first `Exec=` token, so any
      entry wrapped in `env` or `flatpak run app/...` becomes `exec setsid flatpak --app=URL`.
      The flatpak export dir is explicitly searched at `:84`, so this is reachable.
- [ ] `Router.js:385` — config carries `webapp` but no `webappProfile`, and
      `mclovin-open:122` passes no `--profile-directory`. `Browsers.js:266-275,297-316`
      prove the flags compose, and `Browsers.js:329` documents that an `--app=` window's
      class embeds the profile. Harmless on a single-profile browser; wrong the moment a
      second profile exists.

## Consistency between the shim and the service

- [ ] `mclovin-open:135-200` vs `Service.qml:269-275` — the shim's `launch_desktop`
      ignores `fallbackProfile` entirely. Same click, same config, different profile
      depending on whether the shell happens to be up.
- [ ] `mclovin-open:195` — `launch_desktop` backgrounds `setsid "$@" &` and returns 0
      unconditionally. If the target binary is gone the exec fails invisibly, the script
      exits 0, and the notification at `:231-233` never fires — the link is dropped in
      silence, which is exactly what the header comment at `:10-12` promises never happens.

## Configuration surface

- [ ] `Panel.qml`, `PickerView.qml`, `RuleFormView.qml` — nothing writes or displays the
      `webapp` key. It can only be set by hand-editing config.json, so a user who does not
      know it exists falls through to `first_browser()` on every web app click.
- [ ] `Import.js:100` — the CLI importer treats `[webapp]` as a table that ends the current
      handler, dropping `[webapp].browser` and its profile. The CLI supported a web app
      profile (`webapp.rs:24-57`); importing from it loses that.

## Retiring the Rust CLI

- [ ] `mclovin/src/cmd/webapp_fix.rs` — now stale. It pins the literal upstream case line
      and writes the prefix pattern `mclovin*`; against the plugin's `*mclovin*` it will
      bail with "doesn't have the expected case line". Loud rather than harmful, but it
      should be removed or made to defer to the plugin.
- [ ] `mclovin/src/cmd/doctor.rs:35-45` — reports the whitelist healthy whenever the patch
      string is present, without checking it matches the registered handler. This is the
      check that reported green for months while every web app opened in Chromium. Either
      port `mclovin-webapp-fix --check` or drop the check.
- [ ] `~/.local/share/applications/mclovin.desktop` — the retired CLI's handler entry. The
      plugin now filters every mclovin out of `first_browser()` and `isBrowserEntry`, so it
      is no longer reachable as a routing target, but it still appears in app launchers as
      a browser named "mclovin". Delete it when the CLI is formally retired.
- [ ] Two rule sets are drifting: `~/.config/mclovin/rules.toml` (7 rules) and
      `~/.config/omarchy-mclovin/config.json` (5). Decide which is canonical and migrate.

## Upstream

- [ ] `omarchy-launch-webapp` needs patching because its browser whitelist is hardcoded and
      there is no pre-update hook, so `git pull --ff-only` aborts the whole update whenever
      upstream touches that file (nine times in the last twelve months). Worth proposing
      upstream: honour an env var or a config key for the web app browser, so no handler
      outside the whitelist has to patch the tree at all.
