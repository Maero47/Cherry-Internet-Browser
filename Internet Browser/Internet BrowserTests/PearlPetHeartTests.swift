//
//  PearlPetHeartTests.swift
//  Internet BrowserTests
//
//  Her hearts are hers, in both places she has them.
//
//  Pearl reacts in two entirely different technologies now — the setup
//  wizard's SwiftUI `PearlHeartBurst` and the pet's Core Animation layers —
//  and the risk of that is two hearts and two rules. So the drawing has one
//  source (`PearlHeartShape`), the tint has one source
//  (`PearlMascot.heartNSTint`), and the Reduce Motion rule has one source
//  (`PearlMascot.heartsMayFly`). These tests are what stop a second copy of
//  any of the three appearing.
//
//  ## The fourth thing, found in the combine
//
//  There was a fourth copy, and it was invisible while the two features lived
//  on separate branches. The pet was written against a `PearlHeartBurst` whose
//  three hearts were absolute point values, and it copied them: 11, 15 and 9
//  points across, rising 30, 37 and 27. The wizard branch then replaced those
//  very numbers with fractions of a span, because a fixed 37pt rise anchored
//  over a 34pt cat is what made the wizard's hearts paint outside their host
//  and never be seen at all.
//
//  Merged, both were green and the codebase held two descriptions of one
//  burst — one of them the description the other had just been rewritten to
//  stop being. So the pet now reads the same table through `PearlPetBurst`,
//  and the last group below is what fails if the points come back.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class PearlPetHeartTests: XCTestCase {

    /// The pet's heart is the wizard's heart: the same shape, resolved.
    func testThePetsHeartIsTheSameDrawingAsTheWizards() {
        let box = CGRect(x: 0, y: 0, width: 15, height: 15)
        let fromShape = PearlHeartShape().path(in: box).cgPath
        let forLayers = CGPath.pearlHeart(in: box)
        XCTAssertEqual(forLayers, fromShape, "the pet drew its own heart")
        XCTAssertFalse(forLayers.isEmpty)
        XCTAssertEqual(forLayers.boundingBox.width, box.width, accuracy: 0.5)
    }

    /// One tint, two consumers.
    func testTheTintHasOneSource() {
        XCTAssertEqual(PearlMascot.heartTint, Color(nsColor: PearlMascot.heartNSTint))
    }

    /// One rule, and it is the one both reaction paths ask.
    func testTheReduceMotionRuleHasOneSource() {
        XCTAssertTrue(PearlMascot.heartsMayFly(reduceMotion: false))
        XCTAssertFalse(PearlMascot.heartsMayFly(reduceMotion: true))

        let reactions = PearlReactions()
        reactions.fire(.choice, reduceMotion: true)
        XCTAssertEqual(reactions.pulse, 0, "the wizard stopped asking the rule")
        reactions.fire(.choice, reduceMotion: false)
        XCTAssertEqual(reactions.pulse, 1)
    }

    /// Under Reduce Motion the pet builds no heart layers at all — not
    /// invisible ones, none.
    func testUnderReduceMotionThePetBuildsNoHearts() {
        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        view.reduceMotion = true
        let before = view.layer?.sublayers?.count ?? 0

        view.pet()
        view.feed()

        XCTAssertEqual(view.layer?.sublayers?.count ?? 0, before, "hearts flew under Reduce Motion")
    }

    /// And with motion allowed, petting her makes exactly three.
    func testPettingHerMakesThreeHearts() {
        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        let before = view.layer?.sublayers?.count ?? 0

        view.pet()

        XCTAssertEqual(
            (view.layer?.sublayers?.count ?? 0) - before, 3,
            "the burst is three hearts, the way the wizard's is"
        )
        XCTAssertEqual(view.currentAppearance?.pose, .delighted)
    }

    // MARK: - One burst, two spans

    /// The span the pet actually hands the burst in production: the hosting
    /// view's height, which is her sprite plus the headroom the hearts were
    /// given. Everything below is measured at this.
    private var productionSpan: CGFloat {
        PearlPetPlacement.hostFrame(
            in: CGSize(width: 1200, height: 800),
            spriteSize: CGSize(width: PearlSpriteContract.petStanding.width,
                               height: PearlSpriteContract.petStanding.height),
            position: 0.5
        ).height
    }

    /// The geometry the pet flies is the wizard's table, scaled — not a second
    /// set of numbers that happens to look similar.
    ///
    /// Dies on: any of the six point values coming back into `burstHearts` (a
    /// re-hardcoded 15pt heart is 0.174 of an 86pt span, not 0.16); a heart
    /// being added to or dropped from one side only; the stagger being
    /// retyped rather than read.
    func testThePetFliesTheWizardsThreeHeartsAndNoOthers() {
        let span = productionSpan
        let flights = PearlPetBurst.flights(span: span, centreX: 0)

        XCTAssertEqual(flights.count, PearlHeartBurst.hearts.count,
                       "the pet and the wizard disagree about how many hearts a burst is")

        for (flight, heart) in zip(flights, PearlHeartBurst.hearts) {
            XCTAssertEqual(flight.size, span * heart.size, accuracy: 0.001,
                           "the pet drew a heart at a size of its own")
            XCTAssertEqual(flight.end.y - flight.start.y, span * heart.rise, accuracy: 0.001,
                           "the pet flew a rise of its own")
            XCTAssertEqual(flight.end.x - flight.start.x, span * heart.drift, accuracy: 0.001,
                           "the pet drifted by an amount of its own")
            XCTAssertEqual(flight.delay, heart.delay, accuracy: 0.0001,
                           "the pet staggered on its own clock")
        }
    }

    /// She launches them from the same place on herself the wizard's Pearl
    /// does — `origin` down the span, which an `NSView` counts up from its
    /// bottom.
    func testTheHeartsLeaveFromTheSharedOrigin() {
        let span = productionSpan
        let flight = PearlPetBurst.flights(span: span, centreX: 20).first
        XCTAssertEqual(flight?.start.y ?? -1, span * (1 - PearlHeartBurst.origin), accuracy: 0.001)
        XCTAssertEqual(flight?.start.x ?? -1, 20, accuracy: 0.001,
                       "the hearts must leave from her centre line, not the view's corner")
    }

    /// The pet's half of the containment claim: at the span she is really
    /// given, no heart paints outside the view it is drawn in — the same
    /// property `PearlHeartContainmentTests` holds for the wizard, which until
    /// now nothing held for her.
    ///
    /// Dies on: the span being taken from her sprite rather than the view (an
    /// 86pt reach inside a 40pt frame); the headroom in `PearlPetPlacement`
    /// being cut without the burst being re-checked.
    func testNothingThePetPaintsLeavesTheViewSheIsDrawnIn() {
        let span = productionSpan
        let width = PearlSpriteContract.petStanding.width + 2 * PearlPetPlacement.heartSideroom
        let bounds = CGRect(x: 0, y: 0, width: width, height: span)
        let painted = PearlPetBurst.paintedRect(span: span, centreX: bounds.midX)

        XCTAssertTrue(
            bounds.contains(painted),
            """
            the pet's burst paints \(painted) inside a \(bounds) view. Anything outside those \
            bounds is the wizard's old bug in the other feature: painted, composited under \
            something else, never seen.
            """
        )
    }

    /// And the layers she really builds are the flights, so the arithmetic
    /// above is the arithmetic on screen rather than a parallel description of
    /// it.
    ///
    /// Dies on: `burstHearts` going back to positioning the layers itself.
    func testTheLayersSheBuildsAreThoseFlights() throws {
        let span = productionSpan
        let view = PearlPetView(driver: SilentDriver())
        view.frame = CGRect(x: 0, y: 0, width: 56, height: span)
        let existing = Set((view.layer?.sublayers ?? []).map { ObjectIdentifier($0) })

        view.pet()

        let hearts = (view.layer?.sublayers ?? [])
            .filter { !existing.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(hearts.count, 3)

        let flights = PearlPetBurst.flights(span: span, centreX: view.spriteRect.midX)
        for (heart, flight) in zip(hearts, flights) {
            XCTAssertEqual(heart.bounds.width, flight.size, accuracy: 0.001)
            XCTAssertEqual(heart.position.x, flight.start.x, accuracy: 0.001)
            XCTAssertEqual(heart.position.y, flight.start.y, accuracy: 0.001)

            let rise = try XCTUnwrap(heart.animation(forKey: "rise") as? CABasicAnimation)
            let top = try XCTUnwrap(rise.toValue as? NSNumber).doubleValue
            XCTAssertEqual(CGFloat(top), flight.end.y, accuracy: 0.001)
            XCTAssertEqual(rise.duration, PearlHeartBurst.travelDuration, accuracy: 0.0001,
                           "the pet's flight is a different length from the wizard's")
        }
    }
}
