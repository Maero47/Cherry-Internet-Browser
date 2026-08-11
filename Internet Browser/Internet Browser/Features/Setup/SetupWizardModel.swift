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
/// SEAM — extensions step: a short list of recommended extensions is being
/// built on a parallel branch. To land it, add `case extensions` in flow
/// order (between `importData` and `tabLayout` was the plan), give it a
/// `title`/`icon` below, and add its view to `SetupWizardView.stepContent`.
/// That switch is exhaustive over this enum, so the compiler walks the merge
/// through every site that needs the new step — nothing else changes.
enum SetupWizardStep: String, CaseIterable, Identifiable {
    case welcome
    case appearance
    case searchPrivacy
    case importData
    case tabLayout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .appearance: "Appearance"
        case .searchPrivacy: "Search & Privacy"
        case .importData: "Import"
        case .tabLayout: "Tabs"
        }
    }

    var icon: String {
        switch self {
        case .welcome: "hand.wave"
        case .appearance: "paintpalette"
        case .searchPrivacy: "magnifyingglass"
        case .importData: "square.and.arrow.down"
        case .tabLayout: "macwindow"
        }
    }
}

/// Where Pearl, Cherry's black-cat mascot, appears on the welcome step.
///
/// Her painterly hero image is being drawn on a parallel branch and lands in
/// `Assets.xcassets` under this name. Until the asset exists `heroImage`
/// resolves nil and the welcome step shows a neutral placeholder — so the two
/// branches merge without either touching the other's files. If the artwork
/// arrives under a different name, this one string is the whole fix.
enum PearlMascot {
    static let heroAssetName = "PearlHero"

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
