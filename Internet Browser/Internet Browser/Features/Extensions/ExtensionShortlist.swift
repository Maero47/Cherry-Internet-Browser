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
    /// Survivors of the live verification run (2026-08-11, macOS 26.5), in
    /// wizard display order. Ten candidates went through the harness; these
    /// two demonstrably did their job in Cherry.
    ///
    /// - Dark Reader: verified three independent runs — injects its `<style>`
    ///   elements and turns example.com's body to rgb(24, 26, 27).
    /// - Simple Translate: popup renders and a Spanish input came back as a
    ///   real English translation through its backend.
    static let entries: [ExtensionShortlistEntry] = [
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
    // WKWebExtensionController runtime on 2026-08-11. Do not offer them from
    // the wizard. Per-check evidence is in the ExtensionVerificationTests
    // harness output; the mechanism behind each rejection was chased down
    // separately by ExtensionGapDiagnosisTests.
    //
    // TWO OF THESE REJECTION REASONS WERE WRONG, and the corrections are
    // recorded here so nobody reasons from them again. Neither candidate has
    // been promoted: that is a verdict change and belongs to a round that
    // re-runs the full verification harness.
    //
    // - uBlock Origin 1.73.0 (MV2): loads, but blocked zero ad requests in
    //   A/B fetch batteries. Mechanism: this runtime DOES deliver
    //   `webRequest` events — `onBeforeRequest`/`onBeforeSendHeaders` fire
    //   with real URLs and `addListener(…, ["blocking"])` is accepted — but
    //   the listener's return value is discarded. A minimal MV2 fixture's
    //   `{cancel: true}` and its added `Sec-GPC`/`DNT` request headers both
    //   had no effect on the wire. `webRequestBlocking` is not among the
    //   permissions WebKit grants at all.
    // - uBlock Origin Lite 2026.804.1652, Firefox build (MV3): CORRECTION —
    //   it DOES block. The earlier "registered rules are ignored by the
    //   request pipeline" was a measurement artefact: an 8-second settle
    //   window, and probe URLs its converted rules do not contain. Probed
    //   with URLs matching three of its own shipped rules, blocking starts at
    //   t+10s and all six enabled rulesets are in force by t+90s, with
    //   fetchability restored on unload. Static, dynamic and session DNR
    //   rules all work in this runtime.
    // - uBlock Origin Lite, Safari build: blocks nothing (that build expects
    //   its app-extension wrapper). Not re-examined this round.
    // - Bitwarden 2026.7.0 (MV2): toolbar popup stays an unbooted 3-element
    //   shell. Mechanism: the extension popup web view's user agent has no
    //   product token (Cherry sets `applicationNameForUserAgent` on tab
    //   configurations only, never on the extension controller's
    //   `webViewConfiguration`), so Bitwarden's `getDevice()` matches neither
    //   Firefox, Chrome, Edge, Vivaldi, Opera nor Safari, returns null, and
    //   `this.device.toString()` throws inside Angular's DI. Giving the same
    //   popup web view a Safari user agent and reloading boots it fully.
    // - Privacy Badger 2026.8.7 (MV2): no GPC/DNT header appears on page
    //   requests — same discarded-return-value mechanism as uBlock Origin.
    // - Vimium 2.4.2 (MV3): CORRECTION — its content scripts DO inject. The
    //   "content_scripts entry has no specified matches" error is scoped to
    //   the ONE entry whose only patterns are `file:///` and `file:///*/`;
    //   sibling entries load normally (proved with a three-entry fixture, and
    //   by vimium.css reaching the page). Note the patterns themselves parse:
    //   `WKWebExtensionMatchPattern(string: "file:///")` succeeds. What that
    //   lost entry carries is `content_scripts/file_urls.css`, four lines
    //   fixing a Chrome file:// directory-listing quirk. Vimium stays off the
    //   shortlist because its keyboard behaviour is still unverifiable in the
    //   harness, not because it fails to load.
    // - Video Speed Controller 0.11.0 (MV3): its functional script declares
    //   `"world": "MAIN"`, which this runtime never executes — no controller
    //   attaches even with a fully-loaded real video (readyState 4).
    // - Open in Reader View 0.3.1 (MV3): context-menu-driven; Cherry has no
    //   extension context-menu surface, and firing its (empty) toolbar
    //   action changes nothing. Cherry ships its own reader mode anyway.
}
