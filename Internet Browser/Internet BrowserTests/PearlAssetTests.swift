//
//  PearlAssetTests.swift
//  Internet BrowserTests
//
//  Pearl's artwork: the wizard hero imagesets and the runner-game sprite
//  sheet. The pearl-sprites.json manifest is a fixed contract shared with
//  the game code — frame names, counts and logical sizes are pinned here so
//  neither side can drift without a test failing.
//

import XCTest
import AppKit
@testable import Cherry

final class PearlAssetTests: XCTestCase {

    // MARK: - Imagesets resolve by name

    /// The wizard hero is chrome: it is drawn at whatever size the view asks
    /// for, so the asset catalog's automatic 1x/2x selection is exactly right
    /// for it. The runner's sprite sheet is not here on purpose — see
    /// `testTheSpriteSheetShipsLooseBecauseTheManifestIndexesItsPixels`.
    func testPearlImagesetsResolveByName() {
        for name in ["PearlHero", "PearlHeroYellow"] {
            let image = NSImage(named: name)
            XCTAssertNotNil(image, "imageset \(name) should resolve")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, "imageset \(name) should have a size")
        }
    }

    /// The sheet deliberately does NOT ship as an imageset: an imageset is
    /// compiled into `Assets.car`, and `pearl-sprites.json` addresses pixel
    /// rectangles in one specific bitmap that no file lookup could reach.
    func testTheSpriteSheetShipsLooseBecauseTheManifestIndexesItsPixels() {
        XCTAssertNil(
            NSImage(named: "PearlSprites"),
            "the sheet must not be an imageset; it ships as pearl-sprites.png"
        )
        XCTAssertNotNil(Bundle.main.url(forResource: "pearl-sprites", withExtension: "png"))
    }

    func testHeroReadsAtWizardSize() {
        guard let hero = NSImage(named: "PearlHero") else { return XCTFail("PearlHero missing") }
        XCTAssertGreaterThanOrEqual(hero.size.height, 220, "hero must read at 220-320pt tall")
        XCTAssertLessThanOrEqual(hero.size.height, 400)
    }

    // MARK: - Manifest

    private struct Box: Decodable {
        let x: Int, y: Int, w: Int, h: Int
    }

    private struct Manifest: Decodable {
        let scale: Int
        let frames: Frames
    }

    private struct Frames: Decodable {
        let run: [Box]
        let duck: [Box]
        let jump: [Box]
        let hit: [Box]
        let tree_small: [Box]
        let tree_large: [Box]
        let gull: [Box]
        let ground: Box
        let cloud: Box
        let moon: Box
        let star: Box
    }

    private func loadManifest() throws -> Manifest {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "pearl-sprites", withExtension: "json"),
            "pearl-sprites.json must ship in the app bundle"
        )
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    func testManifestParsesWithContractFrameNamesAndCounts() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.scale, 1, "sheet is a 1x pixel-art sheet; consumers divide by scale")
        XCTAssertEqual(manifest.frames.run.count, 2)
        XCTAssertEqual(manifest.frames.duck.count, 2)
        XCTAssertEqual(manifest.frames.jump.count, 1)
        XCTAssertEqual(manifest.frames.hit.count, 1)
        XCTAssertEqual(manifest.frames.gull.count, 2)
        XCTAssertGreaterThanOrEqual(manifest.frames.tree_small.count, 1)
        XCTAssertGreaterThanOrEqual(manifest.frames.tree_large.count, 1)
    }

    func testManifestBoxesMatchTheLogicalSizes() throws {
        // The contract's numbers are logical points at 1x: a consumer computes
        // round(w / scale), and that must land on the contract exactly.
        let manifest = try loadManifest()
        let frames = manifest.frames
        let scale = Double(manifest.scale)
        func logical(_ box: Box) -> [Int] {
            [Int((Double(box.w) / scale).rounded()), Int((Double(box.h) / scale).rounded())]
        }
        for box in frames.run { XCTAssertEqual(logical(box), [44, 47], "run") }
        for box in frames.duck { XCTAssertEqual(logical(box), [59, 30], "duck") }
        for box in frames.jump { XCTAssertEqual(logical(box), [44, 47], "jump") }
        for box in frames.hit { XCTAssertEqual(logical(box), [44, 47], "hit") }
        for box in frames.tree_small { XCTAssertEqual(logical(box), [17, 35], "tree_small") }
        for box in frames.tree_large { XCTAssertEqual(logical(box), [25, 50], "tree_large") }
        for box in frames.gull { XCTAssertEqual(logical(box), [46, 40], "gull") }
        XCTAssertEqual(Int((Double(frames.ground.h) / scale).rounded()), 12, "ground strip is 12pt tall")
    }

    func testEveryFrameBoxLiesInsideTheSheet() throws {
        let frames = try loadManifest().frames
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "pearl-sprites", withExtension: "png"),
            "pearl-sprites.png must ship in the app bundle"
        )
        let sheet = try XCTUnwrap(NSImage(contentsOf: url), "the sprite sheet must decode")
        let width = Int(sheet.size.width), height = Int(sheet.size.height)
        var boxes: [(String, Box)] = [("ground", frames.ground), ("cloud", frames.cloud),
                                      ("moon", frames.moon), ("star", frames.star)]
        for (name, list) in [("run", frames.run), ("duck", frames.duck), ("jump", frames.jump),
                             ("hit", frames.hit), ("tree_small", frames.tree_small),
                             ("tree_large", frames.tree_large), ("gull", frames.gull)] {
            boxes.append(contentsOf: list.map { (name, $0) })
        }
        for (name, box) in boxes {
            XCTAssertGreaterThanOrEqual(box.x, 0, name)
            XCTAssertGreaterThanOrEqual(box.y, 0, name)
            XCTAssertLessThanOrEqual(box.x + box.w, width, "\(name) exceeds sheet width")
            XCTAssertLessThanOrEqual(box.y + box.h, height, "\(name) exceeds sheet height")
        }
    }
}
