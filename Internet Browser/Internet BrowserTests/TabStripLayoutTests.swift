//
//  TabStripLayoutTests.swift
//  Internet BrowserTests
//
//  Locks the flattening rules both tab bars render from: every group with
//  members gets exactly one persistent header pill at its first member's
//  position, a collapsed group's tabs are hidden behind the pill, pinned
//  tabs never appear as strip items but still keep their group's pill alive.
//

import XCTest
@testable import Cherry

@MainActor
final class TabStripLayoutTests: XCTestCase {

    // MARK: - Helpers

    private func makeTab(pinned: Bool = false, group: TabGroup? = nil) -> Tab {
        let tab = Tab()
        tab.isPinned = pinned
        tab.group = group
        return tab
    }

    private func ids(_ items: [TabStripItem]) -> [UUID] {
        items.map(\.id)
    }

    private func headerGroupIDs(_ items: [TabStripItem]) -> [UUID] {
        items.compactMap {
            if case .groupHeader(let group) = $0 { return group.id }
            return nil
        }
    }

    // MARK: - Pill placement

    func testHeaderPillPrecedesGroupsFirstTabWhenExpanded() {
        let group = TabGroup(name: "Work")
        let loose = makeTab()
        let first = makeTab(group: group)
        let second = makeTab(group: group)

        let items = TabStripLayout.regularItems(for: [loose, first, second])

        XCTAssertEqual(ids(items), [loose.id, group.id, first.id, second.id],
                       "The pill must sit immediately before the group's first tab")
    }

    func testCollapsedGroupShowsOnlyThePill() {
        let group = TabGroup(name: "Work", isCollapsed: true)
        let member = makeTab(group: group)
        let loose = makeTab()

        let items = TabStripLayout.regularItems(for: [member, loose])

        XCTAssertEqual(ids(items), [group.id, loose.id],
                       "Collapsed group's tabs are hidden; the pill stays at the group's position")
    }

    func testUngroupedTabsPassThroughUnchanged() {
        let tabs = [makeTab(), makeTab(), makeTab()]
        let items = TabStripLayout.regularItems(for: tabs)
        XCTAssertEqual(ids(items), tabs.map(\.id))
    }

    func testEachGroupGetsExactlyOnePill() {
        let work = TabGroup(name: "Work")
        let play = TabGroup(name: "Play")
        let tabs = [makeTab(group: work), makeTab(group: work),
                    makeTab(group: play), makeTab(group: play)]

        let items = TabStripLayout.regularItems(for: tabs)

        XCTAssertEqual(headerGroupIDs(items), [work.id, play.id])
    }

    // MARK: - Non-contiguous groups

    func testNonContiguousGroupGetsSinglePillAtFirstMember() {
        let group = TabGroup(name: "Scattered")
        let first = makeTab(group: group)
        let interloper = makeTab()
        let straggler = makeTab(group: group)

        let items = TabStripLayout.regularItems(for: [first, interloper, straggler])

        XCTAssertEqual(ids(items), [group.id, first.id, interloper.id, straggler.id],
                       "One pill at the first member; later members stay in place")
    }

    // MARK: - Pinned members

    func testPinnedTabsAreNotStripItemsButKeepTheirGroupsPill() {
        let group = TabGroup(name: "Mixed")
        let pinnedMember = makeTab(pinned: true, group: group)
        let regularMember = makeTab(group: group)

        let items = TabStripLayout.regularItems(for: [pinnedMember, regularMember])

        XCTAssertEqual(ids(items), [group.id, regularMember.id],
                       "The pinned section renders pinned tabs; the pill still leads the group")
    }

    func testAllPinnedCollapsedGroupStillGetsAPill() {
        let group = TabGroup(name: "Pinned only", isCollapsed: true)
        let pinnedMember = makeTab(pinned: true, group: group)

        let items = TabStripLayout.regularItems(for: [pinnedMember])

        XCTAssertEqual(ids(items), [group.id],
                       "Without the pill a collapsed all-pinned group could never be expanded")
    }

    // MARK: - Groups without members

    func testGroupReferencedByNoTabProducesNoPill() {
        let items = TabStripLayout.regularItems(for: [makeTab(), makeTab()])
        XCTAssertTrue(headerGroupIDs(items).isEmpty)
    }
}
