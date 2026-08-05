//
//  SystemAccentSurfaces.swift
//  Cherry Browser
//

import Foundation

/// The surfaces macOS paints from `NSColor.controlAccentColor` rather than from
/// SwiftUI's tint — i.e. what is left in Cherry that does NOT follow
/// `SettingsManager.accentColor` — and the sentence Settings uses to say so.
///
/// **Menus used to be the longest entry on this list and are no longer on it at
/// all.** macOS renders SwiftUI's `Menu`, `.contextMenu` and `Picker` as real
/// `NSMenu`s, and `NSMenu` has no tint of any kind: its highlight is a system
/// material fed by the app's compile-time `AccentColor` asset
/// (`NSColor.selectedMenuItemColor` is deprecated with "no longer a color but a
/// tinted blur effect"). So every menu Cherry opened was the asset's colour
/// whatever the user picked. Cherry now draws its own menus
/// (`CherryMenuController`), which puts them on the tint with everything else.
///
/// What is left here genuinely cannot be reached: `NSColor.h` declares
/// `controlAccentColor` as `@property (class, strong, readonly)` — no setter,
/// and its own comment calls it "a dynamic color that reflects the user's
/// *current preferred* accent color". The one writable input was the
/// `AccentColor` asset, and it is deliberately **absent** now, so these
/// surfaces are the stock macOS accent rather than cherry red. That is the
/// point: they cannot be made to match the user's Cherry accent, so the next
/// best thing is that they do not fight it.
///
/// A caption is easy to let rot, which is what `surveyed` and `cherryDrawn` are
/// for: they are the checklists `caption` is tested against, so the next person
/// to reword it cannot quietly drop a surface — or, now, quietly re-add menus
/// to the wrong side of the sentence.
enum SystemAccentSurfaces {

    /// Every surface confirmed to ignore Cherry's accent, in the order the
    /// caption names them. Confirmed by screenshot and by sampling the pixel,
    /// with Cherry's accent set to blue AND to purple.
    ///
    /// Lower-cased because the caption capitalises only whichever one it starts
    /// with; the test matches case-insensitively.
    static let surveyed = [
        "focus rings",
        "alerts",
        "save panels",
        "inside web pages",
    ]

    /// Surfaces that DO follow the accent and that the caption must not leave
    /// the user guessing about, because they used to be on the other list.
    static let cherryDrawn = [
        "menus",
    ]

    /// What Settings tells the user, verbatim.
    ///
    /// The first sentence exists because menus were the reported defect: a user
    /// who remembers red menus needs to be told they now follow, not left to
    /// discover it. The second names what is still out of reach, and the
    /// Multicolour clause is the surprising part — it is the default, and it is
    /// why those surfaces are macOS blue rather than anything Cherry chose.
    static let caption = """
        Cherry's own menus follow the accent you pick here. Focus rings, alerts, \
        save panels, and the menu and text selection inside web pages are drawn \
        by macOS: those follow the accent colour you pick in System Settings ▸ \
        Appearance, and are the standard macOS colour while that is set to \
        Multicolour.
        """
}
