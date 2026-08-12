//
//  PearlPetHitTestTests.swift
//  Internet BrowserTests
//
//  The promise this whole feature stands or falls on: **Pearl never steals a
//  click from the page.**
//
//  The setup below is the real one, in miniature — a container with a
//  stand-in for the web view filling it and Pearl on top — and every
//  assertion goes through `NSView.hitTest`, the same call AppKit makes for
//  every mouse and scroll event. A point that lands on a pixel she drew must
//  come back as Pearl; every other point in the window, including the
//  transparent corners of her own frame and the whole heart headroom above
//  her, must come back as the page.
//
//  Screenshot verification is banned in this repo, so this file is the only
//  thing standing between a refactor and a cat that eats clicks.
//

import AppKit
import XCTest
@testable import Cherry

/// Stands in for the `WKWebView` under her: a plain opaque view that claims
/// every point inside itself, exactly as the page does.
private final class PageStandIn: NSView {}

@MainActor
final class PearlPetHitTestTests: XCTestCase {

    private var container: NSView!
    private var page: PageStandIn!
    private var pearl: PearlPetView!

    override func setUp() {
        super.setUp()
        container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        page = PageStandIn(frame: container.bounds)
        container.addSubview(page)

        pearl = PearlPetView(driver: SilentDriver())
        let host = PearlPetPlacement.hostFrame(
            in: container.bounds.size,
            spriteSize: CGSize(width: PearlSpriteContract.petStanding.width,
                               height: PearlSpriteContract.petStanding.height),
            position: 0.5
        )
        // `hostFrame` counts y downwards, the way SwiftUI places things; an
        // unflipped `NSView` counts up. Same rectangle, other way up.
        pearl.frame = CGRect(
            x: host.minX,
            y: container.bounds.height - host.maxY,
            width: host.width,
            height: host.height
        )
        container.addSubview(pearl)
    }

    override func tearDown() {
        pearl = nil
        page = nil
        container = nil
        super.tearDown()
    }

    /// The precondition everything else rests on: the artwork is really
    /// loaded. Without it `isOnPearl` answers `false` everywhere and the
    /// pass-through tests would pass for the wrong reason.
    func testTheArtworkIsLoadedSoTheseTestsMeanSomething() throws {
        XCTAssertTrue(PearlSpriteLibrary.shared.hasArtwork)
        let appearance = try XCTUnwrap(pearl.currentAppearance)
        XCTAssertNotNil(PearlSpriteLibrary.shared.slice(appearance.pose.frameName, frame: appearance.frame))
    }

    /// Somewhere solid on her: the middle of her body.
    func testAClickOnHerOwnPixelsReachesHer() {
        let sprite = pearl.spriteRect
        let onHer = CGPoint(x: sprite.midX, y: sprite.minY + sprite.height * 0.3)
        XCTAssertTrue(pearl.isOnPearl(onHer), "the middle of her body is not Pearl")
        XCTAssertIdentical(container.hitTest(container.convert(onHer, from: pearl)), pearl)
    }

    /// The corners of her frame are page, not cat — this is the click that
    /// follows the link she is standing next to.
    func testTheCornersOfHerFrameAreThePage() {
        let sprite = pearl.spriteRect
        for corner in [
            CGPoint(x: sprite.minX + 0.5, y: sprite.maxY - 0.5),
            CGPoint(x: sprite.maxX - 0.5, y: sprite.maxY - 0.5),
        ] {
            XCTAssertFalse(pearl.isOnPearl(corner), "\(corner) is a transparent corner")
            XCTAssertIdentical(
                container.hitTest(container.convert(corner, from: pearl)), page,
                "a click in her transparent corner did not reach the page"
            )
        }
    }

    /// The room above her that the hearts fly through is not hers either.
    func testTheHeartHeadroomIsThePage() {
        let headroom = CGPoint(x: pearl.bounds.midX, y: pearl.bounds.maxY - 4)
        XCTAssertFalse(pearl.isOnPearl(headroom))
        XCTAssertIdentical(container.hitTest(container.convert(headroom, from: pearl)), page)
    }

    /// The whole rest of the window never even reaches her: AppKit rejects it
    /// on her frame. This is the case that covers 99% of a page.
    func testEverywhereElseOnThePageIsThePage() {
        for point in [
            CGPoint(x: 20, y: 20),
            CGPoint(x: 450, y: 300),
            CGPoint(x: 880, y: 580),
            CGPoint(x: 450, y: 598),
        ] {
            XCTAssertIdentical(container.hitTest(point), page, "\(point) did not reach the page")
        }
    }

    /// A sweep of her whole frame: every point that is not one of her pixels
    /// goes to the page, and a decent share of points ARE hers — a sprite that
    /// silently stopped loading would make the first claim trivially true.
    func testEveryTransparentPointInHerFramePassesThrough() {
        var hers = 0, pages = 0
        let bounds = pearl.bounds
        for x in stride(from: 0.5, to: bounds.width, by: 1) {
            for y in stride(from: 0.5, to: bounds.height, by: 1) {
                let point = CGPoint(x: x, y: y)
                let inContainer = container.convert(point, from: pearl)
                if pearl.isOnPearl(point) {
                    hers += 1
                    XCTAssertIdentical(container.hitTest(inContainer), pearl)
                } else {
                    pages += 1
                    XCTAssertIdentical(container.hitTest(inContainer), page)
                }
            }
        }
        XCTAssertGreaterThan(hers, 400, "almost none of her frame is Pearl — is the sprite loading?")
        XCTAssertGreaterThan(pages, hers, "she is not a rectangle; most of her frame is page")
        print("HIT TEST her pixels=\(hers) page pixels inside her frame=\(pages)")
    }

    /// Hidden, she is not there at all.
    func testAHiddenPearlIsNotHitTestableAnywhere() {
        pearl.isHidden = true
        let sprite = pearl.spriteRect
        let onHer = container.convert(CGPoint(x: sprite.midX, y: sprite.minY + 4), from: pearl)
        XCTAssertNil(pearl.hitTest(onHer))
    }

    /// With no artwork there is nothing drawn, so there is nothing to click —
    /// and every click is the page's. The tempting fallback ("treat the whole
    /// rectangle as Pearl") is the exact failure this feature must not have.
    func testWithNoArtworkEveryClickIsThePages() {
        let artless = PearlPetView(
            sprites: PearlSpriteLibrary(bundle: Bundle(for: PageStandIn.self)),
            driver: SilentDriver()
        )
        artless.frame = pearl.frame
        XCTAssertFalse(artless.isOnPearl(CGPoint(x: artless.spriteRect.midX, y: 4)))
    }
}

/// A driver that never fires, so a test can hold a live view without a timer.
@MainActor
final class SilentDriver: PearlFrameDriving {
    private(set) var isRunning = false
    private(set) var starts = 0
    private var tick: (() -> Void)?

    func start(_ tick: @escaping () -> Void) {
        self.tick = tick
        isRunning = true
        starts += 1
    }

    func stop() {
        tick = nil
        isRunning = false
    }

    /// Runs one tick by hand.
    func fire() {
        tick?()
    }
}
