//
//  WindowResizeJankMeasurementTests.swift
//  Internet BrowserTests
//
//  The owner: horizontal live-resize is smooth, vertical and diagonal
//  stutter. This file is the measurement that found the cause, kept
//  executable.
//
//  ## The hypothesis these sweeps refuted
//
//  The first suspect was the homepage wallpaper: the shipped images are
//  2880×1800 (aspect 1.60), the owner's window 1183×795 (aspect 1.49), so
//  `scaledToFill` is height-bound there — a vertical drag changes the image's
//  laid-out size every frame while a horizontal drag only moves the clip.
//  The GEOMETRY half of that is true and `testWallpaperLayerResizesOnTheAxis
//  TheScaleIsBoundTo` pins it. The COST half is false: SwiftUI hands the
//  decoded image to the render server once and the per-frame rescale is
//  GPU-side, so the isolated homepage sweeps time symmetric on both axes
//  (~5–7ms mean, matching the no-image gradient control), and the wide-window
//  reverse prediction fails too. Measured means, this machine: narrow-regime
//  vertical 5.7–6.5ms vs horizontal 6.5–7.3ms; wide-regime horizontal
//  8.1–8.7ms vs vertical 5.7–5.9ms; gradient control 6.1–8.7ms.
//
//  ## What the real-window sweep found instead
//
//  Against a real browser window with a theme active, a vertical sweep hit
//  single frames of 597–867ms while horizontal never exceeded 59ms — and the
//  guard's solve counter moved ONLY on the vertical sweeps. The spike was the
//  contrast guard re-solving every cluster: its live-resize hold looked the
//  held plan up by the cluster's vertical band, and the global rects SwiftUI
//  hands the asking bodies shift 1:1 with the window HEIGHT on this platform
//  (bookmark bar minY 87→91 as the window grew 700→704), so a vertical drag
//  changed the identity every frame and the hold silently stopped holding.
//  The identity is now the cluster's NAME (`ThemeContrastGuard.plate`), and
//  `testRealBrowserWindowLiveResizeSweeps` below pins the end-to-end result.
//
//  Method (identical before and after the fix): a real NSWindow; each sweep
//  frame is one `setFrame(display: true)` followed by a run-loop turn and a
//  CATransaction flush, timed together, bracketed by the live-resize
//  notifications AppKit posts around a real drag.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class WindowResizeJankMeasurementTests: XCTestCase {

    private var savedMatches = false
    private var savedAccent = ""
    private var savedUsesTheme = false
    private var savedUsesCustom = false
    private var savedTheme: FirefoxThemeManager.FirefoxTheme?

    override func setUp() {
        super.setUp()
        let settings = SettingsManager.shared
        savedMatches = settings.homepageMatchesAccent
        savedAccent = settings.accentColorHex
        savedUsesTheme = settings.homepageUsesThemeBackground
        savedUsesCustom = settings.homepageUsesCustomImage
        savedTheme = FirefoxThemeManager.shared.activeTheme
        settings.homepageMatchesAccent = true
        settings.homepageUsesThemeBackground = false
        settings.homepageUsesCustomImage = false
    }

    override func tearDown() {
        let settings = SettingsManager.shared
        settings.homepageMatchesAccent = savedMatches
        settings.accentColorHex = savedAccent
        settings.homepageUsesThemeBackground = savedUsesTheme
        settings.homepageUsesCustomImage = savedUsesCustom
        FirefoxThemeManager.shared.activeTheme = savedTheme
        super.tearDown()
    }

    // MARK: - Sweep machinery

    private struct SweepResult {
        let mean: Double
        let median: Double
        let worst: Double
    }

    /// One live-resize sweep: 60 frames, each frame one `setFrame` +
    /// run-loop turn + CA flush, bracketed by the notifications AppKit posts
    /// around a real drag. Prints and returns per-frame statistics.
    private func sweep(
        _ label: String,
        window: NSWindow,
        from start: CGSize,
        to end: CGSize
    ) -> SweepResult {
        let clock = ContinuousClock()
        let frames = 60
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: window
        )
        var seconds: [Double] = []
        for i in 1...frames {
            let t = CGFloat(i) / CGFloat(frames)
            let size = CGSize(
                width: (start.width + (end.width - start.width) * t).rounded(),
                height: (start.height + (end.height - start.height) * t).rounded()
            )
            let elapsed = clock.measure {
                window.setFrame(
                    NSRect(origin: CGPoint(x: 40, y: 40), size: size),
                    display: true
                )
                RunLoop.main.run(until: Date())
                CATransaction.flush()
            }
            seconds.append(Self.seconds(elapsed))
        }
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: window
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let sorted = seconds.sorted()
        let result = SweepResult(
            mean: seconds.reduce(0, +) / Double(seconds.count),
            median: sorted[sorted.count / 2],
            worst: sorted.last ?? 0
        )
        print(String(
            format: "SWEEP %@ frames=%d mean=%.2fms median=%.2fms worst=%.2fms",
            label, frames, result.mean * 1000, result.median * 1000, result.worst * 1000
        ))
        return result
    }

    private func makeHomepageWindow(size: CGSize) -> NSWindow {
        let hosting = NSHostingView(rootView: HomePageView(
            repository: ShortcutRepository(),
            isPrivateMode: false,
            onShortcutClick: { _ in },
            onSearch: { _ in },
            onAskAI: { _ in false }
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Ordered onscreen: an invisible window's display pass can no-op, and
        // SwiftUI's own commit is driven by the window being visible — offscreen
        // the sweep times pure layout and misses every drawing cost.
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return window
    }

    // MARK: - The refuted wallpaper hypothesis, kept executable

    /// The isolated homepage over the accent wallpaper, height-bound regime
    /// (window aspect < 1.60 throughout, brackets the owner's 1183×795).
    /// Both axes must stay in the same order of magnitude — the record that
    /// the wallpaper's `scaledToFill` is not the vertical cost. No timing
    /// assertion: the numbers land in the log, and the mechanism is pinned
    /// deterministically by the layer test below.
    func testNarrowRegimeHomepageSweeps() {
        SettingsManager.shared.accentColorHex = "2563EB"
        guard case .accentWallpaper = SettingsManager.shared.homepageBackgroundSource(isPrivate: false) else {
            return XCTFail("expected the accent wallpaper under test")
        }
        let window = makeHomepageWindow(size: CGSize(width: 1183, height: 760))
        defer { window.close() }

        _ = sweep(
            "narrow/wallpaper/vertical", window: window,
            from: CGSize(width: 1183, height: 760), to: CGSize(width: 1183, height: 940)
        )
        _ = sweep(
            "narrow/wallpaper/horizontal", window: window,
            from: CGSize(width: 1000, height: 940), to: CGSize(width: 1240, height: 940)
        )
    }

    /// The reverse prediction the hypothesis demanded: wider than 1.60 the
    /// scale is width-bound, so if re-scaling were the cost, horizontal would
    /// be the expensive axis here. Measured: it is not (8.1–8.7ms vs
    /// 5.7–5.9ms means, all within layout noise of the gradient control).
    func testWideRegimeHomepageSweeps() {
        SettingsManager.shared.accentColorHex = "2563EB"
        guard case .accentWallpaper = SettingsManager.shared.homepageBackgroundSource(isPrivate: false) else {
            return XCTFail("expected the accent wallpaper under test")
        }
        let window = makeHomepageWindow(size: CGSize(width: 1330, height: 500))
        defer { window.close() }

        _ = sweep(
            "wide/wallpaper/horizontal", window: window,
            from: CGSize(width: 850, height: 500), to: CGSize(width: 1330, height: 500)
        )
        _ = sweep(
            "wide/wallpaper/vertical", window: window,
            from: CGSize(width: 1330, height: 530), to: CGSize(width: 1330, height: 766)
        )
    }

    /// Control: the same page over the accent-derived gradient (an accent
    /// with no shipped wallpaper). Whatever a frame costs HERE is the page's
    /// own relayout — the wallpaper's share is the difference.
    func testNarrowRegimeGradientControlSweeps() {
        SettingsManager.shared.accentColorHex = "123456"
        guard SettingsManager.shared.homepageBackgroundSource(isPrivate: false) == .accentGradient else {
            return XCTFail("expected the accent gradient under test")
        }
        let window = makeHomepageWindow(size: CGSize(width: 1183, height: 760))
        defer { window.close() }

        _ = sweep(
            "narrow/gradient/vertical", window: window,
            from: CGSize(width: 1183, height: 760), to: CGSize(width: 1183, height: 940)
        )
        _ = sweep(
            "narrow/gradient/horizontal", window: window,
            from: CGSize(width: 1000, height: 940), to: CGSize(width: 1240, height: 940)
        )
    }

    /// The mechanical half of the wallpaper story, pinned: in a height-bound
    /// window (aspect < 1.60) a vertical step changes the wallpaper layer's
    /// SIZE (scale moves with height) while a horizontal step must not — it
    /// only widens the clip. The contents object stays identical either way:
    /// the rescale is the render server's, not a per-frame re-raster, which
    /// is why the wallpaper was exonerated.
    func testWallpaperLayerResizesOnTheAxisTheScaleIsBoundTo() throws {
        SettingsManager.shared.accentColorHex = "2563EB"
        guard case .accentWallpaper = SettingsManager.shared.homepageBackgroundSource(isPrivate: false) else {
            return XCTFail("expected the accent wallpaper under test")
        }
        let window = makeHomepageWindow(size: CGSize(width: 1183, height: 795))
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView?.layer)

        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            CATransaction.flush()
        }
        // The wallpaper is the one bitmap-contents layer larger than the
        // window on exactly one axis (the scaledToFill overflow).
        func wallpaperLayer() -> CALayer? {
            var found: CALayer?
            func walk(_ layer: CALayer) {
                if layer.contents != nil,
                   layer.bounds.width > 1183, layer.bounds.height >= 700 {
                    found = layer
                }
                (layer.sublayers ?? []).forEach(walk)
            }
            walk(root)
            return found
        }

        settle()
        let content = try XCTUnwrap(window.contentView)
        let before = try XCTUnwrap(wallpaperLayer(), "no wallpaper layer found")
        let sizeBefore = before.bounds.size
        let contentsBefore = before.contents.map { ObjectIdentifier($0 as AnyObject) }
        // Height-bound: laid out at the CONTENT height (the title bar is not
        // the homepage's) times the wallpaper aspect, wider than the window.
        XCTAssertEqual(sizeBefore.width, content.bounds.height * 1.6, accuracy: 2)

        window.setFrame(NSRect(x: 40, y: 40, width: 1183, height: 845), display: true)
        settle()
        let afterVertical = try XCTUnwrap(wallpaperLayer())
        XCTAssertGreaterThan(
            content.bounds.height, sizeBefore.height,
            "precondition: the vertical step must actually grow the content"
        )
        XCTAssertEqual(
            afterVertical.bounds.width, content.bounds.height * 1.6, accuracy: 2,
            "a vertical step must move the height-bound scale"
        )
        XCTAssertEqual(
            afterVertical.contents.map { ObjectIdentifier($0 as AnyObject) }, contentsBefore,
            "the decoded image must be reused, not re-rasterised"
        )

        window.setFrame(NSRect(x: 40, y: 40, width: 1233, height: 845), display: true)
        settle()
        let afterHorizontal = try XCTUnwrap(wallpaperLayer())
        XCTAssertEqual(
            afterHorizontal.bounds.size, afterVertical.bounds.size,
            "a horizontal step in the height-bound regime must not touch the wallpaper's size"
        )
    }

    // MARK: - The real window, end to end

    /// The reproducer that found the stutter, kept as the end-to-end pin: a
    /// real browser window under the harness theme, swept on both axes with
    /// the file's one method. Before the identity fix the vertical sweeps hit
    /// 597–867ms single frames (the guard re-solving every cluster — its
    /// held-plan identity was the cluster's vertical band, which a vertical
    /// drag changes every frame); horizontal never left double digits. The
    /// ceiling is far above every post-fix frame and far below every re-solve
    /// spike, so it fails on a return of the stutter and on nothing else.
    ///
    /// The guard's solve counter is the second pin: NOTHING may sample
    /// mid-drag. Settling solves land after `didEndLiveResize` inside
    /// `sweep`, so a re-solve during the drag is separable and asserted on
    /// via the counter delta taken BEFORE the drag ends.
    func testRealBrowserWindowLiveResizeSweeps() throws {
        FirefoxThemeManager.shared.activeTheme = resizeHarnessTheme(
            id: "real-sweep-\(UUID().uuidString)"
        )
        SettingsManager.shared.accentColorHex = "2563EB"
        openBrowserWindow(isPrivate: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let window = try XCTUnwrap(BrowserViewModel.detachedWindows.last)
        defer {
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        window.setFrame(NSRect(x: 40, y: 40, width: 1183, height: 700), display: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let guard_ = ThemeContrastGuard.shared

        // Mid-drag solves are counted with the guard's counter, not wall
        // clock: the sweep helper settles after `didEnd`, so the counter is
        // sampled per-frame inside a bespoke loop here for the vertical axis
        // — the axis that was broken.
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: window
        )
        let solvesBeforeDrag = guard_.sampledPlateCount
        let clock = ContinuousClock()
        var seconds: [Double] = []
        for i in 1...60 {
            let elapsed = clock.measure {
                window.setFrame(
                    NSRect(x: 40, y: 40, width: 1183, height: 700 + CGFloat(i) * 4),
                    display: true
                )
                RunLoop.main.run(until: Date())
                CATransaction.flush()
            }
            seconds.append(Self.seconds(elapsed))
        }
        let solvesMidDrag = guard_.sampledPlateCount - solvesBeforeDrag
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: window
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let worst = seconds.max() ?? 0
        let mean = seconds.reduce(0, +) / Double(seconds.count)
        print(String(
            format: "SWEEP real/vertical frames=%d mean=%.2fms worst=%.2fms midDragSolves=%d",
            seconds.count, mean * 1000, worst * 1000, solvesMidDrag
        ))
        XCTAssertEqual(
            solvesMidDrag, 0,
            "a vertical live-resize frame re-sampled the theme backdrop — the hold is off on the vertical axis"
        )
        XCTAssertLessThan(
            worst, 0.3,
            "a vertical live-resize frame took \(worst * 1000)ms — the owner's stutter is back"
        )

        // The horizontal axis stays as smooth as it already was.
        let horizontal = sweep(
            "real/horizontal", window: window,
            from: CGSize(width: 1010, height: 940), to: CGSize(width: 1250, height: 940)
        )
        XCTAssertLessThan(horizontal.worst, 0.3)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }

    /// The same synthetic imported theme `WindowResizeAndZoomTests` measures
    /// the guard with: opaque frame, translucent toolbar, wide right-anchored
    /// header artwork running from dark into blown-out highlights, decoded
    /// from PNG data the way a real package is.
    private func resizeHarnessTheme(id: String) -> FirefoxThemeManager.FirefoxTheme {
        let size = NSSize(width: 2400, height: 160)
        let drawn = NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.10, green: 0.06, blue: 0.16, alpha: 1),
                NSColor(srgbRed: 0.98, green: 0.95, blue: 0.85, alpha: 1),
            ])
            gradient?.draw(in: rect, angle: 0)
            NSColor(srgbRed: 0.99, green: 0.98, blue: 0.92, alpha: 1).setFill()
            NSRect(x: rect.width * 0.55, y: 0, width: rect.width * 0.12, height: rect.height).fill()
            return true
        }
        let png = drawn.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))
            .flatMap { $0.representation(using: .png, properties: [:]) }
        let image = png.flatMap(NSImage.init(data:)) ?? drawn
        let background = FirefoxThemeManager.ThemeBackground(
            id: "header",
            data: png ?? Data(),
            image: image,
            alignment: "right top",
            tiling: "no-repeat",
            isAnimated: false
        )
        return FirefoxThemeManager.FirefoxTheme(
            id: id,
            name: "Resize Harness",
            colors: [
                "frame": "rgb(46,26,58)",
                "toolbar": "rgba(0,0,0,0.15)",
                "toolbar_text": "rgb(250,250,250)",
                "toolbar_field": "rgba(255,255,255,0.12)",
            ],
            backgrounds: [background]
        )
    }
}
