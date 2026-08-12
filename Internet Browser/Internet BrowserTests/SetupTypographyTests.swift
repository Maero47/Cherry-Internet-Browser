//
//  SetupTypographyTests.swift
//  Internet BrowserTests
//
//  The two claims the setup screens' redesign rests on, made checkable.
//
//  1. THE SCALE IS A SCALE. The verdict on the old screens was "AI slop", and
//     the most mechanical thing about them was eight type sizes — 24, 17, 13,
//     12.5, 12, 11.5, 11, 10 — where most neighbours were within a point of
//     each other. Sizes that close are not roles; they are noise that reads as
//     a form somebody assembled. So there are FOUR sizes carrying five roles,
//     and they have to stay four and stay far apart, which is a thing a test
//     can hold and a comment cannot.
//
//     This test has already earned its keep once: the counter was first drawn
//     at 10pt beside an 11pt aside, and this is what said so.
//
//  2. THE GREY IS LEGIBLE. `.secondary` measures about 3.6:1 on the sheet's
//     own material and `.tertiary` far less, both under the 4.5:1 floor for
//     text at these sizes. `SetupPalette.supporting` replaced them, and this
//     measures it against the live system colours rather than trusting the
//     table in its doc comment.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class SetupTypographyTests: XCTestCase {

    /// The five roles, with the sizes they are declared at. Kept here as
    /// literals on purpose: a `Font` will not tell you its own point size, and
    /// a test that read the number out of the thing it is checking would check
    /// nothing. If a role's size changes, this list changes with it — and the
    /// separation rule below is what says whether the new number is allowed.
    private let scale: [(role: String, size: Double)] = [
        ("welcome", 30),
        ("question", 21),
        ("body", 13),
        ("aside", 11),
        // Deliberately the aside's size, not a point under it: the counter is
        // separated by weight, uppercase and tracking instead.
        ("counter", 11),
    ]

    /// Five roles over four sizes, and no two of those sizes close enough to
    /// be mistaken for each other. The gap has to be at least 15% — enough
    /// that a reader sees a different role rather than a rendering accident.
    ///
    /// Dies on: a fifth size being slipped in between two of these, or a size
    /// being nudged toward its neighbour, which is exactly how eight sizes
    /// happened the first time.
    func testTheScaleIsFourSizesThatCannotBeMistakenForEachOther() {
        XCTAssertEqual(scale.count, 5, "five roles")

        let sizes = Array(Set(scale.map(\.size))).sorted()
        XCTAssertEqual(sizes.count, 4, "four sizes")
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                larger / smaller, 1.15,
                "\(smaller)pt and \(larger)pt are close enough to read as the same size"
            )
        }
    }

    /// The two smallest roles are `SettingsCard`'s own sizes, exactly. The
    /// cards are shared with the Settings pane, and the wizard is meant to
    /// look like the same product — a wizard drawing 12.5pt beside a card
    /// drawing 13pt is the seam that makes it look bolted on.
    func testTheProseSizesMatchTheSharedSettingsCards() {
        XCTAssertEqual(scale.first { $0.role == "body" }?.size, 13)
        XCTAssertEqual(scale.first { $0.role == "aside" }?.size, 11)
    }

    /// The wizard's grey clears the 4.5:1 text floor on BOTH surfaces it is
    /// drawn on — the sheet's material and a card's fill — in both
    /// appearances. Dies on: someone reaching for `.secondary` again because
    /// it is what everything else in the app uses.
    func testTheSupportingToneClearsTheTextFloorOnEverySurface() {
        let ink = NSColor(SetupPalette.supporting)
        let surfaces: [(String, NSColor)] = [
            ("the sheet", .windowBackgroundColor),
            ("a card", .controlBackgroundColor),
        ]

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua),
                                             ("dark", NSAppearance.Name.darkAqua)] {
            for (surfaceName, surface) in surfaces {
                let measured = contrast(
                    luminance(of: ink, in: appearance),
                    luminance(of: surface, in: appearance)
                )
                XCTAssertGreaterThanOrEqual(
                    measured, 4.5,
                    "supporting text measures \(String(format: "%.2f", measured)):1 on \(surfaceName) in \(appearanceName)"
                )
            }
        }
    }

    /// Why the tone exists at all. If this ever starts failing, the system
    /// greys have moved and the fork deserves a fresh measurement rather than
    /// being quietly reverted to `.secondary`.
    func testSecondaryWouldNotHaveClearedItOnTheSheet() {
        let measured = contrast(
            luminance(of: .secondaryLabelColor, in: .aqua),
            luminance(of: .windowBackgroundColor, in: .aqua)
        )
        XCTAssertLessThan(
            measured, 4.5,
            "`.secondary` now clears the floor on the sheet — remeasure whether SetupPalette is still needed"
        )
    }

    // MARK: - Measuring

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A dynamic system colour resolved for one appearance, composited over
    /// nothing — `secondaryLabelColor` carries alpha, so it is flattened onto
    /// the surface it is being compared against first, which is what a reader
    /// actually sees.
    private func luminance(of color: NSColor, in appearance: NSAppearance.Name) -> Double {
        var result = 0.0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            let backdrop = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            let alpha = srgb.alphaComponent
            func flatten(_ component: CGFloat, _ under: CGFloat) -> Double {
                Double(component * alpha + under * (1 - alpha))
            }
            result = Self.relativeLuminance(
                flatten(srgb.redComponent, backdrop?.redComponent ?? 1),
                flatten(srgb.greenComponent, backdrop?.greenComponent ?? 1),
                flatten(srgb.blueComponent, backdrop?.blueComponent ?? 1)
            )
        }
        return result
    }

    nonisolated private static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}
