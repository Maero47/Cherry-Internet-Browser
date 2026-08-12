//
//  PearlPetPlacementTests.swift
//  Internet BrowserTests
//
//  "She must never cover what the user is reading."
//
//  The design answer is that the middle of the page is not a position she can
//  occupy: she stands on the floor of the content area and the only freedom
//  she or the user has is left and right along it. These tests hold that shape
//  — including at the extremes, in tiny windows, and against a corrupt
//  preference — because the moment she can be somewhere else, "she is never in
//  the way" stops being true by construction and becomes something somebody
//  has to remember.
//

import XCTest
@testable import Cherry

@MainActor
final class PearlPetPlacementTests: XCTestCase {

    private let sprite = CGSize(
        width: PearlSpriteContract.petStanding.width,
        height: PearlSpriteContract.petStanding.height
    )
    private let page = CGSize(width: 1200, height: 800)

    private func frame(at position: CGFloat, in size: CGSize? = nil) -> CGRect {
        PearlPetPlacement.spriteFrame(
            in: size ?? page, spriteSize: sprite, position: position
        )
    }

    // MARK: - The floor

    /// Wherever she is, her feet are on the bottom edge of the page.
    func testSheIsAlwaysOnTheFloor() {
        for position in stride(from: -1.0, through: 2.0, by: 0.1) {
            let rect = frame(at: position)
            XCTAssertEqual(
                rect.maxY, page.height - PearlPetPlacement.floorInset, accuracy: 0.001,
                "she left the floor at \(position)"
            )
        }
    }

    /// The middle of the article is not a position. Her top edge is always
    /// well below the vertical middle, where the text and the caret are.
    func testSheCanNeverBeInTheMiddleOfThePage() {
        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
            let rect = frame(at: position)
            XCTAssertGreaterThan(
                rect.minY, page.height * 0.75,
                "she reached the reading area at \(position)"
            )
        }
    }

    /// And never off the sides.
    func testSheStaysInsideThePage() {
        for position in stride(from: -3.0, through: 3.0, by: 0.25) {
            let rect = frame(at: position)
            XCTAssertGreaterThanOrEqual(rect.minX, PearlPetPlacement.sideInset - 0.001)
            XCTAssertLessThanOrEqual(rect.maxX, page.width - PearlPetPlacement.sideInset + 0.001)
        }
    }

    /// The two ends of her travel are different places, or "drag her out of
    /// the way" would be a lie.
    func testTheTwoEndsOfHerTravelAreOppositeSidesOfThePage() {
        XCTAssertLessThan(frame(at: 0).midX, page.width * 0.1)
        XCTAssertGreaterThan(frame(at: 1).midX, page.width * 0.9)
    }

    /// She starts out of the way of the left-hand column most pages put their
    /// body text in.
    func testSheStartsOverToOneSide() {
        XCTAssertGreaterThan(frame(at: PearlPetPlacement.defaultPosition).midX, page.width * 0.75)
    }

    // MARK: - Nonsense in, a legal cat out

    func testACorruptPositionCannotPutHerOffThePage() {
        for nonsense in [CGFloat.nan, .infinity, -.infinity, -99, 1e9] {
            let rect = frame(at: nonsense)
            XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite, "\(nonsense) produced \(rect)")
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, page.width)
        }
        XCTAssertEqual(PearlPetPlacement.clampedPosition(.nan), PearlPetPlacement.defaultPosition)
    }

    /// A window narrower than she is does not produce a negative rectangle.
    /// (`shouldShow` refuses one this small anyway; this is the second lock.)
    func testATinyPageStillProducesASaneRectangle() {
        let rect = frame(at: 0.5, in: CGSize(width: 20, height: 20))
        XCTAssertEqual(rect.width, sprite.width)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertEqual(PearlPetPlacement.travel(in: CGSize(width: 20, height: 20), spriteSize: sprite), 0)
    }

    // MARK: - The view around her

    /// Her hosting view is her sprite plus heart room, and it never hangs over
    /// the edges of the page.
    func testHerHostingViewNeverHangsOverTheEdgeOfThePage() {
        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
            let host = PearlPetPlacement.hostFrame(in: page, spriteSize: sprite, position: position)
            XCTAssertGreaterThanOrEqual(host.minX, -0.001, "she overhangs the left at \(position)")
            XCTAssertLessThanOrEqual(host.maxX, page.width + 0.001, "she overhangs the right at \(position)")
            XCTAssertGreaterThanOrEqual(host.minY, 0)
            XCTAssertLessThanOrEqual(host.maxY, page.height)
        }
    }

    func testHerHostingViewIsMostlyHeadroom() {
        let host = PearlPetPlacement.hostFrame(in: page, spriteSize: sprite, position: 0.5)
        let sprite = frame(at: 0.5)
        XCTAssertTrue(host.contains(sprite))
        XCTAssertEqual(host.maxY, sprite.maxY, accuracy: 0.001, "the room is above her, not below")
        XCTAssertEqual(host.height - sprite.height, PearlPetPlacement.heartHeadroom, accuracy: 0.001)
    }

    /// A view that covered the page would be asked to hit-test every click on
    /// it. Hers covers a few per cent of it.
    func testHerHostingViewIsATinyPartOfThePage() {
        let host = PearlPetPlacement.hostFrame(in: page, spriteSize: sprite, position: 0.5)
        let share = (host.width * host.height) / (page.width * page.height)
        XCTAssertLessThan(share, 0.01, "she covers \(share * 100)% of the page")
        print(String(format: "PET FRAME %.0fx%.0f = %.2f%% of a 1200x800 page",
                     host.width, host.height, share * 100))
    }

    // MARK: - Dragging

    /// A drag of the full travel moves her from one end to the other, and no
    /// further.
    func testADragIsMeasuredInHerOwnTravel() {
        let travel = PearlPetPlacement.travel(in: page, spriteSize: sprite)
        XCTAssertEqual(travel, page.width - sprite.width - 2 * PearlPetPlacement.sideInset)
        XCTAssertEqual(PearlPetPlacement.clampedPosition(0 + travel / travel), 1)
        XCTAssertEqual(PearlPetPlacement.clampedPosition(0.5 + 900 / travel), 1, "a wild drag overshot")
        XCTAssertEqual(PearlPetPlacement.clampedPosition(0.5 - 900 / travel), 0)
    }

    // MARK: - Where she was left

    func testWhereSheWasLeftSurvivesAndCannotCorrupt() throws {
        let suiteName = "pearl-pet-home-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let home = PearlPetHome(defaults: defaults)
        XCTAssertEqual(home.position, PearlPetPlacement.defaultPosition, "no key must mean her corner")

        home.position = 0.25
        XCTAssertEqual(PearlPetHome(defaults: defaults).position, 0.25, accuracy: 0.0001)

        // Whatever else ends up under that key, she still stands somewhere legal.
        defaults.set(-42.0, forKey: PearlPetHome.key)
        XCTAssertEqual(home.position, 0)
        defaults.set("a cat", forKey: PearlPetHome.key)
        XCTAssertTrue((0...1).contains(home.position), "a string preference put her at \(home.position)")
    }
}
