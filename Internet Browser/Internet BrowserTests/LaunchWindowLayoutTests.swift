//
//  LaunchWindowLayoutTests.swift
//  Internet BrowserTests
//
//  The launch window must end in the same laid-out state as a ⌘N window.
//
//  It used to not: the scene-presented launch window was created, measured and
//  shown around a frame that was still being restored, and views realized
//  against that in-between geometry — focus proxies, platform view hosts, the
//  promoted layers that draw the homepage's glyphs — kept its coordinates
//  permanently, surviving later resizes. Side by side in one app instance, the
//  restored window drew the search field's magnifier on the wallpaper and the
//  Favorites "Add" pill without its plus while a ⌘N window drew both
//  correctly. Every browser window now takes the ⌘N bring-up (final frame
//  first, then configuration, then showing — `openBrowserWindow`), the launch
//  window included.
//
//  The test host IS the real app, launched through its real path, so the
//  window this compares is the real launch window. Geometry only; no pixels.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class LaunchWindowLayoutTests: XCTestCase {

    /// How far a view may sit from where the ⌘N window puts it. One source of
    /// truth: `readingOrder` groups frames into rows using `y`, so the row rule
    /// and the assertion cannot drift apart.
    private enum Tolerance {
        static let x: CGFloat = 2
        static let y: CGFloat = 4
        static let width: CGFloat = 2
    }

    func testLaunchWindowHomepageMatchesACommandNWindow() throws {
        pump(1.5)

        // The launch window: the earliest browser window the app brought up.
        let browserWindows = NSApp.windows.filter { window in
            window.contentView != nil && BrowserViewModel.windowViewModels.values
                .contains { $0.associatedWindow === window }
        }
        guard let launchWindow = browserWindows.first,
              let vm = BrowserViewModel.windowViewModels.values
                  .first(where: { $0.associatedWindow === launchWindow }) else {
            return XCTFail("no launch browser window found")
        }

        // A homepage must be showing. If a saved session was restored into
        // this window, open a fresh homepage tab the way ⌘T does. (The
        // historical stranding hit the homepage that lived through the
        // bring-up itself — kept when no session replaces it — so this test
        // is at its sharpest in a run with no saved session.)
        if vm.tabManager.selectedTab?.showHomePage != true {
            vm.newTab()
        }
        pump(1.5)

        // Golden: a window at the same frame through the ⌘N ordering — frame
        // final before it is ever shown. Built by hand so the ordering under
        // test is explicit in the test itself.
        let golden = DetachedWindow(
            contentRect: launchWindow.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        golden.isReleasedWhenClosed = false
        defer {
            golden.close()
            pump(0.2)
        }
        golden.contentView = cherryHostingView(BrowserView(isPrivate: false))
        configureBrowserWindow(golden)
        golden.makeKeyAndOrderFront(nil)
        pump(2.0)

        let launchHomepage = try XCTUnwrap(
            homepageGroups(in: launchWindow.contentView!),
            "launch window shows no homepage to compare"
        )
        let goldenHomepage = try XCTUnwrap(
            homepageGroups(in: golden.contentView!),
            "golden window shows no homepage to compare"
        )

        // Same class of views, same frames, ordered by position — sibling
        // enumeration order is not part of the contract, geometry is.
        var stale: [String] = []
        for (group, goldenFrames) in goldenHomepage {
            // The shared field editor lives in whichever window is key at the
            // moment — keyboard furniture, not layout.
            if group.contains("_NSKeyboardFocusClipView") { continue }
            let launchFrames = launchHomepage[group] ?? []
            if launchFrames.count != goldenFrames.count {
                stale.append("\(group): \(launchFrames.count) views vs \(goldenFrames.count) in ⌘N")
                continue
            }
            for (l, g) in zip(launchFrames, goldenFrames) {
                if abs(l.minX - g.minX) > Tolerance.x
                    || abs(l.minY - g.minY) > Tolerance.y
                    || abs(l.width - g.width) > Tolerance.width {
                    stale.append("\(group): launch=\(l) ⌘N=\(g)")
                }
            }
        }
        XCTAssertTrue(
            stale.isEmpty,
            "launch window's homepage is not laid out like ⌘N's:\n" + stale.sorted().joined(separator: "\n")
        )
    }

    // MARK: - Walking

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Frames of every view inside the homepage's scroll container, grouped by
    /// (container path, view class) and put in reading order, in container
    /// coordinates. `nil` when the window shows no homepage scroll.
    private func homepageGroups(in container: NSView) -> [String: [CGRect]]? {
        guard let clip = homepageClipView(in: container) else { return nil }
        var groups: [String: [CGRect]] = [:]
        func walk(_ view: NSView, path: String) {
            for sub in view.subviews {
                let cls = String(describing: type(of: sub))
                let group = "\(path)/\(cls)"
                groups[group, default: []].append(sub.convert(sub.bounds, to: clip))
                walk(sub, path: group)
            }
        }
        walk(clip, path: "")
        for (key, frames) in groups {
            groups[key] = readingOrder(frames)
        }
        return groups
    }

    /// Sibling frames in reading order: rows top to bottom, and left to right
    /// inside a row.
    ///
    /// Rows, rather than a plain sort on `(minY, minX)` — that sort is what
    /// made this test intermittent. A Favorites tile the pointer is resting on
    /// carries hover's `scaleEffect(1.025)`, and the platform views inside it
    /// (the ⋯ button's anchor, its accessibility view) are then measured about
    /// 1.3pt higher and 0.7pt wider than their resting frames. Every one of
    /// those deltas is well inside what this test allows — but they are not
    /// inside an EXACT `!=` on `minY`, so the hovered tile sorted ahead of its
    /// own row, `zip` paired it against a different tile, and a window that was
    /// laid out perfectly reported 129pt differences. The pointer is not part
    /// of what this test guards, and neither is a comparison whose pairing
    /// turns over on a third of a point.
    ///
    /// So: frames closer together in `y` than the tolerance the assertion
    /// itself applies are not separable into different rows, and are ordered by
    /// `x` instead. The homepage's real rows are 117pt apart (7pt at the very
    /// closest, between a tile and its own ⋯), so the row a frame lands in
    /// never depends on jitter this small. Nothing here is a tolerance: two
    /// views still have to be within `Tolerance` of each other to pass.
    private func readingOrder(_ frames: [CGRect]) -> [CGRect] {
        var rows: [[CGRect]] = []
        for frame in frames.sorted(by: { $0.minY < $1.minY }) {
            if let previous = rows.last?.last, frame.minY - previous.minY < Tolerance.y {
                rows[rows.count - 1].append(frame)
            } else {
                rows.append([frame])
            }
        }
        return rows.flatMap { row in
            row.sorted { a, b in
                a.minX != b.minX ? a.minX < b.minX : a.width < b.width
            }
        }
    }

    /// The homepage's scroll clip view: the one whose content hosts the search
    /// field's platform text field.
    private func homepageClipView(in container: NSView) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            if found != nil { return }
            if String(describing: type(of: view)) == "NSClipView",
               containsTextField(view) {
                found = view
                return
            }
            for sub in view.subviews { walk(sub) }
        }
        func containsTextField(_ view: NSView) -> Bool {
            if view is NSTextField { return true }
            return view.subviews.contains { containsTextField($0) }
        }
        walk(container)
        return found
    }
}
