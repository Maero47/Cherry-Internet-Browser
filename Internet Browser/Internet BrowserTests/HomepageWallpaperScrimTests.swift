//
//  HomepageWallpaperScrimTests.swift
//  Internet BrowserTests
//
//  The homepage draws its clock, its greeting and its shortcut titles straight
//  onto a photograph. Whether that text is readable is not a matter of opinion,
//  and it is not a matter of one screenshot on one wallpaper either: it depends
//  on the worst pixel of the worst of the eight shipped wallpapers, in both
//  appearances.
//
//  So this measures exactly that, against the real image assets, using the
//  scrim constants the app actually ships.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

final class HomepageWallpaperScrimTests: XCTestCase {

    private let floor = 4.5

    /// `HomePageView.foreground` in light mode. Dark mode is plain white.
    private let lightInk = (r: 0.09, g: 0.08, b: 0.11)

    // MARK: - The measurements the comment claims

    func testPrimaryHomepageTextClearsTheFloorOnEveryWallpaper() throws {
        for dark in [false, true] {
            let (ratio, wallpaper) = try worstContrast(dark: dark, textOpacity: 1.0)
            XCTAssertGreaterThanOrEqual(
                ratio, floor,
                "the clock and shortcut titles measure \(ratio):1 on \(wallpaper) in \(dark ? "dark" : "light")"
            )
        }
    }

    func testSupportingHomepageTextClearsTheFloorOnEveryWallpaper() throws {
        for dark in [false, true] {
            let (ratio, wallpaper) = try worstContrast(dark: dark, textOpacity: HomepageText.supporting)
            XCTAssertGreaterThanOrEqual(
                ratio, floor,
                "supporting text measures \(ratio):1 on \(wallpaper) in \(dark ? "dark" : "light")"
            )
        }
    }

    /// The tone the homepage used to use for its greeting and its subtitle.
    /// If this ever passes, the scrim has become heavy enough to fade text
    /// again, which is worth knowing.
    func testTheOldFadedTonesWouldStillFail() throws {
        let (ratio, _) = try worstContrast(dark: false, textOpacity: 0.48)
        XCTAssertLessThan(ratio, floor, "0.48 now clears the floor; the scrim has got heavier")
    }

    // MARK: - The wallpaper has to survive

    /// The point of the change. Outside the content column only the flat veil
    /// applies, and it must leave the picture recognisably a picture.
    func testMostOfTheWallpaperSurvivesOutsideTheContentColumn() {
        XCTAssertLessThanOrEqual(
            HomepageWallpaperScrim.flatVeil, 0.15,
            "the flat veil covers the whole image, so it is the one that costs the wallpaper"
        )
        XCTAssertEqual(
            1 - HomepageWallpaperScrim.flatVeil, 0.88, accuracy: 0.001,
            "88% of the wallpaper should show at the edges"
        )
    }

    /// Neither appearance may quietly become the washed-out one again. The old
    /// values were 0.32 light against 0.28 dark for the flat veil; the flat
    /// veil is now a single number, so that asymmetry cannot come back.
    func testTheFlatVeilCostsBothAppearancesTheSame() {
        // One constant, no appearance branch: this is the assertion.
        XCTAssertEqual(HomepageWallpaperScrim.flatVeil, 0.12, accuracy: 0.0001)
    }

    /// Dark needs a deeper pool than light. Pinned because it looks like an
    /// asymmetry worth "tidying up", and tidying it up would drop dark's clock
    /// back under the floor.
    func testDarkNeedsADeeperCentrePoolThanLight() {
        XCTAssertGreaterThan(
            HomepageWallpaperScrim.centrePool(dark: true),
            HomepageWallpaperScrim.centrePool(dark: false)
        )
    }

    // MARK: - Measuring

    /// Worst contrast across every shipped wallpaper, in the band the content
    /// occupies, with the flat veil and the centre pool both applied.
    private func worstContrast(dark: Bool, textOpacity: Double) throws -> (Double, String) {
        let wallpapers = try loadWallpapers()
        XCTAssertEqual(wallpapers.count, 8, "expected the eight shipped wallpapers")

        let veil: (r: Double, g: Double, b: Double) = dark ? (0, 0, 0) : (1, 1, 1)
        let ink: (r: Double, g: Double, b: Double) = dark ? (1, 1, 1) : lightInk
        let flat = HomepageWallpaperScrim.flatVeil
        let pool = HomepageWallpaperScrim.centrePool(dark: dark)

        var worst = (ratio: Double.infinity, name: "")
        for (name, pixels) in wallpapers {
            for pixel in pixels {
                var background = blend(pixel, veil, flat)
                background = blend(background, veil, pool)
                let text = blend(background, ink, textOpacity)
                let ratio = contrast(luminance(text), luminance(background))
                if ratio < worst.ratio { worst = (ratio, name) }
            }
        }
        return (worst.ratio, worst.name)
    }

    /// Samples the band the clock, the search field and the favourites row
    /// occupy: the middle 60% across, 22%..82% down.
    private func loadWallpapers() throws -> [(String, [(r: Double, g: Double, b: Double)])] {
        // Resolved from the shipped accents rather than hard-coded, so a new
        // accent with a new wallpaper is measured the day it lands.
        let names = AccentColorOption.options.compactMap {
            HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: $0.hex)
        }
        return try names.map { name in
            let image = try XCTUnwrap(NSImage(named: name), "missing wallpaper asset \(name)")
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let rep = NSBitmapImageRep(cgImage: cg)
            var pixels: [(r: Double, g: Double, b: Double)] = []
            let w = rep.pixelsWide, h = rep.pixelsHigh
            for y in stride(from: Int(Double(h) * 0.22), to: Int(Double(h) * 0.82), by: max(1, h / 60)) {
                for x in stride(from: Int(Double(w) * 0.20), to: Int(Double(w) * 0.80), by: max(1, w / 60)) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    pixels.append((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
                }
            }
            return (name, pixels)
        }
    }

    private func blend(
        _ base: (r: Double, g: Double, b: Double),
        _ top: (r: Double, g: Double, b: Double),
        _ alpha: Double
    ) -> (r: Double, g: Double, b: Double) {
        (base.r * (1 - alpha) + top.r * alpha,
         base.g * (1 - alpha) + top.g * alpha,
         base.b * (1 - alpha) + top.b * alpha)
    }

    private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
