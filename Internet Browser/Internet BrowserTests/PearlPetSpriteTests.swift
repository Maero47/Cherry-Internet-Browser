//
//  PearlPetSpriteTests.swift
//  Internet BrowserTests
//
//  The pet's frames are in the RUNNER's sheet, and this file is what makes
//  that a fact rather than an intention.
//
//  Two things could go wrong with sharing one sheet between two features, and
//  both are tested here: a pose could be named in code with no art behind it
//  (the manifest contract catches that, and `PearlPetPose` is walked against
//  it), and adding the pet's frames could have moved the runner's — so the
//  runner's rectangles are pinned to the exact numbers it shipped with.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlPetSpriteTests: XCTestCase {

    private var library: PearlSpriteLibrary { .shared }

    // MARK: - One manifest, extended

    /// Every pose the pet code can ask for is a name the contract knows, with
    /// the frame count the code assumes.
    func testEveryPoseIsAContractName() {
        for pose in PearlPetPose.allCases {
            XCTAssertNotNil(
                PearlSpriteContract.frameCounts[pose.frameName],
                "\(pose) names \(pose.frameName), which the sprite contract has never heard of"
            )
            XCTAssertNotNil(
                PearlSpriteContract.fixedSizes[pose.frameName],
                "\(pose)'s box is not fixed, so her hit-testable rectangle could change under her"
            )
        }
    }

    /// The shipped manifest conforms — which, because `PearlSpriteLibrary`
    /// refuses to slice a non-conforming manifest, is also what proves adding
    /// the pet's frames did not silently turn the runner's art off.
    func testTheShippedManifestStillConformsWithThePetsFramesInIt() {
        XCTAssertEqual(library.manifest?.conformanceIssues(), [])
        XCTAssertTrue(library.hasArtwork, "the sheet fell back to placeholders")
    }

    /// Every pet frame slices out of the real sheet at its full size and has
    /// ink in it.
    func testEveryPetFrameHasRealPixels() throws {
        for pose in PearlPetPose.allCases {
            let count = try XCTUnwrap(PearlSpriteContract.frameCounts[pose.frameName])
            for index in 0..<count {
                let slice = try XCTUnwrap(
                    library.slice(pose.frameName, frame: index),
                    "\(pose.frameName)[\(index)] produced no pixels"
                )
                XCTAssertEqual(Double(slice.width), pose.logicalSize.width)
                XCTAssertEqual(Double(slice.height), pose.logicalSize.height)
                XCTAssertGreaterThan(
                    Self.opaquePixels(slice), 60,
                    "\(pose.frameName)[\(index)] is (nearly) blank"
                )
            }
        }
    }

    /// A two-frame cycle whose frames are identical is not a cycle. This is
    /// what fails if the breathing frames are ever regenerated as copies.
    func testTheTwoFrameCyclesReallyHaveTwoFrames() throws {
        for pose in PearlPetPose.allCases
        where PearlSpriteContract.frameCounts[pose.frameName] == 2 {
            let first = try XCTUnwrap(library.slice(pose.frameName, frame: 0))
            let second = try XCTUnwrap(library.slice(pose.frameName, frame: 1))
            XCTAssertNotEqual(
                Self.pixels(first), Self.pixels(second),
                "\(pose.frameName)'s two frames are the same picture"
            )
        }
    }

    /// She has to be able to swap poses without jumping: every upright pose is
    /// the same box, and the sleeping one shares its floor line.
    func testEveryUprightPoseIsTheSameBox() {
        for pose in PearlPetPose.allCases where pose != .sleeping {
            XCTAssertEqual(pose.logicalSize, PearlSpriteContract.petStanding, "\(pose) is a different size")
        }
        XCTAssertEqual(PearlPetPose.sleeping.logicalSize, PearlSpriteContract.petSleeping)
        XCTAssertLessThan(
            PearlSpriteContract.petSleeping.height, PearlSpriteContract.petStanding.height,
            "asleep she should be the shorter shape"
        )
    }

    /// Her poses are the pet's; the runner's are the runner's. Nothing was
    /// renamed into a shared middle.
    func testThePetNamesAreItsOwn() {
        let runner = ["run", "duck", "jump", "hit", "gull", "ground", "cloud", "moon", "star",
                      "tree_small", "tree_large"]
        for pose in PearlPetPose.allCases {
            XCTAssertFalse(runner.contains(pose.frameName), "\(pose) took over a runner frame")
            XCTAssertTrue(pose.frameName.hasPrefix("pet_"))
        }
    }

    // MARK: - The runner's art did not move

    /// The rectangles the runner shipped with, pinned. Adding frames to a
    /// sheet is a repack away from silently redrawing the offline game, and
    /// nothing about the game would fail — it would just draw the wrong
    /// pixels.
    func testTheRunnersOwnFramesAreExactlyWhereTheyWere() throws {
        let manifest = try XCTUnwrap(library.manifest)
        let pinned: [String: [(x: Int, y: Int, w: Int, h: Int)]] = [
            "run": [(2, 2, 44, 47), (48, 2, 44, 47)],
            "jump": [(94, 2, 44, 47)],
            "hit": [(140, 2, 44, 47)],
            "duck": [(2, 51, 59, 30), (63, 51, 59, 30)],
            "gull": [(124, 51, 46, 40), (172, 51, 46, 40)],
            "tree_small": [(2, 93, 17, 35)],
            "tree_large": [(21, 93, 25, 50)],
            "cloud": [(48, 93, 35, 16)],
            "moon": [(85, 93, 18, 22)],
            "star": [(105, 93, 7, 7)],
            "ground": [(2, 145, 240, 12)],
        ]
        for (name, boxes) in pinned {
            let found = manifest.frames(name)
            XCTAssertEqual(found.count, boxes.count, "\(name) frame count")
            for (index, box) in boxes.enumerated() where index < found.count {
                XCTAssertEqual(
                    [found[index].x, found[index].y, found[index].w, found[index].h],
                    [box.x, box.y, box.w, box.h],
                    "\(name)[\(index)] moved in the sheet"
                )
            }
        }
    }

    /// The pet's frames were appended BELOW the runner's region rather than
    /// packed into its gaps, which is what keeps the pin above cheap to hold.
    func testThePetsFramesLiveBelowTheRunnersRegion() throws {
        let manifest = try XCTUnwrap(library.manifest)
        for pose in PearlPetPose.allCases {
            for frame in manifest.frames(pose.frameName) {
                XCTAssertGreaterThanOrEqual(
                    frame.y, 159,
                    "\(pose.frameName) was packed into the runner's own region"
                )
            }
        }
    }

    // MARK: - Pixels

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func opaquePixels(_ image: CGImage) -> Int {
        let bytes = pixels(image)
        return stride(from: 3, to: bytes.count, by: 4).reduce(into: 0) { count, alpha in
            if bytes[alpha] > 0 { count += 1 }
        }
    }
}
