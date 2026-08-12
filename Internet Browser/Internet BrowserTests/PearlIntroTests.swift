//
//  PearlIntroTests.swift
//  Internet BrowserTests
//
//  Pearl arriving on a setup step: that she does it on every question and only
//  once each, that the words she brings are hers and not the form's, that one
//  click gets rid of her, and that Reduce Motion costs her the entrance and
//  not the sentence.
//
//  Nothing here renders pixels. It walks the same SwiftUI value trees the rest
//  of the wizard's tests walk, and drives the wizard's own entry points —
//  `advance`, `goBack`, `skipPearl`, and the speech bubble's own dismiss
//  closure. A bubble that obeys every rule and is never reached is the same
//  bug as no bubble at all.
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

/// Her arrival as the wizard actually builds it on the current step, plus the
/// bubble inside it — one hop, because a child view's `body` is a function
/// `Mirror` will not call.
@MainActor
private func bubbleOnScreen(_ view: SetupWizardView) -> PearlSpeechBubble? {
    collect(PearlIntro.self, in: view.body)
        .flatMap { collect(PearlSpeechBubble.self, in: $0.body) }
        .first
}

/// The masthead the current step actually draws — the same hop again, this
/// time through whichever of the five step views is on screen. Named
/// exhaustively rather than reflected generically, so a new step that forgets
/// to appear here is a compile-time reminder rather than a silently vacuous
/// assertion.
@MainActor
private func mastheadsOnScreen(_ view: SetupWizardView) -> [SetupStepMasthead] {
    let tree = view.body
    var bodies: [Any] = [tree]
    bodies += collect(SetupAppearanceStep.self, in: tree).map { $0.body }
    bodies += collect(SetupSearchPrivacyStep.self, in: tree).map { $0.body }
    bodies += collect(SetupImportStep.self, in: tree).map { $0.body }
    bodies += collect(SetupExtensionsStep.self, in: tree).map { $0.body }
    bodies += collect(SetupTabLayoutStep.self, in: tree).map { $0.body }
    return bodies.flatMap { collect(SetupStepMasthead.self, in: $0) }
}

// MARK: - Once per step

@MainActor
final class PearlIntroDirectorTests: XCTestCase {

    /// She is on a step until that step's appearance is spent, and never
    /// anywhere she has no line for.
    func testSheIsPresentUntilTheStepIsSpent() {
        let director = PearlIntroDirector()
        XCTAssertTrue(director.isPresent(on: .appearance))
        director.spend(.appearance)
        XCTAssertFalse(director.isPresent(on: .appearance))
        XCTAssertTrue(director.isPresent(on: .searchPrivacy), "spending one step muted her on another")
    }

    func testSheIsNeverPresentOnAStepSheHasNoLineFor() {
        XCTAssertFalse(PearlIntroDirector().isPresent(on: .welcome))
    }

    /// THE rhythm test: one appearance per step. Walking the whole wizard
    /// forward, then back, then forward again must not summon her twice on the
    /// same step.
    ///
    /// Dies on: presence being derived from "is this the current step" alone,
    /// which is the obvious implementation and turns her back into a resident
    /// who merely re-enters on every navigation.
    func testWalkingBackAndForwardDoesNotSummonHerTwiceOnAStep() {
        let view = SetupWizardView(onFinish: {})
        var appearances: [SetupWizardStep: Int] = [:]

        func note() {
            if view.intro.isPresent(on: view.model.step) {
                appearances[view.model.step, default: 0] += 1
            }
        }

        note()
        while !view.model.isLastStep {
            view.advance(reduceMotion: true)
            note()
        }
        view.goBack()
        note()
        view.advance(reduceMotion: true)
        note()

        for step in PearlIntroScript.steps {
            XCTAssertLessThanOrEqual(appearances[step] ?? 0, 1,
                                     "Pearl arrived on \(step) more than once")
        }
        XCTAssertEqual(Set(appearances.keys), Set(PearlIntroScript.steps),
                       "some question step never got its one arrival")
    }

    /// Leaving a step spends it, through the wizard's own navigation and not
    /// through the director directly.
    func testMovingOnEndsHerAppearanceOnTheStepBehindYou() {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: true)
        XCTAssertTrue(view.intro.isPresent(on: .appearance))

        view.advance(reduceMotion: true)
        XCTAssertFalse(view.intro.isPresent(on: .appearance),
                       "she is still standing on the step the user has left")
    }
}

// MARK: - Skippable

@MainActor
final class PearlIntroSkipTests: XCTestCase {

    /// One click on the bubble's OWN control and she is gone from the step —
    /// reached through the closure the "Got it" button calls, not by poking
    /// the director.
    ///
    /// Dies on: the button being wired to something that is not the director;
    /// the intro being rebuilt from a value that ignores the dismissal, which
    /// is the classic way a "dismissible" banner comes straight back.
    func testTheBubbleIsDismissedByItsOwnControl() throws {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: true)

        let bubble = try XCTUnwrap(bubbleOnScreen(view), "no bubble on the first question step")
        bubble.onSkip()

        XCTAssertNil(bubbleOnScreen(view), "Pearl survived her own dismiss button")
        XCTAssertTrue(collect(PearlIntro.self, in: view.body).isEmpty,
                      "the bubble went but Pearl is still standing there")
    }

    /// Skipping her on one step does not skip her for the rest of the run.
    func testSkippingHerOnOneStepDoesNotSilenceHerOnTheNext() throws {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: true)
        view.skipPearl()
        XCTAssertNil(bubbleOnScreen(view))

        view.advance(reduceMotion: true)
        XCTAssertNotNil(bubbleOnScreen(view), "one skip muted her for the whole wizard")
    }

    /// The step is answerable on the frame she lands on: she is above the
    /// question in the flow, not over it, and the step's own controls are
    /// complete and present while she is still talking.
    ///
    /// Dies on: the intro being turned into a cover or a modal, or the step's
    /// content being deferred until she is dismissed.
    func testTheStepIsFullyBuiltWhileSheIsStillOnIt() throws {
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: true)
        XCTAssertNotNil(bubbleOnScreen(view), "precondition: she is on the appearance step")

        let step = try XCTUnwrap(collect(SetupAppearanceStep.self, in: view.body).first,
                                 "the appearance step is not on screen behind her")
        let swatches = collect(AccentSwatch.self, in: step.body)
        XCTAssertEqual(swatches.count, AccentColorOption.options.count,
                       "the step's controls are not all there while Pearl is talking")

        // …and they work: the tap that writes the setting is live, not parked
        // behind her.
        let settings = SettingsManager.shared
        let saved = settings.accentColorHex
        defer { settings.accentColorHex = saved }
        let target = try XCTUnwrap(swatches.first { $0.option.hex != saved })
        target.action()
        XCTAssertEqual(settings.accentColorHex, target.option.hex,
                       "a control under Pearl's bubble did not answer")
    }
}

// MARK: - Reduce Motion

@MainActor
final class PearlArrivalMotionTests: XCTestCase {

    /// THE accessibility test for the arrival. With Reduce Motion on she is
    /// simply THERE — full opacity, full size, in place — from the first frame,
    /// before `landed` has flipped and without any animation to flip it.
    ///
    /// Dies on: the arrival being expressed as "animate faster" or "a shorter
    /// spring" rather than "no animation"; the opacity ramp being left in, which
    /// would make her fade in silently under Reduce Motion and, worse, would
    /// leave a reader who never gets a frame with `landed == true` looking at
    /// an invisible bubble.
    func testUnderReduceMotionSheIsAlreadyLandedAndSayingHerPiece() {
        XCTAssertNil(PearlArrival.animation(reduceMotion: true),
                     "Reduce Motion still animates her arrival")
        XCTAssertEqual(PearlArrival.opacity(landed: false, reduceMotion: true), 1,
                       "with Reduce Motion on the bubble starts invisible")
        XCTAssertEqual(PearlArrival.offset(landed: false, reduceMotion: true), 0)
        XCTAssertEqual(PearlArrival.scale(landed: false, reduceMotion: true), 1)
    }

    /// And with motion allowed she really does arrive rather than being
    /// switched on: below her place, transparent, and slightly small.
    func testWithMotionAllowedSheArrivesFromSomewhereElse() {
        XCTAssertNotNil(PearlArrival.animation(reduceMotion: false))
        XCTAssertGreaterThan(PearlArrival.offset(landed: false, reduceMotion: false), 0,
                             "she does not come up from anywhere; she just appears")
        XCTAssertEqual(PearlArrival.opacity(landed: false, reduceMotion: false), 0)
        XCTAssertLessThan(PearlArrival.scale(landed: false, reduceMotion: false), 1)

        XCTAssertEqual(PearlArrival.offset(landed: true, reduceMotion: false), 0)
        XCTAssertEqual(PearlArrival.opacity(landed: true, reduceMotion: false), 1)
        XCTAssertEqual(PearlArrival.scale(landed: true, reduceMotion: false), 1)
    }

    /// She rises into place; she does not fly in from off the sheet.
    func testHerEntranceIsAShortRiseAndNotAFlight() {
        XCTAssertGreaterThan(PearlArrival.travel, 8)
        XCTAssertLessThanOrEqual(PearlArrival.travel, 40,
                                 "an entrance this long is a thing the user waits through")
    }

    /// The whole wizard walked with Reduce Motion on still shows her on every
    /// question step, bubble and all. The accessibility setting costs her the
    /// entrance, not the appearance.
    func testUnderReduceMotionSheStillArrivesOnEveryQuestionStep() {
        let view = SetupWizardView(onFinish: {})
        var seen: Set<SetupWizardStep> = []
        while true {
            if bubbleOnScreen(view) != nil { seen.insert(view.model.step) }
            guard !view.model.isLastStep else { break }
            view.advance(reduceMotion: true)
        }
        XCTAssertEqual(seen, Set(PearlIntroScript.steps),
                       "Reduce Motion cost her a bubble on some step")
        XCTAssertEqual(view.reactions.pulse, 0, "precondition: no hearts fired at all")
    }
}

// MARK: - What she says

@MainActor
final class PearlBubbleCopyTests: XCTestCase {

    private var lines: [(step: SetupWizardStep, line: String)] {
        PearlIntroScript.steps.compactMap { step in
            PearlIntroScript.arrival(on: step).map { (step, $0.line) }
        }
    }

    /// Five bubbles, one per question. Dies on: a step being given two, or the
    /// welcome being given one, or a question quietly losing hers.
    func testThereIsExactlyOneBubblePerQuestion() {
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.count, SetupWizardModel.questionCount)
        XCTAssertEqual(Set(lines.map(\.line)).count, 5, "two steps say the same thing")
    }

    /// One or two sentences, and long enough to have said something. Dies on:
    /// a bubble growing into the paragraph the welcome page already has, or
    /// shrinking to a label.
    func testEveryBubbleIsOneOrTwoSentences() {
        for (step, line) in lines {
            let sentences = line.split(whereSeparator: { ".!?".contains($0) })
                .filter { $0.contains(where: \.isLetter) }
            XCTAssertLessThanOrEqual(sentences.count, 2,
                                     "\(step): \(sentences.count) sentences — she is monologuing")
            XCTAssertGreaterThanOrEqual(sentences.count, 1, "\(step) says nothing")
            XCTAssertGreaterThan(line.count, 80, "\(step): too short to explain anything")
            XCTAssertLessThan(line.count, 230, "\(step): too long to read while answering")
        }
    }

    /// It is HER talking, to YOU. Dies on: a bubble being rewritten in the
    /// interface's own disembodied voice, which is the exact failure mode the
    /// masthead subtitles had and the reason they are gone.
    func testEveryBubbleIsInHerVoiceAndAddressedToTheReader() {
        for (step, line) in lines {
            let words = line.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
            XCTAssertTrue(
                words.contains(where: { ["i", "i'll", "i'd", "i'm", "i've", "me", "my"].contains($0) }),
                "\(step) is not in Pearl's voice: \(line)"
            )
            XCTAssertTrue(
                words.contains(where: { ["you", "you'll", "you're", "you've", "your", "yours"].contains($0) }),
                "\(step) does not address the reader: \(line)"
            )
        }
    }

    /// The tells of help text. Dies on: somebody "clarifying" a bubble back
    /// into the sentence a preferences pane would have written.
    func testNoBubbleReadsLikeHelpText() {
        let tells = ["please", "simply", "click here", "you can configure", "preferences",
                     "select an option", "choose your", "below", "this screen", "this step",
                     "settings pane"]
        for (step, line) in lines {
            let lowered = line.lowercased()
            for tell in tells {
                XCTAssertFalse(lowered.contains(tell),
                               "\(step) contains help-text phrasing (\"\(tell)\"): \(line)")
            }
        }
    }

    /// She does not read the question back at you. The masthead is right above
    /// her bubble; repeating it is the sheet saying everything twice, which is
    /// the thing this rework removed.
    func testNoBubbleJustRepeatsTheStepsOwnQuestion() throws {
        let view = SetupWizardView(onFinish: {})
        while !view.model.isLastStep {
            view.advance(reduceMotion: true)
            let arrival = try XCTUnwrap(PearlIntroScript.arrival(on: view.model.step))
            let mastheads = mastheadsOnScreen(view)
            let question = try XCTUnwrap(mastheads.first?.question,
                                         "\(view.model.step) has no question on it")
            XCTAssertFalse(arrival.line.lowercased().contains(question.lowercased()),
                           "\(view.model.step): her bubble reads the question back")
        }
    }

    /// The last bubble is the sign-off as well as the question, because it
    /// replaced a separate sign-off block at the bottom of that step. Dies on:
    /// the goodbye being dropped in a rewrite, which would end the wizard on a
    /// picker.
    func testTheLastBubbleIsAlsoHerGoodbye() throws {
        let last = try XCTUnwrap(PearlIntroScript.arrival(on: .tabLayout))
        XCTAssertEqual(last.pose, .delighted, "she signs off in the same pose she used to")
        XCTAssertTrue(last.line.lowercased().contains("offline page"),
                      "the goodbye lost the offline game, which is a real thing she really is in")
        XCTAssertTrue(last.line.lowercased().contains("last one"),
                      "the last bubble does not say it is the last one")
    }

    /// The grey help line under each question is GONE, and stays gone: her
    /// bubble is the explanation now, and two explanations three inches apart
    /// is the form-with-a-cat-stapled-to-it this rework was written against.
    ///
    /// Dies on: any question step re-growing a masthead subtitle.
    func testTheQuestionStepsCarryNoHelpTextSubtitleAnyMore() {
        let view = SetupWizardView(onFinish: {})
        while !view.model.isLastStep {
            view.advance(reduceMotion: true)
            let mastheads = mastheadsOnScreen(view)
            // Not a vacuous loop: every question step really does have one.
            XCTAssertEqual(mastheads.count, 1, "\(view.model.step) draws no masthead")
            for masthead in mastheads {
                XCTAssertNil(masthead.subtitle,
                             """
                             \(view.model.step) says "\(masthead.subtitle ?? "")" under its question \
                             while Pearl says the same thing above it
                             """)
            }
        }
    }
}

// MARK: - Reading her, on the plate she is drawn on

@MainActor
final class PearlBubbleContrastTests: XCTestCase {

    /// Her line is `.primary` on the bubble's own fill, and that has to clear
    /// the 4.5:1 text floor in both appearances — measured against the live
    /// system colours, the way the rest of the wizard's tone is.
    ///
    /// Dies on: the bubble being tinted with the user's accent (Cherry's
    /// palette runs to yellows), or her line being faded to the supporting
    /// tone, which is for the interface's asides and not for the only voice on
    /// the screen.
    func testHerLineClearsTheTextFloorInsideTheBubble() {
        for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                   ("dark", NSAppearance.Name.darkAqua)] {
            let measured = contrast(
                luminance(of: .labelColor, in: appearance),
                luminance(of: .controlBackgroundColor, in: appearance)
            )
            XCTAssertGreaterThanOrEqual(
                measured, 4.5,
                "Pearl's line measures \(String(format: "%.2f", measured)):1 in the \(name) bubble"
            )
        }
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(of color: NSColor, in appearance: NSAppearance.Name) -> Double {
        var result = 0.0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            func channel(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            result = 0.2126 * channel(Double(srgb.redComponent))
                + 0.7152 * channel(Double(srgb.greenComponent))
                + 0.0722 * channel(Double(srgb.blueComponent))
        }
        return result
    }
}
