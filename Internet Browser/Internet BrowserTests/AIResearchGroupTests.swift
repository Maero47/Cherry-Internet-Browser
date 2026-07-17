//
//  AIResearchGroupTests.swift
//  Internet BrowserTests
//
//  Locks the AI research tab-group rules: the reserved aiIndigo color stays
//  out of the user palette, group names derive from the search query with a
//  word-boundary cap, and closing a group's last tab dissolves the group —
//  the path a research run's tabs actually take (the tab-bar ✕, not
//  "Remove from Group").
//

import XCTest
@testable import Cherry

@MainActor
final class AIResearchGroupTests: XCTestCase {

    // MARK: - Reserved color

    func testAIIndigoIsNotUserSelectable() {
        XCTAssertFalse(TabGroupColor.userSelectable.contains(.aiIndigo))
        XCTAssertEqual(TabGroupColor.userSelectable.count, TabGroupColor.allCases.count - 1)
    }

    func testAIIndigoDisplayNameAndRawValueRoundTrip() {
        XCTAssertEqual(TabGroupColor.aiIndigo.displayName, "AI")
        // Session restore rebuilds the color from its raw value.
        XCTAssertEqual(TabGroupColor(rawValue: TabGroupColor.aiIndigo.rawValue), .aiIndigo)
    }

    func testAutoAssignedGroupColorNeverUsesAIIndigo() {
        let manager = TabManager(createDefaultTab: false)
        let tabs = (0..<TabGroupColor.allCases.count + 2).map { _ in Tab() }
        manager.tabs = tabs
        for tab in tabs {
            let group = manager.addTabToNewGroup(tab)
            XCTAssertNotEqual(group.color, .aiIndigo)
        }
    }

    // MARK: - Group naming

    func testShortQueryIsUsedVerbatim() {
        XCTAssertEqual(TabGroup.aiResearchName(for: "swift concurrency"), "swift concurrency")
    }

    func testWhitespaceIsTrimmedAndCollapsed() {
        XCTAssertEqual(TabGroup.aiResearchName(for: "  what is\n WKWebView?  "), "what is WKWebView?")
    }

    func testEmptyQueryFallsBack() {
        XCTAssertEqual(TabGroup.aiResearchName(for: "   \n  "), "AI Research")
    }

    func testLongQueryIsCappedOnWordBoundaryWithEllipsis() {
        let name = TabGroup.aiResearchName(for: "how do tab groups work in modern macOS browsers")
        XCTAssertEqual(name, "how do tab groups work…")
        XCTAssertLessThanOrEqual(name.count, 25)
    }

    func testLongSingleWordIsHardCapped() {
        let name = TabGroup.aiResearchName(for: String(repeating: "a", count: 40))
        XCTAssertEqual(name, String(repeating: "a", count: 24) + "…")
    }

    // MARK: - Lifecycle

    func testClosingLastGroupedTabRemovesGroup() {
        let manager = TabManager(createDefaultTab: false)
        let keeper = Tab()
        let grouped = (0..<2).map { _ in Tab() }
        manager.tabs = [keeper] + grouped
        manager.selectedTabID = keeper.id

        let group = manager.createGroup(name: "AI run", color: .aiIndigo)
        for tab in grouped {
            manager.addTabToGroup(tab, group: group)
        }
        XCTAssertEqual(manager.tabGroups.count, 1)

        manager.closeTab(grouped[0])
        XCTAssertEqual(manager.tabGroups.count, 1, "Group must survive while it still has a member")

        manager.closeTab(grouped[1])
        XCTAssertTrue(manager.tabGroups.isEmpty, "Closing the last member must dissolve the group")
        XCTAssertEqual(manager.tabs, [keeper])
    }

    func testClosingUngroupedTabLeavesOtherGroupsAlone() {
        let manager = TabManager(createDefaultTab: false)
        let loose = Tab()
        let grouped = Tab()
        manager.tabs = [loose, grouped]
        manager.selectedTabID = grouped.id

        let group = manager.createGroup(name: "AI run", color: .aiIndigo)
        manager.addTabToGroup(grouped, group: group)

        manager.closeTab(loose)
        XCTAssertEqual(manager.tabGroups, [group])
    }
}
