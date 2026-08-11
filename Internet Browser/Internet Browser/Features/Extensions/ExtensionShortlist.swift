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

    // REJECTED CANDIDATES — verified NOT to work in Cherry's
    // WKWebExtensionController runtime on 2026-08-11. Do not re-test these
    // versions; do not offer them from the wizard. Full per-check evidence is
    // in the ExtensionVerificationTests harness output.
    //
    // - uBlock Origin 1.73.0 (MV2): loads, but blocked zero ad requests in
    //   A/B fetch batteries — Apple's runtime has no blocking webRequest.
    // - uBlock Origin Lite 2026.804.1652, Firefox build (MV3): loads, and
    //   declarativeNetRequest reports six rulesets ENABLED (ublock-filters,
    //   easylist, ...), yet no request is ever blocked — registered rules are
    //   ignored by the request pipeline. An apparent success in one early run
    //   was WebKit's own tracker blocking, not the extension (unload did not
    //   restore fetchability; later runs never blocked at all).
    // - uBlock Origin Lite, Safari build: same, blocks nothing (that build
    //   expects its app-extension wrapper).
    // - Bitwarden 2026.7.0 (MV2): toolbar popup web view stays an unbooted
    //   3-element shell with no text after 30s — the Angular app never
    //   starts. No autofill artifacts in pages either.
    // - Privacy Badger 2026.8.7 (MV2): no GPC/DNT header appears on page
    //   requests (its header injection needs blocking webRequest).
    // - Vimium 2.4.2 (MV3): the runtime rejects its content_scripts (its
    //   `file:///` match patterns fail Apple's parser: "content_scripts
    //   entry has no specified matches"); no script injects at all.
    // - Video Speed Controller 0.11.0 (MV3): its functional script declares
    //   `"world": "MAIN"`, which this runtime never executes — no controller
    //   attaches even with a fully-loaded real video (readyState 4).
    // - Open in Reader View 0.3.1 (MV3): context-menu-driven; Cherry has no
    //   extension context-menu surface, and firing its (empty) toolbar
    //   action changes nothing. Cherry ships its own reader mode anyway.
}
