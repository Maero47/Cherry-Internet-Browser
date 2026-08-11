//
//  ThemeContrastGuard.swift
//  Internet Browser
//
//  Keeping chrome controls legible over a Firefox theme's header artwork.
//
//  ## The problem this exists for
//
//  `NavigationBarView` composites `ThemeHeaderBackdropView()` — the theme's
//  opaque `frame` colour plus its header images — and then the theme's own
//  (frequently transparent) `toolbar` colour over it. That is the
//  Firefox-compatible behaviour and it is correct: a theme whose toolbar colour
//  is transparent is SUPPOSED to show its illustration through the bar. Icons
//  are then drawn in one flat `toolbar_text`.
//
//  One flat colour cannot be legible against a busy illustration. Measured off
//  a real screenshot of an imported theme, the incognito eye landed on the
//  bright part of the artwork at **1.33:1** — invisible — while the reader book
//  a few pixels away sat at 5.10:1. Which control disappears depends on the
//  theme AND on the window width, because the art is anchored to the window's
//  right edge and slides under the controls as the window resizes.
//
//  ## What this does about it
//
//  Nothing, wherever the theme is already legible. That is the whole design.
//  The guard re-composites the exact backdrop a CLUSTER of controls is drawn
//  against — same frame colour, same header images, same anchoring and tiling
//  arithmetic (`ThemeHeaderLayerPlacement`), same overlay colours — into a
//  small offscreen bitmap, and measures it. If every control in the cluster
//  already clears its floor, the guard returns nil and NOT ONE PIXEL changes.
//
//  Where it does not, ONE surface appears behind the WHOLE cluster: one colour,
//  one opacity, one shape, decided once from the worst control-sized window
//  anywhere under it.
//
//  ## Why the decision is per cluster and never per control
//
//  The first version of this solved each control separately, and it was wrong
//  in a way no ratio caught. A translucent scrim takes its colour from whatever
//  it is over, so the sparkle got a pale pink patch, Home an orange one, the
//  star a tan one — each a different tint, a different width, and three
//  controls further along the row got nothing at all because they happened not
//  to need it. Magnified, it read as smudges rather than as a treatment, and
//  the patches were more eye-catching than the icons they existed to serve.
//
//  A control must not look different from the control beside it because of what
//  happens to be behind it. So: one decision per cluster, applied uniformly,
//  including to the controls that would have passed on their own. There is
//  deliberately NO per-control fallback — a fallback that fires on one icon in a
//  row would reproduce exactly the defect it was added to avoid.
//
//  That uniformity also constrains the glyphs. One surface can only serve one
//  polarity of foreground, so a themed toolbar draws EVERY glyph in the theme's
//  `toolbar_text` (see `NavigationBarView.themedGlyph`) rather than letting some
//  keep an accent tint. Firefox does the same thing with the same key, and the
//  toggles carry their state in their symbol (`book` vs `book.fill`) rather than
//  in their colour, so nothing is lost saying it.
//
//  ## Why a percentile, and why a window
//
//  A backdrop is not one colour, it is a few hundred pixels of illustration.
//  Averaging hides the highlight the glyph actually vanishes into, so the guard
//  solves for the **10th-percentile pixel** rather than the mean.
//
//  Across a cluster that is not enough on its own: a tenth of a nine-button
//  cluster is most of one button, so a single control could be sacrificed to the
//  average of its neighbours. The criterion is therefore applied to a sliding
//  CONTROL-SIZED window and the strictest answer wins — the tolerance is a
//  fraction of one control, never a fraction of the whole row.
//

import AppKit
import SwiftUI

// MARK: - The arithmetic

/// WCAG 2.x contrast over plain sRGB doubles.
///
/// Deliberately not `NSColor`-based like `MCPStatusPalette`: this runs over
/// hundreds of sampled pixels per control per layout pass, where NSColor
/// conversion would dominate. `ThemeContrastGuardTests` measures a set of
/// colours through BOTH and asserts they agree, so this staying honest is a
/// test result rather than a claim.
nonisolated enum ThemeContrast {

    /// WCAG AA for non-text content (icons, control glyphs).
    static let iconFloor = 3.0
    /// WCAG AA for body-size text — what the omnibox and tab titles are.
    static let textFloor = 4.5

    /// The share of a control's backdrop allowed to sit below the floor.
    /// Solving for the 10th-percentile pixel rather than the median is what
    /// stops a small bright highlight — exactly the thing an icon disappears
    /// into — from being averaged away.
    static let harmfulPercentile = 0.10

    /// The luminance at which a pure black and a pure white backdrop give a
    /// foreground the SAME contrast: (L+0.05)/0.05 == 1.05/(L+0.05), so
    /// (L+0.05)² = 0.0525 and L = √0.0525 − 0.05 ≈ 0.1791.
    ///
    /// Above it, darkening always beats lightening; below it, the reverse. It
    /// is also why a scrim can always succeed: at full opacity the better of
    /// the two directions is never worse than 0.2291/0.05 ≈ **4.58:1**, so the
    /// 3:1 floor is always reachable for an opaque glyph.
    static let scrimCrossoverLuminance = 0.1791288

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)
    }

    struct RGBA: Equatable {
        var rgb: RGB
        var alpha: Double
    }

    static func relativeLuminance(_ color: RGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }

    static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `top` painted over an opaque `bottom`. Alpha compositing happens in the
    /// display's own (gamma-encoded) space, which is what these components are.
    static func composite(_ top: RGBA, over bottom: RGB) -> RGB {
        guard top.alpha < 1 else { return top.rgb }
        let a = max(0, top.alpha)
        return RGB(
            red: top.rgb.red * a + bottom.red * (1 - a),
            green: top.rgb.green * a + bottom.green * (1 - a),
            blue: top.rgb.blue * a + bottom.blue * (1 - a)
        )
    }

    /// The contrast of `foreground` against `backdrop` at the harmful tail —
    /// the value the worst `harmfulPercentile` of the region falls below.
    static func harmfulRatio(foreground: RGBA, backdrop: [RGB]) -> Double {
        guard !backdrop.isEmpty else { return .infinity }
        var ratios = backdrop.map { pixel -> Double in
            ratio(relativeLuminance(composite(foreground, over: pixel)), relativeLuminance(pixel))
        }
        ratios.sort()
        let index = Int((Double(ratios.count - 1) * harmfulPercentile).rounded(.down))
        return ratios[index]
    }

    /// Which way a scrim has to move the backdrop for this foreground: darken
    /// under a light glyph, lighten under a dark one. A property of the
    /// foreground ALONE, which is what lets one surface serve a whole cluster.
    static func scrimIsDark(for foreground: RGBA) -> Bool {
        let glyph = composite(foreground, over: RGB(red: 0.5, green: 0.5, blue: 0.5))
        return relativeLuminance(glyph) > scrimCrossoverLuminance
    }

    /// Whether a glyph of this tone belongs in `appearance`.
    ///
    /// A light glyph belongs on a dark bar and a dark glyph on a light one.
    /// This is the same crossover `scrimIsDark` uses, asked of the appearance
    /// instead of the scrim, so the two can never disagree about which side of
    /// the line a tone is on.
    static func glyphSuits(_ foreground: RGBA, _ appearance: ColorScheme) -> Bool {
        scrimIsDark(for: foreground) == (appearance == .dark)
    }

    /// The least opacity of `scrimColor` that brings `backdrop` up to `floor`
    /// for `foreground`, or nil when it is already there.
    ///
    /// Found by bisection rather than a formula because the criterion is a
    /// percentile over the real pixels, not a single blended colour. It is
    /// monotonic in opacity (every pixel moves the same way), so bisection
    /// converges on the minimum.
    static func minimumOpacity(
        foreground: RGBA, backdrop: [RGB], scrimColor: RGB, floor: Double
    ) -> Double? {
        guard !backdrop.isEmpty else { return nil }
        guard harmfulRatio(foreground: foreground, backdrop: backdrop) < floor else { return nil }

        func ratioAt(_ opacity: Double) -> Double {
            harmfulRatio(
                foreground: foreground,
                backdrop: backdrop.map { composite(RGBA(rgb: scrimColor, alpha: opacity), over: $0) }
            )
        }

        var low = 0.0
        var high = 1.0
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if ratioAt(mid) >= floor { high = mid } else { low = mid }
        }
        // Rounded UP to a hundredth so the shipped opacity is never a hair
        // under the solved one.
        return min(1.0, (high * 100).rounded(.up) / 100)
    }

    /// ONE surface for a whole cluster: the colour and opacity that make EVERY
    /// control-sized window under `sample` clear `floor`, or nil when they all
    /// already do.
    ///
    /// The window is what stops a cluster averaging one of its own controls
    /// away. `harmfulPercentile` of a nine-button row is most of one button, so
    /// applying the percentile to the row as a whole would let a single control
    /// sit under the floor and still pass. Applied to a sliding control-sized
    /// window instead, the tolerance stays a fraction of ONE control wherever
    /// the window happens to be, and the strictest window sets the surface.
    ///
    /// Windows overlap by half, so a bad patch straddling two of them is caught
    /// whole by the one centred on it rather than diluted by both.
    static func plate(
        foreground: RGBA,
        sample: ThemeBackdropSample,
        floor: Double,
        windowPoints: CGFloat
    ) -> ThemeScrimPlan? {
        guard !sample.pixels.isEmpty, sample.columns > 0, sample.rows > 0 else { return nil }

        let isDark = scrimIsDark(for: foreground)
        let scrimColor: RGB = isDark ? .black : .white

        var worstBefore = Double.infinity
        var required = 0.0
        for window in sample.windows(ofPoints: windowPoints) {
            worstBefore = min(worstBefore, harmfulRatio(foreground: foreground, backdrop: window))
            if let opacity = minimumOpacity(
                foreground: foreground, backdrop: window, scrimColor: scrimColor, floor: floor
            ) {
                required = max(required, opacity)
            }
        }
        guard required > 0 else { return nil }

        // Reported at the worst window, which is the one the surface was sized
        // for — every other window clears by more.
        var worstAfter = Double.infinity
        for window in sample.windows(ofPoints: windowPoints) {
            worstAfter = min(worstAfter, harmfulRatio(
                foreground: foreground,
                backdrop: window.map { composite(RGBA(rgb: scrimColor, alpha: required), over: $0) }
            ))
        }

        return ThemeScrimPlan(
            isDark: isDark, opacity: required, ratioBefore: worstBefore, ratioAfter: worstAfter
        )
    }
}

/// A rectangle of composited backdrop, kept 2-D so it can be walked a control
/// at a time rather than averaged whole.
struct ThemeBackdropSample: Equatable {
    /// Row-major, `columns` per row.
    var pixels: [ThemeContrast.RGB]
    var columns: Int
    var rows: Int
    /// Width in POINTS of the region these samples cover, which is what turns a
    /// control size into a number of columns.
    var pointWidth: CGFloat

    static let empty = ThemeBackdropSample(pixels: [], columns: 0, rows: 0, pointWidth: 0)

    /// Every control-sized window across the sample, each as a flat pixel list.
    /// A region narrower than one window is one window.
    func windows(ofPoints windowPoints: CGFloat) -> [[ThemeContrast.RGB]] {
        guard columns > 0, rows > 0, pixels.count == columns * rows else { return [] }
        guard pointWidth > 0, windowPoints > 0, pointWidth > windowPoints else { return [pixels] }

        let width = max(1, min(columns, Int((windowPoints / pointWidth * CGFloat(columns)).rounded())))
        let stride = max(1, width / 2)
        var result: [[ThemeContrast.RGB]] = []
        var start = 0
        while start + width <= columns {
            var window: [ThemeContrast.RGB] = []
            window.reserveCapacity(width * rows)
            for row in 0..<rows {
                let base = row * columns + start
                window.append(contentsOf: pixels[base..<(base + width)])
            }
            result.append(window)
            if start + width == columns { break }
            start = min(start + stride, columns - width)
        }
        return result
    }
}

/// What to draw behind one control, and the two numbers that justify it.
struct ThemeScrimPlan: Equatable {
    /// True for a black scrim (light glyph), false for a white one.
    let isDark: Bool
    /// The minimum opacity that clears the floor, to a hundredth.
    let opacity: Double
    /// Harmful-tail contrast the control had without it.
    let ratioBefore: Double
    /// Harmful-tail contrast it has with it.
    let ratioAfter: Double

    var color: Color { isDark ? .black : .white }
}

// MARK: - Sampling the real backdrop

/// Re-composites the theme header backdrop offscreen for one rectangle, so a
/// control can be measured against the pixels it is actually drawn on.
///
/// This is the same stack `ThemeHeaderBackdropView` paints — opaque `frame`
/// colour, then the header image layers bottom-first through
/// `ThemeHeaderLayerPlacement`, then the surface's own overlay colours — into a
/// bitmap the size of the control instead of the size of the window.
@MainActor
enum ThemeBackdropSampler {

    /// Horizontal sampling resolution — effectively one sample per point up to
    /// a whole cluster's width. It has to stay near 1:1 ACROSS the row, because
    /// the cluster surface is decided by the worst control-sized window in it:
    /// squeeze a 280pt row into a few dozen columns and one control is five
    /// columns wide, far too coarse to find the highlight it vanishes into.
    static let maxColumns = 320

    /// Vertical resolution. A glyph box is 18pt, so this is 1:1 for the toolbar
    /// and a mild downsample for a tall region.
    static let maxRows = 24

    /// Animated header layers (GIF/APNG) are sampled at up to this many frames
    /// and STACKED into one sample, so every control-sized window spans the
    /// whole loop. A surface that only holds on frame 0 is not a fix for an
    /// animated theme.
    static let maxAnimationSamples = 6

    /// The composited backdrop under `rect` (global/SwiftUI coordinates),
    /// anchored inside `canvas` (the window-wide virtual canvas header images
    /// align to). Empty when no theme is active.
    ///
    /// Kept 2-D: the returned sample is walked a control at a time, so it
    /// cannot be flattened to a bag of pixels here. Animation frames stack
    /// along ROWS, which keeps each column band covering every frame.
    static func backdrop(
        under rect: CGRect,
        canvas: CGRect,
        overlays: [Color]
    ) -> ThemeBackdropSample {
        let manager = FirefoxThemeManager.shared
        guard manager.activeTheme != nil, rect.width >= 1, rect.height >= 1 else { return .empty }

        let base = manager.frameBackground.map(ThemeContrast.resolve)
            // Image-only theme with no frame colour: the stock `.bar` material
            // is underneath, and its resolved window background is the closest
            // thing to it that can be measured.
            ?? ThemeContrast.resolve(Color(nsColor: .windowBackgroundColor))
        let renderers = manager.headerBackgrounds.map(BackgroundLayerRenderer.init)
        let resolvedOverlays = overlays.map(ThemeContrast.resolve)

        let columns = max(1, min(maxColumns, Int(rect.width.rounded())))
        let rows = max(1, min(maxRows, Int(rect.height.rounded())))
        let frames = min(
            maxAnimationSamples,
            max(1, renderers.map(\.sampleFrameCount).max() ?? 1)
        )

        var pixels: [ThemeContrast.RGB] = []
        pixels.reserveCapacity(columns * rows * frames)
        for frame in 0..<frames {
            pixels += compose(
                rect: rect,
                canvas: canvas,
                columns: columns,
                rows: rows,
                base: base.rgb,
                renderers: renderers,
                frame: frame,
                overlays: resolvedOverlays
            )
        }
        guard pixels.count == columns * rows * frames else { return .empty }
        return ThemeBackdropSample(
            pixels: pixels, columns: columns, rows: rows * frames, pointWidth: rect.width
        )
    }

    private static func compose(
        rect: CGRect,
        canvas: CGRect,
        columns: Int,
        rows: Int,
        base: ThemeContrast.RGB,
        renderers: [BackgroundLayerRenderer],
        frame: Int,
        overlays: [ThemeContrast.RGBA]
    ) -> [ThemeContrast.RGB] {
        let width = columns
        let height = rows
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        // Keep real pixels rather than blended ones — see `maxResolution`.
        context.interpolationQuality = .none

        let bounds = CGRect(origin: .zero, size: rect.size)
        context.setFillColor(
            red: base.red, green: base.green, blue: base.blue, alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Work in the surface's own points with a TOP-LEFT origin, matching
        // the flipped canvas view the placement arithmetic was written for.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / rect.width, y: -CGFloat(height) / rect.height)

        let origin = CGPoint(x: rect.minX - canvas.minX, y: rect.minY - canvas.minY)
        for renderer in renderers.reversed() {
            guard let image = renderer.sampleImage(frame: frame) else { continue }
            for tile in renderer.placement.tileRects(
                imageSize: renderer.pointSize, canvas: canvas.size, origin: origin, viewBounds: bounds
            ) {
                context.saveGState()
                context.translateBy(x: tile.minX, y: tile.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: tile.size))
                context.restoreGState()
            }
        }

        for overlay in overlays where overlay.alpha > 0 {
            context.setFillColor(
                red: overlay.rgb.red, green: overlay.rgb.green,
                blue: overlay.rgb.blue, alpha: overlay.alpha
            )
            context.fill(bounds)
        }

        guard let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var pixels: [ThemeContrast.RGB] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            pixels.append(ThemeContrast.RGB(
                red: Double(bytes[index]) / 255,
                green: Double(bytes[index + 1]) / 255,
                blue: Double(bytes[index + 2]) / 255
            ))
        }
        return pixels
    }
}

extension ThemeContrast {

    /// The tone a themed toolbar actually draws its glyphs in.
    ///
    /// ## Who owns the tone
    ///
    /// A Firefox theme ships ONE `toolbar_text` and it does not vary by
    /// appearance — the format has no way to say "and this in light mode".
    /// For chrome the theme PAINTS, that is not a defect to be corrected: the
    /// theme's backdrop does not vary by appearance either, so the tone it
    /// was authored against is there in both. The appearance has no opinion
    /// about chrome the theme owns — the tone the theme names is the tone
    /// that gets drawn, in Light and in Dark alike, the way Firefox draws it.
    ///
    /// That pairing is also what keeps the island shut. Judging the theme's
    /// tone by the APPEARANCE put dark ink on the theme's dark bar in Light
    /// mode, and the guard — correctly serving the ink it was given — laid a
    /// pale plate under it: a light island punched into dark themed chrome.
    /// With the tone and the backdrop both the theme's, they are on the same
    /// side of the crossover by construction, the plate (chosen FROM the
    /// glyph, see `scrimIsDark`) lands on the theme's side too, and the same
    /// theme produces the same chrome colours in both appearances.
    ///
    /// The appearance still speaks twice, and only twice:
    /// - a theme that paints chrome but names NO tone gets the absolute
    ///   fallback for the current appearance;
    /// - a tone named for chrome the theme does NOT paint sits on a stock
    ///   surface, which DOES vary by appearance — there the old rule stands:
    ///   kept when it suits the appearance, dropped when it cannot be.
    /// The tone a themed bar falls back to when the theme names none.
    ///
    /// Absolute rather than `Color.primary`, and that is load-bearing: an
    /// absolute tone resolves the same in every appearance, so the glyph and
    /// the plate chosen from it can never disagree even if the appearance the
    /// guard measures in and the one the content draws in ever drift apart
    /// again. They used to: `.preferredColorScheme` was the only place
    /// Cherry's appearance choice went, so `resolve` measured in the SYSTEM's
    /// appearance while the content drew in Cherry's. `CherryAppearance` now
    /// pins `NSApp.appearance` to the same choice, which closes that gap — the
    /// absolute tones stay as the belt to that suspender.
    static let barGlyphOnLight = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let barGlyphOnDark = Color(red: 0.98, green: 0.98, blue: 0.98)

    @MainActor
    static func toolbarGlyph(
        themeText: Color?, themePaintsBackdrop: Bool, appearance: ColorScheme
    ) -> Color {
        let fallback = appearance == .dark ? barGlyphOnDark : barGlyphOnLight
        guard let themeText else { return fallback }
        guard themePaintsBackdrop else {
            return glyphSuits(resolve(themeText), appearance) ? themeText : fallback
        }
        return themeText
    }

    /// A SwiftUI `Color` as sRGB components, resolved against the app's
    /// effective appearance — `Color.primary` is a different colour in Aqua and
    /// Dark Aqua, and the guard must measure the one on screen.
    @MainActor
    static func resolve(_ color: Color) -> RGBA {
        let base = NSColor(color)
        var converted: NSColor?
        let appearance = NSApplication.shared.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            converted = base.usingColorSpace(.sRGB)
        }
        guard let srgb = converted ?? base.usingColorSpace(.sRGB) else {
            return RGBA(rgb: .black, alpha: 1)
        }
        return RGBA(
            rgb: RGB(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            ),
            alpha: Double(srgb.alphaComponent)
        )
    }
}

// MARK: - The guard

/// Answers "does this CLUSTER need a surface, and which one" for one rectangle,
/// caching the answer.
///
/// The unit is deliberately a cluster and never a control. Asking per control
/// is what produced a row of differently-tinted patches with gaps in it; asking
/// once for the row produces one surface or none.
///
/// A cache is not an optimisation here, it is what makes the guard usable from
/// a view body at all: the question is asked on every layout pass, and the
/// answer only changes when the theme, the geometry, or the colours do — which
/// is exactly the key.
@MainActor
final class ThemeContrastGuard {
    static let shared = ThemeContrastGuard()

    /// One question a chrome surface actually asked, and the answer served —
    /// enough to tell who asked (the rect, the floor, the control width) and
    /// what was decided.
    struct ServedPlate {
        let rect: CGRect
        let floor: Double
        let windowPoints: CGFloat
        let foreground: ThemeContrast.RGBA
        let plan: ThemeScrimPlan?
    }

    /// Recorded only while a test has set this non-nil; nil (the default)
    /// records nothing and costs nothing. This is how a test pins a view's
    /// BODY to the guard: the pure arithmetic can be perfectly tested and a
    /// bar still unguarded because nothing in its body asks, and measuring
    /// the drawn pixels to find out is banned on this project. Cache hits are
    /// recorded too — a body that asks is a body that asks.
    var served: [ServedPlate]?

    private var cache: [String: ThemeScrimPlan?] = [:]

    /// Plenty for every cluster in several windows at a few window widths;
    /// dropped wholesale rather than evicted one by one, because a resize
    /// invalidates a whole generation of keys at once anyway.
    private let cacheLimit = 512

    private init() {}

    /// The one surface `rect` needs so that EVERY control-sized window in it
    /// clears `floor`, or nil when they all already do — including whenever no
    /// theme is active at all, which is what keeps the stock look untouched.
    ///
    /// - Parameters:
    ///   - rect: the band the glyphs actually occupy across the whole cluster,
    ///     not the whole hit area: measuring the padding above and below a 16pt
    ///     row of icons would average in artwork nothing is drawn on.
    ///   - windowPoints: the width of one control. The tolerance inside the
    ///     percentile is a fraction of THIS, not of the cluster, so a wide row
    ///     cannot average one of its own controls away.
    ///   - overlays: colours this surface paints between the header backdrop
    ///     and the controls (the theme's `toolbar`, a field fill).
    func plate(
        behind rect: CGRect,
        canvas: CGRect?,
        context: ThemeLegibility?,
        floor: Double,
        windowPoints: CGFloat
    ) -> ThemeScrimPlan? {
        // Read first and unconditionally: this is the @Observable dependency
        // that re-runs the caller's body when the theme changes, and a cache
        // hit must not skip it.
        let themeID = FirefoxThemeManager.shared.activeTheme?.id
        guard let themeID, let context, rect.width >= 1, rect.height >= 1 else { return nil }

        let canvas = canvas ?? rect
        let resolved = ThemeContrast.resolve(context.foreground)
        let key = [
            themeID,
            Self.quantized(rect), Self.quantized(canvas),
            Self.tag(resolved),
            context.overlays.map { Self.tag(ThemeContrast.resolve($0)) }.joined(separator: "/"),
            String(format: "%.2f/%.0f", floor, windowPoints)
        ].joined(separator: "|")

        if let cached = cache[key] {
            served?.append(ServedPlate(
                rect: rect, floor: floor, windowPoints: windowPoints,
                foreground: resolved, plan: cached
            ))
            return cached
        }

        let sample = ThemeBackdropSampler.backdrop(
            under: rect, canvas: canvas, overlays: context.overlays
        )
        let plan = ThemeContrast.plate(
            foreground: resolved, sample: sample, floor: floor, windowPoints: windowPoints
        )
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = plan
        served?.append(ServedPlate(
            rect: rect, floor: floor, windowPoints: windowPoints,
            foreground: resolved, plan: plan
        ))
        return plan
    }

    private static func quantized(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }

    private static func tag(_ color: ThemeContrast.RGBA) -> String {
        String(
            format: "%02X%02X%02X%02X",
            Int((color.rgb.red * 255).rounded()), Int((color.rgb.green * 255).rounded()),
            Int((color.rgb.blue * 255).rounded()), Int((color.alpha * 255).rounded())
        )
    }
}

// MARK: - Applying it

/// What a themed chrome surface tells its controls about how they are drawn:
/// the tone of the glyph or text, and the colours the surface itself paints
/// between the theme header backdrop and that glyph.
///
/// Nil in the environment — the default, and what a private window and the
/// stock look both leave it as — switches the guard off entirely, which is
/// what makes the unthemed look impossible to move from here.
struct ThemeLegibility: Equatable {
    /// The tone the glyph or text is drawn in.
    var foreground: Color
    /// Layers this surface paints over the header backdrop: the theme's
    /// `toolbar` colour, a field fill, a selected tab's fill.
    var overlays: [Color] = []
}

extension View {
    /// Puts ONE measured surface behind this whole cluster — and nothing at all
    /// when every control-sized window under it already clears `floor`, which
    /// is the common case and the whole point.
    ///
    /// There is no per-control variant on purpose. The colour, the opacity and
    /// the shape are decided once for the cluster and applied to all of it,
    /// including to the controls that would have passed alone: a treatment that
    /// appears on some icons in a row and not others is the defect, not the fix.
    ///
    /// - Parameters:
    ///   - context: how this cluster's glyphs are drawn. Passed explicitly
    ///     rather than read from the environment, since `.background` content
    ///     sits OUTSIDE an `.environment` applied to the view it backs — so
    ///     `.themeLegibility(x).themeLegibilityPlate()` would silently measure
    ///     nothing.
    ///   - measureInset: how far in from this view's bounds the glyphs actually
    ///     are, vertically. A 28pt toolbar button carries a 16pt symbol, so the
    ///     rows above and below carry no glyph and must not be averaged in.
    ///   - windowPoints: the width of one control in this cluster.
    ///   - height: the row's shared surface height. Defaults to
    ///     `AppConstants.ToolbarSurface.height`, which is the omnibox's, so a
    ///     cluster surface is the same size and on the same centre line as the
    ///     pill beside it instead of being however tall its own contents plus
    ///     padding happened to come out. Tabs pass their own, being a different
    ///     row.
    ///   - decidedAcrossCluster: measure the whole cluster's span (published by
    ///     the container via `themeClusterSpan`) at this view's own vertical
    ///     band, instead of just this view's rect. For a row of SEPARATE views
    ///     that still form one cluster — the tab strip's tabs — which is what
    ///     makes every one of them reach the same answer and so look the same,
    ///     instead of each solving the patch of artwork it happens to sit on.
    func themeLegibilityPlate(
        _ context: ThemeLegibility?,
        floor: Double = ThemeContrast.iconFloor,
        shape: RoundedRectangle = AppConstants.ToolbarSurface.shape,
        height: CGFloat? = AppConstants.ToolbarSurface.height,
        measureInset: CGFloat = 5,
        windowPoints: CGFloat = 28,
        decidedAcrossCluster: Bool = false
    ) -> some View {
        background {
            ThemeLegibilityPlateLayer(
                context: context,
                floor: floor,
                shape: shape,
                height: height,
                measureInset: measureInset,
                windowPoints: windowPoints,
                decidedAcrossCluster: decidedAcrossCluster
            )
        }
    }
}

/// The horizontal span a cluster occupies, published by whoever owns the
/// cluster, for members that are SEPARATE views and cannot see each other —
/// the tab strip's tabs. Without it each tab would solve the patch of artwork
/// it happens to sit on and end up looking unlike its neighbour; with it they
/// all measure the same region and reach the same answer.
///
/// Only x and width are used; the vertical band comes from the member itself.
private struct ThemeClusterSpanKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var themeClusterSpan: CGRect? {
        get { self[ThemeClusterSpanKey.self] }
        set { self[ThemeClusterSpanKey.self] = newValue }
    }
}

extension View {
    /// Declares the span its members should all be measured across. Set by the
    /// container, read by `themeLegibilityPlate(decidedAcrossCluster:)`.
    func themeClusterSpan(_ span: CGRect?) -> some View {
        environment(\.themeClusterSpan, span)
    }
}

private struct ThemeLegibilityPlateLayer: View {
    @Environment(\.chromeCanvasFrame) private var chromeCanvasFrame
    @Environment(\.themeClusterSpan) private var clusterSpan

    let context: ThemeLegibility?
    let floor: Double
    let shape: RoundedRectangle
    /// Nil means "as tall as the thing being backed" — what a tab wants.
    let height: CGFloat?
    let measureInset: CGFloat
    let windowPoints: CGFloat
    let decidedAcrossCluster: Bool

    var body: some View {
        GeometryReader { geometry in
            let bounds = geometry.frame(in: .global)
            // Only the vertical band the glyphs occupy is measured; the full
            // width is, because the surface spans the full width and every
            // control-sized window in it has to hold.
            let own = bounds.insetBy(dx: 0, dy: min(measureInset, bounds.height / 3))
            let span = decidedAcrossCluster ? clusterSpan : nil
            let measured = span.map {
                CGRect(x: $0.minX, y: own.minY, width: max(1, $0.width), height: own.height)
            } ?? own
            if let plan = ThemeContrastGuard.shared.plate(
                behind: measured,
                canvas: chromeCanvasFrame,
                context: context,
                floor: floor,
                windowPoints: windowPoints
            ) {
                // A crisp edge, and no blur: this is a surface, not a smudge.
                // It also keeps the shipped opacity equal to the solved one
                // everywhere inside it, which a blurred shape does not.
                //
                // Drawn at the ROW's height on the row's centre line, in the
                // row's corner — not at whatever size this particular cluster's
                // contents came out. That is what makes it a sibling of the
                // omnibox pill rather than a second, separately-sized surface
                // that happens to sit beside one.
                shape
                    .fill(plan.color.opacity(plan.opacity))
                    .frame(height: height)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .allowsHitTesting(false)
    }
}
