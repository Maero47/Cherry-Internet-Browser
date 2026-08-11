//
//  SetupWizardFirstRun.swift
//  Cherry Browser
//

import Foundation

/// The explicit first-run marker behind the setup wizard.
///
/// "First run" is exactly one fact: this key has never been written. Not "no
/// bookmarks yet", not "settings are still defaults" — both describe states a
/// long-time user can be in, and a wizard keyed on either would resurrect for
/// them. The key is written once, when the wizard is finished or skipped
/// (`BrowserViewModel.showSetupWizard`'s didSet is the single write site via
/// `SetupWizardPresenter.markSeen`), and nothing in the app ever removes it.
///
/// A present-but-corrupt value (a string, a bool — a hand-edited plist) still
/// counts as seen: `shouldShow` asks only whether ANY object exists under the
/// key. Failing safe here means never showing the wizard to someone who has
/// already been through it; showing it again to a user who tampered with their
/// own defaults would be the worse wrong.
///
/// The value written is a version, not a bare flag, so a future wizard that
/// gains material new steps can choose to re-offer just those — the seam costs
/// nothing today because `shouldShow` deliberately ignores the number.
enum SetupWizardFirstRun {
    static let seenVersionKey = "setupWizardSeenVersion"
    static let currentVersion = 1

    /// True only while nothing has ever been stored under the key. Any stored
    /// object — current version, older version, corrupt junk — means the
    /// wizard has had its one showing.
    static func shouldShow(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: seenVersionKey) == nil
    }

    static func markSeen(in defaults: UserDefaults) {
        defaults.set(currentVersion, forKey: seenVersionKey)
    }
}

/// Decides which window, if any, gets to present the setup wizard.
///
/// One claim per app session: the first non-private browser window built by
/// `openBrowserWindow` on a first run wins it, every later window (⌘N while
/// the sheet is still up, a second launch window after Dock reopen) is
/// refused. The claim deliberately does NOT write the first-run marker —
/// the marker records "finished or skipped", so a user who quits the app
/// mid-wizard is offered it again next launch instead of losing the remaining
/// steps to a crash or a reflexive ⌘Q. They are not trapped either way:
/// every step is skippable in one click, and dismissing the sheet by any
/// means writes the marker for good.
///
/// Private windows never claim. The launch window is never private, so this
/// only comes up for a first-ever run started from "New Incognito Window" —
/// and a wizard that writes persistent, app-wide configuration is the
/// opposite of what opening a private window asks for. Private windows also
/// refuse theming (`HomepageBackgroundResolver`), so the appearance step
/// would be previewing choices the window it sits on refuses to show.
///
/// The test-host guard exists because the unit-test host launches the real
/// app through the real `openBrowserWindow` path: without it, a test run on
/// a machine whose defaults lack the marker would present a sheet over the
/// launch window that the window-geometry tests are measuring. Tests that
/// exercise the claim itself construct their own presenter with the guard
/// off and swap it into `shared`.
final class SetupWizardPresenter {
    static var shared = SetupWizardPresenter()

    /// Whether this process is hosting XCTest. The environment variables are
    /// the load-bearing half: Xcode sets them on the host process from exec,
    /// so they are visible however early this runs — whereas
    /// `NSClassFromString("XCTestCase")` only answers true once the XCTest
    /// dylib is actually loaded, which on some runner configurations happens
    /// AFTER `applicationDidFinishLaunching` has already opened the launch
    /// window. A guard that depends on that timing presents the wizard over
    /// the launch window on exactly the machines where the dylib comes late,
    /// which is how the geometry tests regressed on one machine while
    /// passing on another.
    private static let isTestHost: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private let defaults: UserDefaults
    private let respectsTestHost: Bool
    private(set) var hasClaimedThisSession = false

    init(defaults: UserDefaults = .standard, respectsTestHost: Bool = true) {
        self.defaults = defaults
        self.respectsTestHost = respectsTestHost
    }

    /// Whether the asking window should present the wizard. True at most once
    /// per session, and only for a non-private window on a true first run.
    func claimPresentation(isPrivate: Bool) -> Bool {
        if respectsTestHost && Self.isTestHost { return false }
        guard !isPrivate,
              !hasClaimedThisSession,
              SetupWizardFirstRun.shouldShow(in: defaults)
        else { return false }
        hasClaimedThisSession = true
        return true
    }

    /// Ends first run for good — called from the one dismissal choke point,
    /// whatever dismissed the sheet (Finish, Skip Setup, Escape).
    func markSeen() {
        SetupWizardFirstRun.markSeen(in: defaults)
    }
}
