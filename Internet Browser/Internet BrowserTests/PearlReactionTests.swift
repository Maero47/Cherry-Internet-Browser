//
//  PearlReactionTests.swift
//  Internet BrowserTests
//
//  Pearl's hearts: that they fire on the moments that deserve them, that they
//  do NOT fire on the moments that don't, and that under Reduce Motion they do
//  not fire at all.
//
//  The Reduce Motion half is the one that matters most, and it is deliberately
//  stronger than "the animation is skipped": the hearts ARE the animation, so
//  a reaction that fired-but-didn't-move would leave a static rosette of
//  hearts sitting permanently over the footer, which is worse than nothing.
//  The counter must not move.
//
//  These drive the wizard's OWN entry points (`advance`, `goBack`, the accent
//  swatch's own action closure) rather than a reaction object held at arm's
//  length. A reaction object that obeys every rule and is never actually
//  reached is the same bug as no reaction object at all.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

private func collectReactionValues<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collectReactionValues(type, in: $0.value, depth: depth + 1)
    }
}

// MARK: - The rule

@MainActor
final class PearlReactionRuleTests: XCTestCase {

    func testAReactionRaisesThePulseAndRecordsWhy() {
        let reactions = PearlReactions()
        XCTAssertEqual(reactions.pulse, 0)
        XCTAssertNil(reactions.lastReason)

        reactions.fire(.choice, reduceMotion: false)

        XCTAssertEqual(reactions.pulse, 1)
        XCTAssertEqual(reactions.lastReason, .choice)
    }

    /// Every reaction gets its own pulse, because the burst view is `.id`-ed
    /// on the counter: a second heart burst that reused the first one's id
    /// would never restart its animation and would simply not appear.
    func testEachReactionIsItsOwnPulse() {
        let reactions = PearlReactions()
        for expected in 1...4 {
            reactions.fire(.choice, reduceMotion: false)
            XCTAssertEqual(reactions.pulse, expected)
        }
    }

    /// THE accessibility test. Nothing fires, for any reason, ever.
    func testNothingFiresUnderReduceMotion() {
        let reactions = PearlReactions()
        for reason in [PearlReactions.Reason.choice, .stepDone, .arrived] {
            reactions.fire(reason, reduceMotion: true)
        }
        XCTAssertEqual(reactions.pulse, 0, "hearts fired with Reduce Motion on")
        XCTAssertNil(reactions.lastReason, "a reaction was recorded with Reduce Motion on")
    }

    /// And the block is per-call, not a latch: turning Reduce Motion off again
    /// (the user can, mid-wizard, from System Settings) must not leave her
    /// permanently mute.
    func testTheBlockIsPerCallAndNotALatch() {
        let reactions = PearlReactions()
        reactions.fire(.choice, reduceMotion: true)
        reactions.fire(.choice, reduceMotion: false)
        XCTAssertEqual(reactions.pulse, 1)
    }
}

// MARK: - The moments

@MainActor
final class PearlWizardReactionTests: XCTestCase {

    /// Completing a step is a moment. Dies on: `advance` losing its reaction —
    /// the object would keep all its rules and never be called.
    func testFinishingAStepFiresHearts() {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: false)

        XCTAssertEqual(view.reactions.pulse, 1)
        XCTAssertEqual(view.reactions.lastReason, .stepDone)
    }

    /// Reaching the LAST step is a bigger moment than finishing a middle one,
    /// and says so — that reason is what the sign-off's own burst rides on.
    func testArrivingAtTheLastStepIsItsOwnReason() {
        let view = SetupWizardView(onFinish: {})
        while !view.model.isLastStep {
            view.advance(reduceMotion: false)
        }
        XCTAssertEqual(view.reactions.lastReason, .arrived)
        XCTAssertEqual(view.reactions.pulse, SetupWizardModel.steps.count - 1)
    }

    /// Back is not a celebration. Dies on: the tempting symmetry of firing on
    /// every navigation, which turns the hearts into a scroll indicator.
    func testGoingBackDoesNotFireHearts() {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: false)
        let after = view.reactions.pulse

        view.goBack()

        XCTAssertEqual(view.reactions.pulse, after, "going back set off hearts")
    }

    /// Finishing fires nothing: the sheet is being torn down, and hearts on a
    /// view that is going away are hearts nobody sees. This is also the reason
    /// there is no celebration between pressing Start Browsing and the sheet
    /// closing — Pearl is never allowed to delay an action.
    func testFinishingTheWizardFiresNothingAndDoesNotDelayTheDismissal() {
        var finished = 0
        let view = SetupWizardView(onFinish: { finished += 1 })
        while !view.model.isLastStep { view.advance(reduceMotion: false) }
        let before = view.reactions.pulse

        view.advance(reduceMotion: false)

        XCTAssertEqual(finished, 1, "Start Browsing did not dismiss the sheet on the spot")
        XCTAssertEqual(view.reactions.pulse, before)
    }

    /// The whole wizard walked with Reduce Motion on: not one heart.
    func testWalkingTheWholeWizardUnderReduceMotionFiresNothing() {
        let view = SetupWizardView(onFinish: {})
        while !view.model.isLastStep { view.advance(reduceMotion: true) }
        view.goBack()
        view.advance(reduceMotion: true)

        XCTAssertEqual(view.reactions.pulse, 0)
    }

    /// The tap that writes the setting is the SAME tap that sends the hearts
    /// up — read out of the appearance step's own accent swatches, so a
    /// reaction wired to some other code path would not save it.
    ///
    /// Runs against the real `SettingsManager`, so the accent is pinned and
    /// restored the way `SetupWizardSettingsPathTests` pins what it touches.
    func testPickingAnAccentBothWritesTheSettingAndFiresHearts() throws {
        let settings = SettingsManager.shared
        let saved = settings.accentColorHex
        defer { settings.accentColorHex = saved }

        let reactions = PearlReactions()
        let step = SetupAppearanceStep(reactions: reactions)
        let swatches = collectReactionValues(AccentSwatch.self, in: step.body)
        XCTAssertFalse(swatches.isEmpty, "the appearance step offers no accent swatches")

        let target = try XCTUnwrap(swatches.first { $0.option.hex != saved },
                                   "every swatch is already the current accent")
        target.action()

        XCTAssertEqual(settings.accentColorHex, target.option.hex,
                       "the swatch stopped writing the setting")
        XCTAssertEqual(reactions.pulse, 1, "the swatch writes the setting but Pearl never reacts")
        XCTAssertEqual(reactions.lastReason, .choice)
    }
}
