//
//  PearlPetBehaviourTests.swift
//  Internet BrowserTests
//
//  The three things she learned this round beyond being resizable and
//  movable, each held to the same bar the rest of the feature is: nothing
//  interrupts, nothing needs dismissing, and nothing runs when nothing is
//  happening.
//
//  1. **She dozes when you leave Cherry.** Not a screensaver — the tick stops
//     outright, which is the only honest way to cost nothing in an app nobody
//     is looking at, and it is what these tests actually assert.
//  2. **She notices a finished download.** One integer comparison on a counter
//     the download toast already runs on: no observer, no polling, no second
//     source of truth about downloads.
//  3. **A wheel event that lands on her belongs to the page.** She was always
//     a cat-shaped hole for CLICKS; scrolling used to stop dead on her, which
//     was a small hole at 1x and is nine times the area at 3x.
//

import AppKit
import XCTest
@testable import Cherry

/// A page that records the wheel events handed to it.
private final class ScrollSpyPage: NSView {
    var wheels: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { wheels.append(event) }
}

@MainActor
final class PearlPetBehaviourTests: XCTestCase {

    /// Held for the length of a test: a view whose window has been released is
    /// a view that has quietly left its window.
    private var host: NSWindow!

    override func setUp() {
        super.setUp()
        host = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: true
        )
    }

    override func tearDown() {
        host = nil
        super.tearDown()
    }

    private func pearl(driver: SilentDriver, clock: @escaping () -> TimeInterval) -> PearlPetView {
        let view = PearlPetView(driver: driver, clock: clock)
        view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: .default))
        return view
    }

    // MARK: - Dozing

    /// You switched to another app: she curls up, and — the point of the whole
    /// behaviour — her timer stops. Coming back wakes her and starts it again.
    ///
    /// Dies on `PearlPetMood.isStill` not counting dozing (she would keep
    /// ticking behind another app), on `doze()` not reaching the pose (she
    /// would freeze mid-groom instead of settling), and on `appCameBack` not
    /// disturbing her (she would stay asleep for the rest of the session).
    func testSheDozesWhenYouLeaveCherryAndWakesWhenYouComeBack() {
        var now: TimeInterval = 1000
        let driver = SilentDriver()
        let view = pearl(driver: driver, clock: { now })
        host.contentView?.addSubview(view)
        XCTAssertTrue(view.isTicking, "precondition: she is running")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertFalse(view.isTicking, "she kept animating in an app nobody is looking at")
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(view.currentAppearance?.pose, .sleeping, "she froze rather than settling")

        now += 5
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(view.isTicking, "she never woke up")
        XCTAssertNotEqual(view.currentAppearance?.pose, .sleeping)
    }

    /// Dozing is not the two-minute nap: she goes straight to sleep, and she
    /// is awake again the moment you return however long you were gone.
    func testDozingIsImmediateAndUndoneByComingBack() {
        var mood = PearlPetMood()
        mood.lastDisturbed = 0
        XCTAssertNotEqual(mood.appearance(at: 1).pose, .sleeping, "one second in, she is awake")

        mood.doze()
        XCTAssertEqual(mood.appearance(at: 1).pose, .sleeping)
        XCTAssertTrue(mood.isStill(at: 1, reduceMotion: false), "a dozing cat still has a timer")

        mood.disturb(at: 9_999)
        XCTAssertFalse(mood.isDozing)
        XCTAssertNotEqual(mood.appearance(at: 9_999).pose, .sleeping)
        XCTAssertFalse(mood.isStill(at: 9_999, reduceMotion: false))
    }

    /// A reaction that was in the air when you left still finishes, so leaving
    /// mid-fish is not a fish that never happened.
    func testAReactionSurvivesTheAppLosingFocus() {
        var mood = PearlPetMood()
        mood.feed(at: 100)
        mood.doze()
        XCTAssertEqual(mood.appearance(at: 100.5).pose, .eating)
        XCTAssertFalse(mood.isStill(at: 100.5, reduceMotion: false), "the meal lost its timer")
        XCTAssertTrue(mood.isStill(at: 100 + PearlPetMood.mealDuration, reduceMotion: false))
    }

    /// The observers are the window's, like the tick: out of the window, the
    /// notifications reach nothing. This is the "off means off, no residue"
    /// rule applied to the two things she now listens to.
    ///
    /// Dies on the observers being registered in `init` rather than on the way
    /// into a window, and on `viewDidMoveToWindow` forgetting to remove them.
    func testOutOfAWindowSheIsNotListeningToAnything() {
        var now: TimeInterval = 1000
        let driver = SilentDriver()
        let view = pearl(driver: driver, clock: { now })
        host.contentView?.addSubview(view)
        view.removeFromSuperview()
        XCTAssertFalse(view.isTicking, "precondition: leaving the window stopped her")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(view.isTicking, "a notification restarted a Pearl who is not in a window")
        XCTAssertEqual(driver.starts, 1, "she started again from outside a window")
    }

    // MARK: - Downloads

    /// The first count she is handed is the state of the world when she
    /// arrived, not news — otherwise every new tab in a session with downloads
    /// in it would open with a celebrating cat.
    ///
    /// Dies on `noticedDownloads` starting at zero instead of nil.
    func testTheCountSheArrivesToIsNotNews() {
        var now: TimeInterval = 500
        let view = pearl(driver: SilentDriver(), clock: { now })
        host.contentView?.addSubview(view)

        view.noticeDownloads(7)
        XCTAssertNotEqual(view.currentAppearance?.pose, .delighted, "she celebrated the past")
    }

    /// A download finishing makes her look up, once, and then she goes back to
    /// what she was doing. No hearts: hearts are for affection.
    ///
    /// Dies on the notice being wired to the count's VALUE rather than its
    /// change (she would react on every SwiftUI update), and on it bursting
    /// hearts.
    func testAFinishedDownloadMakesHerLookUpOnce() {
        var now: TimeInterval = 500
        let driver = SilentDriver()
        let view = pearl(driver: driver, clock: { now })
        host.contentView?.addSubview(view)
        view.noticeDownloads(2)
        let layersBefore = view.layer?.sublayers?.count ?? 0

        view.noticeDownloads(3)
        XCTAssertEqual(view.currentAppearance?.pose, .delighted, "she did not notice at all")
        XCTAssertEqual(view.layer?.sublayers?.count ?? 0, layersBefore, "a download threw hearts")

        // The same count again is the same download.
        now += PearlPetMood.noticeDuration + 0.1
        driver.fire()
        XCTAssertNotEqual(view.currentAppearance?.pose, .delighted, "the notice never ended")
        view.noticeDownloads(3)
        XCTAssertNotEqual(
            view.currentAppearance?.pose, .delighted,
            "she reacted again to a download she had already seen"
        )
    }

    /// She wakes for it: a download finishing while she is asleep on a tab you
    /// left open is exactly the moment being noticed is worth anything.
    func testADownloadWakesASleepingPearl() {
        var now: TimeInterval = 500
        let driver = SilentDriver()
        let view = pearl(driver: driver, clock: { now })
        host.contentView?.addSubview(view)
        view.noticeDownloads(0)

        now += PearlPetMood.sleepsAfter + 10
        driver.fire()
        XCTAssertEqual(view.currentAppearance?.pose, .sleeping, "precondition: she is asleep")

        view.noticeDownloads(1)
        XCTAssertEqual(view.currentAppearance?.pose, .delighted)
        XCTAssertTrue(view.isTicking, "nothing is carrying the reaction to its end")
    }

    /// Under Reduce Motion she does not react to a download at all. The fish
    /// still happens because the user asked for it; this is Cherry deciding to
    /// animate at somebody who asked it not to.
    func testUnderReduceMotionADownloadMovesNothing() {
        var now: TimeInterval = 500
        let view = pearl(driver: SilentDriver(), clock: { now })
        view.reduceMotion = true
        host.contentView?.addSubview(view)
        view.noticeDownloads(1)

        view.noticeDownloads(2)
        XCTAssertEqual(view.currentAppearance?.pose, .sitting)
        XCTAssertFalse(view.isTicking, "she started a timer under Reduce Motion")
    }

    // MARK: - Scrolling past her

    /// A wheel event that lands on her own pixels is handed to whatever was
    /// behind her, unmodified. Without this she is a hole in the page's
    /// scrolling.
    ///
    /// Dies on `scrollWheel` being removed, on `pageBehind` looking for a
    /// class name instead of asking the view stack, and on the pass-through
    /// flag not being cleared (which would make her un-clickable afterwards).
    func testScrollingOverHerScrollsThePage() throws {
        // A pane that covers every coordinate a synthesised wheel event could
        // claim to be at: `NSEvent` will not build a scroll event with a
        // location of our choosing (only `CGEvent` will, in screen
        // coordinates), and this test is about what she does with the event
        // rather than about where AppKit thinks the pointer is.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 100_000, height: 100_000))
        let page = ScrollSpyPage(frame: container.bounds)
        container.addSubview(page)

        let view = pearl(driver: SilentDriver(), clock: { 0 })
        container.addSubview(view)
        let sprite = view.convert(view.spriteRect, to: container)
        let onHer = CGPoint(x: sprite.midX, y: sprite.midY)
        XCTAssertIdentical(container.hitTest(onHer), view, "precondition: the wheel lands on her")

        let event = try XCTUnwrap(Self.scrollEvent())
        view.scrollWheel(with: event)

        XCTAssertEqual(page.wheels.count, 1, "the page did not scroll under her")
        XCTAssertIdentical(page.wheels.first, event, "she re-synthesised the event instead of passing it")
        XCTAssertIdentical(
            container.hitTest(onHer), view,
            "she stayed transparent to hit testing after passing an event through"
        )
    }

    /// A wheel event, which only Core Graphics will build.
    static func scrollEvent() -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    /// The pass-through asks the view stack rather than naming a class, so
    /// what is behind her is whatever is really there — and a point that is
    /// nowhere near the pane is nobody's.
    func testWhatIsBehindHerIsWhateverTheViewStackSays() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let page = ScrollSpyPage(frame: container.bounds)
        container.addSubview(page)
        let view = pearl(driver: SilentDriver(), clock: { 0 })
        container.addSubview(view)

        let sprite = view.convert(view.spriteRect, to: container)
        XCTAssertIdentical(
            view.pageBehind(at: CGPoint(x: sprite.midX, y: sprite.midY)), page,
            "the page under her own pixels is not what she would hand a wheel event to"
        )
        XCTAssertIdentical(view.pageBehind(at: CGPoint(x: 40, y: 40)), page)
        XCTAssertNil(
            view.pageBehind(at: CGPoint(x: -50, y: -50)),
            "a point outside the pane found something to scroll"
        )
    }
}
