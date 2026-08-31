#!/bin/sh
# The shim's fallback and --app= paths, exercised through the real script.
#
# Every case here is a defect this file was written to keep fixed. The shape is
# test_zoom_open.sh's: a throwaway HOME, stub browsers on a pinned PATH, and a
# log the stubs append to, so nothing on the machine running it is consulted.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT HUP INT TERM

home="$root/home"
bin="$root/bin"
data="$root/data"
log="$root/launch.log"
mkdir -p "$home/.config/omarchy-mclovin" "$bin" "$data/applications"

# Two real browsers and one that is registered but not installed -- the state a
# machine is left in by an uninstall that leaves the desktop entry behind.
for name in fake-chrome fake-firefox obscure-browser; do
  printf '#!/bin/sh\nprintf "%s:%%s\\n" "$*" >>"$MCLOVIN_TEST_LOG"\n' "$name" >"$bin/$name"
  chmod +x "$bin/$name"
done

entry() { # <id> <exec> [categories]
  cat >"$data/applications/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$1
Exec=$2 %u
Categories=Network;${3:-WebBrowser};
EOF
}
entry fake-chrome "$bin/fake-chrome"
entry fake-firefox "$bin/fake-firefox"
entry ghost "$bin/does-not-exist"

printf '#!/bin/sh\nexit 1\n' >"$bin/notify-send"; chmod +x "$bin/notify-send"

# Stubbed so this file is hermetic. Without them the real xdg-open runs, finds
# the sandbox's own desktop entries through XDG_DATA_HOME, and launches one --
# which looks like the shim chose it.
printf '#!/bin/sh\nprintf "xdg-open:%%s\\n" "$1" >>"$MCLOVIN_TEST_LOG"\nexit 0\n' >"$bin/xdg-open"
printf '#!/bin/sh\nprintf "Zoom.desktop\\n"\n' >"$bin/xdg-mime"
chmod +x "$bin/xdg-open" "$bin/xdg-mime"

export HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$data"
export MCLOVIN_TEST_LOG="$log" PATH="$bin:/usr/bin:/bin"

config() { printf '%s\n' "$1" >"$home/.config/omarchy-mclovin/config.json"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; printf 'log:\n'; cat "$log" >&2 || true; exit 1; }

run() { # <expected-log-line-or-EMPTY> <description> <args...>
  expected=$1; what=$2; shift 2
  : >"$log"
  # The shell is deliberately absent: PATH holds no omarchy-shell, so every case
  # here takes the fallback the shim uses when the shell is not answering.
  "$repo/mclovin-open" "$@" >/dev/null 2>&1 || true
  attempts=0
  while [ "$attempts" -lt 60 ]; do
    if [ "$expected" = EMPTY ]; then
      [ ! -s "$log" ] || break
    else
      grep -Fq -- "$expected" "$log" && return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.01
  done
  if [ "$expected" = EMPTY ]; then
    [ -s "$log" ] && fail "$what -- expected nothing to launch"
    return 0
  fi
  fail "$what -- missing: $expected"
}

# A stale .fallback must not swallow the link: the entry reads fine, so the old
# code stopped there and reported success for a program that is not installed.
config '{"fallback":"ghost"}'
run 'fake-chrome:https://a.test/1' 'stale fallback falls through to a real browser' 'https://a.test/1'

# --app= walked the same candidates by whether the KEY was set rather than
# whether it resolved, so a webapp naming an uninstalled browser never reached
# the fallback.
config '{"webapp":"ghost","fallback":"fake-chrome"}'
run 'fake-chrome:--app=https://web.test/' 'stale webapp falls through to the fallback' '--app=https://web.test/'

# --app= is a Chromium flag. A Gecko browser must be skipped, not handed one.
config '{"webapp":"fake-firefox","fallback":"fake-chrome"}'
run 'fake-chrome:--app=https://web.test/' 'a Gecko webapp browser is skipped' '--app=https://web.test/'

# ...and when Gecko is all there is, the link opens as an ordinary window
# rather than not at all.
rm -f "$data/applications/fake-chrome.desktop"
config '{"webapp":"fake-firefox"}'
run 'fake-firefox:https://web.test/' 'with only Gecko, the web app opens as a tab' '--app=https://web.test/'
entry fake-chrome "$bin/fake-chrome"

# A private request must carry the family's flag into the fallback, or not open.
config '{"fallback":"fake-chrome"}'
run 'fake-chrome:--incognito https://p.test/1' 'private survives the fallback' --incognito 'https://p.test/1'

config '{"fallback":"fake-firefox"}'
run 'fake-firefox:--private-window https://p.test/2' 'the Gecko flag is the Gecko one' --incognito 'https://p.test/2'

# A browser with no private mode is refused rather than opened normally, which
# is the rule Browsers.js states and Service.qml enforces on the other path.
# A configured browser with no documented private flag is refused, and the chain
# carries on to one that has it. Refusing outright while another browser could
# honour the request would drop a link for no gain -- the invariant is that no
# ordinary window ever answers a private request, not that the first candidate
# wins.
entry obscure-browser "$bin/obscure-browser"
config '{"fallback":"obscure-browser"}'
run 'fake-chrome:--incognito https://p.test/3' 'an unflaggable browser is skipped, not obeyed' --incognito 'https://p.test/3'

# ...and when NOTHING installed has a private flag, nothing opens. This is the
# one case where dropping the link is the honest answer, and it is the rule
# Browsers.js states: a browser with no entry gets nothing rather than an
# ordinary window called private.
rm -f "$data/applications/fake-chrome.desktop" "$data/applications/fake-firefox.desktop" \
      "$data/applications/ghost.desktop"
run EMPTY 'with no private-capable browser, nothing opens' --incognito 'https://p.test/4'
entry fake-chrome "$bin/fake-chrome"
entry fake-firefox "$bin/fake-firefox"

# Regression: the ordinary path is untouched by any of the above.
config '{"fallback":"fake-chrome"}'
run 'fake-chrome:https://ordinary.test/' 'an ordinary link still opens' 'https://ordinary.test/'

# A Flatpak-exported browser's Exec is a wrapper: the browser's own arguments
# begin after the app id, so `--app=` has to land where %U sits and not after
# argv[0]. Running the first Exec token with the flag bolted on produced
# `flatpak --app=URL`, which is not a flatpak flag and opens nothing.
printf '#!/bin/sh\nprintf "flatpak:%%s\\n" "$*" >>"$MCLOVIN_TEST_LOG"\n' >"$bin/fake-flatpak"
chmod +x "$bin/fake-flatpak"
cat >"$data/applications/flat-chrome.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=flat-chrome
Exec=$bin/fake-flatpak run --branch=stable --command=brave com.brave.Browser %U
Categories=Network;WebBrowser;
EOF
config '{"webapp":"flat-chrome"}'
run 'flatpak:run --branch=stable --command=brave com.brave.Browser --app=https://web.test/' \
    'a Flatpak browser gets --app where the URL goes' '--app=https://web.test/'
rm -f "$data/applications/flat-chrome.desktop"

# Service.qml pins fallbackProfile on its own fallback. Ignoring it here put the
# same link in a different profile depending on whether the shell was up.
config '{"fallback":"fake-chrome","fallbackProfile":"Work"}'
run 'fake-chrome:--profile-directory=Work https://profile.test/' \
    'the fallback honours fallbackProfile' 'https://profile.test/'

config '{"fallback":"fake-firefox","fallbackProfile":"Personal"}'
run 'fake-firefox:-P Personal https://profile.test/' \
    'Gecko takes -P, not --profile-directory' 'https://profile.test/'

config '{"fallback":"fake-firefox","fallbackProfile":"/abs/path"}'
run 'fake-firefox:--profile /abs/path https://profile.test/' \
    'an absolute Gecko profile uses --profile' 'https://profile.test/'

# first_browser searched two of the four directories the launchers search. This
# entry lives only in /usr/local's position, reached through XDG_DATA_HOME's
# sibling, so it is found only if the list is complete.
rm -f "$data/applications"/*.desktop
config '{}'
run EMPTY 'with no entry in any searched directory, nothing launches' 'https://none.test/'
entry fake-chrome "$bin/fake-chrome"
config '{}'
run 'fake-chrome:https://found.test/' 'and it is found again once one exists' 'https://found.test/'

# Two applications can claim one scheme under one desktop id -- Omarchy's Zoom
# web app handler and the native client are both Zoom.desktop -- so XDG picks by
# directory precedence, silently and forever. --handler names the file outright.
printf '#!/bin/sh\nprintf "native-zoom:%%s\\n" "$*" >>"$MCLOVIN_TEST_LOG"\n' >"$bin/native-zoom"
printf '#!/bin/sh\nprintf "webapp-zoom:%%s\\n" "$*" >>"$MCLOVIN_TEST_LOG"\n' >"$bin/webapp-zoom"
chmod +x "$bin/native-zoom" "$bin/webapp-zoom"
mkdir -p "$data/sys"
cat >"$data/applications/Zoom.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Zoom
Exec=$bin/webapp-zoom %u
MimeType=x-scheme-handler/zoommtg;
EOF
cat >"$data/sys/Zoom.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Zoom Workplace
Exec=$bin/native-zoom %U
MimeType=x-scheme-handler/zoommtg;
EOF

config '{}'
run 'native-zoom:zoommtg://zoom.us/join?action=join&confno=123456789' \
    'the named handler receives the converted URI' \
    --zoom-direct "--handler=$data/sys/Zoom.desktop" 'https://zoom.us/j/123456789'

run 'webapp-zoom:zoommtg://zoom.us/join?action=join&confno=222222222' \
    'a different named handler receives it instead' \
    --zoom-direct "--handler=$data/applications/Zoom.desktop" 'https://zoom.us/j/222222222'

# A handler that has been uninstalled must not swallow the link: the URI still
# has xdg-open, and failing that the browser.
run 'xdg-open:zoommtg://zoom.us/join?action=join&confno=333333333' \
    'a missing handler falls through to xdg-open rather than dropping the link' \
    --zoom-direct '--handler=/nonexistent/Zoom.desktop' 'https://zoom.us/j/333333333'
rm -f "$data/applications/Zoom.desktop"

# --native=ID is the flag that replaced --zoom-direct. Both are accepted, and a
# rule saved under the old name still works.
run 'native-zoom:zoommtg://zoom.us/join?action=join&confno=444444444' \
    '--native=zoom converts and launches' \
    --native=zoom "--handler=$data/sys/Zoom.desktop" 'https://zoom.us/j/444444444'

run 'native-zoom:zoommtg://zoom.us/join?action=join&confno=555555555' \
    '--zoom-direct still means --native=zoom' \
    --zoom-direct "--handler=$data/sys/Zoom.desktop" 'https://zoom.us/j/555555555'

# A site the table does not know converts to nothing, and the link goes to the
# browser rather than nowhere.
run 'fake-chrome:https://example.test/x' \
    'an unknown site falls through to the browser' \
    --native=nosuchsite 'https://example.test/x'

# The same rejections as before, now reached through the new flag.
run 'fake-chrome:https://zoom.us.evil.example/j/1' \
    'a lookalike domain is still refused' \
    --native=zoom 'https://zoom.us.evil.example/j/1'

printf 'shim fallback tests passed\n'
