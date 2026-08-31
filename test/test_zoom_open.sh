#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

home="$test_root/home"
bin="$test_root/bin"
data="$test_root/data"
log="$test_root/launch.log"
mkdir -p "$home/.config/omarchy-mclovin" "$bin" "$data/applications"

cat >"$home/.config/omarchy-mclovin/config.json" <<'JSON'
{"fallback":"fake-browser.desktop"}
JSON

cat >"$data/applications/fake-browser.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Fake Browser
Exec=$bin/fake-browser %u
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF

cat >"$bin/xdg-open" <<'SH'
#!/bin/sh
printf 'xdg-open:%s\n' "$1" >>"$MCLOVIN_TEST_LOG"
exit "${MCLOVIN_XDG_EXIT:-0}"
SH

cat >"$bin/fake-browser" <<'SH'
#!/bin/sh
printf 'browser:%s\n' "$1" >>"$MCLOVIN_TEST_LOG"
SH

# Stubbed alongside xdg-open, not left to the real one: whether this machine has
# Zoom installed is exactly what the launcher asks, so a real xdg-mime would make
# these results depend on the machine running them.
cat >"$bin/xdg-mime" <<'SH'
#!/bin/sh
[ -n "${MCLOVIN_TEST_ZOOM_HANDLER-}" ] || exit 0
printf '%s\n' "$MCLOVIN_TEST_ZOOM_HANDLER"
SH

chmod +x "$bin/xdg-open" "$bin/fake-browser" "$bin/xdg-mime"

export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export XDG_DATA_HOME="$data"
export MCLOVIN_TEST_LOG="$log"
export MCLOVIN_TEST_ZOOM_HANDLER="Zoom.desktop"
export PATH="$bin:/usr/bin"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_log() {
  expected=$1
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    grep -Fx -- "$expected" "$log" >/dev/null 2>&1 && return 0
    attempts=$((attempts + 1))
    sleep 0.01
  done
  printf 'launch log:\n' >&2
  cat "$log" >&2 || true
  fail "missing: $expected"
}

: >"$log"
MCLOVIN_XDG_EXIT=0 "$repo/mclovin-open" --zoom-direct \
  'https://us02web.zoom.us/j/123-456-789?pwd=x%2By%2Fz'
assert_log 'xdg-open:zoommtg://zoom.us/join?action=join&confno=123456789&pwd=x%2By%2Fz'

: >"$log"
MCLOVIN_XDG_EXIT=0 "$repo/mclovin-open" --zoom-direct \
  'https://app.zoom.us/wc/join/987654321'
assert_log 'xdg-open:zoommtg://zoom.us/join?action=join&confno=987654321'

: >"$log"
MCLOVIN_XDG_EXIT=0 "$repo/mclovin-open" --zoom-direct \
  'HTTPS://APP.ZOOM.US/w/111-222-333'
assert_log 'xdg-open:zoommtg://zoom.us/join?action=join&confno=111222333'

: >"$log"
MCLOVIN_XDG_EXIT=0 "$repo/mclovin-open" --zoom-direct \
  'https://zoom.us.evil.example/j/123456789'
assert_log 'browser:https://zoom.us.evil.example/j/123456789'

: >"$log"
MCLOVIN_XDG_EXIT=1 "$repo/mclovin-open" --zoom-direct \
  'https://zoom.us/j/123456789?pwd=secret'
assert_log 'xdg-open:zoommtg://zoom.us/join?action=join&confno=123456789&pwd=secret'
assert_log 'browser:https://zoom.us/j/123456789?pwd=secret'

# No zoommtg handler at all. xdg-open exits 0 with nothing registered — it
# searches every mimeapps location, opens nothing, and reports success — so the
# launcher has to ask xdg-mime rather than read that status. Before it did, this
# link was dropped in silence.
: >"$log"
MCLOVIN_TEST_ZOOM_HANDLER='' MCLOVIN_XDG_EXIT=0 "$repo/mclovin-open" --zoom-direct \
  'https://zoom.us/j/123456789'
assert_log 'browser:https://zoom.us/j/123456789'
grep -q '^xdg-open:' "$log" && fail "asked xdg-open with no zoommtg handler registered"

printf 'zoom direct launcher tests passed\n'
