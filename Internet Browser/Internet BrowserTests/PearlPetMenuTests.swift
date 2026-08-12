//
//  PearlPetMenuTests.swift
//  Internet BrowserTests
//
//  What her right-click menu offers, and — the part worth testing — that each
//  entry calls the browser's real path rather than a copy of it.
//
//  Two kinds of proof here:
//
//  1. a spy in the `PearlPetHost` slot, which shows WHICH browser method each
//     action calls and in what order;
//  2. a real `BrowserViewModel` in the same slot, which shows that the call
//     lands: the search leaves a tab pointed at the user's own search engine,
//     built by the same `URL.searchURL` the address bar uses.
//
//  The protocol is what makes both possible, and it is deliberately not an
//  abstraction: every method on it except the selection reader existed on
//  `BrowserViewModel` before the pet did.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
private final class HostSpy: PearlPetHost {
    var screenshots = 0
    var newTabs = 0
    var searches: [String] = []
    var calls: [String] = []
    var selection: String?

    func captureScreenshot() {
        screenshots += 1
        calls.append("screenshot")
    }

    func newTab(url: URL?) {
        newTabs += 1
        calls.append("newTab")
    }

    func performSearch(_ query: String) {
        searches.append(query)
        calls.append("search")
    }

    func readPageSelection(_ completion: @escaping (String?) -> Void) {
        calls.append("selection")
        completion(selection)
    }
}

@MainActor
final class PearlPetMenuTests: XCTestCase {

    // MARK: - The selection, cleaned up

    func testASelectionBecomesAQuery() {
        XCTAssertEqual(PearlPetMenu.query(from: "otters"), "otters")
        XCTAssertEqual(PearlPetMenu.query(from: "  sea   otters \n"), "sea otters")
        XCTAssertEqual(PearlPetMenu.query(from: "sea\notters"), "sea otters")
    }

    func testNothingSelectedIsNoQuery() {
        XCTAssertNil(PearlPetMenu.query(from: nil))
        XCTAssertNil(PearlPetMenu.query(from: ""))
        XCTAssertNil(PearlPetMenu.query(from: "   \n\t  "))
    }

    /// A selected chapter is not a query. It is cut, not refused — refusing it
    /// would leave the useful row missing for the case it was written for.
    func testAWholeParagraphIsCutRatherThanRefused() {
        let long = String(repeating: "otter ", count: 400)
        let query = PearlPetMenu.query(from: long)
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.count, PearlPetMenu.maximumQueryLength)
    }

    /// The row shows the user their own words, elided rather than sprawling.
    func testTheRowNamesWhatWillBeSearchedFor() {
        XCTAssertEqual(PearlPetMenu.searchTitle(for: "otters"), "Search for “otters”")
        let title = PearlPetMenu.searchTitle(for: String(repeating: "x", count: 200))
        XCTAssertTrue(title.hasSuffix("…”"), "a 200-character menu row: \(title)")
        XCTAssertLessThan(title.count, PearlPetMenu.titleLength + 16)
    }

    // MARK: - Each action reaches the browser

    func testTheScreenshotIsCherrysScreenshot() {
        let spy = HostSpy()
        PearlPetMenu.takeScreenshot(host: spy)
        XCTAssertEqual(spy.screenshots, 1)
        XCTAssertEqual(spy.calls, ["screenshot"], "the pet did something else as well")
    }

    /// A new tab, then the search in it — the same two calls the browser makes
    /// for itself, in the order that puts the results somewhere that is not
    /// the page the user was reading.
    func testTheSearchOpensATabAndSearchesInIt() {
        let spy = HostSpy()
        PearlPetMenu.search("sea otters", host: spy)
        XCTAssertEqual(spy.calls, ["newTab", "search"])
        XCTAssertEqual(spy.searches, ["sea otters"])
    }

    /// The real thing: a real view model in the host slot, and a tab left
    /// pointing at the user's own search engine's results.
    func testTheSearchLandsOnTheUsersOwnSearchEngine() throws {
        let viewModel = BrowserViewModel()
        let host: any PearlPetHost = viewModel
        let tabsBefore = viewModel.tabManager.tabs.count

        PearlPetMenu.search("sea otters", host: host)

        XCTAssertEqual(viewModel.tabManager.tabs.count, tabsBefore + 1, "no new tab was opened")
        let url = try XCTUnwrap(viewModel.tabManager.selectedTab?.url, "the new tab went nowhere")
        let expected = try XCTUnwrap(
            URL.searchURL(for: "sea otters", engine: SettingsManager.shared.searchEngine)
        )
        XCTAssertEqual(url, expected, "the pet built its own search URL instead of using Cherry's")
    }

    /// `BrowserViewModel` is the host, and its screenshot IS the browser's
    /// screenshot — the one the ⌥⌘4 menu command and the toolbar camera call.
    /// Nothing in the pet feature implements one.
    func testTheBrowserItselfIsTheHost() {
        let viewModel = BrowserViewModel()
        XCTAssertTrue((viewModel as Any) is any PearlPetHost)
    }

    /// With nothing selected the page reader says so, and the menu has no
    /// search row to build.
    func testWithNothingSelectedThereIsNoSearchRow() {
        let spy = HostSpy()
        spy.selection = "  \n "
        var offered: String??
        spy.readPageSelection { offered = PearlPetMenu.query(from: $0) }
        XCTAssertEqual(offered, .some(nil))
    }

    /// A view model with no web view answers "nothing selected" rather than
    /// hanging the menu.
    func testAPageWithNoWebViewReportsNoSelection() {
        let viewModel = BrowserViewModel()
        var answered = false
        var selection: String? = "unset"
        viewModel.readPageSelection { value in
            answered = true
            selection = value
        }
        XCTAssertTrue(answered, "the menu would wait forever for a page that cannot answer")
        XCTAssertNil(selection)
    }

    // MARK: - The fish

    /// The fish is delight and nothing else: no counter, no file, no key.
    /// This is the test that fails if somebody gives her a persisted appetite.
    func testTheFishPersistsNothing() {
        let before = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.lowercased().contains("pearl") }
            .sorted()

        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        view.feed()
        view.feed()
        view.feed()

        let after = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.lowercased().contains("pearl") }
            .sorted()
        XCTAssertEqual(before, after, "feeding her wrote something down")
    }
}
