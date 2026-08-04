//
//  MCPBrowserBridge.swift
//  Cherry Browser
//
//  The only place in the MCP feature that touches a browser type.
//
//  ## Private windows are absent, not filtered
//
//  There is exactly ONE window enumeration in this file — `visibleViewModels` —
//  and every tool starts from it. It mirrors
//  `ExtensionManager.extensionVisibleViewModels`: read the registry, drop
//  `isPrivateMode`. Nothing else in this file reads
//  `BrowserViewModel.windowViewModels`, and no tool takes a `Tab` from anywhere
//  but a window that expression yielded.
//
//  That is deliberate and it is the point. A private window is not "included
//  then removed at the end" — a private tab is never in a collection any tool
//  can see, so there is no late `filter` for a future refactor to get wrong. One
//  misplaced predicate in a second enumeration is an incognito leak, and the
//  leak would be silent.
//
//  The corollary, also deliberate: `read_page` with a private tab's id answers
//  `not_found`, exactly as an id that never existed does. It must not say "that
//  tab is private", because the existence of a private window is itself the
//  secret.
//
//  ## Isolation
//
//  `@MainActor` by construction — this target sets
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated type here is
//  main-actor-isolated, as are `TabManager`, `BrowserViewModel`, `Tab` and both
//  repositories. Every method below returns a `Sendable` payload struct and
//  nothing else; see `MCPToolPayloads.swift` for why.
//

import AppKit
import Foundation
import WebKit

// MARK: - Rate limiting

/// A rolling-window call counter.
///
/// Only `open_tab` uses one, because it is the only tool that changes what is on
/// the user's screen. Main-actor-isolated like everything else here, so the
/// bookkeeping needs no lock.
final class MCPRateLimiter {

    private let limit: Int
    private let window: TimeInterval
    private let now: () -> Date
    private var accepted: [Date] = []

    /// - Parameter now: injected so a test can advance time instead of sleeping
    ///   through a real minute.
    init(limit: Int, window: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    /// Records a call and says whether it is allowed.
    ///
    /// Call this only for work that is actually about to happen — a refusal that
    /// never touched the screen must not consume the user's budget, or a client
    /// could rate-limit itself out of the tool with its own malformed URLs.
    func allow() -> Bool {
        let moment = now()
        accepted.removeAll { moment.timeIntervalSince($0) >= window }
        guard accepted.count < limit else { return false }
        accepted.append(moment)
        return true
    }

    /// Whole seconds until the oldest recorded call falls out of the window.
    /// At least 1, so a client never reads "retry in 0 seconds" and retries at once.
    func retryAfterSeconds() -> Int {
        guard let oldest = accepted.min() else { return 0 }
        let remaining = window - now().timeIntervalSince(oldest)
        return max(1, Int(remaining.rounded(.up)))
    }
}

// MARK: - Bridge

final class MCPBrowserBridge {

    static let shared = MCPBrowserBridge()

    /// Every window the registry knows about, private ones included.
    ///
    /// Injected so a test can supply a known set of windows rather than whatever
    /// the running app happens to have open. Deliberately the UNfiltered set:
    /// the privacy filter lives in `visibleViewModels` below and applies to
    /// whatever this yields, so a test that hands in a private window still
    /// cannot see through it.
    private let registeredViewModels: () -> [BrowserViewModel]

    private let history: HistoryRepository
    private let bookmarks: BookmarkRepository
    private let openTabLimiter: MCPRateLimiter

    init(
        registeredViewModels: @escaping () -> [BrowserViewModel] = {
            Array(BrowserViewModel.windowViewModels.values)
        },
        history: HistoryRepository = .shared,
        bookmarks: BookmarkRepository = .shared,
        openTabLimiter: MCPRateLimiter = MCPRateLimiter(limit: 5, window: 60)
    ) {
        self.registeredViewModels = registeredViewModels
        self.history = history
        self.bookmarks = bookmarks
        self.openTabLimiter = openTabLimiter
    }

    // MARK: Window enumeration — the one and only

    /// THE window enumeration. Mirrors
    /// `ExtensionManager.extensionVisibleViewModels` (`ExtensionManager.swift`),
    /// which is the same rule the extension system enforces.
    ///
    /// Ordered front-to-back by AppKit's window order, so a model reading the
    /// first window is reading the one the user is looking at. Windows with no
    /// `NSWindow` yet (and every window in a unit test) sort last, by id, so the
    /// order is total and stable across calls.
    private var visibleViewModels: [BrowserViewModel] {
        let zOrder = NSApp?.windows ?? []
        return registeredViewModels()
            .filter { !$0.isPrivateMode }
            .sorted { lhs, rhs in
                let left = lhs.associatedWindow.flatMap { zOrder.firstIndex(of: $0) } ?? Int.max
                let right = rhs.associatedWindow.flatMap { zOrder.firstIndex(of: $0) } ?? Int.max
                if left != right { return left < right }
                return lhs.windowID.uuidString < rhs.windowID.uuidString
            }
    }

    /// A window by the `window_id` a client passed back.
    ///
    /// Resolved against `visibleViewModels`, so a private window's id is simply
    /// unknown here — same answer as a window that has since closed.
    private func visibleViewModel(id: UUID) -> BrowserViewModel? {
        visibleViewModels.first { $0.windowID == id }
    }

    /// The window and tab a `tab_id` names, or nil.
    private func locate(tabID: UUID) -> (window: BrowserViewModel, tab: Tab)? {
        for viewModel in visibleViewModels {
            if let tab = viewModel.tabManager.tabs.first(where: { $0.id == tabID }) {
                return (viewModel, tab)
            }
        }
        return nil
    }

    /// What `read_page` reads when no `tab_id` was given: the focused tab of the
    /// key window, else of the frontmost non-private window.
    ///
    /// `TabManager.focusedTab` is split-view aware, so a split window resolves to
    /// the pane the user is actually in.
    private func defaultTarget() -> (window: BrowserViewModel, tab: Tab)? {
        let candidates = visibleViewModels
        let keyed = candidates.first {
            guard let window = $0.associatedWindow else { return false }
            return window === NSApp?.keyWindow
        }
        guard let viewModel = keyed ?? candidates.first,
              let tab = viewModel.tabManager.focusedTab
        else {
            return nil
        }
        return (viewModel, tab)
    }

    private func isSelected(_ tab: Tab, in viewModel: BrowserViewModel) -> Bool {
        let manager = viewModel.tabManager
        return tab.id == manager.selectedTabID || tab.id == manager.secondarySelectedTabID
    }

    // MARK: - list_tabs

    func listTabs(windowID: UUID?) -> MCPListTabsPayload {
        let windows: [BrowserViewModel]
        if let windowID {
            guard let only = visibleViewModel(id: windowID) else {
                // Deliberately not an error, and deliberately says nothing about
                // why. An unknown id, a closed window and a private window all
                // land here and must be indistinguishable.
                return MCPListTabsPayload(
                    windows: [],
                    totalTabs: 0,
                    truncated: false,
                    note: "No open window has that window_id. Call list_tabs with no arguments for the current windows."
                )
            }
            windows = [only]
        } else {
            windows = visibleViewModels
        }

        let totalTabs = windows.reduce(0) { $0 + $1.tabManager.tabs.count }
        var remaining = MCPResultCaps.tabs
        var payloads: [MCPWindowPayload] = []

        for viewModel in windows {
            guard remaining > 0 else { break }
            let manager = viewModel.tabManager
            let tabs = manager.tabs.prefix(remaining).map { tab in
                MCPTabPayload(
                    tabID: tab.id.uuidString,
                    title: tab.displayTitle.mcpTruncated(to: MCPResultCaps.tabTitleChars),
                    url: tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars),
                    selected: isSelected(tab, in: viewModel),
                    pinned: tab.isPinned,
                    sleeping: tab.isSleeping,
                    loading: tab.isLoading,
                    internalPage: tab.internalPage?.rawValue
                )
            }
            remaining -= tabs.count
            payloads.append(MCPWindowPayload(
                windowID: viewModel.windowID.uuidString,
                isActive: isKeyWindow(viewModel),
                tabCount: manager.tabs.count,
                tabs: Array(tabs)
            ))
        }

        let shown = payloads.reduce(0) { $0 + $1.tabs.count }
        let truncated = shown < totalTabs
        return MCPListTabsPayload(
            windows: payloads,
            totalTabs: totalTabs,
            truncated: truncated,
            note: truncated
                ? "\(shown) of \(totalTabs) tabs shown; pass window_id to narrow."
                : nil
        )
    }

    private func isKeyWindow(_ viewModel: BrowserViewModel) -> Bool {
        guard let window = viewModel.associatedWindow else { return false }
        return window === NSApp?.keyWindow
    }

    // MARK: - open_tab

    /// Schemes `open_tab` will open. Everything else is refused by name.
    static let openableSchemes: Set<String> = ["http", "https"]

    func openTab(url: URL, windowID: UUID?, activate: Bool) -> MCPOpenTabOutcome {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .refused(MCPOpenTabRefusalPayload(
                reason: .invalidURL,
                detail: "\"\(url.absoluteString)\" has no scheme. Pass an absolute http:// or https:// URL.",
                scheme: nil,
                retryAfterSeconds: nil
            ))
        }

        guard Self.openableSchemes.contains(scheme) else {
            return .refused(MCPOpenTabRefusalPayload(
                reason: .unsupportedScheme,
                detail: "Cherry will not open a \(scheme): URL from an MCP client. "
                    + "open_tab opens http and https only"
                    + (scheme == CherryPage.urlScheme
                        ? " — cherry: addresses are Cherry's own internal pages, not the web."
                        : "."),
                scheme: scheme,
                retryAfterSeconds: nil
            ))
        }

        // Window resolution before the limiter, so a request naming a window that
        // is not there does not spend the user's budget either.
        let target: BrowserViewModel?
        if let windowID {
            // An unknown id — including a private window's — falls back rather
            // than failing, per the plan, and never reveals which case it was.
            target = visibleViewModel(id: windowID) ?? visibleViewModels.first
        } else {
            target = visibleViewModels.first
        }
        guard let viewModel = target else {
            return .refused(MCPOpenTabRefusalPayload(
                reason: .noWindow,
                detail: "Cherry has no open window to put a tab in. Ask the user to open one.",
                scheme: nil,
                retryAfterSeconds: nil
            ))
        }

        guard openTabLimiter.allow() else {
            return .refused(MCPOpenTabRefusalPayload(
                reason: .rateLimited,
                detail: "open_tab is limited to 5 tabs per minute so it cannot fill the user's screen. "
                    + "Wait, or ask the user to open the page themselves.",
                scheme: nil,
                retryAfterSeconds: openTabLimiter.retryAfterSeconds()
            ))
        }

        let tab = viewModel.tabManager.newTab(url: url, switchTo: activate)
        return .opened(MCPOpenTabPayload(
            tabID: tab.id.uuidString,
            windowID: viewModel.windowID.uuidString,
            url: url.absoluteString.mcpTruncated(to: MCPResultCaps.urlChars),
            activated: activate
        ))
    }

    // MARK: - search_history

    /// - Note: `HistoryRepository.searchHistory(query:)` scans the whole
    ///   in-memory history on the main actor. `MCPHistorySearchCostTests`
    ///   measures that scan against 20,000 rows and is the gate on whether this
    ///   path stays as it is.
    func searchHistory(query: String, limit: Int, sinceDays: Int?) -> MCPSearchHistoryPayload {
        let capped = min(max(1, limit), MCPResultCaps.historyLimitMaximum)
        let clamped = capped < limit
        var matches = history.searchHistory(query: query)

        if let sinceDays {
            let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86_400)
            matches = matches.filter { $0.visitDate >= cutoff }
        }
        matches.sort { $0.visitDate > $1.visitDate }

        let results = matches.prefix(capped).map { item in
            MCPHistoryEntryPayload(
                title: item.title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
                url: item.url.absoluteString.mcpTruncated(to: MCPResultCaps.urlChars),
                visitedAt: item.visitDate,
                visitCount: item.visitCount
            )
        }

        let truncated = results.count < matches.count
        return MCPSearchHistoryPayload(
            query: query,
            results: Array(results),
            returned: results.count,
            totalMatches: matches.count,
            truncated: truncated,
            note: Self.searchNote(
                returned: results.count,
                total: matches.count,
                order: "most recent first",
                clamped: clamped,
                maximum: MCPResultCaps.historyLimitMaximum,
                narrowing: "narrow the query"
            )
        )
    }

    /// What a client is told when a search hit a cap.
    ///
    /// Never nothing. A bare 25-of-318 with no explanation reads to a model as
    /// "these are all the matches", and it will answer the user as if they were.
    private static func searchNote(
        returned: Int,
        total: Int,
        order: String,
        clamped: Bool,
        maximum: Int,
        narrowing: String
    ) -> String? {
        var parts: [String] = []
        if returned < total {
            parts.append("\(returned) of \(total) matches shown, \(order)")
        }
        if clamped {
            parts.append("limit was capped at \(maximum)")
        } else if returned < total {
            parts.append("raise limit (max \(maximum)) or \(narrowing)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "."
    }

    // MARK: - search_bookmarks

    func searchBookmarks(query: String, folder: String?, limit: Int) -> MCPSearchBookmarksPayload {
        let capped = min(max(1, limit), MCPResultCaps.bookmarkLimitMaximum)
        let clamped = capped < limit
        var matches = bookmarks.searchBookmarks(query: query)

        if let folder {
            matches = matches.filter { $0.folder?.caseInsensitiveCompare(folder) == .orderedSame }
        }
        matches.sort { $0.createdAt > $1.createdAt }

        let results = matches.prefix(capped).map { bookmark in
            MCPBookmarkEntryPayload(
                title: bookmark.title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
                url: bookmark.url.absoluteString.mcpTruncated(to: MCPResultCaps.urlChars),
                folder: bookmark.folder?.mcpTruncated(to: MCPResultCaps.folderChars),
                inBookmarkBar: bookmark.isInBookmarkBar,
                createdAt: bookmark.createdAt
            )
        }

        let truncated = results.count < matches.count
        return MCPSearchBookmarksPayload(
            query: query,
            results: Array(results),
            returned: results.count,
            totalMatches: matches.count,
            truncated: truncated,
            note: Self.searchNote(
                returned: results.count,
                total: matches.count,
                order: "newest first",
                clamped: clamped,
                maximum: MCPResultCaps.bookmarkLimitMaximum,
                narrowing: "pass folder"
            )
        )
    }

    // MARK: - read_page

    /// The refusal ladder, then extraction, then chunking.
    ///
    /// `async` rather than something wrapped in `MainActor.run` because
    /// `PageAIExtractor.extract` awaits `evaluateJavaScript`, and the main actor
    /// has to be released across that await — a `MainActor.run` block cannot
    /// suspend, and blocking the main thread on a page's JavaScript would hitch
    /// the UI on every call.
    func readPage(tabID: UUID?, offset: Int) async -> MCPReadPageOutcome {
        let located: (window: BrowserViewModel, tab: Tab)?
        if let tabID {
            located = locate(tabID: tabID)
        } else {
            located = defaultTarget()
        }

        guard let (viewModel, tab) = located else {
            return .unreadable(MCPUnreadablePayload(
                reason: .notFound,
                detail: tabID == nil
                    ? "Cherry has no open window with a tab to read."
                    : "No open tab has that tab_id. Call list_tabs for the current ids.",
                tabID: tabID?.uuidString,
                windowID: nil,
                url: nil
            ))
        }

        let identity = (
            tabID: tab.id.uuidString,
            windowID: viewModel.windowID.uuidString,
            url: tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars)
        )

        func refuse(_ reason: MCPUnreadableReason, _ detail: String) -> MCPReadPageOutcome {
            .unreadable(MCPUnreadablePayload(
                reason: reason,
                detail: detail,
                tabID: identity.tabID,
                windowID: identity.windowID,
                url: identity.url
            ))
        }

        // 1. Asleep. `Tab.sleep()` sets `webView = nil`, and `wake()` deliberately
        //    performs no load — the web view is only recreated when the tab is
        //    displayed — so waking from here would leave a tab that is awake,
        //    blank, and no longer eligible for the sleep timer. Refusing is both
        //    correct and free.
        if tab.isSleeping {
            return refuse(
                .sleeping,
                "This tab is asleep and has no live web view. Its URL is \(identity.url) — "
                    + "open_tab it to load a fresh copy, or ask the user to switch to it."
            )
        }

        // 2. A cherry:// internal page. THE trap in this whole file.
        //
        //    `Tab.openInternalPage` deliberately KEEPS `webView` and `url`
        //    pointing at the site the internal page is covering, so Back restores
        //    it with history intact. A naive `tab.webView` read here therefore
        //    returns the text of a page the user is NOT looking at, labelled with
        //    the settings page's identity. Cherry's own AI had exactly this bug in
        //    `toggleAskThisPage`; the guard there —
        //    `tab.internalPage == nil, !tab.showHomePage, let webView = tab.webView`
        //    — is reproduced by steps 2, 3 and 6 of this ladder, in that order.
        if let page = tab.internalPage {
            return refuse(
                .internalPage,
                "This tab is showing Cherry's own \(page.displayTitle) page (\(page.url.absoluteString)), "
                    + "which has no readable page text. Nothing was read."
            )
        }

        // 3. The home / new-tab page.
        if tab.showHomePage {
            return refuse(
                .homePage,
                "This tab is on Cherry's new-tab page, which has no article text. "
                    + "Use open_tab to load a page, then read it."
            )
        }

        // 4. A PDF. WebKit's PDF viewer has no DOM the extractor's heuristics
        //    apply to, so a read returns viewer chrome or nothing — say so rather
        //    than hand a model junk.
        //
        //    `BrowserViewModel.isViewingPDF` is a per-WINDOW flag set from the
        //    DISPLAYED page's navigation, so it only speaks for a tab the window
        //    is currently showing; applying it to any tab in the window would
        //    wrongly refuse the window's other tabs. The URL check covers the
        //    background-PDF case that flag cannot see.
        if (viewModel.isViewingPDF && isSelected(tab, in: viewModel))
            || tab.url?.pathExtension.lowercased() == "pdf" {
            return refuse(
                .pdf,
                "This tab is a PDF (\(identity.url)). Cherry's text extraction does not apply to "
                    + "WebKit's PDF viewer, so nothing was read."
            )
        }

        // 5. Never displayed, so no web view was ever built and nothing loaded.
        //    A background tab from `open_tab(activate: false)` is in this state
        //    until the user selects it.
        guard let webView = tab.webView else {
            return refuse(
                .notRendered,
                "This tab has never been displayed, so Cherry has not created a web view for it and "
                    + "nothing has loaded. Its URL is \(identity.url) — ask the user to switch to it, "
                    + "or call open_tab with activate: true."
            )
        }

        // 6. There is a live page. Read it — including while it is still loading:
        //    `PageAIExtractor` has a layout-independent last resort, so a mid-load
        //    page usually yields something, and blocking until load would risk the
        //    client's 60-second first-byte timer.
        let loading = tab.isLoading
        guard let content = await PageAIExtractor.extract(from: webView) else {
            return refuse(
                .noContent,
                loading
                    ? "This page is still loading and has no extractable text yet. Try again shortly."
                    : "Cherry found no readable text on this page."
            )
        }

        return .page(Self.chunk(
            content,
            offset: offset,
            tabID: identity.tabID,
            windowID: identity.windowID,
            url: identity.url,
            fallbackTitle: tab.displayTitle,
            loading: loading
        ))
    }

    /// Slices extracted text into one `read_page` answer.
    ///
    /// Offsets and lengths are counted in `Character`s, consistently, so a client
    /// walking a page by `next_offset` sees no overlap and no gap: each call
    /// returns `[offset, offset + returned_chars)` and hands back exactly
    /// `offset + returned_chars`.
    ///
    /// `nonisolated static` because it is pure string work — no reason for it to
    /// hold the main actor, and it is directly testable.
    nonisolated static func chunk(
        _ content: ExtractedPageContent,
        offset: Int,
        tabID: String,
        windowID: String,
        url: String,
        fallbackTitle: String,
        loading: Bool
    ) -> MCPReadPagePayload {
        let characters = Array(content.text)
        let total = characters.count
        let start = min(max(0, offset), total)
        let end = min(start + MCPResultCaps.readPageChars, total)
        let slice = String(characters[start..<end])
        let hasMore = end < total

        let note: String?
        if hasMore {
            note = "Showing characters \(start)–\(end) of \(total). "
                + "Call read_page again with offset: \(end) for the next chunk."
        } else if start == total, total > 0 {
            note = "offset \(offset) is at or past the end of this page (total_chars \(total)); "
                + "nothing left to read."
        } else {
            note = nil
        }

        let title = content.title.isEmpty ? fallbackTitle : content.title
        return MCPReadPagePayload(
            tabID: tabID,
            windowID: windowID,
            title: title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
            url: url,
            text: slice,
            offset: start,
            returnedChars: slice.count,
            totalChars: total,
            hasMore: hasMore,
            nextOffset: hasMore ? end : nil,
            loading: loading,
            note: note
        )
    }
}
