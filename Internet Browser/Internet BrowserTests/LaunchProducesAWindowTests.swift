//
//  LaunchProducesAWindowTests.swift
//  Internet BrowserTests
//
//  The most basic thing a browser can fail at: starting up and showing
//  nothing.
//
//  1542 tests passed on a tree whose app launched, stayed alive, and never put
//  a window on screen. Every existing launch test calls `openBrowserWindow`
//  itself and checks what comes back — none of them runs the thing that CALLS
//  it. `AppDelegate.applicationDidFinishLaunching` is where the launch window
//  comes from, and it was untested: anything in it that throws, returns early
//  or never reaches `openBrowserWindow` leaves exactly the observed symptom —
//  a live app, idle in its event loop, with nothing to show.
//
//  So this file tests the delegate method itself, and then the state a user
//  would call "the app opened": a window that is visible, has a real window
//  number from the window server, and is registered so the rest of the app can
//  find it.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class LaunchProducesAWindowTests: XCTestCase {

    /// Browser windows this test opened, so it can put the app back the way it
    /// found it. The app under test is the test host, and a window left behind
    /// is a window every later test in the run has to cope with.
    private var opened: [NSWindow] = []

    /// Nothing here ever takes a window it did not open off screen. The test
    /// host IS the app, its launch window is a real one every later test is
    /// laid out against, and hiding it re-lays that content at a geometry it
    /// was never shown at.
    ///
    /// Windows this test opened are CLOSED, not merely ordered out. A window
    /// that is only hidden still exists, still holds a live view model in the
    /// registry, and still turns up in `NSApplication.shared.windows` — and
    /// the launch tests that run after this class walk exactly those. Leaving
    /// five of them behind is what made `LaunchWindowLayoutTests` fail one run
    /// in three while this class was being written.
    override func tearDown() {
        for window in opened {
            window.orderOut(nil)
            BrowserViewModel.detachedWindows.removeAll { $0 === window }
            BrowserViewModel.detachedWindowDelegates.removeAll { $0 === window.delegate }
            window.delegate = nil
            // `close()` on a window built with `init(contentRect:…)` releases
            // it, and this array is still holding one. Closing without this
            // line over-releases the window and takes the test host down a few
            // hundred tests later, which reads as a flaky suite rather than as
            // this file's fault — it did exactly that once while this class was
            // being written.
            window.isReleasedWhenClosed = false
            window.close()
        }
        opened = []
        super.tearDown()
    }

    private func browserWindows() -> [NSWindow] {
        BrowserViewModel.detachedWindows
    }

    /// Let the run loop turn, so anything the launch kicked off asynchronously
    /// — the ad blocker's rules, the extension reload, SwiftUI's first update
    /// pass, a sheet being presented over the new window — has happened before
    /// the window is judged. A launch that puts a window up and loses it one
    /// turn of the run loop later is the same failure as never putting one up.
    private func settle(_ seconds: TimeInterval = 1.5) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A window a user would see: on screen, with a window number the window
    /// server actually issued, and big enough to be a browser.
    private func assertIsAUsableWindow(
        _ window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            window.isVisible,
            "the launch window was created but never ordered on screen",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            window.windowNumber, 0,
            "the launch window has no window-server number, so it has never been shown",
            file: file, line: line
        )
        XCTAssertNotNil(
            window.contentView,
            "the launch window has no content",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(window.frame.width, 400, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.frame.height, 300, file: file, line: line)
        XCTAssertTrue(
            NSScreen.screens.contains { $0.frame.intersects(window.frame) },
            "the launch window is at \(window.frame), which is on no screen",
            file: file, line: line
        )
    }

    // MARK: - The delegate's own launch

    /// **The one this file exists for: the app under test launched, and it has
    /// a window.**
    ///
    /// Nothing is simulated here, and that is the point. The test host IS
    /// Cherry — these tests are injected into the shipping app bundle, which
    /// AppKit launched normally and whose real
    /// `applicationDidFinishLaunching` has already run by the time any test
    /// body executes. So this asserts on the outcome of the app's OWN launch:
    /// a browser window that exists, is on screen, has a window number the
    /// window server issued, and is registered so the rest of the app can
    /// route to it.
    ///
    /// Written this way rather than by calling the delegate method again,
    /// which was the first draft: `applicationDidFinishLaunching` installs
    /// app-global things — the MCP window-lifecycle observation, the extension
    /// reload, two `NotificationCenter` registrations — that a second call
    /// duplicates and no `tearDown` can undo. That draft made
    /// `LaunchWindowLayoutTests` fail. A test for "the app launches" must not
    /// be the reason another test stops trusting the app it launched into.
    ///
    /// Dies on: any path that leaves the app running with no browser window —
    /// `openBrowserWindow` throwing, returning early, or never being reached
    /// because something earlier in the delegate raised (AppKit swallows that
    /// and carries on into the event loop, which is exactly the reported
    /// symptom: a live app, idle, with nothing to show); and on the window
    /// being built but never ordered on screen.
    func testTheAppLaunchedWithAWindowOnScreen() throws {
        let windows = browserWindows()
        XCTAssertFalse(
            windows.isEmpty,
            "the app finished launching with no browser window at all"
        )

        let onScreen = windows.filter(\.isVisible)
        XCTAssertFalse(
            onScreen.isEmpty,
            "the app has \(windows.count) browser window(s) and none of them is on screen — "
                + "a live app showing nothing"
        )
        for window in onScreen {
            assertIsAUsableWindow(window)
        }

        // And the app can find it: a window nothing is registered against
        // takes no commands, no key routing and no reopen.
        XCTAssertTrue(
            BrowserViewModel.windowViewModels.values.contains { model in
                model.associatedWindow.map { $0.isVisible } ?? false
            },
            "no view model is associated with any window that is on screen"
        )
    }

    /// The launch window comes up at the frame Cherry persisted, and a saved
    /// frame that is still on a screen is used rather than ignored. The frame
    /// is applied before the window is shown, which is the ordering
    /// `openBrowserWindow` exists to keep.
    func testTheLaunchWindowUsesThePersistedFrame() throws {
        let key = "cherryBrowserWindowFrame"
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let wanted = NSRect(x: 60, y: 90, width: 1180, height: 860)
        BrowserWindowFrameStore.save(wanted)
        let restored = try XCTUnwrap(
            BrowserWindowFrameStore.restore(),
            "a frame that is on a screen must survive the round trip"
        )

        openBrowserWindow(isPrivate: false, frame: restored)
        let window = try XCTUnwrap(browserWindows().last, "openBrowserWindow produced no window")
        opened.append(window)

        assertIsAUsableWindow(window)
        XCTAssertEqual(window.frame, wanted, "the launch window did not come up at the saved frame")
    }

    /// Every browser window goes through one function, and it has to produce a
    /// shown window whether or not a frame was restored — a fresh install has
    /// no saved frame, and "no window on a fresh install" is the same failure.
    func testEveryWindowPathProducesAShownWindow() throws {
        for isPrivate in [false, true] {
            let before = browserWindows().count
            openBrowserWindow(isPrivate: isPrivate)
            let window = try XCTUnwrap(
                browserWindows().last,
                "openBrowserWindow(isPrivate: \(isPrivate)) produced no window"
            )
            opened.append(window)
            XCTAssertEqual(browserWindows().count, before + 1)
            assertIsAUsableWindow(window)
        }
    }

    /// Becoming the front app must not disturb the window that is already up.
    ///
    /// This is the one launch-path step a headless or locked test machine
    /// never reaches: `applicationDidBecomeActive` re-runs
    /// `configureBrowserWindow` over **every** window the app owns — including
    /// SwiftUI's own sheet and panel windows, which are not browser windows and
    /// are smaller than the browser's `contentMinSize`. A launch that produces
    /// a window and then loses it when the app comes to the front looks
    /// identical, to a user, to a launch that never produced one.
    ///
    /// Dies on: the activation pass ordering a window out, closing it, or
    /// resizing the one the user is looking at.
    func testComingToTheFrontLeavesTheWindowAlone() throws {
        let frame = NSRect(x: 80, y: 100, width: 1120, height: 820)
        openBrowserWindow(isPrivate: false, frame: frame)
        let window = try XCTUnwrap(browserWindows().last)
        opened.append(window)
        XCTAssertTrue(window.isVisible, "precondition: the window came up")

        AppDelegate().applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        )
        settle()

        assertIsAUsableWindow(window)
        XCTAssertEqual(
            window.frame, frame,
            "coming to the front moved or resized the window the user was looking at"
        )
        XCTAssertTrue(
            browserWindows().contains { $0 === window },
            "the activation pass dropped the window out of the registry"
        )
    }

    // MARK: - The way back when there is no window left

    /// The Dock-click recovery path, which is the only way back once every
    /// window is gone — Cherry does not quit with its last window.
    ///
    /// The bug this is written against is not hypothetical: the guard is
    /// `!flag && BrowserViewModel.windowViewModels.isEmpty`, and a browser
    /// window that exists but is not on screen keeps its view model alive. In
    /// that state AppKit says "no visible windows", the registry says "there is
    /// a window", and the handler declines to open one — so an app that has
    /// somehow lost its window on screen can never be brought back, which is
    /// exactly what "open -a again does nothing" means.
    ///
    /// Dies on: the recovery being keyed on the registry alone rather than on
    /// whether any window is actually SHOWING.
    func testReopeningWithNoWindowOnScreenBringsOneBack() throws {
        // One window that exists and is not on screen: the state a stuck
        // launch leaves behind.
        openBrowserWindow(isPrivate: false)
        let stranded = try XCTUnwrap(browserWindows().last)
        opened.append(stranded)
        stranded.orderOut(nil)

        // Made the app's whole idea of "browser windows" for the length of the
        // call, rather than ordering the test host's own launch window off
        // screen to get there. That window is real and every later test in the
        // run is laid out against it; taking it off screen and putting it back
        // re-lays its SwiftUI content at a geometry it was never shown at,
        // which is a hazard this project has been bitten by before — and which
        // this test, in its first form, reintroduced.
        let realWindows = BrowserViewModel.detachedWindows
        BrowserViewModel.detachedWindows = [stranded]
        defer {
            let broughtBack = BrowserViewModel.detachedWindows.filter { window in
                window !== stranded && !realWindows.contains { $0 === window }
            }
            opened.append(contentsOf: broughtBack)
            BrowserViewModel.detachedWindows = realWindows
        }

        XCTAssertFalse(
            browserWindows().contains { $0.isVisible },
            "precondition: no browser window is on screen before the Dock click"
        )
        XCTAssertFalse(
            BrowserViewModel.windowViewModels.isEmpty,
            "precondition: a stranded window's view model is still registered — "
                + "that is what makes this state different from 'all windows closed'"
        )

        let before = browserWindows().count
        let handled = AppDelegate().applicationShouldHandleReopen(
            NSApp, hasVisibleWindows: false
        )

        let after = browserWindows()
        XCTAssertTrue(
            after.contains { $0.isVisible },
            "a Dock click with nothing on screen left the app with nothing on screen "
                + "(handled: \(handled), windows before: \(before), after: \(after.count))"
        )
        if let brought = after.last, brought !== stranded {
            assertIsAUsableWindow(brought)
        }
    }
}
