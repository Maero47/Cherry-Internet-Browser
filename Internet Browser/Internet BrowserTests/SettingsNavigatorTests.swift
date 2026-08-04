//
//  SettingsNavigatorTests.swift
//  Internet BrowserTests
//
//  Clicking the MCP connection indicator has to land the user on Settings ▸
//  Connections, from either starting state: Settings not open, and Settings
//  already open. The first version handled only the first, and left its request
//  set when it failed — so the click did nothing AND the next Settings open was
//  hijacked onto Connections.
//

import XCTest
@testable import Cherry

@MainActor
final class SettingsNavigatorTests: XCTestCase {

    private var navigator: SettingsNavigator!

    override func setUp() {
        super.setUp()
        // A fresh instance per test: the shared one is app state, and a test
        // that leaves a request on it would redirect the next Settings page the
        // developer opens.
        navigator = SettingsNavigator()
    }

    func testThereIsNothingToApplyUntilSomethingAsks() {
        XCTAssertNil(navigator.takeRequestedSection())
        XCTAssertEqual(navigator.requestSerial, 0)
    }

    /// The case that used to work: Settings is not open, the click creates it,
    /// and the new page picks the request up on appear.
    func testARequestSurvivesUntilThePageThatNeedsItAppears() {
        navigator.request(.connections)
        XCTAssertEqual(navigator.takeRequestedSection(), .connections)
    }

    /// The case that used to be a silent no-op: `Tab.openInternalPage` only
    /// re-sets `internalPage = .settings`, so an already-open Settings page is
    /// never recreated and `onAppear` never fires. The serial is what an
    /// on-screen page observes instead.
    func testAskingAgainForTheSameSectionStillPublishesAChange() {
        navigator.request(.connections)
        let first = navigator.requestSerial
        _ = navigator.takeRequestedSection()

        navigator.request(.connections)
        XCTAssertGreaterThan(
            navigator.requestSerial, first,
            "asking twice for the same section must be two events, or the second click does nothing"
        )
        XCTAssertEqual(navigator.takeRequestedSection(), .connections)
    }

    /// The hijack: an unconsumed request used to sit there and redirect an
    /// unrelated Settings open later, sending a user who asked for General to
    /// Connections.
    func testTakingARequestClearsItSoTheNextOpenIsNotHijacked() {
        navigator.request(.connections)
        XCTAssertEqual(navigator.takeRequestedSection(), .connections)
        XCTAssertNil(navigator.takeRequestedSection(), "the request outlived the page that consumed it")
        XCTAssertNil(navigator.takeRequestedSection())
    }

    /// Two Settings pages can exist at once, in different windows. Only one
    /// should move; the other must stay where the user left it.
    func testOnlyOnePageCanConsumeARequest() {
        navigator.request(.connections)
        let firstPage = navigator.takeRequestedSection()
        let secondPage = navigator.takeRequestedSection()
        XCTAssertEqual(firstPage, .connections)
        XCTAssertNil(secondPage)
    }

    func testTheLatestRequestWins() {
        navigator.request(.connections)
        navigator.request(.privacy)
        XCTAssertEqual(navigator.takeRequestedSection(), .privacy)
    }

    /// The section the indicator asks for has to exist, and has to be the one
    /// carrying the switch that stops the reading.
    func testConnectionsIsASectionAndSitsBeforeAbout() {
        let sections = SettingsSection.allCases
        let connections = try? XCTUnwrap(sections.firstIndex(of: .connections))
        let about = try? XCTUnwrap(sections.firstIndex(of: .about))
        XCTAssertNotNil(connections)
        XCTAssertNotNil(about)
        XCTAssertLessThan(connections ?? .max, about ?? .min)
        XCTAssertFalse(SettingsSection.connections.subtitle.isEmpty)
        XCTAssertFalse(SettingsSection.connections.icon.isEmpty)
    }
}
