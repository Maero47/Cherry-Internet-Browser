//
//  AppTerminationPolicyTests.swift
//  Internet BrowserTests
//
//  Locks the "should closing this window quit the app?" policy.
//
//  The bug this guards against is a data-loss bug: the original check was
//  `NSApp.windows.filter(\.isVisible).isEmpty`, and `NSWindow.isVisible` is
//  FALSE for a window the user minimised to the Dock. Closing the last tab of
//  window A therefore terminated the app while window B sat minimised with all
//  its tabs open.
//
//  The first attempt at a fix used `NSWindow.canBecomeMain` as the "is this a
//  real browser window" test, which was wrong in the same way: AppKit's default
//  implementation returns true only while the window is VISIBLE, so a minimised
//  window that doesn't override it — the app's first window, from the SwiftUI
//  WindowGroup — still reported "gone". `testDefaultCanBecomeMainIsVisibilityCoupled`
//  pins that AppKit behaviour so the mistake can't come back.
//

import XCTest
import AppKit
@testable import Cherry

final class AppTerminationPolicyTests: XCTestCase {

    private typealias Window = TabManager.WindowLiveness

    /// An ordinary browser window on screen.
    private func onScreen() -> Window {
        Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: false)
    }

    /// A browser window the user minimised to the Dock — still holds its tabs.
    /// These are the values AppKit really reports in that state: not visible,
    /// miniaturized, titled, not a panel.
    private func minimized() -> Window {
        Window(isVisible: false, isMiniaturized: true, isTitled: true, isPanel: false)
    }

    /// A window that has been closed (or was never shown).
    private func closed() -> Window {
        Window(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false)
    }

    /// A helper window: the tear-off ghost, the hover preview, the off-screen
    /// research host. All borderless, so never titled.
    private func helper(isVisible: Bool) -> Window {
        Window(isVisible: isVisible, isMiniaturized: false, isTitled: false, isPanel: false)
    }

    /// A save/print/alert panel or system popover.
    private func panel() -> Window {
        Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: true)
    }

    // MARK: - The regression

    func testMinimizedWindowKeepsAppAlive() {
        // Window A just closed; window B is minimised with open tabs.
        XCTAssertFalse(TabManager.shouldTerminateApp(windows: [closed(), minimized()]))
    }

    func testMinimizedWindowIsNotVisible_soVisibilityAloneWouldHaveQuit() {
        // Trap 1 of 2: documents exactly why the original predicate was wrong.
        XCTAssertFalse(minimized().isVisible)
        XCTAssertTrue(minimized().keepsAppAlive(appIsHidden: false))
    }

    func testHiddenAppWindowsAreNotVisibleEither_theSameTrapAgain() {
        // Trap 2 of 2: `NSWindow.isVisible` is false for EVERY window while the
        // application is hidden (Cmd+H), not just for minimised ones. A tab
        // closed from a non-UI path while hidden would otherwise read as "the
        // last window closed" and terminate the app with every hidden window's
        // tabs still open.
        let hiddenAppWindow = onScreen()   // an ordinary window, but the app is hidden
        XCTAssertFalse(
            Window(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false)
                .keepsAppAlive(appIsHidden: false),
            "with the app visible, these values mean the window is closed"
        )
        XCTAssertTrue(
            Window(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false)
                .keepsAppAlive(appIsHidden: true),
            "with the app hidden, the same values mean the window is merely hidden"
        )
        XCTAssertTrue(hiddenAppWindow.keepsAppAlive(appIsHidden: true))
    }

    func testHiddenAppWithNoWindowsAtAllStillQuits() {
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: [], appIsHidden: true))
    }

    func testHiddenAppWithOnlyHelperWindowsStillQuits() {
        XCTAssertTrue(
            TabManager.shouldTerminateApp(windows: [helper(isVisible: false)], appIsHidden: true)
        )
    }

    // MARK: - The just-closed window must not vote

    /// Closing a window does not remove it from `NSApp.windows` — every browser
    /// window sets `isReleasedWhenClosed = false`. While the app is hidden its
    /// corpse is indistinguishable from a merely-hidden window, so unless the
    /// caller excludes it, closing the LAST window while hidden would find
    /// itself in the list and leave the app resident with nothing open.

    @MainActor
    private func makeBrowserLikeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    func testTheJustClosedWindowIsExcludedFromTheSnapshot() {
        let closing = makeBrowserLikeWindow()
        let other = makeBrowserLikeWindow()
        let snapshot = TabManager.livenessSnapshot(of: [closing, other], excluding: closing)
        XCTAssertEqual(snapshot.count, 1)
    }

    @MainActor
    func testClosingTheLastWindowWhileHiddenQuits() {
        // The residue this closes: with the closed window filtered out, nothing
        // is left to keep the app alive, hidden or not.
        let closing = makeBrowserLikeWindow()
        let snapshot = TabManager.livenessSnapshot(of: [closing], excluding: closing)
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: snapshot, appIsHidden: true))
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: snapshot, appIsHidden: false))
    }

    @MainActor
    func testClosingOneWindowWhileHiddenKeepsTheOtherAlive() {
        // The data-loss case, still protected: the surviving window reports
        // `isVisible == false` only because the app is hidden.
        let closing = makeBrowserLikeWindow()
        let survivor = makeBrowserLikeWindow()
        let snapshot = TabManager.livenessSnapshot(of: [closing, survivor], excluding: closing)
        XCTAssertFalse(snapshot[0].isVisible, "hidden app: not visible, not minimised")
        XCTAssertFalse(snapshot[0].isMiniaturized)
        XCTAssertFalse(TabManager.shouldTerminateApp(windows: snapshot, appIsHidden: true))
    }

    @MainActor
    func testExcludingNothingLeavesTheListIntact() {
        let window = makeBrowserLikeWindow()
        XCTAssertEqual(TabManager.livenessSnapshot(of: [window], excluding: nil).count, 1)
    }

    @MainActor
    func testDefaultCanBecomeMainIsVisibilityCoupled() {
        // Why the policy must not key off `canBecomeMain`: AppKit's default
        // implementation requires visibility, which is precisely what a
        // minimised window lacks. A plain titled window — what the SwiftUI
        // WindowGroup produces, and what `DetachedWindow` overrides away from —
        // reports false the moment it is off screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.canBecomeMain, "AppKit couples canBecomeMain to visibility")

        // The properties the policy actually reads survive being off screen.
        let liveness = Window(window)
        XCTAssertTrue(liveness.isTitled)
        XCTAssertFalse(liveness.isPanel)
    }

    @MainActor
    func testAPlainMinimizedWindowKeepsAppAlive() {
        // The exact repro: a plain (non-overriding) window, minimised. Built
        // from the real NSWindow's structural properties, with only the
        // miniaturized flag stated — so it cannot certify a state AppKit can't
        // report, the way the first version of this test did.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let asMinimized = Window(
            isVisible: false,
            isMiniaturized: true,
            isTitled: window.styleMask.contains(.titled),
            isPanel: window is NSPanel
        )
        XCTAssertFalse(TabManager.shouldTerminateApp(windows: [closed(), asMinimized]))
    }

    // MARK: - Quitting still works

    func testQuitsWhenTheLastWindowCloses() {
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: [closed()]))
    }

    func testQuitsWithNoWindowsAtAll() {
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: []))
    }

    func testQuitsWhenOnlyHelperWindowsRemain() {
        // A visible tear-off ghost / hover preview must not hold the app open.
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: [closed(), helper(isVisible: true)]))
    }

    func testQuitsWhenOnlyAPanelRemains() {
        XCTAssertTrue(TabManager.shouldTerminateApp(windows: [closed(), panel()]))
    }

    // MARK: - Ordinary cases

    func testAnotherOnScreenWindowKeepsAppAlive() {
        XCTAssertFalse(TabManager.shouldTerminateApp(windows: [closed(), onScreen()]))
    }

    func testMixOfMinimizedAndHelperWindowsKeepsAppAlive() {
        XCTAssertFalse(
            TabManager.shouldTerminateApp(
                windows: [closed(), helper(isVisible: true), panel(), minimized()]
            )
        )
    }
}
