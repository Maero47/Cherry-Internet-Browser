//
//  FailureSurface.swift
//  Cherry Browser
//
//  The surface the three failure screens are drawn on, and the one colour they
//  add to the app.
//
//  ## Why there is only one new colour
//
//  These screens appear when the user is already annoyed, so they borrow rather
//  than invent: the surface is `LibraryPalette.listSurface`
//  (`NSColor.controlBackgroundColor`, #FFFFFF in Aqua and #1E1E1E in Dark
//  Aqua), the body tone is `LibraryPalette.supporting`, the radii are
//  `LibraryShape`'s, and the buttons are the same system controls
//  `WebActionConsentSheet` uses, so they carry the user's accent through
//  `CherryWindowRoot`'s `.tint`.
//
//  Exactly one tone is new: `caution`, for the certificate interstitial's mark
//  and its "Not secure" label.
//
//  ## Why caution is not systemRed
//
//  Measured against the real surface with WCAG 2.x relative luminance:
//
//      colour                      light      dark
//      labelColor (.primary)       14.94:1    12.23:1   ← headlines
//      LibraryPalette.supporting   5.74:1     5.93:1    ← body
//      caution                     7.02:1     8.24:1    ← the warning tone
//      systemRed                   3.55:1     4.71:1    ← fails light mode
//      systemOrange                2.20:1     7.53:1    ← fails light mode badly
//
//  `systemRed` is 3.55:1 on white. A certificate warning drawn in it is a
//  warning the user cannot read, which is the one failure mode this screen
//  cannot have. `caution` is a measured amber-brown (#8C4600 light,
//  #F2A65A dark) that clears the floor with room to spare in both appearances
//  and still reads as caution rather than as decoration.
//
//  `FailureContrastTests` re-measures all of it against the shipped colours.
//

import AppKit
import SwiftUI

nonisolated enum FailurePalette {

    /// The page these screens stand in for. Same surface the library screens
    /// draw on, so a full-window Cherry screen looks like a Cherry screen.
    static var surface: Color { LibraryPalette.listSurface }

    /// Body copy, the failing address, the scope sentence.
    static var body: Color { LibraryPalette.supporting }

    /// The certificate interstitial's mark and its "Not secure" label. The only
    /// tone in this feature that is not already somewhere else in the app.
    /// 7.02:1 light, 8.24:1 dark on `surface`.
    static let caution = dynamic(
        light: NSColor(srgbRed: 0.549, green: 0.275, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 0.949, green: 0.651, blue: 0.353, alpha: 1),
        name: "cherryFailureCaution"
    )

    /// A quiet fill for the box the failing address sits in. The same hairline
    /// weight the library rows and `SettingsCard` use.
    static var inset: Color { Color.primary.opacity(0.05) }
    static var hairline: Color { LibraryPalette.hairline }

    private static func dynamic(light: NSColor, dark: NSColor, name: String) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Shared layout

/// The column's own numbers, in one place because something outside the column
/// now needs them: the runner's field is sized against this measure and these
/// margins (`PearlField`), so a change here has to reach it rather than be
/// copied into it.
nonisolated enum FailureLayout {
    /// The reading measure. A failure sentence wider than this stops being a
    /// sentence and starts being a wall.
    static let measure = 560.0
    /// Kept on each side of the column, at every window width.
    static let horizontalMargin = 40.0
    static let verticalMargin = 56.0
    /// Between the column's rows.
    static let rowSpacing = 16.0
}

/// The size of the whole surface a failure screen was given — the window's
/// content area, not the column's share of it.
///
/// Published through the environment rather than handed to the column's
/// content builder, and that is deliberate twice over. A builder taking the
/// size would be a closure, and `PearlRunnerSurfaceTests` proves the runner is
/// drawn above the failure copy by walking the column's content with `Mirror`
/// — which can see a stored view tree and cannot see into a closure. It is
/// also the smaller change: only the one row that cares reads it.
private struct FailureContainerSizeKey: EnvironmentKey {
    /// Zero until a `FailureColumn` measures itself. Anything sized against
    /// this must therefore be sensible at zero; `PearlField` answers with its
    /// floor.
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var failureContainerSize: CGSize {
        get { self[FailureContainerSizeKey.self] }
        set { self[FailureContainerSizeKey.self] = newValue }
    }
}

/// The column both failure screens are laid out in: one measure, one set of
/// margins, so the error surface and the certificate interstitial do not read
/// as two different products.
struct FailureColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Centred in the window when it fits, scrollable when it does not. The
        // `minHeight` is what makes both true at once: a short window (or a
        // long unrecognised-error sentence) scrolls instead of clipping the
        // buttons off the bottom, which is the failure mode a plain centred
        // stack has.
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: FailureLayout.rowSpacing) {
                    content
                }
                .frame(maxWidth: FailureLayout.measure, alignment: .leading)
                .padding(.horizontal, FailureLayout.horizontalMargin)
                .padding(.vertical, FailureLayout.verticalMargin)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
            // What the runner's field is sized against. The column's own copy
            // ignores it and keeps its measure.
            .environment(\.failureContainerSize, geometry.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FailurePalette.surface)
    }
}

/// The address, shown the way an address should be: whole, selectable, and in
/// a face where `l`, `1` and `I` are distinguishable. Rendered with
/// `Text(verbatim:)` so nothing in a URL is ever read as markdown.
struct FailureAddress: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(FailurePalette.body)
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(LibraryShape.rowShape.fill(FailurePalette.inset))
            .overlay(LibraryShape.rowShape.stroke(FailurePalette.hairline, lineWidth: 1))
            .accessibilityLabel("Address that failed to load: \(text)")
    }
}
