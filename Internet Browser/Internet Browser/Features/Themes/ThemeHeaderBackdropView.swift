//
//  ThemeHeaderBackdropView.swift
//  Internet Browser
//

import SwiftUI
import AppKit
import ImageIO
import QuartzCore

// MARK: - Chrome canvas environment

private struct ChromeCanvasFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// The window content's frame in the SwiftUI `.global` space — the
    /// virtual canvas Firefox theme header images anchor to. `BrowserView`
    /// publishes it so every chrome surface renders ITS slice of one
    /// continuous window-wide backdrop (right-anchored art hugs the window's
    /// right edge whether it shows through the tab strip, a split pane's
    /// toolbar, or the vertical tab sidebar). Nil (e.g. previews) makes each
    /// surface its own canvas.
    var chromeCanvasFrame: CGRect? {
        get { self[ChromeCanvasFrameKey.self] }
        set { self[ChromeCanvasFrameKey.self] = newValue }
    }
}

// MARK: - Backdrop view

/// The shared "theme header backdrop" every themed chrome surface uses as
/// its base layer: the theme's opaque `frame` color with the header
/// background images (`additional_backgrounds` / `theme_frame`) composited
/// on top, each honoring its manifest alignment and tiling. Surfaces then
/// draw their own `toolbar`/tab/field colors OVER this — so a transparent
/// toolbar shows frame + images through, exactly like Firefox.
struct ThemeHeaderBackdropView: View {
    @Environment(\.chromeCanvasFrame) private var chromeCanvasFrame

    var body: some View {
        let manager = FirefoxThemeManager.shared
        GeometryReader { geometry in
            ZStack {
                if let frame = manager.frameBackground {
                    frame
                } else {
                    // Image-only theme without a frame color: keep the stock
                    // material underneath the images.
                    Rectangle().fill(.bar)
                }
                if let theme = manager.activeTheme, !theme.backgrounds.isEmpty {
                    let own = geometry.frame(in: .global)
                    let canvas = chromeCanvasFrame ?? own
                    ThemeHeaderCanvasRepresentable(
                        themeID: theme.id,
                        backgrounds: theme.backgrounds,
                        canvasSize: canvas.size,
                        originInCanvas: CGPoint(x: own.minX - canvas.minX, y: own.minY - canvas.minY)
                    )
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: - AppKit canvas

private struct ThemeHeaderCanvasRepresentable: NSViewRepresentable {
    let themeID: String
    let backgrounds: [FirefoxThemeManager.ThemeBackground]
    let canvasSize: CGSize
    let originInCanvas: CGPoint

    func makeNSView(context: Context) -> ThemeHeaderCanvasNSView {
        let view = ThemeHeaderCanvasNSView()
        view.setBackgrounds(backgrounds, themeID: themeID)
        view.updateLayout(canvasSize: canvasSize, originInCanvas: originInCanvas)
        return view
    }

    func updateNSView(_ view: ThemeHeaderCanvasNSView, context: Context) {
        if view.themeID != themeID {
            view.setBackgrounds(backgrounds, themeID: themeID)
        }
        view.updateLayout(canvasSize: canvasSize, originInCanvas: originInCanvas)
    }
}

/// Draws all of a theme's header image layers into one view: bottom layer
/// first (the persisted list is topmost-first, mirroring CSS
/// `background-image` order), each anchored/tiled within the window-sized
/// virtual canvas and translated by this surface's offset inside it.
/// Animated layers (GIF/APNG) show whichever frame `ThemeAnimationClock`
/// says is current for the theme — every surface therefore shows the SAME
/// frame — and register for redraws with the shared ticker only while in a
/// window and only while some layer actually animates.
final class ThemeHeaderCanvasNSView: NSView, ThemeAnimationTickReceiver {
    private(set) var themeID: String = ""
    private var renderers: [BackgroundLayerRenderer] = []
    private var canvasSize: CGSize = .zero
    private var originInCanvas: CGPoint = .zero

    // Top-left origin, matching the canvas coordinates the anchors are
    // computed in.
    override var isFlipped: Bool { true }

    func setBackgrounds(_ backgrounds: [FirefoxThemeManager.ThemeBackground], themeID: String) {
        self.themeID = themeID
        renderers = backgrounds.map(BackgroundLayerRenderer.init)
        needsDisplay = true
        updateTickerRegistration()
    }

    func updateLayout(canvasSize: CGSize, originInCanvas: CGPoint) {
        guard canvasSize != self.canvasSize || originInCanvas != self.originInCanvas else { return }
        self.canvasSize = canvasSize
        self.originInCanvas = originInCanvas
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTickerRegistration()
    }

    // viewDidMoveToWindow(nil) covers normal removal, but a closing window
    // can dealloc the view tree without it. This drops the canvas from the
    // clock's table, and — the part that must not be lost — it is the only
    // thing that makes the clock re-check its receivers when the last
    // animating canvas dies. Delete it and nothing invalidates the shared
    // timer: it goes on firing at up to 60 Hz on the main thread for windows
    // that no longer exist.
    deinit {
        ThemeAnimationClock.shared.removeReceiver(self)
    }

    private func updateTickerRegistration() {
        guard window != nil, let shortestDelay = renderers.compactMap(\.minimumFrameDelay).min() else {
            ThemeAnimationClock.shared.removeReceiver(self)
            return
        }
        ThemeAnimationClock.shared.addReceiver(self, shortestFrameDelay: shortestDelay)
    }

    func themeAnimationDidTick() {
        if syncFrames() { needsDisplay = true }
    }

    /// Pulls every layer onto the frame the theme's shared clock says is
    /// current. Returns true when that changed anything.
    @discardableResult
    private func syncFrames() -> Bool {
        guard !renderers.isEmpty else { return false }
        let elapsed = ThemeAnimationClock.shared.elapsed(themeID: themeID)
        var changed = false
        for renderer in renderers where renderer.updateFrame(elapsed: elapsed) {
            changed = true
        }
        return changed
    }

    override func draw(_ dirtyRect: NSRect) {
        // Synced here and not only on the tick, so a surface appearing
        // mid-loop paints the shared frame on its very first draw instead of
        // showing frame 0 until the next tick.
        syncFrames()
        let canvas = CGSize(
            width: canvasSize.width > 0 ? canvasSize.width : bounds.width,
            height: canvasSize.height > 0 ? canvasSize.height : bounds.height
        )
        for renderer in renderers.reversed() {
            renderer.draw(canvas: canvas, origin: originInCanvas, viewBounds: bounds)
        }
    }
}

// MARK: - Per-layer renderer

/// Renders one header image layer. Static images draw the decoded `NSImage`
/// directly; animated ones re-decode the current frame on demand from the
/// original file data (cached until the frame advances), so a long GIF never
/// holds all its frames in memory at once.
private final class BackgroundLayerRenderer {
    private enum HorizontalAnchor { case left, center, right }
    private enum VerticalAnchor { case top, center, bottom }
    private enum Tiling {
        case none, both, horizontal, vertical

        var tilesHorizontally: Bool { self == .both || self == .horizontal }
        var tilesVertically: Bool { self == .both || self == .vertical }
    }

    private let horizontal: HorizontalAnchor
    private let vertical: VerticalAnchor
    private let tiling: Tiling
    private let staticImage: NSImage
    private let frameSource: CGImageSource?
    private let frameDelays: [TimeInterval]
    private var cursor = ThemeAnimationFrameCursor()
    private var currentFrameImage: NSImage?

    /// Nil for static layers — the view only registers with the shared
    /// redraw ticker when some layer returns a delay.
    var minimumFrameDelay: TimeInterval? {
        frameSource != nil ? frameDelays.min() : nil
    }

    init(background: FirefoxThemeManager.ThemeBackground) {
        (horizontal, vertical) = Self.parseAlignment(background.alignment)
        tiling = Self.parseTiling(background.tiling)
        staticImage = background.image
        if background.isAnimated,
           let source = CGImageSourceCreateWithData(background.data as CFData, nil),
           CGImageSourceGetCount(source) > 1 {
            frameSource = source
            frameDelays = Self.frameDelays(of: source)
        } else {
            frameSource = nil
            frameDelays = []
        }
    }

    /// Adopts the frame this layer should be showing `elapsed` seconds into
    /// the theme's shared animation clock — a function of the shared time
    /// only, so two surfaces asking with the same `elapsed` land on the same
    /// frame no matter when either was created. Returns true when the frame
    /// changed, i.e. the layer needs redrawing.
    func updateFrame(elapsed: TimeInterval) -> Bool {
        guard frameSource != nil, !frameDelays.isEmpty else { return false }
        guard cursor.update(elapsed: elapsed, delays: frameDelays) else { return false }
        // Dropped, not replaced: `displayImage` re-decodes on demand, so only
        // the one visible frame is ever held.
        currentFrameImage = nil
        return true
    }

    private var displayImage: NSImage {
        guard let frameSource else { return staticImage }
        if let cached = currentFrameImage { return cached }
        guard let cgImage = CGImageSourceCreateImageAtIndex(
            frameSource,
            cursor.frameIndex,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return staticImage }
        let image = NSImage(cgImage: cgImage, size: staticImage.size)
        currentFrameImage = image
        return image
    }

    func draw(canvas: CGSize, origin: CGPoint, viewBounds: NSRect) {
        let image = displayImage
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return }

        let anchorX: CGFloat
        switch horizontal {
        case .left: anchorX = 0
        case .center: anchorX = (canvas.width - size.width) / 2
        case .right: anchorX = canvas.width - size.width
        }
        let anchorY: CGFloat
        switch vertical {
        case .top: anchorY = 0
        case .center: anchorY = (canvas.height - size.height) / 2
        case .bottom: anchorY = canvas.height - size.height
        }

        let xs = tiling.tilesHorizontally
            ? Self.tilePositions(anchor: anchorX, length: size.width, from: origin.x, to: origin.x + viewBounds.width)
            : [anchorX]
        let ys = tiling.tilesVertically
            ? Self.tilePositions(anchor: anchorY, length: size.height, from: origin.y, to: origin.y + viewBounds.height)
            : [anchorY]

        for y in ys {
            for x in xs {
                let rect = NSRect(x: x - origin.x, y: y - origin.y, width: size.width, height: size.height)
                guard rect.intersects(viewBounds) else { continue }
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// Tile origins along one axis: the anchor position repeated by the
    /// image's length until the visible range is covered (CSS `repeat`
    /// keeps the anchor tile's phase and paints outward from it).
    private static func tilePositions(anchor: CGFloat, length: CGFloat, from minEdge: CGFloat, to maxEdge: CGFloat) -> [CGFloat] {
        guard length > 0.5, maxEdge > minEdge else { return [anchor] }
        var positions: [CGFloat] = []
        var position = anchor + floor((minEdge - anchor) / length) * length
        while position < maxEdge {
            positions.append(position)
            position += length
        }
        return positions
    }

    /// CSS `background-position` keywords ("right top", "center",
    /// "left bottom", …), order-insensitive. Firefox's documented default
    /// for header images is "right top".
    private static func parseAlignment(_ raw: String) -> (HorizontalAnchor, VerticalAnchor) {
        var horizontal: HorizontalAnchor?
        var vertical: VerticalAnchor?
        var centers = 0
        for token in raw.lowercased().split(whereSeparator: \.isWhitespace) {
            switch token {
            case "left": horizontal = .left
            case "right": horizontal = .right
            case "top": vertical = .top
            case "bottom": vertical = .bottom
            case "center": centers += 1
            default: break
            }
        }
        if horizontal == nil, centers > 0 { horizontal = .center; centers -= 1 }
        if vertical == nil, centers > 0 { vertical = .center }
        return (horizontal ?? .right, vertical ?? .top)
    }

    private static func parseTiling(_ raw: String) -> Tiling {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "repeat": return .both
        case "repeat-x": return .horizontal
        case "repeat-y": return .vertical
        default: return .none
        }
    }

    /// Per-frame delays via ImageIO, handling both GIF and APNG. Browsers
    /// treat near-zero delays as 100 ms — do the same.
    private static func frameDelays(of source: CGImageSource) -> [TimeInterval] {
        (0..<CGImageSourceGetCount(source)).map { index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                return 0.1
            }
            var delay: TimeInterval?
            if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? TimeInterval)
            } else if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                delay = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? TimeInterval)
                    ?? (png[kCGImagePropertyAPNGDelayTime] as? TimeInterval)
            }
            guard let delay, delay > 0.011 else { return 0.1 }
            return delay
        }
    }
}
