//
//  PearlPetCostTests.swift
//  Internet BrowserTests
//
//  What Pearl costs, measured.
//
//  "A pet that costs frames on every page is a pet people switch off", and the
//  standard this is held to is the one the contrast guard's live-resize round
//  set: 605ms/frame was the defect, 0.08ms/frame was the fix, and the
//  assertions there are two orders of magnitude looser than the fixed path so
//  they fail on a regression and on nothing else. Same shape here.
//
//  There are exactly two ways she can cost anything on a page:
//
//  1. **Idle** — her animation tick. Ten times a second, it asks
//     `PearlPetMood` what pose it is, compares, and usually does nothing. This
//     measures the whole production tick path, including the frames where the
//     picture really does change.
//
//  2. **Scrolling** — hit testing. A scroll event is delivered to the view
//     under the pointer, so AppKit hit-tests the pane for every wheel event
//     the user produces. Pearl is a view in that pane, so she is on that path
//     whether or not the pointer is anywhere near her: that is the cost of
//     scrolling with her switched on, and it is measured here at all three
//     points — over the page, over her transparent frame, and over the cat.
//
//  Nothing else runs. She does not observe the page, the scroll position, the
//  navigation, or the DOM; there is no JavaScript, no `WKWebView` message
//  handler and no notification anywhere in the feature.
//

import AppKit
import XCTest
@testable import Cherry

private final class PageStandInForCost: NSView {}

@MainActor
final class PearlPetCostTests: XCTestCase {

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    // MARK: - Idle

    /// One second of Pearl standing on a page, tick by tick, at the rate she
    /// really runs at — and then the per-tick cost across a full loop of her
    /// day, so the frames where she blinks, grooms and breathes are all in the
    /// average.
    func testIdleTickCost() {
        var now: TimeInterval = 0
        let driver = SilentDriver()
        let view = PearlPetView(driver: driver, clock: { now })
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isTicking, "precondition: she is running")

        let clock = ContinuousClock()
        var poses = Set<PearlPetPose>()
        var tickSeconds: [Double] = []
        let ticks = Int(PearlPetMood.idleLoop / PearlPetMood.tickInterval)
        for _ in 0..<ticks {
            now += PearlPetMood.tickInterval
            tickSeconds.append(Self.seconds(clock.measure { driver.fire() }))
            if let pose = view.currentAppearance?.pose { poses.insert(pose) }
        }

        let total = tickSeconds.reduce(0, +)
        let mean = total / Double(tickSeconds.count)
        let worst = tickSeconds.max() ?? 0
        print(String(
            format: "PEARL IDLE ticks=%d over %.0fs of her day: mean=%.4fms worst=%.4fms "
                + "total main-thread time=%.2fms (%.4f%% of one second)",
            ticks, PearlPetMood.idleLoop, mean * 1000, worst * 1000, total * 1000,
            (total / PearlPetMood.idleLoop) * 100
        ))

        XCTAssertGreaterThan(poses.count, 1, "she never changed pose — this measured a stuck cat")
        XCTAssertLessThan(worst, 0.005, "a tick cost \(worst * 1000)ms; she is doing real work per frame")
        XCTAssertLessThan(
            total / PearlPetMood.idleLoop, 0.001,
            "she is using more than 0.1% of a core standing still"
        )
    }

    // MARK: - Scrolling

    /// Every wheel event on a page with Pearl on it, measured where the
    /// pointer actually is: over the page (the overwhelmingly common case,
    /// which AppKit settles on her frame without calling into her), over the
    /// transparent part of her frame, and over the cat herself.
    func testScrollHitTestCost() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let page = PageStandInForCost(frame: container.bounds)
        container.addSubview(page)

        let view = PearlPetView(driver: SilentDriver())
        let host = PearlPetPlacement.hostFrame(
            in: container.bounds.size,
            spriteSize: CGSize(width: PearlSpriteContract.petStanding.width,
                               height: PearlSpriteContract.petStanding.height),
            position: PearlPetPlacement.defaultPosition
        )
        view.frame = CGRect(x: host.minX, y: container.bounds.height - host.maxY,
                            width: host.width, height: host.height)
        container.addSubview(view)

        let sprite = view.convert(view.spriteRect, to: container)
        let cases: [(String, CGPoint, NSView)] = [
            ("over the page", CGPoint(x: 400, y: 500), page),
            ("over her heart headroom", CGPoint(x: view.frame.midX, y: view.frame.maxY - 4), page),
            ("over her own pixels", CGPoint(x: sprite.midX, y: sprite.minY + sprite.height * 0.3), view),
        ]

        let clock = ContinuousClock()
        let events = 2000
        for (label, point, expected) in cases {
            XCTAssertIdentical(container.hitTest(point), expected, "\(label) went to the wrong view")
            let elapsed = Self.seconds(clock.measure {
                for _ in 0..<events { _ = container.hitTest(point) }
            })
            let per = elapsed / Double(events)
            print(String(
                format: "PEARL SCROLL hit test %@: %.5fms/event (%d events in %.2fms)",
                label, per * 1000, events, elapsed * 1000
            ))
            XCTAssertLessThan(
                per, 0.0005,
                "a wheel event \(label) cost \(per * 1000)ms of hit testing"
            )
        }
    }

    /// The same measurement with her switched off, as the baseline: the pane
    /// without her in it. The difference between this and the case above is
    /// the whole of what she costs a scrolling page.
    func testScrollHitTestCostWithoutHer() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let page = PageStandInForCost(frame: container.bounds)
        container.addSubview(page)

        let clock = ContinuousClock()
        let events = 2000
        let point = CGPoint(x: 400, y: 500)
        let elapsed = Self.seconds(clock.measure {
            for _ in 0..<events { _ = container.hitTest(point) }
        })
        print(String(
            format: "PEARL SCROLL baseline (no pet): %.5fms/event",
            (elapsed / Double(events)) * 1000
        ))
    }

    /// The alpha masks are built once per frame of art and then reused, so the
    /// first hit test on a pose is the only one that touches a bitmap. If that
    /// ever regressed, every wheel event would rasterise a sprite.
    func testTheHitTestDoesNotRasteriseAnything() {
        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        let point = CGPoint(x: view.spriteRect.midX, y: view.spriteRect.minY + 8)

        let clock = ContinuousClock()
        _ = view.isOnPearl(point)   // the one that may build a mask
        let warm = Self.seconds(clock.measure {
            for _ in 0..<10_000 { _ = view.isOnPearl(point) }
        }) / 10_000
        print(String(format: "PEARL pixel lookup: %.6fms", warm * 1000))
        XCTAssertLessThan(warm, 0.0001, "a pixel lookup cost \(warm * 1000)ms — it is not a cached mask")
    }
}
