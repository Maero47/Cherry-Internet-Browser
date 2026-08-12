//
//  PearlContrastTests.swift
//  Internet BrowserTests
//
//  Whether Pearl can actually be SEEN on the surfaces she is drawn on, and
//  whether her hearts can.
//
//  ## Why this measures a silhouette and not text on a picture
//
//  The usual contrast question about artwork is "does the type over it clear
//  the floor". Here the answer is that there is no type over it: nothing in
//  the wizard and nothing on the library screens draws a single character on
//  top of Pearl. Her name sits under her on the welcome, her sign-off sits
//  beside her on the last step, the empty-screen headline sits under her. That
//  was a design decision, and it means the honest contrast question is a
//  different one:
//
//      **she is a nearly-black cat, and half the surfaces she stands on are
//      nearly black too. Does she disappear?**
//
//  What stops her is the cream rim light that traces her whole silhouette —
//  the thing that makes the artwork work on dark backgrounds — and, on light
//  backgrounds, her own dark mass just inside it. So this measures her OUTLINE
//  BAND: the opaque pixels within three of a transparent one, which is exactly
//  the edge a reader's eye finds her by.
//
//  ## The bar
//
//  WCAG 1.4.11 asks 3:1 of a graphical object against what is adjacent to it.
//  A silhouette does not have one adjacency, it has thousands, and it does not
//  need every one of them — a cat whose top and left edges separate cleanly is
//  a visible cat even if her bottom edge melts. So the bar is the **75th
//  percentile of the outline band**: at least a quarter of her edge clears
//  3:1.
//
//  Measured, at the time of writing, on every pose against every surface in
//  both appearances, the worst 75th percentile is **9.9:1** — so this is not a
//  bar being scraped. What it catches is the real failure: a pose drawn or
//  re-cut without its rim light collapses to about 1.2:1 on the dark surfaces
//  (the median already sits there — her fur genuinely is as dark as dark mode),
//  and a pose that came out pale would collapse the same way on white.
//
//  Nothing here captures the screen. It decodes the shipped imagesets into an
//  sRGB buffer of its own and does arithmetic on them.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class PearlContrastTests: XCTestCase {

    /// WCAG 1.4.11, non-text contrast.
    private let floor = 3.0

    /// How much of the outline has to clear it. See the file comment.
    private let outlinePercentile = 0.75

    /// The two surfaces Pearl is ever drawn on, resolved from the same colours
    /// the views use rather than typed in as hex: the wizard sheet's material
    /// and the library list's.
    private var surfaces: [(name: String, color: NSColor)] {
        [
            ("the wizard sheet", .windowBackgroundColor),
            ("a library screen", .controlBackgroundColor),
        ]
    }

    private var appearances: [(name: String, appearance: NSAppearance.Name)] {
        [("light", .aqua), ("dark", .darkAqua)]
    }

    // MARK: - She does not disappear

    func testEveryPoseSeparatesFromEverySurfaceInBothAppearances() throws {
        for pose in PearlMascot.Pose.allCases {
            let band = try outlineLuminances(of: pose)
            XCTAssertGreaterThan(band.count, 200,
                                 "\(pose) produced almost no outline to measure — did it decode?")

            for (surfaceName, surfaceColor) in surfaces {
                for (appearanceName, appearance) in appearances {
                    let backdrop = luminance(of: surfaceColor, in: appearance)
                    let ratios = band.map { contrast($0, backdrop) }.sorted()
                    let index = Int((Double(ratios.count - 1) * (1 - outlinePercentile)).rounded(.up))
                    let atPercentile = ratios[ratios.count - 1 - index]

                    XCTAssertGreaterThanOrEqual(
                        atPercentile, floor,
                        """
                        \(pose) melts into \(surfaceName) in \(appearanceName): only a quarter of \
                        her outline reaches \(String(format: "%.2f", atPercentile)):1 against a \
                        backdrop of luminance \(String(format: "%.3f", backdrop))
                        """
                    )
                }
            }
        }
    }

    /// The rim light is doing the work on dark surfaces, and this says so out
    /// loud: her MEDIAN outline pixel fails badly against a dark backdrop —
    /// her fur really is as dark as dark mode — and it is only the cream edge
    /// that saves her. If this test ever starts passing, the artwork has been
    /// lightened materially and the percentile bar above deserves a fresh look
    /// rather than being quietly trusted.
    func testHerFurAloneWouldNotSeparateInDarkMode() throws {
        let band = try outlineLuminances(of: .waving)
        let backdrop = luminance(of: .controlBackgroundColor, in: .darkAqua)
        let ratios = band.map { contrast($0, backdrop) }.sorted()
        let median = ratios[ratios.count / 2]

        XCTAssertLessThan(median, floor,
                          "Pearl's fur now clears the floor unaided — remeasure the rim-light claim")
    }

    // MARK: - The hearts

    /// Her hearts are drawn over the sheet and over her own fur, so they are
    /// measured against both. Dies on: someone tinting them with the user's
    /// accent (Cherry's palette runs to yellows, which do not survive a light
    /// sheet) or picking a prettier rose that does not.
    func testTheHeartsClearTheFloorOnTheSheetAndOnPearlHerself() throws {
        let heart = NSColor(PearlMascot.heartTint)

        for (appearanceName, appearance) in appearances {
            let ink = luminance(of: heart, in: appearance)

            let sheet = luminance(of: .windowBackgroundColor, in: appearance)
            XCTAssertGreaterThanOrEqual(
                contrast(ink, sheet), floor,
                "the hearts measure \(String(format: "%.2f", contrast(ink, sheet))):1 on the \(appearanceName) sheet"
            )

            // The darkest part of her — the hearts rise straight out of her
            // back, so this is a real adjacency and not a hypothetical one.
            let fur = try darkestFurLuminance(of: .sitting)
            XCTAssertGreaterThanOrEqual(
                contrast(ink, fur), floor,
                "the hearts measure \(String(format: "%.2f", contrast(ink, fur))):1 over her own fur in \(appearanceName)"
            )
        }
    }

    // MARK: - Measuring

    /// The luminance of every opaque pixel within three of a transparent one:
    /// the edge a reader finds her by.
    private func outlineLuminances(of pose: PearlMascot.Pose) throws -> [Double] {
        let bitmap = try decode(pose)
        let reach = 3
        var band: [Double] = []

        for y in reach..<(bitmap.height - reach) {
            for x in reach..<(bitmap.width - reach) {
                guard bitmap.alpha(x, y) >= 0.9 else { continue }
                var touchesOutside = false
                for (dx, dy) in [(reach, 0), (-reach, 0), (0, reach), (0, -reach)]
                where bitmap.alpha(x + dx, y + dy) <= 0.1 {
                    touchesOutside = true
                    break
                }
                guard touchesOutside else { continue }
                band.append(bitmap.luminance(x, y))
            }
        }
        return band
    }

    /// The 5th-percentile (darkest) opaque pixel — a real patch of her, not
    /// one stray shadow pixel.
    private func darkestFurLuminance(of pose: PearlMascot.Pose) throws -> Double {
        let bitmap = try decode(pose)
        var opaque: [Double] = []
        for y in stride(from: 0, to: bitmap.height, by: 2) {
            for x in stride(from: 0, to: bitmap.width, by: 2) where bitmap.alpha(x, y) >= 0.9 {
                opaque.append(bitmap.luminance(x, y))
            }
        }
        opaque.sort()
        return opaque[Int(Double(opaque.count - 1) * 0.05)]
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A dynamic system colour resolved for one appearance, in sRGB.
    private func luminance(of color: NSColor, in appearance: NSAppearance.Name) -> Double {
        var result = 0.0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            result = Self.relativeLuminance(
                Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)
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

    /// The pose's own pixels, in an sRGB buffer this test owns — no screen, no
    /// window, no appearance involved. The imageset is asked for its largest
    /// representation so the outline band is measured at the resolution the
    /// artwork was drawn at.
    private func decode(_ pose: PearlMascot.Pose) throws -> Bitmap {
        let image = try XCTUnwrap(pose.image, "\(pose) did not resolve out of the catalog")
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
            "\(pose) has no bitmap behind it"
        )

        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    /// Premultiplied sRGB, un-premultiplied on read.
    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> Double {
            Double(pixels[(y * width + x) * 4 + 3]) / 255
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            let a = Double(pixels[i + 3]) / 255
            guard a > 0 else { return 0 }
            let r = Double(pixels[i]) / 255 / a
            let g = Double(pixels[i + 1]) / 255 / a
            let b = Double(pixels[i + 2]) / 255 / a
            return PearlContrastTests.relativeLuminance(min(r, 1), min(g, 1), min(b, 1))
        }
    }
}
