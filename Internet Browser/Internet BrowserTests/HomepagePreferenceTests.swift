//
//  HomepagePreferenceTests.swift
//  Internet BrowserTests
//
//  Address resolution for the new General ▸ Homepage field — the reader that
//  `SettingsManager.homepage` never had.
//

import XCTest
@testable import Cherry

final class HomepagePreferenceTests: XCTestCase {

    func testAcceptsFullURLs() {
        XCTAssertEqual(
            HomepagePreference.resolve("https://www.apple.com")?.absoluteString,
            "https://www.apple.com"
        )
        XCTAssertEqual(
            HomepagePreference.resolve("http://example.com/start?a=b")?.absoluteString,
            "http://example.com/start?a=b"
        )
    }

    func testUpgradesABareHostToHTTPS() {
        XCTAssertEqual(
            HomepagePreference.resolve("example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            HomepagePreference.resolve("example.com/path")?.absoluteString,
            "https://example.com/path"
        )
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            HomepagePreference.resolve("  example.com \n")?.absoluteString,
            "https://example.com"
        )
    }

    /// A half-typed or unusable homepage resolves to nil, which `goHome`
    /// treats as "show the new tab page" — Home can never end up broken.
    func testRejectsInputThatWouldNotLoad() {
        XCTAssertNil(HomepagePreference.resolve(""))
        XCTAssertNil(HomepagePreference.resolve("   "))
        XCTAssertNil(HomepagePreference.resolve("https://"))
    }

    /// Home is already Cherry's new-tab page, so an internal page can't be the
    /// custom homepage — and neither can anything that isn't the web.
    func testRejectsNonWebSchemes() {
        XCTAssertNil(HomepagePreference.resolve("cherry://settings"))
        XCTAssertNil(HomepagePreference.resolve("file:///etc/passwd"))
        XCTAssertNil(HomepagePreference.resolve("javascript://alert(1)"))
    }
}
