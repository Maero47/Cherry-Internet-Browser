//
//  PearlSpriteManifestTests.swift
//  Internet BrowserTests
//
//  The sprite contract's teeth. The art is drawn by another hand in another
//  worktree; this file is what makes "the real sprites drop in without a
//  code change" a checked property instead of a hope. It decodes both shapes
//  the agreed JSON uses, holds the SHIPPED manifest (placeholder today, real
//  art tomorrow) to the contract, and pins the game's collision geometry to
//  the same logical sizes the manifest is validated against.
//

import XCTest
@testable import Cherry

@MainActor
final class PearlSpriteManifestTests: XCTestCase {

    /// A minimal conforming manifest in the contract's own shape: arrays for
    /// animated names, bare objects for single ones.
    private let conformingJSON = Data("""
    { "scale": 2, "frames": {
        "run": [ {"x":0,"y":0,"w":88,"h":94}, {"x":88,"y":0,"w":88,"h":94} ],
        "duck": [ {"x":0,"y":94,"w":118,"h":60}, {"x":118,"y":94,"w":118,"h":60} ],
        "jump": [{"x":176,"y":0,"w":88,"h":94}],
        "hit": [{"x":264,"y":0,"w":88,"h":94}],
        "tree_small": [{"x":0,"y":174,"w":34,"h":70}],
        "tree_large": [{"x":34,"y":174,"w":50,"h":100}],
        "gull": [{"x":236,"y":94,"w":92,"h":80},{"x":328,"y":94,"w":92,"h":80}],
        "ground": {"x":0,"y":274,"w":2400,"h":24},
        "cloud": {"x":124,"y":174,"w":92,"h":28},
        "moon": {"x":84,"y":174,"w":40,"h":80},
        "star": {"x":216,"y":174,"w":18,"h":18}
    } }
    """.utf8)

    private func decoded(_ data: Data) throws -> PearlSpriteManifest {
        try PearlSpriteManifest.decode(data)
    }

    // MARK: - Decoding the agreed shape

    func testBothFrameShapesDecode() throws {
        let manifest = try decoded(conformingJSON)
        XCTAssertEqual(manifest.scale, 2)
        XCTAssertEqual(manifest.frames("run").count, 2, "an array decodes as its frames")
        XCTAssertEqual(manifest.frames("ground").count, 1, "a bare object decodes as one frame")
        XCTAssertEqual(manifest.frames("ground").first?.w, 2400)
        XCTAssertEqual(manifest.frames("run")[1].x, 88)
    }

    func testAConformingManifestHasNoIssues() throws {
        XCTAssertEqual(try decoded(conformingJSON).conformanceIssues(), [])
    }

    // MARK: - The contract's teeth

    private func mutatedJSON(_ replacing: String, with replacement: String) -> Data {
        Data(String(decoding: conformingJSON, as: UTF8.self)
            .replacingOccurrences(of: replacing, with: replacement).utf8)
    }

    func testAWrongSpriteSizeIsCaught() throws {
        // Pearl running at 90px wide instead of 44 × scale 2 = 88.
        let manifest = try decoded(mutatedJSON(
            "\"run\": [ {\"x\":0,\"y\":0,\"w\":88,\"h\":94}",
            with: "\"run\": [ {\"x\":0,\"y\":0,\"w\":90,\"h\":94}"
        ))
        XCTAssertTrue(
            manifest.conformanceIssues().contains { $0.hasPrefix("run[0]") },
            "a frame that disagrees with the collision geometry must be named"
        )
    }

    func testAMissingNameIsCaught() throws {
        let manifest = try decoded(mutatedJSON("\"gull\"", with: "\"seagull\""))
        let issues = manifest.conformanceIssues()
        XCTAssertTrue(issues.contains("gull is missing"))
        XCTAssertTrue(issues.contains("seagull is not a name in the contract"),
                      "invented frame names are exactly what the contract forbids")
    }

    func testAWrongFrameCountIsCaught() throws {
        let manifest = try decoded(mutatedJSON(
            ", {\"x\":88,\"y\":0,\"w\":88,\"h\":94} ]",
            with: " ]"
        ))
        XCTAssertTrue(manifest.conformanceIssues().contains {
            $0.contains("run has 1 frames")
        })
    }

    func testAWrongGroundHeightIsCaught() throws {
        let manifest = try decoded(mutatedJSON("\"w\":2400,\"h\":24", with: "\"w\":2400,\"h\":30"))
        XCTAssertTrue(manifest.conformanceIssues().contains {
            $0.hasPrefix("ground is 30px tall")
        })
    }

    func testAZeroScaleIsCaught() throws {
        let manifest = try decoded(mutatedJSON("\"scale\": 2", with: "\"scale\": 0"))
        XCTAssertTrue(manifest.conformanceIssues().contains {
            $0.contains("scale is 0")
        })
    }

    // MARK: - The shipped manifest
    //
    // Today this is the placeholder written alongside this code; the day the
    // art worker's manifest replaces it, the same test holds THAT file to
    // the same contract. Either way, a Cherry build never ships a manifest
    // the game's geometry disagrees with.

    private var appBundle: Bundle {
        Bundle(for: PearlSpriteLibrary.self)
    }

    func testTheShippedManifestExistsAndConforms() throws {
        let url = try XCTUnwrap(
            appBundle.url(forResource: "pearl-sprites", withExtension: "json"),
            "pearl-sprites.json must be in the app bundle"
        )
        let manifest = try decoded(Data(contentsOf: url))
        XCTAssertEqual(manifest.conformanceIssues(), [])
    }

    func testTheSpriteLibraryLoadsTheShippedManifest() {
        let library = PearlSpriteLibrary(bundle: appBundle)
        XCTAssertNotNil(library.manifest, "the library must find and decode the shipped manifest")
        XCTAssertEqual(library.manifest?.conformanceIssues(), [])
        // The art has landed, so the placeholder branch this test used to
        // tolerate is gone: images must resolve. `PearlSpriteSheetTests`
        // checks the pixels behind them.
        XCTAssertTrue(library.hasArtwork, "the shipped sheet must slice")
        XCTAssertNotNil(library.image("run", frame: 0))
        XCTAssertNotNil(library.image("gull", frame: 1))
    }

    // MARK: - One geometry, shared

    /// The simulation's collision sizes and the manifest validator's sizes
    /// are the same constants; if someone forks them, jumps that clear trees
    /// on screen stop clearing them in the model.
    func testTheGameAndTheContractShareTheirGeometry() {
        XCTAssertEqual(PearlSpriteContract.run.width, 44)
        XCTAssertEqual(PearlSpriteContract.run.height, 47)
        XCTAssertEqual(PearlSpriteContract.duck.width, 59)
        XCTAssertEqual(PearlSpriteContract.duck.height, 30)
        XCTAssertEqual(PearlSpriteContract.treeSmall.width, 17)
        XCTAssertEqual(PearlSpriteContract.treeSmall.height, 35)
        XCTAssertEqual(PearlSpriteContract.treeLarge.width, 25)
        XCTAssertEqual(PearlSpriteContract.treeLarge.height, 50)
        XCTAssertEqual(PearlSpriteContract.gull.width, 46)
        XCTAssertEqual(PearlSpriteContract.gull.height, 40)
        XCTAssertEqual(PearlSpriteContract.groundHeight, 12)
    }
}
