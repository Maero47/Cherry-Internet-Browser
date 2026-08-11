//
//  ExtensionShortlist.swift
//  Internet Browser
//
//  The first-run wizard's extension shortlist: only entries that were LOADED
//  INTO THIS APP'S ExtensionManager and observed doing their job (see
//  ExtensionVerificationTests and the per-candidate evidence it writes —
//  loading cleanly was never accepted as passing). Kept as a Swift table
//  rather than a bundled JSON resource deliberately: the only consumer is the
//  wizard in this same process, a table is compile-time checked (no runtime
//  parse/IO failure path to handle in first-run code), and the invariants are
//  asserted directly by ExtensionShortlistTests.
//
//  Rules for editing:
//  - Never add an entry without re-running the verification harness against
//    the exact package version you list. `verifiedVersion` is a promise.
//  - `caveat` is text the wizard MUST surface to the user, not a footnote.
//  - `sourceURL` is where the wizard downloads the package from; it must be
//    a stable, official location serving exactly the verified artifact line.
//

import Foundation

/// One wizard-offerable extension, verified against Cherry's own
/// `WKWebExtensionController` runtime.
struct ExtensionShortlistEntry: Identifiable, Equatable {
    /// Stable slug used by the wizard; never shown to users.
    let id: String
    /// Name shown in the wizard row.
    let displayName: String
    /// What it does, one line, user-facing.
    let summary: String
    /// Official package download location (the artifact the wizard installs).
    let sourceURL: URL
    /// The exact version that passed live verification in Cherry.
    let verifiedVersion: String
    /// Spoken-out-loud warning the wizard must show, or nil if none.
    let caveat: String?
}

enum ExtensionShortlist {
    /// Survivors of the live verification run (2026-08-12, macOS 26.5), in
    /// wizard display order. Re-run from scratch in the runtime the app now
    /// ships — the user-agent change altered the environment every extension
    /// runs in, and a shortlist verified under different conditions is not
    /// verified. Ten candidates went through the harness; these three
    /// demonstrably did their job in Cherry.
    ///
    /// - uBO Lite: blocks real requests. Three URLs built from rules it
    ///   actually ships came back blocked from t+10s, stayed blocked for the
    ///   full two-minute window, and became fetchable again the moment it was
    ///   switched off (the attribution leg). The control URL never blocked.
    /// - Dark Reader: injects its `<style>` elements and turns example.com's
    ///   body to rgb(24, 26, 27) — four independent runs now.
    /// - Simple Translate: popup renders (142 elements) and "buenos días
    ///   amigo" came back as "good morning friend" through its backend.
    static let entries: [ExtensionShortlistEntry] = [
        ExtensionShortlistEntry(
            id: "ubo-lite",
            displayName: "uBO Lite",
            summary: "Blocks ads and trackers",
            sourceURL: URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.804.1652/uBOLite_2026.804.1652.firefox.signed.xpi")!,
            verifiedVersion: "2026.804.1652",
            caveat: "Blocking starts about ten seconds after it loads, so the first page or two can still show ads. It also does not block everything in Cherry: one of its six filter lists (easylist) registers but never takes effect, so some ads get through."
        ),
        ExtensionShortlistEntry(
            id: "darkreader",
            displayName: "Dark Reader",
            summary: "Dark mode for every website",
            sourceURL: URL(string: "https://addons.mozilla.org/firefox/downloads/file/4899461/darkreader-4.9.129.xpi")!,
            verifiedVersion: "4.9.129",
            caveat: nil
        ),
        ExtensionShortlistEntry(
            id: "simple-translate",
            displayName: "Simple Translate",
            summary: "Translate text from the toolbar popup",
            sourceURL: URL(string: "https://addons.mozilla.org/firefox/downloads/file/4674724/simple_translate-3.0.1.xpi")!,
            verifiedVersion: "3.0.1",
            caveat: "Translation from the toolbar popup is verified. The floating translate button on selected text did not work reliably in Cherry."
        ),
    ]

    // REJECTED CANDIDATES — did NOT demonstrate their function in Cherry's
    // WKWebExtensionController runtime. Do not offer them from the wizard.
    // Every one of these was re-run on 2026-08-12 against the shipping
    // runtime (the user-agent change included), with a battery that now
    // carries URLs built from rules a real blocker ships and a settle window
    // polled to two minutes instead of sampled once at t+8s — the two
    // measurement errors that produced a wrong verdict last time. Per-check
    // evidence is in the ExtensionVerificationTests output; the mechanism
    // behind each rejection was chased down by ExtensionGapDiagnosisTests.
    //
    // - uBlock Origin 1.73.0 (MV2): loads (one `commands` manifest warning),
    //   and blocked ZERO of eight discriminator URLs across the full 120s
    //   window — re-measured, not inherited. Mechanism: this runtime DOES
    //   deliver `webRequest` events — `onBeforeRequest`/`onBeforeSendHeaders`
    //   fire with real URLs and `addListener(…, ["blocking"])` is accepted —
    //   but the listener's return value is discarded. A minimal MV2 fixture's
    //   `{cancel: true}` and its added `Sec-GPC`/`DNT` request headers both
    //   had no effect on the wire. `webRequestBlocking` is not among the
    //   permissions WebKit grants at all. Nothing Cherry can bridge.
    // - uBlock Origin Lite, Safari build (MV3): blocks nothing, still. It
    //   registers three rulesets (`ublock-filters`, `easylist`,
    //   `easyprivacy`) and not one request stopped in 120s; that build
    //   expects its Safari app-extension wrapper. THE FIREFOX BUILD OF THE
    //   SAME VERSION IS ON THE SHORTLIST — the wizard must serve that
    //   artifact, not this one.
    // - Bitwarden 2026.7.0 (MV2): its popup does not come up. Round 1 saw an
    //   unbooted 3-element Angular shell and diagnosed the cause — the popup
    //   web view had no product token in its user agent, so `getDevice()`
    //   returned null and threw inside Angular's DI. That gap is now closed
    //   (the extension controller carries the same user agent as tabs, see
    //   `BrowserUserAgent`), and this round re-ran the probe against it: the
    //   popup web view now answers no JavaScript AT ALL — a 30-second
    //   evaluate returns nothing, its web content process wedged — and it
    //   deadlocked the harness until the probe was given a deadline. Whatever
    //   the user agent fixed, the popup is still not usable. Login, vault
    //   sync and autofill remain unexercised.
    // - Privacy Badger 2026.8.7 (MV2): no GPC/DNT header appears on page
    //   requests (httpbin echoes the real headers back) — same
    //   discarded-return-value mechanism as uBlock Origin.
    // - Vimium 2.4.2 (MV3): its content scripts DO inject — this round proved
    //   it positively rather than by inference: `vimium.css` reaches the page
    //   (a `.vimium-reset` div computes to `display: inline`, which only its
    //   stylesheet does). The "content_scripts entry has no specified
    //   matches" error is scoped to the ONE entry whose only patterns are
    //   `file:///` and `file:///*/`; sibling entries load normally, and
    //   Cherry now reports that as a warning against a LOADED extension (see
    //   `ExtensionPackageStatus`), not a failed load. It stays off the
    //   shortlist for one honest reason: its keyboard behaviour cannot be
    //   exercised here. Every Vimium handler is wrapped in `forTrusted`
    //   (`lib/utils.js`), which drops any event with `isTrusted == false`, so
    //   a dispatched `KeyboardEvent` can never drive it; and a real `NSEvent`
    //   cannot be delivered either, because the test host is never the active
    //   app (`activate(ignoringOtherApps:)` is refused, the window never
    //   becomes key, and WebKit drops keys aimed at a non-key window). NOT a
    //   verdict that Vimium is broken — a verdict that nobody has watched it
    //   work. Listing it would be listing something unrun.
    // - Video Speed Controller 0.11.0 (MV3): its functional script declares
    //   `"world": "MAIN"`, which this runtime never executes — no controller
    //   attaches even with a fully-loaded real video (readyState 4).
    // - Open in Reader View 0.3.1 (MV3): context-menu-driven; Cherry has no
    //   extension context-menu surface, and firing its (empty) toolbar
    //   action changes nothing. Cherry ships its own reader mode anyway.
}
