//
//  OmniboxView.swift
//  Internet Browser
//

import SwiftUI

struct OmniboxView: View {
    @Binding var text: String
    let isLoading: Bool
    let isSecure: Bool
    /// Private windows are never themed by an imported Firefox theme.
    var isPrivateMode: Bool = false
    /// Any change takes keyboard focus (View ▸ Focus Address Bar, ⌘L). A
    /// counter rather than a Bool so repeated ⌘L presses each re-focus and
    /// re-select, the way every browser's address bar behaves.
    var focusTrigger: Int = 0
    let onSubmit: (String) -> Void
    let onFocus: () -> Void
    var onTextChange: ((String) -> Void)? = nil
    var onBlur: (() -> Void)? = nil
    var onArrowDown: (() -> Void)? = nil
    var onArrowUp: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    /// Imported Firefox theme overrides (toolbar_field*), nil when no theme
    /// is active or in a private window — the field then keeps its material.
    private var themedFieldBackground: Color? {
        guard !isPrivateMode else { return nil }
        let manager = FirefoxThemeManager.shared
        return isFocused ? manager.fieldFocusBackground : manager.fieldBackground
    }
    private var themedFieldText: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.fieldText
    }
    private var themedFocusBorder: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.fieldFocusBorder
    }

    /// What the URL is drawn in, and what the bar paints between the theme
    /// header artwork and it — the theme's `toolbar` colour and then the
    /// field's own (frequently translucent) fill. Nil unthemed and in private
    /// windows, which leaves the material field exactly as it was.
    private var fieldLegibility: ThemeLegibility? {
        let manager = FirefoxThemeManager.shared
        guard !isPrivateMode, manager.activeTheme != nil,
              let fieldBackground = themedFieldBackground else { return nil }
        var overlays: [Color] = []
        if manager.hasHeaderBackdrop, let toolbar = manager.toolbarColor { overlays.append(toolbar) }
        overlays.append(fieldBackground)
        return ThemeLegibility(foreground: themedFieldText ?? Color.primary, overlays: overlays)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Security indicator
            if !isFocused && !text.isEmpty {
                securityIndicator
            }

            // Text field
            TextField("Search or enter website name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit {
                    submitInput()
                }
                .onChange(of: isFocused) { _, newValue in
                    if newValue {
                        onFocus()
                        // Select all text when focused
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.firstResponder?
                                .tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                        }
                    } else {
                        onBlur?()
                    }
                }
                .onChange(of: text) { _, newValue in
                    if isFocused {
                        onTextChange?(newValue)
                    }
                }
                .onKeyPress(.downArrow) {
                    onArrowDown?()
                    return onArrowDown != nil ? .handled : .ignored
                }
                .onKeyPress(.upArrow) {
                    onArrowUp?()
                    return onArrowUp != nil ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    onEscape?()
                    return onEscape != nil ? .handled : .ignored
                }
                .onChange(of: focusTrigger) { _, _ in
                    // Already focused? Re-select all, which `onChange(of:
                    // isFocused)` would otherwise skip.
                    if isFocused {
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.firstResponder?
                                .tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                        }
                    } else {
                        isFocused = true
                    }
                }

            // Loading indicator or reload button
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .foregroundStyle(themedFieldText ?? Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if let themedFieldBackground {
                // Often semi-transparent (e.g. rgba(0,0,0,0.34)) — it
                // composites over the nav bar's theme header backdrop
                // (frame color + header images + toolbar color) behind this
                // view, exactly like Firefox's URL field over its header.
                //
                // Which is exactly why the field needs the guard too: a 34%
                // black fill over a bright illustration is not a background,
                // it is a tint on the artwork, and the URL is read against
                // whatever shows through. The scrim stays inside the field's
                // own rounded rect, so all that changes is how opaque the
                // field is — no new shape appears on the bar.
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themedFieldBackground)
                    // ON TOP of the field colour, not under it: the guard
                    // solves for a scrim composited over the backdrop it
                    // sampled, and that sample already includes the field fill.
                    // Sliding it underneath would make the shipped opacity
                    // stop matching the arithmetic that chose it.
                    Color.clear
                        .themeLegibilityPlate(
                            fieldLegibility,
                            floor: ThemeContrast.textFloor,
                            cornerRadius: 8,
                            measureInset: 2,
                            // The URL can be any length, so every run-of-text
                            // width across the field has to hold, not just the
                            // stretch this particular address happens to cover.
                            windowPoints: 40,
                            spread: 0
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFocused ? (themedFocusBorder ?? SettingsManager.shared.accentColor) : Color.primary.opacity(0.12),
                    lineWidth: isFocused ? 2 : 0.5
                )
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        )
    }

    @ViewBuilder
    private var securityIndicator: some View {
        if isSecure {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if text.hasPrefix("http://") {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    private func submitInput() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        onSubmit(input)
        isFocused = false
    }

    func focus() {
        isFocused = true
    }
}

