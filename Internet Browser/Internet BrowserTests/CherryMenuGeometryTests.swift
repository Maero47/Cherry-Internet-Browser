//
//  CherryMenuGeometryTests.swift
//  Internet BrowserTests
//
//  Edge flipping is the thing `NSMenu` did silently and correctly and that a
//  hand-drawn menu gets wrong silently and incorrectly: you only find out by
//  opening a menu near the bottom of a screen you happened to think of. So the
//  placement is pure arithmetic, and every edge is covered here instead.
//
//  All rects are AppKit screen coordinates: origin bottom-left, y up.
//

import XCTest
@testable import Cherry

final class CherryMenuGeometryTests: XCTestCase {

    /// A 1440×900 display with the menu bar taken off the top.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let small = CGSize(width: 200, height: 120)

    // MARK: - Context menus

    func testContextMenuHangsBelowAndRightOfTheClick() {
        let frame = CherryMenuGeometry.contextFrame(
            size: small, at: CGPoint(x: 400, y: 600), in: screen
        )
        XCTAssertEqual(frame.minX, 400, "Left edge sits at the click.")
        XCTAssertEqual(frame.maxY, 600, "Top edge sits at the click.")
    }

    func testContextMenuFlipsUpNearTheBottomOfTheScreen() {
        // 40pt above the bottom: a 120pt menu cannot hang below it.
        let frame = CherryMenuGeometry.contextFrame(
            size: small, at: CGPoint(x: 400, y: 40), in: screen
        )
        XCTAssertEqual(frame.minY, 40, "Flipped: the menu's bottom is now at the click.")
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY, "And it is fully on screen.")
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    func testContextMenuFlipsLeftNearTheRightEdge() {
        let frame = CherryMenuGeometry.contextFrame(
            size: small, at: CGPoint(x: 1430, y: 600), in: screen
        )
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX, "Never clipped by the right edge.")
        XCTAssertEqual(frame.maxX, 1430, accuracy: 0.5, "Flipped about the click, not merely shoved.")
    }

    func testContextMenuInTheBottomRightCornerFlipsBothWays() {
        let frame = CherryMenuGeometry.contextFrame(
            size: small, at: CGPoint(x: 1435, y: 20), in: screen
        )
        XCTAssertTrue(screen.contains(frame), "Corner case: still entirely on screen.")
    }

    /// A menu too tall for the screen has nowhere to flip to, so it is slid on
    /// screen and capped rather than left hanging off an edge.
    func testAMenuTallerThanTheScreenIsCappedAndOnScreen() {
        let frame = CherryMenuGeometry.contextFrame(
            size: CGSize(width: 200, height: 2000), at: CGPoint(x: 400, y: 400), in: screen
        )
        XCTAssertLessThanOrEqual(frame.height, CherryMenuGeometry.maxHeight(in: screen))
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    // MARK: - Menus hung off a control

    func testAnchoredMenuOpensBelowTheControlAlignedToItsLeftEdge() {
        let button = CGRect(x: 300, y: 700, width: 28, height: 28)
        let frame = CherryMenuGeometry.anchoredFrame(size: small, below: button, in: screen)
        XCTAssertEqual(frame.minX, button.minX)
        XCTAssertEqual(frame.maxY, button.minY, "Top of the menu meets the bottom of the button.")
    }

    func testAnchoredMenuFlipsAboveAControlNearTheBottom() {
        let button = CGRect(x: 300, y: 30, width: 28, height: 28)
        let frame = CherryMenuGeometry.anchoredFrame(size: small, below: button, in: screen)
        XCTAssertEqual(frame.minY, button.maxY, "Bottom of the menu meets the top of the button.")
    }

    /// The ⋯ button lives at the far right of the toolbar, which is exactly
    /// where a left-aligned menu would run off the screen.
    func testAnchoredMenuFlipsToTheControlsRightEdgeNearTheRightOfTheScreen() {
        let button = CGRect(x: 1400, y: 700, width: 28, height: 28)
        let frame = CherryMenuGeometry.anchoredFrame(size: small, below: button, in: screen)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertEqual(frame.maxX, button.maxX, accuracy: 0.5, "Right-aligned to the button.")
    }

    // MARK: - Submenus

    func testSubmenuOpensToTheRightWithItsFirstRowLevelWithItsParentRow() {
        let parent = CGRect(x: 300, y: 500, width: 200, height: 300)
        let frame = CherryMenuGeometry.submenuFrame(
            size: small, rowTop: 760, parent: parent, in: screen
        )
        XCTAssertEqual(frame.minX, parent.maxX - CherryMenuGeometry.submenuOverlap)
        XCTAssertEqual(frame.maxY, 760)
    }

    func testSubmenuFlipsToTheLeftWhenThereIsNoRoomOnTheRight() {
        let parent = CGRect(x: 1200, y: 500, width: 200, height: 300)
        let frame = CherryMenuGeometry.submenuFrame(
            size: small, rowTop: 760, parent: parent, in: screen
        )
        XCTAssertLessThan(frame.minX, parent.minX, "Opened on the other side.")
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
    }

    /// Squeezed from both sides there is no good answer, only a usable one:
    /// stay on screen.
    func testSubmenuOnANarrowScreenStaysOnScreen() {
        let narrow = CGRect(x: 0, y: 0, width: 320, height: 875)
        let parent = CGRect(x: 100, y: 500, width: 200, height: 300)
        let frame = CherryMenuGeometry.submenuFrame(
            size: small, rowTop: 760, parent: parent, in: narrow
        )
        XCTAssertGreaterThanOrEqual(frame.minX, narrow.minX)
        XCTAssertLessThanOrEqual(frame.maxX, narrow.maxX)
    }

    /// A submenu opened from a row near the bottom must not hang off it.
    func testSubmenuFromALowRowIsPushedBackOnScreen() {
        let parent = CGRect(x: 300, y: 10, width: 200, height: 120)
        let frame = CherryMenuGeometry.submenuFrame(
            size: small, rowTop: 40, parent: parent, in: screen
        )
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
    }

    // MARK: - A second display

    /// Screens other than the main one have a non-zero origin, and one that can
    /// be negative. Placement has to be relative to the screen it is on, not to
    /// the global origin.
    func testPlacementIsRelativeToTheScreenTheClickIsOn() {
        let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let frame = CherryMenuGeometry.contextFrame(
            size: small, at: CGPoint(x: -1000, y: 260), in: secondary
        )
        XCTAssertGreaterThanOrEqual(frame.minY, secondary.minY)
        XCTAssertTrue(secondary.contains(frame))
    }
}
