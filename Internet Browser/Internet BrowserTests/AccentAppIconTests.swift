//
//  AccentAppIconTests.swift
//  Internet BrowserTests
//
//  The accent → Dock-icon asset-name mapping. The artwork itself lands on a
//  separate branch, so these tests cover the name derivation and the
//  fail-safe: an accent whose artwork is absent must resolve to no image
//  (which restores the bundled AppIcon) rather than a blank one.
//

import XCTest
import AppKit
@testable import Cherry

final class AccentAppIconTests: XCTestCase {

    func testNamesTheImageSetForEveryPaletteAccent() {
        let expected: [String: String] = [
            "DB283C": "AppIconAccentDB283C",
            "2563EB": "AppIconAccent2563EB",
            "059669": "AppIconAccent059669",
            "7C3AED": "AppIconAccent7C3AED",
            "EA580C": "AppIconAccentEA580C",
            "DB2777": "AppIconAccentDB2777",
            "0D9488": "AppIconAccent0D9488",
            "6B7280": "AppIconAccent6B7280",
        ]
        for option in AccentColorOption.options {
            XCTAssertEqual(
                AccentAppIcon.imageName(forAccentHex: option.hex),
                expected[option.hex],
                "accent \(option.name)"
            )
        }
        XCTAssertEqual(expected.count, AccentColorOption.options.count)
    }

    func testNormalizesTheHexTheSameWayTheWallpaperLookupDoes() {
        for spelling in ["db283c", "#DB283C", "#db283c", " DB283C "] {
            XCTAssertEqual(
                AccentAppIcon.imageName(forAccentHex: spelling),
                "AppIconAccentDB283C",
                "spelling \(spelling)"
            )
        }
    }

    /// Missing artwork must produce a nil image: assigning nil to
    /// `NSApplication.applicationIconImage` is what restores the bundled icon,
    /// so this is the whole fallback.
    func testAnAccentWithNoArtworkResolvesToNoImage() {
        let name = AccentAppIcon.imageName(forAccentHex: "123456")
        XCTAssertEqual(name, "AppIconAccent123456")
        XCTAssertNil(NSImage(named: name))
    }
}
