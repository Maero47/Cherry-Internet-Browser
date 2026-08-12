//
//  PearlRunnerContrastTests.swift
//  Internet BrowserTests
//
//  Whether the runner can be PLAYED — the cat, the things that kill her, and
//  the score, measured against the field they are actually drawn on.
//
//  ## What this measures, and where it gets it
//
//  Nothing here captures a screen. It decodes the shipped sprite sheet through
//  `PearlSpriteLibrary` — the same slices the canvas draws — into an sRGB
//  buffer of its own, and it takes the field and the ink from
//  `PearlRunnerCanvas` itself, built around a real `PearlRunnerGame` moved to
//  a day or a night distance. Asking the palette instead would prove only that
//  the palette is self-consistent; asking the canvas is what dies when a
//  colour is hardcoded back into the renderer.
//
//  ## The bars
//
//  - **Artwork: 3:1** (WCAG 1.4.11), on the 75th percentile of each frame's
//    OUTLINE BAND — the opaque pixels within three of a transparent one, which
//    is the edge the eye finds a sprite by. This is `PearlContrastTests`'s bar
//    for exactly the same reason it gives there: a sprite does not have one
//    adjacency, it has thousands, and a shape whose top and left separate
//    cleanly is a visible shape even where its underside melts.
//  - **Text: 4.5:1**, for the 11pt score and the 12pt overlay line.
//  - **The ground: 2:1.** It is the one element measured below the artwork
//    floor and it is deliberate. The ground is not a glyph, it is a 560-point
//    horizon: three rows of `#C9A86A` over nine of `#8A6A42`, running the full
//    width of the field with Pearl standing on it. Its top edge is what marks
//    the running line, and no field in the legible band can give that tan more
//    than about 2.5:1 — a field dark enough to lift it is a field Pearl has
//    already vanished into. It measured 2.10:1 on the old paper field too, so
//    this is the bar the horizon has always been at, now stated out loud.
//
//  ## Why there is no per-appearance sweep of the field itself
//
//  Because the answer would be the same twice: the field is a static sRGB
//  tone, not a dynamic colour, and `testTheFieldIsTheSameColourInBothAppearances`
//  is what holds it that way. That is the design — see `PearlRunnerPalette` —
//  and it is also what makes the offline screen safe under an imported theme:
//  a legibility budget that depended on the page's colour would be a budget a
//  theme could spend. What IS measured per appearance is the field against the
//  page, which is the defect this file was opened for.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class PearlRunnerContrastTests: XCTestCase {

    /// WCAG 1.4.11, non-text contrast.
    private let artworkFloor = 3.0
    /// WCAG 1.4.3 for text below 18pt.
    private let textFloor = 4.5
    /// The horizon. See the file comment.
    private let horizonFloor = 2.0
    /// How much of a sprite's outline has to clear the artwork floor.
    private let outlinePercentile = 0.75

    /// Every frame the runner draws, and nothing the desktop pet draws.
    private let cast: [(String, Int)] = [
        ("run", 0), ("run", 1), ("jump", 0), ("duck", 0), ("duck", 1), ("hit", 0),
        ("tree_small", 0), ("tree_large", 0), ("gull", 0), ("gull", 1),
        ("cloud", 0), ("moon", 0), ("star", 0),
    ]

    private var library: PearlSpriteLibrary {
        PearlSpriteLibrary(bundle: Bundle(for: PearlSpriteLibrary.self))
    }

    /// All four skies, not two. Every state the field can be in owes the same
    /// measurement, and the two new ones (dusk at 350, dawn at 1050) are
    /// measured here for the first time rather than argued from the fact that
    /// they sit between the old two.
    private var fields: [(name: String, canvas: PearlRunnerCanvas)] {
        PearlSky.allCases.map { ("the \($0) field", canvas(sky: $0)) }
    }

    // MARK: - The cast

    /// The whole reason this file exists: every drawn thing separates from the
    /// field, in day and at night, with no help from the appearance.
    ///
    /// Dies on: the field going back to paper (the gull and the cloud fail),
    /// the field going Chrome-dark (Pearl and both trees fail), the day and
    /// night tones drifting out of the 0.139–0.183 window `PearlRunnerPalette`
    /// solves for, and a sprite being redrawn without its own internal
    /// contrast.
    func testEveryDrawnThingSeparatesFromTheFieldInDayAndAtNight() throws {
        for (fieldName, canvas) in fields {
            let field = luminance(canvas.background)
            for (name, index) in cast {
                let band = try outlineLuminances(of: name, frame: index)
                XCTAssertGreaterThan(band.count, 20,
                                     "\(name)[\(index)] produced almost no outline — did it decode?")
                let measured = percentile(of: band, on: field)
                XCTAssertGreaterThanOrEqual(
                    measured, artworkFloor,
                    """
                    \(name)[\(index)] melts into \(fieldName): only a quarter of its outline \
                    reaches \(string(measured)):1
                    """
                )
            }
        }
    }

    /// The horizon, held to its own stated bar because it is a horizon and not
    /// a glyph. Dies on a field bright enough to swallow the tan — which is
    /// the direction the old paper field failed in.
    func testTheGroundStripStillMarksTheRunningLine() {
        // The tile's top three rows, which are the edge the sky meets.
        let tan = NSColor(srgbRed: 0xC9 / 255, green: 0xA8 / 255, blue: 0x6A / 255, alpha: 1)
        for (fieldName, canvas) in fields {
            let measured = contrast(luminance(tan), luminance(canvas.background))
            XCTAssertGreaterThanOrEqual(
                measured, horizonFloor,
                "the ground's top edge measures \(string(measured)):1 against \(fieldName)"
            )
        }
    }

    /// The score and the game-over line, at the strength they are drawn at
    /// between blinks. The blink itself is not measured: it is five short
    /// pulses of a number that is already on screen, it is dropped entirely
    /// under Reduce Motion, and holding a deliberate flash to a reading floor
    /// would just delete it.
    ///
    /// Dies on: the score going back to `ink.opacity(0.75)` (4.78 falls to
    /// 3.48 on the day field), the ink being softened to the sheet's cream,
    /// or the field being lifted past 0.183 where white ink stops holding
    /// 4.5:1.
    func testTheScoreAndTheOverlayLineClearTheTextFloor() {
        for (fieldName, canvas) in fields {
            // Through the app's own compositing measurement, because the score
            // carries an opacity and reading its raw components would report
            // the flattering number rather than the drawn one.
            let field = NSColor(canvas.background)
            for (role, tone) in [("the score", canvas.scoreInk(blinkedOut: false)),
                                 ("the overlay line", canvas.ink)] {
                let measured = LibraryPalette.contrastRatio(NSColor(tone), on: field)
                XCTAssertGreaterThanOrEqual(
                    measured, textFloor,
                    "\(role) measures \(string(measured)):1 on \(fieldName)"
                )
            }
        }
    }

    // MARK: - The mark, before anybody presses anything

    /// Pearl at rest is the same near-black cat, and the offline page in Dark
    /// Aqua is `#1E1E1E`: standing straight on it she measured 1.22:1, which
    /// is a cat-shaped hole where every other failure family has a symbol. So
    /// she stands on a chip of the game's own field, and this measures her on
    /// the tone the mark actually carries — found by walking the mark's own
    /// body, so deleting the chip fails here rather than passing quietly.
    ///
    /// Dies on: the chip being removed, and on the chip being tinted to
    /// anything Pearl does not separate from.
    func testTheIdleMarkStandsOnTheGamesOwnField() throws {
        let tones = colours(in: PearlStillMark().body)
        XCTAssertFalse(tones.isEmpty, "the mark draws no tone of its own at all")

        let field = NSColor(PearlRunnerPalette.day)
        let chip = try XCTUnwrap(
            tones.first { NSColor($0) == field },
            "the mark no longer stands on the game's field; it carries \(tones)"
        )
        let band = try outlineLuminances(of: "run", frame: 0)
        let measured = percentile(of: band, on: luminance(chip))
        XCTAssertGreaterThanOrEqual(
            measured, artworkFloor,
            "Pearl measures \(string(measured)):1 on the mark she stands on"
        )
    }

    /// The number the mark's own comment quotes for the page it used to stand
    /// on, so the reason the chip exists cannot quietly stop being true.
    func testPearlWouldNotReadOnTheDarkPageWithoutIt() throws {
        let page = luminance(FailurePalette.surface, in: .darkAqua)
        let measured = percentile(of: try outlineLuminances(of: "run", frame: 0), on: page)
        XCTAssertEqual(measured, 1.22, accuracy: 0.02)
        XCTAssertLessThan(measured, artworkFloor)
    }

    /// Every `Color` stored anywhere in a view's body. SwiftUI keeps a
    /// `.background(shape.fill(colour))` as stored values in the modifier
    /// tree, so this finds the chip's tone; a body with no fill in it comes
    /// back empty, which is the point.
    private func colours(in value: Any, depth: Int = 0) -> [Color] {
        if let colour = value as? Color { return [colour] }
        guard depth < 40 else { return [] }
        return Mirror(reflecting: value).children.flatMap { colours(in: $0.value, depth: depth + 1) }
    }

    // MARK: - The field against the page

    /// The reported defect, as a number. A field is a picture on a page: it
    /// has to be visibly its own object (a floor) and it must not be a hole
    /// punched in the page (a ceiling), in EITHER appearance, because the same
    /// field is drawn in both.
    ///
    /// Dies on: the field going back to paper — `#F7F7F5` measures 15.5:1
    /// against the Dark Aqua page, which is the bug — and on a field that
    /// creeps close enough to the page to lose its edge.
    func testTheFieldIsAPanelOnThePageAndNotAHolePunchedInIt() {
        let ceiling = 6.0
        let floor = 1.5
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (fieldName, canvas) in fields {
                let page = luminance(FailurePalette.surface, in: appearance)
                let measured = contrast(luminance(canvas.background), page)
                XCTAssertLessThanOrEqual(
                    measured, ceiling,
                    "\(fieldName) measures \(string(measured)):1 against the \(label) page — that is a hole, not a panel"
                )
                XCTAssertGreaterThanOrEqual(
                    measured, floor,
                    "\(fieldName) measures \(string(measured)):1 against the \(label) page — the panel has no edge"
                )
            }
        }
    }

    /// The old field, measured, so the ceiling above has a wall behind it and
    /// nobody has to take the bug report's word for it.
    func testTheFieldThatShippedBeforeWouldFailThatCeilingInDarkMode() {
        let paper = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1)
        let page = luminance(FailurePalette.surface, in: .darkAqua)
        XCTAssertGreaterThan(
            contrast(luminance(paper), page), 15.0,
            "the old day field no longer measures as the slab it was; re-derive the ceiling"
        )
    }

    // MARK: - Neither appearance nor theme may move it

    /// The field is a fixed sRGB tone, not a dynamic colour. This is what
    /// keeps every ratio above true in both appearances without measuring
    /// them twice — and what keeps an imported theme, which can put its own
    /// colours on Cherry's surfaces, from being able to spend the game's
    /// legibility budget.
    ///
    /// Dies on someone "fixing" dark mode the obvious way: making the field a
    /// `dynamic(light:dark:)` NSColor like `FailurePalette.caution`.
    func testTheFieldIsTheSameColourInBothAppearances() throws {
        for (_, canvas) in fields {
            let light = try XCTUnwrap(
                resolve(canvas.background, in: .aqua)?.usingColorSpace(.sRGB))
            let dark = try XCTUnwrap(
                resolve(canvas.background, in: .darkAqua)?.usingColorSpace(.sRGB))
            XCTAssertEqual(light.redComponent, dark.redComponent, accuracy: 0.001)
            XCTAssertEqual(light.greenComponent, dark.greenComponent, accuracy: 0.001)
            XCTAssertEqual(light.blueComponent, dark.blueComponent, accuracy: 0.001)
        }
    }

    /// Nightfall still reaches the renderer, and the ink no longer follows it.
    /// Dies on the canvas ignoring `isNight` (one flat field forever) and on
    /// the ink being flipped back with the sky, which is the Chrome-runner
    /// move this palette gave up.
    func testNightMovesTheFieldAndLeavesTheInkAlone() {
        let day = canvas(sky: .day)
        let night = canvas(sky: .night)
        XCTAssertNotEqual(NSColor(day.background), NSColor(night.background),
                          "nightfall no longer changes the sky")
        XCTAssertEqual(NSColor(day.ink), NSColor(night.ink),
                       "the ink flips with the sky again; the field no longer crosses the middle")
    }

    /// Four skies, four tones — and the point of adding two of them was that
    /// the player can SEE the run has got somewhere, so no two of them may be
    /// the same colour.
    ///
    /// Dies on a new phase being added to `PearlSky` without a tone of its
    /// own (the palette's `switch` would have to fall back to an existing
    /// one), and on dusk or dawn being quietly aliased to day or night.
    func testEverySkyIsADifferentTone() {
        let tones = PearlSky.allCases.map { NSColor(canvas(sky: $0).background) }
        for (index, tone) in tones.enumerated() {
            for other in tones[(index + 1)...] {
                XCTAssertNotEqual(tone, other, "two of the four skies are the same colour")
            }
        }
    }

    /// The change between consecutive skies is carried by HUE, not by
    /// brightness — because brightness is the axis this artwork has already
    /// spent (see `PearlRunnerPalette`'s 0.139–0.183 window, which is 0.044
    /// wide in total). Stated as a bound so a later reader who "fixes" the
    /// dusk tone by darkening it fails here rather than in the sprite bars.
    ///
    /// Dies on any sky leaving the window, in either direction.
    func testNoSkyLeavesTheWindowTheArtworkWasSolvedFor() {
        for (name, canvas) in fields {
            let measured = luminance(canvas.background)
            XCTAssertGreaterThanOrEqual(measured, 0.139,
                                        "\(name) is at \(measured); below 0.139 the trees go")
            XCTAssertLessThanOrEqual(measured, 0.183,
                                     "\(name) is at \(measured); above 0.183 the score stops reading")
        }
    }

    // MARK: - The arithmetic itself

    /// This file does its own luminance arithmetic over decoded pixels rather
    /// than through `NSColor`, so it says so out loud and checks the two agree.
    /// The same guard `ThemeContrastGuardTests` keeps over its own fast path.
    func testThisFilesArithmeticAgreesWithTheAppsOwn() {
        for colour in [NSColor.white, NSColor.black,
                       NSColor(srgbRed: 0.4, green: 0.45, blue: 0.5, alpha: 1)] {
            let mine = contrast(luminance(colour), luminance(NSColor(PearlRunnerPalette.day)))
            let theirs = LibraryPalette.contrastRatio(colour, on: NSColor(PearlRunnerPalette.day))
            XCTAssertEqual(mine, theirs, accuracy: 0.01)
        }
    }

    // MARK: - Why neither extreme was available

    /// The argument in `PearlRunnerPalette`'s header, re-measured: a paper
    /// field deletes the gull and the cloud, a Chrome-style dark field deletes
    /// Pearl and the trees, and those are the two fields that used to ship.
    /// Both directions are checked because a later reader's first instinct
    /// will be one of them.
    ///
    /// Dies on the sheet being redrawn — a paler cat or a shaded gull would
    /// widen the window, and the dusk field would then be a choice worth
    /// re-taking rather than the only one on the table.
    func testNeitherAPaperFieldNorADarkOneWouldServeThisSheet() throws {
        let paper = luminance(NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        XCTAssertLessThan(percentile(of: try outlineLuminances(of: "gull", frame: 0), on: paper),
                          artworkFloor, "a paper field now carries the gull; re-take the decision")
        XCTAssertLessThan(percentile(of: try outlineLuminances(of: "cloud", frame: 0), on: paper),
                          artworkFloor)

        let chromeDark = luminance(NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1))
        XCTAssertLessThan(percentile(of: try outlineLuminances(of: "run", frame: 0), on: chromeDark),
                          artworkFloor, "a dark field now carries Pearl; re-take the decision")
        XCTAssertLessThan(percentile(of: try outlineLuminances(of: "tree_large", frame: 0), on: chromeDark),
                          artworkFloor)
    }

    /// The numbers `PearlRunnerPalette`'s header quotes, so the prose that
    /// justifies the two tones cannot drift away from the tones themselves.
    /// The same guard `FailureContrastTests` keeps over its own comment.
    func testTheNumbersTheHeaderQuotesAreTheRealOnes() throws {
        XCTAssertEqual(luminance(PearlRunnerPalette.day), 0.170, accuracy: 0.001)
        XCTAssertEqual(luminance(PearlRunnerPalette.dusk), 0.163, accuracy: 0.001)
        XCTAssertEqual(luminance(PearlRunnerPalette.night), 0.152, accuracy: 0.001)
        XCTAssertEqual(luminance(PearlRunnerPalette.dawn), 0.159, accuracy: 0.001)

        let paper = luminance(NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        XCTAssertEqual(percentile(of: try outlineLuminances(of: "gull", frame: 0), on: paper),
                       2.07, accuracy: 0.01)
        XCTAssertEqual(percentile(of: try outlineLuminances(of: "cloud", frame: 0), on: paper),
                       1.07, accuracy: 0.01)

        let chromeDark = luminance(NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1))
        XCTAssertEqual(percentile(of: try outlineLuminances(of: "run", frame: 0), on: chromeDark),
                       1.30, accuracy: 0.01)
        XCTAssertEqual(percentile(of: try outlineLuminances(of: "tree_large", frame: 0), on: chromeDark),
                       1.80, accuracy: 0.01)
    }

    // MARK: - Building the thing under test

    /// A canvas around a real game, moved to a score inside the sky asked for.
    /// The assertion is part of the fixture: a dusk canvas that is quietly a
    /// day one would measure the same field twice and report four passes for
    /// two tones.
    private func canvas(sky: PearlSky) -> PearlRunnerCanvas {
        let score = PearlSky.allCases.firstIndex(of: sky)! * PearlTuning.skyPhaseScore
        var game = PearlRunnerGame(seed: 1)
        game.distance = Double(score) / PearlTuning.pointsPerDistance
        XCTAssertEqual(game.sky, sky, "the fixture did not reach \(sky)")
        return PearlRunnerCanvas(
            game: game, highScore: 0, isTicking: true, isMuted: false, reduceMotion: false
        )
    }

    // MARK: - Measuring

    private func percentile(of band: [Double], on field: Double) -> Double {
        let ratios = band.map { contrast($0, field) }.sorted()
        let index = Int((Double(ratios.count - 1) * (1 - outlinePercentile)).rounded(.up))
        return ratios[ratios.count - 1 - index]
    }

    /// The luminance of every opaque pixel within three of a transparent one —
    /// or of the frame's edge, since a sprite drawn flush to its own rectangle
    /// still meets the field there.
    private func outlineLuminances(of name: String, frame index: Int) throws -> [Double] {
        let bitmap = try decode(name, frame: index)
        let reach = 3
        var band: [Double] = []

        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.alpha(x, y) >= 0.9 {
                let outside = [(reach, 0), (-reach, 0), (0, reach), (0, -reach)].contains {
                    bitmap.alpha(x + $0.0, y + $0.1) <= 0.1
                }
                if outside { band.append(bitmap.luminance(x, y)) }
            }
        }
        return band
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: Color) -> Double {
        luminance(NSColor(color))
    }

    private func luminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        return Self.relativeLuminance(Double(srgb.redComponent),
                                      Double(srgb.greenComponent),
                                      Double(srgb.blueComponent))
    }

    /// A dynamic colour resolved for one appearance. The `NSColor` is built
    /// INSIDE the drawing block on purpose: `NSColor(_: Color)` bakes the
    /// appearance it is built in, so hoisting it out would measure whichever
    /// appearance the test host happens to be running under, twice.
    private func luminance(_ color: Color, in appearance: NSAppearance.Name) -> Double {
        guard let srgb = resolve(color, in: appearance) else { return 0 }
        return Self.relativeLuminance(Double(srgb.redComponent),
                                      Double(srgb.greenComponent),
                                      Double(srgb.blueComponent))
    }

    private func resolve(_ color: Color, in appearance: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    private func string(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    nonisolated private static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// A frame's own pixels, in an sRGB buffer this test owns. Taken from the
    /// library rather than from the file so a change to how the sheet is
    /// delivered is measured rather than missed.
    private func decode(_ name: String, frame index: Int) throws -> Bitmap {
        let slice = try XCTUnwrap(
            library.slice(name, frame: index),
            "\(name)[\(index)] produced no pixels — the sheet did not reach the app"
        )
        let width = slice.width, height = slice.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    /// Premultiplied sRGB, un-premultiplied on read. Out-of-bounds reads
    /// answer "transparent", which is what makes a sprite's own frame edge
    /// count as an edge.
    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> Double {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return Double(pixels[(y * width + x) * 4 + 3]) / 255
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            let a = Double(pixels[i + 3]) / 255
            guard a > 0 else { return 0 }
            let r = Double(pixels[i]) / 255 / a
            let g = Double(pixels[i + 1]) / 255 / a
            let b = Double(pixels[i + 2]) / 255 / a
            return PearlRunnerContrastTests.relativeLuminance(min(r, 1), min(g, 1), min(b, 1))
        }
    }
}
