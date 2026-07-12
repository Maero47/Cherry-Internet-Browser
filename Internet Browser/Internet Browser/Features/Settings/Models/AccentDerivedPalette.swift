//
//  AccentDerivedPalette.swift
//  Cherry Browser
//

import SwiftUI

/// Derives the homepage appearance (MeshGradient colors, picker preview, logo)
/// from an accent color hex, powering the "Match Accent" homepage mode.
///
/// Kept separate from `HomepageTheme` on purpose: it is one *source* of
/// homepage colors among others (curated themes today, possibly imported
/// browser themes later), all funneled through `SettingsManager`'s
/// `homepageGradientColors` / `homepageLogoImageName`.
enum AccentDerivedPalette {

    // MARK: - Gradient derivation

    /// Returns 9 MeshGradient colors (3×3 grid) spun out of the accent color.
    ///
    /// The grid mirrors the structure of the curated `HomepageTheme` palettes:
    /// two rich mid-tone rows on top (the center cell brightest, so the mesh
    /// glows from the middle) and a near-black bottom row that anchors the
    /// gradient. Columns drift a few degrees around the accent hue so the
    /// result reads as a cohesive wash of the accent rather than a flat fill.
    /// `HomepageBackground`'s light-mode white overlay turns these deep tones
    /// into pastels, exactly as it does for the curated themes.
    static func gradientColors(fromHex hex: String) -> [Color] {
        let accent = hsb(fromHex: hex)
        // Anchor overall depth to the accent's own brightness (0.30–0.65 for
        // typical accents) so dark accents yield dark homepages.
        let base = 0.30 + 0.35 * accent.brightness

        func cell(_ hueShift: Double, _ satMul: Double, _ brightMul: Double) -> Color {
            Color(
                hue: wrappedHue(accent.hue + hueShift),
                saturation: min(1, accent.saturation * satMul),
                brightness: min(0.72, max(0.05, base * brightMul))
            )
        }

        return [
            cell(-0.035, 1.05, 0.80), cell( 0.000, 1.05, 0.92), cell(+0.030, 1.10, 0.70),
            cell(-0.020, 1.00, 0.62), cell(+0.010, 0.95, 1.00), cell(+0.035, 1.05, 0.78),
            cell(-0.015, 1.10, 0.24), cell( 0.000, 1.10, 0.30), cell(+0.020, 1.15, 0.17),
        ]
    }

    // MARK: - Logo selection

    /// Picks the closest-hue Cherry logo asset for the accent, falling back to
    /// the neutral black logo for desaturated (graphite-like) accents.
    static func logoImageName(fromHex hex: String) -> String {
        let accent = hsb(fromHex: hex)
        guard accent.saturation >= 0.25 else { return "CherryLogoBlack" }

        switch accent.hue * 360 {
        case 345..., ..<20: return "CherryLogoRed"
        case ..<50:         return "CherryLogoOrange"
        case ..<195:        return "CherryLogoGreen"
        case ..<255:        return "CherryLogoBlue"
        case ..<300:        return "CherryLogoPurple"
        default:            return "CherryLogoPink"
        }
    }

    // MARK: - Color math

    struct HSB {
        var hue: Double        // 0..<1
        var saturation: Double // 0...1
        var brightness: Double // 0...1
    }

    /// Parses a hex string (same formats as `Color(hex:)`) into HSB components.
    static func hsb(fromHex hex: String) -> HSB {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (r, g, b) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (0, 0, 0)
        }
        return hsb(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    static func hsb(red: Double, green: Double, blue: Double) -> HSB {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC

        var hue = 0.0
        if delta > 0 {
            if maxC == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        return HSB(
            hue: hue,
            saturation: maxC == 0 ? 0 : delta / maxC,
            brightness: maxC
        )
    }

    private static func wrappedHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }
}
