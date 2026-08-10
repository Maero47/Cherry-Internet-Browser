//
//  CherryAppearance.swift
//  Cherry Browser
//

import AppKit

/// Puts Cherry's appearance choice where AppKit can see it.
///
/// `CherryWindowRoot`'s `.preferredColorScheme` styles the SwiftUI content and
/// nothing else. Until this existed, that was the ONLY place the choice went:
/// `NSApp.effectiveAppearance` — and everything hanging off it: sheets, the
/// menu panels, alerts, open/save panels, and `ThemeContrast.resolve`, which
/// the contrast guard measures every glyph and plate through — kept following
/// macOS. The app had two appearances at once, the guard measured in one while
/// the content drew in the other, and with the system dark and Cherry light it
/// solved for exactly the wrong polarity (light glyph, light plate).
///
/// The choice is applied to the APPLICATION, not window by window. Cherry has
/// one appearance setting for the whole app, no Cherry window ever sets an
/// appearance of its own, and a window whose `appearance` is nil inherits
/// `NSApp`'s — so one assignment reaches every window that exists and every
/// window not yet born, panels and sheets included. System is expressed as no
/// override at all (nil), which is what lets AppKit keep re-deriving
/// `effectiveAppearance` from macOS while the app runs; storing "what the
/// system said at apply time" would freeze it.
///
/// Applied from `SettingsManager`: once at init (didSet does not fire there —
/// same pattern as `applyCookiePolicy` and `applyAppIcon`) and from
/// `appearanceMode.didSet` for live changes.
@MainActor
enum CherryAppearance {

    static func nsAppearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func apply(_ mode: AppearanceMode) {
        NSApp.appearance = nsAppearance(for: mode)
    }
}
