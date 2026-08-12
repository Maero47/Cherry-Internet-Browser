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
}
