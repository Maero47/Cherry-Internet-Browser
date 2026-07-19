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
