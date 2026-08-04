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

    /// The blocker the window-level filter alone did not cover.
    ///
    /// `BrowserViewModel.transferTab(tabID:to:)` moves a `Tab` between windows with
    /// no privacy check, and it is wired to the tab bar — drag an incognito tab onto
    /// a normal window and it now lives in a non-private window's `TabManager` while
    /// still carrying `isPrivate == true` and its live private-store `WKWebView`.
    /// Filtering only on the window published its URL and title in `list_tabs`, and
    /// `read_page` extracted the private page in full: not asleep, not internal, not
    /// the home page, and it has a web view, so every rung passed.
    func testAPrivateTabMovedIntoANormalWindowIsStillInvisible() async throws {
        let sentinel = "SAFFRON-PRIVATE-BODY"
        let normal = window(tabs: ["https://swift.org/blog"])
        // Two tabs, and only one moves: `TabManager.removeTab` closes the window and
        // calls `NSApp.terminate` when it empties a manager, which in a test bundle
        // would take the whole run down with it.
        let incognito = window(isPrivate: true, tabs: [
            "https://private.example/embarrassing",
            "https://private.example/stays",
        ])
        let bridge = makeBridge(windows: [normal, incognito])

        let privateTab = try XCTUnwrap(incognito.tabManager.tabs.first)
        privateTab.isPrivate = true
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: sentinel, paragraphs: 8),
            into: privateTab.createWebView()
        )
        // The page really is readable — otherwise this test proves nothing.
        let direct = await PageAIExtractor.extract(from: try XCTUnwrap(privateTab.webView))
        XCTAssertTrue(direct?.text.contains(sentinel) == true, "the sentinel page is not readable")

        // Exactly what dragging the tab onto the normal window's tab bar does.
        XCTAssertTrue(BrowserViewModel.transferTab(tabID: privateTab.id, to: normal))
        XCTAssertTrue(normal.tabManager.tabs.contains { $0 === privateTab }, "precondition")
        XCTAssertFalse(normal.isPrivateMode, "precondition: the destination window is NOT private")
        XCTAssertTrue(privateTab.isPrivate, "precondition: the tab still knows it is private")

        // list_tabs: absent, and not counted.
        let listed = bridge.listTabs(windowID: nil)
        let body = try json(of: listed)
        XCTAssertEqual(listed.totalTabs, 1, "the private tab was counted in total_tabs")
        XCTAssertEqual(listed.windows.first?.tabCount, 1, "tab_count reported the private tab")
        XCTAssertFalse(body.contains(privateTab.id.uuidString), "the private tab's id leaked")
        XCTAssertFalse(body.contains("private.example"), "the private tab's URL leaked")

        // read_page: refused, with the same bytes as an id that never existed.
        let outcome = await bridge.readPage(tabID: privateTab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .notFound)
        XCTAssertNil(outcome.text)
        XCTAssertFalse(try json(of: outcome).contains(sentinel), "the private page's text leaked")

        let unknown = await bridge.readPage(tabID: UUID(), offset: 0)
        guard case .unreadable(let moved) = outcome, case .unreadable(let never) = unknown else {
            return XCTFail("both should be refusals")
        }
        XCTAssertEqual(moved.detail, never.detail)
        XCTAssertNil(moved.url, "the refusal handed back the private tab's URL")
    }

    /// …including when it is the focused tab, which is what `read_page` with no
    /// `tab_id` resolves to. `TabManager.focusedTab` knows nothing about privacy.
    func testAFocusedPrivateTabIsNotWhatReadPageFallsBackTo() async throws {
        let normal = window(tabs: ["https://swift.org/blog"])
        let incognito = window(isPrivate: true, tabs: [
            "https://private.example/secret",
            "https://private.example/stays",
        ])
        let bridge = makeBridge(windows: [normal, incognito])

        let privateTab = try XCTUnwrap(incognito.tabManager.tabs.first)
        privateTab.isPrivate = true
        XCTAssertTrue(BrowserViewModel.transferTab(tabID: privateTab.id, to: normal))
        normal.tabManager.selectedTabID = privateTab.id
        XCTAssertTrue(normal.tabManager.focusedTab === privateTab, "precondition")

        let outcome = await bridge.readPage(tabID: nil, offset: 0)
        XCTAssertEqual(outcome.reason, .notFound, "read_page fell back to a private tab")
        XCTAssertFalse(try json(of: outcome).contains("private.example"))
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
    ///
    /// The binding limit is the RESULT SIZE budget, not the 300-tab cap. Per-field
    /// caps never bounded a payload: 300 tabs at 120 title + 500 url is ~210,000
    /// characters, far past the ~25,000-token hard limit this design is sized
    /// against, and `list_tabs` has no chunking to fall back on.
    func testTabsBeyondTheCapAreReportedNotDropped() throws {
        let viewModel = window(tabs: [])
        for index in 0..<(MCPResultCaps.tabs + 12) {
            viewModel.tabManager.newTab(url: URL(string: "https://example.com/\(index)")!, switchTo: false)
        }
        let bridge = makeBridge(windows: [viewModel])

        let listed = bridge.listTabs(windowID: nil)
        XCTAssertEqual(listed.windows[0].tabCount, MCPResultCaps.tabs + 12,
                       "the window must still report how many tabs it really has")
        XCTAssertEqual(listed.totalTabs, MCPResultCaps.tabs + 12)
        XCTAssertTrue(listed.truncated)
        XCTAssertLessThan(listed.windows[0].tabs.count, MCPResultCaps.tabs + 12)

        let note = try XCTUnwrap(listed.note)
        XCTAssertTrue(note.contains("of \(MCPResultCaps.tabs + 12) tabs shown"), note)
        XCTAssertTrue(note.contains("window_id"), note)
        XCTAssertTrue(note.contains("result size limit") || note.contains("cap of"), note)

        // The point of the budget: the body actually fits.
        XCTAssertLessThan(try json(of: listed).count, MCPResultCaps.payloadChars,
                          "list_tabs emitted more than its own declared budget")
    }

    /// The budget binds on total size, not on row count — a handful of tabs with
    /// pathological titles and URLs must not blow the envelope either.
    func testAFewEnormousTabsAlsoFitTheBudget() throws {
        let viewModel = window(tabs: [])
        for index in 0..<200 {
            let tab = viewModel.tabManager.newTab(
                url: URL(string: "https://example.com/" + String(repeating: "p", count: 900))!,
                switchTo: false
            )
            tab.title = "\(index) " + String(repeating: "T", count: 400)
        }
        let bridge = makeBridge(windows: [viewModel])

        let listed = bridge.listTabs(windowID: nil)
        XCTAssertTrue(listed.truncated)
        XCTAssertLessThan(try json(of: listed).count, MCPResultCaps.payloadChars)
        XCTAssertTrue(try XCTUnwrap(listed.note).contains("result size limit"), listed.note ?? "")
    }

    /// A budget that returned nothing would be worse than one that overflows: the
    /// first row is always admitted, whatever it costs.
    func testTheFirstRowIsAlwaysReturnedEvenIfItIsHuge() throws {
        let viewModel = window(tabs: [])
        let tab = viewModel.tabManager.newTab(
            url: URL(string: "https://example.com/" + String(repeating: "p", count: 5_000))!,
            switchTo: true
        )
        tab.title = String(repeating: "T", count: 5_000)
        let bridge = makeBridge(windows: [viewModel])

        XCTAssertEqual(bridge.listTabs(windowID: nil).windows.first?.tabs.count, 1)
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

    /// A real PDF in a real `WKWebView`, refused because the DOCUMENT says it is one.
    ///
    /// Detection is `document.contentType`, not the URL: this fixture's URL is
    /// `arxiv.org/pdf/2401.00001`, whose `pathExtension` is `"00001"`, which is
    /// exactly the extensionless shape the old `pathExtension == "pdf"` check missed
    /// — and which `BrowserViewModel.isViewingPDF` also misses, since
    /// `WebViewWrapper` computes it the same way.
    func testARealPDFIsRefusedEvenWithNoPDFExtensionInTheURL() async throws {
        let viewModel = window(tabs: ["https://arxiv.org/pdf/2401.00001"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.loadPDF(into: tab.createWebView(),
                                         baseURL: URL(string: "https://arxiv.org/pdf/2401.00001")!)

        let outcome = await bridge.readPage(tabID: tab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .pdf, "a real PDF was not refused")
        XCTAssertNil(outcome.text)
    }

    /// A `.pdf` URL that is really HTML must NOT be refused. The old heuristic did
    /// refuse it; asking the document cannot.
    func testAnHTMLPageServedAtAPDFPathIsStillReadable() async throws {
        let viewModel = window(tabs: ["https://example.com/report.pdf"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "TAMARIND-NOT-A-PDF", paragraphs: 6),
            into: tab.createWebView()
        )

        guard case .page(let payload) = await bridge.readPage(tabID: tab.id, offset: 0) else {
            return XCTFail("an HTML page at a .pdf path was refused")
        }
        XCTAssertTrue(payload.text.contains("TAMARIND-NOT-A-PDF"))
    }

    /// A PDF in one split pane must not refuse the article in the other.
    ///
    /// `BrowserViewModel.isViewingPDF` is per-WINDOW and last-writer-wins across
    /// panes, and `isSelected` is true for BOTH panes, so gating on it refused a
    /// perfectly readable pane — the same "one tab's state answering for another's"
    /// bug as reading a `cherry://` tab's covered site. The bridge no longer reads
    /// that flag at all; this test is what would notice if it came back.
    func testAPDFInOneSplitPaneDoesNotRefuseTheOther() async throws {
        let viewModel = window(tabs: ["https://arxiv.org/pdf/2401.00001", "https://swift.org/blog"])
        let bridge = makeBridge(windows: [viewModel])
        let manager = viewModel.tabManager
        let pdfTab = manager.tabs[0]
        let articleTab = manager.tabs[1]

        try await MCPPageFixture.loadPDF(into: pdfTab.createWebView(),
                                         baseURL: URL(string: "https://arxiv.org/pdf/2401.00001")!)
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "GUAVA-OTHER-PANE", paragraphs: 6),
            into: articleTab.createWebView()
        )

        // Both panes on screen, which is what made `isViewingPDF` ambiguous.
        manager.selectedTabID = pdfTab.id
        manager.openSplit(with: articleTab.id)
        viewModel.isViewingPDF = true

        let pdfOutcome = await bridge.readPage(tabID: pdfTab.id, offset: 0)
        XCTAssertEqual(pdfOutcome.reason, .pdf)

        guard case .page(let payload) = await bridge.readPage(tabID: articleTab.id, offset: 0) else {
            return XCTFail("the article pane was refused because the other pane holds a PDF")
        }
        XCTAssertTrue(payload.text.contains("GUAVA-OTHER-PANE"))
    }

    /// `showSettingsPage` is a cover-the-web-view flag of exactly the same shape as
    /// `internalPage` — `BrowserView` still has a live render branch for it and
    /// `BrowserViewModel.canZoom` checks all three together. Vestigial today, but if
    /// it is ever set again the rung already holds, and it holds without leaking.
    func testTheSettingsPageFlagIsAlsoARefusalAndAlsoDoesNotLeak() async throws {
        let sentinel = "CARDAMOM-COVERED-BY-SETTINGS"
        let viewModel = window(tabs: ["https://covered.example/secret"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: sentinel, paragraphs: 8),
            into: tab.createWebView()
        )

        tab.showSettingsPage = true
        let outcome = await bridge.readPage(tabID: tab.id, offset: 0)
        XCTAssertEqual(outcome.reason, .internalPage)

        let body = try json(of: outcome)
        XCTAssertFalse(body.contains(sentinel), "the covered site leaked through showSettingsPage")
        XCTAssertFalse(body.contains("covered.example"))
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

    /// The honesty limit of "genuinely displayed", made visible instead of hidden.
    ///
    /// `read_page`'s promise holds at the tab boundary — a sleeping tab, a
    /// `cherry://` page and a PDF are all refused. Below it, the extractor's
    /// last-resort branches read `textContent`, which is layout-independent, so a
    /// `display:none` panel comes back as text. That was measured, not assumed: on a
    /// page whose only bulk text is hidden, `document.body.innerText.length` is 13
    /// and the extractor returns 1,199 characters including the hidden block.
    ///
    /// Constraining extraction to the visible paths would break the branches that
    /// make a mid-load or never-laid-out page readable at all, which the plan wants.
    /// So the payload reports which path produced the text and the description tells
    /// the model what to do about it.
    func testTextFromHiddenDOMIsLabelledAsNotDisplayed() async throws {
        let hidden = String(repeating: "PAPRIKA-HIDDEN-PANEL ", count: 60)
        let viewModel = window(tabs: ["https://app.example/dashboard"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            "<html><body><div style=\"display:none\"><p>\(hidden)</p></div><p>tiny</p></body></html>",
            into: tab.createWebView()
        )

        guard case .page(let payload) = await bridge.readPage(tabID: tab.id, offset: 0) else {
            return XCTFail("the page was refused rather than read")
        }
        XCTAssertTrue(payload.text.contains("PAPRIKA-HIDDEN-PANEL"),
                      "precondition: the extractor really does surface hidden DOM")
        XCTAssertEqual(payload.sourceDisplayed, false,
                       "hidden text was presented as though it were on screen")
        XCTAssertEqual(payload.textSource, PageTextSource.rawClone.rawValue)
        XCTAssertTrue(try XCTUnwrap(payload.note).contains("not being displayed"), payload.note ?? "")
    }

    /// The success payload reports the LIVE document's URL, not the tab model's.
    ///
    /// They diverge during navigation and across redirects, and a mismatch means
    /// text from page A labelled as page B. Only on this branch: on a `cherry://`
    /// tab `webView.url` IS the covered site, so the refusals keep using
    /// `displayURL` — which the covered-site tests above pin.
    func testTheSuccessPayloadReportsTheLiveDocumentsURL() async throws {
        let viewModel = window(tabs: ["https://stale.example/old-address"])
        let bridge = makeBridge(windows: [viewModel])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "FENNEL-LIVE-URL", paragraphs: 6),
            into: tab.createWebView()
        )

        guard case .page(let payload) = await bridge.readPage(tabID: tab.id, offset: 0) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(payload.url, tab.webView?.url?.absoluteString)
        XCTAssertNotEqual(payload.url, "https://stale.example/old-address",
                          "the tab model's URL was reported for text from a different document")
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

    /// A page longer than `read_page` will ever serve is cut, and the payload says
    /// so rather than presenting the first slice of it as the whole page.
    ///
    /// This also bounds the work: `chunk` used to open with `Array(content.text)`,
    /// full grapheme segmentation of the entire page on the main actor, with nothing
    /// capping the page first — so walking an N-character page was O(N) allocation
    /// per call, repeated freely, since only `open_tab` is rate-limited.
    func testAPageLongerThanTheTotalCapIsClampedAndSaysSo() throws {
        let huge = String(repeating: "y", count: MCPResultCaps.readPageTotalChars + 12_345)
        let payload = MCPBrowserBridge.chunk(
            ExtractedPageContent(title: "Huge", text: huge), offset: 0,
            tabID: "t", windowID: "w", url: "https://example.com", fallbackTitle: "",
            loading: false
        )

        XCTAssertEqual(payload.totalChars, MCPResultCaps.readPageTotalChars)
        XCTAssertEqual(payload.pageClamped, true)
        let note = try XCTUnwrap(payload.note)
        XCTAssertTrue(note.contains("\(huge.count) characters and was clamped"), note)
        XCTAssertTrue(note.contains("not reachable"), note)

        // And the walk still terminates exactly at the clamped total.
        var offset = 0
        var covered = 0
        while true {
            let chunk = MCPBrowserBridge.chunk(
                ExtractedPageContent(title: "Huge", text: huge), offset: offset,
                tabID: "t", windowID: "w", url: "https://example.com", fallbackTitle: "",
                loading: false
            )
            covered += chunk.returnedChars
            guard chunk.hasMore, let next = chunk.nextOffset else { break }
            offset = next
        }
        XCTAssertEqual(covered, MCPResultCaps.readPageTotalChars)
    }

    /// A page that fits is not marked clamped — the flag's presence is the signal.
    func testAnOrdinaryPageIsNotMarkedClamped() {
        let payload = MCPBrowserBridge.chunk(
            ExtractedPageContent(title: "Fine", text: String(repeating: "z", count: 5_000)),
            offset: 0,
            tabID: "t", windowID: "w", url: "https://example.com", fallbackTitle: "",
            loading: false
        )
        XCTAssertNil(payload.pageClamped)
        XCTAssertNil(payload.note)
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

