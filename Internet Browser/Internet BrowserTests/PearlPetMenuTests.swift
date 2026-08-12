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

    // MARK: - The rows themselves

    private func pearl() -> PearlPetView {
        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: .default))
        view.contentSize = CGSize(width: 1200, height: 800)
        return view
    }

    private func titles(_ items: [CherryMenuItem]) -> [String] {
        items.filter { !$0.isSeparator }.map(\.title)
    }

    /// The menu she really builds, in order, with nothing selected: the four
    /// rows that were already there plus the two this round added.
    ///
    /// Dies on a row being dropped, renamed, or reordered into the middle of
    /// the pair it does not belong with.
    func testWhatIsOnHerMenu() {
        let view = pearl()
        let items = view.menuItems(selection: nil, host: HostSpy())
        XCTAssertEqual(titles(items), [
            "Take a Screenshot",
            "Give Pearl a Fish",
            "Pearl's Size",
            "Send Pearl Home",
            "Put Pearl Away",
        ])
        XCTAssertEqual(
            titles(view.menuItems(selection: "sea otters", host: HostSpy())).count, 6,
            "the search row went missing when there was a selection"
        )
    }

    /// The size submenu offers the three whole multiples, with the one she is
    /// ticked — a menu that does not say which size she is is a menu you have
    /// to experiment with.
    ///
    /// Dies on the checkmark being wired to a constant, and on the rows being
    /// built from anything other than `PearlPetSize.allCases`.
    func testTheSizeSubmenuOffersTheThreeSizesAndSaysWhichSheIs() throws {
        let view = pearl()
        view.size = .medium

        let submenu = try XCTUnwrap(
            view.menuItems(selection: nil, host: HostSpy()).first { $0.title == "Pearl's Size" }
        )
        XCTAssertTrue(submenu.hasSubmenu)
        XCTAssertEqual(submenu.submenuItems.map(\.title), ["Small", "Medium", "Large"])
        XCTAssertEqual(submenu.submenuItems.map(\.isOn), [false, true, false])

        view.size = .large
        let after = try XCTUnwrap(
            view.menuItems(selection: nil, host: HostSpy()).first { $0.title == "Pearl's Size" }
        )
        XCTAssertEqual(after.submenuItems.map(\.isOn), [false, false, true])
    }

    /// And picking one off it really resizes her.
    func testPickingASizeOffTheMenuResizesHer() throws {
        let view = pearl()
        view.size = .small
        var reported: [PearlPetSize] = []
        view.onResize = { reported.append($0) }

        let submenu = try XCTUnwrap(
            view.menuItems(selection: nil, host: HostSpy()).first { $0.title == "Pearl's Size" }
        )
        let large = try XCTUnwrap(submenu.submenuItems.first { $0.title == "Large" })
        guard case .action(let perform) = large.kind else {
            return XCTFail("the size row is not an action")
        }
        perform()

        XCTAssertEqual(view.size, .large)
        XCTAssertEqual(reported, [.large])
    }

    /// "Send Pearl Home" is the way back from a spot the user regrets — the one
    /// thing on this menu that no other route in Cherry offers. It is disabled
    /// rather than absent when she is already there, so it can be learned.
    ///
    /// Dies on the row being wired to something other than `PearlPetSpot.home`,
    /// and on the enabled test being inverted.
    func testSendPearlHomePutsHerBackAndKnowsWhenItIsNeeded() throws {
        let view = pearl()
        view.spot = PearlPetSpot(x: 0.1, y: 0.1)
        var reported: [PearlPetSpot] = []
        view.onMove = { reported.append($0) }

        let row = try XCTUnwrap(
            view.menuItems(selection: nil, host: HostSpy()).first { $0.title == "Send Pearl Home" }
        )
        XCTAssertTrue(row.isEnabled, "she is parked away from home and the way back is greyed out")
        guard case .action(let perform) = row.kind else {
            return XCTFail("the home row is not an action")
        }
        perform()

        XCTAssertEqual(view.spot, .home)
        XCTAssertEqual(reported, [.home], "the SwiftUI side was never told, so it would not stick")

        let afterwards = try XCTUnwrap(
            view.menuItems(selection: nil, host: HostSpy()).first { $0.title == "Send Pearl Home" }
        )
        XCTAssertFalse(afterwards.isEnabled, "she is home and the row still offers to send her there")
    }

    // MARK: - The fish

    /// The fish is delight and nothing else: no counter, no file, no key.
    /// This is the test that fails if somebody gives her a persisted appetite.
    func testTheFishPersistsNothing() {
        let before = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.lowercased().contains("pearl") }
            .sorted()

        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: .default))
        view.feed()
        view.feed()
        view.feed()

        let after = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.lowercased().contains("pearl") }
            .sorted()
        XCTAssertEqual(before, after, "feeding her wrote something down")
    }
}
