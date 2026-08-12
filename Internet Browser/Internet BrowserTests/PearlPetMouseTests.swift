//
//  PearlPetMouseTests.swift
//  Internet BrowserTests
//
//  Picking her up, putting her down, and the difference between a click and a
//  drag.
//
//  The events here are handed to the view directly rather than posted: the
//  test host cannot drive a real pointer (it never becomes the active
//  application), so "the user dragged her" is expressed as the three calls
//  AppKit would make. What is being checked is the arithmetic between them,
//  which is where the interesting mistake lives — a drag measured in the
//  view's OWN coordinates stops dead after two pixels, because the view is
//  being re-placed under the pointer as it moves.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlPetMouseTests: XCTestCase {

    private let page = CGSize(width: 1200, height: 800)

    private func pearl() -> PearlPetView {
        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(x: 500, y: 0, width: 56, height: 86)
        view.contentSize = page
        view.position = 0.5
        return view
    }

    private func event(_ type: NSEvent.EventType, at x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: CGPoint(x: x, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private var travel: CGFloat {
        PearlPetPlacement.travel(
            in: page,
            spriteSize: CGSize(width: PearlSpriteContract.petStanding.width,
                               height: PearlSpriteContract.petStanding.height)
        )
    }

    /// A drag reports where she should now be, in the same fraction the
    /// placement model uses, and it tracks the POINTER rather than herself.
    func testDraggingHerMovesHerWithThePointer() {
        let view = pearl()
        var moved: [CGFloat] = []
        view.onMove = { moved.append($0) }

        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseDragged(with: event(.leftMouseDragged, at: 700))
        // What SwiftUI does in response: she is re-placed, and told so.
        view.position = moved.last ?? 0.5
        view.frame.origin.x += 100
        view.mouseDragged(with: event(.leftMouseDragged, at: 800))

        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(moved[0], 0.5 + 100 / travel, accuracy: 0.0001)
        XCTAssertEqual(
            moved[1], 0.5 + 200 / travel, accuracy: 0.0001,
            "the second half of the drag was measured against a moving view"
        )
    }

    /// A twitch is not a drag.
    func testATwitchIsNotADrag() {
        let view = pearl()
        var moves = 0
        view.onMove = { _ in moves += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseDragged(with: event(.leftMouseDragged, at: 601))
        XCTAssertEqual(moves, 0, "a one-pixel wobble moved her")
    }

    /// A drag cannot push her off the page however far the pointer goes.
    func testADragCannotPushHerOffThePage() {
        let view = pearl()
        var moved: [CGFloat] = []
        view.onMove = { moved.append($0) }

        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseDragged(with: event(.leftMouseDragged, at: 9000))
        view.mouseDragged(with: event(.leftMouseDragged, at: -9000))
        XCTAssertEqual(moved.first, 1)
        XCTAssertEqual(moved.last, 0)
    }

    /// Clicking her is petting her.
    func testAClickPetsHer() {
        let view = pearl()
        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseUp(with: event(.leftMouseUp, at: 600))
        XCTAssertEqual(view.currentAppearance?.pose, .delighted)
    }

    /// Putting her down at the end of a drag is not.
    func testPuttingHerDownAfterADragIsNotAClick() {
        let view = pearl()
        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseDragged(with: event(.leftMouseDragged, at: 700))
        view.mouseUp(with: event(.leftMouseUp, at: 700))
        XCTAssertNotEqual(
            view.currentAppearance?.pose, .delighted,
            "moving her out of the way also petted her"
        )
    }

    /// She is not a window-dragging background — picking her up moves the cat,
    /// not the window.
    func testSheIsNotATitleBar() {
        XCTAssertFalse(pearl().mouseDownCanMoveWindow)
    }
}
