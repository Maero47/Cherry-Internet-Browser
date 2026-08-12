//
//  PearlSpriteLibrary.swift
//  Cherry Browser
//
//  Turns the sprite manifest into drawable images, or into honest
//  placeholders if the sheet is ever unreachable.
//
//  ## How the sheet is delivered
//
//  Both `pearl-sprites.json` and `pearl-sprites.png` ship as LOOSE bundle
//  resources from `Features/PearlRunner/Sprites/`, and that is a decision,
//  not an accident. The manifest addresses pixel rectangles in one specific
//  bitmap (244x245 as this is written; the runner's own frames occupy its
//  first 159 rows and the desktop pet's the rest), so the delivery has to
//  hand back that exact bitmap. An
//  asset-catalog imageset cannot: it is compiled into `Assets.car` with no
//  file to look up, and `NSImage(named:)` resolves to whichever 1x/2x
//  representation the drawing context prefers — the manifest's coordinates
//  would then index the wrong pixels, silently, on Retina only.
//
//  The sheet is authored at 1x (`"scale": 1`), so a manifest rectangle is
//  the contract's logical size in points. Magnification is nearest-neighbour
//  via `.interpolation(.none)`; a 2x sheet would be redundant, since the 2x
//  art is an exact pixel-doubling of the 1x.
//
//  If the sheet ever goes missing, `image(_:frame:)` returns nil and the
//  renderer falls back to flat rectangles at the same logical sizes, so the
//  geometry never changes. `PearlSpriteSheetTests` is what makes sure that
//  fallback stays theoretical.
//

import AppKit
import SwiftUI

@MainActor
final class PearlSpriteLibrary {

    static let shared = PearlSpriteLibrary(bundle: .main)

    let manifest: PearlSpriteManifest?
    private let slices: [String: [CGImage]]

    /// The loaded sheet's size in real pixels, or nil in placeholder mode.
    /// The manifest's rectangles are pixel coordinates into exactly this.
    private(set) var sheetPixelSize: CGSize?

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
        sheetPixelSize = CGSize(width: sheet.width, height: sheet.height)
    }

    /// The raw pixels cropped out of the sheet for a frame, or nil in
    /// placeholder mode. A slice narrower than its manifest rectangle means
    /// the rectangle ran off the edge of the sheet.
    func slice(_ name: String, frame index: Int) -> CGImage? {
        guard let frames = slices[name], !frames.isEmpty else { return nil }
        return frames[index % frames.count]
    }

    /// The image for a frame, pixelated the way pixel art should be, or nil
    /// in placeholder mode.
    func image(_ name: String, frame index: Int) -> Image? {
        guard let slice = slice(name, frame: index) else { return nil }
        return Image(decorative: slice, scale: CGFloat(manifest?.scale ?? 1))
            .interpolation(.none)
    }

    // MARK: - Alpha

    private var masks: [String: [UInt8]] = [:]

    /// The alpha of every pixel of a frame, row-major from the TOP row, built
    /// once and kept — empty in placeholder mode.
    ///
    /// This lives with the art rather than with the one view that wants it
    /// (`PearlPetView.hitTest`, which asks "is this point one of Pearl's own
    /// pixels?" for every mouse and wheel event that reaches her frame)
    /// because it is a fact about the sheet, and because a cache kept beside
    /// the consumer would be keyed by frame name alone — and would then answer
    /// one library's question with another library's pixels.
    func alphaMask(_ name: String, frame index: Int) -> [UInt8] {
        let key = "\(name)#\(index)"
        if let cached = masks[key] { return cached }
        guard let slice = slice(name, frame: index) else {
            masks[key] = []
            return []
        }

        let width = slice.width, height = slice.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return }
            context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        masks[key] = bytes
        return bytes
    }
}
