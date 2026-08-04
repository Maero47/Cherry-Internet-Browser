//
//  MCPStatusPalette.swift
//  Cherry Browser
//
//  The three colours the Connections pane adds, and the measurements that
//  justify them.
//
//  ## Why not `.secondary`, `.red`, `.green`
//
//  Every number below was read off the real colours in both appearances rather
//  than eyeballed, against the pane's actual surface: `SettingsCard` fills with
//  `NSColor.controlBackgroundColor`, which resolves to #FFFFFF in Aqua and
//  #1E1E1E in Dark Aqua. Contrast is WCAG 2.x relative luminance.
//
//      colour                     light      dark
//      labelColor (.primary)      14.94:1    12.23:1     ← used for status titles
//      secondaryLabelColor        3.95:1     5.89:1      ← FAILS in light mode
//      systemRed                  3.57:1     4.86:1      ← FAILS in light mode
//      systemGreen                2.22:1     8.25:1      ← FAILS in light mode
//
//  The three system choices a status view reaches for first all fail the 4.5:1
//  floor in light mode. A status colour that only reads in dark mode is a bug,
//  so this pane carries its own, per-appearance:
//
//      failure    #B3261E / #FF8A8A          6.54:1     7.34:1
//      serving    #1A7F3C / #4ED07E          5.07:1     8.46:1
//      supporting #666666 / #9A9A9A          5.74:1     5.93:1
//
//  `supporting` exists because `.secondary` at 3.95:1 cannot carry copy that
//  says what a client can read off this browser. It is a dimmer grey that still
//  clears the floor, so the pane keeps its hierarchy without lying quietly.
//
//  The accent is used for exactly one thing here, the "in use right now" glyph,
//  and never for text: the user picks the accent, so its contrast is not ours
//  to guarantee.
//

import AppKit
import SwiftUI

nonisolated enum MCPStatusPalette {

    /// Cannot run. 6.54:1 light, 7.34:1 dark.
    static let failure = dynamic(
        light: NSColor(srgbRed: 0.702, green: 0.149, blue: 0.118, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.541, blue: 0.541, alpha: 1),
        name: "cherryMCPFailure"
    )

    /// Bound and waiting. 5.07:1 light, 8.46:1 dark.
    static let serving = dynamic(
        light: NSColor(srgbRed: 0.102, green: 0.498, blue: 0.235, alpha: 1),
        dark: NSColor(srgbRed: 0.306, green: 0.816, blue: 0.494, alpha: 1),
        name: "cherryMCPServing"
    )

    /// Body copy that should sit below a title without dropping under the
    /// contrast floor. 5.74:1 light, 5.93:1 dark.
    static let supporting = dynamic(
        light: NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1),
        dark: NSColor(srgbRed: 0.604, green: 0.604, blue: 0.604, alpha: 1),
        name: "cherryMCPSupporting"
    )

    /// Switched off, or between states. Deliberately the plain label grey.
    static let dormant = MCPStatusPalette.supporting

    private static func dynamic(light: NSColor, dark: NSColor, name: String) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Drawing on an unknown backdrop

    /// The darker of the two tones `readableForeground(on:)` picks between.
    /// Not pure black: #1A1A1A against a light accent is within a hair of
    /// black's contrast and does not read as a hole punched in the badge.
    static let ink = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1)

    /// White or `ink`, whichever contrasts better with `background`.
    ///
    /// This is what lets the toolbar indicator survive a backdrop nobody can
    /// measure in advance. The indicator draws on `.bar`, or an imported
    /// theme's `toolbarColor`, or a header backdrop **image** — so the glyph
    /// cannot be tinted and left to take its chances. Instead it sits on an
    /// opaque accent-filled badge, and this picks a glyph tone guaranteed to
    /// contrast with that badge. The badge decouples the signal from the
    /// backdrop entirely: whatever is behind it, the glyph is only ever read
    /// against the badge.
    ///
    /// Measured across the eight shipped accents, worst case **4.60:1**
    /// (Pink #DB2777), best 5.70:1 (Purple #7C3AED) — every one clears 4.5.
    /// `MCPStatusPaletteTests` re-measures the whole palette rather than
    /// trusting that sentence.
    static func readableForeground(on background: Color) -> Color {
        Color(nsColor: readableForeground(on: NSColor(background)))
    }

    static func readableForeground(on background: NSColor) -> NSColor {
        let white = NSColor.white
        return contrastRatio(white, background) >= contrastRatio(ink, background) ? white : ink
    }

    /// WCAG 2.x contrast ratio of `foreground` drawn on `background`. Exposed so
    /// the tests measure with the same arithmetic the choice is made with,
    /// rather than a copy of it.
    ///
    /// `foreground` is composited over `background` first, because several of
    /// the colours worth measuring are translucent: `secondaryLabelColor` is
    /// black at half alpha, not a grey. Treating its raw components as opaque
    /// reports 21:1 for a colour that actually renders at 3.95:1 — a
    /// measurement that flatters exactly the colour this palette exists to
    /// replace.
    static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> Double {
        let (a, b) = (
            relativeLuminance(composite(foreground, over: background)),
            relativeLuminance(background)
        )
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `foreground` painted over an opaque `background`. A no-op for an opaque
    /// foreground, which is what the badge and the pane's own three colours are.
    static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        guard let top = foreground.usingColorSpace(.sRGB),
              let bottom = background.usingColorSpace(.sRGB)
        else {
            return foreground
        }
        let alpha = top.alphaComponent
        guard alpha < 1 else { return top }
        func blend(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * alpha + b * (1 - alpha) }
        return NSColor(
            srgbRed: blend(top.redComponent, bottom.redComponent),
            green: blend(top.greenComponent, bottom.greenComponent),
            blue: blend(top.blueComponent, bottom.blueComponent),
            alpha: 1
        )
    }

    static func relativeLuminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }
}

extension MCPServerPresentation.Tone {

    /// The glyph's colour. Never applied to body text except in `.failure`,
    /// where the red is measured and the title carries it.
    var color: Color {
        switch self {
        case .off, .starting: MCPStatusPalette.dormant
        case .ready: MCPStatusPalette.serving
        case .inUse: SettingsManager.shared.accentColor
        case .failure: MCPStatusPalette.failure
        }
    }

    /// Titles stay at label contrast (≈15:1) unless the news is bad, where the
    /// measured red is the fastest thing to scan on the pane.
    var titleColor: Color {
        self == .failure ? MCPStatusPalette.failure : .primary
    }

    var symbol: String {
        switch self {
        case .off: "circle"
        case .starting: "circle.dotted"
        case .ready: "checkmark.circle.fill"
        case .inUse: "antenna.radiowaves.left.and.right"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}
