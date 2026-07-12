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
                RoundedRectangle(cornerRadius: 8)
                    .fill(themedFieldBackground)
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

