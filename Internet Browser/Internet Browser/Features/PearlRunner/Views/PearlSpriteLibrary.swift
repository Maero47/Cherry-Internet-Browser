//
//  PearlSpriteLibrary.swift
//  Cherry Browser
//
//  Turns the sprite manifest into drawable images, or into honest
//  placeholders when the sheet has not landed yet.
//
//  The manifest (`pearl-sprites.json`) is the contract; the sheet
//  (`pearl-sprites.png`, drawn by the art worker in parallel with this code)
//  is optional at build time. When it is present each named frame is sliced
//  out once at load; when it is absent `image(_:frame:)` returns nil and the
//  renderer draws flat rectangles at the contract's logical sizes instead.
//  Either way the geometry is identical, which is what lets the real art
//  drop in without a code change.
//

import AppKit
import SwiftUI

@MainActor
final class PearlSpriteLibrary {

    static let shared = PearlSpriteLibrary(bundle: .main)

    let manifest: PearlSpriteManifest?
    private let slices: [String: [CGImage]]

    /// True once the real sheet is in the bundle and sliced.
    var hasArtwork: Bool {
        !slices.isEmpty
    }

    init(bundle: Bundle) {
        var loaded: PearlSpriteManifest?
        if let url = bundle.url(forResource: "pearl-sprites", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            loaded = try? PearlSpriteManifest.decode(data)
        }
        manifest = loaded

        // The sheet is worth slicing only if it exists AND the manifest that
        // maps it is intact and conforming; a sheet addressed by a broken
        // manifest would draw garbage rectangles.
        guard let manifest = loaded, manifest.conformanceIssues().isEmpty,
              let sheetURL = bundle.url(forResource: "pearl-sprites", withExtension: "png"),
              let sheet = NSImage(contentsOf: sheetURL)?
                  .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            slices = [:]
            return
        }

        var sliced: [String: [CGImage]] = [:]
        for (name, frames) in manifest.frames {
            sliced[name] = frames.compactMap { frame in
                sheet.cropping(to: CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h))
            }
        }
        slices = sliced
    }

    /// The image for a frame, pixelated the way pixel art should be, or nil
    /// in placeholder mode.
    func image(_ name: String, frame index: Int) -> Image? {
        guard let frames = slices[name], !frames.isEmpty else { return nil }
        let slice = frames[index % frames.count]
        return Image(decorative: slice, scale: CGFloat(manifest?.scale ?? 1))
            .interpolation(.none)
    }
}
