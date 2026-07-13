//
//  NSImage+Extensions.swift
//  Cherry Browser
//

import AppKit

extension NSImage {
    /// PNG-encoded bitmap of the image. Favicons are persisted as PNG so the
    /// stored blob stays small and always round-trips through NSImage(data:),
    /// even when the download was an ICO or SVG.
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
