//
//  ThemeOwnsChromeTests.swift
//  Internet BrowserTests
//
//  A theme paints the chrome in BOTH appearances, and the tone it names for
//  that chrome is the tone that gets drawn — the appearance has no opinion
//  about chrome the theme owns. These pin the ENTRY POINTS — the very
//  properties the bars, tabs and omnibox read — not just the pure decision
//  function, so a one-line change in a view reverts a test, not just a pixel.
//
//  The trap this exists to keep shut: in Light appearance with a dark theme,
//  dropping the theme's light `toolbar_text` for dark ink lands dark glyphs on
//  the theme's dark bar, and the guard then correctly puts a PALE plate under
//  them — a light island punched into dark themed chrome. When the tone and
//  the backdrop both come from the theme they are on the same side by
//  construction, and the island cannot arise.
//
//  Every test installs its fixture theme directly on the manager (never
//  persisted) and restores whatever theme and appearance were active before.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class ThemeOwnsChromeTests: XCTestCase {

    private var savedTheme: FirefoxThemeManager.FirefoxTheme?
    private var savedAppAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        savedTheme = FirefoxThemeManager.shared.activeTheme
        savedAppAppearance = NSApp.appearance
    }

    override func tearDown() {
        FirefoxThemeManager.shared.activeTheme = savedTheme
        NSApp.appearance = savedAppAppearance
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A theme authored against dark chrome: dark frame and toolbar, light
    /// text everywhere — the "Praise the sun" shape, and the polarity the
    /// owner actually complained about.
    private let darkChromeTheme = FirefoxThemeManager.FirefoxTheme(
        id: "theme-owns-chrome-dark-fixture",
        name: "Dark chrome fixture",
        colors: [
            "frame": "rgb(20, 24, 34)",
            "toolbar": "rgba(28, 32, 44, 0.9)",
            "toolbar_text": "rgb(250, 250, 245)",
            "tab_background_text": "rgb(236, 238, 244)",
            "tab_text": "rgb(255, 255, 255)",
            "toolbar_field": "rgba(0, 0, 0, 0.34)",
            "toolbar_field_text": "rgb(248, 248, 250)",
        ]
    )

    /// The opposite polarity, so a gate keyed on EITHER appearance judgment
    /// drops one of the two fixtures' tones and dies here.
    private let lightChromeTheme = FirefoxThemeManager.FirefoxTheme(
        id: "theme-owns-chrome-light-fixture",
        name: "Light chrome fixture",
        colors: [
            "frame": "rgb(233, 226, 214)",
            "toolbar": "rgb(244, 240, 232)",
            "toolbar_text": "rgb(28, 26, 30)",
            "tab_background_text": "rgb(40, 38, 44)",
            "tab_text": "rgb(20, 20, 22)",
            "toolbar_field": "rgb(252, 250, 246)",
            "toolbar_field_text": "rgb(30, 30, 34)",
        ]
    )

    /// A theme that paints the chrome but names no glyph tone at all — no
    /// `toolbar_text`, no `bookmark_text`, no `icons`.
    private let untonedTheme = FirefoxThemeManager.FirefoxTheme(
        id: "theme-owns-chrome-untoned-fixture",
        name: "Untoned fixture",
        colors: [
            "frame": "rgb(20, 24, 34)",
            "toolbar": "rgba(28, 32, 44, 0.9)",
        ]
    )

    // MARK: - View entry points, built the way the browser builds them

    private func navigationBar(isPrivate: Bool = false) -> NavigationBarView {
        NavigationBarView(
            tab: Tab(),
            onNavigate: { _ in }, onBack: {}, onForward: {}, onReload: {},
            onStop: {}, onHome: {},
            isPrivateMode: isPrivate
        )
    }

    private func bookmarkBar(isPrivate: Bool = false) -> BookmarkBarView {
        BookmarkBarView(
            repository: BookmarkRepository.shared,
            onBookmarkClick: { _ in },
            isPrivateMode: isPrivate
        )
    }

    private func tabItem(isPrivate: Bool = false) -> TabItemView {
        TabItemView(
            tab: Tab(isPrivate: isPrivate), isSelected: false,
            onSelect: {}, onClose: {}
        )
    }

    private func omnibox(isPrivate: Bool = false) -> OmniboxView {
        OmniboxView(
            text: .constant("cherry"), isLoading: false, isSecure: true,
            isPrivateMode: isPrivate,
            onSubmit: { _ in }, onFocus: {}
        )
    }

    // MARK: - The decision: the theme's tone is the tone, in both appearances

    /// The reversal itself, at the entry points. For chrome the theme paints,
    /// the tone the bars actually draw is the theme's own `toolbar_text` — in
    /// Light AND in Dark, for a dark-chrome theme AND a light-chrome one.
    /// Before the fix the dark-chrome theme's light tone was dropped for dark
    /// ink in Light appearance, which is the island's first half.
    func testAThemedToolbarDrawsTheThemesOwnToneInBothAppearances() {
        for theme in [darkChromeTheme, lightChromeTheme] {
            FirefoxThemeManager.shared.activeTheme = theme
            let expected = FirefoxThemeManager.shared.toolbarText
            XCTAssertNotNil(expected, "fixture must name a toolbar_text")

            for mode in [AppearanceMode.light, .dark] {
                CherryAppearance.apply(mode)
                assertSameTone(
                    navigationBar().themedToolbarText, expected,
                    "navigation bar, theme \(theme.name), \(mode) appearance"
                )
                assertSameTone(
                    bookmarkBar().themedToolbarText, expected,
                    "bookmark bar, theme \(theme.name), \(mode) appearance"
                )
                // The tone the guard measures is the same one the bar draws.
                assertSameTone(
                    navigationBar().legibility?.foreground, expected,
                    "guard foreground, theme \(theme.name), \(mode) appearance"
                )
                // And every accent-/state-tinted glyph funnels into it.
                assertSameTone(
                    navigationBar().themedGlyph(.accentColor), expected,
                    "themedGlyph funnel, theme \(theme.name), \(mode) appearance"
                )
            }
        }
    }

    /// The owner's standing complaint, as a test: the SAME theme gives the
    /// SAME chrome colours in Light and in Dark — toolbar glyphs, bookmark
    /// labels, tab titles, omnibox text — and the SAME plate decision.
    func testTheSameThemeGivesTheSameChromeColoursAndPlatesInBothAppearances() {
        FirefoxThemeManager.shared.activeTheme = darkChromeTheme

        var tonesByMode: [[ThemeContrast.RGBA]] = []
        var plansByMode: [ThemeScrimPlan?] = []
        for mode in [AppearanceMode.light, .dark] {
            CherryAppearance.apply(mode)
            let tones = [
                navigationBar().themedToolbarText,
                bookmarkBar().themedToolbarText,
                tabItem().themedTitleColor,
                omnibox().themedFieldText,
            ].map { tone -> ThemeContrast.RGBA in
                XCTAssertNotNil(tone, "every themed surface must have a tone in \(mode)")
                return ThemeContrast.resolve(tone ?? .clear)
            }
            tonesByMode.append(tones)

            let foreground = ThemeContrast.resolve(
                navigationBar().legibility?.foreground ?? .clear
            )
            plansByMode.append(ThemeContrast.plate(
                foreground: foreground, sample: themeArtworkWithHighlight(),
                floor: ThemeContrast.iconFloor, windowPoints: 28
            ))
        }

        for (light, dark) in zip(tonesByMode[0], tonesByMode[1]) {
            assertSameResolved(light, dark, "a chrome tone changed between appearances")
        }
        XCTAssertEqual(
            plansByMode[0], plansByMode[1],
            "the same theme must reach the same plate decision in both appearances"
        )
    }

    // MARK: - Why the island cannot come back

    /// In Light appearance, over the dark theme's artwork, the cluster plate —
    /// chosen from the tone the bar ACTUALLY draws — must be the DARK one.
    /// Before the fix the bar drew dark ink there, the guard answered with a
    /// pale plate, and that pale plate in dark themed chrome was the island.
    func testInLightAppearanceADarkThemesPlateIsDarkNotAPaleIsland() {
        FirefoxThemeManager.shared.activeTheme = darkChromeTheme
        CherryAppearance.apply(.light)

        let foreground = ThemeContrast.resolve(
            navigationBar().legibility?.foreground ?? .clear
        )
        let plan = ThemeContrast.plate(
            foreground: foreground, sample: themeArtworkWithHighlight(),
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        XCTAssertNotNil(plan, "the highlight band must demand a plate at all")
        XCTAssertEqual(
            plan?.isDark, true,
            "a theme-owned light glyph takes a dark plate; a pale one is the island"
        )
        // And with it, the glyphs clear the icon floor over the highlight.
        XCTAssertGreaterThanOrEqual(plan?.ratioAfter ?? 0, ThemeContrast.iconFloor)
    }

    // MARK: - What the appearance still decides

    /// A theme that paints the chrome but names no tone still gets the
    /// absolute fallback, picked by the appearance — that branch keeps its
    /// job. Off a view hierarchy the bars' `colorScheme` environment is Light,
    /// so the entry points must hand back the Light fallback.
    func testAnUntonedThemeStillGetsTheAbsoluteFallback() {
        FirefoxThemeManager.shared.activeTheme = untonedTheme

        assertSameTone(
            navigationBar().themedToolbarText, ThemeContrast.barGlyphOnLight,
            "navigation bar, untoned theme"
        )
        assertSameTone(
            bookmarkBar().themedToolbarText, ThemeContrast.barGlyphOnLight,
            "bookmark bar, untoned theme"
        )
    }

    /// Unthemed and private chrome is exactly what it always was: no override
    /// tone anywhere, the stock accent/state tints untouched.
    func testUnthemedAndPrivateChromeKeepsTheStockLook() {
        FirefoxThemeManager.shared.activeTheme = nil
        XCTAssertNil(navigationBar().themedToolbarText)
        XCTAssertNil(navigationBar().legibility)
        XCTAssertNil(bookmarkBar().themedToolbarText)
        XCTAssertNil(tabItem().themedTitleColor)
        XCTAssertNil(omnibox().themedFieldText)
        XCTAssertEqual(navigationBar().themedGlyph(.orange), .orange)

        FirefoxThemeManager.shared.activeTheme = darkChromeTheme
        XCTAssertNil(navigationBar(isPrivate: true).themedToolbarText)
        XCTAssertNil(navigationBar(isPrivate: true).legibility)
        XCTAssertNil(bookmarkBar(isPrivate: true).themedToolbarText)
        XCTAssertNil(tabItem(isPrivate: true).themedTitleColor)
        XCTAssertNil(omnibox(isPrivate: true).themedFieldText)
    }

    // MARK: - Helpers

    /// The shape of a themed bar that needs the guard at all: the theme's dark
    /// chrome with a bright illustration band running through one side — the
    /// arrangement where a glyph vanishes and a plate must appear.
    private func themeArtworkWithHighlight() -> ThemeBackdropSample {
        let columns = 40, rows = 8
        let chrome = ThemeContrast.RGB(red: 0.08, green: 0.10, blue: 0.14)
        let highlight = ThemeContrast.RGB(red: 0.98, green: 0.86, blue: 0.55)
        var pixels: [ThemeContrast.RGB] = []
        for _ in 0..<rows {
            for column in 0..<columns {
                pixels.append(column > columns * 2 / 3 ? highlight : chrome)
            }
        }
        return ThemeBackdropSample(pixels: pixels, columns: columns, rows: rows, pointWidth: 240)
    }

    /// Both colours resolved in the CURRENT applied appearance and compared
    /// channel-wise — `Color` equality is too clever for two colours built by
    /// different code paths.
    private func assertSameTone(
        _ actual: Color?, _ expected: Color?, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual, let expected else {
            XCTFail("\(label): tone missing (actual \(String(describing: actual)), "
                + "expected \(String(describing: expected)))", file: file, line: line)
            return
        }
        assertSameResolved(
            ThemeContrast.resolve(actual), ThemeContrast.resolve(expected),
            label, file: file, line: line
        )
    }

    private func assertSameResolved(
        _ actual: ThemeContrast.RGBA, _ expected: ThemeContrast.RGBA, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.rgb.red, expected.rgb.red, accuracy: 0.002, label, file: file, line: line)
        XCTAssertEqual(actual.rgb.green, expected.rgb.green, accuracy: 0.002, label, file: file, line: line)
        XCTAssertEqual(actual.rgb.blue, expected.rgb.blue, accuracy: 0.002, label, file: file, line: line)
    }
}
