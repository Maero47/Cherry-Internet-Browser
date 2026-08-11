//
//  WindowResizeAndZoomTests.swift
//  Internet BrowserTests
//
//  Two owner reports, one file.
//
//  1. The green traffic light offered only Fullscreen. The arrangement menu
//     (Fill / Center / Move & Resize / tiling) is the system moving and
//     resizing the window server-side, and `isMovable = false` declares a
//     window ineligible for exactly that (NSWindow.h). These tests pin the
//     configuration every browser window must keep for the menu to exist —
//     the menu itself only the owner can see by hovering.
//
//  2. Live-resizing stuttered. Measured cause: every resize frame swept every
//     chrome cluster's plate question through a fresh cache key, and a full
//     re-sample and re-solve cost ~600ms per frame against a busy theme.
//     The guard now serves each cluster's last settled plan while a live
//     resize is in flight and recomputes the moment it settles. These tests
//     pin the hold to that shape: no solving mid-drag, and a settled answer
//     identical to the one computed cold.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class WindowResizeAndZoomTests: XCTestCase {

    private var savedTheme: FirefoxThemeManager.FirefoxTheme?

    override func setUp() {
        super.setUp()
        savedTheme = FirefoxThemeManager.shared.activeTheme
    }

    override func tearDown() {
        FirefoxThemeManager.shared.activeTheme = savedTheme
        super.tearDown()
    }

    // MARK: - The green button's arrangement menu

    /// `configureBrowserWindow` must leave the window system-movable — a
    /// window that reports `isMovable == false` is excluded from server-side
    /// move/resize, which is what the green button's Fill / Center /
    /// Move & Resize commands are. Background dragging stays off; Cherry's
    /// own drag areas are the only drag surface.
    func testABrowserWindowStaysEligibleForTheSystemArrangementMenu() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // What the old configuration left behind; configuring must correct
        // it, not merely fail to set it.
        window.isMovable = false

        configureBrowserWindow(window)

        XCTAssertTrue(window.isMovable, "a non-movable window loses the arrangement menu")
        XCTAssertFalse(window.isMovableByWindowBackground, "the content area must not drag the window")
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    /// `WindowConfiguratorNSView` runs after SwiftUI installs the content and
    /// used to force `isMovable = false` — which would quietly undo the fix
    /// on every browser window. It must agree with `configureBrowserWindow`.
    func testTheWindowConfiguratorAgreesTheWindowStaysSystemMovable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView()
        window.isMovable = false

        window.contentView?.addSubview(WindowConfiguratorNSView())

        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
    }

    /// The drag area moves the window itself (`mouseDragged` →
    /// `setFrameOrigin`). Now that the window is system-movable, AppKit would
    /// also start a server-side drag from any view that allows it — two
    /// movers, double-speed dragging. The drag area must refuse AppKit's.
    func testTheDragAreaRefusesAppKitsOwnWindowDrag() {
        XCTAssertFalse(DragAreaNSView().mouseDownCanMoveWindow)
        // …and the default it overrides really is the dangerous one: a plain
        // non-drawing view lets a mouse-down move a movable window.
        XCTAssertTrue(NSView().mouseDownCanMoveWindow)
    }

    // MARK: - The live-resize hold

    /// A synthetic but realistic imported theme: an opaque frame colour, a
    /// translucent toolbar, and a wide right-anchored header illustration
    /// running from dark into blown-out highlights — artwork that slides
    /// under the controls as the window resizes and forces real solves.
    /// Decoded from PNG data the way `FirefoxThemeManager` loads a package,
    /// so the sampler sees a bitmap-backed image, not a drawing handler.
    private func harnessTheme(id: String) -> FirefoxThemeManager.FirefoxTheme {
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

    private var harnessGlyph: Color {
        Color(.sRGB, red: 250 / 255, green: 250 / 255, blue: 250 / 255, opacity: 1)
    }
    private var harnessToolbar: Color {
        Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.15)
    }

    /// One simulated frame of a live resize: the questions Cherry's chrome
    /// asks the guard at window width `width` — the tab strip (every tab,
    /// measured across the shared cluster span), both navigation button
    /// clusters, the omnibox, and the bookmark bar — with the floors, control
    /// widths and overlay stacks the real call sites pass.
    ///
    /// `height` reproduces what a VERTICAL drag does to these questions on
    /// this platform: the global rects SwiftUI hands the asking bodies shift
    /// 1:1 with the window height (measured in
    /// `HomepageWallpaperResizeTimingTests` — bookmark bar minY 87→91 as the
    /// window grew 700→704), so every cluster's y here carries the same
    /// shift. A horizontal frame changes only `width` and leaves every y
    /// alone, which is why the original hold — keyed on the y band — held
    /// horizontally and broke vertically.
    private func askEveryCluster(
        width: CGFloat, height: CGFloat = 84, tabs: Int, of guard_: ThemeContrastGuard
    ) {
        let shift = height - 84
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let field = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.12)
        let iconContext = ThemeLegibility(foreground: harnessGlyph, overlays: [harnessToolbar])
        let fieldContext = ThemeLegibility(foreground: harnessGlyph, overlays: [harnessToolbar, field])

        // Tab strip: separate views, one shared span (`decidedAcrossCluster`).
        let span = CGRect(
            x: 76, y: 8 + shift,
            width: max(1, min(CGFloat(tabs) * 180, width - 220)), height: 20
        )
        for _ in 0..<tabs {
            _ = guard_.plate(
                behind: span, cluster: "tabStrip", canvas: canvas,
                context: ThemeLegibility(foreground: harnessGlyph),
                floor: ThemeContrast.textFloor, windowPoints: 60
            )
        }
        _ = guard_.plate(
            behind: CGRect(x: 8, y: 46 + shift, width: 180, height: 24), cluster: "navigation", canvas: canvas,
            context: iconContext, floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        _ = guard_.plate(
            behind: CGRect(x: width - 150, y: 46 + shift, width: 142, height: 24), cluster: "actions", canvas: canvas,
            context: iconContext, floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        _ = guard_.plate(
            behind: CGRect(x: 200, y: 44 + shift, width: max(1, width - 360), height: 28), cluster: "omniboxField", canvas: canvas,
            context: fieldContext, floor: ThemeContrast.textFloor, windowPoints: 40
        )
        _ = guard_.plate(
            behind: CGRect(x: 8, y: 78 + shift, width: width - 16, height: 20), cluster: "bookmarkBar", canvas: canvas,
            context: fieldContext, floor: ThemeContrast.textFloor, windowPoints: 40
        )
    }

    private func postLiveResize(_ name: Notification.Name, _ window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    /// The monitor is the hold's clock: resizing while any window is mid-drag,
    /// settled — with a generation bump, which is what re-runs every asking
    /// body — only when the last one ends.
    func testTheMonitorTracksTheLiveResizeLifecycle() {
        let monitor = WindowLiveResizeMonitor.shared
        let first = NSWindow()
        let second = NSWindow()
        let generation = monitor.settledGeneration
        XCTAssertFalse(monitor.isLiveResizing)

        postLiveResize(NSWindow.willStartLiveResizeNotification, first)
        XCTAssertTrue(monitor.isLiveResizing)

        postLiveResize(NSWindow.willStartLiveResizeNotification, second)
        postLiveResize(NSWindow.didEndLiveResizeNotification, first)
        XCTAssertTrue(monitor.isLiveResizing, "another window is still mid-resize")
        XCTAssertEqual(monitor.settledGeneration, generation, "nothing settled yet")

        postLiveResize(NSWindow.didEndLiveResizeNotification, second)
        XCTAssertFalse(monitor.isLiveResizing)
        XCTAssertEqual(monitor.settledGeneration, generation + 1, "settling must advance the generation")
    }

    /// The hold itself: once the chrome has settled, a live-resize sweep asks
    /// frame after frame and the guard answers every question WITHOUT a
    /// single new sample-and-solve — and starts solving again the moment the
    /// resize is over.
    func testALiveResizeServesTheHeldPlanWithoutResampling() {
        FirefoxThemeManager.shared.activeTheme = harnessTheme(id: "hold-\(UUID().uuidString)")
        let guard_ = ThemeContrastGuard.shared
        let window = NSWindow()

        askEveryCluster(width: 1000, tabs: 8, of: guard_)
        let settledSolves = guard_.sampledPlateCount

        postLiveResize(NSWindow.willStartLiveResizeNotification, window)
        guard_.served = []
        for width in stride(from: CGFloat(1002), through: 1200, by: 2) {
            askEveryCluster(width: width, tabs: 8, of: guard_)
        }
        let asked = guard_.served?.count ?? 0
        guard_.served = nil
        postLiveResize(NSWindow.didEndLiveResizeNotification, window)

        XCTAssertEqual(
            guard_.sampledPlateCount, settledSolves,
            "a live-resize frame must serve held plans, never re-solve"
        )
        XCTAssertEqual(asked, 100 * 12, "every cluster question was still asked and answered")

        // …and with the resize over, fresh geometry is measured again.
        askEveryCluster(width: 1234, tabs: 8, of: guard_)
        XCTAssertGreaterThan(
            guard_.sampledPlateCount, settledSolves,
            "after settling, a new geometry must be solved for real"
        )
    }

    /// The promise the hold must keep: whatever was served mid-drag, the
    /// answer after the resize settles is EXACTLY the answer a cold solve
    /// gives for the final geometry. The two widths are chosen so the
    /// right-anchored artwork puts the cluster on the blown-out band at the
    /// start and on mid-gradient at the end — a stuck hold would be caught.
    func testThePlateAfterAResizeSettlesEqualsTheColdAnswer() {
        FirefoxThemeManager.shared.activeTheme = harnessTheme(id: "settle-\(UUID().uuidString)")
        let guard_ = ThemeContrastGuard.shared
        let window = NSWindow()
        let cluster = CGRect(x: 8, y: 46, width: 180, height: 24)
        let context = ThemeLegibility(foreground: harnessGlyph, overlays: [harnessToolbar])
        func canvas(_ width: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: width, height: 84) }

        let before = guard_.plate(
            behind: cluster, cluster: "navigation", canvas: canvas(1000), context: context,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )

        postLiveResize(NSWindow.willStartLiveResizeNotification, window)
        for width in stride(from: CGFloat(1050), through: 1350, by: 50) {
            let held = guard_.plate(
                behind: cluster, cluster: "navigation", canvas: canvas(width), context: context,
                floor: ThemeContrast.iconFloor, windowPoints: 28
            )
            XCTAssertEqual(held, before, "mid-drag the cluster keeps its settled plan")
        }
        postLiveResize(NSWindow.didEndLiveResizeNotification, window)

        let settled = guard_.plate(
            behind: cluster, cluster: "navigation", canvas: canvas(1360), context: context,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        let cold = ThemeContrast.plate(
            foreground: ThemeContrast.resolve(harnessGlyph),
            sample: ThemeBackdropSampler.backdrop(
                under: cluster, canvas: canvas(1360), overlays: [harnessToolbar]
            ),
            floor: ThemeContrast.iconFloor,
            windowPoints: 28
        )
        XCTAssertEqual(settled, cold, "the settled answer must equal the cold one")
        XCTAssertNotEqual(
            settled, before,
            "precondition: the artwork must differ between the two widths, or a stuck hold could pass"
        )
    }

    /// The vertical twin of `testALiveResizeServesTheHeldPlanWithoutResampling`,
    /// and the pin for the owner's second report: horizontal drags were smooth,
    /// vertical and diagonal stuttered. The hold used to find a cluster's held
    /// plan by its vertical band — geometry a VERTICAL drag changes every
    /// frame (the global y shifts with the window height on this platform), so
    /// the plan was never found and every frame re-solved. The identity is now
    /// the cluster's name; a height sweep must serve held plans exactly as a
    /// width sweep does.
    func testAVerticalLiveResizeServesTheHeldPlanWithoutResampling() {
        FirefoxThemeManager.shared.activeTheme = harnessTheme(id: "vhold-\(UUID().uuidString)")
        let guard_ = ThemeContrastGuard.shared
        let window = NSWindow()

        askEveryCluster(width: 1100, height: 84, tabs: 8, of: guard_)
        let settledSolves = guard_.sampledPlateCount

        postLiveResize(NSWindow.willStartLiveResizeNotification, window)
        guard_.served = []
        // Every frame moves the canvas height AND every cluster's y — the
        // churn a real vertical drag produces.
        for height in stride(from: CGFloat(86), through: 284, by: 2) {
            askEveryCluster(width: 1100, height: height, tabs: 8, of: guard_)
        }
        let asked = guard_.served?.count ?? 0
        guard_.served = nil
        postLiveResize(NSWindow.didEndLiveResizeNotification, window)

        XCTAssertEqual(
            guard_.sampledPlateCount, settledSolves,
            "a vertical live-resize frame must serve held plans, never re-solve"
        )
        XCTAssertEqual(asked, 100 * 12, "every cluster question was still asked and answered")

        // …and with the resize over, fresh geometry is measured again.
        askEveryCluster(width: 1100, height: 300, tabs: 8, of: guard_)
        XCTAssertGreaterThan(
            guard_.sampledPlateCount, settledSolves,
            "after settling, a new geometry must be solved for real"
        )
    }

    /// The vertical settle promise: whatever was served while the heights
    /// churned, the answer after the drag ends is EXACTLY the cold answer for
    /// the final geometry. The end height pushes the cluster off the bottom
    /// edge of the 160pt header artwork onto the plain frame colour, so a
    /// stuck hold — which would keep serving the on-artwork plan — is caught.
    func testThePlateAfterAVerticalResizeSettlesEqualsTheColdAnswer() {
        FirefoxThemeManager.shared.activeTheme = harnessTheme(id: "vsettle-\(UUID().uuidString)")
        let guard_ = ThemeContrastGuard.shared
        let window = NSWindow()
        let context = ThemeLegibility(foreground: harnessGlyph, overlays: [harnessToolbar])
        // The cluster's y carries the height shift a real vertical drag
        // produces; the canvas grows with it.
        func cluster(_ height: CGFloat) -> CGRect {
            CGRect(x: 8, y: 46 + (height - 84), width: 180, height: 24)
        }
        func canvas(_ height: CGFloat) -> CGRect {
            CGRect(x: 0, y: 0, width: 1000, height: height)
        }

        let before = guard_.plate(
            behind: cluster(84), cluster: "navigation", canvas: canvas(84), context: context,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )

        postLiveResize(NSWindow.willStartLiveResizeNotification, window)
        for height in stride(from: CGFloat(104), through: 284, by: 20) {
            let held = guard_.plate(
                behind: cluster(height), cluster: "navigation", canvas: canvas(height), context: context,
                floor: ThemeContrast.iconFloor, windowPoints: 28
            )
            XCTAssertEqual(held, before, "mid-drag the cluster keeps its settled plan")
        }
        postLiveResize(NSWindow.didEndLiveResizeNotification, window)

        let settled = guard_.plate(
            behind: cluster(320), cluster: "navigation", canvas: canvas(320), context: context,
            floor: ThemeContrast.iconFloor, windowPoints: 28
        )
        let cold = ThemeContrast.plate(
            foreground: ThemeContrast.resolve(harnessGlyph),
            sample: ThemeBackdropSampler.backdrop(
                under: cluster(320), canvas: canvas(320), overlays: [harnessToolbar]
            ),
            floor: ThemeContrast.iconFloor,
            windowPoints: 28
        )
        XCTAssertEqual(settled, cold, "the settled answer must equal the cold one")
        XCTAssertNotEqual(
            settled, before,
            "precondition: the backdrop must differ between the two heights, or a stuck hold could pass"
        )
    }

    /// The vertical measurement, same clock and same questions as the
    /// horizontal sweep below. Before the identity fix this swept every
    /// cluster into a fresh identity per frame and re-solved — the ~600ms
    /// frames `HomepageWallpaperResizeTimingTests` measured in a real window.
    func testVerticalLiveResizeSweepTiming() {
        FirefoxThemeManager.shared.activeTheme = harnessTheme(id: "vsweep-\(UUID().uuidString)")
        let guard_ = ThemeContrastGuard.shared
        let clock = ContinuousClock()
        let window = NSWindow()

        askEveryCluster(width: 1100, height: 84, tabs: 8, of: guard_)

        postLiveResize(NSWindow.willStartLiveResizeNotification, window)
        var frameSeconds: [Double] = []
        for height in stride(from: CGFloat(86), through: 324, by: 2) {
            let elapsed = clock.measure {
                askEveryCluster(width: 1100, height: height, tabs: 8, of: guard_)
            }
            frameSeconds.append(Self.seconds(elapsed))
        }
        postLiveResize(NSWindow.didEndLiveResizeNotification, window)

        let total = frameSeconds.reduce(0, +)
        let mean = total / Double(frameSeconds.count)
        let worst = frameSeconds.max() ?? 0
        print(String(
            format: "VERTICAL SWEEP frames=%d total=%.1fms mean/frame=%.2fms worst frame=%.2fms",
            frameSeconds.count, total * 1000, mean * 1000, worst * 1000
        ))

        XCTAssertLessThan(
            worst, 0.1,
            "a vertical live-resize frame re-solved the backdrop (worst \(worst * 1000)ms) — the hold is off on the vertical axis"
        )
    }

    /// The measurement, taken the same way before and after the fix: settle at
    /// 1000pt, then a 120-frame live-resize sweep to 1360pt bracketed by the
    /// notifications AppKit posts around a real live resize, then the settling
    /// frame after the drag ends. Every sweep frame asks the guard exactly
    /// what the chrome would ask at that width.
    ///
    /// Before the hold: mean 605ms and worst 753ms PER FRAME (the stutter).
    /// The assertion is deliberately two orders of magnitude looser than the
    /// held path costs, so it fails on any return to per-frame solving and on
    /// nothing else.
    func testLiveResizeSweepTiming() {
        FirefoxThemeManager.shared.activeTheme = harnessTheme(id: "sweep-\(UUID().uuidString)")
        let guard_ = ThemeContrastGuard.shared
        let clock = ContinuousClock()
        let window = NSWindow()

        let settleBefore = clock.measure { askEveryCluster(width: 1000, tabs: 8, of: guard_) }
        print(String(format: "SETTLED frame before drag=%.2fms", Self.seconds(settleBefore) * 1000))

        postLiveResize(NSWindow.willStartLiveResizeNotification, window)
        var frameSeconds: [Double] = []
        for width in stride(from: CGFloat(1003), through: 1360, by: 3) {
            let elapsed = clock.measure { askEveryCluster(width: width, tabs: 8, of: guard_) }
            frameSeconds.append(Self.seconds(elapsed))
        }
        postLiveResize(NSWindow.didEndLiveResizeNotification, window)

        let total = frameSeconds.reduce(0, +)
        let mean = total / Double(frameSeconds.count)
        let worst = frameSeconds.max() ?? 0
        print(String(
            format: "SWEEP frames=%d total=%.1fms mean/frame=%.2fms worst frame=%.2fms",
            frameSeconds.count, total * 1000, mean * 1000, worst * 1000
        ))

        let settling = clock.measure { askEveryCluster(width: 1360, tabs: 8, of: guard_) }
        print(String(format: "SETTLING frame after drag=%.2fms", Self.seconds(settling) * 1000))
        let settled = clock.measure { askEveryCluster(width: 1360, tabs: 8, of: guard_) }
        print(String(format: "SETTLED repeat frame=%.3fms", Self.seconds(settled) * 1000))

        XCTAssertLessThan(
            worst, 0.1,
            "a live-resize frame re-solved the backdrop (worst \(worst * 1000)ms) — the hold is off"
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }
}
