//
//  MCPBrowserBridgeTests.swift
//  Internet BrowserTests
//
//  This is where the MCP feature starts handing the user's own data to an
//  external process, so these are the tests that matter most in it.
//
//  Two of them are the ones to read first:
//
//  * `testPrivateWindowsTabsAreAbsentAndItsPagesUnreadable` — a private window
//    open, its tabs absent from `list_tabs`, and its pages unreadable by
//    `read_page` even when the tab id is passed in correctly. That is what an
//    incognito leak would look like, and it would be silent.
//  * `testInternalPageTabNeverLeaksTheCoveredSitesText` — a real page loaded into
//    a real `WKWebView`, then covered by `cherry://settings`.
//    `Tab.openInternalPage` deliberately KEEPS that web view alive so Back can
//    restore it, so a naive `tab.webView` read returns the text of a page the
//    user is not looking at, labelled as the settings page. It carries a positive
//    control: if the sentinel page turns out not to be readable at all, the test
//    fails rather than passing vacuously.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class MCPBrowserBridgeTests: XCTestCase {

    /// Windows this test is asserting about. Held strongly for the duration:
    /// `BrowserViewModel.windowViewModels` is a registry of WEAK boxes, so an
    /// unreferenced view model would drop out mid-test.
    private var windows: [BrowserViewModel] = []

    override func tearDown() {
        windows = []
        super.tearDown()
    }

    /// A bridge over exactly the windows a test built, and nothing else.
    ///
    /// It is handed the UNfiltered set on purpose: the privacy rule lives inside
    /// the bridge, so a test that passes in a private window is testing the real
    /// filter rather than its own.
    private func makeBridge(
        windows viewModels: [BrowserViewModel],
        history: HistoryRepository? = nil,
        bookmarks: BookmarkRepository? = nil,
        limiter: MCPRateLimiter? = nil
    ) -> MCPBrowserBridge {
        windows = viewModels
        return MCPBrowserBridge(
            registeredViewModels: { viewModels },
            history: history ?? MCPRepositoryFixture.emptyHistory,
            bookmarks: bookmarks ?? MCPRepositoryFixture.emptyBookmarks,
            openTabLimiter: limiter ?? MCPRateLimiter(limit: 5, window: 60)
        )
    }

    private func window(isPrivate: Bool = false, tabs urls: [String]) -> BrowserViewModel {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.isPrivateMode = isPrivate
        for url in urls {
            viewModel.tabManager.newTab(url: URL(string: url)!, switchTo: true)
        }
        return viewModel
    }

    private func json(of payload: some Encodable) throws -> String {
        let data = try MCPPayloadEncoding.encoder.encode(payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - Incognito

    /// The leak test. Two normal windows and one incognito window.
    func testPrivateWindowsTabsAreAbsentAndItsPagesUnreadable() async throws {
        let first = window(tabs: ["https://swift.org/blog", "https://apple.com"])
        let second = window(tabs: ["https://example.com/docs"])
        let incognito = window(isPrivate: true, tabs: ["https://private.example/embarrassing"])
        let bridge = makeBridge(windows: [first, incognito, second])

        let listed = bridge.listTabs(windowID: nil)

        XCTAssertEqual(listed.windows.count, 2, "an incognito window appeared in list_tabs")
        XCTAssertEqual(listed.totalTabs, 3, "incognito tabs were counted in the total")
        XCTAssertEqual(
            Set(listed.windows.map(\.windowID)),
            Set([first.windowID.uuidString, second.windowID.uuidString])
        )

        // Not merely "the window is missing" — nothing about it is in the bytes.
        let body = try json(of: listed)
        XCTAssertFalse(body.contains(incognito.windowID.uuidString), "the private window's id leaked")
        XCTAssertFalse(body.contains("private.example"), "a private tab's URL leaked")
        for tab in incognito.tabManager.tabs {
            XCTAssertFalse(body.contains(tab.id.uuidString), "a private tab's id leaked")
        }

        // And the id itself is no key. A caller who somehow HAS a private tab's
        // id — guessed, remembered from before the window went private, leaked
        // some other way — still gets nothing.
        let privateTab = try XCTUnwrap(incognito.tabManager.tabs.first)
        let outcome = await bridge.readPage(tabID: privateTab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .notFound)
        XCTAssertNil(outcome.text)

        // `not_found`, and specifically NOT "that tab is private": the existence
        // of a private window is itself the secret, so this has to be the same
        // answer as an id that never existed.
        let refusal = try json(of: outcome)
        for word in ["private", "Private", "incognito", "Incognito"] {
            XCTAssertFalse(refusal.contains(word), "the refusal admitted the tab is private")
        }
        let unknown = await bridge.readPage(tabID: UUID(), offset: 0)
        XCTAssertEqual(unknown.reason, outcome.reason,
                       "a private tab's id must be indistinguishable from one that never existed")
        guard case .unreadable(let privateRefusal) = outcome,
              case .unreadable(let unknownRefusal) = unknown else {
            return XCTFail("both should be refusals")
        }
        XCTAssertEqual(privateRefusal.detail, unknownRefusal.detail,
                       "the wording differed, which makes the id an oracle")
    }

    /// `list_tabs` naming a private window by id must not confirm it exists.
    func testAskingForAPrivateWindowByIDLooksLikeAWindowThatIsNotOpen() throws {
        let normal = window(tabs: ["https://swift.org"])
        let incognito = window(isPrivate: true, tabs: ["https://private.example"])
        let bridge = makeBridge(windows: [normal, incognito])

        let byPrivateID = bridge.listTabs(windowID: incognito.windowID)
        let byNonsenseID = bridge.listTabs(windowID: UUID())

        XCTAssertTrue(byPrivateID.windows.isEmpty)
        XCTAssertEqual(byPrivateID.totalTabs, 0)
        XCTAssertEqual(try json(of: byPrivateID), try json(of: byNonsenseID),
                       "the answers must be byte-identical, or the id is an oracle")
    }

    /// `open_tab` must never target a private window, even when asked to.
    func testOpenTabAimedAtAPrivateWindowLandsInANormalOne() {
        let normal = window(tabs: ["https://swift.org"])
        let incognito = window(isPrivate: true, tabs: [])
        let bridge = makeBridge(windows: [normal, incognito])

        let outcome = bridge.openTab(
            url: URL(string: "https://example.com")!,
            windowID: incognito.windowID,
            activate: false
        )

        guard case .opened(let payload) = outcome else {
            return XCTFail("expected the tab to open somewhere; got \(outcome)")
        }
        XCTAssertEqual(payload.windowID, normal.windowID.uuidString)
        XCTAssertEqual(incognito.tabManager.tabs.count, 0, "a tab was opened in a private window")
        XCTAssertEqual(normal.tabManager.tabs.count, 2)
    }

    // MARK: - list_tabs

    func testWindowIDsAreDistinctAndSurviveASecondCall() {
        let first = window(tabs: ["https://a.example"])
        let second = window(tabs: ["https://b.example"])
        let bridge = makeBridge(windows: [first, second])

        let firstCall = bridge.listTabs(windowID: nil).windows.map(\.windowID)
        let secondCall = bridge.listTabs(windowID: nil).windows.map(\.windowID)

        XCTAssertEqual(Set(firstCall).count, 2, "two windows shared one window_id")
        XCTAssertEqual(firstCall, secondCall, "window_ids changed between calls")

        // And each one round-trips: a client can narrow with what it was given.
        for id in firstCall {
            let narrowed = bridge.listTabs(windowID: UUID(uuidString: id))
            XCTAssertEqual(narrowed.windows.map(\.windowID), [id])
        }
    }

    func testTabStateIsReported() {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        tab.title = "Swift Blog"
        tab.isPinned = true

        let listed = bridge.listTabs(windowID: nil)
        let payload = listed.windows[0].tabs[0]

        XCTAssertEqual(payload.tabID, tab.id.uuidString)
        XCTAssertEqual(payload.title, "Swift Blog")
        XCTAssertEqual(payload.url, "https://swift.org/blog")
        XCTAssertTrue(payload.selected)
        XCTAssertTrue(payload.pinned)
        XCTAssertFalse(payload.sleeping)
        XCTAssertNil(payload.internalPage)
    }

    /// A `cherry://` tab reports the internal page's own address, never the site
    /// it is covering — the same distinction `read_page` refuses on.
    func testInternalPageTabReportsTheCherryURLAndNotTheCoveredSite() throws {
        let viewModel = window(tabs: ["https://covered.example/secret"])
        let bridge = makeBridge(windows: [viewModel])
        viewModel.tabManager.tabs[0].openInternalPage(.settings)

        let listed = bridge.listTabs(windowID: nil)
        XCTAssertEqual(listed.windows[0].tabs[0].internalPage, "settings")
        XCTAssertEqual(listed.windows[0].tabs[0].url, "cherry://settings")
        XCTAssertFalse(try json(of: listed).contains("covered.example"))
    }

    /// Both panes of a split window count as selected — there are two tabs on
    /// screen, and a model asking "what is the user looking at" needs both.
    func testBothSplitViewPanesAreMarkedSelected() {
        let viewModel = window(tabs: ["https://a.example", "https://b.example", "https://c.example"])
        let bridge = makeBridge(windows: [viewModel])
        let manager = viewModel.tabManager
        manager.selectedTabID = manager.tabs[0].id
        manager.openSplit(with: manager.tabs[2].id)

        let tabs = bridge.listTabs(windowID: nil).windows[0].tabs
        XCTAssertEqual(tabs.filter(\.selected).map(\.tabID),
                       [manager.tabs[0].id.uuidString, manager.tabs[2].id.uuidString])
    }

    /// Past the cap the answer says so, and says how to get the rest. A silent
    /// 300-of-400 reads to a model as "these are all the tabs".
    func testTabsBeyondTheCapAreReportedNotDropped() {
        let viewModel = window(tabs: [])
        for index in 0..<(MCPResultCaps.tabs + 12) {
            viewModel.tabManager.newTab(url: URL(string: "https://example.com/\(index)")!, switchTo: false)
        }
        let bridge = makeBridge(windows: [viewModel])

        let listed = bridge.listTabs(windowID: nil)
        XCTAssertEqual(listed.windows[0].tabs.count, MCPResultCaps.tabs)
        XCTAssertEqual(listed.windows[0].tabCount, MCPResultCaps.tabs + 12,
                       "the window must still report how many tabs it really has")
        XCTAssertEqual(listed.totalTabs, MCPResultCaps.tabs + 12)
        XCTAssertTrue(listed.truncated)
        XCTAssertEqual(listed.note, "300 of 312 tabs shown; pass window_id to narrow.")
    }

    func testLongTitlesAndURLsAreTruncatedVisibly() {
        let viewModel = window(tabs: ["https://example.com/" + String(repeating: "p", count: 800)])
        let bridge = makeBridge(windows: [viewModel])
        viewModel.tabManager.tabs[0].title = String(repeating: "T", count: 400)

        let payload = bridge.listTabs(windowID: nil).windows[0].tabs[0]
        XCTAssertEqual(payload.title.count, MCPResultCaps.tabTitleChars + 1)
        XCTAssertTrue(payload.title.hasSuffix("…"), "a clipped title must not read as the real one")
        XCTAssertEqual(payload.url.count, MCPResultCaps.urlChars + 1)
        XCTAssertTrue(payload.url.hasSuffix("…"))
    }

    // MARK: - open_tab

    func testOnlyHTTPAndHTTPSAreOpened() {
        let viewModel = window(tabs: [])
        let bridge = makeBridge(windows: [viewModel])

        for (input, scheme) in [
            ("cherry://settings", "cherry"),
            ("file:///etc/passwd", "file"),
            ("javascript:alert(1)", "javascript"),
            ("data:text/html,<b>hi</b>", "data"),
            ("ftp://example.com/x", "ftp"),
        ] {
            let outcome = bridge.openTab(url: URL(string: input)!, windowID: nil, activate: false)
            guard case .refused(let payload) = outcome else {
                return XCTFail("\(input) was opened")
            }
            XCTAssertEqual(payload.reason, .unsupportedScheme, input)
            XCTAssertEqual(payload.scheme, scheme, "the refusal must name the scheme")
            XCTAssertTrue(payload.detail.contains(scheme), "\(input): \(payload.detail)")
        }

        XCTAssertTrue(viewModel.tabManager.tabs.isEmpty, "a refused URL still opened a tab")

        for allowed in ["http://example.com", "https://example.com", "HTTPS://Example.com"] {
            guard case .opened = bridge.openTab(url: URL(string: allowed)!, windowID: nil, activate: false) else {
                return XCTFail("\(allowed) was refused")
            }
        }
    }

    /// `cherry:` is the one that matters most: `BrowserViewModel.navigate(to:in:)`
    /// routes it to Cherry's own internal pages, so an unvalidated `open_tab`
    /// would let a client drive the browser's UI.
    func testCherrySchemeRefusalExplainsWhy() {
        let bridge = makeBridge(windows: [window(tabs: [])])
        guard case .refused(let payload) = bridge.openTab(
            url: URL(string: "cherry://history")!, windowID: nil, activate: false
        ) else {
            return XCTFail("cherry:// was opened")
        }
        XCTAssertTrue(payload.detail.contains("internal pages"), payload.detail)
    }

    func testTheSixthTabInAMinuteIsRateLimited() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let limiter = MCPRateLimiter(limit: 5, window: 60, now: { now })
        let viewModel = window(tabs: [])
        let bridge = makeBridge(windows: [viewModel], limiter: limiter)

        func open() -> MCPOpenTabOutcome {
            bridge.openTab(url: URL(string: "https://example.com/x")!, windowID: nil, activate: false)
        }

        for attempt in 1...5 {
            guard case .opened = open() else { return XCTFail("tab \(attempt) was refused") }
            now.addTimeInterval(1)
        }

        guard case .refused(let payload) = open() else {
            return XCTFail("the 6th tab in a minute was opened")
        }
        XCTAssertEqual(payload.reason, .rateLimited)
        XCTAssertEqual(viewModel.tabManager.tabs.count, 5, "the refused call still opened a tab")
        XCTAssertGreaterThan(payload.retryAfterSeconds ?? 0, 0, "a client needs to know how long to wait")

        // The window is rolling, not a fixed bucket: once the first call ages
        // out, one more is allowed.
        now.addTimeInterval(60)
        guard case .opened = open() else { return XCTFail("still limited a minute later") }
    }

    /// A refusal that never touched the screen must not spend the user's budget,
    /// or a client can rate-limit itself out of the tool with its own typos.
    func testRefusedSchemesDoNotConsumeTheRateLimit() {
        let viewModel = window(tabs: [])
        let bridge = makeBridge(windows: [viewModel], limiter: MCPRateLimiter(limit: 5, window: 60))

        for _ in 0..<20 {
            _ = bridge.openTab(url: URL(string: "file:///etc/passwd")!, windowID: nil, activate: false)
        }
        for attempt in 1...5 {
            guard case .opened = bridge.openTab(
                url: URL(string: "https://example.com")!, windowID: nil, activate: false
            ) else {
                return XCTFail("tab \(attempt) was refused after 20 rejected URLs")
            }
        }
    }

    func testActivateFalseLeavesTheUsersTabSelected() {
        let viewModel = window(tabs: ["https://swift.org"])
        let bridge = makeBridge(windows: [viewModel])
        let before = viewModel.tabManager.selectedTabID

        _ = bridge.openTab(url: URL(string: "https://example.com")!, windowID: nil, activate: false)
        XCTAssertEqual(viewModel.tabManager.selectedTabID, before, "open_tab stole the user's tab")

        guard case .opened(let payload) = bridge.openTab(
            url: URL(string: "https://example.org")!, windowID: nil, activate: true
        ) else {
            return XCTFail("activate: true was refused")
        }
        XCTAssertEqual(viewModel.tabManager.selectedTabID?.uuidString, payload.tabID)
        XCTAssertTrue(payload.activated)
    }

    func testNoWindowMeansNoTab() {
        let bridge = makeBridge(windows: [])
        guard case .refused(let payload) = bridge.openTab(
            url: URL(string: "https://example.com")!, windowID: nil, activate: false
        ) else {
            return XCTFail("a tab was opened with no window to put it in")
        }
        XCTAssertEqual(payload.reason, .noWindow)
    }

    // MARK: - read_page: the refusal ladder

    func testSleepingTabIsRefusedAndNotWoken() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        tab.sleep()
        XCTAssertTrue(tab.isSleeping, "precondition")

        let outcome = await bridge.readPage(tabID: tab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .sleeping)
        XCTAssertTrue(tab.isSleeping, "read_page woke a sleeping tab")
        XCTAssertTrue(try json(of: outcome).contains("swift.org/blog"),
                      "the refusal should hand back the URL so the model can act")
    }

    func testHomePageIsRefused() async {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(switchTo: true)
        let bridge = makeBridge(windows: [viewModel])

        let outcome = await bridge.readPage(tabID: viewModel.tabManager.tabs[0].id, offset: 0)
        XCTAssertEqual(outcome.reason, .homePage)
    }

    func testInternalPageIsRefusedEvenWithoutAWebView() async {
        let viewModel = window(tabs: ["https://covered.example/secret"])
        let bridge = makeBridge(windows: [viewModel])
        viewModel.tabManager.tabs[0].openInternalPage(.settings)

        let outcome = await bridge.readPage(tabID: viewModel.tabManager.tabs[0].id, offset: 0)
        XCTAssertEqual(outcome.reason, .internalPage)
    }

    /// A PDF the window is displaying is refused…
    func testPDFIsRefused() async {
        let viewModel = window(tabs: ["https://example.com/paper"])
        viewModel.isViewingPDF = true
        let bridge = makeBridge(windows: [viewModel])

        let outcome = await bridge.readPage(tabID: viewModel.tabManager.tabs[0].id, offset: 0)
        XCTAssertEqual(outcome.reason, .pdf)
    }

    /// …but `isViewingPDF` is a per-WINDOW flag set from the DISPLAYED page, so it
    /// must not condemn the window's other tabs. Getting this wrong is the same
    /// shape of bug as reading a `cherry://` tab's covered site: one tab's state
    /// answering for another's.
    func testAPDFInOneTabDoesNotMakeTheWindowsOtherTabsUnreadable() async {
        let viewModel = window(tabs: ["https://example.com/paper", "https://swift.org/blog"])
        viewModel.isViewingPDF = true
        viewModel.tabManager.selectedTabID = viewModel.tabManager.tabs[0].id
        let bridge = makeBridge(windows: [viewModel])

        let other = await bridge.readPage(tabID: viewModel.tabManager.tabs[1].id, offset: 0)
        XCTAssertNotEqual(other.reason, .pdf, "a background tab inherited the window's PDF state")
        XCTAssertEqual(other.reason, .notRendered)
    }

    func testAPDFURLIsRefusedEvenInABackgroundTab() async {
        let viewModel = window(tabs: ["https://example.com/report.pdf"])
        let bridge = makeBridge(windows: [viewModel])

        let outcome = await bridge.readPage(tabID: viewModel.tabManager.tabs[0].id, offset: 0)
        XCTAssertEqual(outcome.reason, .pdf)
    }

    /// A tab that has never been displayed has no web view and nothing loaded —
    /// which is exactly the state `open_tab(activate: false)` leaves one in.
    func testNeverDisplayedTabSaysSoRatherThanClaimingNoContent() async throws {
        let viewModel = window(tabs: [])
        let bridge = makeBridge(windows: [viewModel])
        guard case .opened(let opened) = bridge.openTab(
            url: URL(string: "https://swift.org/blog")!, windowID: nil, activate: false
        ) else {
            return XCTFail("open_tab was refused")
        }

        let outcome = await bridge.readPage(tabID: UUID(uuidString: opened.tabID), offset: 0)
        XCTAssertEqual(outcome.reason, .notRendered)
        let detail = try json(of: outcome)
        XCTAssertTrue(detail.contains("activate: true"), "the refusal must say what to do instead")
    }

    func testUnknownTabIDIsNotFound() async {
        let bridge = makeBridge(windows: [window(tabs: ["https://swift.org"])])
        let outcome = await bridge.readPage(tabID: UUID(), offset: 0)
        XCTAssertEqual(outcome.reason, .notFound)
    }

    func testNoWindowsAtAllIsNotFound() async {
        let bridge = makeBridge(windows: [])
        let outcome = await bridge.readPage(tabID: nil, offset: 0)
        XCTAssertEqual(outcome.reason, .notFound)
    }

    // MARK: - read_page: the covered-site non-leak, against a real page

    /// The one that would have caught Cherry's own Ask-This-Page bug.
    func testInternalPageTabNeverLeaksTheCoveredSitesText() async throws {
        let sentinel = "MARZIPAN-SENTINEL-9F3A"
        let viewModel = window(tabs: ["https://covered.example/secret"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]

        let webView = tab.createWebView()
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: sentinel, paragraphs: 8),
            into: webView
        )

        // Positive control. Without this the test could pass because the page was
        // never readable in the first place, which proves nothing about the guard.
        let direct = await PageAIExtractor.extract(from: webView)
        XCTAssertTrue(
            direct?.text.contains(sentinel) == true,
            "the sentinel page is not readable at all, so this test cannot prove the guard works"
        )

        // Now cover it, exactly as typing cherry://settings does. The web view and
        // `url` are deliberately kept alive underneath.
        tab.openInternalPage(.settings)
        XCTAssertNotNil(tab.webView, "precondition: openInternalPage keeps the covered web view")

        let outcome = await bridge.readPage(tabID: tab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .internalPage)
        XCTAssertNil(outcome.text)

        let body = try json(of: outcome)
        XCTAssertFalse(body.contains(sentinel), "the covered site's text leaked through a cherry:// tab")
        XCTAssertFalse(body.contains("covered.example"), "the covered site's URL leaked")
        XCTAssertTrue(body.contains("cherry://settings"))
    }

    // MARK: - read_page: the readable path

    func testAReadablePageComesBackAsText() async throws {
        let sentinel = "PERSIMMON-BODY-TEXT"
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: sentinel, paragraphs: 6),
            into: tab.createWebView()
        )

        let outcome = await bridge.readPage(tabID: tab.id, offset: 0)
        guard case .page(let payload) = outcome else {
            return XCTFail("expected text; got \(outcome)")
        }
        XCTAssertTrue(payload.text.contains(sentinel))
        XCTAssertEqual(payload.tabID, tab.id.uuidString)
        XCTAssertEqual(payload.windowID, viewModel.windowID.uuidString)
        XCTAssertEqual(payload.offset, 0)
        XCTAssertEqual(payload.returnedChars, payload.text.count)
        XCTAssertFalse(payload.hasMore)
        XCTAssertNil(payload.nextOffset)
        XCTAssertFalse(payload.loading)
    }

    /// A page mid-load is read anyway and flagged, rather than refused: the
    /// extractor has a layout-independent last resort, and blocking until load
    /// would risk the client's 60-second first-byte timer.
    func testAStillLoadingPageIsReadAndFlagged() async throws {
        let sentinel = "QUINCE-MIDLOAD"
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: sentinel, paragraphs: 6),
            into: tab.createWebView()
        )
        tab.isLoading = true

        guard case .page(let payload) = await bridge.readPage(tabID: tab.id, offset: 0) else {
            return XCTFail("a loading page was refused instead of read")
        }
        XCTAssertTrue(payload.text.contains(sentinel))
        XCTAssertTrue(payload.loading, "the model has to be told the text may be incomplete")
    }

    /// With no `tab_id`, read what the user is looking at — and say which tab
    /// that was, so the model is never guessing.
    func testOmittingTabIDReadsTheFocusedTab() async throws {
        let viewModel = window(tabs: ["https://a.example", "https://b.example"])
        let bridge = makeBridge(windows: [viewModel])
        let second = viewModel.tabManager.tabs[1]
        viewModel.tabManager.selectedTabID = second.id
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "LOQUAT-FOCUSED", paragraphs: 6),
            into: second.createWebView()
        )

        guard case .page(let payload) = await bridge.readPage(tabID: nil, offset: 0) else {
            return XCTFail("the focused tab was not readable")
        }
        XCTAssertEqual(payload.tabID, second.id.uuidString)
    }

    /// A page with no meaningful text is a refusal with a reason, not an empty
    /// success a model would fill in for itself.
    func testAnEmptyPageIsNoContent() async throws {
        let viewModel = window(tabs: ["https://blank.example"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load("<html><body></body></html>", into: tab.createWebView())

        let outcome = await bridge.readPage(tabID: tab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .noContent)
    }

    // MARK: - read_page: chunking

    /// Walk a >100 KB page to completion. No overlap, no gap, and the
    /// concatenation is the original text exactly.
    func testChunkingWalksALongPageWithNoOverlapAndNoGap() {
        let original = String(repeating: "Cherry reads pages. ", count: 8_000) // 160,000 chars
        XCTAssertGreaterThan(original.count, 100_000, "precondition: a >100 KB page")
        let content = ExtractedPageContent(title: "Long", text: original)

        var offset = 0
        var reassembled = ""
        var chunks = 0
        var seenOffsets: [Int] = []

        while true {
            let payload = MCPBrowserBridge.chunk(
                content, offset: offset,
                tabID: "t", windowID: "w", url: "https://example.com", fallbackTitle: "",
                loading: false
            )
            chunks += 1
            seenOffsets.append(payload.offset)
            XCTAssertEqual(payload.offset, offset, "chunk \(chunks) started somewhere else")
            XCTAssertEqual(payload.totalChars, original.count)
            XCTAssertEqual(payload.returnedChars, payload.text.count)
            XCTAssertLessThanOrEqual(payload.returnedChars, MCPResultCaps.readPageChars)
            reassembled += payload.text

            guard payload.hasMore, let next = payload.nextOffset else {
                XCTAssertNil(payload.nextOffset)
                break
            }
            XCTAssertEqual(next, offset + payload.returnedChars,
                           "next_offset must be exactly where this chunk ended")
            offset = next
            XCTAssertLessThan(chunks, 20, "runaway chunk loop")
        }

        XCTAssertEqual(chunks, 4, "160,000 chars at 40,000 per call")
        XCTAssertEqual(seenOffsets, [0, 40_000, 80_000, 120_000])
        XCTAssertEqual(reassembled, original, "the walk lost or repeated text")
    }

    /// Reading past the end says so instead of looking like a short page.
    func testAnOffsetPastTheEndReturnsNothingAndSaysWhy() {
        let content = ExtractedPageContent(title: "Short", text: String(repeating: "a", count: 100))
        let payload = MCPBrowserBridge.chunk(
            content, offset: 5_000,
            tabID: "t", windowID: "w", url: "https://example.com", fallbackTitle: "",
            loading: false
        )
        XCTAssertEqual(payload.offset, 100)
        XCTAssertEqual(payload.returnedChars, 0)
        XCTAssertEqual(payload.totalChars, 100)
        XCTAssertFalse(payload.hasMore)
        XCTAssertTrue(payload.note?.contains("past the end") == true, payload.note ?? "no note")
    }

    /// A capped chunk always carries the instruction for getting the rest.
    func testATruncatedReadTellsTheModelHowToContinue() {
        let content = ExtractedPageContent(
            title: "Long",
            text: String(repeating: "x", count: MCPResultCaps.readPageChars + 10)
        )
        let payload = MCPBrowserBridge.chunk(
            content, offset: 0,
            tabID: "t", windowID: "w", url: "https://example.com", fallbackTitle: "",
            loading: false
        )
        XCTAssertTrue(payload.hasMore)
        XCTAssertEqual(payload.nextOffset, MCPResultCaps.readPageChars)
        XCTAssertTrue(payload.note?.contains("offset: \(MCPResultCaps.readPageChars)") == true,
                      payload.note ?? "no note")
    }

    /// Walk a real >100 KB page through the whole bridge, not just `chunk`.
    func testALongRealPageIsReadToCompletionThroughTheBridge() async throws {
        let viewModel = window(tabs: ["https://long.example"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "Cherry reads long pages carefully.", paragraphs: 400),
            into: tab.createWebView()
        )

        var offset = 0
        var reassembled = ""
        var total = -1
        for call in 1...20 {
            guard case .page(let payload) = await bridge.readPage(tabID: tab.id, offset: offset) else {
                return XCTFail("call \(call) did not return text")
            }
            if total < 0 { total = payload.totalChars }
            XCTAssertEqual(payload.totalChars, total, "the page changed size mid-walk")
            XCTAssertEqual(payload.offset, offset)
            reassembled += payload.text
            guard payload.hasMore, let next = payload.nextOffset else { break }
            XCTAssertEqual(next, offset + payload.returnedChars)
            offset = next
        }

        XCTAssertGreaterThan(total, 100_000, "precondition: the fixture must exceed 100 KB")
        XCTAssertEqual(reassembled.count, total, "the walk did not cover the page exactly once")
    }
}

