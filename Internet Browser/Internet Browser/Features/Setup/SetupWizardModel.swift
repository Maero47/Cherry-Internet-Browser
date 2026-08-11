//
//  SetupWizardModel.swift
//  Cherry Browser
//

import AppKit
import Observation

/// The wizard's steps, in the order the user walks them. The declaration
/// order IS the flow: progress dots, Back/Continue and early finish all
/// derive from `allCases`, so a step exists exactly by having a case here.
///
/// The extensions step sits between Import and Tabs, where the seam that
/// reserved it said it would: everything before it is about Cherry itself,
/// and `extensions` is the first step that reaches outside the app — it
/// downloads and installs real packages. It comes after Import because a user
/// who has just brought their old browser over is in exactly the frame of
/// mind to be asked what they want added to it.
enum SetupWizardStep: String, CaseIterable, Identifiable {
    case welcome
    case appearance
    case searchPrivacy
    case importData
    case extensions
    case tabLayout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .appearance: "Appearance"
        case .searchPrivacy: "Search & Privacy"
        case .importData: "Import"
        case .extensions: "Extensions"
        case .tabLayout: "Tabs"
        }
    }

    var icon: String {
        switch self {
        case .welcome: "hand.wave"
        case .appearance: "paintpalette"
        case .searchPrivacy: "magnifyingglass"
        case .importData: "square.and.arrow.down"
        case .extensions: "puzzlepiece.extension"
        case .tabLayout: "macwindow"
        }
    }
}

/// Where Pearl, Cherry's black-cat mascot, appears on the welcome step.
///
/// The artwork has landed (`Assets.xcassets/PearlHero.imageset`), so the
/// welcome step draws HER — the neutral placeholder that stood in while the
/// two branches were apart is gone, and nothing draws in her place. This one
/// string is still the whole binding between the wizard and the catalog: it is
/// the name the welcome step resolves at render time, so a test that watches
/// the wizard's own view tree produce an image (rather than merely asserting
/// the file exists) fails the moment it stops matching the catalog.
///
/// `PearlHero` and not `PearlHeroYellow`: the cut-out with the alpha channel,
/// because she sits directly on the sheet's own material. The yellow-plate
/// variant carries its own background and would paint a card the sheet did
/// not ask for.
enum PearlMascot {
    static let heroAssetName = "PearlHero"

    /// How tall Pearl is drawn on the welcome step. She is a portrait cut-out
    /// (162 × 320 at 1x), so height is the dimension that decides how much of
    /// the page she owns: at 200pt she is the largest thing on it — the page
    /// reads as her greeting rather than as a form with a picture on it — and
    /// still leaves the title, the paragraph and the footer un-scrolled inside
    /// the sheet's 560pt.
    static let heroHeight: CGFloat = 200

    @MainActor
    static var heroImage: NSImage? { NSImage(named: heroAssetName) }
}

/// Navigation state for the setup wizard, and nothing else.
///
/// Deliberately holds NO copy of any setting: every control in the step views
/// binds straight to `SettingsManager.shared` (or calls its selection
/// methods), exactly as the Settings pane does, so there is no "apply at the
/// end" buffer to drift from the real store — this codebase has twice been
/// hurt by a second definition of the same fact. A test pins this by
/// reflecting over the stored properties.
@MainActor
@Observable
final class SetupWizardModel {
    /// The flow, verbatim from the enum — never a hand-maintained subset, so
    /// a newly added case (the extensions seam) cannot be forgotten here.
    static let steps: [SetupWizardStep] = SetupWizardStep.allCases

    private(set) var stepIndex = 0

    /// Dismisses the sheet. The first-run marker is written by the dismissal
    /// itself (`BrowserViewModel.showSetupWizard.didSet`), not here, so
    /// Finish, Skip Setup and Escape all end first run through one path.
    @ObservationIgnored let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var step: SetupWizardStep { Self.steps[stepIndex] }
    var isFirstStep: Bool { stepIndex == 0 }
    var isLastStep: Bool { stepIndex == Self.steps.count - 1 }

    func advance() {
        if isLastStep {
            finish()
        } else {
            stepIndex += 1
        }
    }

    func goBack() {
        guard !isFirstStep else { return }
        stepIndex -= 1
    }

    /// Finishing early and skipping are the same act — nothing in the wizard
    /// is worth blocking a browser on, so every step offers it.
    func finish() {
        onFinish()
    }
}
