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

    func testPearlImagesetsResolveByName() {
        for name in ["PearlHero", "PearlHeroYellow", "PearlSprites"] {
            let image = NSImage(named: name)
            XCTAssertNotNil(image, "imageset \(name) should resolve")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, "imageset \(name) should have a size")
        }
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
        XCTAssertEqual(manifest.scale, 2)
        XCTAssertEqual(manifest.frames.run.count, 2)
        XCTAssertEqual(manifest.frames.duck.count, 2)
        XCTAssertEqual(manifest.frames.jump.count, 1)
        XCTAssertEqual(manifest.frames.hit.count, 1)
        XCTAssertEqual(manifest.frames.gull.count, 2)
        XCTAssertGreaterThanOrEqual(manifest.frames.tree_small.count, 1)
        XCTAssertGreaterThanOrEqual(manifest.frames.tree_large.count, 1)
    }

    func testManifestBoxesMatchTheLogicalSizes() throws {
        let frames = try loadManifest().frames
        for box in frames.run { XCTAssertEqual([box.w, box.h], [44, 47], "run") }
        for box in frames.duck { XCTAssertEqual([box.w, box.h], [59, 30], "duck") }
        for box in frames.jump { XCTAssertEqual([box.w, box.h], [44, 47], "jump") }
        for box in frames.hit { XCTAssertEqual([box.w, box.h], [44, 47], "hit") }
        for box in frames.tree_small { XCTAssertEqual([box.w, box.h], [17, 35], "tree_small") }
        for box in frames.tree_large { XCTAssertEqual([box.w, box.h], [25, 50], "tree_large") }
        for box in frames.gull { XCTAssertEqual([box.w, box.h], [46, 40], "gull") }
        XCTAssertEqual(frames.ground.h, 12, "ground strip is 12pt tall")
    }

    func testEveryFrameBoxLiesInsideTheSheet() throws {
        let frames = try loadManifest().frames
        let sheet = try XCTUnwrap(NSImage(named: "PearlSprites"), "PearlSprites sheet missing")
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
