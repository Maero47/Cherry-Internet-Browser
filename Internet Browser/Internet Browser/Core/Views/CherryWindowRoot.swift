//
//  CherryWindowRoot.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// The appearance every Cherry window inherits: the user's accent colour as
/// the SwiftUI tint, and the chosen light/dark override.
///
/// The light/dark override here styles the SwiftUI content ONLY. The same
/// choice is applied to `NSApp.appearance` by `CherryAppearance`, and both
/// must stay: without the AppKit half, every surface that reads
/// `effectiveAppearance` — sheets, panels, alerts, and the contrast guard's
/// `ThemeContrast.resolve` — follows macOS while the content follows Cherry,
/// and the guard measures glyphs in an appearance they are not drawn in.
///
/// This is applied ONCE per window root — the `WindowGroup` scene and each
/// `NSHostingView` the app builds by hand (detached windows, tear-off windows,
/// incognito windows, the tab ghost/preview chips). Everything those windows
/// contain, including sheets, popovers and alerts presented from them,
/// inherits it through the environment.
///
/// It deliberately replaces the seven scattered `.tint(...)` calls that used
/// to sit on individual controls: a new prominent button, switch or progress
/// bar anywhere in the app is accent-tinted with nothing to remember. Views
/// that paint the accent as an explicit *fill* (icon chips, selection rings)
/// still read `SettingsManager.shared.accentColor` directly — `.tint` only
/// governs what SwiftUI's own controls use.
///
/// What this CANNOT reach is anything macOS draws from
/// `NSColor.controlAccentColor`: focus rings, `NSAlert` buttons,
/// `NSOpenPanel`/`NSSavePanel`, and selection inside web page content. There is
/// no runtime API to retint those — `controlAccentColor` is a read-only class
/// property. `SystemAccentSurfaces` is the list, and the sentence Settings
/// shows the user.
///
/// **Menus used to be on that list and no longer are.** macOS renders SwiftUI's
/// `Menu`, `.contextMenu` and `Picker` as real `NSMenu`s, whose highlight comes
/// from the `AccentColor` asset by way of a system material and has no tint of
/// any kind — so every one of Cherry's own menus was cherry red whatever accent
/// the user picked. Cherry now draws them itself (`CherryMenuController`), so
/// they follow this `.tint` like every other Cherry-drawn surface. WebKit's
/// page context menu and the menu bar are the two that remain native, because
/// neither is Cherry's to draw.
///
/// Selection and the insertion point in Cherry's OWN text fields are likewise
/// not on the list — `NSTextView` exposes both, and `AccentTextSelection` sets
/// them on each window's field editor.
///
/// The surfaces that ARE still on it resolve to the accent the user picked in
/// System Settings ▸ Appearance; only while that is "Multicolour" (the macOS
/// default) do they fall back to the app's compile-time `AccentColor` asset.
/// That asset is deliberately neutral — see `Assets.xcassets/AccentColor` and
/// `SystemAccentSurfaces` — so a save panel does not come up cherry red next to
/// a blue Cherry accent.
struct CherryWindowRoot: ViewModifier {
    private var settings: SettingsManager { .shared }

    func body(content: Content) -> some View {
        content
            .tint(settings.accentColor)
            .preferredColorScheme(settings.resolvedColorScheme)
    }
}

extension View {
    /// Marks this view as a Cherry window's root content. See `CherryWindowRoot`.
    func cherryWindowRoot() -> ModifiedContent<Self, CherryWindowRoot> {
        modifier(CherryWindowRoot())
    }
}

/// Builds the `NSHostingView` for a hand-made Cherry window, with the window
/// root appearance already applied. Every `NSHostingView(rootView:)` in the
/// app goes through here so no window can be created untinted.
@MainActor
func cherryHostingView<Content: View>(_ content: Content) -> NSHostingView<ModifiedContent<Content, CherryWindowRoot>> {
    NSHostingView(rootView: content.cherryWindowRoot())
}
