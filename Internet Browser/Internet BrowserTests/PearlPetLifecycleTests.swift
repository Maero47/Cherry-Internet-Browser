//
//  PearlPetLifecycleTests.swift
//  Internet BrowserTests
//
//  "Nothing may run when she is off, and nothing may keep running when a
//  window closes."
//
//  This project has already been bitten by a timer outliving its view — twice,
//  in the theme clock and in the runner — so the pet's tick is held to the
//  same standard as the runner's: it can be started, stopped, and PROVEN
//  stopped, and the proof is here rather than in a comment.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlPetLifecycleTests: XCTestCase {

    private func pearl(driver: SilentDriver, reduceMotion: Bool = false) -> PearlPetView {
        let view = PearlPetView(driver: driver)
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        view.reduceMotion = reduceMotion
        return view
    }

    /// A Pearl that has never been in a window has never ticked. Building the
    /// view is not the thing that starts her.
    func testSheDoesNotTickBeforeSheIsInAWindow() {
        let driver = SilentDriver()
        let view = pearl(driver: driver)
        XCTAssertFalse(view.isTicking)
        XCTAssertEqual(driver.starts, 0)
    }

    /// In a window she ticks; out of it she does not. This is the window-close
    /// case: SwiftUI takes the overlay out of the tree, AppKit takes the view
    /// out of the window, and the tick stops on the way out.
    func testLeavingTheWindowStopsHer() {
        let driver = SilentDriver()
        let view = pearl(driver: driver)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isTicking, "she joined a window and did not start")

        view.removeFromSuperview()
        XCTAssertFalse(view.isTicking, "her tick survived leaving the window")
        XCTAssertFalse(driver.isRunning)
    }

    /// Closing the window is the same door, and it is the one the requirement
    /// is actually about.
    func testClosingTheWindowStopsHer() {
        let driver = SilentDriver()
        let view = pearl(driver: driver)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isTicking)

        window.contentView = NSView()   // what closing a window does to its content
        XCTAssertFalse(view.isTicking, "her tick survived the window's content going away")
    }

    /// The real production driver, held to the same promise the runner's is:
    /// `stop()` invalidates, and a dropped driver invalidates in `deinit`.
    func testTheRealDriverStopsAndDoesNotOutliveItsOwner() {
        var fires = 0
        var driver: PearlFrameTimerDriver? = PearlFrameTimerDriver(interval: 0.01)
        driver?.start { fires += 1 }
        XCTAssertTrue(driver?.isRunning == true)
        driver?.stop()
        XCTAssertFalse(driver?.isRunning == true)

        driver = PearlFrameTimerDriver(interval: 0.01)
        driver?.start { fires += 1 }
        driver = nil
        let before = fires
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fires, before, "a dropped driver's timer is still firing")
    }

    // MARK: - Reduce Motion

    /// "She stops moving, she does not disappear." Under Reduce Motion there
    /// is no tick at all — not a tick that draws the same frame, no tick — and
    /// she is still there, sitting.
    func testReduceMotionStopsTheTickButNotHer() {
        let driver = SilentDriver()
        let view = pearl(driver: driver, reduceMotion: true)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)

        XCTAssertFalse(view.isTicking, "she is animating under Reduce Motion")
        XCTAssertEqual(view.currentAppearance?.pose, .sitting, "she vanished instead of sitting still")
        XCTAssertEqual(view.currentAppearance?.frame, 0)
    }

    /// A fish is something the user asked for, so it still happens — and the
    /// tick that carries it stops itself the moment the meal is over.
    func testUnderReduceMotionAFishStillHappensAndThenStops() {
        var now: TimeInterval = 1000
        let driver = SilentDriver()
        let view = PearlPetView(driver: driver, clock: { now })
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        view.reduceMotion = true
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)
        XCTAssertFalse(view.isTicking)

        view.feed()
        XCTAssertEqual(view.currentAppearance?.pose, .eating, "the fish did nothing at all")
        XCTAssertTrue(view.isTicking, "nothing is carrying the meal to its end")

        now += PearlPetMood.mealDuration + 0.1
        driver.fire()
        XCTAssertFalse(view.isTicking, "the meal ended and the tick kept running")
        XCTAssertEqual(view.currentAppearance?.pose, .sitting)
    }

    /// Switched off mid-reaction, she leaves with the reaction. (The switch
    /// removes the whole overlay; this is the same door, taken by hand.)
    func testTakenAwayMidReactionNothingIsLeftRunning() {
        let driver = SilentDriver()
        let view = pearl(driver: driver)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)
        view.pet()
        XCTAssertTrue(view.isTicking)

        view.removeFromSuperview()
        XCTAssertFalse(view.isTicking)
        XCTAssertFalse(driver.isRunning)
    }
}
