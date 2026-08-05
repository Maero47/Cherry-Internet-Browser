//
//  SystemAccentSurfaces.swift
//  Cherry Browser
//

import Foundation

/// The surfaces macOS paints from `NSColor.controlAccentColor` rather than from
/// SwiftUI's tint — i.e. the complete list of things in Cherry that do NOT
/// follow `SettingsManager.accentColor`, and the sentence Settings uses to say
/// so.
///
/// This is a value with a test rather than a string inside a view because the
/// sentence is the entire fix. Nothing can be recoloured:
///
/// - `NSColor.h` declares `controlAccentColor` as
///   `@property (class, strong, readonly)`. There is no setter, and its comment
///   calls it "a dynamic color that reflects the user's *current preferred*
///   accent color".
/// - `NSMenu` exposes no tint. It conforms to `NSAppearanceCustomization`, but
///   `NSAppearance` only spans light/dark/vibrant/high-contrast — there is no
///   accent axis and no public way to author an appearance. The highlight is
///   not even a colour any more: `NSColor.selectedMenuItemColor` is deprecated
///   with "no longer a color but a tinted blur effect", i.e. a system material.
/// - The only input is the compile-time `AccentColor` asset, and macOS consults
///   that only while System Settings ▸ Appearance ▸ Accent is "Multicolour".
///
/// So on a default Mac every menu Cherry opens highlights in the asset's cherry
/// red whatever accent the user picked in Settings, and naming that is the only
/// honest thing the app can do. Recolouring *some* of these would be worse than
/// naming all of them: the menu bar's menus and WebKit's page menu are not
/// Cherry's to draw, so a partial job would leave three highlight colours in
/// one app instead of the two there are now.
///
/// A caption is easy to let rot, which is what `surveyed` is for: it is the
/// checklist `caption` is tested against, so the next person to reword it
/// cannot quietly drop `menus` — the surface this list was extended for, and
/// the one users actually report.
enum SystemAccentSurfaces {

    /// Every surface confirmed to ignore Cherry's accent, in the order the
    /// caption names them. Confirmed by screenshot rather than by reasoning:
    /// the ⋯ menu, all of Cherry's context menus (tab, bookmark, history,
    /// download, homepage tile), `Picker` menus in Settings, WebKit's page
    /// menu, `NSSavePanel`/`NSAlert` chrome and web-page selection all sample
    /// the same red with the Cherry accent set to blue AND to purple.
    ///
    /// Lower-cased because the caption capitalises only whichever one it starts
    /// with; the test matches case-insensitively.
    static let surveyed = [
        "menus",
        "focus rings",
        "alerts",
        "save panels",
        "selection inside web pages",
    ]

    /// What Settings tells the user, verbatim.
    ///
    /// All three clauses earn their place. Naming the surfaces is the point.
    /// The Multicolour clause is the surprising one — it is the default, and it
    /// is why these surfaces look *stuck* on red rather than merely unthemed.
    /// And the menu bar clause is the exception that would otherwise make the
    /// sentence false: the menu bar's menus are drawn outside Cherry's process,
    /// so under Multicolour they fall back to stock macOS blue instead of to
    /// Cherry's asset.
    static let caption = """
        Menus, focus rings, alerts, save panels and selection inside web pages \
        are drawn by macOS: they follow the accent colour you pick in System \
        Settings ▸ Appearance, and stay Cherry red while that is set to \
        Multicolour. The menu bar's own menus stay macOS blue there instead.
        """
}
