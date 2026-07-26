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
}
