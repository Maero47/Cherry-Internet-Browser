//
//  HomepageCustomImageStore.swift
//  Cherry Browser
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The one copy of the picture the user chose for their homepage.
///
/// The file the user picked in the open panel is never referenced again after
/// import: it can live on a volume that unmounts, in a Downloads folder that
/// gets cleaned, or behind a sandbox grant that lapses with the panel. So the
/// image is decoded, normalized and re-encoded into
/// `Application Support/<bundle id>/HomepageBackground/` — the same ownership
/// model `FirefoxThemeManager` uses for imported theme packages — and that
/// copy is the only thing the homepage ever reads.
///
/// Import is also where every unreasonable input is dealt with, so the render
/// path never has to:
/// - **Not an image / corrupt:** decoding happens up front and failure throws;
///   nothing already stored is touched until a replacement has been fully
///   encoded in memory.
/// - **Huge files:** anything longer than `maxPixelSize` on its long edge is
///   downsampled at import. A 50MP photo becomes a ≤4096px one once, instead
///   of being decoded at full size on every homepage draw.
/// - **HEIC and friends:** everything is re-encoded to PNG (sources with
///   alpha) or JPEG (everything else), so the stored file is always a format
///   the drawing side trivially handles — and EXIF, including any GPS
///   position in the original, never reaches disk. Camera orientation is
///   applied during the decode so the stored pixels are upright.
///
/// The decoded image is cached here and handed to SwiftUI as one `NSImage`,
/// so the homepage never re-decodes the file per draw. A missing or unreadable
/// stored file simply reads as `image == nil`, which
/// `HomepageBackgroundResolver` treats as "this source is not available" —
/// the homepage falls back to the next background, never to blank.
@Observable
final class HomepageCustomImageStore {
    static let shared = HomepageCustomImageStore()

    enum ImportError: LocalizedError {
        case notAnImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .notAnImage:
                return "That file couldn't be read as a picture."
            case .encodingFailed:
                return "The picture couldn't be saved into Cherry's storage."
            }
        }
    }

    /// The long-edge ceiling for the stored copy. Chosen to stay comfortably
    /// sharper than any window the homepage is drawn in (a 16" MacBook Pro is
    /// 3456 physical pixels across) while keeping the decode the homepage pays
    /// bounded no matter what was picked.
    static let maxPixelSize = 4096

    /// The stored picture, decoded once and reused for every draw.
    /// `nil` means none is stored, or the stored file has become unreadable.
    private(set) var image: NSImage?

    /// Bumped on every import and removal, so views can key the drawn image
    /// on it — replacing the picture must read as new content, not as a
    /// same-identity update to be skipped.
    private(set) var generation = 0

    /// Where the copy lives, while one exists. Exposed for the tests that
    /// exercise the storage lifecycle.
    private(set) var storedFileURL: URL?

    private let directory: URL
    private let fileManager = FileManager.default

    private static let baseFileName = "HomepageBackground"

    /// `Application Support/<bundle id, or "Cherry">/HomepageBackground/`,
    /// matching `FirefoxThemeManager.themesDirectory`'s layout.
    private static let defaultDirectory: URL = {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let appDirectoryName = Bundle.main.bundleIdentifier ?? "Cherry"
        return base
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("HomepageBackground", isDirectory: true)
    }()

    /// - Parameter directory: the directory this store owns outright. The
    ///   default is the app's own storage; tests point it at a scratch
    ///   directory to run the whole lifecycle against a real filesystem.
    init(directory: URL = HomepageCustomImageStore.defaultDirectory) {
        self.directory = directory
        loadStoredImage()
    }

    var isAvailable: Bool { image != nil }

    /// Decode → normalize → encode, all before the directory is touched: a
    /// failed import must never cost the user the picture they already had.
    func importImage(from url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImportError.notAnImage
        }
        // One decode does all the work: cap the long edge, apply the EXIF
        // orientation, and surface corrupt image data as a nil here rather
        // than as a broken draw later.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.notAnImage
        }

        // Asked of the ORIGINAL, not the decode: thumbnailing hands back a
        // premultiplied-alpha bitmap even for an opaque JPEG, so the decoded
        // image's alphaInfo would call everything transparent.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let type: UTType = hasAlpha ? .png : .jpeg
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, type.identifier as CFString, 1, nil
        ) else {
            throw ImportError.encodingFailed
        }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, decoded, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportError.encodingFailed
        }

        let fileURL = directory.appendingPathComponent(
            "\(Self.baseFileName).\(hasAlpha ? "png" : "jpg")"
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try (encoded as Data).write(to: fileURL, options: .atomic)
        } catch {
            throw ImportError.encodingFailed
        }
        // Only now retire a copy stored under the other extension.
        for stale in storedFiles() where stale != fileURL {
            try? fileManager.removeItem(at: stale)
        }

        image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        storedFileURL = fileURL
        generation += 1
    }

    /// Going back means the copy is gone, not just no longer shown.
    func removeImage() {
        for file in storedFiles() {
            try? fileManager.removeItem(at: file)
        }
        image = nil
        storedFileURL = nil
        generation += 1
    }

    private func loadStoredImage() {
        guard let file = storedFiles().first,
              let loaded = NSImage(contentsOf: file),
              loaded.isValid else {
            image = nil
            storedFileURL = nil
            return
        }
        image = loaded
        storedFileURL = file
    }

    /// Built by name from the directory the store was given, never from
    /// `contentsOfDirectory(at:)`'s URLs — those come back canonicalized
    /// (`/private/var/…` for a store handed `/var/…`), which made the
    /// just-written file compare unequal to itself and get "cleaned up".
    private func storedFiles() -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { ($0 as NSString).deletingPathExtension == Self.baseFileName }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
}
