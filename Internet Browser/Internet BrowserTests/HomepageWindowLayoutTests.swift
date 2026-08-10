//
//  HomepageWindowLayoutTests.swift
//  Internet BrowserTests
//
//  The homepage must lay out against the width its window really has.
//
//  It used to be possible for it not to: the browser's minimum size was a
//  `.frame(minWidth:)` on the SwiftUI content, which the hand-built windows
//  (⌘N, incognito, detached tabs) never learned about. Dragged narrower than
//  the minimum, such a window kept its content pinned at the minimum width —
//  left-anchored, so the search field ran off the right edge and the clock sat
//  off-centre, and every layout the window produced in that state used
//  coordinates the window did not contain. These tests read laid-out geometry
//  only; nothing here renders or samples pixels.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Cherry

@MainActor
final class HomepageWindowLayoutTests: XCTestCase {

    /// A hand-built browser window forced narrower than the single-pane
    /// minimum: the content must follow the window's width rather than pin at
    /// the minimum, and nothing in the chrome may lay out past the window's
    /// right edge.
    func testChromeFollowsAWindowNarrowerThanTheMinimum() throws {
        openBrowserWindow(isPrivate: false)
        let window = try XCTUnwrap(BrowserViewModel.detachedWindows.last)
        defer {
            window.close()
            pump(0.2)
        }

        // The floor a user's drag is held to. `setFrame` below bypasses it on
        // purpose, standing in for the ways a frame is imposed from outside
        // (tiling, zoom, restored frames).
        XCTAssertEqual(window.contentMinSize.width, 1000, "hand-built windows must carry the single-pane floor")
        XCTAssertEqual(window.contentMinSize.height, 600)

        window.setFrame(NSRect(x: 50, y: 50, width: 700, height: 800), display: true)
        pump(3.0)

        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(
            content.bounds.width, 700, accuracy: 1,
            "content pinned at a width the window does not have"
        )

        // Every view must have re-laid for 700 — none may keep a frame from
        // the layout the window had before the resize. Compared against a
        // fresh window opened straight at 700, keyed by tree path, so views
        // that legitimately exceed the window (a scroller's own content) are
        // fine as long as the resized window agrees with the fresh one.
        openBrowserWindow(isPrivate: false)
        let fresh = try XCTUnwrap(BrowserViewModel.detachedWindows.last)
        defer {
            fresh.close()
            pump(0.2)
        }
        fresh.setFrame(NSRect(x: 50, y: 50, width: 700, height: 800), display: true)
        pump(3.0)

        let resized = frames(in: content)
        let golden = frames(in: try XCTUnwrap(fresh.contentView))
        var stale: [String] = []
        for (path, frame) in resized {
            guard let goldenFrame = golden[path] else { continue }
            if abs(frame.minX - goldenFrame.minX) > 2 || abs(frame.width - goldenFrame.width) > 2 {
                stale.append("\(path): resized=\(frame) fresh=\(goldenFrame)")
            }
        }
        XCTAssertTrue(
            stale.isEmpty,
            "kept frames from the pre-resize layout: \(stale.sorted().joined(separator: "\n"))"
        )
    }

    /// The wallpaper paints the homepage, not the window at large: laid out at
    /// a narrow width (where `scaledToFill`'s aspect overflow is at its
    /// worst), no layer of the homepage may extend past the homepage's bounds.
    func testHomepageWallpaperStaysInsideTheHomepageBounds() throws {
        let settings = SettingsManager.shared
        let savedMatches = settings.homepageMatchesAccent
        let savedAccent = settings.accentColorHex
        // An imported theme that defines `ntp_background` outranks the accent
        // wallpaper (`HomepageBackgroundResolver.resolve` checks it first), so
        // without standing this preference down the subject of this test
        // depends on which theme happens to be installed on the machine — it
        // passed until a theme with a background was imported, then failed for
        // a reason that had nothing to do with layout.
        let savedUsesTheme = settings.homepageUsesThemeBackground
        settings.homepageMatchesAccent = true
        settings.homepageUsesThemeBackground = false
        settings.accentColorHex = "DB283C"
        defer {
            settings.homepageMatchesAccent = savedMatches
            settings.homepageUsesThemeBackground = savedUsesTheme
            settings.accentColorHex = savedAccent
        }
        guard case .accentWallpaper = settings.homepageBackgroundSource(isPrivate: false) else {
            return XCTFail("expected the accent wallpaper to be the background under test")
        }

        let hosting = NSHostingView(rootView: HomePageView(
            repository: ShortcutRepository(),
            isPrivateMode: false,
            onShortcutClick: { _ in },
            onSearch: { _ in },
            onAskAI: { _ in false }
        ))
        hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        // A titled window releases itself on close by default; ARC also
        // releases the local. One owner only.
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            pump(0.2)
        }
        window.contentView = hosting
        window.layoutIfNeeded()
        pump(0.5)

        let root = try XCTUnwrap(hosting.layer)
        var escapees: [String] = []
        walkLayers(root, root: root, underMask: false) { layer, frameInRoot, underMask in
            // A layer beneath a masking ancestor cannot paint outside that
            // ancestor; what this hunts is geometry that escapes with nothing
            // above it to cut the painting off.
            guard !underMask else { return }
            if frameInRoot.minX < root.bounds.minX - 4 || frameInRoot.maxX > root.bounds.maxX + 4 {
                escapees.append("\(type(of: layer)) at \(frameInRoot)")
            }
        }
        XCTAssertTrue(escapees.isEmpty, "painting outside the homepage: \(escapees)")
    }

    /// The same guarantee for the picture the user chose. The shipped
    /// wallpapers all share one moderate aspect; a user's photo can have any,
    /// so `scaledToFill`'s overflow — the exact mechanism behind the original
    /// containment bug — is unbounded here. A very wide picture in a narrow
    /// window and a very tall picture in a short window must both stay inside
    /// the homepage, on both axes.
    func testHomepageCustomPictureStaysInsideTheHomepageBounds() throws {
        let settings = SettingsManager.shared
        let store = HomepageCustomImageStore.shared
        let savedMatches = settings.homepageMatchesAccent
        let savedUsesTheme = settings.homepageUsesThemeBackground
        let savedUsesCustom = settings.homepageUsesCustomImage
        var backup: URL?
        if let current = store.storedFileURL {
            backup = FileManager.default.temporaryDirectory
                .appendingPathComponent("layout-backup-\(UUID().uuidString).\(current.pathExtension)")
            try FileManager.default.copyItem(at: current, to: backup!)
        }
        defer {
            if let backup {
                try? store.importImage(from: backup)
                try? FileManager.default.removeItem(at: backup)
            } else {
                store.removeImage()
            }
            settings.homepageMatchesAccent = savedMatches
            settings.homepageUsesThemeBackground = savedUsesTheme
            settings.homepageUsesCustomImage = savedUsesCustom
        }
        settings.homepageUsesCustomImage = true
        settings.homepageUsesThemeBackground = false

        for (scenario, imageSize, hostSize) in [
            ("a very wide picture in a narrow window",
             CGSize(width: 3200, height: 200), CGSize(width: 600, height: 800)),
            ("a very tall picture in a short window",
             CGSize(width: 200, height: 3200), CGSize(width: 900, height: 300)),
        ] {
            let picked = try makePicture(size: imageSize)
            try store.importImage(from: picked)
            try? FileManager.default.removeItem(at: picked)
            guard settings.homepageBackgroundSource(isPrivate: false) == .customImage else {
                return XCTFail("expected the user's picture to be the background under test")
            }

            let hosting = NSHostingView(rootView: HomePageView(
                repository: ShortcutRepository(),
                isPrivateMode: false,
                onShortcutClick: { _ in },
                onSearch: { _ in },
                onAskAI: { _ in false }
            ))
            hosting.frame = CGRect(origin: .zero, size: hostSize)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            defer {
                window.close()
                pump(0.2)
            }
            window.contentView = hosting
            window.layoutIfNeeded()
            pump(0.5)

            let root = try XCTUnwrap(hosting.layer)
            var escapees: [String] = []
            walkLayers(root, root: root, underMask: false) { layer, frameInRoot, underMask in
                guard !underMask else { return }
                if frameInRoot.minX < root.bounds.minX - 4 || frameInRoot.maxX > root.bounds.maxX + 4
                    || frameInRoot.minY < root.bounds.minY - 4 || frameInRoot.maxY > root.bounds.maxY + 4 {
                    escapees.append("\(type(of: layer)) at \(frameInRoot)")
                }
            }
            XCTAssertTrue(escapees.isEmpty, "\(scenario): painting outside the homepage: \(escapees)")
        }
    }

    /// A real image file for the store to import: pale (so this doubles as a
    /// bright-photo fixture) and extreme in aspect.
    private func makePicture(size: CGSize) throws -> URL {
        let width = Int(size.width), height = Int(size.height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-picture-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: - Walking

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Frames of every view in `container`'s coordinate space, keyed by a
    /// class-name tree path with sibling indices — stable across two windows
    /// showing the same content.
    private func frames(in container: NSView) -> [String: CGRect] {
        var acc: [String: CGRect] = [:]
        func walk(_ view: NSView, path: String) {
            var counts: [String: Int] = [:]
            for sub in view.subviews {
                let cls = String(describing: type(of: sub))
                let index = counts[cls, default: 0]
                counts[cls] = index + 1
                let subPath = "\(path)/\(cls)[\(index)]"
                acc[subPath] = sub.convert(sub.bounds, to: container)
                walk(sub, path: subPath)
            }
        }
        walk(container, path: "")
        return acc
    }

    private func walkLayers(
        _ layer: CALayer, root: CALayer, underMask: Bool,
        visit: (CALayer, CGRect, Bool) -> Void
    ) {
        for sub in layer.sublayers ?? [] {
            visit(sub, sub.convert(sub.bounds, to: root), underMask)
            walkLayers(
                sub, root: root,
                underMask: underMask || sub.masksToBounds || sub.mask != nil,
                visit: visit
            )
        }
    }
}
