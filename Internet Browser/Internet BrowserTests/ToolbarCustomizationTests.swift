//
//  ToolbarCustomizationTests.swift
//  Internet BrowserTests
//
//  The pure half of toolbar customisation: `ToolbarLayout.resolve` turning
//  whatever an older, newer or hand-edited defaults file holds into a layout
//  the nav bar can draw, and the overflow-menu rule that keeps a hidden
//  button invokable.
//

import XCTest
import Observation
@testable import Cherry

final class ToolbarCustomizationTests: XCTestCase {

    private func ids(_ items: [ToolbarButtonID]) -> [String] {
        items.map(\.rawValue)
    }

    private let defaultIDs = ToolbarLayout.defaultOrder.map(\.rawValue)

    // MARK: - Defaults

    /// A fresh install has nothing stored and must look exactly like the
    /// toolbar did before customisation existed.
    func testEmptySavedDataGivesTheDefaults() {
        let layout = ToolbarLayout.resolve(savedOrder: [], hidden: [])

        XCTAssertEqual(layout.order, ToolbarLayout.defaultOrder)
        XCTAssertTrue(layout.hidden.isEmpty)
    }

    /// The documented default order, spelled out — this is the order the nav
    /// bar has always drawn, and a reshuffle of `allCases` would be a silent
    /// visual change for every existing user.
    func testDefaultOrderIsTheShippedToolbarOrder() {
        XCTAssertEqual(
            defaultIDs,
            ["askThisPage", "home", "bookmark", "savePDF", "autoFill",
             "adBlock", "focusMode", "readerMode", "privateMode"]
        )
        XCTAssertEqual(ToolbarLayout.defaultHidden, [])
    }

    func testSavedOrderIsHonoured() {
        let saved = ["privateMode", "home", "askThisPage", "bookmark", "savePDF",
                     "autoFill", "adBlock", "focusMode", "readerMode"]

        XCTAssertEqual(ids(ToolbarLayout.resolve(savedOrder: saved, hidden: []).order), saved)
    }

    // MARK: - Stored-data repair

    /// A button removed in a later build leaves its id behind; it must not
    /// resurrect anything or shift the rest.
    func testUnknownIDIsDropped() {
        let saved = defaultIDs + ["timeMachine"]

        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: [])

        XCTAssertEqual(ids(layout.order), defaultIDs)
    }

    /// A duplicate must collapse to its FIRST occurrence — a button drawn
    /// twice is worse than a button in a stale slot.
    func testDuplicateIDCollapsesToItsFirstOccurrence() {
        let saved = ["home", "bookmark", "home", "askThisPage", "bookmark"]

        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: [])

        XCTAssertEqual(Array(ids(layout.order).prefix(3)), ["home", "bookmark", "askThisPage"])
        XCTAssertEqual(layout.order.count, ToolbarButtonID.allCases.count)
        XCTAssertEqual(Set(layout.order), Set(ToolbarButtonID.allCases))
    }

    /// The case that quietly breaks the next feature: an order written by an
    /// EARLIER build knows nothing about a button added since. It must appear,
    /// at its default-order position — not vanish, and not land at the end.
    func testUnseenItemIsInsertedAtItsDefaultPosition() {
        // Everything except `savePDF` (default index 3), in default order —
        // exactly what a build that predates that button would have written.
        let saved = defaultIDs.filter { $0 != "savePDF" }

        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: [])

        XCTAssertEqual(ids(layout.order), defaultIDs)
    }

    /// Several unseen items at once keep their default order relative to each
    /// other as well as to the items already stored.
    func testSeveralUnseenItemsAreEachInsertedAtTheirDefaultPosition() {
        let saved = ["home", "adBlock", "privateMode"]

        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: [])

        XCTAssertEqual(ids(layout.order), defaultIDs)
    }

    /// With a REORDERED saved layout the newcomer still lands beside the
    /// neighbour it was designed to sit next to — right after the last item
    /// that precedes it in default order.
    func testUnseenItemFollowsItsDefaultPredecessorInAReorderedLayout() {
        // User moved `home` to the front; `bookmark` (default index 2, right
        // after `home`) is the button this build added.
        let saved = ["home", "askThisPage", "savePDF", "autoFill",
                     "adBlock", "focusMode", "readerMode", "privateMode"]

        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: [])

        XCTAssertEqual(
            ids(layout.order),
            ["home", "askThisPage", "bookmark", "savePDF", "autoFill",
             "adBlock", "focusMode", "readerMode", "privateMode"]
        )
    }

    /// An unseen item whose default position is first, with no predecessor in
    /// the stored order, goes to the front rather than the back.
    func testUnseenFirstItemGoesToTheFront() {
        let saved = defaultIDs.filter { $0 != "askThisPage" }

        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: [])

        XCTAssertEqual(layout.order.first, .askThisPage)
        XCTAssertEqual(ids(layout.order), defaultIDs)
    }

    /// Junk in the order never costs the user a button.
    func testEveryCatalogueItemSurvivesGarbageInput() {
        let layout = ToolbarLayout.resolve(
            savedOrder: ["", "home", "HOME", "home", "🍒", "readerMode"],
            hidden: []
        )

        XCTAssertEqual(Set(layout.order), Set(ToolbarButtonID.allCases))
        XCTAssertEqual(layout.order.count, ToolbarButtonID.allCases.count)
    }

    // MARK: - Hidden set

    func testHiddenSetIsFilteredToTheCatalogue() {
        let layout = ToolbarLayout.resolve(
            savedOrder: defaultIDs,
            hidden: ["readerMode", "timeMachine", "", "savePDF"]
        )

        XCTAssertEqual(layout.hidden, [.readerMode, .savePDF])
    }

    /// Hiding changes visibility only — the item keeps its slot in the order,
    /// so showing it again puts it back where it was.
    func testHidingKeepsTheItemInTheOrder() {
        let layout = ToolbarLayout.resolve(savedOrder: defaultIDs, hidden: ["readerMode"])

        XCTAssertEqual(ids(layout.order), defaultIDs)
        XCTAssertTrue(layout.hidden.contains(.readerMode))
    }

    // MARK: - Reset

    func testResetRestoresDefaultOrderAndNothingHidden() {
        let saved = ["privateMode", "readerMode", "home"]
        let customised = ToolbarLayout.resolve(savedOrder: saved, hidden: ["home"])
        XCTAssertNotEqual(customised.order, ToolbarLayout.defaultOrder)
        XCTAssertFalse(customised.hidden.isEmpty)

        // What `SettingsManager.resetToolbarLayout()` writes back.
        let reset = ToolbarLayout.resolve(
            savedOrder: ToolbarLayout.defaultOrder.map(\.rawValue),
            hidden: []
        )

        XCTAssertEqual(reset.order, ToolbarLayout.defaultOrder)
        XCTAssertEqual(reset.hidden, ToolbarLayout.defaultHidden)
    }

    // MARK: - Overflow menu

    /// A hidden button is offered in the ⋯ menu, so hiding it never removes
    /// the feature.
    func testHiddenItemIsOverflowMenuEligible() {
        let layout = ToolbarLayout.resolve(savedOrder: defaultIDs, hidden: ["readerMode"])

        let overflow = ToolbarLayout.overflowItems(
            order: layout.order,
            hidden: layout.hidden,
            isAvailable: { _ in true }
        )

        XCTAssertEqual(overflow, [.readerMode])
    }

    /// A button still ON the toolbar is not duplicated into the menu.
    func testVisibleItemsAreNotOfferedInTheOverflowMenu() {
        let layout = ToolbarLayout.resolve(savedOrder: defaultIDs, hidden: [])

        let overflow = ToolbarLayout.overflowItems(
            order: layout.order,
            hidden: layout.hidden,
            isAvailable: { _ in true }
        )

        XCTAssertTrue(overflow.isEmpty)
    }

    /// Availability still rules: no "Save PDF" entry when no PDF is open, even
    /// though the button is hidden. The nav bar supplies the very same
    /// condition it uses to decide whether to draw the button.
    func testUnavailableHiddenItemStaysOutOfTheOverflowMenu() {
        let layout = ToolbarLayout.resolve(
            savedOrder: defaultIDs,
            hidden: ["savePDF", "autoFill", "readerMode"]
        )

        let overflow = ToolbarLayout.overflowItems(
            order: layout.order,
            hidden: layout.hidden,
            isAvailable: { $0 != .savePDF && $0 != .autoFill }
        )

        XCTAssertEqual(overflow, [.readerMode])
    }

    /// The menu lists hidden items in the user's own order, not catalogue order.
    func testOverflowItemsFollowTheUsersOrder() {
        let saved = ["readerMode", "home", "askThisPage", "bookmark", "savePDF",
                     "autoFill", "adBlock", "focusMode", "privateMode"]
        let layout = ToolbarLayout.resolve(savedOrder: saved, hidden: ["askThisPage", "readerMode"])

        let overflow = ToolbarLayout.overflowItems(
            order: layout.order,
            hidden: layout.hidden,
            isAvailable: { _ in true }
        )

        XCTAssertEqual(overflow, [.readerMode, .askThisPage])
    }

    // MARK: - Ask Cherry AI availability

    /// The whole rule, and the only thing that can still take the button away.
    /// It used to also demand `tab.url != nil && tab.internalPage == nil &&
    /// !tab.showHomePage`; any return of a surface condition has to change
    /// this signature, which is what makes this assertion able to fail.
    func testAskCherryAIIsAvailableWheneverThereIsAnActionToInvoke() {
        XCTAssertTrue(ToolbarLayout.askThisPageIsAvailable(hasAction: true))
        XCTAssertFalse(ToolbarLayout.askThisPageIsAvailable(hasAction: false))
    }

    /// Settings and the `⋯` menu both print this. "Ask This Page" is a promise
    /// the button breaks the moment it appears on the home page.
    func testTheCatalogueTitleNamesTheActionNotTheSurface() {
        XCTAssertEqual(ToolbarButtonID.askThisPage.title, "Ask Cherry AI")
        XCTAssertFalse(ToolbarButtonID.askThisPage.title.lowercased().contains("this page"))
        // The persisted id is untouched by the rename (see `testCatalogueIDsAreStable`).
        XCTAssertEqual(ToolbarButtonID.askThisPage.rawValue, "askThisPage")
    }

    // MARK: - Catalogue

    /// Persisted ids are forever: renaming a case silently returns that button
    /// to its default slot for every user who had moved it.
    func testCatalogueIDsAreStable() {
        XCTAssertEqual(
            Set(ToolbarButtonID.allCases.map(\.rawValue)),
            ["askThisPage", "home", "bookmark", "savePDF", "autoFill",
             "adBlock", "focusMode", "readerMode", "privateMode"]
        )
    }

    /// Structural controls are not customisable and must never enter the
    /// catalogue.
    func testStructuralControlsAreNotInTheCatalogue() {
        let ids = Set(ToolbarButtonID.allCases.map(\.rawValue))
        for structural in ["back", "forward", "reload", "stop", "omnibox", "extensions", "menu"] {
            XCTAssertFalse(ids.contains(structural), "\(structural) must not be customisable")
        }
    }

    func testEveryItemHasATitleAndAnIcon() {
        for item in ToolbarButtonID.allCases {
            XCTAssertFalse(item.title.isEmpty, "\(item.rawValue) has no title")
            XCTAssertFalse(item.systemImage.isEmpty, "\(item.rawValue) has no icon")
        }
    }
}

/// The stored side: `SettingsManager`'s toolbar accessors, and the observation
/// that carries a change made in one window's Settings to every open nav bar.
final class ToolbarSettingsTests: XCTestCase {

    /// The real `UserDefaults` keys `SettingsManager` writes. Spelled out here
    /// rather than reached through the (private) `Keys` enum on purpose: these
    /// strings are the on-disk contract, and a test that renamed itself along
    /// with the constant would not notice a launch-breaking rename.
    private static let orderKey = "toolbarItemOrder"
    private static let hiddenKey = "hiddenToolbarItems"

    override func setUp() {
        super.setUp()

        let savedOrder = SettingsManager.shared.toolbarItemOrder
        let savedHidden = SettingsManager.shared.hiddenToolbarItems
        // Registered BEFORE anything is touched, and via addTeardownBlock so it
        // still runs when a test fails part-way. These tests write to the app's
        // real defaults domain, so a half-finished run must not leave the
        // developer's own toolbar layout blanked.
        addTeardownBlock {
            SettingsManager.shared.toolbarItemOrder = savedOrder
            SettingsManager.shared.hiddenToolbarItems = savedHidden
        }

        SettingsManager.shared.toolbarItemOrder = []
        SettingsManager.shared.hiddenToolbarItems = []
    }

    func testAFreshInstallReportsTheDefaultToolbar() {
        XCTAssertTrue(SettingsManager.shared.toolbarIsDefault)
        XCTAssertEqual(SettingsManager.shared.toolbarLayout.order, ToolbarLayout.defaultOrder)
    }

    func testHidingAndShowingRoundTrips() {
        let settings = SettingsManager.shared

        settings.setToolbarItem(.readerMode, hidden: true)
        XCTAssertTrue(settings.isToolbarItemHidden(.readerMode))
        XCTAssertFalse(settings.toolbarIsDefault)

        settings.setToolbarItem(.readerMode, hidden: false)
        XCTAssertFalse(settings.isToolbarItemHidden(.readerMode))
        XCTAssertTrue(settings.toolbarIsDefault)
    }

    /// Hiding writes back the RESOLVED set, so an id left behind by another
    /// build is cleaned out the first time the user touches the card.
    func testHidingCleansStaleIDsOutOfStorage() {
        let settings = SettingsManager.shared
        settings.hiddenToolbarItems = ["timeMachine", "readerMode"]

        settings.setToolbarItem(.savePDF, hidden: true)

        XCTAssertEqual(settings.hiddenToolbarItems, ["readerMode", "savePDF"])
    }

    func testMovingAnItemSwapsItWithItsNeighbour() {
        let settings = SettingsManager.shared

        settings.moveToolbarItem(.home, by: -1)

        XCTAssertEqual(
            settings.toolbarLayout.order.map(\.rawValue).prefix(2),
            ["home", "askThisPage"]
        )
    }

    func testMovingPastEitherEndIsANoOp() {
        let settings = SettingsManager.shared

        settings.moveToolbarItem(ToolbarLayout.defaultOrder.first!, by: -1)
        settings.moveToolbarItem(ToolbarLayout.defaultOrder.last!, by: 1)

        XCTAssertEqual(settings.toolbarLayout.order, ToolbarLayout.defaultOrder)
    }

    func testResetRestoresTheStockToolbar() {
        let settings = SettingsManager.shared
        settings.moveToolbarItem(.privateMode, by: -1)
        settings.setToolbarItem(.home, hidden: true)
        XCTAssertFalse(settings.toolbarIsDefault)

        settings.resetToolbarLayout()

        XCTAssertTrue(settings.toolbarIsDefault)
        XCTAssertEqual(settings.toolbarLayout.order, ToolbarLayout.defaultOrder)
        XCTAssertEqual(settings.toolbarLayout.hidden, ToolbarLayout.defaultHidden)
    }

    /// Live propagation, at the level SwiftUI actually works at: reading
    /// `toolbarLayout` — the single property `NavigationBarView.body` reads —
    /// registers a dependency that fires when Settings changes the layout.
    /// That is the same `@Observable` invalidation SwiftUI wraps every `body`
    /// in, so every open window's nav bar is redrawn, not just the one whose
    /// Settings page was used.
    func testChangingTheLayoutNotifiesEveryReaderOfToolbarLayout() {
        var hideFired = false
        withObservationTracking {
            _ = SettingsManager.shared.toolbarLayout
        } onChange: {
            hideFired = true
        }

        SettingsManager.shared.setToolbarItem(.readerMode, hidden: true)
        XCTAssertTrue(hideFired, "hiding a button must invalidate readers of toolbarLayout")

        var moveFired = false
        withObservationTracking {
            _ = SettingsManager.shared.toolbarLayout
        } onChange: {
            moveFired = true
        }

        SettingsManager.shared.moveToolbarItem(.home, by: -1)
        XCTAssertTrue(moveFired, "reordering must invalidate readers of toolbarLayout")

        var resetFired = false
        withObservationTracking {
            _ = SettingsManager.shared.toolbarLayout
        } onChange: {
            resetFired = true
        }

        SettingsManager.shared.resetToolbarLayout()
        XCTAssertTrue(resetFired, "resetting must invalidate readers of toolbarLayout")
    }

    /// The only part that can lose data across a launch: what actually lands
    /// in `UserDefaults`.
    ///
    /// Reads the two keys straight out of `UserDefaults.standard` rather than
    /// re-reading the in-memory properties — those would agree with themselves
    /// even if no `didSet` ever wrote anything — and then rehydrates from
    /// exactly those strings the way `SettingsManager.init` does.
    func testHideAndReorderAreWrittenToUserDefaults() {
        let settings = SettingsManager.shared
        let defaults = UserDefaults.standard

        settings.setToolbarItem(.savePDF, hidden: true)
        settings.moveToolbarItem(.privateMode, by: -1)

        let storedOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
        let storedHidden = defaults.stringArray(forKey: Self.hiddenKey) ?? []

        XCTAssertEqual(
            storedOrder,
            ["askThisPage", "home", "bookmark", "savePDF", "autoFill",
             "adBlock", "focusMode", "privateMode", "readerMode"]
        )
        XCTAssertEqual(storedHidden, ["savePDF"])

        // What the next launch rebuilds from the bytes on disk.
        let rehydrated = ToolbarLayout.resolve(savedOrder: storedOrder, hidden: Set(storedHidden))
        XCTAssertEqual(rehydrated.order, settings.toolbarLayout.order)
        XCTAssertEqual(rehydrated.hidden, [.savePDF])
        XCTAssertEqual(rehydrated.order.last, .readerMode)
    }

    /// Reset has to reach the disk too, or the old layout comes back on the
    /// next launch.
    func testResetIsWrittenToUserDefaults() {
        let settings = SettingsManager.shared
        let defaults = UserDefaults.standard
        settings.setToolbarItem(.home, hidden: true)
        settings.moveToolbarItem(.privateMode, by: -1)

        settings.resetToolbarLayout()

        XCTAssertEqual(
            defaults.stringArray(forKey: Self.orderKey),
            ToolbarLayout.defaultOrder.map(\.rawValue)
        )
        XCTAssertEqual(defaults.stringArray(forKey: Self.hiddenKey), [])

        let rehydrated = ToolbarLayout.resolve(
            savedOrder: defaults.stringArray(forKey: Self.orderKey) ?? [],
            hidden: Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        )
        XCTAssertEqual(rehydrated.order, ToolbarLayout.defaultOrder)
        XCTAssertEqual(rehydrated.hidden, ToolbarLayout.defaultHidden)
    }
}
