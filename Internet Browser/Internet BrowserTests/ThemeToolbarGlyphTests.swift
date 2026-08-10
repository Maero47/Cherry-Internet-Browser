//
//  ThemeToolbarGlyphTests.swift
//  Internet BrowserTests
//
//  A Firefox theme names ONE `toolbar_text` and the format has no way to vary
//  it by appearance. For chrome the theme PAINTS that is the whole answer: the
//  backdrop does not vary by appearance either, so the theme's tone is drawn
//  in both appearances and the plate — chosen FROM the glyph — lands on the
//  theme's side with it. The appearance only speaks where the theme left it a
//  say: the fallback when no tone is named, and the suitability judgment for
//  a tone named for chrome the theme does NOT paint (a stock surface).
//
//  These pin the pure decision; `ThemeOwnsChromeTests` pins the same decision
//  at the view entry points.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class ThemeToolbarGlyphTests: XCTestCase {

    private let lightGlyph = Color(red: 0.98, green: 0.98, blue: 0.96)  // a dark-chrome theme
    private let darkGlyph = Color(red: 0.11, green: 0.10, blue: 0.13)   // a light-chrome theme

    // MARK: - Chrome the theme paints is the theme's to tone

    /// The owner's call: a theme paints the chrome in both appearances, and
    /// the tone it names for that chrome is the tone that gets drawn — in
    /// both. No polarity of theme, no appearance, drops it.
    func testAPaintedBarKeepsTheThemesToneInBothAppearances() {
        for appearance in [ColorScheme.light, .dark] {
            for tone in [lightGlyph, darkGlyph] {
                XCTAssertEqual(
                    ThemeContrast.toolbarGlyph(
                        themeText: tone, themePaintsBackdrop: true, appearance: appearance
                    ),
                    tone,
                    "the appearance has no opinion about chrome the theme owns"
                )
            }
        }
    }

    // MARK: - Where the appearance still has its say

    /// A theme that ships artwork and no `toolbar_text` at all still gets a
    /// tone, and it is the one that adapts.
    func testNoThemeToneFallsBackToTheAppearancesOwnTone() {
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(themeText: nil, themePaintsBackdrop: true, appearance: .light),
            ThemeContrast.barGlyphOnLight
        )
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(themeText: nil, themePaintsBackdrop: true, appearance: .dark),
            ThemeContrast.barGlyphOnDark
        )
    }

    /// A tone named for chrome the theme does NOT paint sits on a stock
    /// surface, and stock surfaces vary by appearance — so there the old rule
    /// stands: kept when it suits the appearance, dropped for the absolute
    /// fallback when it cannot have been legible.
    func testAToneForUnpaintedChromeStillDefersToTheAppearance() {
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(
                themeText: lightGlyph, themePaintsBackdrop: false, appearance: .dark
            ),
            lightGlyph
        )
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(
                themeText: lightGlyph, themePaintsBackdrop: false, appearance: .light
            ),
            ThemeContrast.barGlyphOnLight
        )
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(
                themeText: darkGlyph, themePaintsBackdrop: false, appearance: .light
            ),
            darkGlyph
        )
        XCTAssertEqual(
            ThemeContrast.toolbarGlyph(
                themeText: darkGlyph, themePaintsBackdrop: false, appearance: .dark
            ),
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

    /// The pair moves together, so the plate's polarity is decided by the
    /// glyph that actually comes out. For a theme-owned tone that is the
    /// THEME's polarity, identical in both appearances — the island's pale
    /// plate in dark chrome cannot be asked for. For the no-tone fallback it
    /// is the appearance's, because the fallback is the appearance's tone.
    func testThePlatePolarityFollowsTheGlyphThatComesOut() {
        for appearance in [ColorScheme.light, .dark] {
            for theme in [lightGlyph, darkGlyph] {
                let glyph = ThemeContrast.toolbarGlyph(
                    themeText: theme, themePaintsBackdrop: true, appearance: appearance
                )
                XCTAssertEqual(
                    ThemeContrast.scrimIsDark(for: resolve(glyph, in: appearance)),
                    ThemeContrast.scrimIsDark(for: resolve(theme, in: appearance)),
                    "the plate's polarity must be the theme tone's own, in every appearance"
                )
            }

            let fallback = ThemeContrast.toolbarGlyph(
                themeText: nil, themePaintsBackdrop: true, appearance: appearance
            )
            XCTAssertEqual(
                ThemeContrast.scrimIsDark(for: resolve(fallback, in: appearance)),
                appearance == .dark,
                "the no-tone fallback stays the appearance's tone, plate opposite it"
            )
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
            let glyph = ThemeContrast.toolbarGlyph(
                themeText: lightGlyph, themePaintsBackdrop: true, appearance: appearance
            )
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
