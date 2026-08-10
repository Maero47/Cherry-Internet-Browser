//
//  HomepageCustomImageStoreTests.swift
//  Internet BrowserTests
//
//  The lifecycle of the picture a user chooses for their homepage: chosen →
//  copied into Cherry's own storage → survives relaunch and the original's
//  disappearance → removed → the copy is gone — and every way the file can be
//  wrong (not an image, corrupt, huge, HEIC, transparent) is dealt with at
//  import, so the homepage's render path never meets it.
//
//  Every test runs against a real filesystem in a scratch directory;
//  "relaunch" means a fresh store instance pointed at the same directory,
//  which is exactly what an app relaunch does.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Cherry

@MainActor
final class HomepageCustomImageStoreTests: XCTestCase {

    private var directory: URL!
    private var pickedDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomepageCustomImageStoreTests-\(UUID().uuidString)", isDirectory: true)
        directory = base.appendingPathComponent("store", isDirectory: true)
        pickedDirectory = base.appendingPathComponent("picked", isDirectory: true)
        try FileManager.default.createDirectory(at: pickedDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // MARK: - Chosen → copied → survives

    func testChoosingCopiesThePictureIntoOwnedStorage() throws {
        let picked = try makePicture(named: "picked.jpg", width: 640, height: 400)
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: picked)

        XCTAssertNotNil(store.image)
        let stored = try XCTUnwrap(store.storedFileURL)
        XCTAssertTrue(
            stored.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path),
            "the copy must live inside the store's own directory, not at \(stored.path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

        // The picked file is never referenced again: it can vanish (volume
        // unmounted, folder cleaned) without costing the homepage anything.
        try FileManager.default.removeItem(at: picked)
        let relaunched = HomepageCustomImageStore(directory: directory)
        XCTAssertNotNil(relaunched.image, "the copy must not depend on the file the user picked")
    }

    func testTheCopySurvivesRelaunch() throws {
        let picked = try makePicture(named: "picked.jpg", width: 640, height: 400)
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: picked)

        let relaunched = HomepageCustomImageStore(directory: directory)
        XCTAssertNotNil(relaunched.image)
        XCTAssertEqual(relaunched.storedFileURL, store.storedFileURL)
    }

    // MARK: - Removed → cleaned up

    func testRemovalDeletesTheCopyNotJustThePreference() throws {
        let picked = try makePicture(named: "picked.jpg", width: 640, height: 400)
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: picked)

        store.removeImage()

        XCTAssertNil(store.image)
        XCTAssertNil(store.storedFileURL)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [], "removal must delete the copy, not merely stop showing it")
        XCTAssertNil(
            HomepageCustomImageStore(directory: directory).image,
            "a relaunch after removal must find nothing"
        )
    }

    // MARK: - Missing or unreadable falls out of availability

    func testACopyThatDiedBehindTheStoresBackReadsAsUnavailable() throws {
        let picked = try makePicture(named: "picked.jpg", width: 640, height: 400)
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: picked)
        let stored = try XCTUnwrap(store.storedFileURL)

        // Storage cleaned out from under the app.
        try FileManager.default.removeItem(at: stored)
        XCTAssertNil(HomepageCustomImageStore(directory: directory).image)

        // Or the file survives but its bytes rot.
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01, 0x02, 0x03]).write(to: stored)
        XCTAssertNil(
            HomepageCustomImageStore(directory: directory).image,
            "a corrupt copy must read as unavailable, not as a broken draw"
        )
    }

    // MARK: - Bad input is refused at the door

    func testAFileThatIsNotAPictureIsRefusedAndCostsNothing() throws {
        let store = HomepageCustomImageStore(directory: directory)
        let good = try makePicture(named: "good.jpg", width: 640, height: 400)
        try store.importImage(from: good)

        let text = pickedDirectory.appendingPathComponent("notes.txt")
        try Data("not a picture".utf8).write(to: text)
        XCTAssertThrowsError(try store.importImage(from: text))

        let corrupt = pickedDirectory.appendingPathComponent("broken.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x41, count: 128)).write(to: corrupt)
        XCTAssertThrowsError(try store.importImage(from: corrupt))

        XCTAssertNotNil(store.image, "a failed import must never cost the picture already stored")
        let stored = try XCTUnwrap(store.storedFileURL)
        XCTAssertNotNil(NSImage(contentsOf: stored), "the stored copy must still decode")
    }

    // MARK: - Huge files are downsampled once, at import

    func testAHugePictureIsDownsampledAtImportNotAtEveryDraw() throws {
        let huge = try makePicture(named: "huge.jpg", width: 6000, height: 500)
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: huge)

        let (width, height) = try storedPixelSize(of: store)
        XCTAssertEqual(
            max(width, height), HomepageCustomImageStore.maxPixelSize,
            "the long edge must be capped at the store's ceiling"
        )
        let expectedShortEdge = 500.0 * Double(HomepageCustomImageStore.maxPixelSize) / 6000.0
        XCTAssertEqual(
            Double(min(width, height)), expectedShortEdge, accuracy: 2,
            "downsampling must keep the aspect"
        )
    }

    func testAReasonablePictureKeepsItsPixels() throws {
        let picked = try makePicture(named: "picked.jpg", width: 640, height: 400)
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: picked)

        let (width, height) = try storedPixelSize(of: store)
        XCTAssertEqual(width, 640)
        XCTAssertEqual(height, 400)
    }

    // MARK: - Formats

    func testHEICIsNormalizedIntoAFormatTheHomepageAlwaysHandles() throws {
        let heic: URL
        do {
            heic = try makePicture(named: "photo.heic", width: 800, height: 600, type: .heic)
        } catch {
            throw XCTSkip("this machine cannot encode HEIC to build the fixture")
        }
        let store = HomepageCustomImageStore(directory: directory)
        try store.importImage(from: heic)

        XCTAssertNotNil(store.image)
        XCTAssertEqual(try XCTUnwrap(store.storedFileURL).pathExtension, "jpg")
    }

    func testATransparentPNGKeepsItsAlphaAndOnlyOneCopyEverExists() throws {
        let store = HomepageCustomImageStore(directory: directory)
        let transparent = try makePicture(named: "glass.png", width: 300, height: 300, type: .png, alpha: true)
        try store.importImage(from: transparent)
        XCTAssertEqual(try XCTUnwrap(store.storedFileURL).pathExtension, "png")

        // Replacing it with an opaque photo must retire the PNG: exactly one
        // stored file, ever.
        let photo = try makePicture(named: "photo.jpg", width: 300, height: 300)
        try store.importImage(from: photo)
        XCTAssertEqual(try XCTUnwrap(store.storedFileURL).pathExtension, "jpg")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "a replaced picture must not leave its old copy behind: \(files)")
    }

    // MARK: - The entry point the homepage actually calls

    /// `SettingsManager.homepageBackgroundSource` with the real shared store:
    /// a chosen picture wins in ordinary AND private windows, and removing it
    /// falls back to the accent wallpaper rather than to nothing.
    func testTheSettingsEntryPointServesTheChosenPictureAndFallsBackOnRemoval() throws {
        let settings = SettingsManager.shared
        let store = HomepageCustomImageStore.shared

        let savedMatches = settings.homepageMatchesAccent
        let savedUsesTheme = settings.homepageUsesThemeBackground
        let savedUsesCustom = settings.homepageUsesCustomImage
        let savedAccent = settings.accentColorHex
        var backup: URL?
        if let current = store.storedFileURL {
            backup = FileManager.default.temporaryDirectory
                .appendingPathComponent("store-backup-\(UUID().uuidString).\(current.pathExtension)")
            try FileManager.default.copyItem(at: current, to: backup!)
        }
        defer {
            if let backup {
                try? store.importImage(from: backup)
                try? FileManager.default.removeItem(at: backup)
            } else {
                store.removeImage()
            }
            settings.homepageMatchesAccent = savedMatches
            settings.homepageUsesThemeBackground = savedUsesTheme
            settings.homepageUsesCustomImage = savedUsesCustom
            settings.accentColorHex = savedAccent
        }

        let picked = try makePicture(named: "picked.jpg", width: 320, height: 200)
        try store.importImage(from: picked)
        settings.homepageUsesCustomImage = true
        settings.homepageMatchesAccent = true
        settings.homepageUsesThemeBackground = false
        settings.accentColorHex = "DB283C"

        XCTAssertEqual(settings.homepageBackgroundSource(isPrivate: false), .customImage)
        XCTAssertEqual(
            settings.homepageBackgroundSource(isPrivate: true), .customImage,
            "the user's own picture is not a theme; private windows show it"
        )

        store.removeImage()
        XCTAssertEqual(
            settings.homepageBackgroundSource(isPrivate: false),
            .accentWallpaper(assetName: "HomepageWallpaperDB283C"),
            "with the copy gone the homepage must fall back, never blank"
        )
    }

    // MARK: - Fixtures

    /// A real image file on disk, in the format asked for — what lands in the
    /// store is always the product of a genuine decode of a genuine file.
    private func makePicture(
        named name: String, width: Int, height: Int,
        type: UTType = .jpeg, alpha: Bool = false
    ) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.85, blue: 0.7, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let url = pickedDirectory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw HomepageCustomImageStore.ImportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HomepageCustomImageStore.ImportError.encodingFailed
        }
        return url
    }

    private func storedPixelSize(of store: HomepageCustomImageStore) throws -> (width: Int, height: Int) {
        let stored = try XCTUnwrap(store.storedFileURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(stored as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
