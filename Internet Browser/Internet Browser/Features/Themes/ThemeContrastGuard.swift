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
//  For each control the guard re-composites the exact backdrop that control is
//  drawn against — same frame colour, same header images, same anchoring and
//  tiling arithmetic (`ThemeHeaderLayerPlacement`), same overlay colours — into
//  a small offscreen bitmap, and measures it. If the control already clears its
//  floor, the guard returns nil and NOT ONE PIXEL changes.
//
//  Only where it fails does a scrim appear: behind that one control, in the
//  direction that moves the backdrop away from the glyph (dark under a light
//  glyph, light under a dark one), at the LOWEST opacity that clears the floor
//  and no more. It is soft-edged and control-sized, so the artwork still runs
//  between and around the controls and still reads as the illustration the user
//  imported the theme for. A flat bar across the cluster would fix the number
//  and destroy the reason the theme is there.
//
//  ## Why a percentile and not the mean
//
//  A control's backdrop is not one colour, it is a few hundred pixels of
//  illustration. Averaging hides the highlight the glyph actually vanishes
//  against. The guard solves for the **10th-percentile pixel** — the worst
//  tenth of the region must clear the floor — which makes the median (what a
//  screenshot audit measures) clear it comfortably.
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

    /// The scrim `foreground` needs over `backdrop` to clear `floor`, or nil
    /// when it already does — which is the answer for every control the theme
    /// already draws legibly, and the reason a legible theme is untouched.
    ///
    /// Opacity is found by bisection rather than a formula because the
    /// criterion is a percentile over the real pixels, not a single blended
    /// colour. It is monotonic in opacity (every pixel moves the same way), so
    /// bisection converges on the minimum.
    static func scrim(foreground: RGBA, backdrop: [RGB], floor: Double) -> ThemeScrimPlan? {
        guard !backdrop.isEmpty else { return nil }

        let before = harmfulRatio(foreground: foreground, backdrop: backdrop)
        guard before < floor else { return nil }

        // Away from the glyph's own tone: darken under a light glyph, lighten
        // under a dark one. Chosen from the foreground alone, so every control
        // sharing a colour gets the same direction and the row stays coherent.
        let glyph = composite(foreground, over: RGB(red: 0.5, green: 0.5, blue: 0.5))
        let isDark = relativeLuminance(glyph) > scrimCrossoverLuminance
        let scrimColor: RGB = isDark ? .black : .white

        func ratioAt(_ opacity: Double) -> Double {
            let scrimmed = backdrop.map { pixel in
                composite(RGBA(rgb: scrimColor, alpha: opacity), over: pixel)
            }
            return harmfulRatio(foreground: foreground, backdrop: scrimmed)
        }

        var low = 0.0
        var high = 1.0
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if ratioAt(mid) >= floor { high = mid } else { low = mid }
        }
        // Rounded UP to a hundredth so the shipped opacity is never a hair
        // under the solved one.
        let opacity = min(1.0, (high * 100).rounded(.up) / 100)

        return ThemeScrimPlan(
            isDark: isDark,
            opacity: opacity,
            ratioBefore: before,
            ratioAfter: ratioAt(opacity)
        )
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

    /// Longest side of the sampling bitmap. A toolbar glyph box is 18pt, so
    /// this is 1:1 for buttons and a downsample for the wider text runs.
    ///
    /// Sampling is POINT-sampled, not interpolated (see `interpolationQuality`
    /// below), and that is the whole reason this number can be small. Smoothly
    /// downsampling a patterned backdrop averages its highlights into its
    /// shadows, and the highlight IS the thing a glyph disappears into — a
    /// blended sample reports a backdrop that is nowhere on screen and solves
    /// for a scrim too weak to deliver its own ratio.
    static let maxResolution = 48

    /// Animated header layers (GIF/APNG) are sampled at up to this many frames
    /// and the results UNIONED, so the scrim is solved against the whole loop.
    /// A scrim that only holds on frame 0 is not a fix for an animated theme.
    static let maxAnimationSamples = 6

    /// The composited backdrop under `rect` (global/SwiftUI coordinates),
    /// anchored inside `canvas` (the window-wide virtual canvas header images
    /// align to). Empty when no theme is active.
    static func backdrop(
        under rect: CGRect,
        canvas: CGRect,
        overlays: [Color]
    ) -> [ThemeContrast.RGB] {
        let manager = FirefoxThemeManager.shared
        guard manager.activeTheme != nil, rect.width >= 1, rect.height >= 1 else { return [] }

        let base = manager.frameBackground.map(ThemeContrast.resolve)
            // Image-only theme with no frame colour: the stock `.bar` material
            // is underneath, and its resolved window background is the closest
            // thing to it that can be measured.
            ?? ThemeContrast.resolve(Color(nsColor: .windowBackgroundColor))
        let renderers = manager.headerBackgrounds.map(BackgroundLayerRenderer.init)
        let resolvedOverlays = overlays.map(ThemeContrast.resolve)

        let frames = min(
            maxAnimationSamples,
            max(1, renderers.map(\.sampleFrameCount).max() ?? 1)
        )
        var pixels: [ThemeContrast.RGB] = []
        for frame in 0..<frames {
            pixels += compose(
                rect: rect,
                canvas: canvas,
                base: base.rgb,
                renderers: renderers,
                frame: frame,
                overlays: resolvedOverlays
            )
        }
        return pixels
    }

    private static func compose(
        rect: CGRect,
        canvas: CGRect,
        base: ThemeContrast.RGB,
        renderers: [BackgroundLayerRenderer],
        frame: Int,
        overlays: [ThemeContrast.RGBA]
    ) -> [ThemeContrast.RGB] {
        let width = max(1, min(maxResolution, Int(rect.width.rounded())))
        let height = max(1, min(maxResolution, Int(rect.height.rounded())))
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

/// Answers "does this control need a scrim, and how much" for one rectangle,
/// caching the answer.
///
/// A cache is not an optimisation here, it is what makes the guard usable from
/// a view body at all: the question is asked on every layout pass of every
/// control, and the answer only changes when the theme, the geometry, or the
/// colours do — which is exactly the key.
@MainActor
final class ThemeContrastGuard {
    static let shared = ThemeContrastGuard()

    private var cache: [String: ThemeScrimPlan?] = [:]
    /// Dominant tones of extension action icons, by extension id.
    private var tones: [String: Color] = [:]

    /// Plenty for every control in several windows at a few window widths;
    /// dropped wholesale rather than evicted one by one, because a resize
    /// invalidates a whole generation of keys at once anyway.
    private let cacheLimit = 1024

    private init() {}

    /// The scrim needed behind `rect` (global coordinates) for a control drawn
    /// in `foreground`, or nil when the theme already draws it above `floor` —
    /// including whenever no theme is active at all, which is what keeps the
    /// stock look untouched.
    ///
    /// - Parameters:
    ///   - rect: the region actually occupied by the glyph or text, not the
    ///     whole hit target: measuring the padding around a 16pt icon would
    ///     average in artwork nothing is drawn on.
    ///   - overlays: colours this surface paints between the header backdrop
    ///     and the control (the theme's `toolbar`, a field fill, a tab fill).
    func scrim(
        behind rect: CGRect,
        canvas: CGRect?,
        foreground: Color?,
        overlays: [Color],
        floor: Double
    ) -> ThemeScrimPlan? {
        // Read first and unconditionally: this is the @Observable dependency
        // that re-runs the caller's body when the theme changes, and a cache
        // hit must not skip it.
        let themeID = FirefoxThemeManager.shared.activeTheme?.id
        guard let themeID, let foreground, rect.width >= 1, rect.height >= 1 else { return nil }

        let canvas = canvas ?? rect
        let resolved = ThemeContrast.resolve(foreground)
        let key = [
            themeID,
            Self.quantized(rect), Self.quantized(canvas),
            Self.tag(resolved), overlays.map { Self.tag(ThemeContrast.resolve($0)) }.joined(separator: "/"),
            String(format: "%.2f", floor)
        ].joined(separator: "|")

        if let cached = cache[key] { return cached }

        let backdrop = ThemeBackdropSampler.backdrop(under: rect, canvas: canvas, overlays: overlays)
        let plan = ThemeContrast.scrim(foreground: resolved, backdrop: backdrop, floor: floor)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = plan
        return plan
    }

    /// The dominant tone of an arbitrary icon image, for the one kind of
    /// toolbar control whose glyph Cherry does not choose: an extension's
    /// action icon.
    ///
    /// Without this the guard measures such a button against the bar's
    /// `toolbar_text` — a colour that button never draws — and can pick the
    /// wrong direction outright. uBO Lite's icon is a dark red shield, so on a
    /// bright illustration it needs the backdrop LIGHTENED while its neighbours
    /// need it darkened.
    ///
    /// The tone is the alpha-weighted mean over the icon, so it describes the
    /// silhouette that has to read against the bar. A two-tone icon still has
    /// internal contrast of its own, and that is the extension's design, not
    /// something a scrim behind it can or should correct.
    func dominantTone(of image: NSImage, id: String) -> Color? {
        if let cached = tones[id] { return cached }

        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var total = (red: 0.0, green: 0.0, blue: 0.0, weight: 0.0)
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            // Premultiplied, so the stored components are already alpha-scaled
            // — summing them and dividing by summed alpha is the weighted mean.
            let alpha = Double(bytes[index + 3]) / 255
            guard alpha > 0 else { continue }
            total.red += Double(bytes[index]) / 255
            total.green += Double(bytes[index + 1]) / 255
            total.blue += Double(bytes[index + 2]) / 255
            total.weight += alpha
        }
        guard total.weight > 0 else { return nil }

        let tone = Color(
            .sRGB,
            red: total.red / total.weight,
            green: total.green / total.weight,
            blue: total.blue / total.weight,
            opacity: 1
        )
        tones[id] = tone
        return tone
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

private struct ThemeLegibilityKey: EnvironmentKey {
    static let defaultValue: ThemeLegibility? = nil
}

extension EnvironmentValues {
    var themeLegibility: ThemeLegibility? {
        get { self[ThemeLegibilityKey.self] }
        set { self[ThemeLegibilityKey.self] = newValue }
    }
}

extension View {
    /// Declares how this subtree's controls are drawn, for
    /// `themeLegibilityScrim()` to measure against. Set once per themed
    /// surface; pass nil to opt a subtree out.
    func themeLegibility(_ value: ThemeLegibility?) -> some View {
        environment(\.themeLegibility, value)
    }

    /// Overrides just the glyph tone for one control — the few that carry
    /// their own tint (the accent-coloured state indicators) rather than the
    /// theme's `toolbar_text`. Keeps the surface's overlay stack. Passing nil
    /// keeps the inherited tone, which is what a toggle in its OFF state wants:
    /// it is back to plain `toolbar_text` then.
    func themeLegibilityTint(_ tint: Color?) -> some View {
        modifier(ThemeLegibilityTint(tint: tint))
    }

    /// Backs this control with the measured scrim it needs — and with nothing
    /// at all when the theme already draws it above `floor`, which is the
    /// common case and the whole point.
    ///
    /// - Parameters:
    ///   - measureInset: how far in from this view's bounds the glyph actually
    ///     is. A 28pt toolbar button carries a 16pt symbol, so the outer ring
    ///     is padding no glyph is drawn on and must not be averaged in.
    ///   - softness: blur applied to the scrim's edge, so it reads as light
    ///     falling off rather than as a chip stamped on the artwork.
    ///   - spread: how far the scrim shape is grown BEYOND this view before it
    ///     is blurred. This is not decoration: a blur eats into the middle as
    ///     well as the rim, and a scrim that only reaches its solved opacity at
    ///     the very centre does not deliver the ratio it was solved for.
    ///     Growing by more than the blur's reach keeps the whole measured
    ///     region at full opacity and puts the entire falloff outside it —
    ///     which is what makes the shipped pixels match the arithmetic.
    ///   - context: how this one control is drawn. Given explicitly rather
    ///     than read from the environment wherever the surface knows it, since
    ///     `.background` content sits OUTSIDE an `.environment` applied to the
    ///     view it backs — so `.themeLegibility(x).themeLegibilityScrim()`
    ///     would silently measure nothing. Nil falls back to the environment,
    ///     which is how `ToolbarButtonStyle` picks up the whole bar's tone.
    func themeLegibilityScrim(
        _ context: ThemeLegibility? = nil,
        floor: Double = ThemeContrast.iconFloor,
        cornerRadius: CGFloat = 9,
        measureInset: CGFloat = 5,
        softness: CGFloat = 1,
        spread: CGFloat = 3
    ) -> some View {
        background {
            ThemeLegibilityScrimLayer(
                explicitContext: context,
                floor: floor,
                cornerRadius: cornerRadius,
                measureInset: measureInset,
                softness: softness,
                spread: spread
            )
        }
    }
}

private struct ThemeLegibilityTint: ViewModifier {
    @Environment(\.themeLegibility) private var context
    let tint: Color?

    func body(content: Content) -> some View {
        content.environment(
            \.themeLegibility,
            context.map { ThemeLegibility(foreground: tint ?? $0.foreground, overlays: $0.overlays) }
        )
    }
}

private struct ThemeLegibilityScrimLayer: View {
    @Environment(\.chromeCanvasFrame) private var chromeCanvasFrame
    @Environment(\.themeLegibility) private var inherited

    let explicitContext: ThemeLegibility?
    let floor: Double
    let cornerRadius: CGFloat
    let measureInset: CGFloat
    let softness: CGFloat
    let spread: CGFloat

    private var context: ThemeLegibility? { explicitContext ?? inherited }

    var body: some View {
        GeometryReader { geometry in
            let bounds = geometry.frame(in: .global)
            let measured = bounds.insetBy(
                dx: min(measureInset, bounds.width / 3),
                dy: min(measureInset, bounds.height / 3)
            )
            if let plan = ThemeContrastGuard.shared.scrim(
                behind: measured,
                canvas: chromeCanvasFrame,
                foreground: context?.foreground,
                overlays: context?.overlays ?? [],
                floor: floor
            ) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(plan.color.opacity(plan.opacity))
                    .padding(-spread)
                    .blur(radius: softness)
            }
        }
        .allowsHitTesting(false)
    }
}
