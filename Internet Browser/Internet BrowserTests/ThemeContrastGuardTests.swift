//
//  ThemeContrastGuardTests.swift
//  Internet BrowserTests
//
//  The toolbar draws over a theme's header illustration, so no colour in the
//  app can be checked against a known backdrop — the backdrop is whatever
//  picture the user imported, sliding under the controls as the window
//  resizes. `ThemeContrastGuard` answers that by measuring the real pixels and
//  solving for the least scrim that clears the floor.
//
//  Which means the ARITHMETIC is the guarantee. These tests hold it to it:
//  that it agrees with the app's other WCAG implementation rather than being a
//  second opinion, that it leaves a legible theme alone, that when it does act
//  it reaches the floor, that it does not overshoot, and that it cannot be
//  talked out of acting by a backdrop that is mostly fine and locally fatal.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

final class ThemeContrastGuardTests: XCTestCase {

    private func rgb(_ red: Double, _ green: Double, _ blue: Double) -> ThemeContrast.RGB {
        ThemeContrast.RGB(red: red, green: green, blue: blue)
    }

    private func opaque(_ color: ThemeContrast.RGB) -> ThemeContrast.RGBA {
        ThemeContrast.RGBA(rgb: color, alpha: 1)
    }

    private func flat(_ color: ThemeContrast.RGB, count: Int = 400) -> [ThemeContrast.RGB] {
        Array(repeating: color, count: count)
    }

    /// One flat region put through the SHIPPING solver as a single window, so
    /// these cases exercise the code the app actually runs rather than a
    /// simplified twin of it.
    private func plan(
        foreground: ThemeContrast.RGBA, over backdrop: [ThemeContrast.RGB], floor: Double
    ) -> ThemeScrimPlan? {
        ThemeContrast.plate(
            foreground: foreground,
            sample: ThemeBackdropSample(
                pixels: backdrop, columns: backdrop.count, rows: 1, pointWidth: 1
            ),
            floor: floor,
            windowPoints: 28
        )
    }

    // MARK: - The arithmetic itself

    /// If the luminance formula is wrong, every number the guard reports is
    /// wrong in the same direction and it still "passes". These are the fixed
    /// points of WCAG 2.x.
    func testRelativeLuminanceMatchesTheWCAGFixedPoints() {
        XCTAssertEqual(ThemeContrast.relativeLuminance(.black), 0, accuracy: 1e-9)
        XCTAssertEqual(ThemeContrast.relativeLuminance(.white), 1, accuracy: 1e-9)
        // #808080 — the canonical mid grey, well above the 0.03928 knee.
        XCTAssertEqual(
            ThemeContrast.relativeLuminance(rgb(128 / 255, 128 / 255, 128 / 255)),
            0.2158, accuracy: 0.0005
        )
        XCTAssertEqual(ThemeContrast.ratio(1, 0), 21, accuracy: 1e-9)
    }

    /// This runs over hundreds of sampled pixels per control, so it is plain
    /// doubles rather than `MCPStatusPalette`'s `NSColor` maths. Two WCAG
    /// implementations in one app is a liability unless they are held to each
    /// other, so they are.
    func testItAgreesWithTheAppsOtherWCAGImplementation() {
        let samples: [(Double, Double, Double)] = [
            (0, 0, 0), (1, 1, 1), (0.5, 0.5, 0.5),
            (0.145, 0.388, 0.922),      // #2563EB, the default accent
            (1.0, 0.722, 0.427),        // rgb(255,184,109), a real toolbar_text
            (0.227, 0.122, 0.173),      // rgb(58,31,44), a real frame colour
            (0.02, 0.9, 0.35),
        ]
        for (red, green, blue) in samples {
            let mine = ThemeContrast.relativeLuminance(rgb(red, green, blue))
            let theirs = MCPStatusPalette.relativeLuminance(
                NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            )
            XCTAssertEqual(mine, theirs, accuracy: 1e-9, "luminance of \(red),\(green),\(blue)")
        }

        for (red, green, blue) in samples {
            let backdrop = rgb(red, green, blue)
            let mine = ThemeContrast.ratio(
                ThemeContrast.relativeLuminance(.white),
                ThemeContrast.relativeLuminance(backdrop)
            )
            let theirs = MCPStatusPalette.contrastRatio(
                .white, NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            )
            XCTAssertEqual(mine, theirs, accuracy: 1e-9)
        }
    }

    /// A translucent foreground is not its own colour. `Color.primary` is white
    /// at 85%, and treating it as opaque white reports a contrast it does not
    /// have — the same trap `MCPStatusPalette.composite` exists for.
    func testATranslucentForegroundIsCompositedBeforeItIsMeasured() {
        let backdrop = rgb(0.2, 0.2, 0.2)
        let translucent = ThemeContrast.RGBA(rgb: .white, alpha: 0.85)
        let composited = ThemeContrast.composite(translucent, over: backdrop)

        XCTAssertEqual(composited.red, 0.85 + 0.2 * 0.15, accuracy: 1e-9)
        XCTAssertLessThan(
            ThemeContrast.harmfulRatio(foreground: translucent, backdrop: flat(backdrop)),
            ThemeContrast.harmfulRatio(foreground: opaque(.white), backdrop: flat(backdrop))
        )
    }

    // MARK: - Leaving a legible theme alone

    /// The default answer, and the reason a theme that already reads keeps
    /// every pixel of its artwork: no scrim at all.
    func testALegibleBackdropGetsNoScrim() {
        XCTAssertNil(plan(
            foreground: opaque(.white),
            over: flat(rgb(0.1, 0.1, 0.12)),
            floor: ThemeContrast.iconFloor
        ))
        XCTAssertNil(plan(
            foreground: opaque(.black),
            over: flat(rgb(0.95, 0.95, 0.9)),
            floor: ThemeContrast.textFloor
        ))
    }

    /// No theme means no sampled pixels, which has to mean no scrim — this is
    /// the path the stock look takes, and it must be incapable of drawing
    /// anything.
    func testAnEmptyBackdropGetsNoScrim() {
        XCTAssertNil(plan(
            foreground: opaque(.white), over: [], floor: ThemeContrast.iconFloor
        ))
    }

    /// A backdrop that clears the floor by a hair is still clear, and must cost
    /// nothing. The pair below straddles the line: 3.05:1 is untouched, 2.95:1
    /// is corrected — which is what "only where it fails" has to mean.
    func testTheFloorIsAThresholdAndNotACushion() {
        let above = srgb(forLuminance: 1.05 / 3.05 - 0.05)
        let clears = flat(rgb(above, above, above))     // 3.05:1 against white
        XCTAssertGreaterThan(
            ThemeContrast.harmfulRatio(foreground: opaque(.white), backdrop: clears),
            ThemeContrast.iconFloor
        )
        XCTAssertNil(plan(
            foreground: opaque(.white), over: clears, floor: ThemeContrast.iconFloor
        ))

        let under = srgb(forLuminance: 1.05 / 2.95 - 0.05)
        let fails = flat(rgb(under, under, under))      // 2.95:1
        XCTAssertLessThan(
            ThemeContrast.harmfulRatio(foreground: opaque(.white), backdrop: fails),
            ThemeContrast.iconFloor
        )
        XCTAssertNotNil(plan(
            foreground: opaque(.white), over: fails, floor: ThemeContrast.iconFloor
        ))
    }

    // MARK: - Reaching the floor when it does act

    /// The promise: whatever the illustration is doing, the control clears its
    /// floor afterwards. Run over backdrops from black to white, so this covers
    /// the awkward middle where neither direction is comfortable.
    func testEveryFailingBackdropIsBroughtUpToTheFloor() {
        let foregrounds: [(String, ThemeContrast.RGBA)] = [
            ("white", opaque(.white)),
            ("label 85%", ThemeContrast.RGBA(rgb: .white, alpha: 0.85)),
            ("toolbar_text orange", opaque(rgb(1.0, 0.722, 0.427))),
            ("accent #2563EB", opaque(rgb(0.145, 0.388, 0.922))),
            ("black", opaque(.black)),
        ]
        for (name, foreground) in foregrounds {
            for step in 0...20 {
                let level = Double(step) / 20
                let backdrop = flat(rgb(level, level, level))
                let floor = ThemeContrast.iconFloor
                guard let plan = plan(
                    foreground: foreground, over: backdrop, floor: floor
                ) else {
                    XCTAssertGreaterThanOrEqual(
                        ThemeContrast.harmfulRatio(foreground: foreground, backdrop: backdrop),
                        floor, "\(name) on \(level): no scrim, so it had to already pass"
                    )
                    continue
                }
                XCTAssertGreaterThanOrEqual(
                    plan.ratioAfter, floor,
                    "\(name) on \(level) still at \(plan.ratioAfter):1 after a \(plan.opacity) scrim"
                )
            }
        }
    }

    /// A busy illustration, not a flat colour: this is a spread of tones with
    /// bright highlights in it, which is the case the whole guard exists for.
    func testABusyBackdropIsBroughtUpToTheFloor() {
        var backdrop: [ThemeContrast.RGB] = []
        for index in 0..<400 {
            let level = Double(index % 17) / 16          // a repeating ramp, 0…1
            backdrop.append(rgb(level, level * 0.8, 1 - level))
        }
        guard let plan = plan(
            foreground: opaque(.white), over: backdrop, floor: ThemeContrast.iconFloor
        ) else { return XCTFail("a ramp through white fails a white glyph and must be corrected") }
        XCTAssertGreaterThanOrEqual(plan.ratioAfter, ThemeContrast.iconFloor)
    }

    // MARK: - Not overshooting

    /// "The lowest opacity that clears the floor and no more" is the whole
    /// reason this does not flatten the artwork, so it is measured: a hair less
    /// scrim has to fail.
    func testTheOpacityIsTheLeastThatWorks() {
        let backdrop = flat(rgb(0.85, 0.8, 0.6))
        let plan = plan(
            foreground: opaque(.white), over: backdrop, floor: ThemeContrast.iconFloor
        )
        guard let plan else { return XCTFail("a white glyph on bright artwork needs a scrim") }

        XCTAssertGreaterThan(plan.opacity, 0)
        XCTAssertLessThan(plan.opacity, 1, "a flat opaque chip would be flattening the theme")

        let weaker = backdrop.map {
            ThemeContrast.composite(
                ThemeContrast.RGBA(rgb: .black, alpha: max(0, plan.opacity - 0.02)), over: $0
            )
        }
        XCTAssertLessThan(
            ThemeContrast.harmfulRatio(foreground: opaque(.white), backdrop: weaker),
            ThemeContrast.iconFloor,
            "0.02 less scrim still cleared the floor, so the solved opacity was not minimal"
        )
    }

    /// A backdrop that fails by a whisker must cost a whisker of scrim, not a
    /// slab of it.
    func testANearMissCostsAlmostNothing() {
        // 2.95:1 — five hundredths under the 3:1 floor.
        let level = srgb(forLuminance: 1.05 / 2.95 - 0.05)
        guard let plan = plan(
            foreground: opaque(.white), over: flat(rgb(level, level, level)),
            floor: ThemeContrast.iconFloor
        ) else { return XCTFail("2.95:1 is under the floor and must be corrected") }
        XCTAssertLessThan(plan.opacity, 0.1, "a 0.05 shortfall bought \(plan.opacity) of scrim")
    }

    // MARK: - Which way the scrim goes

    func testTheScrimMovesAwayFromTheGlyph() {
        // Light glyph on bright artwork -> darken.
        let onBright = plan(
            foreground: opaque(.white), over: flat(rgb(0.9, 0.9, 0.9)),
            floor: ThemeContrast.iconFloor
        )
        XCTAssertEqual(onBright?.isDark, true)

        // Dark glyph on artwork of much the same weight -> lighten. #2563EB
        // (relative luminance 0.155) is the real case: the accent-tinted
        // toolbar glyphs sit just BELOW the crossover, so darkening behind them
        // would make them worse, and the guard has to go the other way.
        XCTAssertLessThan(
            ThemeContrast.relativeLuminance(rgb(0.145, 0.388, 0.922)),
            ThemeContrast.scrimCrossoverLuminance
        )
        let onSimilar = plan(
            foreground: opaque(rgb(0.145, 0.388, 0.922)), over: flat(rgb(0.35, 0.3, 0.32)),
            floor: ThemeContrast.iconFloor
        )
        XCTAssertEqual(onSimilar?.isDark, false)

        // …and a plainly dark glyph on mid-grey, well clear of the crossover.
        let ink = plan(
            foreground: opaque(rgb(0.05, 0.05, 0.05)), over: flat(rgb(0.35, 0.35, 0.35)),
            floor: ThemeContrast.iconFloor
        )
        XCTAssertEqual(ink?.isDark, false)
    }

    /// The direction is picked by one constant, and the constant claims to be
    /// the luminance where black and white backdrops are worth the same. If it
    /// drifts, the guard starts choosing the harder direction on glyphs near
    /// the middle and needs more scrim than it should.
    func testTheCrossoverConstantIsWhereBlackAndWhiteAreWorthTheSame() {
        let crossover = ThemeContrast.scrimCrossoverLuminance
        XCTAssertEqual(
            ThemeContrast.ratio(crossover, 0), ThemeContrast.ratio(crossover, 1),
            accuracy: 0.001
        )
        // …and that shared value is the floor's ceiling: the worst any opaque
        // glyph can do with the better direction at full opacity.
        XCTAssertEqual(ThemeContrast.ratio(crossover, 0), 4.58, accuracy: 0.01)
        XCTAssertGreaterThan(ThemeContrast.ratio(crossover, 0), ThemeContrast.iconFloor)
    }

    // MARK: - The percentile

    /// Averaging is what makes a naive fix fail on real artwork: an icon over
    /// mostly-dark art with one bright highlight through it looks fine on
    /// average and is unreadable where the highlight is. Solving for the worst
    /// tenth is what catches that, and this is the test that says so.
    func testASmallBrightHighlightIsNotAveragedAway() {
        var backdrop = flat(rgb(0.05, 0.05, 0.08), count: 340)   // 85% very dark
        backdrop += flat(rgb(0.98, 0.98, 0.95), count: 60)       // 15% blown out

        // The mean says this is comfortable…
        let meanLevel = backdrop.map(\.red).reduce(0, +) / Double(backdrop.count)
        XCTAssertGreaterThan(
            ThemeContrast.ratio(
                ThemeContrast.relativeLuminance(.white),
                ThemeContrast.relativeLuminance(rgb(meanLevel, meanLevel, meanLevel))
            ),
            ThemeContrast.iconFloor
        )

        // …and the guard still corrects it, because a tenth of the region is not.
        guard let plan = plan(
            foreground: opaque(.white), over: backdrop, floor: ThemeContrast.iconFloor
        ) else { return XCTFail("a highlight over 15% of the region must not be averaged away") }
        XCTAssertGreaterThanOrEqual(plan.ratioAfter, ThemeContrast.iconFloor)
    }

    /// The other side of the same choice: a highlight smaller than the
    /// tolerance is deliberately NOT corrected. A guard with no tolerance would
    /// scrim a control because three pixels of its 400 are bright, and that is
    /// how artwork gets covered for no legibility gain.
    func testAHighlightInsideTheToleranceIsLeftAlone() {
        var backdrop = flat(rgb(0.05, 0.05, 0.08), count: 396)
        backdrop += flat(rgb(0.98, 0.98, 0.95), count: 4)        // 1% of the region
        XCTAssertNil(plan(
            foreground: opaque(.white), over: backdrop, floor: ThemeContrast.iconFloor
        ))
    }

    // MARK: - One decision for a whole cluster

    /// A cluster sample: `columns` wide, every column a flat colour taken from
    /// `levels`, so a row of artwork can be described by what is under each
    /// control.
    private func strip(_ levels: [Double], columnsEach: Int, rows: Int = 18) -> ThemeBackdropSample {
        var pixels: [ThemeContrast.RGB] = []
        for _ in 0..<rows {
            for level in levels {
                pixels += Array(repeating: rgb(level, level, level), count: columnsEach)
            }
        }
        let columns = levels.count * columnsEach
        return ThemeBackdropSample(
            pixels: pixels, columns: columns, rows: rows, pointWidth: CGFloat(columns)
        )
    }

    /// A row that is legible end to end keeps every pixel of its artwork. This
    /// is the answer the guard gives most of the time and the reason a theme
    /// that works is untouched.
    func testAClusterThatIsLegibleEndToEndGetsNoSurface() {
        let sample = strip(Array(repeating: 0.06, count: 9), columnsEach: 28)
        XCTAssertNil(ThemeContrast.plate(
            foreground: opaque(.white), sample: sample,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        ))
    }

    /// THE regression test for the defect this round exists to fix.
    ///
    /// Fourteen controls over comfortable artwork and ONE over a blown-out
    /// highlight. The bad patch is 6.7% of the row — inside the 10% the
    /// percentile is allowed to write off — so a percentile taken across the
    /// WHOLE row shrugs at it, and the last assertion here proves that. The
    /// guard has to size the surface for that one control, and then put the
    /// same surface under all fifteen.
    func testOneBadControlInALongRowStillSetsTheSurface() {
        var levels = Array(repeating: 0.06, count: 14)
        levels.insert(0.97, at: 9)
        let sample = strip(levels, columnsEach: 28)

        guard let plan = ThemeContrast.plate(
            foreground: opaque(.white), sample: sample,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        ) else { return XCTFail("one control on a blown-out highlight must set the surface") }

        // Every window clears afterwards, not just on average.
        for window in sample.windows(ofPoints: 28) {
            let scrimmed = window.map {
                ThemeContrast.composite(
                    ThemeContrast.RGBA(rgb: plan.isDark ? .black : .white, alpha: plan.opacity),
                    over: $0
                )
            }
            XCTAssertGreaterThanOrEqual(
                ThemeContrast.harmfulRatio(foreground: opaque(.white), backdrop: scrimmed),
                ThemeContrast.iconFloor
            )
        }

        // …and taking the percentile across the row instead would have called
        // this row fine, which is exactly why the window exists.
        let wholeRow = ThemeContrast.harmfulRatio(foreground: opaque(.white), backdrop: sample.pixels)
        XCTAssertGreaterThanOrEqual(
            wholeRow, ThemeContrast.iconFloor,
            "a row-wide percentile is supposed to miss this — if it no longer does, the case is too easy to be a regression test"
        )
    }

    /// The surface is the worst window's answer and no stronger: adding more
    /// comfortable artwork beside a bad patch must not change what is drawn.
    func testTheSurfaceIsTheWorstWindowAndNotAnAverageOfTheRow() {
        let bad = strip([0.97], columnsEach: 28)
        let mixed = strip([0.06, 0.06, 0.97, 0.06, 0.06], columnsEach: 28)

        let alone = ThemeContrast.plate(
            foreground: opaque(.white), sample: bad,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        let inARow = ThemeContrast.plate(
            foreground: opaque(.white), sample: mixed,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        XCTAssertNotNil(alone)
        XCTAssertNotNil(inARow)
        XCTAssertEqual(alone?.opacity ?? 0, inARow?.opacity ?? -1, accuracy: 0.02)
        XCTAssertEqual(alone?.isDark, inARow?.isDark)
    }

    /// One answer per cluster is the point: whatever the row is sitting on, the
    /// guard returns a single colour and a single opacity, never a set of them.
    func testAClusterOverWildlyVaryingArtworkStillGetsOneAnswer() {
        let sample = strip([0.02, 0.95, 0.4, 0.8, 0.1, 0.99, 0.3], columnsEach: 28)
        guard let plan = ThemeContrast.plate(
            foreground: opaque(.white), sample: sample,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        ) else { return XCTFail("artwork running to 0.99 fails a white glyph") }

        XCTAssertGreaterThanOrEqual(plan.ratioAfter, ThemeContrast.iconFloor)
        // A single opacity, applied everywhere — including where it was not
        // needed, which is what makes the row look like one treatment.
        XCTAssertGreaterThan(plan.opacity, 0)
        XCTAssertLessThanOrEqual(plan.opacity, 1)
    }

    // MARK: - Walking a cluster a control at a time

    func testWindowsCoverTheSampleAtControlWidth() {
        let sample = strip(Array(repeating: 0.5, count: 4), columnsEach: 28)   // 112pt wide
        let windows = sample.windows(ofPoints: 28)
        // 28pt windows striding 14pt across 112pt: 0, 14, 28, 42, 56, 70, 84.
        XCTAssertEqual(windows.count, 7)
        for window in windows {
            XCTAssertEqual(window.count, 28 * sample.rows)
        }
    }

    /// A region narrower than one control is one window — a lone button must
    /// not be sliced into pieces too small to mean anything.
    func testARegionNarrowerThanOneControlIsASingleWindow() {
        let sample = strip([0.5], columnsEach: 20)
        XCTAssertEqual(sample.windows(ofPoints: 28).count, 1)
        XCTAssertEqual(sample.windows(ofPoints: 28).first?.count, sample.pixels.count)
    }

    /// Windows overlap by half so a bad patch straddling a boundary is caught
    /// whole by the window centred on it rather than halved by both neighbours.
    func testAStraddlingHighlightIsCaughtByAnOverlappingWindow() {
        // A highlight in the middle 28pt of a 56pt region, so it lands across
        // the boundary of any non-overlapping pair of windows.
        var levels = Array(repeating: 0.06, count: 14)
        levels += Array(repeating: 0.97, count: 28)
        levels += Array(repeating: 0.06, count: 14)
        let sample = strip(levels, columnsEach: 1)

        XCTAssertNotNil(ThemeContrast.plate(
            foreground: opaque(.white), sample: sample,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        ))
    }

    func testAnEmptySampleGetsNoSurface() {
        XCTAssertNil(ThemeContrast.plate(
            foreground: opaque(.white), sample: .empty,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        ))
    }

    // MARK: - Shared layer placement

    /// The guard measures a backdrop it re-composites itself, so it is only
    /// measuring what is on screen if it places the header images the same way
    /// the canvas paints them. Both go through `ThemeHeaderLayerPlacement`;
    /// these are the placements that matter.

    func testARightTopImageHugsTheCanvasRightEdge() {
        let placement = ThemeHeaderLayerPlacement(alignment: "right top", tiling: "no-repeat")
        let rects = placement.tileRects(
            imageSize: CGSize(width: 3000, height: 200),
            canvas: CGSize(width: 1000, height: 800),
            origin: .zero,
            viewBounds: CGRect(x: 0, y: 0, width: 1000, height: 38)
        )
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, -2000, accuracy: 0.001)   // 1000 - 3000
        XCTAssertEqual(rects[0].minY, 0, accuracy: 0.001)
    }

    /// A surface further down the window sees the SAME image shifted up by its
    /// offset — that is what makes the tab strip and the toolbar two slices of
    /// one continuous backdrop rather than two copies of it.
    func testASurfaceOffsetInTheCanvasSeesItsOwnSliceOfTheSameImage() {
        let placement = ThemeHeaderLayerPlacement(alignment: "right top", tiling: "no-repeat")
        let toolbar = placement.tileRects(
            imageSize: CGSize(width: 3000, height: 200),
            canvas: CGSize(width: 1000, height: 800),
            origin: CGPoint(x: 0, y: 38),
            viewBounds: CGRect(x: 0, y: 0, width: 1000, height: 44)
        )
        XCTAssertEqual(toolbar.count, 1)
        XCTAssertEqual(toolbar[0].minY, -38, accuracy: 0.001)
    }

    func testAControlNearTheRightEdgeGetsTheImageShiftedByItsOwnOffset() {
        let placement = ThemeHeaderLayerPlacement(alignment: "left top", tiling: "no-repeat")
        let rects = placement.tileRects(
            imageSize: CGSize(width: 300, height: 200),
            canvas: CGSize(width: 1000, height: 800),
            origin: CGPoint(x: 120, y: 40),
            viewBounds: CGRect(x: 0, y: 0, width: 28, height: 28)
        )
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, -120, accuracy: 0.001)
        XCTAssertEqual(rects[0].minY, -40, accuracy: 0.001)
    }

    func testARepeatingLayerCoversTheWholeSurface() {
        let placement = ThemeHeaderLayerPlacement(alignment: "left top", tiling: "repeat-x")
        let rects = placement.tileRects(
            imageSize: CGSize(width: 100, height: 200),
            canvas: CGSize(width: 1000, height: 800),
            origin: CGPoint(x: 250, y: 0),
            viewBounds: CGRect(x: 0, y: 0, width: 320, height: 38)
        )
        XCTAssertEqual(rects.count, 4)
        XCTAssertEqual(rects.map { $0.minX }, [-50, 50, 150, 250])
    }

    /// Anything that cannot be drawn must not become a rectangle the sampler
    /// then reads pixels out of.
    func testADegenerateImageProducesNoTiles() {
        let placement = ThemeHeaderLayerPlacement(alignment: "right top", tiling: "no-repeat")
        XCTAssertTrue(placement.tileRects(
            imageSize: .zero,
            canvas: CGSize(width: 1000, height: 800),
            origin: .zero,
            viewBounds: CGRect(x: 0, y: 0, width: 28, height: 28)
        ).isEmpty)
    }

    /// Firefox's documented default when a theme's `theme.properties` says
    /// nothing, and the keywords are order-insensitive.
    func testAlignmentKeywordsParseTheWayFirefoxWritesThem() {
        let bottomLeft = ThemeHeaderLayerPlacement(alignment: "bottom left", tiling: "no-repeat")
        let rects = bottomLeft.tileRects(
            imageSize: CGSize(width: 100, height: 100),
            canvas: CGSize(width: 400, height: 300),
            origin: .zero,
            viewBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        XCTAssertEqual(rects[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(rects[0].minY, 200, accuracy: 0.001)
    }

    // MARK: - Helpers

    /// The sRGB component whose relative luminance is `luminance` (grey).
    private func srgb(forLuminance luminance: Double) -> Double {
        let clamped = min(max(luminance, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}
