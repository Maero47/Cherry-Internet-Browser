//
//  BackgroundTabAndZoomTests.swift
//  Internet BrowserTests
//
//  Two behaviours that only show up once a web view exists, so the tests pin
//  the halves that don't need one:
//
//  * a ⌘-clicked / middle-clicked / "Open in New Tab" background tab must be
//    IDENTIFIABLE while it waits to be selected — it has no web view yet, so
//    nothing loads and nothing would name it,
//  * page zoom must live on the Tab, not the web view, so it survives every
//    web-view recreation (sleep/wake, Home) and can be set before one exists.
//

import XCTest
@testable import Cherry

@MainActor
final class BackgroundTabAndZoomTests: XCTestCase {

    // MARK: - Background tab identity

    private func historyItem(
        _ urlString: String,
        title: String,
        visitDate: Date = Date()
    ) -> HistoryItem {
        HistoryItem(url: URL(string: urlString)!, title: title, visitDate: visitDate)
    }

    /// The regression: `newTab(url:switchTo:false)` + `loadURL` left the tab
    /// titled "New Tab" with no favicon, because a background tab has no web
    /// view for `loadURL` to load into.
    func testOpenInNewTabSeedsTheRowsTitle() {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.openHistoryItemInNewTab(historyItem("https://swift.org/blog", title: "Swift Blog"))

        let tab = try? XCTUnwrap(viewModel.tabManager.tabs.last)
        XCTAssertEqual(tab?.title, "Swift Blog")
        XCTAssertEqual(tab?.url?.absoluteString, "https://swift.org/blog")
        XCTAssertEqual(tab?.showHomePage, false, "a seeded background tab is not the new-tab page")
    }

    /// Three ⌘-clicks must give three DISTINGUISHABLE tabs — the whole point of
    /// seeding, and what "three indistinguishable blank tabs" looked like before.
    func testSeveralOpenInNewTabsAreDistinguishable() {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        for (url, title) in [
            ("https://a.example.com", "Alpha"),
            ("https://b.example.com", "Beta"),
            ("https://c.example.com", "Gamma")
        ] {
            viewModel.openHistoryItemInNewTab(historyItem(url, title: title))
        }

        XCTAssertEqual(viewModel.tabManager.tabs.map(\.title), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(Set(viewModel.tabManager.tabs.map(\.displayTitle)).count, 3)
    }

    /// An untitled entry falls back to the host rather than to "New Tab", so
    /// the row is still identifiable.
    func testAnUntitledRowFallsBackToTheHost() {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.openHistoryItemInNewTab(historyItem("https://example.com/x", title: ""))

        XCTAssertEqual(viewModel.tabManager.tabs.last?.title, "example.com")
    }

    /// Background means background: the user's focused tab must not change.
    func testOpenInNewTabDoesNotStealSelection() {
        let viewModel = BrowserViewModel()
        let originalID = viewModel.tabManager.selectedTabID

        viewModel.openHistoryItemInNewTab(historyItem("https://swift.org", title: "Swift"))

        XCTAssertEqual(viewModel.tabManager.selectedTabID, originalID)
        XCTAssertEqual(viewModel.tabManager.tabs.count, 2)
    }

    // MARK: - Zoom lives on the Tab

    func testANewTabStartsAtActualSize() {
        XCTAssertEqual(Tab().zoomLevel, PageZoom.defaultLevel, accuracy: 0.0001)
    }

    /// ⌘+ / ⌘− / ⌘0 must record a level even with no web view (a sleeping tab,
    /// the new-tab page, a tab just sent Home) instead of silently no-opping.
    func testZoomingATabWithNoWebViewStillRecordsTheLevel() {
        let viewModel = BrowserViewModel()
        let tab = try? XCTUnwrap(viewModel.tabManager.selectedTab)
        XCTAssertNil(tab?.webView, "precondition: an unrendered tab has no web view")

        viewModel.zoomIn(for: tab)
        XCTAssertEqual(tab?.zoomLevel ?? 0, PageZoom.step(from: 1.0, direction: 1), accuracy: 0.0001)

        viewModel.zoomIn(for: tab)
        XCTAssertEqual(tab?.zoomLevel ?? 0, 1.25, accuracy: 0.0001)

        viewModel.zoomOut(for: tab)
        XCTAssertEqual(tab?.zoomLevel ?? 0, 1.1, accuracy: 0.0001)

        viewModel.resetZoom(for: tab)
        XCTAssertEqual(tab?.zoomLevel ?? 0, PageZoom.defaultLevel, accuracy: 0.0001)
    }

    /// Sleep releases the web view; the level must not go with it.
    func testZoomSurvivesSleepAndWake() {
        let viewModel = BrowserViewModel()
        let tab = try? XCTUnwrap(viewModel.tabManager.selectedTab)
        tab?.url = URL(string: "https://swift.org")
        tab?.showHomePage = false

        viewModel.zoomIn(for: tab)
        let zoomed = tab?.zoomLevel ?? 0

        tab?.sleep()
        XCTAssertEqual(tab?.isSleeping, true)
        tab?.wake()

        XCTAssertEqual(tab?.zoomLevel ?? 0, zoomed, accuracy: 0.0001)
        XCTAssertNotEqual(zoomed, PageZoom.defaultLevel, "precondition: the tab really was zoomed")
    }

    /// Home releases the web view too (`goHome` sets `webView = nil`).
    func testZoomSurvivesGoingHome() {
        let viewModel = BrowserViewModel()
        let tab = try? XCTUnwrap(viewModel.tabManager.selectedTab)

        viewModel.zoomIn(for: tab)
        let zoomed = tab?.zoomLevel ?? 0

        viewModel.goHome(for: tab)

        XCTAssertEqual(tab?.zoomLevel ?? 0, zoomed, accuracy: 0.0001)
    }

    /// Each tab zooms independently — zoom is per-tab, not per-window.
    func testZoomIsPerTab() {
        let viewModel = BrowserViewModel()
        let first = try? XCTUnwrap(viewModel.tabManager.selectedTab)
        let second = viewModel.tabManager.newTab(switchTo: false)

        viewModel.zoomIn(for: first)

        XCTAssertNotEqual(first?.zoomLevel ?? 0, second.zoomLevel)
        XCTAssertEqual(second.zoomLevel, PageZoom.defaultLevel, accuracy: 0.0001)
    }

    /// `applyZoomLevel()` is the hook `WebViewWrapper` / `adoptWebView` call
    /// when a web view appears. With none, it must be a safe no-op.
    func testApplyingZoomWithNoWebViewIsSafe() {
        let tab = Tab()
        tab.zoomLevel = 1.5
        tab.applyZoomLevel()
        XCTAssertEqual(tab.zoomLevel, 1.5, accuracy: 0.0001)
    }
}
