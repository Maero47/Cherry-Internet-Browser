//
//  CherryPage.swift
//  Cherry Browser
//

import Foundation

/// Internal browser destinations addressable as `cherry://<page>` URLs,
/// Chrome-style (`chrome://settings`). Each case is a real in-tab location:
/// the omnibox shows its URL, typing the URL opens it, and Back returns to
/// the web page that was showing when it opened.
enum CherryPage: String, CaseIterable {
    case settings
    case history
    case bookmarks
    case downloads
    case extensions

    static let urlScheme = "cherry"

    /// The home / new-tab page's canonical address. It is intentionally NOT a
    /// `CherryPage` case: the cases above COVER a live site (Back returns to it),
    /// whereas the home page is the root state (`Tab.showHomePage`) with no site
    /// behind it. This keeps home addressable — the omnibox shows this URL and
    /// typing it opens home — while the whole `cherry://` vocabulary lives here.
    static let newTabURLString = "\(urlScheme)://newtab"

    /// True when typed omnibox input is the new-tab address (`cherry://newtab`,
    /// with or without a trailing slash, plus the slash-less `cherry:newtab`).
    static func isNewTabInput(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("\(urlScheme):") else { return false }
        if trimmed == "\(urlScheme):newtab" { return true }
        return URL(string: trimmed)?.host?.lowercased() == "newtab"
    }

    /// Canonical URL for this page, e.g. `cherry://settings`.
    var url: URL {
        URL(string: "\(Self.urlScheme)://\(rawValue)")!
    }

    /// Tab / page title shown while this page is the tab's location.
    var displayTitle: String {
        switch self {
        case .settings: "Settings"
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .downloads: "Downloads"
        case .extensions: "Extensions"
        }
    }

    /// Parses a `cherry://` URL. Accepts the canonical form, a trailing
    /// slash, and path-suffixed aliases like `cherry://settings/privacy`
    /// (the suffix is ignored — no per-section deep-linking). Returns nil
    /// for any other scheme or an unknown page name, so normal web URLs
    /// never parse as an internal page.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme else { return nil }
        // "cherry://settings" parses with host "settings"; the slash-less
        // "cherry:settings" form puts the name in the path instead.
        let name = url.host?.lowercased()
            ?? url.path.split(separator: "/").first.map { $0.lowercased() }
            ?? ""
        self.init(rawValue: name)
    }

    /// Parses typed omnibox input. Only strings carrying the cherry scheme
    /// are considered — plain search terms and web URLs return nil.
    init?(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("\(Self.urlScheme):"),
              let url = URL(string: trimmed) else { return nil }
        self.init(url: url)
    }
}
