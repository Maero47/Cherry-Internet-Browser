//
//  TabGroupRenameTests.swift
//  Internet BrowserTests
//
//  Locks the inline group-rename rules: a rename commits a trimmed
//  non-empty name, an empty/whitespace draft leaves the old name in place,
//  and a locked group (the AI research group) can never be renamed —
//  including after a session-restore round trip.
//

import XCTest
@testable import Cherry

@MainActor
final class TabGroupRenameTests: XCTestCase {

    // MARK: - renameGroup

    func testRenameCommitsNewName() {
        let manager = TabManager(createDefaultTab: false)
        let group = manager.createGroup(name: "Work")
        manager.renameGroup(group, to: "Research")
        XCTAssertEqual(group.name, "Research")
    }

    func testRenameTrimsWhitespace() {
        let manager = TabManager(createDefaultTab: false)
        let group = manager.createGroup(name: "Work")
        manager.renameGroup(group, to: "  Reading list \n")
        XCTAssertEqual(group.name, "Reading list")
    }

    func testEmptyRenameKeepsPreviousName() {
        let manager = TabManager(createDefaultTab: false)
        let group = manager.createGroup(name: "Work")
        manager.renameGroup(group, to: "")
        XCTAssertEqual(group.name, "Work")
        manager.renameGroup(group, to: "   \n ")
        XCTAssertEqual(group.name, "Work")
    }

    // MARK: - Locked (AI) groups

    func testRenameIsNoOpOnLockedGroup() {
        let manager = TabManager(createDefaultTab: false)
        let group = manager.createAIResearchGroup()
        manager.renameGroup(group, to: "My research")
        XCTAssertEqual(group.name, "AI", "A locked group must always keep its name")
    }

    func testRestoredLockedGroupStaysLocked() {
        let manager = TabManager(createDefaultTab: false)
        let id = UUID()
        let restored = manager.restoreGroup(id: id, name: "AI", color: .aiIndigo, isCollapsed: false, isLocked: true)
        XCTAssertTrue(restored.isLocked)
        manager.renameGroup(restored, to: "renamed")
        XCTAssertEqual(restored.name, "AI")
    }

    func testRestoreDefaultsToUnlocked() {
        let manager = TabManager(createDefaultTab: false)
        let restored = manager.restoreGroup(id: UUID(), name: "Work", color: .green, isCollapsed: true)
        XCTAssertFalse(restored.isLocked)
        manager.renameGroup(restored, to: "Play")
        XCTAssertEqual(restored.name, "Play")
    }
}
