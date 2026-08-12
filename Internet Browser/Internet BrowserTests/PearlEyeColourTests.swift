//
//  PearlEyeColourTests.swift
//  Internet BrowserTests
//
//  `PearlEyes.shipping` says what colour Pearl's eyes are. This is what makes
//  that a fact about the shipped artwork rather than a comment.
//
//  ## Why a constant needs a test at all
//
//  The eye colour lives in two places that a person has to keep in step by
//  hand: one line of Swift, and the pixels of eleven PNGs painted by
//  `Tools/pearl-eyes/pearl_eyes.py`. Doing one without the other is the
//  obvious mistake, it is silent, and it is the exact mistake somebody makes
//  when they decide to go back to amber in a hurry. So the constant is
//  measured against the artwork here — both kinds of it, by two different
//  methods, because the two kinds of artwork are different.
//
//  ## The sprite sheet is pinned by exact pixel counts; the paintings by hue
//
//  The sheet is seven flat colours, so its irises can be counted exactly —
//  and they are, frame by frame, including the three frames where her eyes
//  are SHUT and the right answer is zero.
//
//  It takes two tables to do that, because the two colours are not
//  symmetrical. Purple exists in the sheet only where this round put it, so
//  counting purple per frame says everything about the eyes: under purple the
//  counts must be the table, under amber they must all be zero. Gold cannot
//  carry that claim, because her bright iris gold is ALSO the rim light on her
//  ears, the gold on her tail and the fish she eats — counting gold in a frame
//  counts her ears too. So gold is pinned the other way round, as a total per
//  frame that must come down by EXACTLY the iris count and not by one more,
//  which is the claim that the recolour took her eyes and left her rim light
//  alone — and the claim that under amber her eyes are still there at all.
//
//  The painterly poses are continuous-tone and anti-aliased, so nothing about
//  them can be pinned to an exact value. What is stable is WHERE THE HUE
//  SITS: measured over the iris pixels inside her eyes, amber's circular mean
//  lands near 70° in OKLCh and purple's near 306°, and they are 237° apart.
//  A tolerance of 25° is therefore a wide door that only the right colour
//  fits through.
//
//  Nothing here captures the screen. It reads the shipped bundle's own
//  bitmaps into an sRGB buffer of its own and does arithmetic on them.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlEyeColourTests: XCTestCase {

    private var library: PearlSpriteLibrary { .shared }

    // MARK: - The sprite sheet

    /// Every frame of Pearl in the sheet, and how many iris pixels it has.
    ///
    /// `pet_blink`, `pet_happy` and `pet_sleep` are zero because her eyes are
    /// closed in them — that is the correct answer for those poses, and it is
    /// pinned so that a future recolour which "helpfully" finds eyes in a
    /// sleeping cat fails here rather than shipping a cat who dreams in
    /// colour.
    private let irisPixels: [String: [Int]] = [
        "run": [18, 25],
        "jump": [24],
        "hit": [43],
        "duck": [25, 24],
        "pet_sit": [24, 24],
        "pet_blink": [0],
        "pet_groom": [24, 24],
        "pet_happy": [0],
        "pet_eat": [14, 14],
        "pet_sleep": [0, 0],
    ]

    /// Every gold pixel in each of Pearl's frames when her eyes are amber —
    /// the two iris values, which in amber are ALSO the rim light on her ears
    /// and her back, the gold on her tail, and the fish in `pet_eat`.
    ///
    /// This is the other half of the pin: the recolour must take her irises
    /// and nothing else, so under purple each of these numbers has to come
    /// down by exactly the iris count above and not by one more. `pet_blink`,
    /// `pet_happy` and `pet_sleep` do not move at all, which is what "her
    /// eyes are shut, so there was nothing to take" looks like as a number.
    private let amberGoldPixels: [String: [Int]] = [
        "run": [51, 77],
        "jump": [67],
        "hit": [66],
        "duck": [75, 68],
        "pet_sit": [58, 58],
        "pet_blink": [34],
        "pet_groom": [71, 71],
        "pet_happy": [50],
        "pet_eat": [87, 81],
        "pet_sleep": [29, 29],
    ]

    /// Dies on: `pearl_eyes.py paint` not having been run after `shipping`
    /// was changed, or run for the other colour; a regenerated sheet whose
    /// eyes came back gold (`build_pet_frames.py` snaps to the amber palette
    /// and will do exactly this); an iris that grew or lost a pixel.
    func testTheSheetsIrisPixelsAreTheDeclaredColour() throws {
        XCTAssertTrue(library.hasArtwork, "the library is in placeholder mode")
        let purple = PearlEyes.Colour.purple
        let expected = PearlEyes.shipping == .purple

        for (name, counts) in irisPixels.sorted(by: { $0.key < $1.key }) {
            for (index, count) in counts.enumerated() {
                let slice = try XCTUnwrap(library.slice(name, frame: index),
                                          "\(name)[\(index)] does not slice")
                let found = Self.pixels(slice, matching: [purple.spriteIris, purple.spriteIrisShade])
                XCTAssertEqual(
                    found, expected ? count : 0,
                    """
                    \(name)[\(index)] has \(found) purple iris pixels and \
                    PearlEyes.shipping is \(PearlEyes.shipping.rawValue). Run \
                    `python3 Tools/pearl-eyes/pearl_eyes.py paint \
                    \(PearlEyes.shipping.rawValue)`.
                    """
                )
            }
        }
    }

    /// The recolour took her irises and left every other gold pixel where it
    /// was: her rim light, her ears, the fish. This is the claim the purple
    /// count above cannot make on its own — a paint step that turned her whole
    /// rim light purple would still have put the right number of purple pixels
    /// in her eyes.
    ///
    /// It is also what proves the eyes are still THERE under amber, which
    /// counting purple cannot: a sheet with her eyes erased satisfies
    /// "no purple pixels" perfectly.
    ///
    /// Dies on: the iris mask leaking into her rim light (`pearl_eyes.py`'s
    /// blob rule is one 4-connected diagonal away from her cheek edge in
    /// `hit`, and this is the test that notices if it ever lets go); a sheet
    /// regenerated with a different palette.
    func testTheRecolourTookHerIrisesAndNothingElseGold() throws {
        let amber = PearlEyes.Colour.amber
        for (name, golds) in amberGoldPixels.sorted(by: { $0.key < $1.key }) {
            let irises = try XCTUnwrap(irisPixels[name], "\(name) is in one table and not the other")
            XCTAssertEqual(golds.count, irises.count, "\(name) frame counts disagree")
            for (index, gold) in golds.enumerated() {
                let slice = try XCTUnwrap(library.slice(name, frame: index))
                let taken = PearlEyes.shipping == .purple ? irises[index] : 0
                XCTAssertEqual(
                    Self.pixels(slice, matching: [amber.spriteIris, amber.spriteIrisShade]),
                    gold - taken,
                    "\(name)[\(index)]: the recolour took the wrong gold pixels"
                )
            }
        }
    }

    // MARK: - The painterly poses

    /// Where each pose's eyes are, as fractions of its own size — so this
    /// holds whichever representation the asset catalog hands back, 1x or 2x.
    ///
    /// `PearlCurled` is absent on purpose and the test below says why.
    private let eyes: [PearlMascot.Pose: [CGRect]] = [
        .gazing: [CGRect(x: 0.2037, y: 0.13125, width: 0.0926, height: 0.05313),
                  CGRect(x: 0.35802, y: 0.17656, width: 0.11112, height: 0.05782)],
        .waving: [CGRect(x: 0.30882, y: 0.15, width: 0.12868, height: 0.05625),
                  CGRect(x: 0.54044, y: 0.16875, width: 0.12868, height: 0.05625)],
        .sitting: [CGRect(x: 0.26429, y: 0.20076, width: 0.17142, height: 0.09469),
                   CGRect(x: 0.55, y: 0.20076, width: 0.17143, height: 0.09469)],
        .delighted: [CGRect(x: 0.26266, y: 0.13906, width: 0.0981, height: 0.05469),
                     CGRect(x: 0.42722, y: 0.18125, width: 0.12341, height: 0.06406)],
    ]

    /// Dies on: a pose's imageset being replaced by one with different eyes;
    /// the paint step being run for four poses and missed on the fifth.
    func testEveryPaintedPosesIrisesAreTheDeclaredColour() throws {
        for (pose, rects) in eyes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let bitmap = try decode(pose)
            var hues: [Double] = []
            for rect in rects {
                hues.append(contentsOf: bitmap.irisHues(in: rect))
            }
            XCTAssertGreaterThan(hues.count, 30,
                                 "\(pose) produced almost no iris to measure — did it decode?")

            let mean = Self.circularMean(hues)
            let target = PearlEyes.shipping.paintedHue
            XCTAssertLessThanOrEqual(
                Self.separation(mean, target), PearlEyes.paintedHueTolerance,
                """
                \(pose)'s irises sit at \(String(format: "%.1f", mean))° in OKLCh, and \
                PearlEyes.shipping is \(PearlEyes.shipping.rawValue), which is \
                \(String(format: "%.0f", target))°. Run `python3 \
                Tools/pearl-eyes/pearl_eyes.py paint \(PearlEyes.shipping.rawValue)`.
                """
            )
        }
    }

    /// She is asleep in `PearlCurled` — her eyes are two dark arcs and the
    /// drawing has no iris in it — so there is nothing in that pose for an eye
    /// colour to be, and `pearl_eyes.py` copies her through byte for byte.
    /// Said out loud here so that the pose missing from the table above reads
    /// as an answer rather than as an omission, and so that a sixth pose
    /// cannot arrive without somebody deciding where its eyes are.
    func testTheSleepingPoseHasNoIrisToColourEitherWay() {
        XCTAssertNil(eyes[.curled])
        XCTAssertEqual(Set(eyes.keys).union([.curled]), Set(PearlMascot.Pose.allCases),
                       "a pose was added or renamed without deciding where its eyes are")
    }

    // MARK: - Counting

    private static func pixels(_ image: CGImage,
                               matching wanted: [(red: UInt8, green: UInt8, blue: UInt8)]) -> Int {
        let bytes = rgba(image)
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 250 {
            for colour in wanted
            where abs(Int(bytes[index]) - Int(colour.red)) <= 2
                && abs(Int(bytes[index + 1]) - Int(colour.green)) <= 2
                && abs(Int(bytes[index + 2]) - Int(colour.blue)) <= 2 {
                count += 1
                break
            }
        }
        return count
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func decode(_ pose: PearlMascot.Pose) throws -> Bitmap {
        let image = try XCTUnwrap(pose.image, "\(pose) did not resolve out of the catalog")
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                                    "\(pose) has no bitmap behind it")
        return Bitmap(width: cgImage.width, height: cgImage.height, pixels: Self.rgba(cgImage))
    }

    // MARK: - Hue, on a circle

    private static func circularMean(_ degrees: [Double]) -> Double {
        var x = 0.0, y = 0.0
        for value in degrees {
            x += cos(value * .pi / 180)
            y += sin(value * .pi / 180)
        }
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The short way round between two hues.
    private static func separation(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    /// Premultiplied sRGB, with just enough OKLab to ask what hue a pixel is.
    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        /// The OKLCh hue of every iris pixel inside a normalized rectangle:
        /// opaque, chromatic, and light. Lightness is the discriminator that
        /// matters — her fur is the same hue as amber at half the lightness,
        /// so without it this would measure her cheeks.
        func irisHues(in unit: CGRect) -> [Double] {
            var hues: [Double] = []
            let x0 = Int(unit.minX * CGFloat(width)), x1 = Int(unit.maxX * CGFloat(width))
            let y0 = Int(unit.minY * CGFloat(height)), y1 = Int(unit.maxY * CGFloat(height))
            for y in max(0, y0)..<min(height, y1) {
                for x in max(0, x0)..<min(width, x1) {
                    let index = (y * width + x) * 4
                    let alpha = Double(pixels[index + 3]) / 255
                    guard alpha > 0.9 else { continue }
                    let (lightness, chroma, hue) = Self.oklch(
                        min(Double(pixels[index]) / 255 / alpha, 1),
                        min(Double(pixels[index + 1]) / 255 / alpha, 1),
                        min(Double(pixels[index + 2]) / 255 / alpha, 1)
                    )
                    if chroma >= 0.08 && lightness >= 0.45 {
                        hues.append(hue)
                    }
                }
            }
            return hues
        }

        private static func oklch(_ r: Double, _ g: Double, _ b: Double)
        -> (lightness: Double, chroma: Double, hue: Double) {
            func linear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let red = linear(r), green = linear(g), blue = linear(b)
            let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
            let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
            let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
            let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            let hue = (atan2(bb, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            return (lightness, (a * a + bb * bb).squareRoot(), hue)
        }
    }
}
