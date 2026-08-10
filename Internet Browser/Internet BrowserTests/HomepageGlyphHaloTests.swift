//
//  HomepageGlyphHaloTests.swift
//  Internet BrowserTests
//
//  The homepage draws its clock, its greeting and its shortcut titles straight
//  onto a photograph, with no wash of any kind over the picture. All of the
//  legibility comes from a halo that hugs the glyphs.
//
//  A per-glyph treatment cannot be checked with per-glyph arithmetic: the halo
//  is a stack of blurred shadows, and what reaches the pixel beside a letter is
//  a rendering result, not a number anyone can write down. So this renders the
//  real thing — the real wallpaper asset, the real `HomepageGlyphHalo`, the real
//  type sizes — and samples the pixels that actually come out.
//
//  For each glyph pixel it measures against the backdrop pixels immediately
//  around that glyph, which is what "the actual wallpaper pixels behind them"
//  means for text that carries its own halo.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class HomepageGlyphHaloTests: XCTestCase {

    private let floor = 4.5

    /// The share of glyph pixels allowed to sit below the floor, matching the
    /// tail the theme guard already uses. Type is antialiased, so a strict
    /// worst-single-pixel reading would be measuring the renderer's edge ramp
    /// rather than the design.
    private let harmfulPercentile = 0.10

    /// The homepage's three type roles, with the real sizes, weights and
    /// opacities they are drawn at.
    private var roles: [(label: String, font: Font, text: String, opacity: Double)] {
        [
            ("clock", .system(size: 68, weight: .light, design: .rounded), "22:17", 1.0),
            ("shortcut title", .system(size: 12, weight: .medium), "Computer Scie", 1.0),
            ("greeting", .system(size: 17, weight: .medium, design: .rounded), "Good evening",
             HomepageText.supporting),
        ]
    }

    // MARK: - The bar

    func testTheClockClearsTheFloorOnEveryWallpaperInBothAppearances() throws {
        try assertClears(
            label: "clock",
            font: .system(size: 68, weight: .light, design: .rounded),
            text: "22:17",
            opacity: 1.0
        )
    }

    func testShortcutTitlesClearTheFloorOnEveryWallpaperInBothAppearances() throws {
        try assertClears(
            label: "shortcut title",
            font: .system(size: 12, weight: .medium),
            text: "Computer Scie",
            opacity: 1.0
        )
    }

    func testSupportingTextClearsTheFloorOnEveryWallpaperInBothAppearances() throws {
        try assertClears(
            label: "greeting",
            font: .system(size: 17, weight: .medium, design: .rounded),
            text: "Good evening",
            opacity: HomepageText.supporting
        )
    }

    // MARK: - The user's own picture

    /// The eight shipped wallpapers were vetted; a user's photo is not, and
    /// the brightest thing it can hold is pure white — the worst backdrop
    /// that can exist for white type. Text on a user-chosen picture is drawn
    /// with the reinforced halo (`HomepageGlyphHalo.treatment(for:)` maps
    /// `.customImage` to `.reinforced`), and every role must clear the same
    /// floor there that it clears on the shipped wallpapers.
    func testEveryRoleClearsTheFloorOnAWorstCaseWhitePictureWithTheReinforcedHalo() throws {
        for role in roles {
            try assertClears(
                label: role.label,
                font: role.font,
                text: role.text,
                opacity: role.opacity,
                halo: .reinforced,
                backdrops: [("pure white", .white)]
            )
        }
    }

    /// Why the reinforced stack exists at all: over pure white the standard
    /// stack leaves the faded greeting under the floor (measured 3.76:1
    /// against 4.5). If this test ever starts failing the standard halo has
    /// grown materially stronger, and the custom-image fork deserves a fresh
    /// measurement — do not silently point custom images back at `.standard`.
    func testTheStandardHaloAloneIsNotEnoughOnAWorstCaseWhitePicture() throws {
        let image = try render(
            backdrop: .white, text: "Good evening",
            font: .system(size: 17, weight: .medium, design: .rounded),
            opacity: HomepageText.supporting, halo: .standard, appearance: .aqua
        )
        let mask = try render(
            backdrop: .mask, text: "Good evening",
            font: .system(size: 17, weight: .medium, design: .rounded),
            opacity: 1.0, halo: .none, appearance: .aqua
        )
        XCTAssertLessThan(
            try harmfulRatio(image: image, mask: mask), floor,
            "the standard halo now clears pure white — remeasure whether the reinforced fork is still needed"
        )
    }

    // MARK: - The picture

    /// The point of the whole change: outside the glyphs, the wallpaper is the
    /// wallpaper. Rendered with the halo, the corners must be pixel-identical
    /// to the bare image.
    func testTheWallpaperIsUntouchedAwayFromTheGlyphs() throws {
        let asset = try XCTUnwrap(wallpaperNames.first)
        let withText = try render(
            backdrop: .asset(asset), text: "22:17",
            font: .system(size: 68, weight: .light, design: .rounded),
            opacity: 1.0, halo: .standard, appearance: .aqua
        )
        let bare = try render(
            backdrop: .asset(asset), text: "", font: .system(size: 68), opacity: 1.0,
            halo: .none, appearance: .aqua
        )

        // A generous margin in from every corner, well clear of the centred text.
        let inset = 8
        var compared = 0
        for (x, y) in [(inset, inset),
                       (withText.width - inset - 1, inset),
                       (inset, withText.height - inset - 1),
                       (withText.width - inset - 1, withText.height - inset - 1)] {
            let a = withText.pixel(x, y)
            let b = bare.pixel(x, y)
            XCTAssertEqual(a.r, b.r, accuracy: 0.004, "corner (\(x),\(y)) red moved")
            XCTAssertEqual(a.g, b.g, accuracy: 0.004, "corner (\(x),\(y)) green moved")
            XCTAssertEqual(a.b, b.b, accuracy: 0.004, "corner (\(x),\(y)) blue moved")
            compared += 1
        }
        XCTAssertEqual(compared, 4)
    }

    /// The regression this replaces. The old scrim dimmed the whole page, so
    /// the centre lost most of its saturation; with the wash gone the centre
    /// must keep essentially all of it away from the letters.
    func testTheCentreKeepsItsSaturation() throws {
        let asset = try XCTUnwrap(wallpaperNames.first)
        let bare = try render(
            backdrop: .asset(asset), text: "", font: .system(size: 68), opacity: 1.0,
            halo: .none, appearance: .aqua
        )
        let withText = try render(
            backdrop: .asset(asset), text: "22:17",
            font: .system(size: 68, weight: .light, design: .rounded),
            opacity: 1.0, halo: .standard, appearance: .aqua
        )

        // A band across the middle, skipping the vertical strip the text sits
        // in. The old build measured 8% saturation here against 37-40% at the
        // corners; there is no wash left to cost it anything.
        func meanSaturation(_ image: Sampled) -> Double {
            var total = 0.0
            var count = 0
            let y0 = image.height * 45 / 100, y1 = image.height * 55 / 100
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: 0, to: image.width / 5, by: 2) {
                    let p = image.pixel(x, y)
                    let hi = max(p.r, max(p.g, p.b)), lo = min(p.r, min(p.g, p.b))
                    total += hi <= 0 ? 0 : (hi - lo) / hi
                    count += 1
                }
            }
            return count == 0 ? 0 : total / Double(count)
        }

        let before = meanSaturation(bare)
        let after = meanSaturation(withText)
        XCTAssertEqual(
            after, before, accuracy: 0.01,
            "the halo cost the picture \(Int((1 - after / max(before, 0.0001)) * 100))% of its saturation"
        )
    }

    // MARK: - Measuring

    /// - Parameters:
    ///   - halo: the treatment under test — `.standard` is what the shipped
    ///     wallpapers get, `.reinforced` what a user-chosen picture gets.
    ///   - backdrops: what to measure against; nil means every shipped
    ///     wallpaper.
    private func assertClears(
        label: String, font: Font, text: String, opacity: Double,
        halo: HomepageGlyphHalo.Treatment = .standard,
        backdrops: [(name: String, backdrop: Backdrop)]? = nil
    ) throws {
        let backdrops = backdrops ?? wallpaperNames.map { ($0, Backdrop.asset($0)) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                   ("dark", NSAppearance.Name.darkAqua)] {
            var worst = (ratio: Double.infinity, backdrop: "")
            for (backdropName, backdrop) in backdrops {
                let image = try render(
                    backdrop: backdrop, text: text, font: font, opacity: opacity,
                    halo: halo, appearance: appearance
                )
                let mask = try render(
                    backdrop: .mask, text: text, font: font, opacity: 1.0,
                    halo: .none, appearance: appearance
                )
                let ratio = try harmfulRatio(image: image, mask: mask)
                if ratio < worst.ratio { worst = (ratio, backdropName) }
            }
            XCTAssertGreaterThanOrEqual(
                worst.ratio, floor,
                "\(label) measures \(worst.ratio):1 on \(worst.backdrop) in \(name)"
            )
        }
    }

    /// Contrast of each glyph pixel against the backdrop right beside it, at
    /// the harmful tail.
    private func harmfulRatio(image: Sampled, mask: Sampled) throws -> Double {
        XCTAssertEqual(image.width, mask.width)
        XCTAssertEqual(image.height, mask.height)

        // How far out to look for the backdrop a glyph is judged against: far
        // enough to be outside the letterform, close enough to still be the
        // pixels a reader sees it against.
        let reach = 3
        var ratios: [Double] = []

        for y in stride(from: reach, to: image.height - reach, by: 1) {
            for x in stride(from: reach, to: image.width - reach, by: 1) {
                // A glyph pixel: fully covered in the mask, so its colour in
                // the render is the text and not an antialiased blend.
                guard mask.coverage(x, y) > 0.98 else { continue }

                // The nearest pixels the mask says are not glyph at all.
                var backdrops: [Double] = []
                for (dx, dy) in [(reach, 0), (-reach, 0), (0, reach), (0, -reach)] {
                    guard mask.coverage(x + dx, y + dy) < 0.02 else { continue }
                    backdrops.append(image.luminance(x + dx, y + dy))
                }
                guard !backdrops.isEmpty else { continue }

                let glyph = image.luminance(x, y)
                // The worst of the neighbours, because a glyph sitting half on
                // a bright patch is only as readable as its worst side.
                for backdrop in backdrops {
                    ratios.append((max(glyph, backdrop) + 0.05) / (min(glyph, backdrop) + 0.05))
                }
            }
        }

        XCTAssertFalse(ratios.isEmpty, "no glyph pixels were found to measure")
        ratios.sort()
        let index = Int((Double(ratios.count - 1) * harmfulPercentile).rounded(.down))
        return ratios[index]
    }

    // MARK: - Rendering

    private var wallpaperNames: [String] {
        AccentColorOption.options.compactMap {
            HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: $0.hex)
        }
    }

    private struct Sampled {
        let rep: NSBitmapImageRep
        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                return (0, 0, 0, 0)
            }
            return (Double(c.redComponent), Double(c.greenComponent),
                    Double(c.blueComponent), Double(c.alphaComponent))
        }

        /// White-on-black mask coverage.
        func coverage(_ x: Int, _ y: Int) -> Double {
            let p = pixel(x, y)
            return max(p.r, max(p.g, p.b))
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let p = pixel(x, y)
            func channel(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(p.r) + 0.7152 * channel(p.g) + 0.0722 * channel(p.b)
        }
    }

    /// What the text is rendered over.
    private enum Backdrop {
        /// A shipped wallpaper asset.
        case asset(String)
        /// The brightest backdrop a user's photo can hold — the worst case
        /// that can exist for white type.
        case white
        /// Black, for the coverage mask: the same type, white, with no halo,
        /// so glyph coverage can be told from backdrop brightness.
        case mask
    }

    /// Renders the text over the backdrop exactly as the homepage composes
    /// them, through the real `homepageGlyphHalo(_:)` the homepage applies.
    private func render(
        backdrop: Backdrop, text: String, font: Font, opacity: Double,
        halo: HomepageGlyphHalo.Treatment, appearance: NSAppearance.Name
    ) throws -> Sampled {
        let size = CGSize(width: 320, height: 160)

        let content = ZStack {
            switch backdrop {
            case .asset(let name):
                Image(name).resizable().scaledToFill()
            case .white:
                Color.white
            case .mask:
                Color.black
            }
            Text(text)
                .font(font)
                .foregroundStyle(Color.white.opacity(opacity))
                .homepageGlyphHalo(halo)
        }
        .frame(width: size.width, height: size.height)
        .clipped()

        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return Sampled(rep: rep)
    }
}
