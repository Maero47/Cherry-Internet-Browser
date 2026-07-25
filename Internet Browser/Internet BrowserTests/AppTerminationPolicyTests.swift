//
//  AppTerminationPolicyTests.swift
//  Internet BrowserTests
//
//  Locks the "should closing this window quit the app?" policy.
//
//  The bug this guards against was a data-loss bug: the old check was
//  `NSApp.windows.filter(\.isVisible).isEmpty`, and `NSWindow.isVisible` is
//  FALSE for a window the user minimised to the Dock. Closing the last tab of
//  window A therefore terminated the app while window B sat minimised with all
//  its tabs open. A minimised window must keep the app alive; the app must
//  still quit when the genuinely last window closes.
//

import XCTest
@testable import Cherry

final class AppTerminationPolicyTests: XCTestCase {

    private typealias Window = TabManager.WindowLiveness

    /// An ordinary browser window on screen.
    private func onScreen() -> Window {
        Window(isVisible: true, isMiniaturized: false, canBecomeMain: true)
    }

    /// A browser window the user minimised to the Dock — still holds its tabs.
    private func minimized() -> Window {
        Window(isVisible: false, isMiniaturized: true, canBecomeMain: true)
    }

    /// A window that has been closed (or was never shown).
    private func closed() -> Window {
        Window(isVisible: false, isMiniaturized: false, canBecomeMain: true)
    }

    /// A helper window: the tear-off ghost, the hover preview, the off-screen
    /// research host, a panel or a popover. Never keeps the app alive.
    private func helper(isVisible: Bool) -> Window {
        Window(isVisible: isVisible, isMiniaturized: false, canBecomeMain: false)
    }

    // MARK: - The regression

    func testMinimizedWindowKeepsAppAlive() {
        // Window A just closed; window B is minimised with open tabs.
        XCTAssertFalse(TabManager.shouldTerminateApp(windows: [closed(), minimized()]))
    }

    func testMinimizedWindowIsNotVisible_soVisibilityAloneWouldHaveQuit() {
        // Documents exactly why the old predicate was wrong.
        XCTAssertFalse(minimized().isVisible)
        XCTAssertTrue(minimized().keepsAppAlive)
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

    // MARK: - Ordinary cases

    func testAnotherOnScreenWindowKeepsAppAlive() {
        XCTAssertFalse(TabManager.shouldTerminateApp(windows: [closed(), onScreen()]))
    }

    func testMixOfMinimizedAndHelperWindowsKeepsAppAlive() {
        XCTAssertFalse(
            TabManager.shouldTerminateApp(
                windows: [closed(), helper(isVisible: true), minimized()]
            )
        )
    }
}
