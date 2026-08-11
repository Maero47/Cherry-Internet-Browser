//
//  BookmarkBarPlateTests.swift
//  Internet BrowserTests
//
//  The bookmark bar was the last themed chrome surface outside the contrast
//  guard: since theme-owns-chrome it draws the theme's own tone, but nothing
//  measured that tone against the artwork actually behind it, so titles and
//  favicons could still drown on a busy header image. These pin the bar's way
//  in — the same `ThemeContrastGuard` every other chrome surface uses, ONE
//  decision for the whole bar, a translucent scrim at the solved minimum.
//
//  Following `ThemeOwnsChromeTests`, the ENTRY POINTS are pinned and not just
//  the arithmetic: the view's `legibility` property, and — through the guard's
//  served-decision record — the body's actual `themeLegibilityPlate` call,
//  exercised by hosting the real view offscreen. No screen capture, no pixel
//  measurement: the record says what the bar asked and what it was told.
//
//  Every test installs its fixture theme directly on the manager (never
//  persisted) and restores whatever theme and appearance were active before.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class BookmarkBarPlateTests: XCTestCase {

    private var savedTheme: FirefoxThemeManager.FirefoxTheme?
    private var savedAppAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        savedTheme = FirefoxThemeManager.shared.activeTheme
        savedAppAppearance = NSApp.appearance
        ThemeContrastGuard.shared.served = nil
    }

    override func tearDown() {
        FirefoxThemeManager.shared.activeTheme = savedTheme
        NSApp.appearance = savedAppAppearance
        ThemeContrastGuard.shared.served = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A theme authored against dark chrome: light `toolbar_text`. Over the
    /// problem backdrop its titles drown on the PALE stretch of the bar.
    private let darkChromeTheme = FirefoxThemeManager.FirefoxTheme(
        id: "bookmark-bar-plate-dark-fixture",
        name: "Dark chrome fixture",
        colors: [
            "frame": "rgb(20, 24, 34)",
            "toolbar": "rgba(28, 32, 44, 0.9)",
            "toolbar_text": "rgb(250, 250, 245)",
        ]
    )

    /// The opposite polarity: dark `toolbar_text`, which drowns where the
    /// dark ARTWORK runs through the bar instead.
    private let lightChromeTheme = FirefoxThemeManager.FirefoxTheme(
        id: "bookmark-bar-plate-light-fixture",
        name: "Light chrome fixture",
        colors: [
            "frame": "rgb(233, 226, 214)",
            "toolbar": "rgb(244, 240, 232)",
            "toolbar_text": "rgb(28, 26, 30)",
        ]
    )

    /// For the hosted bar: a pale frame under a light `toolbar_text`, so the
    /// REAL sampled backdrop fails the text floor and the body must plate.
    private let paleFrameLightTextTheme = FirefoxThemeManager.FirefoxTheme(
        id: "bookmark-bar-plate-pale-fixture",
        name: "Pale frame, light text fixture",
        colors: [
            "frame": "rgb(235, 231, 222)",
            "toolbar": "rgba(255, 255, 255, 0.06)",
            "toolbar_text": "rgb(250, 250, 245)",
        ]
    )

    /// The width of one bookmark entry, as the view states it. Pinned here so
    /// the fixture tests and the body cannot drift apart about what "one
    /// control" means for this bar.
    private let entryPoints: CGFloat = 40

    /// The shape of the real complaint: a bar that is pale over most of its
    /// width with the theme's dark artwork running through the right quarter —
    /// so one polarity of tone drowns on the pale stretch and the other
    /// drowns in the artwork.
    private func problemBackdrop() -> ThemeBackdropSample {
        let columns = 96, rows = 8
        let pale = ThemeContrast.RGB(red: 0.86, green: 0.82, blue: 0.74)
        let artwork = ThemeContrast.RGB(red: 0.09, green: 0.10, blue: 0.13)
        var pixels: [ThemeContrast.RGB] = []
        for _ in 0..<rows {
            for column in 0..<columns {
                pixels.append(column >= columns * 3 / 4 ? artwork : pale)
            }
        }
        return ThemeBackdropSample(pixels: pixels, columns: columns, rows: rows, pointWidth: 480)
    }

    // MARK: - View entry points, built the way the browser builds them

    private func bookmarkBar(isPrivate: Bool = false) -> BookmarkBarView {
        BookmarkBarView(
            repository: BookmarkRepository.shared,
            onBookmarkClick: { _ in },
            isPrivateMode: isPrivate
        )
    }

    // MARK: - The context the bar hands the guard

    /// The guard measures the tone the bar actually draws, over the overlays
    /// the bar actually paints — the same convention as the navigation bar,
    /// because it is the same guard.
    ///
    /// Dies when `BookmarkBarView.legibility` is removed, returns nil while
    /// themed, loses its overlays, or measures a tone the bar does not draw.
    func testTheBarsGuardContextIsTheToneAndOverlaysTheBarDraws() {
        FirefoxThemeManager.shared.activeTheme = darkChromeTheme
        CherryAppearance.apply(.light)

        let bar = bookmarkBar()
        guard let legibility = bar.legibility else {
            return XCTFail("a themed bookmark bar must hand the guard a context")
        }
        assertSameResolved(
            ThemeContrast.resolve(legibility.foreground),
            ThemeContrast.resolve(bar.themedToolbarText ?? .clear),
            "the guard must measure the tone the bar draws"
        )
        // The bar layers the theme's `toolbar` colour over the header
        // backdrop, so the guard must measure through it too.
        let toolbar = FirefoxThemeManager.shared.toolbarColor
        XCTAssertEqual(legibility.overlays.count, 1)
        assertSameResolved(
            ThemeContrast.resolve(legibility.overlays[0]),
            ThemeContrast.resolve(toolbar ?? .clear),
            "the guard must measure through the bar's toolbar overlay"
        )
        XCTAssertEqual(
            ThemeContrast.resolve(legibility.overlays[0]).alpha,
            ThemeContrast.resolve(toolbar ?? .clear).alpha,
            accuracy: 0.01
        )
    }

    // MARK: - The floors, over the backdrop shaped like the real problem

    /// Titles clear 4.5:1 and favicon-shaped (non-text) content clears 3:1 in
    /// EVERY entry-sized window of the bar, for both theme polarities, in both
    /// appearances — with the ONE plan the whole bar reaches, not a plan per
    /// entry.
    ///
    /// Dies when the tone entry point breaks (`themedToolbarText` nil or
    /// appearance-flipped while themed), when the solver stops reaching the
    /// floor, or when either floor constant is quietly lowered.
    func testTitlesAndFaviconsClearTheirFloorsOverTheProblemBackdropInBothAppearances() {
        for theme in [darkChromeTheme, lightChromeTheme] {
            FirefoxThemeManager.shared.activeTheme = theme
            for mode in [AppearanceMode.light, .dark] {
                CherryAppearance.apply(mode)

                guard let tone = bookmarkBar().themedToolbarText else {
                    return XCTFail("themed bar lost its tone — \(theme.name), \(mode)")
                }
                let foreground = ThemeContrast.resolve(tone)
                let sample = problemBackdrop()

                guard let plan = ThemeContrast.plate(
                    foreground: foreground, sample: sample,
                    floor: ThemeContrast.textFloor, windowPoints: entryPoints
                ) else {
                    return XCTFail(
                        "the problem backdrop must demand a plate — \(theme.name), \(mode)"
                    )
                }
                XCTAssertLessThan(
                    plan.opacity, 1, "the scrim must stay translucent — the theme has to read"
                )

                // The one plan, applied under every entry-sized window: titles
                // at the text floor, favicon-shaped content at the icon floor.
                var worstTitle = Double.infinity
                var worstFavicon = Double.infinity
                let scrim = ThemeContrast.RGBA(
                    rgb: plan.isDark ? .black : .white, alpha: plan.opacity
                )
                for window in sample.windows(ofPoints: entryPoints) {
                    let scrimmed = window.map { ThemeContrast.composite(scrim, over: $0) }
                    let ratio = ThemeContrast.harmfulRatio(
                        foreground: foreground, backdrop: scrimmed
                    )
                    worstTitle = min(worstTitle, ratio)
                    worstFavicon = min(worstFavicon, ratio)
                }
                XCTAssertGreaterThanOrEqual(
                    worstTitle, ThemeContrast.textFloor,
                    "titles at \(worstTitle):1 — \(theme.name), \(mode)"
                )
                XCTAssertGreaterThanOrEqual(
                    worstFavicon, ThemeContrast.iconFloor,
                    "favicons at \(worstFavicon):1 — \(theme.name), \(mode)"
                )
                print(String(
                    format: "MEASURED %@ %@: before %.2f:1, scrim %@ %.2f, after %.2f:1",
                    theme.name, mode == .dark ? "dark" : "light",
                    plan.ratioBefore, plan.isDark ? "black" : "white",
                    plan.opacity, worstTitle
                ))
            }
        }
    }

    /// The same theme reaches the same answer in both appearances — tone AND
    /// plan — which is the owner's standing complaint about colours that move.
    ///
    /// Dies when the bar's tone is gated on the appearance again while the
    /// theme paints the chrome.
    func testTheSameThemeGivesTheSameBarToneAndPlanInBothAppearances() {
        for theme in [darkChromeTheme, lightChromeTheme] {
            FirefoxThemeManager.shared.activeTheme = theme

            var tones: [ThemeContrast.RGBA] = []
            var plans: [ThemeScrimPlan?] = []
            for mode in [AppearanceMode.light, .dark] {
                CherryAppearance.apply(mode)
                let tone = bookmarkBar().themedToolbarText ?? .clear
                tones.append(ThemeContrast.resolve(tone))
                plans.append(ThemeContrast.plate(
                    foreground: ThemeContrast.resolve(tone), sample: problemBackdrop(),
                    floor: ThemeContrast.textFloor, windowPoints: entryPoints
                ))
            }
            assertSameResolved(tones[0], tones[1], "the bar's tone moved with the appearance")
            XCTAssertEqual(
                plans[0], plans[1],
                "the same theme must reach the same bar plan in both appearances"
            )
        }
    }

    // MARK: - One decision for the whole bar

    /// Per-entry treatment would visibly diverge on this backdrop — a pale
    /// entry needs a scrim the artwork entry does not — which is exactly the
    /// patchwork the cluster rule exists to prevent. The whole-bar span
    /// reaches one plan instead, and that plan holds under both stretches.
    func testPerEntryDecisionsWouldDivergeWhereTheBarsOneDecisionHolds() {
        FirefoxThemeManager.shared.activeTheme = darkChromeTheme
        CherryAppearance.apply(.light)
        let tone = ThemeContrast.resolve(bookmarkBar().themedToolbarText ?? .clear)

        let whole = problemBackdrop()
        let entries = whole.windows(ofPoints: entryPoints)
        let perEntry = entries.map { window in
            ThemeContrast.plate(
                foreground: tone,
                sample: ThemeBackdropSample(
                    pixels: window, columns: window.count / whole.rows,
                    rows: whole.rows, pointWidth: entryPoints
                ),
                floor: ThemeContrast.textFloor, windowPoints: entryPoints
            )
        }
        XCTAssertTrue(
            perEntry.contains { $0 != nil } && perEntry.contains { $0 == nil },
            "the fixture must be one a per-entry guard would answer unevenly, or this proves nothing"
        )

        let one = ThemeContrast.plate(
            foreground: tone, sample: whole,
            floor: ThemeContrast.textFloor, windowPoints: entryPoints
        )
        XCTAssertNotNil(one, "the bar's single decision covers the entry that needed it")
        XCTAssertGreaterThanOrEqual(one?.ratioAfter ?? 0, ThemeContrast.textFloor)
    }

    // MARK: - The body actually asks — the entry point a revert would hit

    /// Hosts the REAL view offscreen and reads the guard's served-decision
    /// record: the bar's body consults the shared guard, at the text floor,
    /// at the bar's entry width, with the bar's own tone, across ONE span the
    /// width of the whole bar — and is answered with one translucent plan.
    ///
    /// This is the test a one-line revert of the body's
    /// `.themeLegibilityPlate` call dies on, which no property test can see.
    /// It also dies when the floor is swapped for the icon floor, when the
    /// plate moves onto the entries (several narrow spans instead of one wide
    /// one), and when the scrim stops being translucent.
    ///
    /// The test host is the whole running browser, whose live windows also
    /// consult the guard once a fixture theme is installed — so the hosted
    /// bar gets a width no other surface has and its questions are read back
    /// by that width. A per-entry mutation leaves NO whole-bar-wide question,
    /// which is exactly what the first assertion catches.
    func testTheHostedBarsBodyReachesOneWholeBarDecisionThroughTheGuard() throws {
        FirefoxThemeManager.shared.activeTheme = paleFrameLightTextTheme
        CherryAppearance.apply(.light)
        ThemeContrastGuard.shared.served = []

        try withHostedBar(width: hostedBarWidth) {
            let served = self.hostedBarQuestions()
            XCTAssertFalse(
                served.isEmpty,
                "the bar's body never asked the guard for a whole-bar decision — "
                    + "the plate call is gone, or it has moved onto the entries"
            )

            let tone = ThemeContrast.resolve(bookmarkBar().themedToolbarText ?? .clear)
            var decisions = Set<String>()
            for question in served {
                XCTAssertEqual(
                    question.floor, ThemeContrast.textFloor,
                    "bookmark titles are body-size text; the bar must ask at 4.5:1"
                )
                XCTAssertEqual(question.windowPoints, entryPoints)
                assertSameResolved(
                    question.foreground, tone, "the bar must ask about the tone it draws"
                )
                let plan = try XCTUnwrap(
                    question.plan, "light text on the pale fixture must be answered with a plan"
                )
                XCTAssertTrue(plan.isDark, "a light tone takes a dark scrim")
                XCTAssertLessThan(plan.opacity, 1, "the scrim must stay translucent")
                XCTAssertGreaterThanOrEqual(plan.ratioAfter, ThemeContrast.textFloor)
                decisions.insert(String(format: "%.0f|%.0f|%.2f",
                                        question.rect.minX, question.rect.width, plan.opacity))
            }
            XCTAssertEqual(
                decisions.count, 1,
                "one decision for the whole bar — several is the per-entry patchwork: \(decisions)"
            )
        }
    }

    // MARK: - Unthemed and private bars are untouched

    /// No theme, or a private window: the bar hands the guard nothing, the
    /// hosted body asks it nothing, and so nothing about the stock look can
    /// move from here.
    ///
    /// Dies when `legibility` stops being nil for either case — including a
    /// dropped `isPrivateMode` guard — or when the body starts querying the
    /// guard with some other context.
    func testUnthemedAndPrivateBarsNeverConsultTheGuard() throws {
        // Each hosted bar gets its OWN width: the unthemed bar hosted first
        // is a real themed-able bar, and if it is still being torn down when
        // the theme below is installed, its (legitimate) question must not be
        // read as the private bar's.
        FirefoxThemeManager.shared.activeTheme = nil
        XCTAssertNil(bookmarkBar().legibility)
        XCTAssertNil(bookmarkBar().themedToolbarText)
        ThemeContrastGuard.shared.served = []
        try withHostedBar(width: 647) {
            XCTAssertTrue(
                self.hostedBarQuestions(width: 647).isEmpty,
                "an unthemed bar asked the guard a question — the stock look is in play"
            )
        }

        // The running browser's own windows may consult the guard once this
        // theme is installed; only a question at the hosted bar's width would
        // be the private bar's, and there must not be one.
        FirefoxThemeManager.shared.activeTheme = darkChromeTheme
        XCTAssertNil(bookmarkBar(isPrivate: true).legibility)
        XCTAssertNil(bookmarkBar(isPrivate: true).themedToolbarText)
        ThemeContrastGuard.shared.served = []
        try withHostedBar(width: hostedBarWidth, isPrivate: true) {
            XCTAssertTrue(
                self.hostedBarQuestions().isEmpty,
                "a private bar asked the guard a question — private windows are never themed"
            )
        }
    }

    // MARK: - The theme still reads

    /// "At the solved minimum" is measurable: a hair less scrim than the plan
    /// carries must fail the floor somewhere under the bar. Anything more
    /// would be flattening artwork the user imported on purpose.
    func testTheBarsScrimIsTheLeastThatClearsTheFloor() {
        FirefoxThemeManager.shared.activeTheme = darkChromeTheme
        CherryAppearance.apply(.light)
        let tone = ThemeContrast.resolve(bookmarkBar().themedToolbarText ?? .clear)
        let sample = problemBackdrop()

        guard let plan = ThemeContrast.plate(
            foreground: tone, sample: sample,
            floor: ThemeContrast.textFloor, windowPoints: entryPoints
        ) else { return XCTFail("the problem backdrop must demand a plate") }

        let weaker = ThemeContrast.RGBA(
            rgb: plan.isDark ? .black : .white, alpha: max(0, plan.opacity - 0.02)
        )
        let worstWithLess = sample.windows(ofPoints: entryPoints).map { window in
            ThemeContrast.harmfulRatio(
                foreground: tone,
                backdrop: window.map { ThemeContrast.composite(weaker, over: $0) }
            )
        }.min() ?? .infinity
        XCTAssertLessThan(
            worstWithLess, ThemeContrast.textFloor,
            "0.02 less scrim still cleared the floor, so the shipped opacity is not minimal"
        )
    }

    // MARK: - Helpers

    /// A width no other surface in the running app plausibly has, so the
    /// hosted bar's questions can be told apart from the live windows'.
    private let hostedBarWidth: CGFloat = 643

    /// The guard questions attributable to the hosted bar: the ones spanning
    /// exactly its width.
    private func hostedBarQuestions(
        width: CGFloat? = nil
    ) -> [ThemeContrastGuard.ServedPlate] {
        let expected = width ?? hostedBarWidth
        return (ThemeContrastGuard.shared.served ?? []).filter {
            abs($0.rect.width - expected) <= 1
        }
    }

    /// Hosts the real `BookmarkBarView` in an offscreen window — the pattern
    /// `HomepageWindowLayoutTests` uses — long enough for its body (and so its
    /// plate layer's geometry) to be evaluated, then runs `check`.
    private func withHostedBar(
        width: CGFloat, isPrivate: Bool = false, check: () throws -> Void
    ) throws {
        let hosting = NSHostingView(rootView: bookmarkBar(isPrivate: isPrivate))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 28)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            pump(0.1)
        }
        window.contentView = hosting
        window.layoutIfNeeded()
        pump(0.4)
        try check()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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
