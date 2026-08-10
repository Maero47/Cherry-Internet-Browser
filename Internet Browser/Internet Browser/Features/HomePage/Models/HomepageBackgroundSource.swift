//
//  HomepageBackgroundSource.swift
//  Cherry Browser
//

import Foundation

/// What actually gets painted behind the homepage. One value, decided in one
/// place, so the Settings picker, the selection state it draws and the
/// homepage itself can never disagree about which source won.
enum HomepageBackgroundSource: Equatable {
    /// The picture the user chose themselves, stored and owned by
    /// `HomepageCustomImageStore`.
    case customImage
    /// An imported Firefox theme's `ntp_background`, flat, as Firefox paints it.
    case themeBackground
    /// The wallpaper image shipped for one of the palette accents.
    case accentWallpaper(assetName: String)
    /// The live accent-derived mesh gradient — used when "Auto" is on but the
    /// accent isn't one of the palette colours, so no wallpaper exists for it.
    case accentGradient
    /// One of the curated homepage themes, chosen explicitly.
    case curatedTheme(HomepageTheme)
}

/// The pure decision behind `SettingsManager.homepageBackgroundSource`.
///
/// Split out from the views because this is exactly where the "I can't get
/// back to the accent wallpaper" bug lived: the old rule let an imported
/// Firefox theme's `ntp_background` outrank the "Auto" choice unconditionally
/// and forever, while Settings kept drawing "Auto" as selected. A theme
/// background now wins only while the user is *letting* it win
/// (`prefersThemeBackground`), which picking any swatch turns off.
enum HomepageBackgroundResolver {

    /// The wallpaper image set shipped for each palette accent, or nil for any
    /// other accent (a hand-edited or legacy `accentColorHex`).
    static func wallpaperAssetName(forAccentHex hex: String) -> String? {
        switch AccentHex.normalized(hex) {
        case "DB283C": return "HomepageWallpaperDB283C"
        case "2563EB": return "HomepageWallpaper2563EB"
        case "059669": return "HomepageWallpaper059669"
        case "7C3AED": return "HomepageWallpaper7C3AED"
        case "EA580C": return "HomepageWallpaperEA580C"
        case "DB2777": return "HomepageWallpaperDB2777"
        case "0D9488": return "HomepageWallpaper0D9488"
        case "6B7280": return "HomepageWallpaper6B7280"
        default: return nil
        }
    }

    /// - Parameters:
    ///   - matchesAccent: the "Auto" choice (`SettingsManager.homepageMatchesAccent`).
    ///   - prefersCustomImage: whether the user is currently letting their own
    ///     picture take over (`homepageUsesCustomImage`). Set when they pick
    ///     one, cleared the moment they pick any other swatch — the same
    ///     no-lock-out contract `prefersThemeBackground` follows.
    ///   - customImageIsAvailable: whether `HomepageCustomImageStore` actually
    ///     holds a readable picture. Preferring one that is gone (storage
    ///     cleaned, file corrupted) must fall through to the next source, not
    ///     to a blank page.
    ///   - prefersThemeBackground: whether the user is currently letting an
    ///     imported theme's background take over (`homepageUsesThemeBackground`).
    ///     Set on import, cleared the moment the user picks a swatch.
    ///   - themeHasBackground: whether the active Firefox theme defines `ntp_background`.
    ///   - isPrivate: whether the asking window is a private one. Private
    ///     windows are never themed — the rule the toolbar, tab strip, omnibox,
    ///     bookmark bar and both sidebars all enforce — so an imported theme's
    ///     background can never win in one. Part of the pure decision rather
    ///     than a check at the call site, so it is covered by the same table.
    ///     The user's own picture is NOT gated on this: that rule keeps an
    ///     imported third-party artifact out of private windows, and the
    ///     picture is the user's own appearance choice, exactly like the
    ///     accent wallpaper — which private windows have always shown.
    static func resolve(
        matchesAccent: Bool,
        prefersCustomImage: Bool,
        customImageIsAvailable: Bool,
        prefersThemeBackground: Bool,
        themeHasBackground: Bool,
        isPrivate: Bool,
        accentHex: String,
        curatedTheme: HomepageTheme
    ) -> HomepageBackgroundSource {
        // A picture the user picked by hand is a stronger signal than a theme
        // they imported: importing a theme expresses "use this theme", while
        // choosing a file expresses "put exactly this on my homepage".
        if prefersCustomImage && customImageIsAvailable {
            return .customImage
        }
        if themeHasBackground && prefersThemeBackground && !isPrivate {
            return .themeBackground
        }
        guard matchesAccent else {
            return .curatedTheme(curatedTheme)
        }
        // No wallpaper ships for accents outside the palette; the accent-derived
        // mesh gradient still follows the accent, so "Auto" stays truthful
        // rather than falling back to an unrelated curated theme.
        if let assetName = wallpaperAssetName(forAccentHex: accentHex) {
            return .accentWallpaper(assetName: assetName)
        }
        return .accentGradient
    }
}
