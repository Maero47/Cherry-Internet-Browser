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
