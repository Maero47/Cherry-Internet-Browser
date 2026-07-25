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
}
