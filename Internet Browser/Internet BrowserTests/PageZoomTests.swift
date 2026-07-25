//
//  PageZoomTests.swift
//  Internet BrowserTests
//
//  The View ▸ Zoom In / Zoom Out / Actual Size ladder, which had no
//  implementation at all before — the three menu items posted notifications
//  nothing listened for.
//

import XCTest
@testable import Cherry

final class PageZoomTests: XCTestCase {

    func testStepsUpAndDownThroughTheLadder() {
        XCTAssertEqual(PageZoom.step(from: 1.0, direction: 1), 1.1, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.step(from: 1.1, direction: 1), 1.25, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.step(from: 1.0, direction: -1), 0.9, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.step(from: 0.9, direction: -1), 0.8, accuracy: 0.0001)
    }

    func testRoundTripsBackToWhereItStarted() {
        let zoomedIn = PageZoom.step(from: 1.0, direction: 1)
        XCTAssertEqual(PageZoom.step(from: zoomedIn, direction: -1), 1.0, accuracy: 0.0001)
    }

    /// Holding ⌘+ at the top (or ⌘- at the bottom) must be a no-op, not an
    /// unreadable page.
    func testClampsAtBothEnds() {
        let max = PageZoom.levels.last!
        let min = PageZoom.levels.first!
        XCTAssertEqual(PageZoom.step(from: max, direction: 1), max, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.step(from: min, direction: -1), min, accuracy: 0.0001)
    }

    /// A page pinch-zoomed to an off-ladder value snaps to the neighbouring
    /// step in the direction pressed, rather than jumping to 100%.
    func testSnapsAnOffLadderZoomToTheNeighbouringStep() {
        XCTAssertEqual(PageZoom.step(from: 1.03, direction: 1), 1.1, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.step(from: 1.03, direction: -1), 1.0, accuracy: 0.0001)
    }

    func testDirectionZeroChangesNothing() {
        XCTAssertEqual(PageZoom.step(from: 1.25, direction: 0), 1.25, accuracy: 0.0001)
    }

    func testLadderIsSortedAndIncludesActualSize() {
        XCTAssertEqual(PageZoom.levels, PageZoom.levels.sorted())
        XCTAssertTrue(PageZoom.levels.contains(PageZoom.defaultLevel))
    }

    /// Every level must be reachable by stepping from the one below, or ⌘+
    /// would skip a rung.
    func testEveryLevelIsReachableByStepping() {
        var level = PageZoom.levels.first!
        var visited = [level]
        while level < PageZoom.levels.last! {
            level = PageZoom.step(from: level, direction: 1)
            visited.append(level)
        }
        XCTAssertEqual(visited, PageZoom.levels)
    }
}
