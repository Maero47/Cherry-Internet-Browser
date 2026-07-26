//
//  BrowserCommandTests.swift
//  Internet BrowserTests
//
//  The command system's invariants. Menus and key equivalents can't be
//  exercised headlessly, so what's tested here is everything the routing
//  depends on: unique identities, a lossless round trip through the
//  notification, and the Cmd+1…9 index mapping.
//

import XCTest
import AppKit
@testable import Cherry

final class BrowserCommandTests: XCTestCase {

    func testRawValuesAreUnique() {
        let rawValues = BrowserCommand.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(rawValues).count,
            rawValues.count,
            "Two commands share a raw value, so one would run the other's action"
        )
    }

    func testRoundTripsThroughItsNotification() {
        for command in BrowserCommand.allCases {
            let notification = Notification(
                name: .browserCommand,
                object: nil,
                userInfo: ["command": command.rawValue]
            )
            XCTAssertEqual(BrowserCommand(notification: notification), command)
        }
    }

    func testIgnoresNotificationsWithNoOrUnknownCommand() {
        let empty = Notification(name: .browserCommand, object: nil, userInfo: nil)
        XCTAssertNil(BrowserCommand(notification: empty))

        let unknown = Notification(
            name: .browserCommand,
            object: nil,
            userInfo: ["command": "notARealCommand"]
        )
        XCTAssertNil(BrowserCommand(notification: unknown))
    }

    func testTabIndexIsSetOnlyForTabSelectionCommands() {
        for index in 1...9 {
            let command = BrowserCommand(rawValue: "selectTab\(index)")
            XCTAssertEqual(command?.tabIndex, index, "selectTab\(index) should map to index \(index)")
        }

        let nonTabCommands = BrowserCommand.allCases.filter { !$0.rawValue.hasPrefix("selectTab") }
        for command in nonTabCommands {
            XCTAssertNil(command.tabIndex, "\(command.rawValue) is not a tab-selection command")
        }
    }

    /// The menu builds Cmd+1…Cmd+9 by looking up `selectTab<n>` by raw value —
    /// if a case were ever renamed, those nine menu items would silently vanish.
    func testEveryTabSelectionCommandIsReachableByRawValue() {
        let byRawValue = (1...9).compactMap { BrowserCommand(rawValue: "selectTab\($0)") }
        XCTAssertEqual(byRawValue.count, 9)
    }

    // MARK: - Key-window routing
    //
    // Commands are broadcast to every window, so this predicate is the only
    // thing keeping a command from running in all of them at once.

    @MainActor
    func testRunsOnlyInTheKeyWindow() {
        let key = NSWindow()
        let other = NSWindow()

        XCTAssertTrue(CommandRouting.shouldRun(in: key, keyWindow: key))
        XCTAssertFalse(CommandRouting.shouldRun(in: other, keyWindow: key))
    }

    /// The bug this predicate exists to avoid: `nil === nil` is **true** in
    /// Swift, so the obvious `window === NSApp.keyWindow` spelling passes when
    /// the app has no key window and the view model isn't registered yet —
    /// running the command in a window that is explicitly not key, and in every
    /// such window if more than one exists.
    @MainActor
    func testFailsClosedWhenEitherWindowIsMissing() {
        let window = NSWindow()

        XCTAssertFalse(
            CommandRouting.shouldRun(in: nil, keyWindow: nil),
            "an unregistered window with no key window must NOT run commands"
        )
        XCTAssertFalse(CommandRouting.shouldRun(in: nil, keyWindow: window))
        XCTAssertFalse(CommandRouting.shouldRun(in: window, keyWindow: nil))
    }

    /// Two unregistered windows must not BOTH pass — the multi-window failure
    /// the nil-equality bug produced.
    @MainActor
    func testTwoUnregisteredWindowsBothFail() {
        let candidates: [NSWindow?] = [nil, nil]
        let passing = candidates.filter { CommandRouting.shouldRun(in: $0, keyWindow: nil) }
        XCTAssertTrue(passing.isEmpty)
    }

    // MARK: - "Key window, else the first" targeting
    //
    // Used where something has to land SOMEWHERE (an extension opening a tab,
    // a Settings link opening in Cherry) rather than being dropped.

    /// A stand-in for the view models the real call sites pass.
    private struct WindowHolder {
        let name: String
        let window: NSWindow?
    }

    @MainActor
    func testPrefersTheKeyWindowsCandidate() {
        let first = NSWindow()
        let key = NSWindow()
        let candidates = [
            WindowHolder(name: "first", window: first),
            WindowHolder(name: "key", window: key)
        ]

        let picked = CommandRouting.preferringKeyWindow(
            candidates, keyWindow: key, window: { $0.window }
        )
        XCTAssertEqual(picked?.name, "key")
    }

    @MainActor
    func testFallsBackToTheFirstCandidateWhenNoneIsKey() {
        let candidates = [
            WindowHolder(name: "first", window: NSWindow()),
            WindowHolder(name: "second", window: NSWindow())
        ]

        let picked = CommandRouting.preferringKeyWindow(
            candidates, keyWindow: NSWindow(), window: { $0.window }
        )
        XCTAssertEqual(picked?.name, "first")
    }

    /// The residue fixed in round 2: hand-written as
    /// `first { $0.window === keyWindow } ?? first`, this returned the
    /// UNREGISTERED candidate — `nil === nil` is true — instead of falling
    /// through to the deterministic first one.
    @MainActor
    func testAnUnregisteredCandidateIsNotMistakenForTheKeyWindow() {
        let candidates = [
            WindowHolder(name: "registered-first", window: NSWindow()),
            WindowHolder(name: "unregistered", window: nil)
        ]

        let picked = CommandRouting.preferringKeyWindow(
            candidates, keyWindow: nil, window: { $0.window }
        )
        XCTAssertEqual(
            picked?.name,
            "registered-first",
            "with no key window the fallback must be the first candidate, not the nil-windowed one"
        )
    }

    @MainActor
    func testNoCandidatesYieldsNil() {
        let picked = CommandRouting.preferringKeyWindow(
            [WindowHolder](), keyWindow: NSWindow(), window: { $0.window }
        )
        XCTAssertNil(picked)
    }
}
