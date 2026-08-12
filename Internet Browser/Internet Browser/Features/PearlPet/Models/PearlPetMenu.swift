//
//  PearlPetMenu.swift
//  Cherry Browser
//
//  What right-clicking Pearl offers, and — the part that matters — what each
//  entry actually calls.
//
//  ## Nothing here implements a browser feature
//
//  Every row on this menu is a call into something Cherry already does: the
//  screenshot is the one `⌥⌘4` and the toolbar camera take, the search is the
//  one the address bar performs, the new tab is `newTab`. That is what
//  `PearlPetHost` is for — it is not an abstraction over the browser, it is
//  the exact set of methods `BrowserViewModel` ALREADY had (plus one reader
//  for the page's selection, which nothing in Cherry had yet), named so a test
//  can hold a spy in the same slot and prove the pet reaches them.
//
//  A pet that re-implemented "take a screenshot" would have its own idea of
//  where files go and its own bugs; this one cannot drift, because there is
//  nothing here to drift.
//
//  ## Why these six
//
//  - **Take a Screenshot.** Cherry can already do it, so the playful route to
//    it costs nothing and lands in Downloads with the toast the user knows.
//  - **Search for the selection.** The genuinely useful one. Absent — not
//    greyed, absent — when nothing is selected, because a menu that offers to
//    search for nothing is a menu that wasted the user's click.
//  - **Give Pearl a Fish.** Pure delight, and deliberately the only row that
//    changes nothing outside the animation: no hunger, no counter, no file. A
//    persisted appetite would be state that can go stale, be wrong across
//    windows, and demand migration, in exchange for a number nobody can see.
//  - **Pearl's Size.** Three whole multiples, with the one she is ticked. It
//    is on her menu rather than only in Settings because the question "is she
//    the right size?" is one you ask while looking at her, and because the
//    answer is worth seeing applied immediately — which is exactly what a
//    Settings pane in another window cannot do. Why three and not a slider:
//    `PearlPetSize`.
//  - **Send Pearl Home.** The one row here that does something no other route
//    in Cherry offers. Now that she can be put anywhere on the page, a drag
//    can leave her somewhere the user regrets — over a video's controls, on
//    top of a fixed sidebar — and without this the only ways back are dragging
//    her out again by the pixel or switching her off. Disabled rather than
//    hidden when she is already home, so it can be learned.
//  - **Put Pearl Away.** The switch, where the user is looking when they want
//    it. Hunting through Settings for the off switch of a thing standing in
//    front of you is the wrong shape of annoying.
//
//  The rows themselves are built by `PearlPetView.menuItems(selection:host:)`
//  rather than here, because two of them are questions only the view can
//  answer — what size she currently is, and whether she is already home.
//

import Foundation

/// The browser capabilities the pet borrows. `BrowserViewModel` conforms with
/// the methods it already had.
@MainActor
protocol PearlPetHost: AnyObject {
    /// Cherry's screenshot: `WKWebView.takeSnapshot` → Downloads → toast.
    func captureScreenshot()
    /// Cherry's new tab.
    func newTab(url: URL?)
    /// Cherry's search, through the user's chosen engine.
    func performSearch(_ query: String)
    /// What the user has selected on the page, if anything. The one thing on
    /// this protocol Cherry did not already have.
    func readPageSelection(_ completion: @escaping (String?) -> Void)
}

enum PearlPetMenuAction: String, CaseIterable {
    case screenshot
    case search
    case fish
    case putAway
}

@MainActor
enum PearlPetMenu {

    /// The longest selection worth sending to a search engine. A selection
    /// longer than this is a paragraph, and a paragraph is not a query.
    static let maximumQueryLength = 240

    /// How much of the selection the menu row shows before it elides.
    static let titleLength = 30

    /// The selection as a query: whitespace collapsed, trimmed, capped, and
    /// `nil` when there is nothing left. Pure, so the awkward cases — a
    /// selection of three newlines, a whole chapter, a stray tab — are
    /// testable without a web view.
    static func query(from raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumQueryLength))
    }

    /// The search row's title, with the user's own words in it so they can see
    /// what they are about to search for.
    static func searchTitle(for query: String) -> String {
        let shown = query.count > titleLength
            ? query.prefix(titleLength).trimmingCharacters(in: .whitespaces) + "…"
            : query
        return "Search for “\(shown)”"
    }

    // MARK: - The actions

    static func takeScreenshot(host: PearlPetHost) {
        host.captureScreenshot()
    }

    /// Opens a new tab and searches in it. Two calls the browser already had,
    /// in the order the omnibox would make them — and a new tab rather than
    /// this one, because she is standing on a page the user was reading.
    static func search(_ query: String, host: PearlPetHost) {
        host.newTab(url: nil)
        host.performSearch(query)
    }
}
