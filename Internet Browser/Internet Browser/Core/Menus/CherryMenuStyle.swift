//
//  CherryMenuStyle.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// The measurements and colours a Cherry-drawn menu uses.
///
/// Named constants rather than literals scattered through the view because
/// three separate things have to agree on them: the SwiftUI rows that draw the
/// menu, the sizing pass that decides how big the panel is before it is shown,
/// and the submenu placement, which needs a row's top edge in screen
/// coordinates. They are set to match AppKit's own menu metrics so a converted
/// menu and a still-native one (WebKit's page menu, the menu bar) do not read
/// as two different widgets.
enum CherryMenuMetrics {
    static let rowHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 11
    static let verticalPadding: CGFloat = 5
    /// How far the highlight is inset from the menu's edge.
    static let horizontalInset: CGFloat = 5
    /// How far a row's *content* is inset — the highlight inset plus the air
    /// inside it. `CherryMenuLayout.width` and the row body must agree on this
    /// or titles truncate.
    static let rowHorizontalPadding: CGFloat = 9
    static let rowCornerRadius: CGFloat = 5
    static let menuCornerRadius: CGFloat = 10
    static let fontSize: CGFloat = 13
    /// The checkmark column, always reserved so titles line up whether or not
    /// any row in the menu is checked — the same reason `NSMenu` reserves it.
    static let stateColumnWidth: CGFloat = 14
    static let iconColumnWidth: CGFloat = 17
    static let submenuChevronWidth: CGFloat = 14
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 460
    /// Trailing air after the longest title, so a menu is never text-tight.
    static let titleTrailingPadding: CGFloat = 16
}

enum CherryMenuColors {
    /// Black or white on the accent — whichever has the higher contrast ratio
    /// against it.
    ///
    /// `NSMenu` never had to answer this: its highlight was a system material,
    /// so AppKit picked the text colour. A highlight that is a solid fill of
    /// the user's accent makes the contrast ours to own, and Cherry ships eight
    /// accents spanning `#7C3AED` to `#EA580C`. Measured rather than guessed at
    /// with a brightness threshold, because on the light half of that range
    /// white text lands at 3.6:1 — under WCAG AA for body text, at the 13pt a
    /// menu row is set in. Picking the maximum is the rule that needs no magic
    /// number and cannot be tuned to the wrong answer.
    static func foregroundOn(_ accent: Color) -> Color {
        contrastRatio(of: .white, on: accent) >= contrastRatio(of: .black, on: accent) ? .white : .black
    }

    /// WCAG relative luminance. Returns `nil` for a colour with no sRGB
    /// representation, which no accent has.
    static func relativeLuminance(of color: Color) -> Double? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// WCAG contrast ratio, 1 (identical) to 21 (black on white).
    static func contrastRatio(of foreground: Color, on background: Color) -> Double {
        guard let a = relativeLuminance(of: foreground), let b = relativeLuminance(of: background) else { return 1 }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
