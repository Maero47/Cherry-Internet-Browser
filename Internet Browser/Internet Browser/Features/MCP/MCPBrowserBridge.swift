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

    /// THE tab enumeration, and the second half of the privacy gate.
    ///
    /// A window's `isPrivateMode` and a tab's `isPrivate` DIVERGE, by design, in
    /// code that already ships. `BrowserViewModel.transferTab(tabID:to:)` — and
    /// `detachTab`'s re-attach branch — move a `Tab` between windows with no
    /// privacy check at all, while the tear-off-to-a-NEW-window path does preserve
    /// it (`BrowserView` sets `vm.isPrivateMode = existingTab.isPrivate`). Both are
    /// wired to the tab bar. So dragging one incognito tab onto a normal window's
    /// tab bar leaves a tab carrying `isPrivate == true`, still holding its live
    /// private-store `WKWebView`, inside a `TabManager` whose view model is not
    /// private.
    ///
    /// Filtering only on the window would publish that tab's URL and title in
    /// `list_tabs` and let `read_page` extract the private page in full: it is not
    /// asleep, not internal, not the home page, and it has a web view, so every
    /// rung of the ladder passes.
    ///
    /// `TabManager.notifyExtensionManager` gates twice for exactly this reason —
    /// `guard !tab.isPrivate else { return }` on top of the window-level exclusion.
    /// This is the other half.
    private func visibleTabs(in viewModel: BrowserViewModel) -> [Tab] {
        viewModel.tabManager.tabs.filter { !$0.isPrivate }
    }

    /// A window by the `window_id` a client passed back.
    ///
    /// Resolved against `visibleViewModels`, so a private window's id is simply
    /// unknown here — same answer as a window that has since closed.
    private func visibleViewModel(id: UUID) -> BrowserViewModel? {
        visibleViewModels.first { $0.windowID == id }
    }

    /// The window and tab a `tab_id` names, or nil.
    ///
    /// Goes through both gates: only non-private windows, and within them only
    /// non-private tabs. A private tab's id is therefore not a key here, and the
    /// answer is byte-identical to an id that never existed.
    func locate(tabID: UUID) -> (window: BrowserViewModel, tab: Tab)? {
        for viewModel in visibleViewModels {
            if let tab = visibleTabs(in: viewModel).first(where: { $0.id == tabID }) {
                return (viewModel, tab)
            }
        }
        return nil
    }

    /// What `read_page` reads when no `tab_id` was given: the focused tab of the
    /// key window, else of the frontmost non-private window.
    ///
    /// `TabManager.focusedTab` is split-view aware, so a split window resolves to
    /// the pane the user is actually in — but it can also BE a private tab that was
    /// moved into this window, so it is checked against `visibleTabs` rather than
    /// trusted. A focused private tab reads as "no tab to read", not as itself.
    private func defaultTarget() -> (window: BrowserViewModel, tab: Tab)? {
        let candidates = visibleViewModels
        let keyed = candidates.first {
            guard let window = $0.associatedWindow else { return false }
            return window === NSApp?.keyWindow
        }
        guard let viewModel = keyed ?? candidates.first,
              let focused = viewModel.tabManager.focusedTab,
              visibleTabs(in: viewModel).contains(where: { $0 === focused })
        else {
            return nil
        }
        return (viewModel, focused)
    }

    private func isSelected(_ tab: Tab, in viewModel: BrowserViewModel) -> Bool {
        let manager = viewModel.tabManager
        return tab.id == manager.selectedTabID || tab.id == manager.secondarySelectedTabID
    }

    // MARK: - The shared refusal ladder

    /// The tab a page-facing tool call names, or the refusal that says there is
    /// none. `nil` means "whatever the user is looking at".
    ///
    /// Shared by `read_page` and `read_elements` so the `not_found` wording is
    /// written once — which is not cosmetic. `MCPBrowserBridgeTests` asserts that
    /// a private tab's id and an id that never existed produce byte-identical
    /// refusals, and that property only holds while there is one sentence.
    func resolveTab(tabID: UUID?) -> Result<(window: BrowserViewModel, tab: Tab), MCPUnreadableRefusal> {
        let located = tabID.map { locate(tabID: $0) } ?? defaultTarget()
        guard let located else {
            return .failure(MCPUnreadableRefusal(
                .notFound,
                tabID == nil
                    ? "Cherry has no open window with a tab to read."
                    : "No open tab has that tab_id. Call list_tabs for the current ids."
            ))
        }
        return .success(located)
    }

    /// THE refusal ladder: sleeping → internal page → home page → never-rendered
    /// → PDF, and a live `WKWebView` if every rung passes.
    ///
    /// There is one of these and there must stay one of these. `read_page` and
    /// `read_elements` ask different questions of a page, but "is there a page
    /// here at all" is the same question, and a second copy of these five rungs
    /// would drift — the `cherry://` rung in particular, which this codebase has
    /// been bitten by twice and which is the difference between refusing and
    /// silently answering about a page the user is not looking at.
    ///
    /// `async` because the PDF rung asks the DOCUMENT rather than guessing from
    /// the URL, and the main actor is released across that call.
    func readableWebView(
        for tab: Tab,
        _ purpose: MCPWebViewPurpose
    ) async -> Result<WKWebView, MCPUnreadableRefusal> {
        let url = tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars)

        // 1. Asleep. `Tab.sleep()` sets `webView = nil`, and `wake()` deliberately
        //    performs no load — the web view is only recreated when the tab is
        //    displayed — so waking from here would leave a tab that is awake,
        //    blank, and no longer eligible for the sleep timer. Refusing is both
        //    correct and free.
        if tab.isSleeping {
            return .failure(MCPUnreadableRefusal(
                .sleeping,
                "This tab is asleep and has no live web view. Its URL is \(url) — "
                    + "open_tab it to load a fresh copy, or ask the user to switch to it."
            ))
        }

        // 2. A cherry:// internal page, or the vestigial settings-page flag. THE
        //    trap in this whole file.
        //
        //    `Tab.openInternalPage` deliberately KEEPS `webView` and `url`
        //    pointing at the site the internal page is covering, so Back restores
        //    it with history intact. A naive `tab.webView` read here therefore
        //    hands back a page the user is NOT looking at, labelled with the
        //    settings page's identity. Cherry's own AI had exactly this bug in
        //    `toggleAskThisPage`; the guard there —
        //    `tab.internalPage == nil, !tab.showHomePage, let webView = tab.webView`
        //    — is reproduced by rungs 2, 3 and 4, in that order.
        //
        //    `showSettingsPage` is included because it is a cover-the-web-view flag
        //    of exactly the same shape, `BrowserView` still has a live render branch
        //    for it, and `BrowserViewModel.canZoom` checks all three together. It is
        //    vestigial today; if it is ever set again this rung already holds.
        if tab.internalPage != nil || tab.showSettingsPage {
            // The internal page's OWN address, never `displayURL`.
            //
            // For `internalPage` those are the same thing. For `showSettingsPage`
            // they are not: `Tab.displayURL` only returns a `cherry://` address when
            // `internalPage != nil`, so on a settings-flag tab it returns the
            // COVERED SITE's URL — which this rung exists to withhold. A test caught
            // exactly that. Deriving the address from the page rather than the tab
            // makes the leak unreachable rather than merely absent.
            let page = tab.internalPage ?? .settings
            return .failure(MCPUnreadableRefusal(
                .internalPage,
                "This tab is showing Cherry's own \(page.displayTitle) page "
                    + "(\(page.url.absoluteString)), \(purpose.internalPageClause)",
                urlOverride: page.url.absoluteString
            ))
        }

        // 3. The home / new-tab page.
        if tab.showHomePage {
            return .failure(MCPUnreadableRefusal(
                .homePage,
                "This tab is on Cherry's new-tab page, \(purpose.homePageClause)"
            ))
        }

        // 4. Never displayed, so no web view was ever built and nothing loaded.
        //    A background tab from `open_tab(activate: false)` is in this state
        //    until the user selects it. The action layer inherits this as a hard
        //    limit: nothing can act on a tab the user has never had on screen.
        guard let webView = tab.webView else {
            return .failure(MCPUnreadableRefusal(
                .notRendered,
                "This tab has never been displayed, so Cherry has not created a web view for it and "
                    + "nothing has loaded. Its URL is \(url) — ask the user to switch to it, "
                    + "or call open_tab with activate: true."
            ))
        }

        // 5. A PDF, asked of the DOCUMENT rather than guessed from the URL.
        //
        //    This used to read `BrowserViewModel.isViewingPDF` plus
        //    `url.pathExtension == "pdf"`, and both were wrong in a way that
        //    mattered. `isViewingPDF` is per-WINDOW and last-writer-wins across
        //    split panes, so a PDF in one pane falsely refused the article in the
        //    other — the same "one tab's state answering for another's" bug as the
        //    cherry:// trap. And the extension test misses every extensionless PDF
        //    (`arxiv.org/pdf/2401.00001`), which then degraded to a misleading
        //    `no_content`.
        //
        //    `document.contentType` is the real answer: verified to return
        //    `application/pdf` for a PDF in WebKit's viewer and `text/html` for a
        //    page, per tab, regardless of URL. It costs one `evaluateJavaScript`,
        //    and the main actor is released across it.
        if await Self.isPDFDocument(webView) {
            return .failure(MCPUnreadableRefusal(
                .pdf,
                "This tab is a PDF (\(url)). \(purpose.pdfClause)"
            ))
        }

        return .success(webView)
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

        // Every count below is over `visibleTabs`, never `tabManager.tabs`. A raw
        // `tabs.count` in `tab_count` or `total_tabs` would report the presence of
        // a private tab even while withholding it, which is the same leak one step
        // quieter.
        let totalTabs = windows.reduce(0) { $0 + visibleTabs(in: $1).count }
        var budget = MCPBudget(chars: MCPResultCaps.payloadChars, items: MCPResultCaps.tabs)
        var payloads: [MCPWindowPayload] = []

        for viewModel in windows {
            guard budget.hasRoom else { break }
            let visible = visibleTabs(in: viewModel)
            var tabs: [MCPTabPayload] = []
            for tab in visible {
                let payload = MCPTabPayload(
                    tabID: tab.id.uuidString,
                    title: tab.displayTitle.mcpTruncated(to: MCPResultCaps.tabTitleChars),
                    url: tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars),
                    selected: isSelected(tab, in: viewModel),
                    pinned: tab.isPinned,
                    sleeping: tab.isSleeping,
                    loading: tab.isLoading,
                    internalPage: tab.internalPage?.rawValue
                )
                guard budget.admit(chars: payload.approximateChars) else { break }
                tabs.append(payload)
            }
            // A window that contributed nothing is left out entirely rather than
            // reported as an empty one — an empty `tabs` array reads as "this
            // window has no tabs", which is a different and false statement.
            guard !tabs.isEmpty else { break }
            payloads.append(MCPWindowPayload(
                windowID: viewModel.windowID.uuidString,
                isActive: isKeyWindow(viewModel),
                tabCount: visible.count,
                tabs: tabs
            ))
        }

        let shown = payloads.reduce(0) { $0 + $1.tabs.count }
        let truncated = shown < totalTabs
        return MCPListTabsPayload(
            windows: payloads,
            totalTabs: totalTabs,
            truncated: truncated,
            note: truncated
                ? "\(shown) of \(totalTabs) tabs shown (\(budget.limitHitDescription)); "
                    + "pass window_id to narrow."
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

        var budget = MCPBudget(chars: MCPResultCaps.payloadChars, items: capped)
        var results: [MCPHistoryEntryPayload] = []
        for item in matches {
            let payload = MCPHistoryEntryPayload(
                title: item.title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
                url: item.url.absoluteString.mcpTruncated(to: MCPResultCaps.urlChars),
                visitedAt: item.visitDate,
                visitCount: item.visitCount
            )
            guard budget.admit(chars: payload.approximateChars) else { break }
            results.append(payload)
        }

        let truncated = results.count < matches.count
        return MCPSearchHistoryPayload(
            query: query,
            results: results,
            returned: results.count,
            totalMatches: matches.count,
            truncated: truncated,
            note: Self.searchNote(
                returned: results.count,
                total: matches.count,
                order: "most recent first",
                clamped: clamped,
                maximum: MCPResultCaps.historyLimitMaximum,
                narrowing: "narrow the query",
                budget: budget
            )
        )
    }

    /// What a client is told when a search hit a cap.
    ///
    /// Never nothing. A bare 25-of-318 with no explanation reads to a model as
    /// "these are all the matches", and it will answer the user as if they were.
    ///
    /// The three reasons an answer stops are different advice, so they are named
    /// separately: its own `limit`, a `limit` above the tool's maximum, and the
    /// whole-result character budget — where raising `limit` would not help at all.
    private static func searchNote(
        returned: Int,
        total: Int,
        order: String,
        clamped: Bool,
        maximum: Int,
        narrowing: String,
        budget: MCPBudget
    ) -> String? {
        var parts: [String] = []
        if returned < total {
            parts.append("\(returned) of \(total) matches shown, \(order)")
        }
        if budget.exhaustedBy == .chars {
            parts.append("stopped at the result size limit of \(MCPResultCaps.payloadChars) "
                + "characters, so raising limit will not return more — \(narrowing)")
        } else if clamped {
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

        var budget = MCPBudget(chars: MCPResultCaps.payloadChars, items: capped)
        var results: [MCPBookmarkEntryPayload] = []
        for bookmark in matches {
            let payload = MCPBookmarkEntryPayload(
                title: bookmark.title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
                url: bookmark.url.absoluteString.mcpTruncated(to: MCPResultCaps.urlChars),
                folder: bookmark.folder?.mcpTruncated(to: MCPResultCaps.folderChars),
                inBookmarkBar: bookmark.isInBookmarkBar,
                createdAt: bookmark.createdAt
            )
            guard budget.admit(chars: payload.approximateChars) else { break }
            results.append(payload)
        }

        let truncated = results.count < matches.count
        return MCPSearchBookmarksPayload(
            query: query,
            results: results,
            returned: results.count,
            totalMatches: matches.count,
            truncated: truncated,
            note: Self.searchNote(
                returned: results.count,
                total: matches.count,
                order: "newest first",
                clamped: clamped,
                maximum: MCPResultCaps.bookmarkLimitMaximum,
                narrowing: "pass folder",
                budget: budget
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
        let viewModel: BrowserViewModel
        let tab: Tab
        switch resolveTab(tabID: tabID) {
        case .success(let located):
            (viewModel, tab) = located
        case .failure(let refusal):
            return .unreadable(MCPUnreadablePayload(
                reason: refusal.reason,
                detail: refusal.detail,
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

        // The ladder — sleeping, cherry://, home page, never-rendered, PDF —
        // lives in `readableWebView(for:_:)` and is shared with `read_elements`.
        //
        // Worth knowing why the PDF rung must refuse at all: WebKit's PDF viewer
        // DOES expose a DOM — the probe measured 839 characters of viewer chrome
        // in `document.body.textContent`. Extraction happens to return nil for it
        // on this WebKit build, but that is luck, not a guarantee, and the failure
        // mode is viewer chrome returned as though it were the paper.
        let webView: WKWebView
        switch await readableWebView(for: tab, .readingText) {
        case .success(let live):
            webView = live
        case .failure(let refusal):
            return .unreadable(MCPUnreadablePayload(
                reason: refusal.reason,
                detail: refusal.detail,
                tabID: identity.tabID,
                windowID: identity.windowID,
                url: refusal.urlOverride ?? identity.url
            ))
        }

        // There is a live page. Read it — including while it is still loading:
        // `PageAIExtractor` has a layout-independent last resort, so a mid-load
        // page usually yields something, and blocking until load would risk the
        // client's 60-second first-byte timer.
        let loading = tab.isLoading
        guard let content = await PageAIExtractor.extract(from: webView) else {
            return refuse(
                .noContent,
                loading
                    ? "This page is still loading and has no extractable text yet. Try again shortly."
                    : "Cherry found no readable text on this page."
            )
        }

        // The URL is reported from the LIVE document here, not from the tab model.
        // They diverge during navigation and across redirects, and a mismatch means
        // text from page A labelled as page B.
        //
        // Only on this branch. The refusals above keep using `displayURL`, because
        // on a cherry:// tab `webView.url` IS the covered site — reporting it there
        // would leak exactly what rung 2 exists to withhold.
        let liveURL = (webView.url?.absoluteString).map { $0.mcpTruncated(to: MCPResultCaps.urlChars) }

        return .page(Self.chunk(
            content,
            offset: offset,
            tabID: identity.tabID,
            windowID: identity.windowID,
            url: liveURL ?? identity.url,
            fallbackTitle: tab.displayTitle,
            loading: loading
        ))
    }

    /// Whether WebKit is displaying this web view's content as a PDF.
    ///
    /// Asks the document, so it is per-tab, extension-independent, and cannot false
    /// positive on an HTML page served at a `.pdf` path. A thrown or unexpected
    /// result means "not a PDF" — the extraction path below handles that safely, and
    /// refusing a readable page because one JS call failed would be worse.
    private static func isPDFDocument(_ webView: WKWebView) async -> Bool {
        let contentType = try? await webView.evaluateJavaScript("document.contentType")
        return (contentType as? String)?.lowercased() == "application/pdf"
    }

    /// Slices extracted text into one `read_page` answer.
    ///
    /// Offsets and lengths are counted in `Character`s, consistently, so a client
    /// walking a page by `next_offset` sees no overlap and no gap: each call
    /// returns `[offset, offset + returned_chars)` and hands back exactly
    /// `offset + returned_chars`.
    ///
    /// ## Why this does not build an array
    ///
    /// It used to open with `Array(content.text)` — full grapheme-cluster
    /// segmentation of the entire page, synchronously, with nothing bounding
    /// `content.text` first, because the 40,000 cap only applies once the array
    /// exists. Walking an N-character page therefore did O(N) allocation per call
    /// for O(N/40000) calls, and only `open_tab` is rate-limited, so a client could
    /// repeat it freely.
    ///
    /// Two changes: the page is clamped to `readPageTotalChars` before anything
    /// walks it (with `page_clamped` and a `note` saying so), and the slice is taken
    /// by `String.Index` rather than by materialising an array. Each call is now
    /// bounded work over a bounded string.
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
        let extractedChars = content.text.count
        let clamped = extractedChars > MCPResultCaps.readPageTotalChars
        // One `prefix` on the clamping path only; the common case does not copy.
        let text = clamped
            ? String(content.text.prefix(MCPResultCaps.readPageTotalChars))
            : content.text
        let total = clamped ? MCPResultCaps.readPageTotalChars : extractedChars

        let start = min(max(0, offset), total)
        let end = min(start + MCPResultCaps.readPageChars, total)
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: end - start)
        let slice = String(text[lower..<upper])
        let hasMore = end < total

        var notes: [String] = []
        if hasMore {
            notes.append("Showing characters \(start)–\(end) of \(total); "
                + "call read_page again with offset: \(end) for the next chunk")
        } else if start == total, total > 0 {
            notes.append("offset \(offset) is at or past the end of this page "
                + "(total_chars \(total)); nothing left to read")
        }
        if clamped {
            notes.append("this page extracted to \(extractedChars) characters and was clamped to "
                + "the first \(total); the rest is not reachable through read_page")
        }
        if content.source?.isSourceDisplayed == false {
            notes.append("text_source is \(content.source?.rawValue ?? "") — this text came from part "
                + "of the document that is not being displayed at all (a hidden or collapsed panel, "
                + "off-screen navigation), so do not tell the user it is what they are looking at")
        }

        let title = content.title.isEmpty ? fallbackTitle : content.title
        return MCPReadPagePayload(
            tabID: tabID,
            windowID: windowID,
            title: title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
            url: url,
            text: slice,
            offset: start,
            returnedChars: end - start,
            totalChars: total,
            hasMore: hasMore,
            nextOffset: hasMore ? end : nil,
            loading: loading,
            textSource: content.source?.rawValue,
            sourceDisplayed: content.source?.isSourceDisplayed,
            pageClamped: clamped ? true : nil,
            note: notes.isEmpty ? nil : notes.joined(separator: ". ") + "."
        )
    }
}
