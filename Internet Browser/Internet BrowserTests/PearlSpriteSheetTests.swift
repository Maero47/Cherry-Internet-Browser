//
//  PearlSpriteSheetTests.swift
//  Internet BrowserTests
//
//  The seam neither the game branch nor the art branch could test alone.
//
//  `PearlSpriteManifestTests` proves the manifest parses and conforms;
//  `PearlAssetTests` proves the artwork exists. Both stayed green while the
//  two halves disagreed about how the sheet reaches the app — the art shipped
//  it as a compiled asset-catalog imageset, the game looked for a loose
//  bundle resource — and the running game quietly drew placeholder rectangles
//  forever.
//
//  These tests close that seam by asserting on the join: the shipped
//  manifest, the shipped sheet, and `PearlSpriteLibrary` in the middle
//  actually producing real pixels. Screenshot verification is banned in this
//  repo, so this file is the only thing standing between a refactor of the
//  delivery path and a silently art-less game.
//

import XCTest
import AppKit
@testable import Cherry

@MainActor
final class PearlSpriteSheetTests: XCTestCase {

    private var appBundle: Bundle { Bundle(for: PearlSpriteLibrary.self) }

    // MARK: - The sheet reaches the app

    /// The delivery decision, pinned: the sheet ships as a LOOSE bundle
    /// resource, not as an asset-catalog imageset, because the manifest
    /// addresses exact pixels and an imageset is compiled into `Assets.car`
    /// where no such file exists.
    func testTheSpriteSheetShipsAsALooseBundleResource() throws {
        let url = try XCTUnwrap(
            appBundle.url(forResource: "pearl-sprites", withExtension: "png"),
            "pearl-sprites.png must ship as a loose resource; an imageset is "
            + "compiled into Assets.car and this lookup returns nil"
        )
        let sheet = try XCTUnwrap(NSImage(contentsOf: url), "the shipped sheet must decode")
        XCTAssertGreaterThan(sheet.size.width, 0)
        XCTAssertGreaterThan(sheet.size.height, 0)
    }

    // MARK: - The library resolves it into real slices

    func testTheLibraryLoadsTheRealSheetAndNotPlaceholders() throws {
        let library = PearlSpriteLibrary(bundle: appBundle)

        XCTAssertNotNil(library.manifest, "the shipped manifest must decode")
        XCTAssertEqual(library.manifest?.conformanceIssues(), [])
        XCTAssertTrue(
            library.hasArtwork,
            "the library fell back to placeholder rectangles: it found the "
            + "manifest but could not reach the sheet the manifest maps"
        )
        let size = try XCTUnwrap(library.sheetPixelSize, "a loaded sheet must report its pixel size")
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// Every rectangle in the manifest must lie inside the sheet the library
    /// actually loaded, proved by the slice coming back at full requested
    /// size — `CGImage.cropping` silently returns the intersection, so a
    /// short slice is a rectangle hanging off the edge.
    func testEveryContractFrameSlicesOutOfTheRealSheetAtItsFullSize() throws {
        let library = PearlSpriteLibrary(bundle: appBundle)
        let manifest = try XCTUnwrap(library.manifest)
        let sheet = try XCTUnwrap(library.sheetPixelSize, "no sheet loaded, so nothing to slice")

        for (name, expectedCount) in PearlSpriteContract.frameCounts.sorted(by: { $0.key < $1.key }) {
            let boxes = manifest.frames(name)
            XCTAssertEqual(boxes.count, expectedCount, "\(name) frame count")

            for (index, box) in boxes.enumerated() {
                XCTAssertGreaterThanOrEqual(box.x, 0, "\(name)[\(index)] x")
                XCTAssertGreaterThanOrEqual(box.y, 0, "\(name)[\(index)] y")
                XCTAssertLessThanOrEqual(
                    Double(box.x + box.w), sheet.width,
                    "\(name)[\(index)] runs off the right edge of the \(Int(sheet.width))px sheet"
                )
                XCTAssertLessThanOrEqual(
                    Double(box.y + box.h), sheet.height,
                    "\(name)[\(index)] runs off the bottom edge of the \(Int(sheet.height))px sheet"
                )

                let slice = try XCTUnwrap(
                    library.slice(name, frame: index),
                    "\(name)[\(index)] produced no pixels from the real sheet"
                )
                XCTAssertEqual(slice.width, box.w, "\(name)[\(index)] sliced width")
                XCTAssertEqual(slice.height, box.h, "\(name)[\(index)] sliced height")
            }
        }
    }

    /// A slice of solid nothing would satisfy the geometry above while still
    /// being an empty sheet, so check the drawn frames carry actual ink.
    func testPearlsOwnFramesCarryVisiblePixels() throws {
        let library = PearlSpriteLibrary(bundle: appBundle)

        for (name, index) in [("run", 0), ("run", 1), ("duck", 0), ("jump", 0),
                              ("hit", 0), ("gull", 0), ("tree_small", 0), ("ground", 0)] {
            let slice = try XCTUnwrap(library.slice(name, frame: index), "\(name)[\(index)] missing")
            XCTAssertGreaterThan(
                opaquePixelCount(slice), 0,
                "\(name)[\(index)] is fully transparent — the sheet region is blank"
            )
        }
    }

    private func opaquePixelCount(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { count, alpha in
            if pixels[alpha] > 0 { count += 1 }
        }
    }

    // MARK: - Exactly one manifest

    /// Two source files named `pearl-sprites.json` both want to be flattened
    /// into `Contents/Resources/`; Xcode calls that "Multiple commands
    /// produce" and fails the build. This asserts on what actually shipped,
    /// which also catches a copy that lands in a Resources subdirectory and
    /// so never collides at all.
    ///
    /// It walks the built bundle rather than the source tree on purpose: the
    /// test host is sandboxed, and reaching back into the checkout goes
    /// through TCC, which turns a millisecond of I/O into minutes of waiting.
    func testExactlyOnePearlSpritesManifestShipsInTheApp() throws {
        let resources = appBundle.bundleURL.appending(path: "Contents/Resources")
        let shipped = FileManager.default
            .enumerator(at: resources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "pearl-sprites.json" } ?? []

        XCTAssertEqual(
            shipped.count, 1,
            "exactly one pearl-sprites.json may ship; found \(shipped.count): "
            + shipped.map { $0.path(percentEncoded: false) }.joined(separator: ", ")
        )
        XCTAssertEqual(
            shipped.first, appBundle.url(forResource: "pearl-sprites", withExtension: "json"),
            "the manifest the library loads must be the one that shipped"
        )
    }

    // MARK: - Pixel art stays pixel art

    /// The sheet is authored at 1x and the renderer must magnify it with
    /// nearest-neighbour. `Image.interpolation(.none)` is what does that, and
    /// a manifest scale of 1 is what keeps the slices at their authored size
    /// rather than being halved into a blur.
    func testTheSheetIsAuthoredAtOneToOneWithTheContract() throws {
        let library = PearlSpriteLibrary(bundle: appBundle)
        let manifest = try XCTUnwrap(library.manifest)
        XCTAssertEqual(manifest.scale, 1, "a 1x sheet: manifest pixels are contract points")

        let run = try XCTUnwrap(library.slice("run", frame: 0))
        XCTAssertEqual(Double(run.width) / Double(manifest.scale), PearlSpriteContract.run.width)
        XCTAssertEqual(Double(run.height) / Double(manifest.scale), PearlSpriteContract.run.height)
    }
}
