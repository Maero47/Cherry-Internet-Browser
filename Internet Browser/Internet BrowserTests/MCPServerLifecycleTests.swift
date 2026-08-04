//
//  MCPServerLifecycleTests.swift
//  Internet BrowserTests
//
//  Locks "should the MCP listener be bound right now?".
//
//  The bug this guards against is a privacy bug, and it shipped: closing
//  Cherry's window with its close button does NOT quit Cherry. The termination
//  policy is only consulted on the last-TAB path, and nothing implements
//  `applicationShouldTerminateAfterLastWindowClosed` — so the process stayed
//  alive with zero windows, the listener stayed bound to 127.0.0.1:8787, and
//  `search_bookmarks` kept returning real bookmarks. With no window there is
//  also no navigation bar, so the connection indicator could not exist, let
//  alone warn anyone.
//
//  The fix is one predicate, and the point of these tests is that it is not a
//  NEW predicate: `MCPServerManager.shouldServe` is the enabled flag ANDed with
//  the inverse of `TabManager.shouldTerminateApp`. The four traps in "does
//  Cherry still have a window" (minimised windows aren't `isVisible`, NO window
//  is `isVisible` while the app is hidden, panels and borderless helpers don't
//  count, a closed window is still in `NSApp.windows`) are answered once, over
//  in `AppTerminationPolicyTests`. `testServesExactlyWhenTheAppWouldNotQuit`
//  below is the one that pins the two together, so a second definition growing
//  here fails a test rather than drifting quietly.
//

import XCTest
import AppKit
@testable import Cherry

final class MCPServerLifecycleTests: XCTestCase {

    private typealias Window = TabManager.WindowLiveness

    /// An ordinary browser window on screen.
    private func onScreen() -> Window {
        Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: false)
    }

    /// A browser window the user minimised to the Dock — still holds its tabs.
    private func minimized() -> Window {
        Window(isVisible: false, isMiniaturized: true, isTitled: true, isPanel: false)
    }

    /// A closed window, which lingers in `NSApp.windows` with these values.
    /// Identical to the values a merely-hidden window reports, which is why the
    /// snapshot has to exclude the closing window explicitly.
    private func closed() -> Window {
        Window(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false)
    }

    /// A save/print/alert panel or system popover.
    private func panel() -> Window {
        Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: true)
    }

    /// The tab-drag ghost, the hover preview, the off-screen research host:
    /// borderless, so never titled.
    private func helper(isVisible: Bool) -> Window {
        Window(isVisible: isVisible, isMiniaturized: false, isTitled: false, isPanel: false)
    }

    private func shouldServe(
        enabled: Bool = true,
        _ windows: [Window],
        appIsHidden: Bool = false
    ) -> Bool {
        MCPServerManager.shouldServe(enabled: enabled, windows: windows, appIsHidden: appIsHidden)
    }

    // MARK: - The defect

    func testDoesNotServeWithNoWindowsAtAll() {
        // The reproduction, reduced: enabled, running, and nothing on screen.
        // Before the fix this state served history and bookmarks indefinitely.
        XCTAssertFalse(shouldServe([]))
    }

    func testDoesNotServeWhenOnlyTheClosedWindowRemains() {
        // What `NSApp.windows` really looks like the moment the last window
        // closes, if the caller forgets to exclude it: one entry, not visible,
        // not minimised. It must not hold the socket open.
        XCTAssertFalse(shouldServe([closed()]))
    }

    func testServesWithAWindowOnScreen() {
        XCTAssertTrue(shouldServe([onScreen()]))
    }

    // MARK: - The states a hand-rolled predicate would get wrong

    func testServesWhenTheOnlyWindowIsMinimised() {
        // A minimised window reports `isVisible == false`. Cherry is still a
        // browser with the user's tabs in it, the indicator still exists in
        // that window's toolbar, and the app is not quitting — so the server
        // stays up. Anything that keys off visibility alone kills it here.
        XCTAssertFalse(minimized().isVisible)
        XCTAssertTrue(shouldServe([minimized()]))
    }

    func testServesWhileTheAppIsHidden() {
        // ⌘H makes EVERY window report `isVisible == false`. Same rule as the
        // termination policy: hidden is not closed.
        XCTAssertTrue(shouldServe([onScreen()], appIsHidden: true))
        XCTAssertTrue(
            shouldServe([Window(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false)],
                        appIsHidden: true)
        )
    }

    func testDoesNotServeWhenOnlyAPanelIsLeft() {
        // A save sheet or a system popover is not a browser window, has no
        // toolbar, and must not be the reason the user's history is readable.
        XCTAssertFalse(shouldServe([panel()]))
        XCTAssertFalse(shouldServe([closed(), panel()]))
    }

    func testDoesNotServeWhenOnlyHelperWindowsAreLeft() {
        XCTAssertFalse(shouldServe([helper(isVisible: true)]))
        XCTAssertFalse(shouldServe([closed(), helper(isVisible: true)]))
    }

    func testDoesNotServeWithOnlyHelpersWhileHidden() {
        XCTAssertFalse(shouldServe([helper(isVisible: false)], appIsHidden: true))
    }

    func testOneRealWindowAmongHelpersAndPanelsStillServes() {
        XCTAssertTrue(shouldServe([closed(), helper(isVisible: true), panel(), minimized()]))
    }

    // MARK: - The switch still wins

    func testNeverServesWhileTheFeatureIsOff() {
        // Windows do not enable anything. Off is off, in every window state.
        for windows in [[onScreen()], [minimized()], [panel()], []] {
            XCTAssertFalse(shouldServe(enabled: false, windows))
            XCTAssertFalse(shouldServe(enabled: false, windows, appIsHidden: true))
        }
    }

    // MARK: - One definition, not two

    func testServesExactlyWhenTheAppWouldNotQuit() {
        // The whole reuse argument, as an assertion: for every window shape and
        // both hidden states, "serve" is "enabled, and this is not a state the
        // termination policy calls the end of the app". If someone re-derives
        // the window rule inside `MCPServerManager`, this is what catches it.
        let shapes: [[Window]] = [
            [],
            [closed()],
            [onScreen()],
            [minimized()],
            [panel()],
            [helper(isVisible: true)],
            [closed(), minimized()],
            [closed(), panel(), helper(isVisible: false)],
            [onScreen(), minimized(), panel()],
        ]
        for windows in shapes {
            for appIsHidden in [false, true] {
                let wouldQuit = TabManager.shouldTerminateApp(windows: windows, appIsHidden: appIsHidden)
                XCTAssertEqual(
                    MCPServerManager.shouldServe(enabled: true, windows: windows, appIsHidden: appIsHidden),
                    !wouldQuit,
                    "serve must be the exact inverse of the termination policy (hidden: \(appIsHidden))"
                )
                XCTAssertFalse(
                    MCPServerManager.shouldServe(enabled: false, windows: windows, appIsHidden: appIsHidden)
                )
            }
        }
    }

    // MARK: - The closing window must not vote

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
    func testClosingTheLastWindowStopsServing() {
        // `willCloseNotification` fires while the window is still in
        // `NSApp.windows`, which is the entire reason `livenessSnapshot` takes
        // `excluding:`. This is the end-to-end shape of the fix, minus AppKit.
        let closing = makeBrowserLikeWindow()
        let snapshot = TabManager.livenessSnapshot(of: [closing], excluding: closing)
        XCTAssertFalse(
            MCPServerManager.shouldServe(enabled: true, windows: snapshot, appIsHidden: false)
        )
        XCTAssertFalse(
            MCPServerManager.shouldServe(enabled: true, windows: snapshot, appIsHidden: true),
            "a hidden app with its last window closed has no window either"
        )
    }

    @MainActor
    func testClosingOneWindowOfTwoKeepsServing() {
        // The survivor here is off screen — an unshown `NSWindow` reports the
        // same values a window of a hidden app does — so this is the hidden-app
        // case, and the one that would lose the server if the closing window's
        // exclusion were the only thing keeping the count right.
        let closing = makeBrowserLikeWindow()
        let survivor = makeBrowserLikeWindow()
        let snapshot = TabManager.livenessSnapshot(of: [closing, survivor], excluding: closing)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(
            MCPServerManager.shouldServe(enabled: true, windows: snapshot, appIsHidden: true)
        )
    }
}
