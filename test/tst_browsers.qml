import QtQuick
import QtTest
import "../Browsers.js" as Browsers

// Chromium 146+ hands a forwarded URL to the profile's most recently activated
// window of any type, and opens a new ordinary window when that one is an
// --app= window. These pin the decision that raises the ordinary window first,
// which window, and every input for which it must NOT.
//
// Plain objects stand in for Toplevel handles: the functions compare handles
// by identity and read appId, title and activated, nothing else.
TestCase {
  name: "Browsers"

  function win(appId, title, activated) {
    return { appId: appId, title: title, activated: activated === true }
  }

  // The measured miss: the last Brave window touched is the WhatsApp --app=
  // window, which the compositor still has active, and the ordinary window
  // sits behind it. A link handed to Brave in that state opened a new window
  // 4/4; raising the ordinary window first made it a tab 3/3. It is that
  // window, never the app one, that comes back -- and the reason names the
  // window that armed it, which is what `status` shows.
  function test_a_link_after_an_app_window_raises_the_ordinary_window() {
    var normal = win("brave-browser", "GitHub - Brave", false)
    var app = win("brave-web.whatsapp.com__-Default", "WhatsApp", true)
    var landing = Browsers.linkLanding([normal, app], [normal], "brave-browser", "44", 1, false)
    verify(landing.raise === normal)
    verify(landing.reason.indexOf("brave-web.whatsapp.com__-Default") !== -1, landing.reason)
  }

  // A PWA window has no `__` and is not the ordinary class either. It arms the
  // same trap and needs no attribution to a browser to be handled: the
  // ordinary window is simply not the active one.
  function test_a_pwa_window_arms_the_raise_without_being_a_candidate() {
    var normal = win("brave-browser", "GitHub - Brave", false)
    var pwa = win("brave-abcdefghijklmnopabcdefghijklmn-Default", "Some PWA", true)
    var landing = Browsers.linkLanding([pwa, normal], [], "brave-browser", "44", 1, false)
    verify(landing.raise === normal)
  }

  // Rows 1 and 4 of the measurement: the ordinary window was the last one
  // touched and the link became a tab with no help. Raising it would only
  // spawn hyprctl for nothing.
  function test_the_active_ordinary_window_needs_no_raise() {
    var normal = win("brave-browser", "GitHub - Brave", true)
    var app = win("brave-web.whatsapp.com__-Default", "WhatsApp", false)
    var landing = Browsers.linkLanding([normal, app], [normal], "brave-browser", "44", 1, false)
    verify(landing.raise === null)
    verify(landing.reason.indexOf("already active") !== -1, landing.reason)
  }

  // Two ordinary windows, a terminal in front. Chromium would put the tab in
  // the one used last; the record says which, and list order must not.
  function test_the_last_activated_ordinary_window_is_the_one_raised() {
    var a = win("brave-browser", "Docs - Brave", false)
    var b = win("brave-browser", "Mail - Brave", false)
    var term = win("Alacritty", "~", true)
    compare(Browsers.findProfileToplevel([a, b, term], "brave-browser", "44", 1, [b, a]), b)
    compare(Browsers.linkLanding([a, b, term], [b, a], "brave-browser", "44", 1, false).raise, b)
  }

  // The record is pruned on the next activation, not on close, so it can name
  // a window that is gone. Membership decides, never the handle.
  function test_a_closed_window_leaves_the_order() {
    var gone = win("brave-browser", "Closed - Brave", false)
    var a = win("brave-browser", "Docs - Brave", false)
    compare(Browsers.findProfileToplevel([a], "brave-browser", "44", 1, [gone, a]), a)
    compare(Browsers.ordinaryToplevelsByRecency([a], [gone], "brave-browser").length, 1)
  }

  // Passes on today's code on purpose: it pins that an empty record -- the
  // shell just started -- decides the way every pick did before there was a
  // record, the compositor's flag first and then list order.
  function test_without_history_the_flag_and_then_list_order_decide() {
    var a = win("brave-browser", "Docs - Brave", false)
    var b = win("brave-browser", "Mail - Brave", true)
    compare(Browsers.findProfileToplevel([a, b], "brave-browser", "44", 1, []), b)
    b.activated = false
    compare(Browsers.findProfileToplevel([a, b], "brave-browser", "44", 1, []), a)
  }

  // Every guard, each with the trap armed so a forgotten one would return a
  // window and fail: a private pick wants a fresh window; Firefox has no --app=
  // windows and takes a link on its own; no ordinary window means nothing to
  // raise and the argv is the only thing carrying the link.
  function test_private_gecko_and_no_window_are_launched_untouched() {
    var normal = win("brave-browser", "GitHub - Brave", false)
    var app = win("brave-web.whatsapp.com__-Default", "WhatsApp", true)

    var priv = Browsers.linkLanding([normal, app], [normal], "brave-browser", "44", 1, true)
    verify(priv.raise === null, "private")
    verify(priv.reason.indexOf("private") !== -1, priv.reason)

    var firefox = win("firefox", "Docs — Personal — Mozilla Firefox", false)
    var gecko = Browsers.linkLanding([firefox, app], [firefox], "firefox", "Personal", 1, false)
    verify(gecko.raise === null, "gecko")
    verify(gecko.reason.indexOf("not Chromium") !== -1, gecko.reason)

    var none = Browsers.linkLanding([app], [], "brave-browser", "44", 1, false)
    verify(none.raise === null, "no ordinary window")
    verify(none.reason.indexOf("no ordinary window") !== -1, none.reason)
    verify(Browsers.linkLanding([], [], "brave-browser", "44", 1, false).raise === null, "nothing open")
  }

  // Chromium windows do not say which profile they show, and its activation
  // order is per profile: raising a window makes that window's profile the
  // browser's last-used one, so an unpinned link would follow the raise into
  // a profile the browser would not have chosen. Nothing is raised with
  // several profiles, pinned or not, and the reason says so because the limit
  // is documented rather than hidden.
  function test_several_chromium_profiles_are_never_raised_pinned_or_not() {
    var chromium = win("chromium", "Docs - Chromium", false)
    var app = win("chromium-web.whatsapp.com__-Default", "WhatsApp", true)
    var pinned = Browsers.linkLanding([chromium, app], [chromium], "chromium", "Work", 4, false)
    verify(pinned.raise === null, "pinned")
    verify(pinned.reason.indexOf("4 profiles") !== -1, pinned.reason)
    var unpinned = Browsers.linkLanding([chromium, app], [chromium], "chromium", "", 4, false)
    verify(unpinned.raise === null, "unpinned")
    verify(unpinned.reason.indexOf("4 profiles") !== -1, unpinned.reason)
  }

  // A second Brave running under XWayland reports `Brave-browser` where the
  // Wayland one reports `brave-browser`, and the two are different processes.
  // Measured live before this was pinned: with the comparison folding case, a
  // link routed to Brave raised a 1Password popup belonging to the XWayland
  // instance and Brave opened a new window anyway. The raise has to reach the
  // process that will be handed the URL or it is worse than doing nothing.
  function test_an_xwayland_window_of_another_instance_is_not_a_candidate() {
    var xwayland = win("Brave-browser", "1Password - Brave", true)
    var normal = win("brave-browser", "Tailscale - Brave", false)
    var app = win("brave-web.whatsapp.com__-Default", "WhatsApp", false)

    verify(!Browsers.isOrdinaryWindowOf("Brave-browser", "brave-browser"))
    compare(Browsers.ordinaryWindowBrowser("Brave-browser", [{ id: "brave-browser" }]), "")
    compare(Browsers.findProfileToplevel([xwayland, normal], "brave-browser", "44", 1,
                                         [xwayland, normal]), normal)

    var landing = Browsers.linkLanding([xwayland, normal, app], [xwayland, normal],
                                       "brave-browser", "44", 1, false)
    verify(landing.raise === normal)
  }

  // With a link in hand the window that gets focused is the window that gets
  // the tab, and `class:` focuses whichever window Hyprland lists first. The
  // address names one window; class is only for a window Hyprland's model
  // does not know. The address is bare hex and gets its 0x here, once.
  function test_window_selector_names_one_window_by_address_and_falls_back_to_class() {
    var a = win("brave-browser", "Docs - Brave", false)
    var b = win("brave-browser", "Mail - Brave", false)
    var hypr = [{ wayland: a, address: "55bedbe16bc0" }, { wayland: b, address: "0x55bedbe1a2f0" }]
    compare(Browsers.windowSelector(b, hypr), "address:0x55bedbe1a2f0")
    compare(Browsers.windowSelector(a, hypr), "address:0x55bedbe16bc0")

    var unknown = win("brave-web.whatsapp.com__-Default", "WhatsApp", false)
    compare(Browsers.windowSelector(unknown, hypr), "class:^(brave-web\\.whatsapp\\.com__-Default)$")
    compare(Browsers.windowSelector(unknown, []), "class:^(brave-web\\.whatsapp\\.com__-Default)$")
    compare(Browsers.windowSelector(a, [{ wayland: a, address: "" }]), "class:^(brave-browser)$")
    compare(Browsers.windowSelector(null, hypr), "")
  }
}
