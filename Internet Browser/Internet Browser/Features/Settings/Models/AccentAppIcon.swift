//
//  AccentAppIcon.swift
//  Cherry Browser
//

import AppKit

/// Swaps the RUNNING app's icon — the one in the Dock, ⌘-Tab and the Force
/// Quit list — to the artwork that matches the current accent colour.
///
/// Asset-name driven and fail-safe by design: the artwork lives in image sets
/// named `AppIconAccent<HEX>` (one per palette accent). `NSImage(named:)`
/// returns nil for a name the catalog doesn't have, and assigning nil to
/// `applicationIconImage` is AppKit's documented way of restoring the bundled
/// `AppIcon`. So a build whose accent artwork hasn't landed yet — or a
/// hand-edited accent hex outside the palette — simply keeps the default icon
/// instead of showing a blank one.
///
/// This does NOT change the icon Finder shows for Cherry.app: that comes from
/// the `CFBundleIconFile`/`AppIcon` resource baked into the bundle and can
/// only change by shipping a different bundle.
enum AccentAppIcon {

    /// The image-set name for an accent hex. Pure, so it is unit-testable
    /// without touching `NSApplication`.
    ///
    /// The hex is normalised the same way `HomepageBackgroundResolver` does
    /// it — `#` stripped, upper-cased against a fixed locale so a Turkish
    /// system locale can't map an "i" out from under us — because both names
    /// are looked up against literal asset names.
    static func imageName(forAccentHex hex: String) -> String {
        "AppIconAccent" + AccentHex.normalized(hex)
    }

    /// Points `NSApplication.applicationIconImage` at the artwork for `hex`,
    /// falling back to the bundled icon when that artwork isn't in the bundle.
    @MainActor
    static func apply(accentHex: String) {
        NSApplication.shared.applicationIconImage = NSImage(named: imageName(forAccentHex: accentHex))
    }
}

/// Normalisation shared by every accent-hex → asset-name lookup.
enum AccentHex {
    /// Upper-cased, `#`/whitespace-free form of an accent hex.
    ///
    /// Locale-independent: these are identifiers, not prose. Hex digits dodge
    /// the Turkish I/ı mapping today only by accident, and the accent hex is a
    /// persisted string a user can hand-edit, so the fixed locale is the
    /// guarantee rather than the coincidence.
    static func normalized(_ hex: String) -> String {
        hex
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
