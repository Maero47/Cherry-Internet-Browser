//
//  ThemeToolbarGlyphTests.swift
//  Internet BrowserTests
//
//  A Firefox theme names ONE `toolbar_text` and the format has no way to vary
//  it by appearance. A theme authored against dark chrome therefore hands a
//  light glyph to a light toolbar, and the contrast guard — behaving exactly as
//  designed — asks for a dark plate under it. The result was an action cluster
//  that read as a dark island punched in a pale bar.
//
//  The fix decides the pair at the glyph, because the plate is chosen FROM the
//  glyph. These pin that decision, and pin that the plate follows.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class ThemeToolbarGlyphTests: XCTestCase {

    private let lightGlyph = Color(red: 0.98, green: 0.98, blue: 0.96)  // a dark-chrome theme
    private let darkGlyph = Color(red: 0.11, green: 0.10, blue: 0.13)   // a light-chrome theme

    // MARK: - The island

    /// The reported bug: a light glyph on a light bar. The theme's tone is
    /// dropped rather than kept, because keeping it is what produced the island.
    func testALightThemeGlyphIsNotUsedInLightAppearance() {
        let resolved = ThemeContrast.toolbarGlyph(themeText: lightGlyph, appearance: .light)
        XCTAssertEqual(resolved, ThemeContrast.barGlyphOnLight)
    }

    /// The mirror of the same bug, which the old code had too: a dark-chrome
    /// theme's opposite number would have put a light plate in a dark bar.
    func testADarkThemeGlyphIsNotUsedInDarkAppearance() {
        let resolved = ThemeContrast.toolbarGlyph(themeText: darkGlyph, appearance: .dark)
        XCTAssertEqual(resolved, ThemeContrast.barGlyphOnDark)
    }

    // MARK: - The theme keeps what it can

    /// A theme's tone is not thrown away for its own sake. Whenever it suits
    /// the appearance it is exactly what gets drawn, which is the common case
    /// and the reason a theme names one at all.
    func testAThemeToneIsKeptWhenItSuitsTheAppearance() {
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(themeText: lightGlyph, appearance: .dark), lightGlyph
        )
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(themeText: darkGlyph, appearance: .light), darkGlyph
        )
    }

    /// A theme that ships artwork and no `toolbar_text` at all still gets a
    /// tone, and it is the one that adapts.
    func testNoThemeToneFallsBackToTheAppearancesOwnTone() {
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(themeText: nil, appearance: .light),
            ThemeContrast.barGlyphOnLight
        )
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(themeText: nil, appearance: .dark),
            ThemeContrast.barGlyphOnDark
        )
    }

    /// The fallback tones are absolute, not dynamic. `ThemeContrast.resolve`
    /// reads the APPLICATION's appearance, which is not necessarily the
    /// window's, so a dynamic fallback would be measured in one appearance and
    /// drawn in the other and the plate would come out inverted. This is the
    /// assertion that stops someone "tidying" them back to `Color.primary`.
    func testTheFallbackTonesResolveTheSameInBothAppearances() {
        for tone in [ThemeContrast.barGlyphOnLight, ThemeContrast.barGlyphOnDark] {
            let inLight = resolve(tone, in: .light)
            let inDark = resolve(tone, in: .dark)
            XCTAssertEqual(inLight.rgb.red, inDark.rgb.red, accuracy: 0.001)
            XCTAssertEqual(inLight.rgb.green, inDark.rgb.green, accuracy: 0.001)
            XCTAssertEqual(inLight.rgb.blue, inDark.rgb.blue, accuracy: 0.001)
        }
    }

    // MARK: - The plate follows

    /// The pair has to move together. Whatever tone comes out, the plate the
    /// guard picks from it must be the opposite polarity — that is what stops
    /// the island, and it is why the fix could not be made on the plate alone.
    func testThePlateIsAlwaysTheOppositePolarityToTheResolvedGlyph() {
        for appearance in [ColorScheme.light, .dark] {
            for theme in [lightGlyph, darkGlyph, Color?.none] {
                let glyph = ThemeContrast.toolbarGlyph(themeText: theme, appearance: appearance)
                let resolved = resolve(glyph, in: appearance)
                let plateIsDark = ThemeContrast.scrimIsDark(for: resolved)
                XCTAssertEqual(
                    plateIsDark, appearance == .dark,
                    "a \(appearance == .dark ? "dark" : "light") bar got a "
                        + "\(plateIsDark ? "dark" : "light") plate"
                )
            }
        }
    }

    /// `glyphSuits` is the single definition of "this tone belongs here", and
    /// it must agree with the crossover the scrim already uses. If these two
    /// ever drift, a glyph could be judged to suit an appearance while its
    /// plate is chosen for the other one.
    func testGlyphSuitsAgreesWithTheScrimCrossover() {
        for appearance in [ColorScheme.light, .dark] {
            for tone in [lightGlyph, darkGlyph] {
                let rgba = resolve(tone, in: appearance)
                XCTAssertEqual(
                    ThemeContrast.glyphSuits(rgba, appearance),
                    ThemeContrast.scrimIsDark(for: rgba) == (appearance == .dark)
                )
            }
        }
    }

    // MARK: - The floor does not move

    /// The brief's condition: whatever the glyph tone becomes, every control
    /// still clears 3:1 against its real backdrop, in both appearances.
    ///
    /// Measured against a backdrop with the shape that causes trouble — the
    /// pale tiled bar with the theme's dark artwork running through part of it,
    /// so one window of the cluster is bright and another is not.
    func testEveryControlStillClearsTheIconFloorOnARealBackdrop() {
        for appearance in [ColorScheme.light, .dark] {
            let glyph = ThemeContrast.toolbarGlyph(themeText: lightGlyph, appearance: appearance)
            let foreground = resolve(glyph, in: appearance)
            let sample = mixedBar(appearance: appearance)

            let achieved: Double
            if let plan = ThemeContrast.plate(
                foreground: foreground, sample: sample,
                floor: ThemeContrast.iconFloor, windowPoints: 34
            ) {
                achieved = plan.ratioAfter
                // The plate must move the backdrop away from the glyph, not
                // toward it: a light glyph gets a dark plate and vice versa.
                XCTAssertEqual(plan.isDark, ThemeContrast.scrimIsDark(for: foreground))
            } else {
                // No plate needed means every window already cleared the floor.
                achieved = sample.windows(ofPoints: 34)
                    .map { ThemeContrast.harmfulRatio(foreground: foreground, backdrop: $0) }
                    .min() ?? .infinity
            }

            XCTAssertGreaterThanOrEqual(
                achieved, ThemeContrast.iconFloor,
                "controls measure \(achieved):1 in \(appearance == .dark ? "dark" : "light")"
            )
        }
    }

    /// A themed bar that is pale over most of its width and dark where the
    /// theme's artwork sits — the arrangement in the owner's screenshot.
    private func mixedBar(appearance: ColorScheme) -> ThemeBackdropSample {
        let columns = 40, rows = 8
        let pale = appearance == .dark
            ? ThemeContrast.RGB(red: 0.13, green: 0.16, blue: 0.22)
            : ThemeContrast.RGB(red: 0.62, green: 0.78, blue: 0.93)
        let artwork = ThemeContrast.RGB(red: 0.90, green: 0.45, blue: 0.10)

        var pixels: [ThemeContrast.RGB] = []
        for _ in 0..<rows {
            for column in 0..<columns {
                pixels.append(column > columns * 2 / 3 ? artwork : pale)
            }
        }
        return ThemeBackdropSample(
            pixels: pixels, columns: columns, rows: rows, pointWidth: 240
        )
    }

    /// Resolves a colour in a named appearance, the way the bar does when it
    /// draws in that appearance.
    private func resolve(_ color: Color, in scheme: ColorScheme) -> ThemeContrast.RGBA {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        var resolved = ThemeContrast.RGBA(rgb: .black, alpha: 1)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = ThemeContrast.resolve(color)
        }
        return resolved
    }
}
