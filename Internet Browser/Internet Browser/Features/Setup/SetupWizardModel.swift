//
//  SetupWizardModel.swift
//  Cherry Browser
//

import AppKit
import Observation

/// The wizard's steps, in the order the user walks them. The declaration
/// order IS the flow: the progress rule, the step counter, Back/Continue and
/// early finish all derive from `allCases`, so a step exists exactly by having
/// a case here.
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

    // A per-step SF Symbol used to live here, for the accent-tinted rounded
    // tile at the top of every step. That tile is gone — a coloured square
    // with a glyph in it beside a bold title is the most machine-made shape
    // on a settings-shaped screen, and it said nothing the step's question
    // does not say better. The symbols the cards use are the cards' own.
}

// Pearl herself — her poses, her sizes, her hearts and the one rule about
// when she may react — lives in `Features/Pearl/PearlMascot.swift`. She
// appears on library screens as well as in this wizard now, so a home inside
// Setup would have been the wrong one. `PearlMascot.heroAssetName` and
// `heroImage` still resolve exactly as they did; they now name the waving
// pose rather than the gazing one.

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

    /// How many QUESTIONS the wizard asks — the flow minus the welcome, which
    /// is Pearl saying hello rather than something to answer. The counter on
    /// every step reads against this, so it agrees with the welcome page's own
    /// sentence ("five questions") instead of quietly saying six.
    static var questionCount: Int { steps.count - 1 }

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

    /// How full the rule across the top of the sheet is: empty on the welcome,
    /// full on the last step. Computed, never stored — every one of these is a
    /// view of `stepIndex`, and the model is pinned to hold nothing else.
    var progressFraction: Double {
        guard Self.steps.count > 1 else { return 1 }
        return Double(stepIndex) / Double(Self.steps.count - 1)
    }

    /// Whether the small Pearl belongs in the footer on this step. She is
    /// there for the four question steps in the middle and nowhere else: on
    /// the welcome and on the last step she is already on the page at full
    /// size, and two Pearls at once is a mascot with no idea where it lives.
    var showsFooterCompanion: Bool { !isFirstStep && !isLastStep }

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
