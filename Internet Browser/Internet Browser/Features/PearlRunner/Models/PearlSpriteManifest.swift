//
//  PearlSpriteManifest.swift
//  Cherry Browser
//
//  The contract between this code and the artist drawing Pearl.
//
//  ## How the split works
//
//  `pearl-sprites.json` sits beside the sprite sheet and maps frame names to
//  pixel rectangles in it. The art is being drawn in parallel with this code,
//  so everything here is written against the manifest, not against any
//  particular image: the game's collision geometry uses the LOGICAL sizes
//  below (fixed, at 1x), the renderer draws whatever the manifest points at,
//  and until the real sheet lands it draws flat placeholder rectangles at
//  exactly those logical sizes. The real sprites drop in with no code change.
//
//  `conformanceIssues()` is the contract's teeth: it checks a manifest's
//  frame counts and pixel sizes against the logical sizes times the declared
//  scale, and the placeholder manifest shipped with Cherry is held to it by
//  `PearlSpriteManifestTests`.
//

import Foundation

// MARK: - The fixed logical sizes

/// The sprite contract's sizes at 1x, shared by the simulation (collision
/// boxes) and the renderer (draw rectangles). These are agreed with the art
/// worker and do not move: art that disagrees fails `conformanceIssues()`,
/// code that invents a new frame name fails it too.
nonisolated enum PearlSpriteContract {

    struct LogicalSize: Equatable {
        let width: Double
        let height: Double
    }

    static let run = LogicalSize(width: 44, height: 47)
    static let duck = LogicalSize(width: 59, height: 30)
    /// Airborne and hit are single poses in the standing frame size.
    static let jump = run
    static let hit = run
    static let treeSmall = LogicalSize(width: 17, height: 35)
    static let treeLarge = LogicalSize(width: 25, height: 50)
    static let gull = LogicalSize(width: 46, height: 40)
    /// The ground is a repeating strip: height fixed, width the artist's.
    static let groundHeight = 12.0
    /// Scenery. Sizes are the placeholder's own; the contract fixes the
    /// names, not these dimensions.
    static let cloud = LogicalSize(width: 46, height: 14)
    static let moon = LogicalSize(width: 20, height: 40)
    static let star = LogicalSize(width: 9, height: 9)

    /// Frame name → exact frame count. The complete set of names — a manifest
    /// with a name outside this list is not conforming.
    static let frameCounts: [String: Int] = [
        "run": 2, "duck": 2, "jump": 1, "hit": 1,
        "tree_small": 1, "tree_large": 1, "gull": 2,
        "ground": 1, "cloud": 1, "moon": 1, "star": 1,
    ]

    /// The names whose pixel sizes must equal the logical size × scale,
    /// because collision geometry is derived from them.
    static let fixedSizes: [String: LogicalSize] = [
        "run": run, "duck": duck, "jump": jump, "hit": hit,
        "tree_small": treeSmall, "tree_large": treeLarge, "gull": gull,
    ]
}

// MARK: - The manifest

nonisolated struct PearlSpriteManifest: Equatable {

    struct Frame: Equatable, Decodable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    /// Pixels per logical point in the sheet (2 for the shipped art).
    let scale: Int
    let frames: [String: [Frame]]

    /// Frames for a name, in manifest order.
    func frames(_ name: String) -> [Frame] {
        frames[name] ?? []
    }

    // MARK: Decoding

    /// A frame entry is an array for animated names ("run": [...]) and a bare
    /// object for single ones ("ground": {...}) — both shapes appear in the
    /// agreed contract, so both decode.
    private struct FrameList: Decodable {
        let frames: [Frame]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let many = try? container.decode([Frame].self) {
                frames = many
            } else {
                frames = [try container.decode(Frame.self)]
            }
        }
    }

    private struct Raw: Decodable {
        let scale: Int
        let frames: [String: FrameList]
    }

    static func decode(_ data: Data) throws -> PearlSpriteManifest {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return PearlSpriteManifest(
            scale: raw.scale,
            frames: raw.frames.mapValues(\.frames)
        )
    }

    // MARK: Conformance

    /// Everything about this manifest that breaks the contract, in plain
    /// sentences. Empty means the art and the collision geometry agree.
    func conformanceIssues() -> [String] {
        var issues: [String] = []

        if scale < 1 {
            issues.append("scale is \(scale); it must be a positive integer")
        }

        for (name, expectedCount) in PearlSpriteContract.frameCounts.sorted(by: { $0.key < $1.key }) {
            let found = frames(name)
            if found.isEmpty {
                issues.append("\(name) is missing")
                continue
            }
            if found.count != expectedCount {
                issues.append("\(name) has \(found.count) frames; the contract says \(expectedCount)")
            }
        }

        for name in frames.keys.sorted() where PearlSpriteContract.frameCounts[name] == nil {
            issues.append("\(name) is not a name in the contract")
        }

        let pixelScale = Double(max(scale, 1))
        for (name, size) in PearlSpriteContract.fixedSizes.sorted(by: { $0.key < $1.key }) {
            for (index, frame) in frames(name).enumerated() {
                let expectedWidth = Int(size.width * pixelScale)
                let expectedHeight = Int(size.height * pixelScale)
                if frame.w != expectedWidth || frame.h != expectedHeight {
                    issues.append(
                        "\(name)[\(index)] is \(frame.w)x\(frame.h)px; "
                        + "\(size.width)x\(size.height) at \(scale)x needs \(expectedWidth)x\(expectedHeight)"
                    )
                }
            }
        }

        if let ground = frames("ground").first {
            let expectedHeight = Int(PearlSpriteContract.groundHeight * pixelScale)
            if ground.h != expectedHeight {
                issues.append("ground is \(ground.h)px tall; the 12pt strip at \(scale)x needs \(expectedHeight)")
            }
        }

        return issues
    }
}
