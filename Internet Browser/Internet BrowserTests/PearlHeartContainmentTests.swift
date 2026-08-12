//
//  PearlHeartContainmentTests.swift
//  Internet BrowserTests
//
//  The bug this file exists for: **the hearts fired, and nobody ever saw one.**
//
//  Every test about them was green. The pulse rose on the right moments, it
//  did not rise under Reduce Motion, the tint cleared its contrast floor, the
//  burst was `.id`-ed so a second reaction restarted it. All true, all useless:
//  the burst was painting somewhere that does not reach the screen.
//
//  ## What was actually wrong
//
//  The burst was anchored to the TOP of the 34pt Pearl who lived in the
//  wizard's footer, offset another 6pt up, and its tallest heart rose 37pt
//  beyond that. Topmost painted pixel: 43pt above her head. Her head sat 13pt
//  below the footer's own top edge. So THIRTY of those forty-three points were
//  painted outside the footer altogether — that is not the tail of the
//  animation, that is the entire ascent.
//
//  On macOS that overflow does not survive. Hosting `SetupWizardView` in an
//  `NSHostingView` and walking the AppKit tree it becomes gives:
//
//      NSHostingView<SetupWizardView>  (0, 0, 620, 560)
//        PlatformContainer             (0, 3, 620, 502)   ← the ScrollView
//          HostingScrollView                                clips=true
//        _FocusRingView                (384, 519, …)      ← a footer button
//        _FocusRingView                (489.5, 519, …)
//
//  The footer contributes NO AppKit view. Pearl, the divider and the hearts
//  are painted into the hosting view's own backing layer — and a layer's own
//  content composites beneath its sublayers, always. The scroll view's
//  container is a sublayer covering the sheet's top 505 points, and the hearts
//  flew from y≈513 up to y≈476: straight in behind it, through the band where
//  SwiftUI also installs the scroll view's edge treatment (`NSScrollPocket`,
//  a 28pt `CABackdropLayer`, present the moment a step's content scrolls).
//
//  What was left on screen was the first tenth of a second of a 9–15pt heart,
//  still sitting on the crown of a small cat in the bottom-left corner, three
//  hundred points away from the swatch the user had just clicked.
//
//  ## What is pinned here
//
//  Not "the hearts are bigger". The invariant: **a burst never needs to paint
//  outside the frame it is drawn over**, and **the only thing that gives it a
//  frame is `PearlPortrait`, which always gives it its own height.** Break
//  either and one of these goes red.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

private func collect<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collect(type, in: $0.value, depth: depth + 1)
    }
}

/// Every Pearl the wizard actually draws on its current step.
///
/// One hop through the two views she lives inside — her arrival and the
/// welcome page — because a `Mirror` walk stops at a child view's boundary.
/// She used to be inline in the wizard's own footer as well, which is exactly
/// the arrangement this file exists to stop coming back.
@MainActor
private func pearlsOnScreen(_ view: SetupWizardView) -> [PearlPortrait] {
    let tree = view.body
    return collect(PearlPortrait.self, in: tree)
        + collect(PearlIntro.self, in: tree).flatMap { collect(PearlPortrait.self, in: $0.body) }
        + collect(SetupWelcomeStep.self, in: tree).flatMap { collect(PearlPortrait.self, in: $0.body) }
}

@MainActor
final class PearlHeartContainmentTests: XCTestCase {

    // MARK: - The arithmetic

    /// THE test. Every heart, at the top of its rise, is still inside the
    /// frame the burst was handed — and still inside it at the bottom of its
    /// rise, which is the other way to fall off.
    ///
    /// Dies on: any heart's `rise` being raised past the room above `origin`
    /// (the exact shape of the bug: 37pt of rise from an anchor with 13pt of
    /// room); `origin` being moved up so the hearts start at her ears and
    /// leave over the top; a heart being grown until its own half-height
    /// pushes it out.
    func testNoHeartEverPaintsOutsideTheFrameItIsDrawnOver() {
        let band = PearlHeartBurst.paintedBand

        XCTAssertGreaterThanOrEqual(
            band.lowerBound, 0,
            """
            the burst paints \(String(format: "%.1f", -band.lowerBound * 100))% of a span above \
            the top of the view it is drawn over. That overflow is what made the footer hearts \
            invisible: on macOS it lands behind the scroll view's platform container.
            """
        )
        XCTAssertLessThanOrEqual(
            band.upperBound, 1,
            "the burst paints below the bottom of the view it is drawn over"
        )
    }

    /// The same question sideways. A heart that drifts out of her silhouette
    /// is in the same danger as one that rises out of it — on the question
    /// steps her left edge is the sheet's margin and her right edge is her
    /// speech bubble.
    func testNoHeartDriftsOutOfTheFrameEither() {
        XCTAssertLessThanOrEqual(
            PearlHeartBurst.widestReachFromCentre, 0.5,
            "a heart drifts past the edge of the frame the burst was given"
        )
    }

    /// The burst has no size of its own — it is fractions, all the way down.
    /// This is the structural reason the bug cannot come back by someone
    /// re-anchoring it somewhere small: there is no fixed 37pt rise left to
    /// out-grow a host.
    ///
    /// Dies on: a point value creeping back in as a heart's size or rise
    /// (a fraction above 1 is a point value wearing a fraction's name).
    func testTheBurstIsDescribedInFractionsAndNotInPoints() {
        XCTAssertFalse(PearlHeartBurst.hearts.isEmpty)
        for heart in PearlHeartBurst.hearts {
            XCTAssertGreaterThan(heart.size, 0)
            XCTAssertLessThanOrEqual(heart.size, 1, "\(heart.size) is not a fraction of a span")
            XCTAssertLessThanOrEqual(heart.rise, 1, "\(heart.rise) is not a fraction of a span")
            XCTAssertLessThanOrEqual(abs(heart.drift), 1)
        }
        XCTAssertGreaterThan(PearlHeartBurst.origin, 0)
        XCTAssertLessThanOrEqual(PearlHeartBurst.origin, 1)
    }

    /// And the hearts still actually go somewhere: a "contained" burst that
    /// contains itself by not moving is the cure killing the patient.
    func testTheHeartsStillTravelFarEnoughToReadAsARise() {
        let longest = PearlHeartBurst.hearts.map(\.rise).max() ?? 0
        XCTAssertGreaterThanOrEqual(longest, 0.2,
                                    "the hearts barely move; this is not a burst")
        XCTAssertGreaterThanOrEqual(longest * PearlMascot.introHeight, 30,
                                    "at her drawn size the rise is shorter than the one nobody saw")
    }

    // MARK: - Who is allowed to give it a frame

    /// `PearlPortrait` hands the burst its OWN height, and hands it nothing
    /// else. This is the half of the fix that call sites cannot undo.
    ///
    /// Dies on: the span being loosened into a caller-supplied parameter
    /// again, which is precisely how the footer got to anchor a 43pt reach
    /// over a 34pt cat.
    func testThePortraitGivesTheBurstItsOwnHeightAndNothingElse() {
        for height in [PearlMascot.introHeight, PearlMascot.heroHeight, 34] as [CGFloat] {
            let portrait = PearlPortrait(pose: .sitting, height: height, label: "Pearl", pulse: 1)
            let bursts = collect(PearlHeartBurst.self, in: portrait.body)
            XCTAssertEqual(bursts.count, 1, "a reacting Pearl draws no burst at \(height)pt")
            XCTAssertEqual(bursts.first?.span, height,
                           "the burst was given a span that is not Pearl's own height")
        }
    }

    /// No pulse, no burst — she is not permanently haloed in hearts.
    func testAPearlWhoIsNotReactingDrawsNoBurstAtAll() {
        let portrait = PearlPortrait(pose: .sitting, height: PearlMascot.introHeight, label: "Pearl")
        XCTAssertTrue(collect(PearlHeartBurst.self, in: portrait.body).isEmpty)
    }

    // MARK: - In the real wizard

    /// Pressing the wizard's own Continue puts a burst on the Pearl the next
    /// step actually draws, at that Pearl's own height.
    ///
    /// Dies on: the reaction reaching a Pearl who is not on screen; the intro
    /// dropping `pulse` on its way through to the portrait, which would leave
    /// every existing reaction test green and the hearts gone again.
    func testAdvancingPutsARealBurstOnTheRealPearl() throws {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: false)
        XCTAssertEqual(view.reactions.pulse, 1, "precondition: Continue fired a reaction")

        let portraits = pearlsOnScreen(view)
        let portrait = try XCTUnwrap(portraits.first, "the step she arrived on draws no Pearl")
        XCTAssertEqual(portrait.pulse, view.reactions.pulse,
                       "Pearl is on screen but the pulse never reached her")

        let bursts = collect(PearlHeartBurst.self, in: portrait.body)
        XCTAssertEqual(bursts.count, 1, "she reacted and no hearts were built")
        XCTAssertEqual(bursts.first?.span, portrait.height)
    }

    /// Nowhere in the wizard is she drawn small enough for the old failure to
    /// be possible again. The footer companion is retired; if a Pearl this
    /// size reappears, she is back in a 60pt strip with 13pt of headroom, and
    /// her hearts are back behind the scroll view.
    ///
    /// Dies on: `footerPearl` being reinstated, at any size under her resting
    /// height.
    func testTheWizardNeverDrawsAPearlSmallEnoughToHideHerHearts() {
        let view = SetupWizardView(onFinish: {})
        for _ in SetupWizardModel.steps.indices {
            let pearls = pearlsOnScreen(view)
            // Not a vacuous loop: she really is on every one of these steps.
            XCTAssertEqual(pearls.count, 1, "\(view.model.step) draws \(pearls.count) Pearls")
            for portrait in pearls {
                XCTAssertGreaterThanOrEqual(
                    portrait.height, PearlMascot.restingHeight,
                    """
                    the wizard draws Pearl at \(portrait.height)pt. That is footer-companion size, \
                    and a burst fired from down there paints its whole ascent behind the scroll \
                    view's platform container.
                    """
                )
            }
            if !view.model.isLastStep { view.advance(reduceMotion: false) }
        }
    }
}
