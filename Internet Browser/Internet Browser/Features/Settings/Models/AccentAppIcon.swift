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

    /// The image-set name for an accent hex, or nil when the hex isn't one —
    /// see `AccentHex.canonical`. Pure, so it is unit-testable without
    /// touching `NSApplication`.
    ///
    /// Nil rather than a best-effort name on purpose: unvalidated
    /// concatenation turns an empty or punctuation-only `accentColorHex` into
    /// the bare prefix `"AppIconAccent"`, which resolves to nil today only
    /// because no such asset exists. The artwork branch is landing a whole
    /// `AppIconAccent*` family, so a bare-prefix lookup is a landmine; make
    /// the fallback deliberate instead of accidental.
    static func imageName(forAccentHex hex: String) -> String? {
        guard let canonical = AccentHex.canonical(hex) else { return nil }
        return "AppIconAccent" + canonical
    }

    /// Points `NSApplication.applicationIconImage` at the artwork for `hex`,
    /// falling back to the bundled icon when that artwork isn't in the bundle
    /// (or the hex isn't usable).
    @MainActor
    static func apply(accentHex: String) {
        NSApplication.shared.applicationIconImage = imageName(forAccentHex: accentHex)
            .flatMap { NSImage(named: $0) }
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

    /// `normalized`, but only for a string that really is a six-digit hex —
    /// the shape every palette accent and every accent-keyed asset uses. The
    /// 3- and 8-digit forms `Color(hex:)` also accepts have no artwork, so
    /// they get the same nil as garbage does.
    static func canonical(_ hex: String) -> String? {
        let normalized = normalized(hex)
        guard normalized.count == 6,
              normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }
}
