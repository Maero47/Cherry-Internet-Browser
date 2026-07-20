//
//  AIGroupSelectionSyncTests.swift
//  Internet BrowserTests
//
//  Locks the machinery behind the AI-group ↔ chat-selection sync: the pure
//  membership diff both reconciliations write from (compare-before-write is
//  what makes the bidirectional sync converge instead of ping-ponging), and
//  `ensureAIResearchGroup` — every AI path routes through it, so membership
//  edits keep exactly one `.aiIndigo` group until it empties and auto-removes.
//

import XCTest
@testable import Cherry

// MARK: - Pure membership diff

final class AIGroupMembershipDiffTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testAddOnly() {
        let diff = TabManager.reconcileAIGroupMembership(selection: [a, b, c], currentMembers: [a, b])
        XCTAssertEqual(diff.toAdd, [c])
        XCTAssertTrue(diff.toRemove.isEmpty)
    }

    func testRemoveOnly() {
        let diff = TabManager.reconcileAIGroupMembership(selection: [a], currentMembers: [a, b, c])
        XCTAssertTrue(diff.toAdd.isEmpty)
        XCTAssertEqual(diff.toRemove, [b, c])
    }

    func testMixed() {
        let diff = TabManager.reconcileAIGroupMembership(selection: [a, c], currentMembers: [a, b, d])
        XCTAssertEqual(diff.toAdd, [c])
        XCTAssertEqual(diff.toRemove, [b, d])
    }

    /// Equal sets diff to nothing — the guard that stops the two mirrored
    /// `.onChange` reconciliations from ever writing in a converged state.
    func testNoOpWhenEqual() {
        let diff = TabManager.reconcileAIGroupMembership(selection: [a, b], currentMembers: [a, b])
        XCTAssertTrue(diff.toAdd.isEmpty)
        XCTAssertTrue(diff.toRemove.isEmpty)

        let empty = TabManager.reconcileAIGroupMembership(selection: [], currentMembers: [])
        XCTAssertTrue(empty.toAdd.isEmpty)
        XCTAssertTrue(empty.toRemove.isEmpty)
    }

    func testEmptySelectionRemovesAll() {
        let diff = TabManager.reconcileAIGroupMembership(selection: [], currentMembers: [a, b, c])
        XCTAssertTrue(diff.toAdd.isEmpty)
        XCTAssertEqual(diff.toRemove, [a, b, c])
    }
}

// MARK: - Single AI group lifecycle

@MainActor
final class EnsureAIResearchGroupTests: XCTestCase {

    func testEnsureCreatesTheAIGroupWhenAbsent() {
        let manager = TabManager(createDefaultTab: false)
        let group = manager.ensureAIResearchGroup()
        XCTAssertEqual(group.name, "AI")
        XCTAssertEqual(group.color, .aiIndigo)
        XCTAssertTrue(group.isLocked)
        XCTAssertEqual(manager.tabGroups, [group])
    }

    func testEnsureReusesTheExistingAIGroup() {
        let manager = TabManager(createDefaultTab: false)
        let first = manager.ensureAIResearchGroup()
        let second = manager.ensureAIResearchGroup()
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(manager.tabGroups, [first])
    }

    func testEnsureIgnoresUserGroups() {
        let manager = TabManager(createDefaultTab: false)
        let user = manager.createGroup(name: "Work", color: .blue)
        let ai = manager.ensureAIResearchGroup()
        XCTAssertNotEqual(ai.id, user.id)
        XCTAssertEqual(manager.tabGroups.count, 2)
    }

    /// Legacy sessions could have saved several AI groups (creation used to
    /// always make a fresh one) — ensure folds them into one.
    func testEnsureConsolidatesDuplicateAIGroups() {
        let manager = TabManager(createDefaultTab: false)
        let tabs = (0..<2).map { _ in Tab() }
        manager.tabs = tabs
        let first = manager.createAIResearchGroup()
        let second = manager.createAIResearchGroup()
        manager.addTabToGroup(tabs[0], group: first)
        manager.addTabToGroup(tabs[1], group: second)

        let ensured = manager.ensureAIResearchGroup()
        XCTAssertEqual(ensured.id, first.id)
        XCTAssertEqual(manager.tabGroups, [first])
        XCTAssertTrue(tabs.allSatisfy { $0.group?.id == first.id })
    }

    /// The sync moves tabs between groups programmatically (chip-selecting a
    /// user-grouped tab pulls it into the AI group), so `addTabToGroup` must
    /// clean up the vacated group: moving out the sole member drops the old
    /// group, while a group with remaining members survives losing one.
    func testMovingTabBetweenGroupsDropsVacatedEmptyGroup() {
        let manager = TabManager(createDefaultTab: false)
        let solo = Tab()
        let pair = (0..<2).map { _ in Tab() }
        manager.tabs = [solo] + pair

        let soloGroup = manager.createGroup(name: "Solo", color: .blue)
        manager.addTabToGroup(solo, group: soloGroup)
        let pairGroup = manager.createGroup(name: "Pair", color: .green)
        for tab in pair {
            manager.addTabToGroup(tab, group: pairGroup)
        }

        let ai = manager.ensureAIResearchGroup()
        manager.addTabToGroup(solo, group: ai)
        XCTAssertFalse(manager.tabGroups.contains(soloGroup), "Vacated empty group must be dropped")
        XCTAssertEqual(solo.group?.id, ai.id)

        manager.addTabToGroup(pair[0], group: ai)
        XCTAssertTrue(manager.tabGroups.contains(pairGroup), "A group with remaining members survives")
        XCTAssertEqual(pair[1].group?.id, pairGroup.id)

        // Re-adding a tab to the group it's already in must not drop that group.
        manager.addTabToGroup(pair[0], group: ai)
        XCTAssertTrue(manager.tabGroups.contains(ai))
    }

    /// The programmatic paths' contract (repeat web search / reopen): reusing
    /// the AI group for a new tab set must end with members == exactly that
    /// set — the previous run's tabs are ejected (staying open, ungrouped),
    /// never left as a stale superset for the observers to untangle.
    func testReusedGroupSyncsToNewSelectionEjectingStaleMembers() {
        let manager = TabManager(createDefaultTab: false)
        let oldTabs = (0..<2).map { _ in Tab() }
        let newTabs = (0..<2).map { _ in Tab() }
        manager.tabs = oldTabs + newTabs

        let firstRun = manager.ensureAIResearchGroup()
        for tab in oldTabs {
            manager.addTabToGroup(tab, group: firstRun)
        }

        // Second run: reuse the group, add the new set, eject the stale rest.
        let secondRun = manager.ensureAIResearchGroup()
        XCTAssertEqual(secondRun.id, firstRun.id)
        let selection = Set(newTabs.map(\.id))
        for tab in newTabs {
            manager.addTabToGroup(tab, group: secondRun)
        }
        for tab in manager.tabs where tab.group?.color == .aiIndigo && !selection.contains(tab.id) {
            manager.removeTabFromGroup(tab)
        }

        let members = Set(manager.tabs.filter { $0.group?.color == .aiIndigo }.map(\.id))
        XCTAssertEqual(members, selection)
        XCTAssertEqual(manager.tabGroups, [firstRun], "The reused group survives with the new members")
        XCTAssertTrue(oldTabs.allSatisfy { $0.group == nil }, "Stale tabs are ungrouped, not closed")
        XCTAssertEqual(manager.tabs.count, 4, "Ejection never closes tabs")
    }

    /// The reconciliation's write path: applying an add/remove diff through
    /// the normal membership APIs keeps the single AI group until the last
    /// member leaves, at which point the group auto-removes.
    func testMembershipEditsKeepSingleGroupUntilEmptyAutoRemoves() {
        let manager = TabManager(createDefaultTab: false)
        let tabs = (0..<3).map { _ in Tab() }
        manager.tabs = tabs

        let group = manager.ensureAIResearchGroup()
        for tab in tabs {
            manager.addTabToGroup(tab, group: group)
        }
        XCTAssertEqual(manager.tabGroups, [group])
        XCTAssertTrue(tabs.allSatisfy { $0.group?.id == group.id })

        manager.removeTabFromGroup(tabs[0])
        XCTAssertEqual(manager.tabGroups, [group], "Group must survive while members remain")
        XCTAssertNil(tabs[0].group)

        manager.removeTabFromGroup(tabs[1])
        manager.removeTabFromGroup(tabs[2])
        XCTAssertTrue(manager.tabGroups.isEmpty, "Emptying the AI group must auto-remove it")
        XCTAssertTrue(tabs.allSatisfy { $0.group == nil })
    }
}
