//
//  MCPIndicatorContrastTests.swift
//  Internet BrowserTests
//
//  The toolbar indicator is the only thing that tells the user an outside
//  program is reading their browser, and it draws over a backdrop nobody can
//  measure in advance: `.bar`, an imported Firefox theme's `toolbarColor`, or a
//  header backdrop image. A tinted glyph there has no contrast floor at all.
//
//  The fix is a badge: the glyph sits on an opaque accent fill, and its tone is
//  chosen against that fill. This measures the choice against every accent the
//  app actually ships, rather than trusting the sentence in the header comment.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

final class MCPIndicatorContrastTests: XCTestCase {

    /// WCAG AA for body-size text. The glyph is smaller and bolder than body
    /// text, so this is the strict reading of the floor, not a lenient one.
    private let floor = 4.5

    // MARK: - The badge

    func testTheIndicatorGlyphClearsTheFloorOnEveryShippedAccent() {
        var worst = (name: "", ratio: Double.infinity)

        for option in AccentColorOption.options {
            let accent = NSColor(option.color)
            let glyph = MCPStatusPalette.readableForeground(on: accent)
            let ratio = MCPStatusPalette.contrastRatio(glyph, accent)

            XCTAssertGreaterThanOrEqual(
                ratio, floor,
                "\(option.name) (#\(option.hex)) puts the indicator glyph at \(ratio):1 on its own badge"
            )
            if ratio < worst.ratio { worst = (option.name, ratio) }
        }

        // Recorded so a future accent that quietly lowers the worst case shows
        // up as a number in the diff rather than as nothing at all.
        XCTAssertGreaterThanOrEqual(worst.ratio, floor, "worst accent is \(worst.name)")
    }

    /// The choice must actually be the better of the two, not a fixed guess
    /// that happens to work for most of the palette.
    func testTheGlyphToneIsAlwaysTheHigherContrastOfTheTwo() {
        let ink = MCPStatusPalette.ink
        let white = NSColor.white

        for option in AccentColorOption.options {
            let accent = NSColor(option.color)
            let chosen = MCPStatusPalette.readableForeground(on: accent)
            let best = max(
                MCPStatusPalette.contrastRatio(white, accent),
                MCPStatusPalette.contrastRatio(ink, accent)
            )
            XCTAssertEqual(
                MCPStatusPalette.contrastRatio(chosen, accent), best, accuracy: 0.0001,
                option.name
            )
        }
    }

    func testTheGlyphFlipsToneAcrossTheLightnessRange() {
        let onBlack = MCPStatusPalette.readableForeground(on: NSColor.black)
        let onWhite = MCPStatusPalette.readableForeground(on: NSColor.white)
        XCTAssertEqual(MCPStatusPalette.relativeLuminance(onBlack), 1.0, accuracy: 0.001)
        XCTAssertLessThan(MCPStatusPalette.relativeLuminance(onWhite), 0.05)
    }

    // MARK: - The arithmetic itself

    /// If the luminance formula is wrong, every number this file reports is
    /// wrong in the same direction and the tests still pass. These are the
    /// fixed points of WCAG 2.x.
    func testRelativeLuminanceMatchesTheWCAGFixedPoints() {
        XCTAssertEqual(MCPStatusPalette.relativeLuminance(.white), 1.0, accuracy: 0.001)
        XCTAssertEqual(MCPStatusPalette.relativeLuminance(.black), 0.0, accuracy: 0.001)
        XCTAssertEqual(
            MCPStatusPalette.contrastRatio(.white, .black), 21.0, accuracy: 0.01,
            "black on white is 21:1 by definition"
        )
    }

    /// Symmetric for opaque colours, which is what the badge and the pane's own
    /// palette are.
    func testContrastRatioIsSymmetricForOpaqueColours() {
        for option in AccentColorOption.options {
            let accent = NSColor(option.color)
            XCTAssertEqual(
                MCPStatusPalette.contrastRatio(.white, accent),
                MCPStatusPalette.contrastRatio(accent, .white),
                accuracy: 0.0001,
                option.name
            )
        }
    }

    /// The measurement has to composite, or every translucent colour reports
    /// the contrast of its underlying opaque tone. `secondaryLabelColor` is
    /// black at half alpha: read raw it looks like 21:1, drawn it is 3.95:1.
    func testATranslucentColourIsMeasuredAsItIsActuallyDrawn() {
        let halfBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
        let composited = MCPStatusPalette.composite(halfBlack, over: .white)

        XCTAssertEqual(Double(composited.alphaComponent), 1.0, accuracy: 0.001)
        XCTAssertEqual(Double(composited.redComponent), 0.5, accuracy: 0.01)
        XCTAssertEqual(
            MCPStatusPalette.contrastRatio(halfBlack, .white), 3.95, accuracy: 0.05,
            "half-alpha black on white draws as mid grey, not as black"
        )
    }

    func testCompositingAnOpaqueColourChangesNothing() {
        for option in AccentColorOption.options {
            let accent = NSColor(option.color)
            let composited = MCPStatusPalette.composite(accent, over: .white)
            XCTAssertEqual(
                MCPStatusPalette.relativeLuminance(composited),
                MCPStatusPalette.relativeLuminance(accent),
                accuracy: 0.0001,
                option.name
            )
        }
    }

    // MARK: - The pane's own three colours

    /// The pane's surface is `SettingsCard`'s fill. These are the numbers the
    /// palette's header comment claims; measured here so the comment cannot
    /// drift away from the colours.
    func testThePaneColoursClearTheFloorInBothAppearances() {
        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua),
        ]

        for (label, name) in appearances {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("no \(label) appearance")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let surface = NSColor.controlBackgroundColor
                let colours: [(String, Color)] = [
                    ("failure", MCPStatusPalette.failure),
                    ("serving", MCPStatusPalette.serving),
                    ("supporting", MCPStatusPalette.supporting),
                ]
                for (role, colour) in colours {
                    let ratio = MCPStatusPalette.contrastRatio(NSColor(colour), surface)
                    XCTAssertGreaterThanOrEqual(
                        ratio, floor,
                        "\(role) is \(ratio):1 on the card surface in \(label) mode"
                    )
                }

                // The reason this palette exists at all: the obvious system
                // choices fail. If a future macOS makes them pass, the palette
                // is no longer earning its keep and this should be revisited.
                if label == "light" {
                    XCTAssertLessThan(
                        MCPStatusPalette.contrastRatio(.secondaryLabelColor, surface), floor,
                        "secondaryLabelColor now clears the floor in light mode"
                    )
                    XCTAssertLessThan(
                        MCPStatusPalette.contrastRatio(.systemRed, surface), floor,
                        "systemRed now clears the floor in light mode"
                    )
                }
            }
        }
    }
}
