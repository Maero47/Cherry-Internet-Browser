//
//  PearlPresenceTests.swift
//  Internet BrowserTests
//
//  Where Pearl is, and — just as much of the point — where she is not.
//
//  "A mascot everywhere is wallpaper; a mascot somewhere is a character" is a
//  design claim, and a design claim that nothing checks is a design claim that
//  lasts until the next person thinks a screen looks a bit bare. So the
//  absences are tested as hard as the appearances: the search-found-nothing
//  library state must NOT have her, and the wizard must not put two of her on
//  screen at once.
//
//  Nothing here renders pixels. It walks the same SwiftUI value trees
//  `SetupWizardPearlAndExtensionsTests` walks, and asks what the views are
//  actually made of.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

/// Every value of type `T` inside a SwiftUI view value, however deep — the
/// codebase's established way of asking what a view is made of.
private func collectValues<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collectValues(type, in: $0.value, depth: depth + 1)
    }
}

// MARK: - The artwork

@MainActor
final class PearlPoseTests: XCTestCase {

    /// Every pose resolves by name out of the shipped catalog. Dies on: an
    /// imageset that was drawn but never added, a renamed folder, a
    /// `Contents.json` that names files that are not beside it.
    func testEveryPoseResolvesByNameAtRuntime() {
        for pose in PearlMascot.Pose.allCases {
            let image = NSImage(named: pose.assetName)
            XCTAssertNotNil(image, "pose \(pose) names an imageset the catalog does not have")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, "\(pose) has no width")
            XCTAssertGreaterThan(image?.size.height ?? 0, 0, "\(pose) has no height")
        }
    }

    /// They are five different drawings, not one asset wired up five times.
    /// Dies on: a pose being pointed at another pose's imageset while the
    /// screens quietly all show the same cat.
    func testThePosesAreDistinctDrawings() {
        let names = Set(PearlMascot.Pose.allCases.map(\.assetName))
        XCTAssertEqual(names.count, PearlMascot.Pose.allCases.count,
                       "two poses name the same imageset")

        let sizes = PearlMascot.Pose.allCases.compactMap { NSImage(named: $0.assetName)?.size }
        XCTAssertEqual(sizes.count, PearlMascot.Pose.allCases.count)
    }

    /// The pose she arrives in is a SEPARATE, squarer drawing and not the hero
    /// re-used. On the question steps she sits BESIDE a speech bubble, and the
    /// hero's raised paw and long tail make a tall narrow silhouette that eats
    /// the bubble's width for the same height of cat.
    /// Dies on: `.sitting` being repointed at a portrait asset.
    func testTheArrivalPoseIsDrawnSquarerThanTheHeroPortrait() throws {
        let sitting = try XCTUnwrap(NSImage(named: PearlMascot.Pose.sitting.assetName))
        let waving = try XCTUnwrap(NSImage(named: PearlMascot.Pose.waving.assetName))

        let sittingRatio = sitting.size.width / sitting.size.height
        let wavingRatio = waving.size.width / waving.size.height
        XCTAssertGreaterThan(sittingRatio, wavingRatio,
                             "the arrival pose is no squarer than the hero — it will crowd her bubble")
        XCTAssertGreaterThan(sittingRatio, 0.4)
    }

    /// The sleeping pose is landscape, because it sits above two lines of
    /// centred text on a wide empty window rather than beside anything.
    func testTheRestingPoseIsWiderThanItIsTall() throws {
        let curled = try XCTUnwrap(NSImage(named: PearlMascot.Pose.curled.assetName))
        XCTAssertGreaterThan(curled.size.width, curled.size.height)
    }

    /// The sizes she is drawn at are a hierarchy, not three numbers: she leads
    /// the welcome, arrives smaller on a question step, and rests smaller
    /// still on an empty library screen. Dies on: the hero shrinking into an
    /// icon, or her arrival shrinking back toward the 34pt footer companion it
    /// replaced — which is the size at which she stopped being looked at and
    /// her hearts stopped being seen.
    func testHerDrawnSizesAreAHierarchy() {
        XCTAssertGreaterThan(PearlMascot.heroHeight, PearlMascot.introHeight)
        XCTAssertGreaterThan(PearlMascot.introHeight, PearlMascot.restingHeight)

        XCTAssertGreaterThanOrEqual(PearlMascot.heroHeight, 180,
                                    "at this size Pearl is decoration, not the welcome")
        XCTAssertLessThanOrEqual(PearlMascot.heroHeight, 260,
                                 "taller than this and the welcome page has to scroll")
        XCTAssertGreaterThanOrEqual(PearlMascot.introHeight, 100,
                                    "she was asked to come up BIG; this is a footer companion again")
        XCTAssertLessThanOrEqual(PearlMascot.introHeight, 150,
                                 "any taller and the step's first card starts below the fold")
    }
}

// MARK: - In the wizard

@MainActor
final class PearlInTheWizardTests: XCTestCase {

    /// The welcome page shows the WAVING pose specifically. Dies on: the page
    /// falling back to the gazing hero, which is a beautiful drawing of a cat
    /// looking away from you and therefore the wrong one for an introduction.
    func testTheWelcomePageShowsHerWaving() throws {
        let step = try XCTUnwrap(
            collectValues(SetupWelcomeStep.self, in: SetupWizardView(onFinish: {}).body).first,
            "the wizard's first page is not the welcome step"
        )
        let portrait = try XCTUnwrap(
            collectValues(PearlPortrait.self, in: step.body).first,
            "the welcome page draws no Pearl at all"
        )
        XCTAssertEqual(portrait.pose, .waving)
        XCTAssertEqual(portrait.height, PearlMascot.heroHeight)
    }

    /// Never two of her on one screen. She arrives on every question step and
    /// is deliberately silent on the welcome, where she already IS the page at
    /// 196pt — a speech bubble there is her talking over herself.
    ///
    /// Dies on: the welcome growing a bubble; a question step losing its
    /// arrival; the retired footer companion being reinstated alongside the
    /// arrival, which would put a small Pearl and a large Pearl on the same
    /// step.
    func testSheArrivesOnEveryQuestionStepAndNeverOnTheWelcome() throws {
        XCTAssertNil(PearlIntroScript.arrival(on: .welcome),
                     "she is the welcome page; she does not also stand on it with a bubble")

        for step in SetupWizardModel.steps where step != .welcome {
            XCTAssertNotNil(PearlIntroScript.arrival(on: step),
                            "\(step) gets no arrival from Pearl")
        }
        XCTAssertEqual(PearlIntroScript.steps.count, SetupWizardModel.questionCount,
                       "one bubble per question, no more and no fewer")

        // And the real wizard puts exactly one of her on a question step.
        let view = SetupWizardView(onFinish: {})
        view.advance(reduceMotion: true)
        let tree = view.body
        // One hop through her arrival: a `Mirror` walk stops at a child view's
        // boundary, and she is inside `PearlIntro` now rather than inline in
        // the wizard's footer.
        let pearls = collectValues(PearlPortrait.self, in: tree)
            + collectValues(PearlIntro.self, in: tree)
                .flatMap { collectValues(PearlPortrait.self, in: $0.body) }
        XCTAssertEqual(pearls.count, 1,
                       "a question step draws a number of Pearls that is not one")
        XCTAssertEqual(pearls.first?.height, PearlMascot.introHeight)
    }

    /// The counter counts QUESTIONS, so it agrees with the welcome page's own
    /// promise of five rather than quietly saying six. Dies on: the counter
    /// being derived from `steps.count`.
    func testTheWizardCountsFiveQuestionsAndNotSixSteps() {
        XCTAssertEqual(SetupWizardModel.questionCount, 5)
        XCTAssertEqual(SetupWizardModel.steps.count, 6, "precondition: welcome plus five")
    }

    /// The rule across the top is empty on the welcome and full on the last
    /// step, and never runs backwards. Dies on: an off-by-one that leaves it
    /// short of the end, which is the one place a progress indicator is
    /// actually noticed.
    func testTheProgressRuleStartsEmptyAndEndsFull() {
        let model = SetupWizardModel(onFinish: {})
        XCTAssertEqual(model.progressFraction, 0, accuracy: 0.0001)

        var previous = model.progressFraction
        while !model.isLastStep {
            model.advance()
            XCTAssertGreaterThan(model.progressFraction, previous)
            previous = model.progressFraction
        }
        XCTAssertEqual(model.progressFraction, 1, accuracy: 0.0001)
    }
}

// MARK: - On the library screens

@MainActor
final class PearlOnLibraryScreensTests: XCTestCase {

    private func untouched() -> LibraryEmptyState {
        LibraryEmptyState(icon: "bookmark", headline: "No bookmarks yet",
                          detail: "…", isUntouched: true)
    }

    private func noResults() -> LibraryEmptyState {
        LibraryEmptyState(icon: "magnifyingglass", headline: "No bookmarks match that search",
                          detail: "…")
    }

    /// "You have none of these yet" gets Pearl, asleep, INSTEAD of the outline
    /// glyph — she replaces something rather than being added beside it, which
    /// is why she costs the screen nothing.
    func testTheNothingYetStateSleepsHerThereInsteadOfAGlyph() {
        let body = LibraryEmptyView(state: untouched()).body
        let portraits = collectValues(PearlPortrait.self, in: body)

        XCTAssertEqual(portraits.count, 1, "the untouched library screen has no Pearl on it")
        XCTAssertEqual(portraits.first?.pose, .curled)
        XCTAssertEqual(collectValues(NSImage.self, in: body).count, 1,
                       "her image did not resolve out of the catalog on this screen")
    }

    /// And the search that matched nothing does NOT. The user is looking for
    /// something specific and has just been told it isn't here; a curled up
    /// cat in the middle of that is the mascot being cute at somebody who is
    /// trying to work.
    ///
    /// Dies on: someone deciding the empty view "should just always show her".
    func testASearchThatMatchedNothingHasNoPearlOnIt() {
        let body = LibraryEmptyView(state: noResults()).body
        XCTAssertTrue(collectValues(PearlPortrait.self, in: body).isEmpty,
                      "Pearl turned up on a failed search")
        XCTAssertTrue(collectValues(NSImage.self, in: body).isEmpty,
                      "an image resolved on the no-results screen")
    }

    /// The real screens, not a fixture: each library screen must mark exactly
    /// one of its two empty states as untouched, and it must not be the search
    /// one. Dies on: a screen forgetting the flag (no Pearl anywhere) or
    /// putting it on both (Pearl on failed searches).
    func testEveryLibraryScreenMarksItsOwnUntouchedStateAndOnlyThat() throws {
        let screens: [(String, Any)] = [
            ("Bookmarks", BookmarksSidebarView(repository: .shared, onBookmarkClick: { _ in }).body),
            ("History", HistoryView(repository: .shared, onItemClick: { _ in }).body),
        ]

        for (name, body) in screens {
            let states = collectValues(LibraryEmptyState.self, in: body)
            XCTAssertEqual(states.count, 2, "\(name) does not carry two empty states")

            let searchState = try XCTUnwrap(states.first { $0.icon == "magnifyingglass" },
                                            "\(name) has no no-results state")
            let firstRunState = try XCTUnwrap(states.first { $0.icon != "magnifyingglass" },
                                              "\(name) has no nothing-yet state")

            XCTAssertFalse(searchState.isUntouched,
                           "\(name) would put Pearl on a search that matched nothing")
            XCTAssertTrue(firstRunState.isUntouched,
                          "\(name)'s empty screen is still just a glyph and two grey lines")
        }
    }
}
