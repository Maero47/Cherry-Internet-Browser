//
//  OmniboxView.swift
//  Internet Browser
//

import SwiftUI

struct OmniboxView: View {
    @Binding var text: String
    let isLoading: Bool
    let isSecure: Bool
    let onSubmit: (String) -> Void
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

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
                    }
                }

            // Loading indicator or reload button
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? AppConstants.Colors.accentBlue : Color.clear, lineWidth: 2)
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

