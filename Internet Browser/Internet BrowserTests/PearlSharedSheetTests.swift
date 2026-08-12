//
//  PearlSharedSheetTests.swift
//  Internet BrowserTests
//
//  Two features, one sheet — the half of that neither of them could check.
//
//  The offline runner and the desktop pet draw Pearl out of the same
//  `pearl-sprites.png` through the same `PearlSpriteLibrary`. Each side
//  already guards its own end of that: `PearlSpriteSheetTests` proves the
//  sheet ships loose and the runner's frames come out of it with ink in them,
//  and `PearlPetSpriteTests` proves the pet's poses are contract names, slice
//  at full size, and did not move the runner's rectangles.
//
//  What is left is what only exists when both features are in the same tree:
//
//    - **The frames must not overlap.** Every existing test asks whether a
//      rectangle produces pixels. Two rectangles can both produce pixels and
//      still be the same pixels: repack the sheet, land a pet pose on top of a
//      cherry tree, and every test above stays green while the game draws a
//      cat's face on a tree. Nothing on either branch could see this, because
//      neither branch had both sets of rectangles.
//    - **There must be exactly one sheet, reached one way.** A second bitmap
//      or a second library is the shape the last combine failed in: the two
//      halves disagreed about how the art is delivered, every test passed, and
//      the game drew placeholder rectangles forever.
//    - **The renderer's own call must return art.** `PearlRunnerCanvas` and
//      `PearlPetView` do not call `slice`; they call `image` and `alphaMask`.
//      A placeholder is what those return when the delivery breaks, and a
//      placeholder is silent.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlSharedSheetTests: XCTestCase {

    private var appBundle: Bundle { Bundle(for: PearlSpriteLibrary.self) }
    private var library: PearlSpriteLibrary { .shared }

    /// Every rectangle in the shipped manifest, with the name and index it
    /// belongs to.
    private func allFrames() throws -> [(name: String, index: Int, rect: CGRect)] {
        let manifest = try XCTUnwrap(library.manifest, "the shipped manifest must decode")
        return PearlSpriteContract.frameCounts.keys.sorted().flatMap { name in
            manifest.frames(name).enumerated().map { index, frame in
                (name, index, CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h))
            }
        }
    }

    // MARK: - The two features do not stand on each other

    /// No two frames in the sheet share a pixel — the pet's with the runner's,
    /// or either with its own.
    ///
    /// Dies on: a pet frame being packed into the runner's region on top of
    /// something (move `pet_sit[0]` to the ground strip's rectangle and this
    /// is the only test in the repo that notices); a regenerated sheet whose
    /// rows are one pixel tighter than the manifest says.
    func testNoTwoFramesInTheSheetOverlap() throws {
        let frames = try allFrames()
        XCTAssertGreaterThan(frames.count, 1, "nothing to compare")

        for (i, first) in frames.enumerated() {
            for second in frames[(i + 1)...] {
                XCTAssertFalse(
                    first.rect.intersects(second.rect),
                    """
                    \(first.name)[\(first.index)] at \(first.rect) and \
                    \(second.name)[\(second.index)] at \(second.rect) address the same pixels. \
                    Both will slice, both will have ink, and one of them is drawing the other's \
                    picture.
                    """
                )
            }
        }
    }

    /// The two features' frames live in two regions with a boundary between
    /// them, which is what keeps `PearlPetSpriteTests`' pin on the runner's
    /// rectangles cheap to hold.
    func testTheRunnersRegionAndThePetsRegionDoNotInterleave() throws {
        let petNames = Set(PearlPetPose.allCases.map(\.frameName))
        let frames = try allFrames()

        let runnerBottom = frames.filter { !petNames.contains($0.name) }.map { $0.rect.maxY }.max() ?? 0
        let petTop = frames.filter { petNames.contains($0.name) }.map { $0.rect.minY }.min() ?? 0

        XCTAssertGreaterThan(petTop, 0, "the pet has no frames in the sheet at all")
        XCTAssertLessThanOrEqual(
            runnerBottom, petTop,
            "the runner's art reaches \(runnerBottom)px and the pet's starts at \(petTop)px"
        )
    }

    // MARK: - One sheet, one library

    /// One bitmap ships, and it is the one the library loaded.
    ///
    /// Dies on: a second sheet being added beside the first — which is what a
    /// feature "extending" the art by forking it looks like on disk, and which
    /// would not collide at build time unless it happened to share the name.
    func testExactlyOneSpriteSheetShipsInTheApp() throws {
        let resources = appBundle.bundleURL.appending(path: "Contents/Resources")
        let sheets = FileManager.default
            .enumerator(at: resources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("pearl-sprites") && $0.pathExtension == "png" }
            ?? []

        XCTAssertEqual(
            sheets.count, 1,
            "exactly one sprite sheet may ship; found: "
            + sheets.map { $0.lastPathComponent }.joined(separator: ", ")
        )
        XCTAssertEqual(sheets.first, appBundle.url(forResource: "pearl-sprites", withExtension: "png"))
    }

    /// And every frame in the manifest — both features' — addresses that one
    /// bitmap's real pixels.
    func testBothFeaturesFramesLieInsideTheOneLoadedSheet() throws {
        let sheet = try XCTUnwrap(library.sheetPixelSize, "the library is in placeholder mode")
        let url = try XCTUnwrap(appBundle.url(forResource: "pearl-sprites", withExtension: "png"))
        let onDisk = try XCTUnwrap(NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))

        XCTAssertEqual(Int(sheet.width), onDisk.width, "the library loaded a different bitmap")
        XCTAssertEqual(Int(sheet.height), onDisk.height)

        for frame in try allFrames() {
            XCTAssertTrue(
                CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height).contains(frame.rect),
                "\(frame.name)[\(frame.index)] at \(frame.rect) is off the \(Int(sheet.width))×\(Int(sheet.height)) sheet"
            )
        }
    }

    /// The app builds the library exactly once. Two instances would be two
    /// slice caches and two alpha caches of the same bitmap, and — the reason
    /// this is a correctness test rather than a cost one — a second one built
    /// against the wrong bundle answers every question with a placeholder.
    ///
    /// Read from the source because "how many were constructed" is not a
    /// question a running process can be asked; through `AppSourceTree`, which
    /// skips rather than hanging when the checkout sits in a folder macOS
    /// gates.
    ///
    /// Dies on: a feature constructing its own `PearlSpriteLibrary(bundle:)`
    /// instead of taking `.shared`.
    func testTheAppConstructsTheLibraryExactlyOnce() throws {
        let constructions = try AppSourceTree.swiftFiles().flatMap { file in
            file.contents.components(separatedBy: .newlines)
                .filter { $0.contains("PearlSpriteLibrary(") }
                .map { (file.path, $0.trimmingCharacters(in: .whitespaces)) }
        }

        XCTAssertEqual(
            constructions.count, 1,
            "the app builds \(constructions.count) sprite libraries: "
            + constructions.map { "\($0.0): \($0.1)" }.joined(separator: " | ")
        )
        XCTAssertEqual(constructions.first?.0, "Features/PearlRunner/Views/PearlSpriteLibrary.swift")
        XCTAssertTrue(constructions.first?.1.contains("static let shared") == true,
                      "the one construction is no longer the shared one")
    }

    // MARK: - What the renderers actually call

    /// `image(_:frame:)` is the call both renderers make, and a `nil` from it
    /// is the placeholder path — the flat rectangles the last combine shipped
    /// while every test stayed green. Every frame either feature can ask for
    /// comes back as art.
    ///
    /// Dies on: the sheet losing its loose delivery (an imageset compiles into
    /// `Assets.car`, where the manifest's coordinates address nothing); the
    /// manifest and the contract drifting apart, which puts the whole library
    /// into placeholder mode for both features at once.
    func testEveryFrameEitherFeatureDrawsComesBackAsArtwork() throws {
        XCTAssertTrue(library.hasArtwork, "the library is in placeholder mode")

        for (name, count) in PearlSpriteContract.frameCounts.sorted(by: { $0.key < $1.key }) {
            for index in 0..<count {
                XCTAssertNotNil(
                    library.image(name, frame: index),
                    "\(name)[\(index)] draws as a placeholder rectangle"
                )
            }
        }
    }

    /// The pet's hit test asks the library for alpha rather than for a picture,
    /// and an empty mask means she is a cat nobody can click. It has to come
    /// out of the same sheet, at the pose's own size.
    ///
    /// Dies on: the mask cache being keyed by name alone, or the lookup always
    /// reading frame 0 — either of which answers the second frame of a pose
    /// with the first one's pixels, so she is clickable in the shape she was
    /// in half a second ago; a pet frame whose rectangle stopped matching its
    /// contract size.
    func testThePetsAlphaComesOutOfThatSameSheetAtHerOwnSize() throws {
        for pose in PearlPetPose.allCases {
            let count = try XCTUnwrap(PearlSpriteContract.frameCounts[pose.frameName])
            for index in 0..<count {
                let mask = library.alphaMask(pose.frameName, frame: index)
                XCTAssertEqual(
                    mask.count, Int(pose.logicalSize.width * pose.logicalSize.height),
                    "\(pose.frameName)[\(index)]'s mask is not her own box"
                )
                XCTAssertTrue(
                    mask.contains { $0 > 0 },
                    "\(pose.frameName)[\(index)] is transparent everywhere, so she cannot be clicked"
                )
            }

            if count == 2 {
                XCTAssertNotEqual(
                    library.alphaMask(pose.frameName, frame: 0),
                    library.alphaMask(pose.frameName, frame: 1),
                    "\(pose.frameName)'s two frames answer the hit test with the same pixels"
                )
            }
        }
    }

    // MARK: - Two magnifications of one set of pixels

    /// Since `pearl-pet-plus` the two features magnify the shared sheet by
    /// different rules, and this is where they agree that that is safe.
    ///
    /// The runner scales its whole canvas by `PearlField`'s magnification,
    /// which comes in HALVES (0.5 … 2.0). The pet scales one layer by
    /// `PearlPetSize`'s multiple, which is a WHOLE number (1, 2, 3) because
    /// nearest-neighbour at a fraction makes her one-pixel eye glint flicker
    /// as she breathes. Both are legitimate; they are different because the
    /// runner is a moving field seen at speed and she is a still cat you look
    /// at.
    ///
    /// What makes them independent is that neither magnification is stored in
    /// the library: `slice` hands back the raw crop, the SAME object every
    /// time, and each consumer magnifies its own copy. `PearlPetSizeTests`
    /// checks the pet's arithmetic against the contract; this checks it
    /// against the pixels the runner's sheet actually delivers.
    ///
    /// Dies on: the sheet being re-authored at 2x (`"scale": 2`), which the
    /// runner absorbs correctly through `image(_:frame:)`'s `scale:` argument
    /// and the pet does not — she would silently start drawing at 0.5x, 1x and
    /// 1.5x, and the fractional two of those are the flicker `PearlPetSize`
    /// exists to prevent.
    func testThePetsSizesAreWholeMultiplesOfTheRealSlicedPixels() throws {
        for pose in PearlPetPose.allCases {
            let slice = try XCTUnwrap(
                library.slice(pose.frameName, frame: 0),
                "\(pose.frameName) does not slice, so nothing below is measuring art"
            )
            for size in PearlPetSize.allCases {
                let drawn = size.spriteSize(for: pose)
                let magnification = drawn.width / CGFloat(slice.width)
                XCTAssertEqual(
                    magnification, CGFloat(size.multiple), accuracy: 0.0001,
                    "\(pose.frameName) at \(size) magnifies the sheet by \(magnification), "
                        + "not by her multiple of \(size.multiple)"
                )
                XCTAssertEqual(
                    drawn.height / CGFloat(slice.height), CGFloat(size.multiple), accuracy: 0.0001,
                    "\(pose.frameName) at \(size) is stretched: it magnifies differently "
                        + "across than down"
                )
                XCTAssertEqual(
                    magnification.truncatingRemainder(dividingBy: 1), 0,
                    "\(pose.frameName) at \(size) lands on a fraction of a source pixel"
                )
            }
        }
    }

    /// The library is a cache of RAW crops, not of rendered ones. That is the
    /// whole reason two consumers can magnify the same frame differently at
    /// the same moment without one of them getting the other's answer.
    ///
    /// Dies on: `slice` growing a size or scale parameter while the cache key
    /// stays the frame name — at which point whichever feature asked first
    /// decides what the other one draws.
    func testTheLibraryHandsBothFeaturesTheSameUnmagnifiedPixels() throws {
        let manifest = try XCTUnwrap(library.manifest)
        XCTAssertEqual(manifest.scale, 1, "the sheet is no longer authored at 1x")

        for (name, count) in PearlSpriteContract.frameCounts.sorted(by: { $0.key < $1.key }) {
            for index in 0..<count {
                let rect = manifest.frames(name)[index]
                let first = try XCTUnwrap(library.slice(name, frame: index))
                let second = try XCTUnwrap(library.slice(name, frame: index))
                XCTAssertTrue(
                    first === second,
                    "\(name)[\(index)] is re-made per call, so it can be re-made per scale"
                )
                XCTAssertEqual(first.width, rect.w, "\(name)[\(index)] came back magnified")
                XCTAssertEqual(first.height, rect.h, "\(name)[\(index)] came back magnified")
            }
        }
    }

    /// And the two magnifications have no way to hear about each other: the
    /// field's arithmetic never mentions the pet's size and hers never
    /// mentions the field or the world. Same shape as the runner branch's own
    /// `testTheSimulationHasNoWayToHearAboutTheField`, one level up.
    ///
    /// Dies on: a helpful "make Pearl match the field" that reads
    /// `PearlField.metrics` inside the pet, or a field scale derived from her
    /// chosen size — either of which makes one feature's window resize change
    /// how the other one is drawn.
    func testTheTwoMagnificationsCannotHearAboutEachOther() throws {
        let field = try AppSourceTree.read("Features/PearlRunner/Models/PearlField.swift")
        for name in ["PearlPetSize", "PearlPetPose", "PearlPetPlacement"] {
            XCTAssertFalse(field.contains(name), "the runner's field now reads \(name)")
        }

        for path in [
            "Features/PearlPet/Models/PearlPetSize.swift",
            "Features/PearlPet/Models/PearlPetPlacement.swift",
            "Features/PearlPet/Views/PearlPetView.swift",
            "Features/PearlPet/Views/PearlPetOverlay.swift",
        ] {
            let source = try AppSourceTree.read(path)
            for name in ["PearlField", "PearlWorld", "PearlRunnerGame"] {
                let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0).components(separatedBy: "//").first ?? "" }
                    .joined(separator: "\n")
                XCTAssertFalse(code.contains(name), "\(path) now reads \(name)")
            }
        }
    }
}
