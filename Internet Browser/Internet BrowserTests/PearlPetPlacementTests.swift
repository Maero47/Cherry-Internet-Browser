//
//  PearlPetPlacementTests.swift
//  Internet BrowserTests
//
//  "The user puts her where they want and she stays there — and she can never
//  end up lost."
//
//  She used to be confined to the floor, and the test that said so
//  (`testSheCanNeverBeInTheMiddleOfThePage`) was the guarantee that she could
//  not stand in front of what you were reading. The owner asked for the other
//  thing, so that guarantee is gone on purpose and these are what replaced it:
//  her default is still the old corner, every spot she can be dragged to is
//  inside the page, there is a row on her menu that puts her back, and a spot
//  saved in one window lands somewhere legal in every other — including one
//  that is now much smaller, which is the case a stored position gets wrong.
//

import XCTest
@testable import Cherry

@MainActor
final class PearlPetPlacementTests: XCTestCase {

    private let page = CGSize(width: 1200, height: 800)
    private let size = PearlPetSize.default

    private var sprite: CGSize { PearlPetPlacement.spriteSize(for: size) }

    private func frame(
        at spot: PearlPetSpot,
        in content: CGSize? = nil,
        size: PearlPetSize? = nil
    ) -> CGRect {
        PearlPetPlacement.spriteFrame(
            in: content ?? page, size: size ?? self.size, spot: spot
        )
    }

    // MARK: - Inside the page, wherever she is

    /// Every spot in the unit square, and every spot outside it, produces a
    /// rectangle wholly inside the page with its insets respected.
    func testSheIsAlwaysInsideThePage() {
        for x in stride(from: -1.0, through: 2.0, by: 0.1) {
            for y in stride(from: -1.0, through: 2.0, by: 0.1) {
                let rect = frame(at: PearlPetSpot(x: x, y: y))
                XCTAssertGreaterThanOrEqual(
                    rect.minX, PearlPetPlacement.sideInset - 0.001, "off the left at \(x)"
                )
                XCTAssertLessThanOrEqual(
                    rect.maxX, page.width - PearlPetPlacement.sideInset + 0.001,
                    "off the right at \(x)"
                )
                XCTAssertGreaterThanOrEqual(rect.minY, 0, "off the top at \(y)")
                XCTAssertLessThanOrEqual(
                    rect.maxY, page.height - PearlPetPlacement.floorInset + 0.001,
                    "through the floor at \(y)"
                )
            }
        }
    }

    /// The bottom of her travel is the floor she always stood on, to the
    /// point: `y: 1` is the old behaviour, unchanged.
    func testTheBottomOfHerTravelIsTheOldFloor() {
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            let rect = frame(at: PearlPetSpot(x: x, y: 1))
            XCTAssertEqual(
                rect.maxY, page.height - PearlPetPlacement.floorInset, accuracy: 0.001,
                "she left the floor at \(x)"
            )
        }
    }

    /// The top of her travel stops a heart-headroom short of the top edge, so
    /// her reaction still fits on the page. Anything higher is the setup
    /// wizard's old bug: a burst that is painted and never seen.
    func testTheTopOfHerTravelLeavesRoomForHerHearts() {
        for size in PearlPetSize.allCases {
            let rect = frame(at: PearlPetSpot(x: 0.5, y: 0), size: size)
            XCTAssertEqual(
                rect.minY, PearlPetPlacement.heartHeadroom(for: size), accuracy: 0.001,
                "\(size) can stand where her hearts would fly off the page"
            )
        }
    }

    /// The four corners of her freedom are four different places — "put her
    /// where you want" is a lie if the vertical axis does nothing.
    func testTheFourCornersOfHerTravelAreFourPlaces() {
        let topLeft = frame(at: PearlPetSpot(x: 0, y: 0))
        let bottomRight = frame(at: PearlPetSpot(x: 1, y: 1))
        XCTAssertLessThan(topLeft.midX, page.width * 0.1)
        XCTAssertGreaterThan(bottomRight.midX, page.width * 0.9)
        XCTAssertLessThan(topLeft.midY, page.height * 0.25)
        XCTAssertGreaterThan(bottomRight.midY, page.height * 0.75)
    }

    // MARK: - Home

    /// She starts in her corner: out of the way of the left-hand column most
    /// pages put their body text in, and on the floor.
    func testHerDefaultSpotIsTheOldCorner() {
        let rect = frame(at: .home)
        XCTAssertGreaterThan(rect.midX, page.width * 0.75, "she no longer starts out of the way")
        XCTAssertEqual(rect.maxY, page.height - PearlPetPlacement.floorInset, accuracy: 0.001)
        XCTAssertTrue(PearlPetSpot.home.isHome)
    }

    /// The way back exists and knows when it is needed.
    func testAnywhereElseIsNotHome() {
        XCTAssertFalse(PearlPetSpot(x: 0.2, y: 0.2).isHome)
        XCTAssertFalse(PearlPetSpot(x: PearlPetSpot.home.x, y: 0.3).isHome, "the same column is not home")
        XCTAssertFalse(PearlPetSpot(x: 0.3, y: PearlPetSpot.home.y).isHome, "the same row is not home")
        XCTAssertTrue(
            PearlPetSpot(x: PearlPetSpot.home.x + 0.005, y: PearlPetSpot.home.y).isHome,
            "half a per cent of travel away is home enough to disable the row"
        )
    }

    // MARK: - Nonsense in, a legal cat out

    func testACorruptSpotCannotPutHerOffThePage() {
        for nonsense in [CGFloat.nan, .infinity, -.infinity, -99, 1e9] {
            let rect = frame(at: PearlPetSpot(x: nonsense, y: nonsense))
            XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite, "\(nonsense) produced \(rect)")
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, page.width)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxY, page.height)
        }
        // NaN has no nearest legal value, so it is replaced rather than clamped.
        XCTAssertEqual(PearlPetSpot(x: .nan, y: .nan).clamped(), .home)
    }

    /// A window narrower and shorter than she is does not produce a negative
    /// rectangle. (`shouldShow` refuses one this small anyway; this is the
    /// second lock.)
    func testATinyPageStillProducesASaneRectangle() {
        let tiny = CGSize(width: 20, height: 20)
        let rect = frame(at: PearlPetSpot(x: 0.5, y: 0.5), in: tiny)
        XCTAssertEqual(rect.width, sprite.width)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertEqual(PearlPetPlacement.travel(in: tiny, size: size), .zero)
    }

    // MARK: - The view around her

    /// Her hosting view is her sprite plus heart room, and it never hangs over
    /// the edges of the page — at any size, anywhere she can be put.
    func testHerHostingViewNeverHangsOverTheEdgeOfThePage() {
        for size in PearlPetSize.allCases {
            for x in stride(from: 0.0, through: 1.0, by: 0.05) {
                for y in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let host = PearlPetPlacement.hostFrame(
                        in: page, size: size, spot: PearlPetSpot(x: x, y: y)
                    )
                    XCTAssertGreaterThanOrEqual(host.minX, -0.001, "\(size) overhangs the left at \(x)")
                    XCTAssertLessThanOrEqual(
                        host.maxX, page.width + 0.001, "\(size) overhangs the right at \(x)"
                    )
                    XCTAssertGreaterThanOrEqual(host.minY, -0.001, "\(size) overhangs the top at \(y)")
                    XCTAssertLessThanOrEqual(host.maxY, page.height, "\(size) overhangs the bottom at \(y)")
                }
            }
        }
    }

    func testHerHostingViewIsMostlyHeadroom() {
        let host = PearlPetPlacement.hostFrame(in: page, size: size, spot: PearlPetSpot(x: 0.5, y: 1))
        let sprite = frame(at: PearlPetSpot(x: 0.5, y: 1))
        XCTAssertTrue(host.contains(sprite))
        XCTAssertEqual(host.maxY, sprite.maxY, accuracy: 0.001, "the room is above her, not below")
        XCTAssertEqual(
            host.height - sprite.height,
            PearlPetPlacement.heartHeadroom(for: size), accuracy: 0.001
        )
    }

    /// A view that covered the page would be asked to hit-test every click on
    /// it. Hers covers a few per cent of it, even at her largest.
    func testHerHostingViewIsATinyPartOfThePage() {
        for size in PearlPetSize.allCases {
            let host = PearlPetPlacement.hostFrame(in: page, size: size, spot: .home)
            let share = (host.width * host.height) / (page.width * page.height)
            XCTAssertLessThan(share, 0.06, "\(size) covers \(share * 100)% of the page")
            print(String(format: "PET FRAME %@ %.0fx%.0f = %.2f%% of a 1200x800 page",
                         size.title, host.width, host.height, share * 100))
        }
    }

    // MARK: - Dragging

    /// A drag of the full travel moves her from one end to the other, and no
    /// further — on both axes, with the vertical one the right way up.
    func testADragIsMeasuredInHerOwnTravel() {
        let travel = PearlPetPlacement.travel(in: page, size: size)
        XCTAssertEqual(travel.width, page.width - sprite.width - 2 * PearlPetPlacement.sideInset)
        XCTAssertEqual(
            travel.height,
            page.height - sprite.height - PearlPetPlacement.floorInset
                - PearlPetPlacement.heartHeadroom(for: size)
        )

        func dragged(_ delta: CGSize, from start: PearlPetSpot = PearlPetSpot(x: 0.5, y: 0.5)) -> PearlPetSpot {
            PearlPetPlacement.spot(draggedFrom: start, by: delta, in: page, size: size)
        }

        XCTAssertEqual(dragged(CGSize(width: travel.width / 2, height: 0)).x, 1, accuracy: 0.0001)
        XCTAssertEqual(dragged(CGSize(width: -travel.width / 2, height: 0)).x, 0, accuracy: 0.0001)
        // The pointer's y counts up the window; hers counts down the page.
        XCTAssertEqual(
            dragged(CGSize(width: 0, height: travel.height / 2)).y, 0, accuracy: 0.0001,
            "dragging her up the window did not move her up the page"
        )
        XCTAssertEqual(dragged(CGSize(width: 0, height: -travel.height / 2)).y, 1, accuracy: 0.0001)
        XCTAssertEqual(dragged(CGSize(width: 9000, height: 9000)), PearlPetSpot(x: 1, y: 0))
        XCTAssertEqual(dragged(CGSize(width: -9000, height: -9000)), PearlPetSpot(x: 0, y: 1))
    }

    /// An axis with no travel does not divide by zero and does not move her.
    func testADragInAWindowWithNoRoomLeavesHerWhereSheIs() {
        let start = PearlPetSpot(x: 0.4, y: 0.6)
        let moved = PearlPetPlacement.spot(
            draggedFrom: start, by: CGSize(width: 200, height: 200),
            in: CGSize(width: 20, height: 20), size: size
        )
        XCTAssertEqual(moved, start)
    }

    // MARK: - Where she was left

    func testWhereSheWasLeftSurvivesAndCannotCorrupt() throws {
        let suiteName = ThrowawayDefaults.name("pearl-pet-home")
        let defaults = try XCTUnwrap(ThrowawayDefaults.make(suiteName))
        defer { ThrowawayDefaults.destroy(defaults, named: suiteName) }

        let home = PearlPetHome(defaults: defaults)
        XCTAssertEqual(home.spot, .home, "no key must mean her corner")
        XCTAssertEqual(home.size, .default, "no key must mean her default size")

        home.spot = PearlPetSpot(x: 0.25, y: 0.4)
        home.size = .large
        XCTAssertEqual(PearlPetHome(defaults: defaults).spot, PearlPetSpot(x: 0.25, y: 0.4))
        XCTAssertEqual(PearlPetHome(defaults: defaults).size, .large)

        // Whatever else ends up under those keys, she still stands somewhere
        // legal at a size this code can draw.
        defaults.set(-42.0, forKey: PearlPetHome.xKey)
        defaults.set(42.0, forKey: PearlPetHome.yKey)
        XCTAssertEqual(home.spot, PearlPetSpot(x: 0, y: 1))
        defaults.set("a cat", forKey: PearlPetHome.xKey)
        defaults.set("a cat", forKey: PearlPetHome.yKey)
        XCTAssertTrue((0...1).contains(home.spot.x), "a string preference put her at \(home.spot)")
        XCTAssertTrue((0...1).contains(home.spot.y), "a string preference put her at \(home.spot)")
        defaults.set(9, forKey: PearlPetHome.sizeKey)
        XCTAssertEqual(home.size, .default, "a size Cherry cannot draw was honoured")
    }

    /// The case a stored position gets wrong: she was left in the far corner
    /// of a big window, and the window she comes back to is much smaller.
    ///
    /// Dies on the spot being stored in points, on the travel being cached
    /// rather than recomputed from the window she is in, and on any of the
    /// clamps being dropped.
    func testASpotSavedInABigWindowLandsInsideASmallOne() throws {
        let suiteName = ThrowawayDefaults.name("pearl-pet-relaunch")
        let defaults = try XCTUnwrap(ThrowawayDefaults.make(suiteName))
        defer { ThrowawayDefaults.destroy(defaults, named: suiteName) }

        let big = CGSize(width: 2560, height: 1440)
        let home = PearlPetHome(defaults: defaults)

        // Parked in the far bottom-right corner of a big screen, and left there.
        let parked = PearlPetPlacement.spot(
            draggedFrom: .home, by: CGSize(width: 4000, height: -4000), in: big, size: .large
        )
        home.spot = parked
        home.size = .large
        XCTAssertEqual(parked, PearlPetSpot(x: 1, y: 1))

        // Relaunched onto a laptop, in a window a fifth of the area.
        for small in [CGSize(width: 900, height: 600), CGSize(width: 700, height: 420),
                      CGSize(width: 480, height: 300)] {
            let restored = PearlPetHome(defaults: defaults)
            let rect = PearlPetPlacement.spriteFrame(
                in: small, size: restored.size, spot: restored.spot
            )
            XCTAssertGreaterThanOrEqual(rect.minX, 0, "off the left of a \(small) window")
            XCTAssertLessThanOrEqual(rect.maxX, small.width, "off the right of a \(small) window")
            XCTAssertGreaterThanOrEqual(rect.minY, 0, "above the top of a \(small) window")
            XCTAssertLessThanOrEqual(rect.maxY, small.height, "below the bottom of a \(small) window")

            let host = PearlPetPlacement.hostFrame(
                in: small, size: restored.size, spot: restored.spot
            )
            XCTAssertLessThanOrEqual(host.maxX, small.width + 0.001)
            XCTAssertLessThanOrEqual(host.maxY, small.height + 0.001)
        }
    }

    /// And the same window, resized around her live rather than relaunched:
    /// she stays inside it the whole way down.
    func testShrinkingTheWindowNeverLeavesHerOutsideIt() {
        let spot = PearlPetSpot(x: 1, y: 0)
        for width in stride(from: 2000.0, through: 300.0, by: -50) {
            for height in stride(from: 1200.0, through: 200.0, by: -100) {
                let content = CGSize(width: width, height: height)
                let rect = PearlPetPlacement.spriteFrame(in: content, size: .large, spot: spot)
                XCTAssertGreaterThanOrEqual(rect.minY, 0, "above the top of \(content)")
                XCTAssertLessThanOrEqual(rect.maxY, height, "below the bottom of \(content)")
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "off the left of \(content)")
                XCTAssertLessThanOrEqual(rect.maxX, width, "off the right of \(content)")
            }
        }
    }
}
