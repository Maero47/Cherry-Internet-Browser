//
//  AccentTextSelection.swift
//  Cherry Browser
//

import AppKit
import SwiftUI

/// Tints the caret and the selection highlight in Cherry's OWN text fields.
///
/// These are the two accent-bearing surfaces that look like they belong to the
/// system but don't have to be: `NSTextView` exposes `insertionPointColor` and
/// `selectedTextAttributes`, so unlike focus rings, `NSAlert` buttons or the
/// open/save panels, selection is reachable from the app. Left alone it comes
/// from `NSColor.selectedTextBackgroundColor` / `textInsertionPointColor` —
/// i.e. the system accent, or Cherry red while the system accent is
/// "Multicolour" — which makes the address bar one of the most visible places
/// the old accent kept showing through.
///
/// Applied to the WINDOW'S SHARED FIELD EDITOR rather than to individual
/// fields: every `NSTextField`-backed SwiftUI `TextField` in a window edits
/// through that one `NSTextView` (which is why `OmniboxView` can send
/// `NSText.selectAll(_:)` to the window's first responder and have it work).
/// So one call per window covers the omnibox, the homepage search field,
/// find-in-page, every Settings field and every sheet — with nothing to
/// remember at each field, matching how `CherryWindowRoot` handles tint.
///
/// Not covered, and can't be from here: text inside web pages (WebKit draws
/// that from the system colour) and `TextEditor`-backed views such as the dev
/// tools HTML editor, which use their own `NSTextView` rather than the field
/// editor.
@MainActor
enum AccentTextSelection {

    /// Tints `window`'s shared field editor, creating it if this is the first
    /// ask. Called from `configureBrowserWindow`, so every window Cherry makes
    /// or adopts gets it.
    static func apply(to window: NSWindow) {
        guard let editor = window.fieldEditor(true, for: nil) as? NSTextView else { return }
        apply(to: editor)
    }

    static func apply(to textView: NSTextView) {
        let accent = NSColor(SettingsManager.shared.accentColor)
        textView.insertionPointColor = accent
        // Background only. Leaving `.foregroundColor` unset keeps each field's
        // own text colour, which stays legible under a translucent accent wash
        // in both light and dark mode — a fully opaque accent would not.
        textView.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.35)]
    }

    /// Re-tints every open window's field editor. Used when the accent changes
    /// so a field being edited at that moment updates too.
    static func refreshOpenWindows() {
        for window in NSApplication.shared.windows {
            apply(to: window)
        }
    }
}
