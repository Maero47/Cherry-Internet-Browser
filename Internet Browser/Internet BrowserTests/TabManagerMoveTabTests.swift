//
//  TabManagerMoveTabTests.swift
//  Internet BrowserTests
//
//  Locks the semantics of `TabManager.moveTab(withID:toPositionOf:)`: the
//  dragged tab lands AT the target's pre-move position in BOTH directions,
//  matching what the tab bars' `tabs.move(fromOffsets:toOffset:)` reorder
//  paths produce. The rightward case is the subtle one — removing the
//  source shifts the target down one, so inserting at the target's
//  pre-move index fills exactly the slot it vacated.
//

import XCTest
@testable import Cherry

@MainActor
final class TabManagerMoveTabTests: XCTestCase {

    /// A manager whose tabs are seeded directly (bypassing `newTab`, which
    /// would notify the extension manager) — order assertions read tab ids.
    private func makeManager(tabCount: Int) -> (TabManager, [UUID]) {
        let manager = TabManager(createDefaultTab: false)
        let tabs = (0..<tabCount).map { _ in Tab() }
        manager.tabs = tabs
        return (manager, tabs.map(\.id))
    }

    func testRightwardDragLandsAtTargetsPosition() {
        let (manager, ids) = makeManager(tabCount: 4)
        // [A, B, C, D]: drag A onto C → A takes C's slot: [B, C, A, D]
        manager.moveTab(withID: ids[0], toPositionOf: ids[2])
        XCTAssertEqual(manager.tabs.map(\.id), [ids[1], ids[2], ids[0], ids[3]])
    }

    func testLeftwardDragLandsAtTargetsPosition() {
        let (manager, ids) = makeManager(tabCount: 4)
        // [A, B, C, D]: drag D onto B → D takes B's slot: [A, D, B, C]
        manager.moveTab(withID: ids[3], toPositionOf: ids[1])
        XCTAssertEqual(manager.tabs.map(\.id), [ids[0], ids[3], ids[1], ids[2]])
    }

    func testRightwardDragToLastPosition() {
        let (manager, ids) = makeManager(tabCount: 3)
        // [A, B, C]: drag A onto C → [B, C, A]
        manager.moveTab(withID: ids[0], toPositionOf: ids[2])
        XCTAssertEqual(manager.tabs.map(\.id), [ids[1], ids[2], ids[0]])
    }

    func testAdjacentSwapBothDirections() {
        let (manager, ids) = makeManager(tabCount: 2)
        manager.moveTab(withID: ids[0], toPositionOf: ids[1])
        XCTAssertEqual(manager.tabs.map(\.id), [ids[1], ids[0]])
        manager.moveTab(withID: ids[0], toPositionOf: ids[1])
        XCTAssertEqual(manager.tabs.map(\.id), [ids[0], ids[1]])
    }

    func testMoveOntoItselfIsANoOp() {
        let (manager, ids) = makeManager(tabCount: 3)
        manager.moveTab(withID: ids[1], toPositionOf: ids[1])
        XCTAssertEqual(manager.tabs.map(\.id), ids)
    }

    func testUnknownIDsAreANoOp() {
        let (manager, ids) = makeManager(tabCount: 3)
        manager.moveTab(withID: UUID(), toPositionOf: ids[0])
        manager.moveTab(withID: ids[0], toPositionOf: UUID())
        XCTAssertEqual(manager.tabs.map(\.id), ids)
    }
}
