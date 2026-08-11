//
//  SetupWizardFirstRunTests.swift
//  Internet BrowserTests
//
//  First-run detection for the setup wizard: shown exactly once, ended for
//  good by finishing OR skipping, surviving relaunch, and failing safe on a
//  corrupt marker. Every test runs against a throwaway defaults suite — the
//  marker in the developer's real defaults is load-bearing (it is what keeps
//  the wizard from re-greeting the owner) and must never be touched.
//

import XCTest
@testable import Cherry

final class SetupWizardFirstRunTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SetupWizardFirstRunTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - The marker

    /// Dies on: `shouldShow` inverting its check, or reading some other
    /// signal ("no bookmarks yet") instead of the explicit marker.
    func testFreshDefaultsMeanFirstRun() {
        XCTAssertTrue(SetupWizardFirstRun.shouldShow(in: defaults))
    }

    /// Dies on: `markSeen` writing nothing, or writing under a different key
    /// than `shouldShow` reads.
    func testMarkSeenEndsFirstRunForGood() {
        SetupWizardFirstRun.markSeen(in: defaults)
        XCTAssertFalse(SetupWizardFirstRun.shouldShow(in: defaults))
    }

    /// Dies on: the marker living in memory (a static Bool) instead of the
    /// defaults store — a fresh handle onto the same suite is this test's
    /// stand-in for a relaunch.
    func testMarkerSurvivesRelaunch() {
        SetupWizardFirstRun.markSeen(in: defaults)
        let relaunched = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(SetupWizardFirstRun.shouldShow(in: relaunched))
    }

    /// A present-but-corrupt marker means "seen", never "show it again": the
    /// wizard must not be able to resurrect for a long-time user whose plist
    /// got hand-edited or half-written. Dies on: `shouldShow` reading the
    /// value as a typed Int (corrupt would read nil and resurrect).
    func testCorruptMarkerFailsSafe() {
        for corrupt: Any in ["yes", true, 3.5, Data([0x01])] {
            defaults.set(corrupt, forKey: SetupWizardFirstRun.seenVersionKey)
            XCTAssertFalse(
                SetupWizardFirstRun.shouldShow(in: defaults),
                "corrupt marker \(corrupt) resurrected the wizard"
            )
        }
    }

    // MARK: - The presentation claim

    private func makePresenter() -> SetupWizardPresenter {
        // The real `shared` refuses to claim inside a test host (that guard
        // is itself deliberate — the test host launches the real app); these
        // presenters switch the guard off to test the claim rules proper.
        SetupWizardPresenter(defaults: defaults, respectsTestHost: false)
    }

    /// Dies on: the claim not consuming itself, so every ⌘N window would
    /// present its own wizard sheet.
    func testClaimIsGrantedOncePerSession() {
        let presenter = makePresenter()
        XCTAssertTrue(presenter.claimPresentation(isPrivate: false))
        XCTAssertFalse(presenter.claimPresentation(isPrivate: false))
    }

    /// Private windows never present the wizard — and a refused private
    /// window must not burn the claim, or a first run started from "New
    /// Incognito Window" would silently spend the wizard on a window that
    /// refuses to show it. Dies on: the `isPrivate` guard being dropped, or
    /// being reordered after the claim is consumed.
    func testPrivateWindowNeverClaimsAndDoesNotBurnTheClaim() {
        let presenter = makePresenter()
        XCTAssertFalse(presenter.claimPresentation(isPrivate: true))
        XCTAssertTrue(presenter.claimPresentation(isPrivate: false))
    }

    /// Dies on: the claim ignoring the marker — the wizard would come back
    /// on every launch.
    func testSeenMarkerBlocksTheClaim() {
        SetupWizardFirstRun.markSeen(in: defaults)
        let presenter = makePresenter()
        XCTAssertFalse(presenter.claimPresentation(isPrivate: false))
    }

    /// The claim itself must NOT write the marker: quitting the app with the
    /// wizard still up is not "seen", and next launch offers it once more.
    /// Dies on: `claimPresentation` calling `markSeen` (or writing the key
    /// any other way).
    func testClaimingAloneDoesNotWriteTheMarker() {
        let presenter = makePresenter()
        _ = presenter.claimPresentation(isPrivate: false)
        XCTAssertTrue(
            SetupWizardFirstRun.shouldShow(in: defaults),
            "claiming wrote the marker — a quit mid-wizard would lose the remaining steps for good"
        )
        // The "relaunch": a fresh presenter over the same store claims again.
        XCTAssertTrue(makePresenter().claimPresentation(isPrivate: false))
    }

    /// Dies on: `markSeen` on the presenter not reaching the store the claim
    /// reads.
    func testPresenterMarkSeenBlocksFutureSessions() {
        let presenter = makePresenter()
        _ = presenter.claimPresentation(isPrivate: false)
        presenter.markSeen()
        XCTAssertFalse(makePresenter().claimPresentation(isPrivate: false))
    }
}
