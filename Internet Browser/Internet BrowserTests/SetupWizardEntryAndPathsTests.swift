//
//  SetupWizardEntryAndPathsTests.swift
//  Internet BrowserTests
//
//  The wizard's ENTRY POINTS, pinned — not just its pure decision functions.
//  A perfectly-tested decision behind an unpinned one-line call site can be
//  reverted with every test staying green; these tests exist so that revert
//  dies. Also pinned: that every step writes THROUGH SettingsManager (the
//  same paths as the Settings pane) rather than keeping a copy to drift.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class SetupWizardEntryAndPathsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedPresenter: SetupWizardPresenter!

    override func setUp() {
        super.setUp()
        suiteName = "SetupWizardEntryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Swap in a presenter over a throwaway store, with the test-host
        // guard off, so the real entry points can win a claim in here without
        // ever touching the developer's real first-run marker.
        savedPresenter = SetupWizardPresenter.shared
        SetupWizardPresenter.shared = SetupWizardPresenter(defaults: defaults, respectsTestHost: false)
    }

    override func tearDown() {
        SetupWizardPresenter.shared = savedPresenter
        savedPresenter = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - BrowserViewModel entry

    /// Dies on: `attachSetupWizardIfEligible` not consulting the presenter,
    /// or consulting it and dropping the answer.
    func testFirstWindowViewModelPresentsTheWizard() {
        let vm = BrowserViewModel()
        vm.attachSetupWizardIfEligible()
        XCTAssertTrue(vm.showSetupWizard)
    }

    /// Dies on: the once-per-session claim being bypassed at the view-model
    /// level — every new window would present its own sheet.
    func testSecondWindowDoesNotPresentAgain() {
        let first = BrowserViewModel()
        first.attachSetupWizardIfEligible()
        let second = BrowserViewModel()
        second.attachSetupWizardIfEligible()
        XCTAssertFalse(second.showSetupWizard)
    }

    /// Dies on: `attachSetupWizardIfEligible` ignoring `isPrivateMode`.
    func testPrivateWindowViewModelNeverPresents() {
        let vm = BrowserViewModel()
        vm.isPrivateMode = true
        vm.attachSetupWizardIfEligible()
        XCTAssertFalse(vm.showSetupWizard)
    }

    /// ANY dismissal of the sheet — Finish, Skip Setup, Escape — lands on the
    /// same true→false transition, and that transition writes the marker.
    /// Dies on: the didSet body being removed, which would resurrect the
    /// wizard on every launch.
    func testDismissingTheWizardWritesTheMarker() {
        let vm = BrowserViewModel()
        vm.attachSetupWizardIfEligible()
        XCTAssertTrue(vm.showSetupWizard, "precondition: this window presented the wizard")

        vm.showSetupWizard = false

        XCTAssertFalse(SetupWizardFirstRun.shouldShow(in: defaults))
    }

    /// Writing `false` over `false` must not count as a dismissal: only a
    /// sheet that was actually up can be skipped. Dies on: the didSet losing
    /// its `oldValue` check — any stray write would end first run unseen.
    func testANeverPresentedWindowCannotEndFirstRun() {
        let vm = BrowserViewModel()
        vm.showSetupWizard = false
        XCTAssertTrue(SetupWizardFirstRun.shouldShow(in: defaults))
    }

    /// Quitting mid-wizard: the sheet was up, never dismissed. The marker
    /// must be absent — next launch offers the wizard once more — and the
    /// session must be replayable without corruption. Dies on: the marker
    /// being written at claim/presentation time.
    func testQuittingMidWizardLeavesTheMarkerSaneAndTheWizardReofferable() {
        let vm = BrowserViewModel()
        vm.attachSetupWizardIfEligible()
        XCTAssertTrue(vm.showSetupWizard, "precondition: the wizard was up when the app quit")

        // No dismissal — the process ends here. "Relaunch":
        let nextLaunch = SetupWizardPresenter(defaults: defaults, respectsTestHost: false)
        XCTAssertTrue(SetupWizardFirstRun.shouldShow(in: defaults))
        XCTAssertTrue(nextLaunch.claimPresentation(isPrivate: false))
    }

    // MARK: - BrowserView entry

    /// The one-line call in `BrowserView.init`, pinned by constructing the
    /// real view. Dies on: that call being removed — the decision logic
    /// would stay perfect and perfectly unreachable.
    func testBrowserViewInitAttachesTheWizard() throws {
        let view = BrowserView(isPrivate: false, presentsSetupWizardIfFirstRun: true)
        let vm = try XCTUnwrap(viewModel(of: view))
        XCTAssertTrue(vm.showSetupWizard)
    }

    /// The `WindowGroup` scene builds a `BrowserView()` that is never
    /// presented; it must not consume the session's one claim. Dies on:
    /// `presentsSetupWizardIfFirstRun` defaulting to true (or the flag being
    /// ignored) — the wizard would be spent on a window nobody sees.
    func testSceneStyleBrowserViewDoesNotConsumeTheClaim() throws {
        let sceneView = BrowserView()
        let sceneVM = try XCTUnwrap(viewModel(of: sceneView))
        XCTAssertFalse(sceneVM.showSetupWizard)
        XCTAssertFalse(SetupWizardPresenter.shared.hasClaimedThisSession)

        // The claim is still there for the window that IS presented.
        let presented = BrowserView(isPrivate: false, presentsSetupWizardIfFirstRun: true)
        let presentedVM = try XCTUnwrap(viewModel(of: presented))
        XCTAssertTrue(presentedVM.showSetupWizard)
    }

    /// The outermost entry point: `openBrowserWindow` itself, the function
    /// every real browser window is born through. Dies on: it no longer
    /// passing `presentsSetupWizardIfFirstRun: true` into `BrowserView`.
    func testOpenBrowserWindowOffersTheWizard() {
        openBrowserWindow(isPrivate: false)
        defer { BrowserViewModel.detachedWindows.last?.close() }
        XCTAssertTrue(SetupWizardPresenter.shared.hasClaimedThisSession)
    }

    /// And its private variant must not: ⇧⌘N on a fresh install spends
    /// nothing. Dies on: `openBrowserWindow` hardcoding `isPrivate: false`
    /// into the BrowserView it builds.
    func testOpenPrivateBrowserWindowDoesNotOfferTheWizard() {
        openBrowserWindow(isPrivate: true)
        defer { BrowserViewModel.detachedWindows.last?.close() }
        XCTAssertFalse(SetupWizardPresenter.shared.hasClaimedThisSession)
    }

    private func viewModel(of view: BrowserView) -> BrowserViewModel? {
        Mirror(reflecting: view).children
            .first { $0.label == "_viewModel" }
            .flatMap { $0.value as? State<BrowserViewModel> }?
            .wrappedValue
    }

    // MARK: - Same settings, same paths

    /// The wizard's navigation model holds NO copy of any setting — every
    /// control binds straight to `SettingsManager.shared`, so there is no
    /// buffered "apply at the end" state to drift from the real store. Dies
    /// on: anyone giving the model a settings property (the
    /// parallel-source-of-truth failure this codebase has met twice).
    func testWizardModelHoldsNoSettingsState() {
        let model = SetupWizardModel(onFinish: {})
        let allowed: Set<String> = ["_stepIndex", "onFinish", "_$observationRegistrar"]
        for label in Mirror(reflecting: model).children.compactMap(\.label) {
            XCTAssertTrue(
                allowed.contains(label),
                "SetupWizardModel grew stored state '\(label)' — settings must live in SettingsManager only"
            )
        }
    }

    /// The wizard's import step drives the same `BrowserImportService` the
    /// Settings ▸ Import pane runs — detection, readers and repository writes
    /// included. Dies on: the step growing its own import path.
    func testImportStepDrivesTheSharedImportService() {
        let step = SetupImportStep()
        let holdsService = Mirror(reflecting: step).children.contains {
            String(describing: type(of: $0.value)).contains("BrowserImportService")
        }
        XCTAssertTrue(holdsService)
    }

    /// The flow: welcome first, then the four decisions, in order — and the
    /// model's list IS `allCases`, so the parallel extensions step joins the
    /// flow by existing (the seam cannot be forgotten in a second list).
    /// Dies on: a hand-maintained steps array diverging from the enum, or
    /// the steps reordering.
    func testWizardStepsCoverTheFourDecisionsInOrder() {
        let steps = SetupWizardModel.steps
        XCTAssertEqual(steps, SetupWizardStep.allCases)
        XCTAssertEqual(steps.first, .welcome)

        let decisions: [SetupWizardStep] = [.appearance, .searchPrivacy, .importData, .tabLayout]
        let positions = decisions.compactMap { steps.firstIndex(of: $0) }
        XCTAssertEqual(positions.count, decisions.count, "a decision step is missing from the flow")
        XCTAssertEqual(positions, positions.sorted(), "the decision steps changed order")
    }

    /// Skippable at every step, finishable early, and Back never underflows.
    /// Dies on: `advance` skipping a step, `goBack` underflowing from the
    /// first step, or the last step's advance not finishing.
    func testWizardNavigationIsBoundedAndFinishable() {
        var finished = 0
        let model = SetupWizardModel(onFinish: { finished += 1 })

        model.goBack()
        XCTAssertEqual(model.stepIndex, 0, "Back from the first step must stay put")

        // Finishable early from the middle of the flow.
        model.advance()
        model.finish()
        XCTAssertEqual(finished, 1)

        // Walking off the end finishes rather than crashing.
        while !model.isLastStep { model.advance() }
        model.advance()
        XCTAssertEqual(finished, 2)
    }
}

/// The four decisions write the SAME `SettingsManager` the Settings pane
/// writes — for the multi-property homepage-background rules, literally the
/// same methods (`selectAutoHomepageBackground` & co., which the pane's
/// swatches now call too). These run against the real singleton, so every
/// touched value is pinned in setUp and restored in tearDown, matching
/// `PrivacySettingsBehaviourTests`.
@MainActor
final class SetupWizardSettingsPathTests: XCTestCase {

    private var savedTheme: HomepageTheme = .cherry
    private var savedMatchesAccent = true
    private var savedUsesThemeBackground = true
    private var savedUsesCustomImage = false

    override func setUp() {
        super.setUp()
        let settings = SettingsManager.shared
        savedTheme = settings.homepageTheme
        savedMatchesAccent = settings.homepageMatchesAccent
        savedUsesThemeBackground = settings.homepageUsesThemeBackground
        savedUsesCustomImage = settings.homepageUsesCustomImage
    }

    override func tearDown() {
        let settings = SettingsManager.shared
        settings.homepageTheme = savedTheme
        settings.homepageMatchesAccent = savedMatchesAccent
        settings.homepageUsesThemeBackground = savedUsesThemeBackground
        settings.homepageUsesCustomImage = savedUsesCustomImage
        super.tearDown()
    }

    /// Dies on: any of Auto's three writes being dropped — the lock-out bug
    /// (a stronger source outranking "Auto" forever) would be back.
    func testSelectAutoClearsEveryOutrankingSource() {
        let settings = SettingsManager.shared
        settings.homepageMatchesAccent = false
        settings.homepageUsesThemeBackground = true
        settings.homepageUsesCustomImage = true

        settings.selectAutoHomepageBackground()

        XCTAssertTrue(settings.homepageMatchesAccent)
        XCTAssertFalse(settings.homepageUsesThemeBackground)
        XCTAssertFalse(settings.homepageUsesCustomImage)
        // And the resolved source agrees: Auto paints from the accent.
        switch settings.homepageBackgroundSource(isPrivate: false) {
        case .accentWallpaper, .accentGradient: break
        case let other: XCTFail("Auto resolved to \(other)")
        }
    }

    /// Dies on: the theme write or any of the three clears being dropped
    /// from `selectCuratedHomepageTheme`.
    func testSelectCuratedThemeWinsImmediately() {
        let settings = SettingsManager.shared
        settings.homepageMatchesAccent = true
        settings.homepageUsesThemeBackground = true
        settings.homepageUsesCustomImage = true

        settings.selectCuratedHomepageTheme(.ocean)

        XCTAssertEqual(settings.homepageTheme, .ocean)
        XCTAssertFalse(settings.homepageMatchesAccent)
        XCTAssertFalse(settings.homepageUsesThemeBackground)
        XCTAssertFalse(settings.homepageUsesCustomImage)
        XCTAssertEqual(settings.homepageBackgroundSource(isPrivate: false), .curatedTheme(.ocean))
    }

    /// Dies on: `selectThemeHomepageBackground` no longer clearing the
    /// custom-image preference — the picture would keep outranking the theme
    /// the user just picked.
    func testSelectThemeBackgroundTakesOverFromTheCustomImage() {
        let settings = SettingsManager.shared
        settings.homepageUsesCustomImage = true

        settings.selectThemeHomepageBackground()

        XCTAssertTrue(settings.homepageUsesThemeBackground)
        XCTAssertFalse(settings.homepageUsesCustomImage)
    }

    /// Dies on: `selectCustomImageHomepageBackground` not setting the
    /// preference (or clearing state it has no business clearing — "Auto"
    /// must be exactly what it was if the picture is later removed).
    func testSelectCustomImageSetsOnlyItsOwnPreference() {
        let settings = SettingsManager.shared
        settings.homepageUsesCustomImage = false
        let matchesAccentBefore = settings.homepageMatchesAccent

        settings.selectCustomImageHomepageBackground()

        XCTAssertTrue(settings.homepageUsesCustomImage)
        XCTAssertEqual(settings.homepageMatchesAccent, matchesAccentBefore)
    }
}
