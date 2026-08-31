# Known Defects — Backlog

Found by an audit of the whole plugin on 31/08/2026: four independent auditors,
then one skeptic per finding whose job was to refute it. Fourteen of thirty-four
findings died there, which is the number that makes the rest worth reading.

Everything the audit confirmed has been fixed. What is left is one item nobody
has been able to place, and it is a tool rather than this plugin.

## Tooling

- [ ] `qmllint` exits 255 with no diagnostic on `Panel.qml` when run from the
      repository root, and does so at every commit in this repository's history.
      The same file copied into an empty directory passes, so it is the tool
      resolving sibling QML rather than the file: `qmlformat` parses it without
      complaint, and the shell loads it. CI runs `qmlformat` for that reason —
      a check that cannot run is better left out than run in a mode that always
      passes.

## Deliberately not done

- The companion serves the extension only the matchers of rules whose
  destination leaves the browser. A *browser* rule that is narrower than a
  matching web-app rule therefore wins in Router while the extension has already
  cancelled the click, and the link opens in a new tab rather than navigating
  the current one. Making the extension exact would mean porting Router's
  specificity ordering into the native host — a second implementation of the one
  thing that decides where every link goes, kept in sync by hope. The cost of
  the bug is a tab; the cost of the fix is the class of defect this audit spent
  its time removing.

## Upstream

- [ ] `omarchy-launch-webapp` needs patching because its browser whitelist is hardcoded and
      there is no pre-update hook, so `git pull --ff-only` aborts the whole update whenever
      upstream touches that file (nine times in the last twelve months). Worth proposing
      upstream: honour an env var or a config key for the web app browser, so no handler
      outside the whitelist has to patch the tree at all.
