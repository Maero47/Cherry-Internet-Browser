//
//  LibraryPalette.swift
//  Cherry Browser
//
//  The surfaces and text tones the library screens (History, Bookmarks,
//  Downloads) draw on, and the measurements that justify them.
//
//  ## Why these screens carry their own greys
//
//  The library screens are read, not admired: the whole task is "I saw a thing
//  before and I want it back". Every field in a row is information — the domain,
//  the time, the file size, where a file went. None of it is decoration, so none
//  of it may sit under the 4.5:1 floor.
//
//  `.secondary` cannot carry it. Measured against the real list surface
//  (`NSColor.controlBackgroundColor`, which resolves to #FFFFFF in Aqua and
//  #1E1E1E in Dark Aqua), with WCAG 2.x relative luminance and the translucent
//  system colours composited over the surface first:
//
//      colour                     light      dark
//      labelColor (.primary)      14.94:1    12.23:1    ← titles
//      secondaryLabelColor        3.95:1     5.89:1     ← FAILS in light mode
//      tertiaryLabelColor         2.30:1     3.31:1     ← FAILS in both
//
//  The old screens used `.secondary` for domains and `.tertiary` for timestamps.
//  In light mode that put the answer to "when did I see this" at 2.3:1.
//
//  So there are exactly two text tones here, and both clear the floor:
//
//      supporting  #666666 / #9A9A9A          5.74:1     5.93:1
//      failure     #B3261E / #FF8A8A          6.54:1     7.34:1
//
//  Hierarchy below the title is carried by size, weight and column position
//  instead of by fading text out. A row has one loud thing (its title) and
//  several quiet ones, and every quiet one is still legible.
//
//  These are the same measured values `MCPStatusPalette` arrived at for the
//  same surface and the same reason; they are restated here rather than
//  imported so the library screens do not depend on the MCP feature, and so
//  `LibraryContrastTests` measures them against *this* surface.
//
//  The accent is the user's own and is used for one thing: state (selection,
//  the in-progress bar, the active scope). Never for text, because the user
//  picks it and its contrast is not ours to guarantee.
//

import AppKit
import SwiftUI

nonisolated enum LibraryPalette {

    // MARK: - Surfaces

    /// The list's own surface. Rows draw straight onto this: no card per row,
    /// no panel inside a panel.
    static var listSurface: Color { Color(nsColor: .controlBackgroundColor) }

    /// The scope rail beside the list. The same treatment the Settings sidebar
    /// uses, so the two full-page surfaces in this app read as one idiom.
    static func railSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.2) : Color.gray.opacity(0.05)
    }

    /// Hairline between rows and around the rail. `SettingsCard`'s border tone.
    static var hairline: Color { Color.primary.opacity(0.06) }

    // MARK: - Text

    /// Everything below a row's title: domain, time, size, folder, count.
    /// 5.74:1 light, 5.93:1 dark on `listSurface`.
    static let supporting = dynamic(
        light: NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1),
        dark: NSColor(srgbRed: 0.604, green: 0.604, blue: 0.604, alpha: 1),
        name: "cherryLibrarySupporting"
    )

    /// A download that did not arrive. 6.54:1 light, 7.34:1 dark.
    /// The only red on these screens — the destructive *action* is not red.
    static let failure = dynamic(
        light: NSColor(srgbRed: 0.702, green: 0.149, blue: 0.118, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.541, blue: 0.541, alpha: 1),
        name: "cherryLibraryFailure"
    )

    private static func dynamic(light: NSColor, dark: NSColor, name: String) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Measurement
    //
    // The same arithmetic the header comment quotes, exposed so
    // `LibraryContrastTests` re-measures the shipped colours rather than
    // trusting a comment that can drift.

    /// WCAG 2.x contrast ratio of `foreground` drawn on `background`.
    ///
    /// `foreground` is composited over `background` first. This matters: the
    /// system label colours are black or white at fractional alpha, not greys.
    /// Reading their raw components reports 21:1 for `secondaryLabelColor`,
    /// which is precisely the flattering measurement this palette exists to
    /// refuse.
    static func contrastRatio(_ foreground: NSColor, on background: NSColor) -> Double {
        let (a, b) = (
            relativeLuminance(composite(foreground, over: background)),
            relativeLuminance(background)
        )
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        guard let top = foreground.usingColorSpace(.sRGB),
              let bottom = background.usingColorSpace(.sRGB)
        else { return foreground }
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

// MARK: - Shape vocabulary

/// The library screens add no new corner radius. Rows, pills and scope items
/// use the Settings sidebar's 7; the search field uses `ToolbarSurface`'s 8.
enum LibraryShape {
    static let row: CGFloat = 7
    static let field: CGFloat = AppConstants.ToolbarSurface.cornerRadius

    static var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: row, style: .continuous)
    }

    static var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: field, style: .continuous)
    }
}
