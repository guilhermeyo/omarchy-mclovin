#!/bin/sh
# mclovin-raise, exercised for real against a stubbed hyprctl and a fake
# browser. Every case is one way the focus can go wrong, and the assertion is
# always the same: the browser still ran, with its argv intact, after the
# focus. The shape is test_zoom_open.sh's: stubs on a pinned PATH and a log the
# stubs append to, so nothing on the machine running it is consulted.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

bin="$test_root/bin"
bare="$test_root/bare"
log="$test_root/launch.log"
mkdir -p "$bin" "$bare"

# One dialect per run, the way a real hyprctl speaks one: the other exits
# non-zero without touching a window, and the script has to reach the dialect
# this machine takes, and then the browser, either way. MCLOVIN_TEST_HANG makes
# every dispatch sit there, which is what a wedged compositor socket looks like.
cat >"$bin/hyprctl" <<'SH'
#!/bin/sh
printf 'hyprctl:%s\n' "$*" >>"$MCLOVIN_TEST_LOG"
[ -z "${MCLOVIN_TEST_HANG-}" ] || sleep 30
case $2 in
  hl.dsp.*) [ "${MCLOVIN_TEST_DIALECT:-lua}" = lua ] ;;
  *)        [ "${MCLOVIN_TEST_DIALECT:-lua}" = classic ] ;;
esac
SH

cat >"$bin/fake-browser" <<'SH'
#!/bin/sh
printf 'browser:%s\n' "$*" >>"$MCLOVIN_TEST_LOG"
SH
chmod +x "$bin/hyprctl" "$bin/fake-browser"
cp "$bin/fake-browser" "$bare/fake-browser"

export MCLOVIN_TEST_LOG="$log"
export PATH="$bin:/usr/bin"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
show() { printf 'launch log:\n' >&2; cat "$log" >&2 || true; }
assert_line() { grep -Fx -- "$1" "$log" >/dev/null 2>&1 || { show; fail "missing: $1"; }; }
refute_prefix() { if grep -q -- "^$1" "$log"; then show; fail "unexpected: $1"; fi; }
assert_first_is_hyprctl() {
  case $(sed -n 1p "$log") in
    hyprctl:*) ;;
    *) show; fail 'browser ran before hyprctl' ;;
  esac
}
assert_last() { [ "$(tail -n 1 "$log")" = "$1" ] || { show; fail "browser was not last: $1"; }; }

# The shim execs the browser in the foreground, so the log is complete on return.

# Lua dialect taken: one dispatch, then the browser, in that order, argv verbatim.
: >"$log"
MCLOVIN_TEST_DIALECT=lua "$repo/mclovin-raise" 'address:0x55bedbe16bc0' \
  fake-browser --profile-directory=Default 'https://example.com/a?x=1&y=2'
assert_line 'hyprctl:dispatch hl.dsp.focus({ window = "address:0x55bedbe16bc0" })'
assert_line 'browser:--profile-directory=Default https://example.com/a?x=1&y=2'
refute_prefix 'hyprctl:dispatch focuswindow'
assert_first_is_hyprctl
assert_last 'browser:--profile-directory=Default https://example.com/a?x=1&y=2'

# Classic dialect: the Lua form fails, the classic one is sent verbatim, then the browser.
: >"$log"
MCLOVIN_TEST_DIALECT=classic "$repo/mclovin-raise" 'address:0x55bedbe16bc0' \
  fake-browser https://example.com/b
assert_line 'hyprctl:dispatch focuswindow address:0x55bedbe16bc0'
assert_line 'browser:https://example.com/b'
assert_first_is_hyprctl
assert_last 'browser:https://example.com/b'

# No hyprctl anywhere. The link must still open: a raise that replaced a
# launch and then had nothing to raise with would swallow the click.
: >"$log"
PATH="$bare:/usr/bin" "$repo/mclovin-raise" 'address:0x55bedbe16bc0' fake-browser https://example.com/c
assert_line 'browser:https://example.com/c'
refute_prefix 'hyprctl:'

# A compositor that does not answer. Both dispatches hang; the timeouts cut
# them off and the browser still runs -- in bounded time, not never.
: >"$log"
start=$(date +%s)
MCLOVIN_TEST_HANG=1 "$repo/mclovin-raise" 'address:0x55bedbe16bc0' fake-browser https://example.com/d
elapsed=$(( $(date +%s) - start ))
assert_line 'browser:https://example.com/d'
assert_last 'browser:https://example.com/d'
[ "$elapsed" -lt 10 ] || fail "a hung hyprctl held the launch for ${elapsed}s"

# Empty selector: no focus, only the command.
: >"$log"
"$repo/mclovin-raise" '' fake-browser https://example.com/e
assert_line 'browser:https://example.com/e'
refute_prefix 'hyprctl:'

# No command: a raise on its own, nothing exec'd.
: >"$log"
"$repo/mclovin-raise" 'address:0x55bedbe16bc0'
assert_line 'hyprctl:dispatch hl.dsp.focus({ window = "address:0x55bedbe16bc0" })'
refute_prefix 'browser:'

# A class selector is a regex with escaped dots. The backslashes are doubled
# inside the Lua string literal and passed verbatim to the classic dispatcher.
: >"$log"
MCLOVIN_TEST_DIALECT=classic "$repo/mclovin-raise" 'class:^(brave-web\.whatsapp\.com__-Default)$' \
  fake-browser https://example.com/f
assert_line 'hyprctl:dispatch hl.dsp.focus({ window = "class:^(brave-web\\.whatsapp\\.com__-Default)$" })'
assert_line 'hyprctl:dispatch focuswindow class:^(brave-web\.whatsapp\.com__-Default)$'
assert_line 'browser:https://example.com/f'

printf 'raise tests passed\n'
