//
//  PearlFieldTests.swift
//  Internet BrowserTests
//
//  How big the runner is drawn, and — the part that matters more — everything
//  that is not allowed to change when it grows.
//
//  Screenshots are not evidence in this codebase, so "the game is bigger now"
//  is proved the only way it can be: the field's size is a pure function of
//  the room it was given (`PearlField`), and this file reads it at the sizes
//  Cherry can actually produce. The window floor is `BrowserWindowMinimum`
//  (1000×600, 1300×600 in split view) and a split pane's own floor is 400
//  points wide, so those are the small windows tested here, not invented ones.
//

import SwiftUI
import XCTest
@testable import Cherry

final class PearlFieldTests: XCTestCase {

    // MARK: - The sizes Cherry can actually produce

    /// A full-screen window on a 16" display. The ceiling: twice the world,
    /// 1120×300, which is the whole point of the change.
    func testAFullScreenWindowGetsTwiceTheWorld() {
        let field = PearlField.metrics(availableWidth: 1512, availableHeight: 850)

        XCTAssertEqual(field.scale, 2.0)
        XCTAssertEqual(field.width, 1120)
        XCTAssertEqual(field.height, 300)
        XCTAssertEqual(field.width, PearlWorld.width * 2,
                       "the field is the world magnified, not a different world")
    }

    /// The narrowest window a Cherry browser can be dragged to — 1000 points
    /// of content, `BrowserWindowMinimum.single`. Still half again the size
    /// the game used to be drawn at, which was the world's own 560×150.
    func testTheNarrowestWindowCherryAllowsStillGetsMoreThanTheOldField() {
        let field = PearlField.metrics(availableWidth: 1000, availableHeight: 600)

        XCTAssertEqual(field.scale, 1.5)
        XCTAssertEqual(field.width, 840)
        XCTAssertEqual(field.height, 225)
        XCTAssertGreaterThan(field.width, PearlWorld.width,
                             "even at the window floor the field must beat the old fixed 560")
    }

    /// A split-view pane at its own 400-point floor: the narrowest container
    /// this screen can be handed at all. The field drops to the smallest size
    /// it is drawn at and still fits inside the pane.
    func testASplitPaneAtItsFloorGetsTheSmallestFieldAndStillFits() {
        let field = PearlField.metrics(availableWidth: 400, availableHeight: 600)

        XCTAssertEqual(field.scale, PearlField.minimumScale)
        XCTAssertEqual(field.width, 280)
        XCTAssertEqual(field.height, 75)
        XCTAssertLessThanOrEqual(field.width, 400,
                                 "a field wider than its pane would be a game with a hidden half")
    }

    /// Narrower still than anything Cherry offers, and before the column has
    /// measured itself at all (the environment's default is `.zero`). The
    /// floor is what stops the arithmetic from answering "no game".
    func testTheFieldNeverCollapsesToNothing() {
        for container in [CGSize(width: 340, height: 600), .zero] {
            let field = PearlField.metrics(
                availableWidth: container.width,
                availableHeight: container.height
            )
            XCTAssertEqual(field.scale, PearlField.minimumScale, "\(container) lost the floor")
            XCTAssertGreaterThan(field.width, 0)
            XCTAssertGreaterThan(field.height, 0)
        }
    }

    /// A wide, short window. Width alone would give the ceiling; the height
    /// share is what keeps the failure copy on screen underneath.
    func testAShortWindowKeepsHalfOfItselfForTheCopy() {
        let field = PearlField.metrics(availableWidth: 1600, availableHeight: 400)

        XCTAssertEqual(field.scale, 1.0, "height, not width, decides this one")
        XCTAssertEqual(field.height, 150)
        XCTAssertLessThanOrEqual(field.height, 400 * PearlField.heightShare)
    }

    // MARK: - The two things a field may never do

    /// Outgrow the margin the copy below it keeps. This is what makes the
    /// rounding directional: a field is allowed to be smaller than its room
    /// and never bigger, at any width in between the tested ones.
    func testTheFieldNeverOutgrowsTheMarginsItWasGiven() {
        // From the width at which the smallest field exactly fills its
        // margins (280 + 40 + 40) up past a 5K display. Below 360 the floor
        // wins on purpose — see `PearlField` — and Cherry cannot produce a
        // container that narrow anyway.
        for width in stride(from: 360.0, through: 2400.0, by: 10.0) {
            let field = PearlField.metrics(availableWidth: width, availableHeight: 2000)
            XCTAssertLessThanOrEqual(
                field.width + PearlField.horizontalMargin * 2, width + 1e-9,
                "a \(width)-point container got a \(field.width)-point field"
            )
        }
    }

    /// Swallow the window. Half of any height Cherry can be resized to is
    /// still copy.
    func testTheFieldNeverTakesMoreThanHalfTheHeight() {
        for height in stride(from: 300.0, through: 1600.0, by: 10.0) {
            let field = PearlField.metrics(availableWidth: 4000, availableHeight: height)
            XCTAssertLessThanOrEqual(
                field.height, height * PearlField.heightShare + 1e-9,
                "a \(height)-point container got a \(field.height)-point field"
            )
        }
    }

    // MARK: - Pixels

    /// The sheet is pixel art magnified nearest-neighbour, and Cherry's
    /// windows are overwhelmingly on 2x displays: every magnification the
    /// field is drawn at has to land each source pixel on a whole number of
    /// device pixels, or Pearl's whiskers come out three device pixels tall
    /// in one row and two in the next.
    func testEveryFieldSizeIsAWholeNumberOfDevicePixelsOnARetinaDisplay() {
        for width in stride(from: 360.0, through: 2400.0, by: 10.0) {
            let scale = PearlField.metrics(availableWidth: width, availableHeight: 2000).scale
            XCTAssertEqual(
                (scale * 2).rounded(), scale * 2, accuracy: 1e-9,
                "\(width) points of room magnified the art by \(scale)x, which is not a whole 2x pixel"
            )
        }
    }

    // MARK: - Where the field sits

    /// The field is a row of the reading column but wider than it, so it
    /// reports the column's width and hangs past both edges by the same
    /// amount — centred on the axis the copy below it is centred on.
    func testTheFieldIsCentredOnTheColumnItBleedsPast() {
        let wide = CGSize(width: 1512, height: 850)
        let column = PearlField.columnWidth(availableWidth: wide.width)
        let bleed = PearlField.bleed(availableWidth: wide.width, availableHeight: wide.height)
        let field = PearlField.metrics(availableWidth: wide.width, availableHeight: wide.height)

        XCTAssertEqual(column, FailureLayout.measure, "the copy keeps its measure whatever the field does")
        XCTAssertEqual(bleed, 280)
        XCTAssertEqual(column + bleed * 2, field.width,
                       "the drawn field is the column plus what hangs off each side of it")
    }

    /// On a narrow window the field is smaller than the column, so there is
    /// nothing to hang off: the bleed is zero rather than negative, which
    /// would squash the field instead of widening it.
    func testANarrowWindowBleedsByNothing() {
        let bleed = PearlField.bleed(availableWidth: 400, availableHeight: 600)

        XCTAssertEqual(bleed, 0)
        XCTAssertLessThanOrEqual(
            PearlField.metrics(availableWidth: 400, availableHeight: 600).width,
            PearlField.columnWidth(availableWidth: 400),
            "a field that fits belongs inside the column, not slung across it"
        )
    }

    /// The field's margin is the column's margin, read rather than copied. A
    /// second literal here is a margin that drifts the first time the column's
    /// changes.
    func testTheFieldKeepsTheSameMarginTheCopyKeeps() {
        XCTAssertEqual(PearlField.horizontalMargin, FailureLayout.horizontalMargin)
        XCTAssertEqual(PearlField.columnWidth(availableWidth: 5000), FailureLayout.measure)
    }

    // MARK: - What a bigger field is not allowed to have touched

    /// The one that matters. The field is a magnification applied by the
    /// canvas; the world it magnifies is untouched, so a jump clears exactly
    /// what `PearlRunnerGameTests` says it clears. If a future "make it
    /// bigger" is done by editing these numbers instead of the field's scale,
    /// the simulation changes underneath the tuning and this dies first.
    func testMakingTheFieldBiggerDidNotMakeTheWorldBigger() {
        XCTAssertEqual(PearlWorld.width, 560)
        XCTAssertEqual(PearlWorld.height, 150)
        XCTAssertEqual(PearlWorld.feetLine, 140)
        XCTAssertEqual(PearlWorld.pearlX, 30)

        XCTAssertEqual(PearlSpriteContract.run, .init(width: 44, height: 47))
        XCTAssertEqual(PearlSpriteContract.duck, .init(width: 59, height: 30))
        XCTAssertEqual(PearlSpriteContract.treeSmall, .init(width: 17, height: 35))
        XCTAssertEqual(PearlSpriteContract.treeLarge, .init(width: 25, height: 50))
        XCTAssertEqual(PearlSpriteContract.gull, .init(width: 46, height: 40))
        XCTAssertEqual(PearlSpriteContract.groundHeight, 12)
    }

    /// And the run itself: the same seed and the same inputs at any field size
    /// is the same run, because the field is not an input to it. There is no
    /// scale to pass in — that absence IS the guarantee, so this steps a real
    /// run and pins where Pearl ends up in world units.
    func testTheSimulationHasNoWayToHearAboutTheField() {
        var game = PearlRunnerGame(seed: 7)
        var replay = PearlRunnerGame(seed: 7)

        for frame in 0..<600 {
            let input = PearlInput(jump: frame % 90 == 0)
            game.step(input: input)
            replay.step(input: input)
        }

        XCTAssertEqual(game, replay)
        XCTAssertEqual(game.pearlBounds.width, PearlSpriteContract.run.width,
                       "Pearl is measured in world points, and the world did not resize")
        XCTAssertLessThanOrEqual(game.pearlBounds.maxY, PearlWorld.feetLine)
    }
}

// MARK: - The view's end of the wire

@MainActor
final class PearlFieldWiringTests: XCTestCase {

    /// The section reads the surface it was given from the environment, which
    /// is the only route the window's size takes to the field. Mirror sees the
    /// `@Environment` property wrapper as a stored child; if the read is
    /// deleted and the field goes back to a fixed size, there is no child to
    /// find.
    func testTheRunnerSectionTakesTheContainerSizeFromTheEnvironment() {
        let section = PearlRunnerSection(offersRunner: true)
        let stored = Mirror(reflecting: section).children.first { $0.label == "_available" }

        XCTAssertNotNil(stored, "the section no longer reads the surface it was given")
        XCTAssertTrue(
            stored?.value is Environment<CGSize>,
            "the container size must arrive as an environment value, not as a guess"
        )
    }

    /// The channel itself: unset it is zero — which is why `PearlField` has to
    /// be sensible at zero — and set, it carries the size a full-screen window
    /// would hand over, which is the 1120-point field.
    func testTheContainerSizeCarriesThroughTheEnvironmentAndSurvivesBeingUnset() {
        var values = EnvironmentValues()
        XCTAssertEqual(values.failureContainerSize, .zero,
                       "unset must be zero, and zero must be survivable")

        values.failureContainerSize = CGSize(width: 1512, height: 850)
        XCTAssertEqual(
            PearlField.metrics(
                availableWidth: values.failureContainerSize.width,
                availableHeight: values.failureContainerSize.height
            ).width,
            1120
        )
    }
}
