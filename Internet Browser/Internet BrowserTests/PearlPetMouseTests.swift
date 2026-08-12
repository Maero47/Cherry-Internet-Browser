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
//  Since she can now be put anywhere on the page rather than slid along its
//  floor, the same tests are run on both axes, and the vertical one has a
//  mistake of its own available: the pointer's y counts UP the window and hers
//  counts DOWN the page, so a drag that forgets the sign moves her the wrong
//  way.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlPetMouseTests: XCTestCase {

    private let page = CGSize(width: 1200, height: 800)
    private let size = PearlPetSize.default

    private func pearl() -> PearlPetView {
        let view = PearlPetView(driver: SilentDriver())
        let host = PearlPetPlacement.hostSize(for: size)
        view.frame = CGRect(x: 500, y: 0, width: host.width, height: host.height)
        view.size = size
        view.contentSize = page
        view.spot = PearlPetSpot(x: 0.5, y: 0.5)
        return view
    }

    private func event(_ type: NSEvent.EventType, at x: CGFloat, _ y: CGFloat = 40) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private var travel: CGSize {
        PearlPetPlacement.travel(in: page, size: size)
    }

    /// A drag reports where she should now be, in the same fractions the
    /// placement model uses, and it tracks the POINTER rather than herself.
    func testDraggingHerMovesHerWithThePointer() {
        let view = pearl()
        var moved: [PearlPetSpot] = []
        view.onMove = { moved.append($0) }

        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseDragged(with: event(.leftMouseDragged, at: 700))
        // What SwiftUI does in response: she is re-placed, and told so.
        view.spot = moved.last ?? view.spot
        view.frame.origin.x += 100
        view.mouseDragged(with: event(.leftMouseDragged, at: 800))

        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(moved[0].x, 0.5 + 100 / travel.width, accuracy: 0.0001)
        XCTAssertEqual(
            moved[1].x, 0.5 + 200 / travel.width, accuracy: 0.0001,
            "the second half of the drag was measured against a moving view"
        )
    }

    /// The same, upwards — and up the WINDOW has to mean up the PAGE, which is
    /// the opposite sign.
    ///
    /// Dies on the vertical term in `PearlPetPlacement.spot(draggedFrom:…)`
    /// losing its minus, and on the drag reading only `locationInWindow.x`.
    func testDraggingHerUpTheWindowMovesHerUpThePage() throws {
        let view = pearl()
        var moved: [PearlPetSpot] = []
        view.onMove = { moved.append($0) }

        view.mouseDown(with: event(.leftMouseDown, at: 600, 400))
        view.mouseDragged(with: event(.leftMouseDragged, at: 600, 500))

        let spot = try XCTUnwrap(moved.first, "a vertical drag moved her not at all")
        XCTAssertEqual(spot.y, 0.5 - 100 / travel.height, accuracy: 0.0001)
        XCTAssertLessThan(spot.y, 0.5, "dragging her up the window moved her down the page")
        XCTAssertEqual(spot.x, 0.5, accuracy: 0.0001, "a vertical drag moved her sideways")
    }

    /// A twitch is not a drag, in any direction.
    func testATwitchIsNotADrag() {
        for (x, y) in [(601.0, 40.0), (600.0, 41.0), (601.0, 41.0)] {
            let view = pearl()
            var moves = 0
            view.onMove = { _ in moves += 1 }

            view.mouseDown(with: event(.leftMouseDown, at: 600))
            view.mouseDragged(with: event(.leftMouseDragged, at: x, y))
            XCTAssertEqual(moves, 0, "a one-pixel wobble to \(x),\(y) moved her")
        }
    }

    /// A drag cannot push her off the page however far the pointer goes.
    func testADragCannotPushHerOffThePage() {
        let view = pearl()
        var moved: [PearlPetSpot] = []
        view.onMove = { moved.append($0) }

        view.mouseDown(with: event(.leftMouseDown, at: 600))
        view.mouseDragged(with: event(.leftMouseDragged, at: 9000, 9000))
        view.mouseDragged(with: event(.leftMouseDragged, at: -9000, -9000))
        XCTAssertEqual(moved.first, PearlPetSpot(x: 1, y: 0))
        XCTAssertEqual(moved.last, PearlPetSpot(x: 0, y: 1))
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

    /// A drag that starts on her is hers from start to finish: AppKit delivers
    /// every event of it to the view that took the `mouseDown`, so the page
    /// never sees one and cannot start selecting text under her.
    ///
    /// Dies on her `mouseDown` returning without claiming the drag (an early
    /// return, a `super` call that lets the event travel on), which is what
    /// would let the page get the rest of the gesture.
    func testTheDragNeverReachesThePage() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let page = MouseSpyPage(frame: container.bounds)
        container.addSubview(page)

        let view = pearl()
        container.addSubview(view)
        let onHer = container.convert(
            CGPoint(x: view.spriteRect.midX, y: view.spriteRect.minY + view.spriteRect.height * 0.3),
            from: view
        )
        XCTAssertIdentical(container.hitTest(onHer), view, "precondition: the press lands on her")

        view.mouseDown(with: event(.leftMouseDown, at: onHer.x, onHer.y))
        view.mouseDragged(with: event(.leftMouseDragged, at: onHer.x + 120, onHer.y + 60))
        view.mouseUp(with: event(.leftMouseUp, at: onHer.x + 120, onHer.y + 60))

        XCTAssertEqual(page.presses, 0, "the page was pressed while she was being carried")
        XCTAssertEqual(page.drags, 0, "the page was dragged through — that is a text selection")
    }
}

/// A page that records being pressed or dragged.
private final class MouseSpyPage: NSView {
    var presses = 0
    var drags = 0
    override func mouseDown(with event: NSEvent) { presses += 1 }
    override func mouseDragged(with event: NSEvent) { drags += 1 }
}
